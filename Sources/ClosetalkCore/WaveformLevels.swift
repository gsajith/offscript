import Foundation

/// The recording island's bars: the microphone's recent loudness, oldest first, each 0...1.
public struct WaveformLevels: Equatable {
    public private(set) var values: [Double]

    public init(count: Int = 12) {
        values = Array(repeating: 0, count: count)
    }

    /// Adds the loudness of the latest chunk of audio and drops the oldest bar.
    public mutating func append(rms: Float) {
        values.removeFirst()
        values.append(Self.level(rms: rms))
    }

    /// Loudness on a decibel scale, which matches how loud speech sounds: -50 dB and quieter is a flat
    /// bar, -10 dB and louder is a full one.
    public static func level(rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(Double(rms))
        return min(max((decibels + 50) / 40, 0), 1)
    }
}
