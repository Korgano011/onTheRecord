# On the Record

A consensual audio recorder and on-device transcriber for iOS.

## What it does

- **Record with consent.** Every recording starts behind a consent gate: you confirm that everyone present has agreed to be recorded before the mic turns on.
- **Always visible.** While recording, a red "RECORDING" banner with a pulsing dot stays on screen. Recording keeps running when the screen locks (via the `audio` background mode), and iOS shows its orange mic indicator and an active-recording lock screen the whole time. It stops only when you tap Stop or Discard — there is no hidden capture.
- **Durable, accessible storage.** Recordings are saved as `.m4a` files in the app's Documents directory (exposed via the Files app), each with a sibling `.json` holding its title, date, duration, and transcript.
- **On-device transcription.** Tapping "Transcribe" uses Apple's Speech framework with on-device recognition, so audio stays on the phone.
- **Export.** Share the audio file or the transcript text via the standard share sheet.

## Structure

- `MyApp.swift` — app entry point.
- `ContentView.swift` — recordings list + entry point for a new recording.
- `ConsentView.swift` — pre-recording consent gate.
- `RecordingSessionView.swift` — active recording screen with the persistent indicator.
- `RecordingDetailView.swift` — playback, transcription, and export.
- `RecorderManager.swift` — foreground `AVAudioRecorder` wrapper.
- `TranscriptionService.swift` — on-device Speech transcription.
- `Recording.swift` — model + file-based `Store`.

## Note on the law

Recording people without their consent is illegal in many places (several US
states require all parties to agree, and other countries have similar rules).
This app is built for recordings everyone involved knows about and agrees to.
