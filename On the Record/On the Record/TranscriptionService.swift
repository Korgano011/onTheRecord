import AVFoundation
import Foundation
import Speech

/// On-device transcription of a finished recording using the Speech framework.
enum TranscriptionService {
    enum TranscriptionError: LocalizedError {
        case notAuthorized
        case recognizerUnavailable
        case noSpeech
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition permission was not granted."
            case .recognizerUnavailable:
                return "Speech recognition is not available on this device right now."
            case .noSpeech:
                return "No speech detected."
            case .failed(let message):
                return message
            }
        }
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes the whole recording at `url` (or only `spans` of it).
    /// With a `chunkLength`, the audio is cut into pieces of at most that
    /// many seconds, each transcribed separately and the text joined, so long
    /// recordings aren't cut off. `progress` reports (chunk, chunk count).
    static func transcribe(url: URL,
                           spans: [TimeSpan]? = nil,
                           chunkLength: TimeInterval?,
                           progress: @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> String {
        let asset = AVURLAsset(url: url)
        let assetDuration = try await asset.load(.duration).seconds
        let ranges = spans ?? [TimeSpan(start: 0, end: assetDuration)]

        let chunks: [[TimeSpan]]
        if let chunkLength, chunkLength > 0 {
            chunks = split(ranges, every: chunkLength)
        } else if spans == nil {
            // No chunking, whole file: transcribe it directly.
            await progress(1, 1)
            do {
                return try await transcribe(url: url)
            } catch TranscriptionError.noSpeech {
                return ""
            }
        } else {
            chunks = [ranges]
        }

        var pieces: [String] = []
        for (index, chunk) in chunks.enumerated() {
            await progress(index + 1, chunks.count)
            let text = try await transcribe(url: url, spans: chunk)
            if !text.isEmpty { pieces.append(text) }
        }
        return pieces.joined(separator: " ")
    }

    /// Splits spans into groups holding at most `length` seconds of audio
    /// each, cutting spans where needed.
    private static func split(_ spans: [TimeSpan], every length: TimeInterval) -> [[TimeSpan]] {
        var chunks: [[TimeSpan]] = []
        var current: [TimeSpan] = []
        var room = length
        for span in spans.sorted(by: { $0.start < $1.start }) {
            var start = span.start
            while span.end - start > 0.01 {
                let end = min(span.end, start + room)
                current.append(TimeSpan(start: start, end: end))
                room -= end - start
                start = end
                if room <= 0.01 {
                    chunks.append(current)
                    current = []
                    room = length
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Transcribes only the given spans of the audio at `url`: they are cut
    /// out into a temporary file, transcribed, and the file deleted.
    /// Returns "" if the spans contain no audio or no speech.
    private static func transcribe(url: URL, spans: [TimeSpan]) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return "" }
        let assetDuration = try await asset.load(.duration).seconds

        let composition = AVMutableComposition()
        guard let output = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TranscriptionError.failed("Couldn’t prepare the audio.")
        }
        var cursor = CMTime.zero
        for span in spans {
            let end = min(span.end, assetDuration)
            guard end > span.start else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: span.start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600))
            try output.insertTimeRange(range, of: track, at: cursor)
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { return "" }

        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.failed("Couldn’t prepare the audio.")
        }
        let partURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: partURL) }
        try await export.export(to: partURL, as: .m4a)
        do {
            return try await transcribe(url: partURL)
        } catch TranscriptionError.noSpeech {
            // A silent stretch shouldn't fail the whole transcript.
            return ""
        }
    }

    /// Transcribes the audio at `url` entirely on device, so audio never
    /// leaves the phone. Uses SpeechAnalyzer, which handles long audio and
    /// pauses; falls back to SFSpeechRecognizer if it isn't available.
    static func transcribe(url: URL) async throws -> String {
        guard await requestAuthorization() else {
            throw TranscriptionError.notAuthorized
        }
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return try await analyze(url: url, locale: locale)
        }
        return try await recognize(url: url)
    }

    private static func analyze(url: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // First use downloads the on-device language model.
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        let collect = Task {
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { pieces.append(text) }
            }
            return pieces.joined(separator: " ")
        }
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            throw TranscriptionError.failed(error.localizedDescription)
        }
        return try await collect.value
    }

    /// Older recognizer. On device it restarts after each pause and its final
    /// result holds only the last stretch, so every finished stretch is kept
    /// as it arrives.
    private static func recognize(url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = true
        // Insert periods, commas, and question marks automatically.
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var finished: [String] = []
            var current = ""
            func heard() -> String {
                (finished + [current]).filter { !$0.isEmpty }.joined(separator: " ")
            }
            recognizer.recognitionTask(with: request) { result, error in
                guard !didResume else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.speechRecognitionMetadata != nil || result.isFinal {
                        // A stretch of speech is done.
                        if !text.isEmpty, text != finished.last { finished.append(text) }
                        current = ""
                    } else {
                        current = text
                    }
                    if result.isFinal {
                        didResume = true
                        continuation.resume(returning: heard())
                        return
                    }
                }
                if let error {
                    didResume = true
                    let text = heard()
                    let nsError = error as NSError
                    // 1110: the recognizer heard no (more) speech.
                    if !text.isEmpty || (nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110) {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                    }
                }
            }
        }
    }
}
