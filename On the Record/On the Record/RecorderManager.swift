import AVFoundation
import Combine
import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#endif

/// Audio recorder. Keeps recording through screen lock (via the `audio`
/// background mode, with iOS's mic indicator showing) until Stop/Discard,
/// and resumes automatically after interruptions such as phone calls —
/// whether the phone is locked or unlocked and in use.
///
/// With autosave on, a long session is saved as numbered parts: every
/// `autosaveInterval` the current file is saved and a new one started, so
/// each part stays short enough to transcribe in full.
///
/// Each autosave can be signalled with a quiet chime and/or a vibration
/// (`PartAlert`), so the person recording knows a part was saved without
/// interrupting the conversation.
///
/// In a shared meeting, every saved part is also uploaded to the meeting
/// so other phones recording the same meeting can build a combined
/// transcript.
///
/// With a stop limit, the session stops and saves itself once that much
/// audio has been recorded, chiming at 10 seconds left and again on stop.
/// How the phone signals that an autosave part was saved.
enum PartAlert: String, CaseIterable, Identifiable {
    case off, chime, vibrate, both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .chime: "Chime"
        case .vibrate: "Vibrate"
        case .both: "Both"
        }
    }
}

@MainActor
final class RecorderManager: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case denied
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: CGFloat = 0   // 0...1, for the meter
    /// True while the system has the mic paused (call, Siri, another app).
    @Published private(set) var isPaused = false
    /// Which part is recording now (1 until the first autosave).
    @Published private(set) var partNumber = 1
    /// Set when the session stopped itself at its time limit.
    @Published private(set) var didAutoStop = false
    /// Total audio to record before stopping; nil means no limit.
    @Published private(set) var stopLimit: TimeInterval?
    private var didWarn = false

    /// Title used for the saved parts; the session view keeps it current.
    var sessionTitle = ""
    /// Save a part after this much audio; nil means never autosave.
    private var autosaveInterval: TimeInterval?
    private var partAlert: PartAlert = .off
    /// Shared meeting the parts are uploaded to, if any.
    private(set) var meetingCode: String?
    /// Audio saved in earlier parts of this session.
    private var savedDuration: TimeInterval = 0
    /// Fallback title, fixed when the session starts so parts match.
    private var defaultSessionTitle = ""

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileName: String?
    private var startDate: Date?
    private var observers: [NSObjectProtocol] = []
    private var lastResumeAttempt = Date.distantPast
    /// Audio time spans recorded while the phone was locked.
    private var lockedSpans: [TimeSpan] = []
    private var lockedSince: TimeInterval?

    /// Requests mic permission. Returns true if granted.
    func requestPermission() async -> Bool {
#if os(iOS) || os(visionOS)
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
#else
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
#endif
    }

    func startRecording(autosaveEvery interval: TimeInterval? = nil,
                        stopAfter limit: TimeInterval? = nil,
                        partAlert: PartAlert = .off,
                        meetingCode: String? = nil) async {
        didAutoStop = false
        didWarn = false
        guard await requestPermission() else {
            state = .denied
            return
        }

#if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            // Lets the part-saved vibration through while the mic is live.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            state = .denied
            return
        }
