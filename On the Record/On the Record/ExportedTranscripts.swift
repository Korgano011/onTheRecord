import Darwin
import SwiftUI

/// A transcript exported for review: a plain .txt file in
/// Documents/Exported Transcripts, so it can also be opened in the Files app.
struct ExportedTranscript: Identifiable, Hashable {
    let url: URL
    let modified: Date
    /// Shared meeting the transcript came from, if any; passed on when it's
    /// published so the agreement links back to the meeting.
    var meetingCode: String?
    /// When it was last published as an agreement; nil if not yet.
    var publishedAt: Date?

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }

    /// Changed after it was last published (the published agreement keeps
    /// the earlier text). Allows a moment for the save just before publishing.
    var editedSincePublished: Bool {
        guard let publishedAt else { return false }
        return modified > publishedAt.addingTimeInterval(2)
    }
}

/// Green "Published" or orange "Edited since publishing" tag.
struct PublishedBadge: View {
    let transcript: ExportedTranscript

    var body: some View {
        if let date = transcript.publishedAt {
            if transcript.editedSincePublished {
                Label("Edited since publishing \(date.formatted(date: .abbreviated, time: .omitted))",
                      systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Published \(date.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

/// Saves, lists, edits and deletes exported transcripts.
enum TranscriptExports {
    static let folderName = "Exported Transcripts"

    static var folder: URL {
        let url = Store.documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Saves the text as a new file (never overwriting an earlier export,
    /// which may have been edited). Returns the file's name.
    @discardableResult
    static func export(_ text: String, title: String, meetingCode: String? = nil) throws -> String {
        let base = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = base.isEmpty ? "Transcript" : base
        var name = safeBase
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".txt").path) {
            name = "\(safeBase) (\(n))"
            n += 1
        }
        let url = folder.appendingPathComponent(name + ".txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        setAttribute(meetingCodeAttribute, meetingCode, on: url)
        return name
    }

    /// Exports and returns the new file, ready to open in the editor.
    static func exportForReview(_ text: String, title: String, meetingCode: String? = nil) throws -> ExportedTranscript {
        let name = try export(text, title: title, meetingCode: meetingCode)
        return ExportedTranscript(url: folder.appendingPathComponent(name + ".txt"), modified: Date(),
                                  meetingCode: meetingCode)
    }

    // MARK: Parties line

    private static let partiesPrefix = "Parties: "

    /// Names in a "Parties: A, B" first line, if the text has one.
    static func parties(in text: String) -> [String] {
        guard let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              first.hasPrefix(partiesPrefix) else { return [] }
        return first.dropFirst(partiesPrefix.count)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The text headed by a "Parties:" line naming everyone, replacing any
    /// existing one rather than adding a second.
    static func withParties(_ names: [String], _ text: String) -> String {
        var body = text
        if !parties(in: text).isEmpty || text.hasPrefix(partiesPrefix) {
            body = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .dropFirst().joined()
            while body.hasPrefix("\n") { body.removeFirst() }
        }
        guard !names.isEmpty else { return body }
        return partiesPrefix + names.joined(separator: ", ") + "\n\n" + body
    }

    /// After publishing: write the parties into the file, then mark it
    /// published (after the write, so it doesn't count as edited since).
    /// Returns the file's new text.
    @discardableResult
    static func recordPublished(_ transcript: ExportedTranscript, parties: [String]) -> String {
        let text = withParties(parties, read(transcript))
        save(text, to: transcript)
        markPublished(transcript)
        return text
    }

    /// Records that the transcript was published, keeping the date with the file.
    static func markPublished(_ transcript: ExportedTranscript, at date: Date = Date()) {
        setAttribute(publishedAttribute, date.ISO8601Format(), on: transcript.url)
    }

    static func publishedAt(_ transcript: ExportedTranscript) -> Date? {
        attribute(publishedAttribute, of: transcript.url).flatMap { try? Date($0, strategy: .iso8601) }
    }

    // The meeting code and published date are kept as hidden extended
    // attributes on the file, so the text stays clean to edit and they
    // follow the file if it's renamed or moved in the Files app.
    private static let meetingCodeAttribute = "com.ontherecord.meetingCode"
    private static let publishedAttribute = "com.ontherecord.publishedAt"
    private static let attributes = [meetingCodeAttribute, publishedAttribute]

    private static func setAttribute(_ name: String, _ value: String?, on url: URL) {
        guard let value, let data = value.data(using: .utf8) else { return }
        _ = data.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
    }

    private static func attribute(_ name: String, of url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? String(data: data, encoding: .utf8) : nil
    }

    static func loadAll() -> [ExportedTranscript] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.pathExtension == "txt" }
            .map { url in
                ExportedTranscript(
                    url: url,
                    modified: (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast,
                    meetingCode: attribute(meetingCodeAttribute, of: url),
                    publishedAt: attribute(publishedAttribute, of: url).flatMap { try? Date($0, strategy: .iso8601) })
            }
            .sorted { $0.modified > $1.modified }
    }

    static func read(_ transcript: ExportedTranscript) -> String {
        (try? String(contentsOf: transcript.url, encoding: .utf8)) ?? ""
    }

    static func save(_ text: String, to transcript: ExportedTranscript) {
        // Unchanged: don't touch the file, so its edited date stays true.
        guard text != read(transcript) else { return }
        // An atomic write replaces the file, dropping its attributes, so
        // read them first and put them back.
        let kept = attributes.map { ($0, attribute($0, of: transcript.url)) }
        try? text.write(to: transcript.url, atomically: true, encoding: .utf8)
        for (name, value) in kept { setAttribute(name, value, on: transcript.url) }
    }

    static func delete(_ transcript: ExportedTranscript) {
        try? FileManager.default.removeItem(at: transcript.url)
    }
}

/// Export button: saves the transcript to Exported Transcripts and says so.
struct ExportTranscriptButton: View {
    let text: String
    let title: String
    var meetingCode: String?
    var label = "Export Transcript"

    @State private var savedAs: String?
    @State private var error: String?

    var body: some View {
        Button {
            do {
                savedAs = try TranscriptExports.export(text, title: title, meetingCode: meetingCode)
            } catch {
                self.error = error.localizedDescription
            }
        } label: {
            Label(label, systemImage: "doc.text")
        }
        .alert("Exported for Review", isPresented: Binding(get: { savedAs != nil }, set: { if !$0 { savedAs = nil } })) {
            Button("OK") { savedAs = nil }
        } message: {
            Text("Saved as “\(savedAs ?? "")” in Exported Transcripts. Review and edit it in the Exported tab, then publish it from there.")
        }
        .alert("Couldn’t Export", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

/// The Exported tab: transcripts waiting to be reviewed, edited, and published.
struct ExportedTranscriptsView: View {
    @State private var transcripts: [ExportedTranscript] = []
    /// Transcript being published straight from the list.
    @State private var publishing: ExportedTranscript?
    /// Just published from the list; offer to open it for editing.
    @State private var justPublished: ExportedTranscript?
    @State private var pendingPublished: ExportedTranscript?
    @State private var path: [ExportedTranscript] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if transcripts.isEmpty {
                    ContentUnavailableView {
                        Label("No Exported Transcripts", systemImage: "doc.text")
                    } description: {
                        Text("Tap Export on a recording’s transcript. It’s saved here so you can review and edit it before publishing.")
                    }
                } else {
                    List {
                        ForEach(transcripts) { transcript in
                            NavigationLink(value: transcript) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(transcript.title).font(.headline).lineLimit(1)
                                    Text("Edited \(transcript.modified.formatted(.dateTime.month().day().hour().minute()))"
                                         + (transcript.meetingCode.map { " · Meeting \($0)" } ?? ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    PublishedBadge(transcript: transcript)
                                        .font(.caption.bold())
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button(transcript.publishedAt == nil ? "Publish" : "Publish Again",
                                       systemImage: "signature") { publishing = transcript }
                                    .tint(.accentColor)
                            }
                            .contextMenu {
                                Button(transcript.publishedAt == nil ? "Publish…" : "Publish Again…",
                                       systemImage: "signature") { publishing = transcript }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { transcripts[$0] }.forEach { TranscriptExports.delete($0) }
                            reload()
                        }
                    }
                }
            }
            .navigationTitle("Exported")
            .navigationDestination(for: ExportedTranscript.self) { transcript in
                ExportedTranscriptEditor(transcript: transcript)
            }
            .sheet(item: $publishing, onDismiss: {
                // Ask once the form has closed, so the two don't collide.
                justPublished = pendingPublished
                pendingPublished = nil
            }) { transcript in
                AgreementComposerView(defaultTitle: transcript.title,
                                      transcript: TranscriptExports.read(transcript),
                                      meetingCode: transcript.meetingCode) { parties in
                    TranscriptExports.recordPublished(transcript, parties: parties)
                    pendingPublished = transcript
                    reload()
                }
            }
            .alert("Published", isPresented: Binding(get: { justPublished != nil },
                                                     set: { if !$0 { justPublished = nil } })) {
                Button("Edit File") {
                    if let transcript = justPublished { path = [transcript] }
                    justPublished = nil
                }
                Button("Done", role: .cancel) { justPublished = nil }
            } message: {
                Text("The names of the parties were added to the top of “\(justPublished?.title ?? "")”. You can edit the file if anything needs changing.")
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        transcripts = TranscriptExports.loadAll()
    }
}

/// Review and edit one exported transcript, then publish it.
struct ExportedTranscriptEditor: View {
    let transcript: ExportedTranscript
    /// Current published state (the file may be published while open).
    @State private var current: ExportedTranscript?

    @State private var text = ""
    @State private var loaded = false
    @State private var showComposer = false
    @FocusState private var editing: Bool

    var body: some View {
        TextEditor(text: $text)
            .focused($editing)
            .padding(.horizontal, 8)
            .navigationTitle(transcript.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // In the top bar: a bottom toolbar is hidden behind the tab bar.
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = false
                        save()
                        showComposer = true
                    } label: {
                        Text(shown.publishedAt == nil ? "Publish" : "Publish Again")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 4) {
                    PublishedBadge(transcript: shown)
                        .font(.caption.bold())
                    Text((shown.publishedAt == nil
                          ? "Review and correct the transcript, then tap Publish. Changes save automatically."
                          : "Edits here don’t change the published agreement. Publish again to post the new version.")
                         + (transcript.meetingCode.map { "\nFrom shared meeting \($0)." } ?? ""))
                }
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .onAppear {
                // Re-read each time, in case it was edited in the Files app.
                text = TranscriptExports.read(transcript)
                loaded = true
                refresh()
            }
            .onChange(of: text) {
                guard loaded else { return }
                save()
                // Only a published transcript's badge depends on edits.
                if shown.publishedAt != nil && !shown.editedSincePublished { refresh() }
            }
            .onDisappear(perform: save)
            .sheet(isPresented: $showComposer) {
                AgreementComposerView(defaultTitle: transcript.title, transcript: text,
                                      meetingCode: transcript.meetingCode) { parties in
                    // Show the names in the editor straight away; the file
                    // already has them, so this doesn't save again.
                    text = TranscriptExports.recordPublished(transcript, parties: parties)
                    refresh()
                }
            }
    }

    private var shown: ExportedTranscript { current ?? transcript }

    /// Re-reads the file's edited and published dates.
    private func refresh() {
        current = TranscriptExports.loadAll().first { $0.url == transcript.url }
    }

    private func save() {
        guard loaded else { return }
        TranscriptExports.save(text, to: transcript)
    }
}
