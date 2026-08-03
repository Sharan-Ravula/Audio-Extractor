import SwiftUI
import AppKit

struct ContentView: View {
    @State private var urlText: String = ""
    @State private var selectedFormat: AudioFormat = .flac
    @State private var videoInfo: VideoInfo?
    @State private var downloadResult: DownloadResult?
    @State private var isFetchingInfo = false
    @State private var isProcessing = false
    @State private var errorMessage: String?

    // Live feedback
    @State private var statusText: String = ""
    @State private var progress: Double = 0
    @State private var elapsedSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?

    @State private var titleHueRotation: Double = 0

    // Comparison feature
    @State private var compareFormat: AudioFormat = .mp3
    @State private var isComparing = false
    @State private var comparisonResult: ComparisonResult?
    @State private var comparisonError: String?
    @State private var showABXSheet = false

    private let service: YTDLPService?
    private let serviceInitError: String?

    init() {
        do {
            service = try YTDLPService()
            serviceInitError = nil
        } catch {
            service = nil
            serviceInitError = error.localizedDescription
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Audio Extractor")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .cyan, .green],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .hueRotation(.degrees(titleHueRotation))
                    .onAppear {
                        withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                            titleHueRotation = 360
                        }
                    }

            if let serviceInitError {
                Label(serviceInitError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                TextField("Paste YouTube URL…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isFetchingInfo || isProcessing)

                Button {
                    Task { await fetchInfo() }
                } label: {
                    if isFetchingInfo {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Fetch Info").bold()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)
                .disabled(urlText.isEmpty || service == nil || isFetchingInfo || isProcessing)
            }

            // Live status while fetching OR processing (download/convert)
            if isFetchingInfo || isProcessing {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ProgressView(value: isProcessing ? progress : nil)
                                .progressViewStyle(.linear)
                                .tint(Self.progressSpectrumColor(t: progress))
                            Text(isProcessing ? "\(Int(progress * 100))%" : "")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(Self.progressSpectrumColor(t: progress))
                                .frame(width: 40, alignment: .trailing)
                        }
                        Text(statusText.isEmpty ? "Working…" : statusText)
                            .font(.caption)
                            .foregroundStyle(statusColor(for: statusText))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack {
                            Text("Elapsed: \(elapsedSeconds)s")
                                .foregroundStyle(.secondary)
                            if isProcessing, progress > 0.02 {
                                let estTotal = Double(elapsedSeconds) / progress
                                let remaining = max(0, Int(estTotal) - elapsedSeconds)
                                Text("· Est. remaining: ~\(remaining)s")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption2)
                    }
                    .padding(4)
                }
            }

            if let info = videoInfo {
                GroupBox("Video Info") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(info.title).font(.headline)
                        HStack(spacing: 4) {
                            Text("Length:").foregroundStyle(.secondary)
                            Text(info.durationFormatted).bold().foregroundStyle(.cyan)
                        }
                        HStack(spacing: 4) {
                            Text("Source bitrate:").foregroundStyle(.secondary)
                            if let bitrate = info.sourceBitrateKbps {
                                Text("\(String(format: "%.0f", bitrate)) kbps")
                                    .bold()
                                    .foregroundStyle(Self.bitrateQualityColor(kbps: bitrate))
                                Text("(\(info.sourceCodec ?? "unknown codec"))").foregroundStyle(.secondary)
                            } else {
                                Text("unavailable").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Output Format") {
                    Picker("Format", selection: $selectedFormat) {
                        ForEach(AudioFormat.allCases) { fmt in
                            formatLabel(for: fmt, info: info).tag(fmt)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .padding(4)

                    Text("Estimates based on video length. WAV is exact (raw PCM); Original reflects the real source bitrate. MP3/M4A/FLAC are approximate — actual size varies slightly with container overhead and content. Color scale: blue = smallest, red = largest.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                }

                Button {
                    Task { await downloadAndConvert() }
                } label: {
                    Text(isProcessing ? "Processing…" : "Download & Convert")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)
            }

            if let result = downloadResult {
                GroupBox("Done") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Saved:").foregroundStyle(.secondary)
                            Text(result.outputURL.lastPathComponent).bold()
                        }
                        HStack(spacing: 4) {
                            Text("Format:").foregroundStyle(.secondary)
                            Text(result.format.displayName)
                                .bold()
                                .foregroundStyle(videoInfo.map { colorForFormat(result.format, info: $0) } ?? .primary)
                        }
                        HStack(spacing: 4) {
                            Text("File size:").foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: result.fileSizeBytes, countStyle: .file))
                                .bold()
                                .foregroundStyle(videoInfo.map { colorForActualSize(result.fileSizeBytes, info: $0) } ?? .primary)
                        }
                        HStack(spacing: 4) {
                            Text("Processing time:").foregroundStyle(.secondary)
                            Text("\(String(format: "%.1f", result.processingTime))s")
                                .bold()
                                .foregroundStyle(Self.speedColor(seconds: result.processingTime))
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Compare Audio Quality") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Runs an audio null test: decodes both files, aligns them, subtracts one from the other, and measures how loud what's left is. Follow up with the blind ABX test to find out if you can actually hear it.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Compare \(result.format.displayName) against:")
                            Picker("", selection: $compareFormat) {
                                ForEach(AudioFormat.allCases.filter { $0 != result.format }) { fmt in
                                    Text(fmt.displayName).tag(fmt)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)

                            Button {
                                Task { await performComparison() }
                            } label: {
                                if isComparing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Compare").bold()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(isComparing)
                        }

                        if let comparisonError {
                            Text(comparisonError).foregroundStyle(.red).font(.caption)
                        }

                        if isComparing {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(statusText.isEmpty ? "Working…" : statusText)
                                        .font(.caption)
                                        .foregroundStyle(statusColor(for: statusText))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Text("Elapsed: \(elapsedSeconds)s")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        if let comparison = comparisonResult {
                            Divider()

                            HStack(spacing: 4) {
                                Text("Detected offset:").foregroundStyle(.secondary)
                                Text(String(format: "%.2f ms", comparison.detectedOffsetMs))
                                    .bold()
                            }
                            .font(.caption2)

                            HStack(spacing: 4) {
                                Text("Difference (RMS):").foregroundStyle(.secondary)
                                if let rms = comparison.differenceRMSdB {
                                    Text(String(format: "%.1f dB", rms))
                                        .bold()
                                        .foregroundStyle(Self.differenceColor(dB: rms))
                                } else {
                                    Text("unavailable").foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)

                            Text(comparison.verdict)
                                .font(.caption)
                                .foregroundStyle(comparison.differenceRMSdB.map { Self.differenceColor(dB: $0) } ?? .secondary)
                                .bold()

                            Text("Files are automatically time-aligned (cross-correlation) before this measurement, resolution ~0.1ms. For the most reliable answer on whether a difference is actually audible, use the blind ABX test below rather than this number alone.")
                                .font(.caption2)
                                .foregroundStyle(.yellow)

                            Button {
                                showABXSheet = true
                            } label: {
                                Text("🎧 Take Blind ABX Test").bold()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            }
            .padding(24)
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 700)
        .sheet(isPresented: $showABXSheet) {
            if let comparison = comparisonResult {
                ABXTestView(
                    fileAURL: comparison.fileAURL,
                    fileBURL: comparison.fileBURL,
                    labelA: comparison.formatA.displayName,
                    labelB: comparison.formatB.displayName
                )
            }
        }
    }

    // MARK: - Elapsed timer

    private func startTimer() {
        elapsedSeconds = 0
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                elapsedSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Actions

    private func fetchInfo() async {
        guard let service else { return }
        errorMessage = nil
        downloadResult = nil
        statusText = "Starting…"
        isFetchingInfo = true
        startTimer()
        defer { isFetchingInfo = false; stopTimer() }
        do {
            videoInfo = try await service.fetchInfo(url: urlText) { line in
                Task { @MainActor in statusText = line }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func downloadAndConvert() async {
        guard let service else { return }
        errorMessage = nil
        isProcessing = true
        progress = 0
        statusText = "Starting…"
        startTimer()
        defer { isProcessing = false; stopTimer() }
        do {
            let outputDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let baseName = sanitizedFileName(videoInfo?.title ?? "audio")
            downloadResult = try await service.downloadAudio(
                url: urlText,
                format: selectedFormat,
                outputDirectory: outputDir,
                baseName: baseName,
                totalDurationSeconds: videoInfo?.durationSeconds ?? 0,
                onStatus: { line in
                    Task { @MainActor in statusText = line }
                },
                onProgress: { pct in
                    Task { @MainActor in progress = pct }
                }
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Builds the picker row: format name + colored, size-estimate text.
    private func formatLabel(for format: AudioFormat, info: VideoInfo) -> Text {
        let sizeText = estimatedSizeText(for: format, durationSeconds: info.durationSeconds, sourceBitrateKbps: info.sourceBitrateKbps)
        let color = colorForFormat(format, info: info)

        var result = AttributedString("\(format.displayName) — ")
        var sizePart = AttributedString(sizeText)
        sizePart.foregroundColor = color
        sizePart.font = .body.bold()
        result += sizePart

        return Text(result)
    }

    /// Raw byte estimate per format. Used both for display text and for
    /// ranking formats along the color spectrum.
    private func estimatedSizeBytes(for format: AudioFormat, durationSeconds: Double, sourceBitrateKbps: Double?) -> Double {
        switch format {
        case .original:
            guard let kbps = sourceBitrateKbps else { return 0 }
            return durationSeconds * (kbps * 1000 / 8) * 1.02 // small container overhead
        case .wav:
            return durationSeconds * 48000 * 2 * 2 // 48kHz, 16-bit, stereo
        case .flac:
            return durationSeconds * 48000 * 2 * 2 * 0.95
        case .mp3:
            return durationSeconds * (320_000 / 8) * 1.06
        case .m4a:
            return durationSeconds * (256_000 / 8) * 1.06
        }
    }

    private func estimatedSizeText(for format: AudioFormat, durationSeconds: Double, sourceBitrateKbps: Double?) -> String {
        guard durationSeconds > 0 else { return "size unknown" }
        let bytes = estimatedSizeBytes(for: format, durationSeconds: durationSeconds, sourceBitrateKbps: sourceBitrateKbps)
        guard bytes > 0 else { return "size unknown" }
        let mb = bytes / 1_048_576
        let prefix = format == .wav ? "" : "~"
        return String(format: "%@%.1f MB", prefix, mb)
    }

    /// Maps a format's estimated size to a color along a blue → green → yellow
    /// → orange → pink → red spectrum, scaled relative to the smallest/largest
    /// option currently on screen — so it adapts to any video length.
    private func colorForFormat(_ format: AudioFormat, info: VideoInfo) -> Color {
        let allBytes = AudioFormat.allCases.map {
            estimatedSizeBytes(for: $0, durationSeconds: info.durationSeconds, sourceBitrateKbps: info.sourceBitrateKbps)
        }
        let thisBytes = estimatedSizeBytes(for: format, durationSeconds: info.durationSeconds, sourceBitrateKbps: info.sourceBitrateKbps)
        let minB = allBytes.min() ?? 0
        let maxB = allBytes.max() ?? 1
        let t = maxB > minB ? (thisBytes - minB) / (maxB - minB) : 0.5
        return Self.spectrumColor(t: t)
    }

    /// Colors a bitrate by perceived quality tier. Unlike the size spectrum,
    /// here HIGHER is better, so the direction is reversed: red = low quality,
    /// green/cyan = high quality.
    private static func bitrateQualityColor(kbps: Double) -> Color {
        switch kbps {
        case ..<64: return .red
        case 64..<96: return .orange
        case 96..<128: return .yellow
        case 128..<192: return .green
        default: return .cyan
        }
    }

    /// Colors an actual downloaded file's size using the same blue→red
    /// spectrum as the format picker, so the "Done" panel visually confirms
    /// where your choice landed relative to the other options.
    private func colorForActualSize(_ actualBytes: Int64, info: VideoInfo) -> Color {
        let allBytes = AudioFormat.allCases.map {
            estimatedSizeBytes(for: $0, durationSeconds: info.durationSeconds, sourceBitrateKbps: info.sourceBitrateKbps)
        }
        let minB = allBytes.min() ?? 0
        let maxB = allBytes.max() ?? 1
        let t = maxB > minB ? (Double(actualBytes) - minB) / (maxB - minB) : 0.5
        return Self.spectrumColor(t: t)
    }

    /// Colors processing time by speed: fast = green, slow = red.
    private static func speedColor(seconds: Double) -> Color {
        switch seconds {
        case ..<10: return .green
        case 10..<30: return .yellow
        case 30..<60: return .orange
        default: return .red
        }
    }

    /// Colors the live status line by what kind of message it is —
    /// makes it easy to tell "downloading" vs "converting" vs "error" apart at a glance.
    private func statusColor(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("warning") {
            return .red
        }
        if lower.contains("[download]") {
            return .blue
        }
        if lower.contains("time=") || lower.contains("frame=") || lower.contains("bitrate=") {
            return .purple // ffmpeg's own progress lines
        }
        if lower.contains("[youtube]") || lower.contains("extract") || lower.contains("[info]") {
            return .cyan
        }
        if lower.contains("starting") || lower.contains("connecting") {
            return .blue
        }
        return .secondary
    }

    /// Blue → cyan → green gradient for progress completion (0 = just started,
    /// 1 = done). Deliberately avoids red/orange so it never reads as "error" —
    /// that meaning is reserved for the size spectrum below.
    private static let progressStops: [(Double, Double, Double)] = [
        (0.20, 0.45, 1.00),  // blue
        (0.20, 0.75, 0.85),  // cyan
        (0.20, 0.80, 0.35),  // green
    ]

    private static func progressSpectrumColor(t: Double) -> Color {
        interpolatedColor(t: t, stops: progressStops)
    }

    private static func interpolatedColor(t: Double, stops: [(Double, Double, Double)]) -> Color {
        let clamped = min(max(t, 0), 1)
        let segments = Double(stops.count - 1)
        let scaled = clamped * segments
        let index = min(Int(scaled), stops.count - 2)
        let localT = scaled - Double(index)

        let a = stops[index]
        let b = stops[index + 1]
        let r = a.0 + (b.0 - a.0) * localT
        let g = a.1 + (b.1 - a.1) * localT
        let bl = a.2 + (b.2 - a.2) * localT
        return Color(red: r, green: g, blue: bl)
    }

    /// Stops, in order, for the size spectrum. RGB-interpolated between
    /// adjacent stops based on t in [0, 1].
    private static let spectrumStops: [(Double, Double, Double)] = [
        (0.20, 0.45, 1.00),  // blue
        (0.20, 0.80, 0.35),  // green
        (0.95, 0.85, 0.20),  // yellow
        (0.95, 0.55, 0.15),  // orange
        (0.95, 0.40, 0.60),  // pink
        (0.90, 0.15, 0.15),  // red
    ]

    private static func spectrumColor(t: Double) -> Color {
        interpolatedColor(t: t, stops: spectrumStops)
    }

    private func performComparison() async {
        guard let service, let info = videoInfo, let currentResult = downloadResult else { return }
        comparisonError = nil
        comparisonResult = nil
        isComparing = true
        statusText = "Starting comparison…"
        startTimer()
        defer { isComparing = false; stopTimer() }
        do {
            let outputDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let baseName = sanitizedFileName(info.title)

            // Download the second format fresh so we have a real file to compare against.
            let secondResult = try await service.downloadAudio(
                url: urlText,
                format: compareFormat,
                outputDirectory: outputDir,
                baseName: baseName + "_compare",
                totalDurationSeconds: info.durationSeconds,
                onStatus: { line in Task { @MainActor in statusText = line } },
                onProgress: { _ in }
            )

            let (rms, peak, offsetSeconds) = try await service.compareAudio(
                fileA: currentResult.outputURL,
                fileB: secondResult.outputURL,
                outputDirectory: outputDir,
                baseName: baseName,
                onStatus: { line in Task { @MainActor in statusText = line } }
            )

            comparisonResult = ComparisonResult(
                formatA: currentResult.format,
                formatB: compareFormat,
                differenceRMSdB: rms,
                differencePeakdB: peak,
                detectedOffsetMs: offsetSeconds * 1000,
                fileAURL: currentResult.outputURL,
                fileBURL: secondResult.outputURL
            )
            // The comparison audio file is kept — it's needed for the ABX test
            // below, and it's just a normal file in Downloads like any other
            // export, not a hidden temp file.
        } catch {
            comparisonError = error.localizedDescription
        }
    }

    /// Colors the null-test difference reading: very negative dB (inaudible) = green,
    /// moving toward 0 dB (clearly audible difference) = red.
    private static func differenceColor(dB: Double) -> Color {
        switch dB {
        case ..<(-50): return .green
        case -50..<(-30): return .cyan
        case -30..<(-15): return .orange
        default: return .red
        }
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}

#Preview {
    ContentView()
}
