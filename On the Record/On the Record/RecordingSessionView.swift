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
    /// Minutes of audio before the reminder to stop plays.
    @AppStorage("reminderMinutes") private var reminderMinutes = 10
    /// How the reminder plays; Off = no reminder.
    @AppStorage("reminderAlert") private var reminderAlert: PartAlert = .off
    @State private var pulse = false
    /// Set once everyone has given consent again, on the recording.
    @State private var consentOnRecording = false
    /// Signal each saved part with a chime and/or vibration.
    @AppStorage("partAlert") private var partAlert: PartAlert = .chime
    /// Name shown to the other phones in a shared meeting.
    @AppStorage("displayName") private var displayName = ""
    @State private var meeting: MeetingInfo?
    @State private var joinCode = ""
    @State private var meetingBusy = false
    @State private var meetingError: String?

    var body: some View {
        VStack(spacing: 28) {
            if recorder.state == .recording {
                banner
                if !consentOnRecording { consentReminder }
                Spacer()
                liveStatus
                Spacer()
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .onChange(of: title) { recorder.sessionTitle = title }
                stopControls
            } else {
                readyHeader
                ScrollView {
                    VStack(spacing: 22) {
                        Text(timeString(0))
                            .font(.system(size: 56, weight: .light, design: .rounded).monospacedDigit())
                        TextField("Title (optional)", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal)
                        autosavePicker
                        if autosaveMinutes > 0 { partAlertPicker }
                        reminderPicker
                        meetingSection
                    }
                    .padding(.vertical)
                }
                .scrollDismissesKeyboard(.interactively)
                recordControls
            }
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

    private var liveStatus: some View {
        VStack(spacing: 20) {
            Text(timeString(recorder.elapsed))
                .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())

            meter

            if recorder.state == .recording, let at = recorder.reminderAt {
                if recorder.didRemind {
                    Label("Reminder: tap Stop & Save when the meeting ends", systemImage: "bell.fill")
                        .font(.callout.bold())
                        .foregroundStyle(.orange)
                }
                Text("\(recorder.didRemind ? "Next reminder" : "Reminder") at \(timeString(at)) · \(timeString(max(0, at - recorder.elapsed))) left")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if recorder.state == .recording, autosaveMinutes > 0 {
                Text("Part \(recorder.partNumber) · autosaves every \(autosaveMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let code = recorder.meetingCode {
                Label("Shared meeting \(code) · each part uploads when saved", systemImage: "person.2.wave.2")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
    }

    /// How the phone says a part was saved, quietly enough not to
    /// interrupt the conversation.
    private var partAlertPicker: some View {
        VStack(spacing: 4) {
            Picker("When a part is saved", selection: $partAlert) {
                ForEach(PartAlert.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(partAlertHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    private var partAlertHint: String {
        switch partAlert {
        case .off: "No signal when a part is saved."
        case .chime: "A very quiet tick each time a part is saved."
        case .vibrate: "A short buzz each time a part is saved. Keep the phone off hard tables so the buzz isn’t recorded."
        case .both: "A quiet tick and a short buzz each time a part is saved."
        }
    }

    /// Several phones can record one meeting (e.g. at opposite ends of a
    /// long table). Each uploads its parts; the Meetings tab then
    /// cross-checks their transcripts.
    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shared meeting (optional)", systemImage: "person.2.wave.2")
                .font(.subheadline.bold())
            if let meeting {
                HStack {
                    VStack(alignment: .leading) {
                        Text(meeting.code)
                            .font(.title2.monospaced().bold())
                        Text("Other phones join with this code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: "Join my On the Record meeting with code \(meeting.code)") {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button("Leave", role: .destructive) { self.meeting = nil }
                        .buttonStyle(.bordered)
                }
            } else {
                Text("Recording with more than one phone? Start a meeting here and join it on the other phones. Each phone uploads its audio, and the transcripts are cross-checked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Your name (shown to the meeting)", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Start Meeting") { Task { await startMeeting() } }
                        .buttonStyle(.bordered)
                    Spacer()
                    TextField("Code", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Button("Join") { Task { await joinMeeting() } }
                        .buttonStyle(.bordered)
                        .disabled(joinCode.count < 6)
                }
                .disabled(meetingBusy || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if meetingBusy { ProgressView() }
            if let meetingError {
                Text(meetingError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func startMeeting() async {
        meetingBusy = true
        meetingError = nil
        defer { meetingBusy = false }
        do {
            let name = title.trimmingCharacters(in: .whitespaces)
            meeting = try await CloudService.shared.createMeeting(title: name.isEmpty ? "Meeting" : name)
        } catch {
            meetingError = error.localizedDescription
        }
    }

    private func joinMeeting() async {
        meetingBusy = true
        meetingError = nil
        defer { meetingBusy = false }
        do {
            meeting = try await CloudService.shared.meeting(code: joinCode)
            if let meeting, title.isEmpty { title = meeting.title }
        } catch {
            meetingError = error.localizedDescription
        }
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
                Task {
                    recorder.sessionTitle = title
                    consentOnRecording = false
                    await recorder.startRecording(
                        autosaveEvery: autosaveMinutes > 0 ? TimeInterval(autosaveMinutes * 60) : nil,
                        remindAfter: reminderTime,
                        reminderAlert: reminderAlert,
                        partAlert: partAlert,
                        meetingCode: meeting?.code)
                    if let code = meeting?.code { MeetingList.remember(code) }
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

    private static let reminderChoices = [5, 10, 15, 20]

    /// Seconds of audio before the reminder plays; nil = no reminder.
    private var reminderTime: TimeInterval? {
        reminderAlert != .off ? TimeInterval(reminderMinutes * 60) : nil
    }

    /// Meetings often run long, so instead of stopping on its own, the
    /// phone plays a long tone and/or buzz after the chosen number of
    /// minutes as a reminder to tap Stop. Recording keeps going.
    private var reminderPicker: some View {
        VStack(spacing: 8) {
            Text("Reminder to stop")
                .font(.subheadline.bold())
            Picker("Reminder to stop", selection: $reminderAlert) {
                ForEach(PartAlert.allCases) { Text($0 == .chime ? "Tone" : $0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if reminderAlert != .off {
                Picker("Remind me after", selection: $reminderMinutes) {
                    ForEach(Self.reminderChoices, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Text(reminderHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .font(.callout)
        .padding(.horizontal)
        .onAppear {
            // Older versions allowed any typed number of minutes.
            if !Self.reminderChoices.contains(reminderMinutes) { reminderMinutes = 10 }
        }
    }

    private var reminderHint: String {
        if reminderAlert == .off {
            return "Records until you tap Stop & Save, with no reminder."
        }
        let how = switch reminderAlert {
        case .chime: "a long tone"
        case .vibrate: "a long vibration"
        default: "a long tone and vibration"
        }
        return "Every \(reminderMinutes) min, plays \(how) to remind you to stop. Recording keeps going, and the reminder repeats, until you tap Stop & Save."
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

    /// Shown from the start of recording until everyone has agreed again,
    /// out loud, so the recording itself is proof of consent.
    private var consentReminder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Remember, nothing else gets discussed until everyone in the room gives their verbal consent to be recorded.",
                  systemImage: "person.wave.2.fill")
                .font(.callout.bold())
            Button {
                recorder.markConsent()
                withAnimation { consentOnRecording = true }
            } label: {
                Label("Everyone has agreed on the recording", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.yellow, lineWidth: 1))
        .padding(.horizontal)
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
