import AVFoundation
import AudioToolbox
import Foundation

/// Short chimes and buzzes for recording reminders, synthesized in memory so no
/// sound files are needed. They play through the speaker even while the
/// phone is locked, because the recording's audio session is active.
@MainActor
enum Chime {
    /// A long, clear tone (about 3 seconds of alternating notes) reminding
    /// the person recording that it's still on. Recording keeps going.
    static func reminder() {
        play(notes: [(880, 0), (1046.5, 0.5), (880, 1.0), (1046.5, 1.5), (880, 2.0)],
             noteLength: 1.0)
    }

    /// A long buzz (about 3 seconds) made of back-to-back vibrations, since
    /// the system vibration on its own is very short.
    static func longVibrate() {
        Task { @MainActor in
            for _ in 0..<5 {
                vibrate()
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    /// A very quiet, short tick when an autosave part is saved, so the
    /// person recording knows without interrupting the conversation.
    static func partSaved() {
        play(notes: [(1318.5, 0)], volume: 0.15, noteLength: 0.25)
    }

    /// One short buzz (iPhone). Needs haptics allowed during recording,
    /// which RecorderManager turns on.
    static func vibrate() {
#if os(iOS)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
#endif
    }

    private static var player: AVAudioPlayer?

    /// Each note is (frequency in Hz, start time in seconds).
    private static func play(notes: [(Double, Double)], volume: Float = 0.8, noteLength: Double = 0.7) {
        player = try? AVAudioPlayer(data: tone(notes: notes, noteLength: noteLength))
        player?.volume = volume
        player?.play()
    }

    /// 16-bit mono WAV of bell-like notes that fade out.
    private static func tone(notes: [(Double, Double)], noteLength: Double) -> Data {
        let sampleRate = 44_100.0
        let total = (notes.map(\.1).max() ?? 0) + noteLength
        var samples = [Double](repeating: 0, count: Int(total * sampleRate))
        for (frequency, start) in notes {
            let first = Int(start * sampleRate)
            for i in 0..<Int(noteLength * sampleRate) where first + i < samples.count {
                let t = Double(i) / sampleRate
                let attack = min(1, t / 0.005)
                let envelope = attack * exp(-t * 6)
                // Fundamental plus a quiet octave for a bell tone.
                let wave = sin(2 * .pi * frequency * t) + 0.3 * sin(4 * .pi * frequency * t)
                samples[first + i] += 0.45 * envelope * wave
            }
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                     // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)) // rate, bytes/sec
        append(UInt16(2)); append(UInt16(16))                    // block align, bits
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Double(Int16.max)))
        }
        return data
    }
}
