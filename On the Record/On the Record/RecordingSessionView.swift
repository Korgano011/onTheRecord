import SwiftUI

/// The recording screen, shown after everyone has agreed. The mic stays off
/// until Record is pressed; once live, a red banner and pulsing dot stay
/// visible the entire time, so recording is never hidden.
struct RecordingSessionView: View {
    @ObservedObject var recorder: RecorderManager
    var onFinished: () -> Void

    @State private var title = ""
    /// Minutes of audio per saved part; 0 = autosave off.
    @AppStorage("autosaveMinutes") private var autosaveMinutes = 5
    /// Minutes of audio before recording stops itself; 0 = no limit.
    @AppStorage("stopAfterMinutes") private var stopAfterMinutes = 0
    @State private var stopAfterText = ""
    @FocusState private var stopAfterFocused: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 28) {
            if recorder.state == .recording {
                banner
            } else {
                readyHeader
            }

            Spacer()

            Text(timeString(recorder.elapsed))
                .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())

            meter

            if recorder.state == .recording, let limit = recorder.stopLimit {
                Text("Stops and saves at \(timeString(limit)) · \(timeString(max(0, limit - recorder.elapsed))) left")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if recorder.state == .recording, autosaveMinutes > 0 {
                Text("Part \(recorder.partNumber) · autosaves every \(autosaveMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .onChange(of: title) { recorder.sessionTitle = title }

            if recorder.state != .recording {
                autosavePicker
                stopAfterPicker
            }

            if recorder.state == .recording {
                stopControls
            } else {
                recordControls
            }
        }
        .onChange(of: recorder.didAutoStop) {
            if recorder.didAutoStop { onFinished() }
        }
        .overlay {
            if recorder.state == .denied {
                deniedOverlay
            }
        }
        // Recording intentionally continues when the screen locks (the `audio`
        // background mode keeps the session alive). iOS shows the orange mic
        // indicator and an active-recording lock screen the whole time, so it
        // stays visible — it just isn't stopped by the screen going idle.
    }

    private var readyHeader: some View {
        VStack(spacing: 6) {
            Text("Ready to record")
                .font(.headline)
            Text("Everyone in the room has agreed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.horizontal)
    }

    private var recordControls: some View {
        VStack(spacing: 16) {
            Button {
                stopAfterFocused = false
                Task {
                    recorder.sessionTitle = title
                    await recorder.startRecording(
                        autosaveEvery: autosaveMinutes > 0 ? TimeInterval(autosaveMinutes * 60) : nil,
                        stopAfter: stopAfterMinutes > 0 ? TimeInterval(stopAfterMinutes * 60) : nil)
                    pulse = true
                }
            } label: {
                Label("Record", systemImage: "record.circle")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            Button("Cancel", action: onFinished)
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }

    /// Long recordings are saved as parts so each one transcribes in full.
    private var autosavePicker: some View {
        VStack(spacing: 4) {
            Picker("Autosave", selection: $autosaveMinutes) {
                Text("Off").tag(0)
                ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(.segmented)
            Text(autosaveMinutes > 0
                 ? "Saves a new part every \(autosaveMinutes) minutes, so long recordings transcribe in full."
                 : "Saves one file when you stop. Very long recordings may not transcribe completely.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    /// Optional time limit, typed in minutes: recording stops and saves on
    /// its own. Empty or 0 means no limit.
    private var stopAfterPicker: some View {
        HStack {
            Text("Stop recording after")
            Spacer()
            TextField("No limit", text: $stopAfterText)
                .focused($stopAfterFocused)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            Text("min")
        }
        .font(.callout)
        .padding(.horizontal)
        .onAppear {
            stopAfterText = stopAfterMinutes > 0 ? String(stopAfterMinutes) : ""
        }
        .onChange(of: stopAfterText) {
            let digits = String(stopAfterText.filter(\.isNumber).prefix(4))
            if digits != stopAfterText { stopAfterText = digits }
            stopAfterMinutes = Int(digits) ?? 0
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { stopAfterFocused = false }
            }
        }
    }

    private var stopControls: some View {
        HStack(spacing: 16) {
            Button(role: .destructive) {
                recorder.cancelRecording()
                onFinished()
            } label: {
                Text("Discard").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                _ = recorder.stopRecording(title: title)
                onFinished()
            } label: {
                Label("Stop & Save", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(recorder.isPaused ? .white : .red)
                .frame(width: 12, height: 12)
                .opacity(pulse ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text(recorder.isPaused ? "PAUSED — mic in use elsewhere" : "RECORDING")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Spacer()
            if recorder.isPaused {
                Button("Resume") { recorder.resumeIfPaused() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .padding()
        .background(recorder.isPaused ? .orange : .red.opacity(0.85))
    }

    private var meter: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 6)
                .fill(.tint)
                .frame(width: geo.size.width * recorder.level)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                )
                .animation(.linear(duration: 0.1), value: recorder.level)
        }
        .frame(height: 12)
        .padding(.horizontal, 40)
    }

    private var deniedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash.fill").font(.largeTitle)
            Text("Microphone access is off")
                .font(.headline)
            Text("Enable the microphone for On the Record in Settings to record.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Close") { onFinished() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(40)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
