import SwiftUI
import AVFoundation

/// Playback, transcription, and export for a single saved recording.
struct RecordingDetailView: View {
    @State var recording: Recording
    var onChange: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var isTranscribing = false
    @State private var transcriptionError: String?
    @State private var busyPart: Recording.PhonePart?
    @State private var partErrors: [Recording.PhonePart: String] = [:]
    /// "Chunk 2 of 5" while a long transcription runs.
    @State private var chunkProgress: String?
    /// Seconds of audio per transcription chunk; 0 = no chunking.
    @AppStorage("transcribeChunkSeconds") private var chunkSeconds = 60
    @State private var showAgreement = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                playbackControls
                Divider()
                transcriptSection
            }
            .padding()
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: recording.audioURL) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAgreement = true
                } label: {
                    Label("Create Agreement", systemImage: "signature")
                }
            }
        }
        .sheet(isPresented: $showAgreement) {
            AgreementComposerView(defaultTitle: recording.title,
                                  transcript: fullTranscript,
                                  meetingCode: recording.meetingCode)
        }
        .onDisappear { player?.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.createdAt, format: .dateTime.weekday().month().day().hour().minute())
                .foregroundStyle(.secondary)
            Text("Duration \(recording.formattedDuration)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let code = recording.meetingCode {
                Label("Shared meeting \(code) · \(recording.uploadedRecordName == nil ? "not uploaded yet" : "uploaded") · see the Meetings tab",
                      systemImage: "person.2.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let names = recording.consentedBy, !names.isEmpty {
                Label("Agreed: \(names.joined(separator: ", "))", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playbackControls: some View {
        Button(action: togglePlayback) {
            Label(isPlaying ? "Pause" : "Play",
                  systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title3)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private var transcriptSection: some View {
        chunkPicker
        if let locked = recording.lockedSpans, !locked.isEmpty {
            Text("Transcripts").font(.headline)
            ForEach(Recording.PhonePart.allCases, id: \.self) { part in
                transcriptPart(part)
            }
        } else {
            singleTranscript
        }
    }

    /// Long audio is transcribed in pieces of this length so it isn't cut off.
    private var chunkPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transcribe in chunks of")
                Spacer()
                Picker("Chunk length", selection: $chunkSeconds) {
                    Text("Off").tag(0)
                    Text("30 sec").tag(30)
                    Text("1 min").tag(60)
                    Text("2 min").tag(120)
                    Text("5 min").tag(300)
                    Text("10 min").tag(600)
                }
                .pickerStyle(.menu)
                .disabled(isTranscribing || busyPart != nil)
            }
            Text(chunkSeconds == 0
                 ? "Transcribes in one pass. Long recordings may be cut off."
                 : "Shorter chunks are less likely to be cut off; a word may be split where chunks meet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let chunkProgress {
                Text(chunkProgress)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var singleTranscript: some View {
        HStack {
            Text("Transcript").font(.headline)
            Spacer()
            Button {
                    Task { await transcribe() }
                } label: {
                    if isTranscribing {
                        ProgressView()
                    } else {
                        Label(recording.transcript == nil ? "Transcribe" : "Transcribe Again",
                              systemImage: "text.viewfinder")
                    }
                }
                .disabled(isTranscribing)
        }

        if let transcript = recording.transcript {
            Text(transcript)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            ShareLink(item: transcript) {
                Label("Export Transcript", systemImage: "doc.text")
            }
            .padding(.top, 4)
        } else if let error = transcriptionError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
        } else {
            Text("No transcript yet. Transcription runs on your device.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// One part (unlocked or locked) with its own Transcribe button.
    private func transcriptPart(_ part: Recording.PhonePart) -> some View {
        let audioLength = recording.audioLength(for: part)
        let text = recording.transcript(for: part)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(part.title, systemImage: part.systemImage)
                    .font(.subheadline.bold())
                Spacer()
                Text("Audio \(Self.timeString(audioLength))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let text {
                Text(text.isEmpty ? "(No speech detected.)" : text)
                    .textSelection(.enabled)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = partErrors[part] {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if audioLength < 0.5 {
                Text("No audio was captured with the phone \(part == .unlocked ? "unlocked" : "locked").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    Task { await transcribe(part) }
                } label: {
                    if busyPart == part {
                        ProgressView()
                    } else {
                        Label(text == nil ? "Transcribe" : "Transcribe Again",
                              systemImage: "text.viewfinder")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busyPart != nil || audioLength < 0.5)

                Spacer()

                if let text, !text.isEmpty {
                    ShareLink(item: text) {
                        Label("Export", systemImage: "doc.text")
                    }
                }
            }
            .font(.callout)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func transcribe(_ part: Recording.PhonePart) async {
        busyPart = part
        partErrors[part] = nil
        defer { busyPart = nil; chunkProgress = nil }
        do {
            let text = try await TranscriptionService.transcribe(
                url: recording.audioURL, spans: recording.spans(for: part),
                chunkLength: chunkLength, progress: showProgress)
            recording.setTranscript(text, for: part)
            Store.save(recording)
            onChange()
        } catch {
            partErrors[part] = error.localizedDescription
        }
    }

    /// Whatever has been transcribed, for publishing as an agreement.
    private var fullTranscript: String? {
        if let transcript = recording.transcript { return transcript }
        let parts = [recording.unlockedTranscript, recording.lockedTranscript].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var chunkLength: TimeInterval? {
        chunkSeconds > 0 ? TimeInterval(chunkSeconds) : nil
    }

    private func showProgress(_ chunk: Int, _ total: Int) {
        chunkProgress = total > 1 ? "Transcribing chunk \(chunk) of \(total)…" : nil
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: recording.audioURL)
        }
        player?.play()
        isPlaying = true
    }

    private func transcribe() async {
        isTranscribing = true
        transcriptionError = nil
        defer { isTranscribing = false; chunkProgress = nil }
        do {
            let text = try await TranscriptionService.transcribe(
                url: recording.audioURL, chunkLength: chunkLength, progress: showProgress)
            recording.transcript = text.isEmpty ? "(No speech detected.)" : text
            Store.save(recording)
            onChange()
        } catch {
            transcriptionError = error.localizedDescription
        }
    }
}
