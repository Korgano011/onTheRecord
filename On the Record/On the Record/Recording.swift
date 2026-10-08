import Foundation

/// A stretch of the recording, in seconds of audio.
struct TimeSpan: Codable, Hashable {
    var start: TimeInterval
    var end: TimeInterval

    func contains(_ time: TimeInterval) -> Bool { time >= start && time < end }
}

/// A single saved recording plus its (optional) transcript.
/// Audio lives as an .m4a file in the app's Documents directory; the
/// metadata below is persisted alongside it as a sibling .json file so
/// everything stays in durable, user-accessible storage.
struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    /// Path relative to Documents (not a full path) so the record survives
    /// the app container moving between launches / devices. Autosaved parts
    /// live in a folder per session, e.g. "Board Meeting/Part 01.m4a".
    var audioFileName: String
    var transcript: String?
    /// Names of everyone who agreed to be recorded (nil for older recordings).
    var consentedBy: [String]?
    /// When the phone was locked during recording (nil for older recordings).
    var lockedSpans: [TimeSpan]?
    /// The transcript split by phone state. Set when lockedSpans is non-empty.
    var unlockedTranscript: String?
    var lockedTranscript: String?
    /// Wall-clock time the audio began, used to line up recordings of the
    /// same meeting made on different phones (nil for older recordings).
    var startedAt: Date?
    /// Code of the shared meeting this was recorded for, if any.
    var meetingCode: String?
    /// CloudKit record name once the audio is uploaded to the meeting.
    var uploadedRecordName: String?
    /// Identifies the recording session (and its folder in the list); shared
    /// by every autosaved part. Nil only for recordings made before folders.
    var sessionID: UUID?
    /// Which autosaved part this is (nil for single recordings).
    var partNumber: Int?
    /// When "Everyone has agreed on the recording" was tapped: seconds into
    /// this file's audio, and the clock time. Set only on the part where it
    /// happened, so the spoken consent can be found and played back.
    var consentAudioTime: TimeInterval?
    var consentDate: Date?

    init(id: UUID = UUID(),
         title: String,
         createdAt: Date = Date(),
         duration: TimeInterval = 0,
         audioFileName: String,
         transcript: String? = nil,
         consentedBy: [String]? = nil,
         lockedSpans: [TimeSpan]? = nil,
         startedAt: Date? = nil,
         meetingCode: String? = nil,
         sessionID: UUID? = nil,
         partNumber: Int? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.transcript = transcript
        self.consentedBy = consentedBy
        self.lockedSpans = lockedSpans
        self.startedAt = startedAt
        self.meetingCode = meetingCode
        self.sessionID = sessionID
        self.partNumber = partNumber
    }

    var audioURL: URL {
        Store.documentsDirectory.appendingPathComponent(audioFileName)
    }

    var metadataURL: URL {
        Store.documentsDirectory
            .appendingPathComponent(audioFileName)
            .deletingPathExtension()
            .appendingPathExtension("json")
    }

    /// Which part of a recording: captured with the phone unlocked or locked.
    enum PhonePart: Hashable, CaseIterable {
        case unlocked, locked

        var title: String { self == .unlocked ? "Phone unlocked" : "Phone locked" }
        var systemImage: String { self == .unlocked ? "lock.open" : "lock.fill" }
    }

    /// The audio spans for one part. Unlocked is everything outside the
    /// locked spans.
    func spans(for part: PhonePart) -> [TimeSpan] {
        let locked = (lockedSpans ?? []).sorted { $0.start < $1.start }
        if part == .locked { return locked }
        var unlocked: [TimeSpan] = []
        var cursor: TimeInterval = 0
        for span in locked {
            if span.start > cursor { unlocked.append(TimeSpan(start: cursor, end: span.start)) }
            cursor = max(cursor, span.end)
        }
        if duration > cursor { unlocked.append(TimeSpan(start: cursor, end: duration)) }
        return unlocked
    }

    func audioLength(for part: PhonePart) -> TimeInterval {
        spans(for: part).reduce(0) { $0 + max(0, min($1.end, duration) - $1.start) }
    }

    func transcript(for part: PhonePart) -> String? {
        part == .unlocked ? unlockedTranscript : lockedTranscript
    }

    mutating func setTranscript(_ text: String, for part: PhonePart) {
        if part == .unlocked { unlockedTranscript = text } else { lockedTranscript = text }
    }

    var formattedDuration: String {
        Recording.format(duration)
    }

    static func format(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Title and part number parsed from "Title (Part n)", for parts saved
    /// before sessionID/partNumber existed.
    var parsedPart: (base: String, number: Int)? {
        guard let match = title.wholeMatch(of: /(.+) \(Part (\d+)\)/),
              let number = Int(match.2) else { return nil }
        return (String(match.1), number)
    }
}

/// One recording session, shown as a folder: a single recording, or the
/// autosaved parts of a long one.
struct RecordingFolder: Identifiable, Hashable {
    let id: String
    let title: String
    /// Sorted by part number.
    let parts: [Recording]

