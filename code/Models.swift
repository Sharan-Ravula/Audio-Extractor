import Foundation

// MARK: - Audio format options

enum AudioFormat: String, CaseIterable, Identifiable {
    case original = "original" // no re-encode — saves exactly what YouTube served
    case wav = "wav"
    case flac = "flac"
    case mp3 = "mp3"
    case m4a = "m4a"   // AAC in an .m4a container — the sane choice if you wanted ".mov"-style audio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "Original (no re-encode)"
        case .wav: return "WAV (lossless, uncompressed)"
        case .flac: return "FLAC (lossless, compressed)"
        case .mp3: return "MP3 (320kbps)"
        case .m4a: return "M4A / AAC (QuickTime-native)"
        }
    }

    var isLossless: Bool {
        self == .original || self == .wav || self == .flac
    }

    /// ffmpeg arguments for this output format. Not used for .original,
    /// which is handled as a plain file copy/rename in YTDLPService.
    func ffmpegArgs(outputPath: String) -> [String] {
        switch self {
        case .original:
            return [] // unused — see downloadAudio's special-case branch
        case .wav:
            return ["-vn", "-acodec", "pcm_s16le", "-ar", "48000", outputPath]
        case .flac:
            return ["-vn", "-acodec", "flac", "-compression_level", "8", outputPath]
        case .mp3:
            return ["-vn", "-acodec", "libmp3lame", "-b:a", "320k", outputPath]
        case .m4a:
            // Try to just remux (copy) if source is already AAC — falls back to re-encode if that fails
            return ["-vn", "-acodec", "aac", "-b:a", "256k", outputPath]
        }
    }
}

// MARK: - Video metadata (parsed from yt-dlp -J output)

struct VideoInfo: Identifiable {
    let id = UUID()
    let title: String
    let durationSeconds: Double
    let sourceBitrateKbps: Double?     // best available audio-only stream bitrate
    let sourceCodec: String?           // e.g. "opus", "aac"
    let sourceExt: String?             // e.g. "webm", "m4a"
    let thumbnailURL: String?

    var durationFormatted: String {
        let mins = Int(durationSeconds) / 60
        let secs = Int(durationSeconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct DownloadResult {
    let outputURL: URL
    let format: AudioFormat
    let processingTime: TimeInterval
    let fileSizeBytes: Int64
}

enum AppError: LocalizedError {
    case ytdlpNotFound
    case ffmpegNotFound
    case invalidURL
    case metadataFetchFailed(String)
    case downloadFailed(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .ytdlpNotFound:
            return "yt-dlp not found. Install it with: brew install yt-dlp"
        case .ffmpegNotFound:
            return "ffmpeg not found. Install it with: brew install ffmpeg"
        case .invalidURL:
            return "That doesn't look like a valid YouTube URL."
        case .metadataFetchFailed(let msg):
            return "Couldn't fetch video info: \(msg)"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .conversionFailed(let msg):
            return "Conversion failed: \(msg)"
        }
    }
}

// MARK: - Format comparison (null test)

struct ComparisonResult {
    let formatA: AudioFormat
    let formatB: AudioFormat
    /// Loudness of the "difference signal" (fileA minus fileB) after aligning
    /// both to the same sample rate/channels. Very negative dB = the two
    /// files are nearly identical; closer to 0 dB = a real, measurable
    /// difference between them.
    let differenceRMSdB: Double?
    let differencePeakdB: Double?
    let detectedOffsetMs: Double
    let fileAURL: URL
    let fileBURL: URL

    var verdict: String {
        guard let rms = differenceRMSdB else { return "Couldn't determine a difference level." }
        switch rms {
        case ..<(-50):
            return "Audibly identical — the difference signal is far below the threshold of human hearing."
        case -50..<(-30):
            return "Extremely subtle difference — essentially inaudible to virtually everyone, on any equipment."
        case -30..<(-15):
            return "Small but real difference — could be detectable on very revealing equipment or by trained ears."
        default:
            return "Clearly measurable difference — likely to be audible."
        }
    }
}
