import Foundation

/// One transcribed word with when it was said and how sure the recognizer was.
struct SpokenWord: Codable, Hashable {
    var text: String
    /// Wall-clock time the word was said (seconds since the reference date),
    /// so words from different phones line up.
    var time: TimeInterval
    /// 0...1; 0.5 when the recognizer didn't say.
    var confidence: Double
    /// Index of the recorder (phone) that heard it.
    var source: Int

    var key: String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }
}

/// A combined transcript: stretches every phone agreed on, plus the places
/// they disagreed, each showing what every phone heard and which was used.
struct MergedTranscript: Codable, Hashable {
    struct Choice: Codable, Hashable {
        var source: Int
        var text: String
        var confidence: Double
    }

    struct Segment: Codable, Hashable, Identifiable {
        var id = UUID()
        var time: TimeInterval
        /// Text every phone agreed on (or that only one phone heard).
        var text: String?
        /// What each phone heard where they disagreed.
        var choices: [Choice]?
        var chosen = 0

        var displayText: String {
            if let choices, choices.indices.contains(chosen) { return choices[chosen].text }
            return text ?? ""
        }
    }

    var segments: [Segment]
    var sourceNames: [String]
    /// Stretches only one phone heard that were added to the transcript.
    var filledIn: Int

    var text: String {
        segments.map(\.displayText).filter { !$0.isEmpty }.joined(separator: " ")
    }

    var disagreementCount: Int { segments.filter { $0.choices != nil }.count }
}

/// Cross-checks independent transcripts of the same conversation made by
/// phones in different spots. Where the phones agree, the words stand.
/// Where one phone heard something the other missed (a far-end speaker),
/// it is filled in. Where they heard different words, the more confident
/// phone wins and the alternative is kept so a person can correct it.
enum TranscriptMerger {
    /// Words heard by only one phone are added when at least this confident.
    static let fillInConfidence = 0.35
    /// Phones' clocks and recognizers can disagree by a few seconds.
    private static let anchorWindow: TimeInterval = 20

    static func merge(_ streams: [[SpokenWord]], names: [String]) -> MergedTranscript {
        let ordered = streams.map { $0.sorted { $0.time < $1.time } }
        guard var merged = ordered.first.map({ words in
            words.map { Item.word($0) }
        }) else {
            return MergedTranscript(segments: [], sourceNames: names, filledIn: 0)
        }
        var filledIn = 0
        for stream in ordered.dropFirst() {
            merged = mergePair(merged, stream, filledIn: &filledIn)
        }
        return MergedTranscript(segments: segments(from: merged), sourceNames: names, filledIn: filledIn)
    }

    // MARK: - Pairwise merge

    /// Merged output so far: settled words, or disagreements already found.
    private enum Item {
        case word(SpokenWord)
        case choice(time: TimeInterval, [MergedTranscript.Choice])

        var time: TimeInterval {
            switch self {
            case .word(let w): w.time
            case .choice(let t, _): t
            }
        }
        /// The word used for alignment (disagreements use the chosen text).
        var asWord: SpokenWord {
            switch self {
            case .word(let w): return w
            case .choice(let t, let choices):
                let best = choices.max { $0.confidence < $1.confidence }!
                return SpokenWord(text: best.text, time: t, confidence: best.confidence, source: best.source)
            }
        }
    }

    private enum Op {
        case same(Int, Int)
        case onlyA(Int)
        case onlyB(Int)
    }

    private static func mergePair(_ a: [Item], _ b: [SpokenWord], filledIn: inout Int) -> [Item] {
        let aWords = a.map(\.asWord)
        let ops = align(aWords, b)

        var out: [Item] = []
        var regionA: [Int] = []
        var regionB: [Int] = []

        func flushRegion() {
            defer { regionA = []; regionB = [] }
            if regionA.isEmpty && regionB.isEmpty { return }
            if regionB.isEmpty {
                out.append(contentsOf: regionA.map { a[$0] })
                return
            }
            let bWords = regionB.map { b[$0] }
            if regionA.isEmpty {
                // Only the new phone heard this stretch.
                if mean(bWords) >= fillInConfidence {
                    out.append(contentsOf: bWords.map { Item.word($0) })
                    filledIn += 1
                }
                return
            }
            // Both heard something different here: keep both versions.
            let aItems = regionA.map { a[$0] }
            var choices: [MergedTranscript.Choice] = []
            if aItems.count == 1, case .choice(_, let earlier) = aItems[0] {
                choices = earlier
            } else {
                let words = aItems.map(\.asWord)
                choices.append(.init(source: words[0].source,
                                     text: words.map(\.text).joined(separator: " "),
                                     confidence: mean(words)))
            }
            choices.append(.init(source: bWords[0].source,
                                 text: bWords.map(\.text).joined(separator: " "),
                                 confidence: mean(bWords)))
            out.append(.choice(time: min(aItems[0].time, bWords[0].time), choices))
        }

        for op in ops {
            switch op {
            case .same(let i, let j):
                flushRegion()
                // Keep the more confident spelling/punctuation of the word.
                if case .word(let w) = a[i], b[j].confidence > w.confidence {
                    out.append(.word(b[j]))
                } else {
                    out.append(a[i])
                }
            case .onlyA(let i): regionA.append(i)
            case .onlyB(let j): regionB.append(j)
            }
        }
        flushRegion()
        return out
    }

