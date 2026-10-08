import SwiftUI

/// Record a conversation, cross-check it across phones, and publish what
/// was agreed to the public verbal-agreement repository.
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Recordings", systemImage: "waveform") { RecordingsView() }
            Tab("Meetings", systemImage: "person.2.wave.2") { MeetingsView() }
            Tab("Exported", systemImage: "doc.text") { ExportedTranscriptsView() }
            Tab("Agreements", systemImage: "signature") { AgreementsView() }
        }
    }
}

struct RecordingsView: View {
    @StateObject private var recorder = RecorderManager()
    @State private var recordings: [Recording] = []
    @State private var showConsent = false
    @State private var showRecording = false
    @State private var folderToDelete: RecordingFolder?

    var body: some View {
        NavigationStack {
            Group {
                if recordings.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showConsent = true
                    } label: {
                        Label("New Recording", systemImage: "mic.circle.fill")
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showConsent) {
            ConsentView {
                showConsent = false
                showRecording = true
            } onCancel: {
                showConsent = false
            }
        }
        .fullScreenCover(isPresented: $showRecording) {
            RecordingSessionView(recorder: recorder) {
                showRecording = false
                reload()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Recordings Yet", systemImage: "waveform")
        } description: {
            Text("Everyone in the room must agree before you record. Tap the mic to begin.")
        } actions: {
            Button("Start a Recording") { showConsent = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var folders: [RecordingFolder] { RecordingFolder.group(recordings) }

    private var list: some View {
        List {
            ForEach(folders) { folder in
                NavigationLink(value: folder) {
                    FolderRow(folder: folder)
                }
            }
            .onDelete(perform: deleteRows)
        }
        .navigationDestination(for: Recording.self) { recording in
            RecordingDetailView(recording: recording) { reload() }
        }
        .navigationDestination(for: RecordingFolder.self) { folder in
            RecordingFolderView(folderID: folder.id, title: folder.title)
        }
        .confirmationDialog("Delete “\(folderToDelete?.title ?? "")” (\(folderToDelete?.partCount ?? ""))?",
                            isPresented: Binding(get: { folderToDelete != nil },
                                                 set: { if !$0 { folderToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) {
                folderToDelete?.parts.forEach { Store.delete($0) }
                folderToDelete = nil
                reload()
            }
        }
    }

    private func reload() {
        recordings = Store.loadAll()
    }

    /// A folder can hold a whole meeting, so ask first.
    private func deleteRows(_ offsets: IndexSet) {
        if let index = offsets.first { folderToDelete = folders[index] }
    }
}

/// The recording(s) in one session folder, in part order.
struct RecordingFolderView: View {
    let folderID: String
    let title: String
    @State private var parts: [Recording] = []

    var body: some View {
        List {
            Section {
                ForEach(parts) { part in
                    NavigationLink(value: part) {
                        RecordingRow(recording: part)
                    }
                }
                .onDelete { offsets in
                    offsets.map { parts[$0] }.forEach { Store.delete($0) }
                    reload()
                }
            } footer: {
                Text("\(parts.count == 1 ? "1 part" : "\(parts.count) parts") · \(Recording.format(parts.reduce(0) { $0 + $1.duration })) total")
            }
        }
        .navigationTitle(title)
        .onAppear(perform: reload)
    }

    private func reload() {
        parts = RecordingFolder.group(Store.loadAll()).first { $0.id == folderID }?.parts ?? []
    }
}

struct FolderRow: View {
    let folder: RecordingFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.title).font(.headline).lineLimit(1)
                Text("\(folder.partCount) · \(folder.createdAt.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Recording.format(folder.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recording.transcript == nil ? "waveform" : "text.quote")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).font(.headline).lineLimit(1)
                Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(recording.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
