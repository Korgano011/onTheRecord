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

    var body: some View {
        NavigationStack {
            Group {
                if agreements.isEmpty && !loading {
                    ContentUnavailableView {
                        Label("No Agreements Yet", systemImage: "signature")
                    } description: {
                        Text(error ?? "Record a conversation where people agree, then publish it here as a verbal agreement anyone can read and judge.")
                    } actions: {
                        Button("Refresh") { Task { await load() } }
                    }
                } else {
                    List(filtered) { agreement in
                        NavigationLink(value: agreement) {
                            AgreementRow(agreement: agreement)
                        }
                    }
                    .searchable(text: $search, prompt: "Search agreements")
                }
            }
            .overlay { if loading && agreements.isEmpty { ProgressView() } }
            .navigationTitle("Agreements")
            .navigationDestination(for: Agreement.self) { agreement in
                AgreementDetailView(agreement: agreement)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showComposer = true
                    } label: {
                        Label("New Agreement", systemImage: "square.and.pencil")
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: cloud.blockedAuthors) { Task { await load() } }
            .sheet(isPresented: $showComposer, onDismiss: { Task { await load() } }) {
                AgreementComposerView(defaultTitle: "", transcript: nil, meetingCode: nil)
            }
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

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            agreements = try await CloudService.shared.agreements()
            error = nil
        } catch {
            self.error = error.localizedDescription
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
            Text(agreement.publishedAt, format: .dateTime.month().day().year())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct AgreementDetailView: View {
    let agreement: Agreement

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

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(agreement.title).font(.title3.bold())
                    Text("\(agreement.category) · published \(agreement.publishedAt.formatted(date: .abbreviated, time: .omitted)) by \(agreement.authorName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .contextMenu {
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
                    Button("Report Agreement", systemImage: "flag") { reportingAgreement = true }
                    Button("Hide Everything from \(agreement.authorName)", systemImage: "person.slash", role: .destructive) {
                        CloudService.shared.block(authorID: agreement.authorID)
                        dismiss()
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
        .sheet(isPresented: $showRules) {
            CommunityRulesView { acceptedRules = true; showRules = false }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private var shareText: String {
        "\(agreement.title)\nParties: \(agreement.parties.joined(separator: ", "))\n\n\(agreement.terms)"
    }

    private func load() async {
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

// MARK: - Composer

/// Turns a recorded conversation into a published verbal agreement.
/// Templates fill in the usual wording so people don't retype it.
struct AgreementComposerView: View {
    var defaultTitle: String
    var transcript: String?
    var meetingCode: String?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("acceptedCommunityRules") private var acceptedRules = false
    @AppStorage("displayName") private var displayName = ""
    @State private var title = ""
    @State private var category = AgreementTemplate.all[0].category
    @State private var parties: [String] = ["", ""]
    @State private var terms = ""
    @State private var includeTranscript = true
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
                            Text(transcript).font(.caption).lineLimit(6).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Only the text is published, never the audio.")
                    }
                }

                Section {
                    TextField("Your name (shown as publisher)", text: $displayName)
                    Toggle("Every party named above agreed to these terms and to publishing them publicly", isOn: $everyoneAgreed)
                } footer: {
                    Text("Published agreements are public: anyone can read, comment on, and judge them. This is a public record of what was agreed, not legal advice.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
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
            .onAppear { if title.isEmpty { title = defaultTitle } }
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

    private var canPublish: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && namedParties.count >= 2
            && !terms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && everyoneAgreed
    }

    private func publish() async {
        guard acceptedRules else { showRules = true; return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            _ = try await CloudService.shared.publish(
                title: title.trimmingCharacters(in: .whitespaces),
                category: category,
                parties: namedParties,
                terms: terms.trimmingCharacters(in: .whitespacesAndNewlines),
                transcript: includeTranscript ? transcript : nil,
                meetingCode: meetingCode)
            dismiss()
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
