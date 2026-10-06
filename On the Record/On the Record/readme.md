# On the Record

A verbal-agreement app for iOS: people meet, agree out loud, and the
conversation is recorded (with everyone's consent), transcribed, and
published as a verbal agreement to a public repository where anyone —
including lawyers — can read it, comment, and judge whether it is right,
wrong, or illegal. Recording is one part of that larger flow.

## What it does

- **Record with consent.** Every recording starts behind a consent gate: you confirm that everyone present has agreed to be recorded before the mic turns on.
- **Always visible.** While recording, a red "RECORDING" banner with a pulsing dot stays on screen. Recording keeps running when the screen locks (via the `audio` background mode), and iOS shows its orange mic indicator and an active-recording lock screen the whole time. It stops only when you tap Stop or Discard — there is no hidden capture.
- **Durable, accessible storage.** Recordings are saved as `.m4a` files in the app's Documents directory (exposed via the Files app), each with a sibling `.json` holding its title, date, duration, and transcript.
- **On-device transcription.** Tapping "Transcribe" uses Apple's Speech framework with on-device recognition, so audio stays on the phone.
- **Part signal.** With autosave on, each saved part can be signalled by a very quiet chime, a short vibration, both, or nothing (ready screen).
- **Shared meetings.** One phone starts a meeting (6-character code), others join it. Every phone records and uploads each saved part to iCloud. The Meetings tab downloads every phone's audio, transcribes each into timed words with confidence, and cross-checks them: words the phones agree on stand, stretches only one phone heard (a far-end speaker) are filled in, and where they heard different words the more confident one is used — the alternative is shown so it can be picked instead. The combined transcript can also be edited by hand.
- **Agreements.** Publish from a recording or a meeting: title, kind (with fill-in templates), parties, terms, optional transcript text (never audio), and confirmation that every party agreed to the terms and to publishing. The Agreements tab lists them with search; each has Right / Wrong / Illegal verdicts (one per person), comments, Report, and Hide-this-person (required by App Review for user-generated content). Community rules are accepted once before posting.
- **Export.** Share the audio file or the transcript text via the standard share sheet.

## Structure

- `MyApp.swift` — app entry point.
- `ContentView.swift` — tabs (Recordings, Meetings, Agreements) + recordings list.
- `MeetingsView.swift` — shared meetings and the combined transcript.
- `AgreementsView.swift` — repository, agreement detail (verdicts, comments, reports), composer + templates, community rules.
- `CloudService.swift` — CloudKit public database: meetings, audio uploads, agreements, comments, verdicts, reports.
- `TranscriptMerger.swift` — cross-checks transcripts from several phones.
- `Chime.swift` — synthesized chimes + part-saved vibration.
- `ConsentView.swift` — pre-recording consent gate.
- `RecordingSessionView.swift` — active recording screen with the persistent indicator.
- `RecordingDetailView.swift` — playback, transcription, and export.
- `RecorderManager.swift` — foreground `AVAudioRecorder` wrapper.
- `TranscriptionService.swift` — on-device Speech transcription.
- `Recording.swift` — model + file-based `Store`.

## iCloud setup (needed for Meetings and Agreements)

1. iCloud needs a **paid** Apple Developer account (personal/free teams can't use it). With one: give the target a real bundle identifier, add Signing & Capabilities → iCloud → CloudKit with container `iCloud.<bundle id>` (or set Code Signing Entitlements to `On the Record.entitlements`), and set `CloudKitEnabled` to YES in `Info.plist`. Until then Meetings and Agreements show a message instead of working; recording and transcription are unaffected.
2. Run once and create a meeting, upload, publish, comment, and vote, so the record types (Meeting, MeetingAudio, Agreement, Comment, Verdict, Report) appear in the CloudKit Dashboard's Development environment.
3. In the Dashboard add indexes: `MeetingAudio.meetingCode` Queryable; `Agreement.recordName` Queryable and `Agreement.publishedAt` Sortable; `Comment.agreement` Queryable and `Comment.createdAt` Sortable; `Verdict.agreement` Queryable.
4. Deploy the schema to Production before submitting to the App Store, and check the Report records regularly (App Review expects reported content to be acted on within 24 hours).

## Note on the law

Recording people without their consent is illegal in many places (several US
states require all parties to agree, and other countries have similar rules).
This app is built for recordings everyone involved knows about and agrees to.
