import Foundation
import Accelerate

/// Detects the timing offset between two audio files using cross-correlation,
/// so the null test can align them before subtracting — instead of naively
/// assuming they start at exactly the same sample (which lossy encoders like
/// LAME MP3 can violate by a few hundred samples of "encoder delay").
enum AudioAligner {

    /// Returns the offset (in seconds) needed to align fileB to fileA.
    /// Positive = fileB's audio starts later than fileA's (trim the start of B).
    /// Negative = fileA's audio starts later than fileB's (trim the start of A).
    static func detectOffsetSeconds(ffmpegPath: String, fileA: URL, fileB: URL) async throws -> Double {
        let sampleRate: Double = 8000   // coarse but fast; resolution ~0.125ms
        let analyzeSeconds: Double = 20 // only need a representative excerpt

        async let samplesATask = extractMonoPCM(ffmpegPath: ffmpegPath, file: fileA, sampleRate: sampleRate, seconds: analyzeSeconds)
        async let samplesBTask = extractMonoPCM(ffmpegPath: ffmpegPath, file: fileB, sampleRate: sampleRate, seconds: analyzeSeconds)
        let (samplesA, samplesB) = try await (samplesATask, samplesBTask)

        guard !samplesA.isEmpty, !samplesB.isEmpty else { return 0 }

        let maxLagSeconds = 0.5 // search up to +/-500ms of drift
        let maxLagSamples = Int(maxLagSeconds * sampleRate)
        let lagSamples = bestLag(samplesA, samplesB, maxLag: maxLagSamples)

        return Double(lagSamples) / sampleRate
    }

    /// Decodes a short, heavily-downsampled mono excerpt via ffmpeg, piped
    /// directly to memory (no temp file needed).
    private static func extractMonoPCM(ffmpegPath: String, file: URL, sampleRate: Double, seconds: Double) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffmpegPath)
            task.arguments = [
                "-i", file.path,
                "-t", "\(seconds)",
                "-ac", "1",
                "-ar", "\(Int(sampleRate))",
                "-f", "f32le",
                "-"
            ]
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            let collector = PCMCollector()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { collector.append(chunk) }
            }

            task.terminationHandler = { process in
                outPipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    continuation.resume(returning: collector.floats)
                } else {
                    continuation.resume(throwing: AppError.conversionFailed("Could not decode audio for alignment detection"))
                }
            }

            do { try task.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// Finds the lag (in samples) that maximizes correlation between a and b,
    /// via a direct dot-product search over the candidate lag range using
    /// Accelerate's vDSP for speed. Returns the lag d such that b[t] best
    /// matches a[t - d] — i.e., d is how much later b's content appears.
    private static func bestLag(_ a: [Float], _ b: [Float], maxLag: Int) -> Int {
        let n = min(a.count, b.count)
        guard n > maxLag * 2 + 1000 else { return 0 }

        // Analyze a window from the middle of the clip, avoiding any silence/fade at the very start.
        let windowSize = min(n - 2 * maxLag, 40_000)
        guard windowSize > 0 else { return 0 }
        let start = max(maxLag, (n - windowSize) / 2)
        let aWindow = Array(a[start..<min(start + windowSize, a.count)])

        var bestLagValue = 0
        var bestScore: Float = -Float.greatestFiniteMagnitude

        for lag in stride(from: -maxLag, through: maxLag, by: 1) {
            let bStart = start + lag
            guard bStart >= 0, bStart + aWindow.count <= b.count else { continue }
            let bWindow = Array(b[bStart..<bStart + aWindow.count])

            var dot: Float = 0
            vDSP_dotpr(aWindow, 1, bWindow, 1, &dot, vDSP_Length(aWindow.count))

            if dot > bestScore {
                bestScore = dot
                bestLagValue = lag
            }
        }
        return bestLagValue
    }
}

/// Thread-safe accumulator for PCM bytes streamed from ffmpeg's stdout pipe.
private final class PCMCollector: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var data = Data()

    nonisolated func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    nonisolated var floats: [Float] {
        lock.lock(); defer { lock.unlock() }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}
