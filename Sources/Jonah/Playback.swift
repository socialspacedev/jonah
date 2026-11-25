import AVFoundation
import Foundation

/// What Jonah measures in a song to improve how the iPod plays it: how loud it is,
/// for the iPod's Sound Check setting, and where the sound starts and stops, so the
/// silence either side can be skipped with the song's start and stop times.
struct SongMeasurement: Codable, Equatable, Sendable {
    /// Integrated loudness (EBU R128), in LUFS.
    var loudness: Double
    /// Highest sample, 1 = full scale.
    var peak: Double
    /// Where to start and stop playing, in ms; 0 means the file's own start or end.
    var startMs: Int
    var stopMs: Int
    /// The file's size, so a measurement is never applied to a different file
    /// that later takes the same name on the iPod.
    var size: Int
}

enum Playback {
    /// The loudness Sound Check levels songs to. Chosen to match the values iTunes
    /// wrote for the songs already on the iPod (the median over a sample of 33), so
    /// new songs sit level with them.
    static let targetLoudness = -15.5

    /// Quieter than this counts as silence.
    static let silence = 0.001                           // -60 dBFS
    /// Shorter silences are part of the song and left alone.
    static let shortestTrim = 0.25
    /// Kept before the first sound and after the last, so nothing audible is clipped.
    static let leadIn = 0.05, tailOut = 0.1

    /// Decodes the whole file. Nil if it can't be decoded (a copy-protected song, say)
    /// or is silent throughout.
    static func measure(_ url: URL) -> SongMeasurement? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard rate > 0, channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { return nil }

        var filters = (0..<channels).map { _ in KWeighting(sampleRate: rate) }
        let subLength = Int(rate / 10)                    // 100 ms, a quarter of a gating block
        let peakLength = Int(rate / 100)                  // 10 ms, for finding silence
        var subBlocks: [Double] = []
        var peaks: [Float] = []
        var subSum = 0.0, subCount = 0
        var windowPeak: Float = 0, windowCount = 0
        var peak: Float = 0

        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch {
                // MP3 lengths are estimates, often one frame too long, so the last read
                // can fail. Anywhere earlier, the end is unknown and a trim could cut music.
                if file.length - file.framePosition < AVAudioFramePosition(rate) { break }
                return nil
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<frames {
                var energy = 0.0
                var loudest: Float = 0
                for c in 0..<channels {
                    let s = data[c][i]
                    loudest = max(loudest, abs(s))
                    let w = filters[c].process(Double(s))
                    energy += w * w
                }
                subSum += energy
                subCount += 1
                if subCount == subLength {
                    subBlocks.append(subSum / Double(subLength))
                    (subSum, subCount) = (0, 0)
                }
                windowPeak = max(windowPeak, loudest)
                windowCount += 1
                if windowCount == peakLength {
                    peaks.append(windowPeak)
                    peak = max(peak, windowPeak)
                    (windowPeak, windowCount) = (0, 0)
                }
            }
        }
        if windowCount > 0 {
            peaks.append(windowPeak)
            peak = max(peak, windowPeak)
        }
        guard let loudness = integratedLoudness(subBlocks) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let (start, stop) = trim(peaks, window: 0.01)
        return SongMeasurement(loudness: loudness, peak: Double(peak), startMs: start, stopMs: stop, size: size)
    }

    /// ITU-R BS.1770: 400 ms blocks overlapping by 75%, an absolute gate at -70 LUFS,
    /// then a relative gate 10 LU below the loudness of what passed the first.
    static func integratedLoudness(_ subBlocks: [Double]) -> Double? {
        guard subBlocks.count >= 4 else { return nil }
        let blocks = (0...(subBlocks.count - 4)).map { subBlocks[$0..<$0 + 4].reduce(0, +) / 4 }
        func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(e) }
        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        let audible = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let gate = lufs(mean(audible)) - 10
        let kept = audible.filter { lufs($0) > gate }
        return lufs(mean(kept))
    }

    /// Start and stop times in ms from per-window peaks; 0 where there's nothing worth trimming.
    static func trim(_ peaks: [Float], window: Double) -> (startMs: Int, stopMs: Int) {
        guard let first = peaks.firstIndex(where: { Double($0) > silence }),
              let last = peaks.lastIndex(where: { Double($0) > silence }) else { return (0, 0) }
        let length = Double(peaks.count) * window
        let soundStart = Double(first) * window
        let soundEnd = Double(last + 1) * window
        let start = soundStart >= shortestTrim ? soundStart - leadIn : 0
        let stop = length - soundEnd >= shortestTrim ? soundEnd + tailOut : 0
        return (Int((start * 1000).rounded()), Int((stop * 1000).rounded()))
    }

    /// The iTunesDB's Sound Check value: 1000 × 10^(−gain/10), with the gain in dB.
    /// Boosts are held back so the song's loudest sample doesn't clip.
    static func soundCheck(_ m: SongMeasurement) -> Int {
        var gain = targetLoudness - m.loudness
        if m.peak > 0 { gain = min(gain, -20 * log10(m.peak)) }
        return Int((1000 * pow(10, -gain / 10)).rounded())
    }
}

/// The two-stage K-weighting filter from ITU-R BS.1770, for any sample rate
/// (coefficients as libebur128 derives them).
private struct KWeighting {
    // Plain numbers rather than arrays: this runs for every sample of every song.
    private let b0, b1, b2, a1, a2: Double      // shelf
    private let ra1, ra2: Double                 // high-pass (its b is 1, −2, 1)
    // Each stage's last two inputs and outputs; the shelf's output is the high-pass's input.
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    init(sampleRate fs: Double) {
        var f0 = 1681.974450955533, q = 0.7071752369554196
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        b0 = (vh + vb * k / q + k * k) / a0
        b1 = 2 * (k * k - vh) / a0
        b2 = (vh - vb * k / q + k * k) / a0
        a1 = 2 * (k * k - 1) / a0
        a2 = (1 - k / q + k * k) / a0
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        let r0 = 1 + k / q + k * k
        ra1 = 2 * (k * k - 1) / r0
        ra2 = (1 - k / q + k * k) / r0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        let z = y - 2 * y1 + y2 - ra1 * z1 - ra2 * z2
        (x2, x1, y2, y1, z2, z1) = (x1, x, y1, y, z1, z)
        return z
    }
}
