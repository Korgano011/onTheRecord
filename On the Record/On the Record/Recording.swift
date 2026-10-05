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
    /// File name only (not a full path) so the record survives the app
    /// container moving between launches / devices.
    var audioFileName: String
    var transcript: String?
    /// Names of everyone who agreed to be recorded (nil for older recordings).
    var consentedBy: [String]?
    /// When the phone was locked during recording (nil for older recordings).
    var lockedSpans: [TimeSpan]?
    /// The transcript split by phone state. Set when lockedSpans is non-empty.
    var unlockedTranscript: String?
    var lockedTranscript: String?

    init(id: UUID = UUID(),
         title: String,
         createdAt: Date = Date(),
         duration: TimeInterval = 0,
         audioFileName: String,
         transcript: String? = nil,
         consentedBy: [String]? = nil,
         lockedSpans: [TimeSpan]? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.transcript = transcript
        self.consentedBy = consentedBy
        self.lockedSpans = lockedSpans
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
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Reads and writes `Recording` metadata to Documents.
enum Store {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func loadAll() -> [Recording] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: nil) else { return [] }

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
    }
}
