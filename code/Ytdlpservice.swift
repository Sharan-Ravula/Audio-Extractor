import Foundation

/// Wraps calls to the `yt-dlp` and `ffmpeg` command-line tools.
/// Requires: brew install yt-dlp ffmpeg
final class YTDLPService {

    private let ytdlpPath: String
    private let ffmpegPath: String

    init() throws {
        guard let ytdlp = Self.which("yt-dlp") else { throw AppError.ytdlpNotFound }
        guard let ffmpeg = Self.which("ffmpeg") else { throw AppError.ffmpegNotFound }
        self.ytdlpPath = ytdlp
        self.ffmpegPath = ffmpeg
    }

    private static func which(_ tool: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [tool]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result?.isEmpty == false) ? result : nil
    }

    // MARK: - Fetch metadata

    /// Runs `yt-dlp -J <url>`. yt-dlp prints its extraction progress
    /// ("[youtube] Downloading webpage" etc.) to stderr, which we surface
    /// live via onStatus so the UI isn't just a blank spinner.
    func fetchInfo(url: String, onStatus: @escaping @Sendable (String) -> Void) async throws -> VideoInfo {
        onStatus("Starting yt-dlp…")
        let json = try await runStreaming(
            executable: ytdlpPath,
            args: ["-J", "--no-warnings", "--no-playlist", url],
            onStdout: nil,
            onStderr: { line in onStatus(line) }
        )

        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.metadataFetchFailed("Could not parse yt-dlp output")
        }

        let title = obj["title"] as? String ?? "Unknown title"
        let duration = obj["duration"] as? Double ?? 0
        let thumbnail = obj["thumbnail"] as? String

        var bestBitrate: Double? = nil
        var bestCodec: String? = nil
        var bestExt: String? = nil

        if let formats = obj["formats"] as? [[String: Any]] {
            let audioOnly = formats.filter { ($0["vcodec"] as? String) == "none" }
            if let best = audioOnly.max(by: { (a, b) in
                (a["abr"] as? Double ?? 0) < (b["abr"] as? Double ?? 0)
            }) {
                bestBitrate = best["abr"] as? Double
                bestCodec = best["acodec"] as? String
                bestExt = best["ext"] as? String
            }
        }

        return VideoInfo(
            title: title,
            durationSeconds: duration,
            sourceBitrateKbps: bestBitrate,
            sourceCodec: bestCodec,
            sourceExt: bestExt,
            thumbnailURL: thumbnail
        )
    }

    // MARK: - Download + convert

    /// Downloads best audio, then converts. Reports live status text and a
    /// 0.0–1.0 overall progress value (0–0.5 = downloading, 0.5–1.0 = converting).
    func downloadAudio(
        url: String,
        format: AudioFormat,
        outputDirectory: URL,
        baseName: String,
        totalDurationSeconds: Double,
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> DownloadResult {
        let startTime = Date()

        let rawDownloadPath = outputDirectory.appendingPathComponent("\(baseName)_raw.%(ext)s").path
        onStatus("Downloading best audio stream…")
        onProgress(0)

        _ = try await runStreaming(
            executable: ytdlpPath,
            args: ["-f", "bestaudio", "--no-playlist", "--newline", "-o", rawDownloadPath, url],
            onStdout: { line in
                onStatus(line)
                if let pct = Self.parseYTDLPPercent(line) {
                    onProgress(pct * 0.5)
                }
            },
            onStderr: { line in onStatus(line) }
        )

        onProgress(0.5)

        let dirContents = try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
        guard let rawFile = dirContents.first(where: { $0.lastPathComponent.hasPrefix("\(baseName)_raw") }) else {
            throw AppError.downloadFailed("Downloaded file not found on disk")
        }

        // .original: no ffmpeg pass at all — just place the exact file yt-dlp
        // downloaded at the final path, keeping whatever extension YouTube's
        // stream actually was (e.g. .webm for Opus, .m4a for AAC).
        if format == .original {
            onProgress(0.9)
            let originalExt = rawFile.pathExtension
            let finalPath = outputDirectory.appendingPathComponent("\(baseName).\(originalExt)")
            if FileManager.default.fileExists(atPath: finalPath.path) {
                try FileManager.default.removeItem(at: finalPath)
            }
            try FileManager.default.moveItem(at: rawFile, to: finalPath)
            onProgress(1.0)

            let attrs = try FileManager.default.attributesOfItem(atPath: finalPath.path)
            let size = attrs[.size] as? Int64 ?? 0
            return DownloadResult(
                outputURL: finalPath,
                format: format,
                processingTime: Date().timeIntervalSince(startTime),
                fileSizeBytes: size
            )
        }

        let outputPath = outputDirectory.appendingPathComponent("\(baseName).\(format.rawValue)").path
        var args = ["-y", "-i", rawFile.path]
        args += format.ffmpegArgs(outputPath: outputPath)

        onStatus("Converting to \(format.rawValue.uppercased())…")
        _ = try await runStreaming(
            executable: ffmpegPath,
            args: args,
            onStdout: nil,
            onStderr: { line in
                onStatus(line)
                if totalDurationSeconds > 0, let elapsed = Self.parseFFmpegElapsedSeconds(line) {
                    let pct = min(elapsed / totalDurationSeconds, 1.0)
                    onProgress(0.5 + pct * 0.5)
                }
            }
        )

        onProgress(1.0)
        try? FileManager.default.removeItem(at: rawFile)

        let attrs = try FileManager.default.attributesOfItem(atPath: outputPath)
        let size = attrs[.size] as? Int64 ?? 0

        return DownloadResult(
            outputURL: URL(fileURLWithPath: outputPath),
            format: format,
            processingTime: Date().timeIntervalSince(startTime),
            fileSizeBytes: size
        )
    }

    // MARK: - Progress parsing

    /// Parses lines like "[download]  45.2% of 3.45MiB at 1.23MiB/s ETA 00:02"
    private static func parseYTDLPPercent(_ line: String) -> Double? {
        guard line.contains("[download]") else { return nil }
        guard let range = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) else { return nil }
        let match = String(line[range]).dropLast() // remove trailing %
        return Double(match).map { $0 / 100.0 }
    }

    /// Parses ffmpeg's "time=00:01:23.45" progress lines into seconds.
    private static func parseFFmpegElapsedSeconds(_ line: String) -> Double? {
        guard let range = line.range(of: #"time=(\d\d):(\d\d):(\d\d\.\d\d)"#, options: .regularExpression) else { return nil }
        let match = String(line[range]) // "time=HH:MM:SS.ss"
        let timeStr = match.replacingOccurrences(of: "time=", with: "")
        let parts = timeStr.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    // MARK: - Format comparison (null test)

    /// Compares two audio files objectively via an audio "null test":
    /// detects any timing offset between them (cross-correlation), aligns
    /// them, subtracts one from the other, and measures the loudness of
    /// what's left. Very negative dB means the files are nearly identical;
    /// closer to 0 dB means a real, measurable difference.
    func compareAudio(
        fileA: URL,
        fileB: URL,
        outputDirectory: URL,
        baseName: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> (rmsDB: Double?, peakDB: Double?, detectedOffsetSeconds: Double) {
        onStatus("Detecting timing offset between files…")
        let offsetSeconds = (try? await AudioAligner.detectOffsetSeconds(ffmpegPath: ffmpegPath, fileA: fileA, fileB: fileB)) ?? 0
        let offsetMs = offsetSeconds * 1000
        onStatus(String(format: "Detected offset: %.2f ms — aligning before comparison…", offsetMs))

        let alignFilter = Self.buildAlignFilter(offsetSeconds: offsetSeconds)

        onStatus("Running null-test comparison…")
        var rmsDB: Double?
        var peakDB: Double?
        _ = try await runStreaming(
            executable: ffmpegPath,
            args: ["-i", fileA.path, "-i", fileB.path, "-filter_complex", alignFilter + ",astats", "-f", "null", "-"],
            onStdout: nil,
            onStderr: { line in
                onStatus(line)
                // astats prints RMS/Peak level dB per-channel, then an "Overall"
                // section last — we keep overwriting so the final value is Overall's.
                if line.contains("RMS level dB:"), let v = Self.parseTrailingDouble(line) {
                    rmsDB = v
                }
                if line.contains("Peak level dB:"), let v = Self.parseTrailingDouble(line) {
                    peakDB = v
                }
            }
        )

        return (rmsDB, peakDB, offsetSeconds)
    }

    /// Builds the alignment + diff filter graph, trimming whichever file
    /// starts later by the detected offset so the subtraction is comparing
    /// the same moment in time on both sides.
    private static func buildAlignFilter(offsetSeconds: Double) -> String {
        let epsilon = 0.0005 // ignore sub-0.5ms offsets — not worth trimming for
        var trimA = ""
        var trimB = ""
        if offsetSeconds > epsilon {
            // B's content starts later than A's — trim B's head to match.
            trimB = "atrim=start=\(offsetSeconds),asetpts=PTS-STARTPTS,"
        } else if offsetSeconds < -epsilon {
            // A's content starts later than B's — trim A's head to match.
            trimA = "atrim=start=\(-offsetSeconds),asetpts=PTS-STARTPTS,"
        }
        return "[0:a]\(trimA)aresample=48000,aformat=channel_layouts=stereo[a0];" +
               "[1:a]\(trimB)aresample=48000,aformat=channel_layouts=stereo[a1];" +
               "[a0][a1]amix=inputs=2:duration=shortest:weights=1 -1:normalize=0"
    }

    private static func parseTrailingDouble(_ line: String) -> Double? {
        guard let colonRange = line.range(of: ":", options: .backwards) else { return nil }
        let numberPart = line[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
        return Double(numberPart)
    }

    // MARK: - Process helper (live line streaming)

    @discardableResult
    private func runStreaming(
        executable: String,
        args: [String],
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe

            let buffer = OutputBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                buffer.appendStdout(chunk)
                for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where !line.isEmpty {
                    onStdout?(String(line))
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where !line.isEmpty {
                    buffer.setLastStderr(String(line))
                    onStderr?(String(line))
                }
            }

            task.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    continuation.resume(returning: buffer.stdout)
                } else {
                    let last = buffer.lastStderr
                    let msg = last.isEmpty ? "Unknown error (exit \(process.terminationStatus))" : last
                    continuation.resume(throwing: AppError.downloadFailed(msg))
                }
            }

            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Thread-safe accumulator for output captured from Process's readabilityHandler,
/// which fires on a background queue. Swift 6 strict concurrency requires shared
/// mutable state crossing concurrency domains to be protected like this.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _stdout = ""
    private nonisolated(unsafe) var _lastStderr = ""

    nonisolated func appendStdout(_ s: String) {
        lock.lock(); _stdout += s; lock.unlock()
    }

    nonisolated func setLastStderr(_ s: String) {
        lock.lock(); _lastStderr = s; lock.unlock()
    }

    nonisolated var stdout: String {
        lock.lock(); defer { lock.unlock() }
        return _stdout
    }

    nonisolated var lastStderr: String {
        lock.lock(); defer { lock.unlock() }
        return _lastStderr
    }
}