#endif

        guard startNewFile() else {
            state = .denied
            return
        }
        autosaveInterval = interval
        self.partAlert = partAlert
        self.meetingCode = meetingCode
        stopLimit = limit
        savedDuration = 0
        partNumber = 1
        defaultSessionTitle = defaultTitle()
        startDate = Date()
        elapsed = 0
        lockedSpans = []
        lockedSince = nil
        state = .recording
        startTimer()
        observeInterruptions()
    }

    /// Creates a recorder writing to a new file and starts it.
    private func startNewFile() -> Bool {
        let fileName = "rec-\(Int(Date().timeIntervalSince1970))-\(partNumber).m4a"
        let url = Store.documentsDirectory.appendingPathComponent(fileName)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        guard let newRecorder = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        newRecorder.isMeteringEnabled = true
        guard newRecorder.record() else { return false }
        recorder = newRecorder
        currentFileName = fileName
        return true
    }

    /// Stops the current file and saves it as a Recording.
    private func saveCurrentPart(consentedBy: [String]?) -> Recording? {
        guard let recorder, let fileName = currentFileName, let startDate else { return nil }
        // Audio actually captured (excludes time paused by interruptions).
        let duration = recorder.currentTime > 0 ? recorder.currentTime : Date().timeIntervalSince(startDate)
        if let lockedSince {   // saved while still locked
            lockedSpans.append(TimeSpan(start: lockedSince, end: duration))
        }
        let spans = lockedSpans
        recorder.stop()

        let base = sessionTitle.trimmingCharacters(in: .whitespaces).isEmpty
            ? defaultSessionTitle : sessionTitle
        let isMultipart = partNumber > 1 || autosaveInterval != nil
        let recording = Recording(
            title: isMultipart ? "\(base) (Part \(partNumber))" : base,
            duration: duration,
            audioFileName: fileName,
            consentedBy: consentedBy,
            lockedSpans: spans,
            startedAt: startDate,
            meetingCode: meetingCode)
        Store.save(recording)
        savedDuration += duration
        if meetingCode != nil {
            Task { await CloudService.shared.uploadToMeeting(recording) }
        }
        return recording
    }

    /// Autosave: save this part and carry on straight into the next one.
    private func autosavePart() {
        let stillLocked = lockedSince != nil
        _ = saveCurrentPart(consentedBy: nil)
        signalPartSaved()
        partNumber += 1
        lockedSpans = []
        lockedSince = stillLocked ? 0 : nil
        startDate = Date()
        if !startNewFile() {
            // Couldn't start the next part; everything so far is saved.
            deactivateSession()
            cleanUp()
        }
    }

    private func signalPartSaved() {
        if partAlert == .chime || partAlert == .both { Chime.partSaved() }
        if partAlert == .vibrate || partAlert == .both { Chime.vibrate() }
    }

    /// Stops and returns a saved Recording (without transcript yet), or nil.
    func stopRecording(title: String, consentedBy: [String]? = nil) -> Recording? {
        sessionTitle = title
        let recording = saveCurrentPart(consentedBy: consentedBy)
        deactivateSession()
        cleanUp()
        return recording
    }

    func cancelRecording() {
        if let fileName = currentFileName {
            let url = Store.documentsDirectory.appendingPathComponent(fileName)
            recorder?.stop()
            try? FileManager.default.removeItem(at: url)
        }
        deactivateSession()
        cleanUp()
    }

    // MARK: - Private

    /// Time limit reached: save, chime, and release the mic. The audio
    /// session stays up until the chime finishes so it can be heard.
    private func autoStop() {
        _ = saveCurrentPart(consentedBy: nil)
        cleanUp()
        Chime.stopped()
        didAutoStop = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Chime.stoppedDuration))
            guard let self, self.state == .idle else { return }
            self.deactivateSession()
        }
    }

    private func deactivateSession() {
#if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    /// A phone call, Siri, alarm, or another app using the mic pauses the
    /// recorder. Resume when the interruption ends, and again whenever the
    /// app becomes active (unlocking / returning to it) in case the "ended"
    /// notice never arrives.
    private func observeInterruptions() {
#if os(iOS) || os(visionOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor [weak self] in self?.resumeIfPaused() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeIfPaused() }
        })
        // Lock/unlock. These fire when the phone has a passcode (iOS ties
        // them to data protection), which nearly every phone does.
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.phoneLocked() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.phoneUnlocked() }
        })
#endif
    }

    private func phoneLocked() {
        guard state == .recording, lockedSince == nil, let recorder else { return }
        lockedSince = recorder.currentTime
    }

    private func phoneUnlocked() {
        guard state == .recording, let start = lockedSince, let recorder else { return }
        lockedSpans.append(TimeSpan(start: start, end: recorder.currentTime))
        lockedSince = nil
    }

    /// Restarts a paused recorder, appending to the same file.
    func resumeIfPaused() {
        guard state == .recording, let recorder, !recorder.isRecording else { return }
        lastResumeAttempt = Date()
#if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(true)
#endif
        recorder.record()
        isPaused = !recorder.isRecording
    }

    private func cleanUp() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        isPaused = false
        timer?.invalidate()
        timer = nil
        recorder = nil
        currentFileName = nil
        startDate = nil
        level = 0
        lockedSpans = []
        lockedSince = nil
        autosaveInterval = nil
        partAlert = .off
        meetingCode = nil
        stopLimit = nil
        savedDuration = 0
        partNumber = 1
        sessionTitle = ""
        state = .idle
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard let recorder else { return }
        if !recorder.isRecording {
            // Paused by the system; retry about once a second.
            isPaused = true
            level = 0
            if Date().timeIntervalSince(lastResumeAttempt) > 1 { resumeIfPaused() }
            return
        }
        isPaused = false
        elapsed = savedDuration + recorder.currentTime
        if let stopLimit, elapsed >= stopLimit {
            autoStop()
            return
        }
        if let stopLimit, !didWarn, stopLimit - elapsed <= 10 {
            didWarn = true
            Chime.warning()
        }
        if let autosaveInterval, recorder.currentTime >= autosaveInterval {
            autosavePart()
            return
        }
        recorder.updateMeters()
        // Map decibels (-60...0) to 0...1.
        let power = recorder.averagePower(forChannel: 0)
        let clamped = max(-60, min(0, power))
        level = CGFloat((clamped + 60) / 60)
    }

    private func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording \(formatter.string(from: Date()))"
    }
}
