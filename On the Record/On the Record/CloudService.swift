import CloudKit
import Combine
import Foundation

/// A shared meeting several phones record at once.
struct MeetingInfo: Hashable, Identifiable {
    var code: String
    var title: String
    var createdAt: Date
    var id: String { code }
}

/// One phone's uploaded recording (one autosave part) for a meeting.
struct MeetingUpload: Identifiable, Hashable {
    var id: String              // CloudKit record name
    var deviceID: String
    var recorderName: String
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var isMine: Bool
}

/// A verbal agreement published to the public repository.
struct Agreement: Identifiable, Hashable, Codable {
    var id: String              // CloudKit record name
    var title: String
    var category: String
    var parties: [String]
    var terms: String
    var transcript: String?
    var authorName: String
    var authorID: String?
    var publishedAt: Date
    var meetingCode: String?
}

struct AgreementComment: Identifiable, Hashable, Codable {
    var id: String
    var text: String
    var authorName: String
    var authorID: String?
    var createdAt: Date
}

/// The public's judgment of an agreement.
enum Verdict: String, CaseIterable, Identifiable, Codable {
    case right, wrong, illegal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .right: "Right"
        case .wrong: "Wrong"
        case .illegal: "Illegal"
        }
    }
    var systemImage: String {
        switch self {
        case .right: "hand.thumbsup"
        case .wrong: "hand.thumbsdown"
        case .illegal: "exclamationmark.octagon"
        }
    }
}

struct VerdictTally: Hashable {
    var counts: [Verdict: Int] = [:]
    var mine: Verdict?
}

/// Everything that goes through iCloud: shared meetings (audio from each
/// phone) and the public repository of verbal agreements with comments,
/// verdicts, and reports. Uses the app's CloudKit public database.
@MainActor
final class CloudService: ObservableObject {
    static let shared = CloudService()

