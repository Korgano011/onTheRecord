import SwiftUI

/// Meeting codes this phone has recorded for or opened.
enum MeetingList {
    static func codes() -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: "meetingCodes") ?? []
        let recorded = Store.loadAll().compactMap(\.meetingCode)
        var seen = Set<String>()
        return (saved + recorded).filter { seen.insert($0).inserted }
    }

    static func remember(_ code: String) {
        var saved = UserDefaults.standard.stringArray(forKey: "meetingCodes") ?? []
        guard !saved.contains(code) else { return }
        saved.insert(code, at: 0)
        UserDefaults.standard.set(saved, forKey: "meetingCodes")
    }

    static func forget(_ code: String) {
        let saved = (UserDefaults.standard.stringArray(forKey: "meetingCodes") ?? []).filter { $0 != code }
        UserDefaults.standard.set(saved, forKey: "meetingCodes")
    }
}

/// Saved combined transcripts, one per meeting, in Documents/Meetings.
enum MeetingStore {
    private static var folder: URL {
        let url = Store.documentsDirectory.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load(_ code: String) -> MergedTranscript? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(code).json")) else { return nil }
        return try? JSONDecoder().decode(MergedTranscript.self, from: data)
    }

    static func save(_ transcript: MergedTranscript, code: String) {
        if let data = try? JSONEncoder().encode(transcript) {
            try? data.write(to: folder.appendingPathComponent("\(code).json"), options: .atomic)
        }
    }
}

