import SwiftUI
import AVFoundation

/// A blind ABX test: on each trial, a hidden "X" clip is secretly either A or B.
/// The listener plays A, B, and X freely, then guesses which one X was.
/// Over many trials, a hit rate near 50% means the files are indistinguishable
/// by ear; a hit rate well above 50% (with statistical significance) means
/// there's a genuine, perceptible difference — this is the same methodology
/// used by the Hydrogenaudio community and most serious codec listening tests.
struct ABXTestView: View {
    let fileAURL: URL
    let fileBURL: URL
    let labelA: String
    let labelB: String

    @Environment(\.dismiss) private var dismiss

    @State private var playerA: AVAudioPlayer?
    @State private var playerB: AVAudioPlayer?
    @State private var currentXIsA: Bool = Bool.random()
    @State private var clipStart: TimeInterval = 0
    @State private var trials: [Bool] = [] // true = correct guess
    @State private var totalTrials = 10
    @State private var playError: String?
    @State private var hasPlayedXThisTrial = false

    private var correctCount: Int { trials.filter { $0 }.count }
    private var isComplete: Bool { trials.count >= totalTrials }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("🎧 Blind ABX Test").font(.title3).bold()
                Spacer()
                Button("Close") { dismiss() }
            }

            Text("A = \(labelA)  ·  B = \(labelB)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let playError {
                Text(playError).foregroundStyle(.red).font(.caption)
            }

            if !isComplete {
                activeTrialView
            } else {
                resultsView
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 520, height: 460)
        .onAppear { preparePlayers() }
        .onDisappear {
            playerA?.stop()
            playerB?.stop()
        }
    }

    // MARK: - Active trial

    private var activeTrialView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trial \(trials.count + 1) of \(totalTrials)")
                .font(.headline)

            Text("Listen to A, B, and X as many times as you like. When ready, guess whether X matches A or B. Neither A nor B is labeled by quality — this is genuinely blind.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("▶ Play A") { play(.a) }
                    .buttonStyle(.bordered)
                Button("▶ Play B") { play(.b) }
                    .buttonStyle(.bordered)
                Button("▶ Play X") { play(.x) }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
            }

            Divider()

            HStack(spacing: 12) {
                Text("X sounds like:")
                Button("A") { submitGuess(guessedA: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!hasPlayedXThisTrial)
                Button("B") { submitGuess(guessedA: false) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!hasPlayedXThisTrial)
            }

            if !hasPlayedXThisTrial {
                Text("Play X at least once before guessing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !trials.isEmpty {
                Text("So far: \(correctCount)/\(trials.count) correct")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        let pct = Int(100.0 * Double(correctCount) / Double(max(trials.count, 1)))
        let p = Self.binomialUpperTailPValue(successes: correctCount, trials: trials.count)
        let significant = p < 0.05

        return VStack(alignment: .leading, spacing: 12) {
            Text("Results").font(.headline)

            Text("\(correctCount) / \(trials.count) correct (\(pct)%)")
                .font(.title2).bold()
                .foregroundStyle(significant ? .orange : .green)

            Text(significant
                 ? "Statistically significant (p = \(String(format: "%.3f", p))). You can genuinely tell these apart — this wasn't luck."
                 : "Not statistically significant (p = \(String(format: "%.3f", p))). This is consistent with random guessing — you likely can't reliably distinguish these.")
                .font(.callout).bold()
                .foregroundStyle(significant ? .orange : .green)

            Text("The p-value is the probability of scoring this well or better purely by chance. Under 0.05 (5%) is the conventional threshold audio engineers use to call a result 'real' rather than luck.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Run Again") {
                    trials = []
                    currentXIsA = Bool.random()
                    hasPlayedXThisTrial = false
                    pickNewClipStart()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Playback

    private enum Choice { case a, b, x }

    private func preparePlayers() {
        do {
            let pa = try AVAudioPlayer(contentsOf: fileAURL)
            let pb = try AVAudioPlayer(contentsOf: fileBURL)
            pa.prepareToPlay()
            pb.prepareToPlay()
            playerA = pa
            playerB = pb
            pickNewClipStart()
        } catch {
            playError = "Couldn't load audio for playback: \(error.localizedDescription)"
        }
    }

    private func pickNewClipStart() {
        guard let pa = playerA, let pb = playerB else { return }
        let dur = min(pa.duration, pb.duration)
        clipStart = dur > 15 ? Double.random(in: 0..<(dur - 10)) : 0
    }

    private func play(_ choice: Choice) {
        playError = nil
        let isA: Bool
        switch choice {
        case .a: isA = true
        case .b: isA = false
        case .x: isA = currentXIsA
        }
        guard let player = isA ? playerA : playerB else { return }

        playerA?.stop()
        playerB?.stop()
        player.currentTime = clipStart
        player.play()

        if choice == .x {
            hasPlayedXThisTrial = true
        }
    }

    private func submitGuess(guessedA: Bool) {
        trials.append(guessedA == currentXIsA)
        currentXIsA = Bool.random()
        hasPlayedXThisTrial = false
        pickNewClipStart()
    }

    // MARK: - Statistics

    /// Probability of getting `successes` or more out of `trials`, under pure
    /// random guessing (p = 0.5). Uses log-gamma for numerically stable
    /// binomial coefficients at any trial count.
    private static func binomialUpperTailPValue(successes k: Int, trials n: Int, p: Double = 0.5) -> Double {
        guard n > 0 else { return 1.0 }
        func logChoose(_ n: Int, _ k: Int) -> Double {
            lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1))
        }
        var total = 0.0
        for i in k...n {
            let logProb = logChoose(n, i) + Double(i) * log(p) + Double(n - i) * log(1 - p)
            total += exp(logProb)
        }
        return min(max(total, 0), 1)
    }
}