    enum CloudError: LocalizedError {
        case noAccount
        case meetingNotFound
        case notEnabled
        case notYours
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAccount: "Sign in to iCloud in Settings to use shared meetings and the agreement repository."
            case .notEnabled: "Shared meetings and the agreement repository use iCloud, which needs a paid Apple Developer account. Recording and transcribing work without it."
            case .notYours: "You can only delete agreements and comments you posted."
            case .meetingNotFound: "No meeting has that code. Check it with the person who started the meeting."
            case .failed(let message): message
            }
        }
    }

    /// Authors this person has hidden (App Review requires blocking).
    @Published private(set) var blockedAuthors: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "blockedAuthors") ?? [])

    /// iCloud needs a paid Apple Developer account. Turn it on by setting
    /// `CloudKitEnabled` to YES in Info.plist and adding the iCloud →
    /// CloudKit capability; until then these features report that they're
    /// off instead of crashing (CloudKit traps without the entitlement).
    static let isEnabled = Bundle.main.object(forInfoDictionaryKey: "CloudKitEnabled") as? Bool ?? false

    /// Agreements are saved on this phone (`LocalAgreements`) instead of
    /// iCloud — always while CloudKit is off, or when chosen in the
    /// Agreements tab for testing.
    static var isLocalTestMode: Bool {
        !isEnabled || UserDefaults.standard.bool(forKey: "agreementsTestMode")
    }

    private var database: CKDatabase {
        get throws {
            guard Self.isEnabled else { throw CloudError.notEnabled }
            return CKContainer.default().publicCloudDatabase
        }
    }
    private var cachedUserID: String?

    /// Identifies this phone's uploads within a meeting.
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }

    static var displayName: String {
        let name = UserDefaults.standard.string(forKey: "displayName")?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Anonymous" : name
    }

    func myUserID() async throws -> String {
        if let cachedUserID { return cachedUserID }
        guard Self.isEnabled else { throw CloudError.notEnabled }
        let status = try await CKContainer.default().accountStatus()
        guard status == .available else { throw CloudError.noAccount }
        let id = try await CKContainer.default().userRecordID().recordName
        cachedUserID = id
        return id
    }

    // MARK: - Meetings

    private static let codeLetters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Starts a meeting and returns its join code.
    func createMeeting(title: String) async throws -> MeetingInfo {
        _ = try await myUserID()
        let code = String((0..<6).map { _ in Self.codeLetters.randomElement()! })
        let record = CKRecord(recordType: "Meeting", recordID: Self.meetingID(code))
        record["code"] = code
        record["title"] = title
        record["createdAt"] = Date()
        try await perform { _ = try await self.database.save(record) }
        return MeetingInfo(code: code, title: title, createdAt: Date())
    }

    /// Looks up a meeting by its code (any capitalization).
    func meeting(code rawCode: String) async throws -> MeetingInfo {
        let code = rawCode.uppercased().filter { $0.isLetter || $0.isNumber }
        do {
            let record = try await database.record(for: Self.meetingID(code))
            return MeetingInfo(code: code,
                               title: record["title"] as? String ?? "Meeting",
                               createdAt: record["createdAt"] as? Date ?? record.creationDate ?? Date())
        } catch let error as CKError where error.code == .unknownItem {
            throw CloudError.meetingNotFound
        } catch {
            throw Self.wrap(error)
        }
    }

    private static func meetingID(_ code: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "meeting-\(code)")
    }

    /// Uploads a saved part to its meeting. Failures are left for
    /// `uploadPending()` to retry.
    func uploadToMeeting(_ recording: Recording) async {
        guard let code = recording.meetingCode, recording.uploadedRecordName == nil else { return }
        let record = CKRecord(recordType: "MeetingAudio")
        record["meetingCode"] = code
        record["deviceID"] = Self.deviceID
        record["recorderName"] = Self.displayName
        record["title"] = recording.title
        record["startedAt"] = recording.startedAt ?? recording.createdAt.addingTimeInterval(-recording.duration)
        record["duration"] = recording.duration
        record["audio"] = CKAsset(fileURL: recording.audioURL)
        guard (try? await database.save(record)) != nil else { return }
        // Re-read in case the recording changed (e.g. transcribed) meanwhile.
        var latest = Store.loadAll().first { $0.id == recording.id } ?? recording
        latest.uploadedRecordName = record.recordID.recordName
        Store.save(latest)
    }

    /// Retries uploads that failed (no signal, not signed in, etc.).
    func uploadPending() async {
        for recording in Store.loadAll() where recording.meetingCode != nil && recording.uploadedRecordName == nil {
            await uploadToMeeting(recording)
        }
    }

    func uploads(meetingCode code: String) async throws -> [MeetingUpload] {
        let query = CKQuery(recordType: "MeetingAudio",
                            predicate: NSPredicate(format: "meetingCode == %@", code))
        let records = try await fetch(query, desiredKeys: ["deviceID", "recorderName", "title", "startedAt", "duration"])
        return records.map { record in
            let device = record["deviceID"] as? String ?? ""
            return MeetingUpload(
                id: record.recordID.recordName,
                deviceID: device,
                recorderName: record["recorderName"] as? String ?? "Phone",
                title: record["title"] as? String ?? "",
                startedAt: record["startedAt"] as? Date ?? record.creationDate ?? Date(),
                duration: record["duration"] as? Double ?? 0,
                isMine: device == Self.deviceID)
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    /// Downloads an upload's audio into Caches and returns the file.
    func downloadAudio(_ upload: MeetingUpload) async throws -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(upload.id).appendingPathExtension("m4a")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let record: CKRecord
        do {
            record = try await database.record(for: CKRecord.ID(recordName: upload.id))
        } catch {
            throw Self.wrap(error)
        }
        guard let asset = record["audio"] as? CKAsset, let source = asset.fileURL else {
            throw CloudError.failed("That recording’s audio is no longer in the meeting.")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Deletes this phone's audio from a meeting (each phone can remove only
    /// its own uploads).
    func removeMyAudio(meetingCode code: String) async throws {
        let mine = try await uploads(meetingCode: code).filter(\.isMine)
        let ids = mine.map { CKRecord.ID(recordName: $0.id) }
        guard !ids.isEmpty else { return }
        try await perform {
            _ = try await self.database.modifyRecords(saving: [], deleting: ids)
        }
    }

    // MARK: - Agreements

    func publish(title: String, category: String, parties: [String], terms: String,
                 transcript: String?, meetingCode: String?) async throws -> Agreement {
        if Self.isLocalTestMode {
            return try LocalAgreements.publish(title: title, category: category, parties: parties, terms: terms,
                                               transcript: transcript, meetingCode: meetingCode,
                                               authorName: Self.displayName)
        }
        _ = try await myUserID()
        let record = CKRecord(recordType: "Agreement")
        record["title"] = title
        record["category"] = category
        record["parties"] = parties
        record["terms"] = terms
        record["transcript"] = transcript
        record["authorName"] = Self.displayName
        record["publishedAt"] = Date()
        record["meetingCode"] = meetingCode
        try await perform { _ = try await self.database.save(record) }
        return agreement(from: record)
    }

    /// Newest published agreements, without hidden authors.
    func agreements() async throws -> [Agreement] {
        if Self.isLocalTestMode {
            return LocalAgreements.agreements().filter { !isBlocked($0.authorID) }
        }
        let query = CKQuery(recordType: "Agreement", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "publishedAt", ascending: false)]
        return try await fetch(query, limit: 200)
            .map(agreement(from:))
            .filter { !isBlocked($0.authorID) }
    }

    private func agreement(from record: CKRecord) -> Agreement {
        Agreement(
            id: record.recordID.recordName,
            title: record["title"] as? String ?? "Untitled agreement",
            category: record["category"] as? String ?? "Other",
            parties: record["parties"] as? [String] ?? [],
            terms: record["terms"] as? String ?? "",
            transcript: record["transcript"] as? String,
            authorName: record["authorName"] as? String ?? "Anonymous",
            authorID: record.creatorUserRecordID?.recordName,
            publishedAt: record["publishedAt"] as? Date ?? record.creationDate ?? Date(),
            meetingCode: record["meetingCode"] as? String)
    }

    func comments(on agreement: Agreement) async throws -> [AgreementComment] {
        if Self.isLocalTestMode {
            return LocalAgreements.comments(on: agreement).filter { !isBlocked($0.authorID) }
        }
        let query = CKQuery(recordType: "Comment",
                            predicate: NSPredicate(format: "agreement == %@", Self.reference(agreement)))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return try await fetch(query, limit: 300)
            .map { record in
                AgreementComment(
                    id: record.recordID.recordName,
                    text: record["text"] as? String ?? "",
                    authorName: record["authorName"] as? String ?? "Anonymous",
                    authorID: record.creatorUserRecordID?.recordName,
                    createdAt: record["createdAt"] as? Date ?? record.creationDate ?? Date())
            }
            .filter { !isBlocked($0.authorID) }
    }

    func addComment(_ text: String, on agreement: Agreement) async throws {
        if Self.isLocalTestMode {
            return try LocalAgreements.addComment(text, authorName: Self.displayName, on: agreement)
        }
        _ = try await myUserID()
        let record = CKRecord(recordType: "Comment")
        record["agreement"] = Self.reference(agreement)
        record["text"] = text
        record["authorName"] = Self.displayName
        record["createdAt"] = Date()
        try await perform { _ = try await self.database.save(record) }
    }

    func verdicts(on agreement: Agreement) async throws -> VerdictTally {
        if Self.isLocalTestMode { return LocalAgreements.verdicts(on: agreement) }
        let me = try? await myUserID()
        let query = CKQuery(recordType: "Verdict",
                            predicate: NSPredicate(format: "agreement == %@", Self.reference(agreement)))
        var tally = VerdictTally()
        for record in try await fetch(query, limit: 400) {
            guard let raw = record["verdict"] as? String, let verdict = Verdict(rawValue: raw) else { continue }
            tally.counts[verdict, default: 0] += 1
            if let me, record.creatorUserRecordID?.recordName == me { tally.mine = verdict }
        }
        return tally
    }

    /// One verdict per person per agreement; voting again replaces it.
    func setVerdict(_ verdict: Verdict, on agreement: Agreement) async throws {
        if Self.isLocalTestMode { return try LocalAgreements.setVerdict(verdict, on: agreement) }
        let me = try await myUserID()
        let record = CKRecord(recordType: "Verdict",
                              recordID: CKRecord.ID(recordName: "verdict-\(agreement.id)-\(me)"))
        record["agreement"] = Self.reference(agreement)
        record["verdict"] = verdict.rawValue
        try await perform {
            _ = try await self.database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        }
    }

    /// True if this person posted it, so they may delete it. CloudKit
    /// reports the current user's own records as created by
    /// `CKCurrentUserDefaultName` rather than their real ID, so both count.
    func isMine(_ authorID: String?) -> Bool {
        guard let authorID else { return false }
        if Self.isLocalTestMode { return authorID == LocalAgreements.authorID }
        return authorID == CKCurrentUserDefaultName || authorID == cachedUserID
    }

    /// Deletes the person's own agreement. In iCloud, comments, verdicts,
    /// and reports on it go too (their references are `.deleteSelf`).
    func deleteAgreement(_ agreement: Agreement) async throws {
        guard isMine(agreement.authorID) else { throw CloudError.notYours }
        if Self.isLocalTestMode { return try LocalAgreements.deleteAgreement(agreement) }
        try await perform {
            _ = try await self.database.deleteRecord(withID: CKRecord.ID(recordName: agreement.id))
        }
    }

    /// Deletes the person's own comment.
    func deleteComment(_ comment: AgreementComment, on agreement: Agreement) async throws {
        guard isMine(comment.authorID) else { throw CloudError.notYours }
        if Self.isLocalTestMode { return try LocalAgreements.deleteComment(comment, on: agreement) }
        try await perform {
            _ = try await self.database.deleteRecord(withID: CKRecord.ID(recordName: comment.id))
        }
    }

    /// Flags an agreement or comment for review.
    func report(agreement: Agreement, comment: AgreementComment? = nil, reason: String) async throws {
        if Self.isLocalTestMode {
            return try LocalAgreements.report(agreement: agreement, comment: comment, reason: reason)
        }
        _ = try await myUserID()
        let record = CKRecord(recordType: "Report")
        record["agreement"] = Self.reference(agreement)
        record["commentID"] = comment?.id
        record["reason"] = reason
        record["createdAt"] = Date()
        try await perform { _ = try await self.database.save(record) }
    }

    func block(authorID: String?) {
        guard let authorID else { return }
        blockedAuthors.insert(authorID)
        UserDefaults.standard.set(Array(blockedAuthors), forKey: "blockedAuthors")
    }

    private func isBlocked(_ authorID: String?) -> Bool {
        authorID.map(blockedAuthors.contains) ?? false
    }

    private static func reference(_ agreement: Agreement) -> CKRecord.Reference {
        CKRecord.Reference(recordID: CKRecord.ID(recordName: agreement.id), action: .deleteSelf)
    }

    // MARK: - Helpers

    private func fetch(_ query: CKQuery, desiredKeys: [CKRecord.FieldKey]? = nil, limit: Int = 400) async throws -> [CKRecord] {
        do {
            let (results, _) = try await database.records(
                matching: query, desiredKeys: desiredKeys, resultsLimit: limit)
            return results.compactMap { try? $0.1.get() }
        } catch {
            throw Self.wrap(error)
        }
    }

    private func perform(_ work: () async throws -> Void) async throws {
        do { try await work() } catch { throw Self.wrap(error) }
    }

    private static func wrap(_ error: Error) -> Error {
        if error is CloudError { return error }
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated: return CloudError.noAccount
            case .networkUnavailable, .networkFailure:
                return CloudError.failed("No internet connection. Try again when you’re online.")
            default: break
            }
        }
        return CloudError.failed(error.localizedDescription)
    }
}
