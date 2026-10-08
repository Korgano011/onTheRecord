import Foundation

/// Local test mode for the agreement repository: the same publish, comment,
/// verdict, and report flow as CloudKit, saved to a JSON file on this phone
/// instead. Always used while CloudKit is off, so the Agreements tab can be
/// tried end to end before iCloud is set up.
@MainActor
enum LocalAgreements {
    struct Report: Codable {
        var agreementID: String
        var commentID: String?
        var reason: String
        var createdAt: Date
    }

    private struct Contents: Codable {
        var agreements: [Agreement] = []
        var comments: [String: [AgreementComment]] = [:]   // by agreement id
        var verdicts: [String: Verdict] = [:]              // this phone's, by agreement id
        var reports: [Report] = []
    }

    /// Stands in for the iCloud user ID, so hiding an author works locally too.
    static var authorID: String { "local-\(CloudService.deviceID)" }

    private static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("AgreementsTest.json")
    }

    private static func load() -> Contents {
        guard let data = try? Data(contentsOf: fileURL),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return Contents() }
        return contents
    }

    private static func update(_ change: (inout Contents) -> Void) throws {
        var contents = load()
        change(&contents)
        try JSONEncoder().encode(contents).write(to: fileURL, options: .atomic)
    }

    static func publish(title: String, category: String, parties: [String], terms: String,
                        transcript: String?, meetingCode: String?, authorName: String) throws -> Agreement {
        let agreement = Agreement(
            id: "local-\(UUID().uuidString)",
            title: title, category: category, parties: parties, terms: terms,
            transcript: transcript, authorName: authorName, authorID: authorID,
            publishedAt: Date(), meetingCode: meetingCode)
        try update { $0.agreements.append(agreement) }
        return agreement
    }

    static func agreements() -> [Agreement] {
        load().agreements.sorted { $0.publishedAt > $1.publishedAt }
    }

    static func comments(on agreement: Agreement) -> [AgreementComment] {
        load().comments[agreement.id] ?? []
    }

    static func addComment(_ text: String, authorName: String, on agreement: Agreement) throws {
        let comment = AgreementComment(id: UUID().uuidString, text: text, authorName: authorName,
                                       authorID: authorID, createdAt: Date())
        try update { $0.comments[agreement.id, default: []].append(comment) }
    }

    /// Only this phone votes locally, so a tally is at most one.
    static func verdicts(on agreement: Agreement) -> VerdictTally {
        var tally = VerdictTally()
        if let mine = load().verdicts[agreement.id] {
            tally.counts[mine] = 1
            tally.mine = mine
        }
        return tally
    }

    static func setVerdict(_ verdict: Verdict, on agreement: Agreement) throws {
        try update { $0.verdicts[agreement.id] = verdict }
    }

    static func report(agreement: Agreement, comment: AgreementComment?, reason: String) throws {
        try update {
            $0.reports.append(Report(agreementID: agreement.id, commentID: comment?.id,
                                     reason: reason, createdAt: Date()))
        }
    }

    /// Removes an agreement with its comments, verdict, and reports.
    static func deleteAgreement(_ agreement: Agreement) throws {
        try update {
            $0.agreements.removeAll { $0.id == agreement.id }
            $0.comments[agreement.id] = nil
            $0.verdicts[agreement.id] = nil
            $0.reports.removeAll { $0.agreementID == agreement.id }
        }
    }

    static func deleteComment(_ comment: AgreementComment, on agreement: Agreement) throws {
        try update {
            $0.comments[agreement.id]?.removeAll { $0.id == comment.id }
            $0.reports.removeAll { $0.commentID == comment.id }
        }
    }

    static var reportCount: Int { load().reports.count }

    /// Deletes all test agreements, comments, verdicts, and reports.
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