    var createdAt: Date { parts.first?.createdAt ?? .distantPast }
    var duration: TimeInterval { parts.reduce(0) { $0 + $1.duration } }
    var partCount: String { parts.count == 1 ? "1 part" : "\(parts.count) parts" }

    static func number(of part: Recording) -> Int {
        part.partNumber ?? part.parsedPart?.number ?? 0
    }

    /// Which folder a recording belongs in: its session, or for older
    /// recordings its "Title (Part n)" title, or just itself.
    static func key(for recording: Recording) -> String {
        recording.sessionID?.uuidString
            ?? recording.parsedPart.map { "title-" + $0.base }
            ?? "rec-" + recording.id.uuidString
    }

    /// Every recording grouped into its session folder, newest first.
    static func group(_ recordings: [Recording]) -> [RecordingFolder] {
        Dictionary(grouping: recordings) { key(for: $0) }
            .map { key, parts in
                let sorted = parts.sorted { number(of: $0) < number(of: $1) }
                return RecordingFolder(id: key,
                                       title: sorted[0].parsedPart?.base ?? sorted[0].title,
                                       parts: sorted)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

/// Reads and writes `Recording` metadata to Documents.
enum Store {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Folders in Documents that hold other data, not recording parts.
    private static let reservedFolders: Set<String> = ["Meetings", TranscriptExports.folderName]

    static func loadAll() -> [Recording] {
        moveLooseParts()
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        // Top-level files plus one level of session folders.
        var files: [URL] = []
        for url in top {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard !reservedFolders.contains(url.lastPathComponent) else { continue }
                files += (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            } else {
                files.append(url)
            }
        }

        let decoder = JSONDecoder()
        var recordings: [Recording] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let rec = try? decoder.decode(Recording.self, from: data) {
                // Only keep records whose audio still exists.
                if fm.fileExists(atPath: rec.audioURL.path) {
                    recordings.append(rec)
                }
            }
        }
        return recordings.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ recording: Recording) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(recording) {
            try? data.write(to: recording.metadataURL, options: .atomic)
        }
    }

    static func delete(_ recording: Recording) {
        let fm = FileManager.default
        try? fm.removeItem(at: recording.audioURL)
        try? fm.removeItem(at: recording.metadataURL)
        removeFolderIfEmpty(recording.audioURL.deletingLastPathComponent())
    }

    /// Creates a new folder in Documents for one session's parts, named
    /// after its title so it's easy to find in the Files app. Returns the
    /// folder name, or nil if it couldn't be created.
    static func makeSessionFolder(named title: String) -> String? {
        let base = title
            .replacingOccurrences(of: "/", with: "-")
            .replacing(/(\d):(\d)/) { "\($0.1).\($0.2)" }   // 3:15 PM → 3.15 PM
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let safeBase = base.isEmpty || reservedFolders.contains(base) ? "Recording" : base
        let fm = FileManager.default
        var name = safeBase
        var n = 2
        while fm.fileExists(atPath: documentsDirectory.appendingPathComponent(name).path) {
            name = "\(safeBase) (\(n))"
            n += 1
        }
        do {
            try fm.createDirectory(at: documentsDirectory.appendingPathComponent(name, isDirectory: true),
                                   withIntermediateDirectories: false)
            return name
        } catch {
            return nil
        }
    }

    /// File name for a part inside its session folder; zero-padded so the
    /// Files app lists them in order.
    static func partFileName(_ number: Int) -> String {
        String(format: "Part %02d.m4a", number)
    }

    /// File name for a recording made without autosave (one file per folder).
    static let singleFileName = "Recording.m4a"

    static func removeFolderIfEmpty(_ folder: URL) {
        guard folder.standardizedFileURL != documentsDirectory.standardizedFileURL,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Recordings saved before session folders existed sit loose in
    /// Documents. Move each session into its own folder (once; afterwards
    /// nothing is left loose to move).
    private static func moveLooseParts() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        let loose = files.filter { $0.pathExtension == "json" }.compactMap { url -> Recording? in
            guard let data = try? Data(contentsOf: url),
                  let rec = try? decoder.decode(Recording.self, from: data),
                  !rec.audioFileName.contains("/"),
                  fm.fileExists(atPath: rec.audioURL.path) else { return nil }
            return rec
        }
        for group in RecordingFolder.group(loose) {
            guard let folder = makeSessionFolder(named: group.title) else { continue }
            let sessionID = UUID()
            for part in group.parts {
                var moved = part
                moved.sessionID = sessionID
                let isPart = part.partNumber != nil || part.parsedPart != nil
                moved.audioFileName = folder + "/"
                    + (isPart ? partFileName(RecordingFolder.number(of: part)) : singleFileName)
                guard (try? fm.moveItem(at: part.audioURL, to: moved.audioURL)) != nil else { continue }
                save(moved)
                try? fm.removeItem(at: part.metadataURL)
            }
            removeFolderIfEmpty(documentsDirectory.appendingPathComponent(folder))
        }
    }
}
