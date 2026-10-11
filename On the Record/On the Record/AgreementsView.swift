import SwiftUI

/// The public repository of verbal agreements: anyone can read them,
/// comment, and judge whether each one is right, wrong, or illegal, so
/// over time it becomes a shared body of knowledge about verbal contracts.
struct AgreementsView: View {
    @ObservedObject private var cloud = CloudService.shared
    @State private var agreements: [Agreement] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var showComposer = false
    @State private var confirmClear = false
    @State private var showAbout = false
    /// Own agreement waiting for delete confirmation.
    @State private var deleting: Agreement?
    @AppStorage("agreementsTestMode") private var testMode = false
    /// Public repository, or everything this person published or was shared.
    @AppStorage("agreementsScope") private var scope: AgreementScope = .everyone

    /// Saving on this phone instead of iCloud (see `LocalAgreements`).
    private var inTestMode: Bool { !CloudService.isEnabled || testMode }

    var body: some View {
        NavigationStack {
            Group {
                if agreements.isEmpty && !loading {
                    ContentUnavailableView {
                        Label(scope == .mine ? "Nothing Here Yet" : "No Agreements Yet", systemImage: "signature")
                    } description: {
                        Text(error ?? emptyMessage)
                    } actions: {
                        Button("Refresh") { Task { await load() } }
                    }
                } else {
                    List {
                        if scope == .mine {
                            ForEach(AgreementGroup.allCases) { group in
                                let items = filtered.filter { group.contains($0) }
                                if !items.isEmpty {
                                    Section(group.title) { ForEach(items) { row($0) } }
                                }
                            }
                        } else {
                            ForEach(filtered) { row($0) }
                        }
                    }
                    .searchable(text: $search, prompt: "Search agreements")
                }
            }
            .overlay { if loading && agreements.isEmpty { ProgressView() } }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if inTestMode {
                        Label("Test mode — saved on this iPhone only", systemImage: "testtube.2")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.orange.opacity(0.2))
                    }
                    Picker("Show", selection: $scope) {
                        ForEach(AgreementScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
            .navigationTitle("Agreements")
            .navigationDestination(for: Agreement.self) { agreement in
                AgreementDetailView(agreement: agreement) {
                    agreements.removeAll { $0.id == agreement.id }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Local Test Mode", isOn: Binding(get: { inTestMode }, set: { testMode = $0 }))
                            .disabled(!CloudService.isEnabled)
                        Button("Clear Test Data", systemImage: "trash", role: .destructive) { confirmClear = true }
                    } label: {
                        Image(systemName: "testtube.2")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showComposer = true
                    } label: {
                        Label("New Agreement", systemImage: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAbout = true
                    } label: {
                        Label("About the Repository", systemImage: "info.circle")
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: cloud.blockedAuthors) { Task { await load() } }
            .onChange(of: testMode) { Task { await load() } }
            .onChange(of: scope) { Task { await load() } }
            .onChange(of: cloud.acceptedShares) {
                // Just joined a shared agreement: show it.
                if scope == .mine { Task { await load() } } else { scope = .mine }
            }
            .alert("Sharing Problem", isPresented: Binding(get: { cloud.shareError != nil },
                                                           set: { if !$0 { cloud.shareError = nil } })) {
                Button("OK") { cloud.shareError = nil }
            } message: {
                Text(cloud.shareError ?? "")
            }
            .confirmationDialog("Delete all test agreements, comments, verdicts, and reports on this iPhone?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Test Data", role: .destructive) {
                    LocalAgreements.clear()
                    Task { await load() }
                }
            }
            .confirmationDialog("Delete “\(deleting?.title ?? "")”?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Agreement", role: .destructive) {
                    if let agreement = deleting { Task { await delete(agreement) } }
                }
            } message: {
                Text(deleting.map(AgreementDetailView.deleteMessage) ?? "")
            }
            .sheet(isPresented: $showAbout) { RepositoryInfoView() }
            .sheet(isPresented: $showComposer, onDismiss: { Task { await load() } }) {
                AgreementComposerView(defaultTitle: "", transcript: nil, meetingCode: nil)
            }
        }
    }

    private func row(_ agreement: Agreement) -> some View {
        NavigationLink(value: agreement) {
            AgreementRow(agreement: agreement)
        }
        .swipeActions {
            if agreement.isSharedWithMe {
                Button("Leave", systemImage: "person.badge.minus", role: .destructive) {
                    Task { await leave(agreement) }
                }
            } else if cloud.isMine(agreement.authorID) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    deleting = agreement
                }
            }
        }
    }

    private var emptyMessage: String {
        switch scope {
        case .mine:
            "Agreements you publish, keep privately, or share — and ones others share with you — appear here."
        case .everyone:
            inTestMode
                ? "Test mode: publish an agreement with the ✎ button. It's saved on this iPhone only."
                : "Record a conversation where people agree, then publish it here as a verbal agreement anyone can read and judge."
        }
    }

    private func leave(_ agreement: Agreement) async {
        do {
            try await CloudService.shared.leave(agreement)
            agreements.removeAll { $0.id == agreement.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var filtered: [Agreement] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return agreements }
        return agreements.filter {
            $0.title.localizedCaseInsensitiveContains(term)
                || $0.terms.localizedCaseInsensitiveContains(term)
                || $0.category.localizedCaseInsensitiveContains(term)
                || $0.parties.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    private func delete(_ agreement: Agreement) async {
        deleting = nil
        do {
            try await CloudService.shared.deleteAgreement(agreement)
            agreements.removeAll { $0.id == agreement.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // Learn who this is, so their own posts show Delete.
            if !CloudService.isLocalTestMode { _ = try? await CloudService.shared.myUserID() }
            agreements = scope == .mine
                ? try await CloudService.shared.myAgreements()
                : try await CloudService.shared.agreements()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum AgreementScope: String, CaseIterable, Identifiable {
    case everyone, mine
    var id: String { rawValue }
    var title: String { self == .everyone ? "Public" : "Mine" }
}

/// Sections of the Mine list.
enum AgreementGroup: String, CaseIterable, Identifiable {
    case published, kept, sharedByMe, sharedWithMe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .published: "Public"
        case .kept: "Private"
        case .sharedByMe: "Shared by Me"
        case .sharedWithMe: "Shared with Me"
        }
    }
    func contains(_ agreement: Agreement) -> Bool {
        switch self {
        case .published: agreement.access == .everyone
        case .kept: agreement.access == .onlyMe
        case .sharedByMe: agreement.access == .parties && !agreement.isSharedWithMe
        case .sharedWithMe: agreement.isSharedWithMe
        }
    }
}

struct AgreementRow: View {
    let agreement: Agreement

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(agreement.title).font(.headline).lineLimit(1)
                Spacer()
                Text(agreement.category)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            Text(agreement.parties.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(agreement.publishedAt, format: .dateTime.month().day().year())
                if agreement.access != .everyone {
                    Label(agreement.isSharedWithMe ? "Shared with you" : agreement.access.title,
                          systemImage: agreement.access.systemImage)
                }
                if agreement.hasTranscript {
                    Label("Transcript", systemImage: "text.bubble")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct AgreementDetailView: View {
    let agreement: Agreement
    /// Called after the person deletes their own agreement.
    var onDeleted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @AppStorage("acceptedCommunityRules") private var acceptedRules = false
    @AppStorage("displayName") private var displayName = ""
    @State private var comments: [AgreementComment] = []
    @State private var tally = VerdictTally()
    @State private var newComment = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showTranscript = false
    @State private var reporting: AgreementComment?
    @State private var reportingAgreement = false
    @State private var showRules = false
    @State private var notice: String?
    @State private var confirmDelete = false
    @State private var deletingComment: AgreementComment?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(agreement.title).font(.title3.bold())
                    Text("\(agreement.category) · published \(agreement.publishedAt.formatted(date: .abbreviated, time: .omitted)) by \(agreement.authorName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if agreement.access != .everyone {
                        Label(visibilityNote, systemImage: agreement.access.systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if agreement.access == .parties && !agreement.isSharedWithMe {
                    Button("Invite Parties / Manage Sharing", systemImage: "person.crop.circle.badge.plus") {
                        Task { await invite() }
                    }
                    .disabled(!CloudSharing.isAvailable)
                }
                LabeledContent("Parties", value: agreement.parties.joined(separator: ", "))
            }

            Section("Terms") {
                Text(agreement.terms).textSelection(.enabled)
            }

            if let transcript = agreement.transcript, !transcript.isEmpty {
                Section {
                    DisclosureGroup("Recorded conversation", isExpanded: $showTranscript) {
                        Text(transcript)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }

            // Verdicts and comments are for the public repository only.
            if agreement.access == .everyone {
            Section {
                HStack {
                    ForEach(Verdict.allCases) { verdict in
                        Button {
                            Task { await vote(verdict) }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: tally.mine == verdict ? verdict.systemImage + ".fill" : verdict.systemImage)
                                    .font(.title3)
                                Text(verdict.title).font(.caption)
                                Text("\(tally.counts[verdict] ?? 0)")
                                    .font(.caption.monospacedDigit().bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(tally.mine == verdict ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Your verdict")
            } footer: {
                Text("Is this agreement right, wrong, or illegal? Anyone — including lawyers — can weigh in. Verdicts are opinions, not legal rulings.")
            }

            Section("Comments") {
                if comments.isEmpty {
                    Text("No comments yet.").foregroundStyle(.secondary)
                }
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(comment.text)
                        Text("\(comment.authorName) · \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        if CloudService.shared.isMine(comment.authorID) {
                            Button("Delete", systemImage: "trash", role: .destructive) { deletingComment = comment }
                        }
                    }
                    .contextMenu {
                        if CloudService.shared.isMine(comment.authorID) {
                            Button("Delete Comment", systemImage: "trash", role: .destructive) { deletingComment = comment }
                        }
                        Button("Report Comment", systemImage: "flag") { reporting = comment }
                        Button("Hide Everything from \(comment.authorName)", systemImage: "person.slash") {
                            CloudService.shared.block(authorID: comment.authorID)
                            comments.removeAll { $0.authorID == comment.authorID && comment.authorID != nil }
                        }
                    }
                }
                VStack(alignment: .leading) {
                    if displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                        TextField("Your name", text: $displayName)
                    }
                    TextField("Add a comment", text: $newComment, axis: .vertical)
                        .lineLimit(1...5)
                    Button("Post Comment") { Task { await postComment() } }
                        .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }
            }

            if let notice {
                Section { Text(notice).foregroundStyle(.secondary) }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Agreement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
                    if agreement.isSharedWithMe {
                        Button("Leave Shared Agreement", systemImage: "person.badge.minus", role: .destructive) {
                            Task { await leave() }
                        }
                    } else if CloudService.shared.isMine(agreement.authorID) {
                        Button("Delete Agreement", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } else {
                        Button("Report Agreement", systemImage: "flag") { reportingAgreement = true }
                        Button("Hide Everything from \(agreement.authorName)", systemImage: "person.slash", role: .destructive) {
                            CloudService.shared.block(authorID: agreement.authorID)
                            dismiss()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Report", isPresented: Binding(
            get: { reporting != nil || reportingAgreement },
            set: { if !$0 { reporting = nil; reportingAgreement = false } })) {
            ForEach(["Offensive or abusive", "Personal information", "Not agreed to by the parties", "Spam"], id: \.self) { reason in
                Button(reason) { Task { await report(reason) } }
            }
        } message: {
            Text("Why are you reporting this?")
        }
        .confirmationDialog("Delete this agreement?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Agreement", role: .destructive) { Task { await deleteAgreement() } }
        } message: {
            Text(Self.deleteMessage(agreement))
        }
        .confirmationDialog("Delete your comment?",
                            isPresented: Binding(get: { deletingComment != nil }, set: { if !$0 { deletingComment = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Comment", role: .destructive) {
                if let comment = deletingComment { Task { await deleteComment(comment) } }
            }
        }
        .sheet(isPresented: $showRules) {
            CommunityRulesView { acceptedRules = true; showRules = false }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private var shareText: String {
        "\(agreement.title)\nParties: \(agreement.parties.joined(separator: ", "))\n\n\(agreement.terms)"
    }

    nonisolated static func deleteMessage(_ agreement: Agreement) -> String {
        switch agreement.access {
        case .everyone: "It’s removed from the repository for everyone, with its comments and verdicts. This can’t be undone."
        case .onlyMe: "It’s deleted from your iCloud on all your devices. This can’t be undone."
        case .parties: "It’s deleted from your iCloud and from everyone you shared it with. This can’t be undone."
        }
    }

    private var visibilityNote: String {
        switch agreement.access {
        case .everyone: ""
        case .onlyMe: "Private — only you can see this, in your iCloud."
        case .parties: agreement.isSharedWithMe
            ? "Shared with you by \(agreement.authorName). Only the people invited can see it."
            : "Shared — only the people you invite can see it."
        }
    }

    private func invite() async {
        do {
            try await CloudSharing.invite(to: agreement)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func leave() async {
        do {
            try await CloudService.shared.leave(agreement)
            onDeleted()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        guard agreement.access == .everyone else { return }
        do {
            async let c = CloudService.shared.comments(on: agreement)
            async let v = CloudService.shared.verdicts(on: agreement)
            comments = try await c
            tally = try await v
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteAgreement() async {
        do {
            try await CloudService.shared.deleteAgreement(agreement)
            onDeleted()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteComment(_ comment: AgreementComment) async {
        deletingComment = nil
        do {
            try await CloudService.shared.deleteComment(comment, on: agreement)
            comments.removeAll { $0.id == comment.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func vote(_ verdict: Verdict) async {
        guard acceptedRules else { showRules = true; return }
        do {
            try await CloudService.shared.setVerdict(verdict, on: agreement)
            if let previous = tally.mine { tally.counts[previous, default: 1] -= 1 }
            tally.counts[verdict, default: 0] += 1
            tally.mine = verdict
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func postComment() async {
        guard acceptedRules else { showRules = true; return }
        busy = true
        defer { busy = false }
        do {
            try await CloudService.shared.addComment(
                newComment.trimmingCharacters(in: .whitespacesAndNewlines), on: agreement)
            newComment = ""
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func report(_ reason: String) async {
        let comment = reporting
        reporting = nil
        reportingAgreement = false
        do {
            try await CloudService.shared.report(agreement: agreement, comment: comment, reason: reason)
            notice = "Thanks — it’s been reported for review."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Community rules

/// Shown once before posting, commenting, or voting (App Review requires
/// users to agree to rules for user-generated content).
struct CommunityRulesView: View {
    var onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("The agreement repository is public. By taking part you agree to:")
                    rule("Publish only agreements every named party agreed to — both to the terms and to publishing them.")
                    rule("Leave out private information: addresses, phone numbers, account numbers, health details.")
                    rule("No abusive, hateful, or harassing content. Objectionable content is removed and repeat abusers are banned.")
                    rule("Verdicts and comments are opinions. Nothing here is legal advice; ask a lawyer about your situation.")
                    Text("Report anything that breaks these rules from its ⋯ menu, or hide everything from a person.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Community Rules")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("I Agree", action: onAccept) }
            }
        }
    }

    private func rule(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
            Text(text)
        }
    }
}

// MARK: - About the repository

/// Where published agreements go and who can see them, in plain words.
struct RepositoryInfoView: View {
    @Environment(\.dismiss) private var dismiss

    /// One line for the publish form.
    static func whereStored(_ visibility: AgreementVisibility) -> String {
        if CloudService.isLocalTestMode {
            return "Test mode is on: this is saved only on this iPhone and nobody else can see it."
        }
        return switch visibility {
        case .everyone: "Stored in the On the Record public repository on Apple iCloud. Anyone using the app can read it."
        case .onlyMe: "Saved privately in your own iCloud. Only you can see it, on your devices."
        case .parties: "Saved in your iCloud and shared only with the people you invite. Each of them needs On the Record and an iCloud account."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if CloudService.isLocalTestMode {
                        Label("Test mode is on. Agreements you publish now are saved only on this iPhone, not in iCloud, and can’t be shared.",
                              systemImage: "testtube.2")
                            .font(.callout.bold())
                            .foregroundStyle(.orange)
                    }
                    point("globe", "Public: stored in the On the Record public repository, a database run on Apple’s iCloud. Anyone using the app can read it, comment, and give a verdict. It can only be viewed in the app; there’s no website.")
                    point("lock.fill", "Private: saved in your own iCloud account. Only you can see it, on your devices — not other users, and not the app’s developer.")
                    point("person.2.fill", "Shared: saved in your iCloud and shared only with the people you invite by link. They need On the Record and an iCloud account. You can remove people or stop sharing at any time.")
                    point("person.crop.circle", "Tap Mine at the top of the Agreements tab to see everything you’ve published, kept privately, or shared, and agreements others shared with you.")
                    point("doc.text", "What’s saved: the title, kind, parties, terms, the transcript text if you include it, and your name as publisher. Public agreements also have the comments and verdicts people add.")
                    point("waveform.slash", "Audio is never published. Recordings stay on your iPhone unless you upload them to a shared meeting.")
                    point("person.2.badge.key", "A transcript can only be published with a consent entry naming at least two people who agreed on the recording.")
                    point("trash", "You can delete your own agreements and comments at any time. Deleting removes them for everyone who could see them.")
                    point("flag", "In the public repository, report anything that breaks the community rules from its ⋯ menu, or hide everything from a person.")
                }
                .padding()
            }
            .navigationTitle("About the Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24)
            Text(text)
        }
    }
}

// MARK: - Composer

/// Turns a recorded conversation into a published verbal agreement.
/// Templates fill in the usual wording so people don't retype it.
struct AgreementComposerView: View {
    var defaultTitle: String
    var transcript: String?
    var meetingCode: String?
    /// Proof of consent behind the transcript. A transcript can only be
    /// published with one naming at least two people.
    var consent: ConsentEntry? = nil
    /// Called after a successful publish, before the sheet closes, with the
    /// new agreement (its parties are the names typed under Parties).
    var onPublished: (Agreement) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("acceptedCommunityRules") private var acceptedRules = false
    @AppStorage("displayName") private var displayName = ""
    @State private var title = ""
    @State private var category = AgreementTemplate.all[0].category
    @State private var parties: [String] = ["", ""]
    @State private var terms = ""
    @State private var includeTranscript = true
    @State private var visibility: AgreementVisibility = .everyone
    @State private var everyoneAgreed = false
    @State private var busy = false
    @State private var error: String?
    @State private var showRules = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (e.g. Lawn care for the summer)", text: $title)
                    Picker("Kind", selection: $category) {
                        ForEach(AgreementTemplate.all) { Text($0.category).tag($0.category) }
                    }
                }

                Section {
                    ForEach(parties.indices, id: \.self) { index in
                        TextField("Party \(index + 1) name", text: $parties[index])
                    }
                    .onDelete { offsets in
                        if parties.count - offsets.count >= 2 { parties.remove(atOffsets: offsets) }
                    }
                    Button("Add Party", systemImage: "person.badge.plus") { parties.append("") }
                } header: {
                    Text("Parties")
                }

                Section {
                    TextEditor(text: $terms)
                        .frame(minHeight: 180)
                    Button("Fill In \(category) Template", systemImage: "doc.on.doc") {
                        terms = AgreementTemplate.all.first { $0.category == category }?.terms(parties: namedParties) ?? terms
                    }
                } header: {
                    Text("Terms")
                } footer: {
                    Text("State what each party agreed to: who does what, for how much, and by when.")
                }

                if let transcript, !transcript.isEmpty {
                    Section {
                        Toggle("Include the recorded conversation", isOn: $includeTranscript)
                        if includeTranscript {
                            Text(transcriptWithParties ?? transcript).font(.caption).lineLimit(6).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Only the text is published, never the audio.")
                    }
                    Section {
                        ConsentBadge(consent: consent)
                            .font(.callout)
                    } header: {
                        Text("Consent on the recording")
                    }
                }

                Section {
                    Picker("Who can see it", selection: $visibility) {
                        ForEach(AgreementVisibility.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Who can see it")
                } footer: {
                    Text(RepositoryInfoView.whereStored(visibility)
                         + (visibility == .parties && CloudSharing.isAvailable
                            ? " After publishing, you’ll choose who to invite." : ""))
                }

                Section {
                    TextField("Your name (shown as publisher)", text: $displayName)
                    Toggle(visibility == .everyone
                           ? "Every party named above agreed to these terms and to publishing them publicly"
                           : "Every party named above agreed to these terms and to keeping this record",
                           isOn: $everyoneAgreed)
                } footer: {
                    Text(visibility == .everyone
                         ? "Published agreements are public: anyone can read, comment on, and judge them. This is a public record of what was agreed, not legal advice."
                         : "This is a record of what was agreed, not legal advice.")
                }

            }
            .alert("Couldn’t Publish", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
            .navigationTitle("New Agreement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Publish") { Task { await publish() } }
                            .disabled(!canPublish)
                    }
                }
            }
            .onAppear {
                if title.isEmpty { title = defaultTitle }
                // Names already at the top of the transcript fill in Parties,
                // otherwise the names from the consent entry.
                if namedParties.isEmpty, let transcript {
                    var names = TranscriptExports.parties(in: transcript)
                    if names.isEmpty { names = consent?.names ?? [] }
                    if !names.isEmpty { parties = names.count >= 2 ? names : names + [""] }
                }
            }
            .sheet(isPresented: $showRules) {
                CommunityRulesView {
                    acceptedRules = true
                    showRules = false
                    Task { await publish() }
                }
            }
        }
    }

    private var namedParties: [String] {
        parties.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The transcript as published: headed by every name typed under
    /// Parties, so the recorded conversation names who took part.
    private var transcriptWithParties: String? {
        guard let transcript, !transcript.isEmpty else { return transcript }
        return TranscriptExports.withParties(namedParties, transcript)
    }

    private var canPublish: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && namedParties.count >= 2
            && !terms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && everyoneAgreed
            && hasConsent
    }

    /// A recorded conversation needs proof that at least two people agreed
    /// on the recording; agreements typed in by hand don't.
    private var hasConsent: Bool {
        guard let transcript, !transcript.isEmpty else { return true }
        return consent?.isEnough == true
    }

    private func publish() async {
        // The community rules cover the public repository only.
        guard acceptedRules || visibility != .everyone else { showRules = true; return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let agreement = try await CloudService.shared.publish(
                title: title.trimmingCharacters(in: .whitespaces),
                category: category,
                parties: namedParties,
                terms: terms.trimmingCharacters(in: .whitespacesAndNewlines),
                transcript: includeTranscript ? transcriptWithParties : nil,
                meetingCode: meetingCode,
                visibility: visibility)
            onPublished(agreement)
            dismiss()
            if agreement.access == .parties && CloudSharing.isAvailable {
                // Once this form has closed, ask who to invite.
                try? await Task.sleep(for: .seconds(0.7))
                try? await CloudSharing.invite(to: agreement)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Starting wording for common kinds of verbal agreement.
struct AgreementTemplate: Identifiable {
    var category: String
    var body: String
    var id: String { category }

    func terms(parties: [String]) -> String {
        let a = parties.first ?? "[Party 1]"
        let b = parties.dropFirst().first ?? "[Party 2]"
        return body.replacingOccurrences(of: "{A}", with: a).replacingOccurrences(of: "{B}", with: b)
    }

    static let all: [AgreementTemplate] = [
        .init(category: "Services", body: """
            {A} will provide the following work for {B}: [describe the work].
            {B} will pay {A} $[amount] [per hour / in total], paid [when / how].
            Work starts [date] and is finished by [date].
            Either party may end this agreement with [notice] notice.
            """),
        .init(category: "Sale", body: """
            {A} sells [item and condition] to {B} for $[amount].
            {B} pays [how] on [date]; {A} hands over the item on [date].
            The item is sold as-is unless stated here: [any promises].
            """),
        .init(category: "Loan", body: """
            {A} lends {B} $[amount] on [date].
            {B} repays [in full / $[amount] per [period]] by [date], with [no interest / interest of ___].
            If a payment is late, [what happens].
            """),
        .init(category: "Rental", body: """
            {A} rents [item or space] to {B} from [date] to [date].
            {B} pays $[amount] [per period], due [when].
            {B} returns it in the same condition; damage is handled by [how].
            """),
        .init(category: "Shared costs", body: """
            {A} and {B} share the cost of [what], split [how].
            Each pays their share by [date] to [whom].
            """),
        .init(category: "Other", body: """
            {A} agrees to: [what].
            {B} agrees to: [what].
            This agreement lasts until [date or event].
            """),
    ]
}
