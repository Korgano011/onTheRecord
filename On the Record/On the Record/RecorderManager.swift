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
/// With a reminder set, the phone plays a long tone and/or long vibration
/// each time that much more audio has been recorded, so the person
/// recording remembers to stop. Recording keeps going until Stop is pressed.
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
    /// Total audio recorded when the next reminder plays; nil means no reminder.
    @Published private(set) var reminderAt: TimeInterval?
    /// Set once the first reminder has played.
    @Published private(set) var didRemind = false
    /// Time between reminders; they repeat until Stop.
    private var reminderInterval: TimeInterval?
    private var reminderAlert: PartAlert = .off

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
    /// Consent confirmed on the recording, waiting to be saved with the
    /// current part.
    private var pendingConsent: (audioTime: TimeInterval, date: Date)?
    /// Ties this session's parts together into one folder in the list.
    private var sessionID = UUID()
    /// Documents subfolder holding this session's file(s).
    private var sessionFolder: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileName: String?
    private var startDate: Date?
    private var observers: [NSObjectProtocol] = []
    private var lastResumeAttempt = Date.distantPast
    /// Audio time spans recorded while the phone was locked.
    private var lockedSpans: [TimeSpan] = []
    private var lockedSince: TimeInterval?
    /// When the app last left the screen (screen off or another app).
    /// iOS only reports the lock once data protection kicks in, which can
    /// be ~10 s after the screen goes off, so the lock is backdated to this.
    private var backgroundedAt: TimeInterval?

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
                        remindAfter reminder: TimeInterval? = nil,
                        reminderAlert: PartAlert = .off,
                        partAlert: PartAlert = .off,
                        meetingCode: String? = nil) async {
        didRemind = false
        guard await requestPermission() else {
            state = .denied
            return
        }

#if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            // Lets the part-saved and reminder vibrations through while the mic is live.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            state = .denied
            return
        }
#endif

        partNumber = 1
        defaultSessionTitle = defaultTitle()
        sessionID = UUID()
        autosaveInterval = interval
        // Each session gets its own folder, visible in the Files app.
        let title = sessionTitle.trimmingCharacters(in: .whitespaces)
        sessionFolder = Store.makeSessionFolder(named: title.isEmpty ? defaultSessionTitle : title)
        guard startNewFile() else {
            if let sessionFolder {
                Store.removeFolderIfEmpty(Store.documentsDirectory.appendingPathComponent(sessionFolder))
            }
            state = .denied
            return
        }
        self.partAlert = partAlert
        self.meetingCode = meetingCode
        reminderInterval = reminderAlert == .off ? nil : reminder
        reminderAt = reminderInterval
        self.reminderAlert = reminderAlert
        savedDuration = 0
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
        let name = autosaveInterval == nil ? Store.singleFileName : Store.partFileName(partNumber)
        let fileName = sessionFolder.map { $0 + "/" + name }
            ?? "rec-\(Int(Date().timeIntervalSince1970))-\(partNumber).m4a"
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
        var recording = Recording(
            title: isMultipart ? "\(base) (Part \(partNumber))" : base,
            duration: duration,
            audioFileName: fileName,
            consentedBy: consentedBy,
            lockedSpans: spans,
            startedAt: startDate,
            meetingCode: meetingCode,
            sessionID: sessionID,
            partNumber: isMultipart ? partNumber : nil)
        if let pendingConsent {
            recording.consentAudioTime = min(pendingConsent.audioTime, duration)
            recording.consentDate = pendingConsent.date
            self.pendingConsent = nil
        }
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
        if backgroundedAt != nil { backgroundedAt = 0 }
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

    /// Everyone has given verbal consent on the recording; saved with the
    /// part being recorded now.
    func markConsent() {
        guard state == .recording, let recorder else { return }
        pendingConsent = (recorder.currentTime, Date())
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
            Store.removeFolderIfEmpty(url.deletingLastPathComponent())
        }
        deactivateSession()
        cleanUp()
    }

    // MARK: - Private

    /// Reminder time reached: long tone and/or long buzz, then schedule the
    /// next one. Recording carries on.
    private func remind() {
        didRemind = true
        if let reminderAt, let reminderInterval { self.reminderAt = reminderAt + reminderInterval }
        if reminderAlert == .chime || reminderAlert == .both { Chime.reminder() }
        if reminderAlert == .vibrate || reminderAlert == .both { Chime.longVibrate() }
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
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder else { return }
                self.backgroundedAt = recorder.currentTime
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.backgroundedAt = nil }
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
        // Backdate to when the screen went off, but by no more than 15 s,
        // in case the app was left for another app well before locking.
        let now = recorder.currentTime
        lockedSince = max(min(backgroundedAt ?? now, now), now - 15, 0)
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
        backgroundedAt = nil
        pendingConsent = nil
        autosaveInterval = nil
        partAlert = .off
        meetingCode = nil
        reminderAt = nil
        reminderInterval = nil
        reminderAlert = .off
        savedDuration = 0
        partNumber = 1
        sessionFolder = nil
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
        if let reminderAt, elapsed >= reminderAt {
            remind()
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