struct MeetingsView: View {
    @State private var codes: [String] = []
    @State private var openCode = ""
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack {
                        TextField("Meeting code", text: $openCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Open") {
                            let code = openCode.uppercased().filter { $0.isLetter || $0.isNumber }
                            MeetingList.remember(code)
                            openCode = ""
                            path.append(code)
                        }
                        .disabled(openCode.count < 6)
                    }
                } footer: {
                    Text("Start or join a shared meeting on the recording screen. Every phone in the meeting uploads its audio, and the combined transcript cross-checks them.")
                }

                if !codes.isEmpty {
                    Section("Your meetings") {
                        ForEach(codes, id: \.self) { code in
                            NavigationLink(value: code) {
                                HStack {
                                    Text(code).font(.body.monospaced())
                                    Spacer()
                                    if MeetingStore.load(code) != nil {
                                        Image(systemName: "text.quote").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            MainActor.assumeIsolated {
                                for code in offsets.map({ codes[$0] }) { MeetingList.forget(code) }
                                reload()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meetings")
            .navigationDestination(for: String.self) { code in
                MeetingDetailView(code: code)
            }
            .onAppear(perform: reload)
            .task { await CloudService.shared.uploadPending() }
        }
    }

    private func reload() { codes = MeetingList.codes() }
}

/// One meeting: who recorded, and the cross-checked transcript.
struct MeetingDetailView: View {
    let code: String

    @State private var meeting: MeetingInfo?
    @State private var uploads: [MeetingUpload] = []
    @State private var merged: MergedTranscript?
    @State private var editedText: String?
    @State private var loading = false
    @State private var building: String?
    @State private var error: String?
    @State private var showAgreement = false

    var body: some View {
        List {
            Section {
                if let meeting {
                    LabeledContent("Title", value: meeting.title)
                    LabeledContent("Started", value: meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Code") { Text(code).font(.body.monospaced()) }
            }

            Section("Recorders") {
                if uploads.isEmpty {
                    Text(loading ? "Loading…" : "No audio uploaded yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recorders, id: \.deviceID) { recorder in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recorder.name + (recorder.isMine ? " (this phone)" : ""))
                            .font(.headline)
                        Text("\(recorder.parts) part\(recorder.parts == 1 ? "" : "s") · \(Self.timeString(recorder.duration)) of audio")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    Task { await buildCombined() }
                } label: {
                    if let building {
                        HStack { ProgressView(); Text(building) }
                    } else {
                        Label(merged == nil ? "Build Combined Transcript" : "Rebuild Combined Transcript",
                              systemImage: "text.badge.checkmark")
                    }
                }
                .disabled(uploads.isEmpty || building != nil)
            } footer: {
                Text("Each phone’s audio is transcribed on this device. Where the phones agree the words stand; where one heard what the other missed, it’s filled in; where they heard different words, the more confident one is used and you can pick the other.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let merged {
                combinedSection(merged)
            }
        }
        .navigationTitle("Meeting \(code)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showAgreement = true
                    } label: {
                        Label("Create Agreement", systemImage: "signature")
                    }
                    .disabled(merged == nil)
                    Button(role: .destructive) {
                        Task { await removeMyAudio() }
                    } label: {
                        Label("Remove This Phone’s Audio from iCloud", systemImage: "icloud.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showAgreement) {
            AgreementComposerView(
                defaultTitle: meeting?.title ?? "Meeting \(code)",
                transcript: currentText,
                meetingCode: code)
        }
    }

    private var currentText: String { editedText ?? merged?.text ?? "" }

    @ViewBuilder
    private func combinedSection(_ merged: MergedTranscript) -> some View {
        Section {
            Text("\(merged.sourceNames.joined(separator: " + ")) · \(merged.disagreementCount) disagreement\(merged.disagreementCount == 1 ? "" : "s") · \(merged.filledIn) stretch\(merged.filledIn == 1 ? "" : "es") filled in")
                .font(.caption)
                .foregroundStyle(.secondary)
            if editedText != nil {
                TextEditor(text: Binding(get: { editedText ?? "" }, set: { editedText = $0 }))
                    .frame(minHeight: 240)
                Button("Done Editing") { saveEdits() }
            } else {
                Text(transcriptText(merged))
                    .textSelection(.enabled)
                Button("Edit Transcript") { editedText = merged.text }
            }
            ExportTranscriptButton(text: currentText, title: "\(meeting?.title ?? "Meeting \(code)") - Combined",
                                   meetingCode: code)
        } header: {
            Text("Combined transcript")
        }

        let choices = merged.segments.filter { $0.choices != nil }
        if !choices.isEmpty && editedText == nil {
            Section("Where the phones disagreed") {
                ForEach(choices) { segment in
                    disagreementRow(segment, names: merged.sourceNames)
                }
            }
        }
    }

    /// Disagreements are underlined in orange in the transcript.
    private func transcriptText(_ merged: MergedTranscript) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in merged.segments.enumerated() {
            if index > 0 { result += AttributedString(" ") }
            var piece = AttributedString(segment.displayText)
            if segment.choices != nil {
                piece.foregroundColor = .orange
                piece.underlineStyle = .single
            }
            result += piece
        }
        return result
    }

    private func disagreementRow(_ segment: MergedTranscript.Segment, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date(timeIntervalSinceReferenceDate: segment.time), format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            ForEach(Array((segment.choices ?? []).enumerated()), id: \.offset) { index, choice in
                Button {
                    choose(index, in: segment)
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: index == segment.chosen ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text("“\(choice.text)”")
                            Text("\(names.indices.contains(choice.source) ? names[choice.source] : "Phone") · \(Int(choice.confidence * 100))% sure")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private struct RecorderSummary {
        var deviceID: String
        var name: String
        var isMine: Bool
        var parts: Int
        var duration: TimeInterval
    }

    private var recorders: [RecorderSummary] {
        Dictionary(grouping: uploads, by: \.deviceID)
            .map { id, parts in
                RecorderSummary(deviceID: id, name: parts[0].recorderName, isMine: parts[0].isMine,
                                parts: parts.count, duration: parts.map(\.duration).reduce(0, +))
            }
            .sorted { $0.isMine && !$1.isMine }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        MeetingList.remember(code)
        merged = MeetingStore.load(code)
        await CloudService.shared.uploadPending()
        do {
            meeting = try await CloudService.shared.meeting(code: code)
            uploads = try await CloudService.shared.uploads(meetingCode: code)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Downloads every phone's parts, transcribes each into timed words,
    /// and cross-checks the phones against each other.
    private func buildCombined() async {
        error = nil
        defer { building = nil }
        let groups = recorders
        var streams: [[SpokenWord]] = []
        var names: [String] = []
        do {
            for (source, recorder) in groups.enumerated() {
                let parts = uploads.filter { $0.deviceID == recorder.deviceID }
                var words: [SpokenWord] = []
                for (index, part) in parts.enumerated() {
                    building = "\(recorder.name): part \(index + 1) of \(parts.count)…"
                    let url = try await CloudService.shared.downloadAudio(part)
                    words += try await TranscriptionService.transcribeWords(
                        url: url, startedAt: part.startedAt, source: source)
                }
                streams.append(words)
                names.append(recorder.name)
            }
            building = "Cross-checking…"
            let result = TranscriptMerger.merge(streams, names: names)
            merged = result
            editedText = nil
            MeetingStore.save(result, code: code)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func choose(_ index: Int, in segment: MergedTranscript.Segment) {
        guard var merged, let i = merged.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        merged.segments[i].chosen = index
        self.merged = merged
        MeetingStore.save(merged, code: code)
    }

    /// A hand-edited transcript replaces the segments with plain text.
    private func saveEdits() {
        guard let editedText, var merged else { return }
        merged.segments = [.init(time: merged.segments.first?.time ?? 0, text: editedText)]
        self.merged = merged
        self.editedText = nil
        MeetingStore.save(merged, code: code)
    }

    private func removeMyAudio() async {
        do {
            try await CloudService.shared.removeMyAudio(meetingCode: code)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