    private static func mean(_ words: [SpokenWord]) -> Double {
        words.isEmpty ? 0 : words.map(\.confidence).reduce(0, +) / Double(words.count)
    }

    // MARK: - Alignment

    /// Lines up two word sequences. Unique three-word phrases both phones
    /// heard at about the same time anchor the alignment; the gaps between
    /// anchors are aligned word by word.
    private static func align(_ a: [SpokenWord], _ b: [SpokenWord]) -> [Op] {
        let anchors = findAnchors(a, b)
        var ops: [Op] = []
        var nextA = 0, nextB = 0
        for (i, j) in anchors where i >= nextA && j >= nextB {
            ops += alignGap(a, nextA..<i, b, nextB..<j)
            for k in 0..<3 { ops.append(.same(i + k, j + k)) }
            nextA = i + 3
            nextB = j + 3
        }
        ops += alignGap(a, nextA..<a.count, b, nextB..<b.count)
        return ops
    }

    private static func findAnchors(_ a: [SpokenWord], _ b: [SpokenWord]) -> [(Int, Int)] {
        func trigrams(_ w: [SpokenWord]) -> [String: [Int]] {
            var map: [String: [Int]] = [:]
            guard w.count >= 3 else { return map }
            for i in 0...(w.count - 3) {
                let key = "\(w[i].key) \(w[i + 1].key) \(w[i + 2].key)"
                map[key, default: []].append(i)
            }
            return map
        }
        let ta = trigrams(a), tb = trigrams(b)
        var pairs: [(Int, Int)] = []
        for (key, ia) in ta where ia.count == 1 {
            guard let jb = tb[key], jb.count == 1 else { continue }
            if abs(a[ia[0]].time - b[jb[0]].time) <= anchorWindow {
                pairs.append((ia[0], jb[0]))
            }
        }
        pairs.sort { $0.0 < $1.0 }
        return longestIncreasing(pairs)
    }

    /// Longest run of pairs whose second index also increases.
    private static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = []          // index into pairs
        var previous = [Int](repeating: -1, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].1 < pair.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { previous[index] = tails[lo - 1] }
            if lo == tails.count { tails.append(index) } else { tails[lo] = index }
        }
        var result: [(Int, Int)] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            result.append(pairs[cursor])
            cursor = previous[cursor]
        }
        return result.reversed()
    }

    /// Word-by-word alignment (Needleman–Wunsch) of a gap between anchors.
    private static func alignGap(_ a: [SpokenWord], _ ra: Range<Int>,
                                 _ b: [SpokenWord], _ rb: Range<Int>) -> [Op] {
        if rb.isEmpty { return ra.map { .onlyA($0) } }
        if ra.isEmpty { return rb.map { .onlyB($0) } }
        let n = ra.count, m = rb.count
        if n * m > 2_000_000 {
            // Too big to align (the phones heard very different things):
            // treat the whole stretch as one disagreement.
            return ra.map { .onlyA($0) } + rb.map { .onlyB($0) }
        }
        let match = 2, mismatch = -1, gap = -1
        let width = m + 1
        var score = [Int](repeating: 0, count: (n + 1) * width)
        for i in 0...n { score[i * width] = i * gap }
        for j in 0...m { score[j] = j * gap }
        for i in 1...n {
            for j in 1...m {
                let same = a[ra.lowerBound + i - 1].key == b[rb.lowerBound + j - 1].key
                let diag = score[(i - 1) * width + j - 1] + (same ? match : mismatch)
                let up = score[(i - 1) * width + j] + gap
                let left = score[i * width + j - 1] + gap
                score[i * width + j] = max(diag, up, left)
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let same = a[ra.lowerBound + i - 1].key == b[rb.lowerBound + j - 1].key
                if same, score[i * width + j] == score[(i - 1) * width + j - 1] + match {
                    ops.append(.same(ra.lowerBound + i - 1, rb.lowerBound + j - 1))
                    i -= 1; j -= 1
                    continue
                }
                if !same, score[i * width + j] == score[(i - 1) * width + j - 1] + mismatch {
                    ops.append(.onlyB(rb.lowerBound + j - 1))
                    ops.append(.onlyA(ra.lowerBound + i - 1))
                    i -= 1; j -= 1
                    continue
                }
            }
            if i > 0, score[i * width + j] == score[(i - 1) * width + j] + gap || j == 0 {
                ops.append(.onlyA(ra.lowerBound + i - 1)); i -= 1
            } else {
                ops.append(.onlyB(rb.lowerBound + j - 1)); j -= 1
            }
        }
        return ops.reversed()
    }

    // MARK: - Output

    private static func segments(from items: [Item]) -> [MergedTranscript.Segment] {
        var segments: [MergedTranscript.Segment] = []
        var words: [SpokenWord] = []
        func flush() {
            guard let first = words.first else { return }
            segments.append(.init(time: first.time, text: words.map(\.text).joined(separator: " ")))
            words = []
        }
        for item in items {
            switch item {
            case .word(let w): words.append(w)
            case .choice(let time, let choices):
                flush()
                let best = choices.indices.max { choices[$0].confidence < choices[$1].confidence } ?? 0
                segments.append(.init(time: time, choices: choices, chosen: best))
            }
        }
        flush()
        return segments
    }
}
