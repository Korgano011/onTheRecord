import SwiftUI

/// Record a conversation, cross-check it across phones, and publish what
/// was agreed to the public verbal-agreement repository.
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Recordings", systemImage: "waveform") { RecordingsView() }
            Tab("Meetings", systemImage: "person.2.wave.2") { MeetingsView() }
            Tab("Agreements", systemImage: "signature") { AgreementsView() }
        }
    }
}

struct RecordingsView: View {
    @StateObject private var recorder = RecorderManager()
    @State private var recordings: [Recording] = []
    @State private var showConsent = false
    @State private var showRecording = false

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

    private var list: some View {
        List {
            ForEach(recordings) { recording in
                NavigationLink(value: recording) {
                    RecordingRow(recording: recording)
                }
            }
            .onDelete(perform: deleteRows)
        }
        .navigationDestination(for: Recording.self) { recording in
            RecordingDetailView(recording: recording) { reload() }
        }
    }

    private func reload() {
        recordings = Store.loadAll()
    }

    private func deleteRows(_ offsets: IndexSet) {
        for index in offsets {
            Store.delete(recordings[index])
        }
        reload()
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
