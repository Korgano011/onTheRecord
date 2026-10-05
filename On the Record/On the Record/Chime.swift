import AVFoundation
import Foundation

/// Short chimes for the recording time limit, synthesized in memory so no
/// sound files are needed. They play through the speaker even while the
/// phone is locked, because the recording's audio session is active.
@MainActor
enum Chime {
    /// One soft ping: 10 seconds left.
    static func warning() {
        play(notes: [(880, 0)])
    }

    /// Falling two-note chime: recording stopped and saved.
    static func stopped() {
        play(notes: [(1046.5, 0), (784, 0.22)])
    }

    /// Length of the stop chime, so the audio session stays up until it ends.
    static let stoppedDuration: TimeInterval = 1.0

    private static var player: AVAudioPlayer?

    /// Each note is (frequency in Hz, start time in seconds).
    private static func play(notes: [(Double, Double)]) {
        player = try? AVAudioPlayer(data: tone(notes: notes))
        player?.volume = 0.8
        player?.play()
    }

    /// 16-bit mono WAV of bell-like notes that fade out.
    private static func tone(notes: [(Double, Double)]) -> Data {
        let sampleRate = 44_100.0
        let noteLength = 0.7
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
