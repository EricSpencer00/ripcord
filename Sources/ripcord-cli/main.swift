import Foundation
import RipcordKit

// A thin harness over RipcordKit: the same code path the app uses, without the app.
// Exists so the mastering chain can be measured against real files from a terminal.

/// Progress callbacks arrive on whichever thread is doing the work, so the "have I already
/// printed this stage" flag needs a lock rather than a plain var.
final class StageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func announce(_ stage: Masterer.Stage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stage.rawValue != last else { return false }
        last = stage.rawValue
        return true
    }
}

func usage() -> Never {
    let text = """
    ripcord — offline mastering

      ripcord-cli <input> [options]

    Options:
      --intensity <gentle|standard|loud>   default: standard
      --delivery <none|apple>              check the master against a delivery target
      --out <path>                         default: "<input> (mastered).wav"
      --analyze                            measure only, write nothing

    With --delivery, the master is encoded to AAC and decoded back to check for overs, and
    the ceiling is lowered and the level pass re-run if it clips. Exits non-zero if any
    check is not met, so a release script can gate on it.
    """
    print(text)
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { usage() }

var intensity = Intensity.standard
var delivery = Delivery.none
var outputPath: String?
var analyzeOnly = false
var inputPath: String?

var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--intensity":
        index += 1
        guard index < arguments.count, let parsed = Intensity(rawValue: arguments[index]) else { usage() }
        intensity = parsed
    case "--delivery":
        index += 1
        guard index < arguments.count, let parsed = Delivery(rawValue: arguments[index]) else { usage() }
        delivery = parsed
    case "--out":
        index += 1
        guard index < arguments.count else { usage() }
        outputPath = arguments[index]
    case "--analyze":
        analyzeOnly = true
    case "-h", "--help":
        usage()
    default:
        let value = arguments[index]
        if value.hasPrefix("-") { usage() }
        inputPath = value
    }
    index += 1
}

guard let inputPath else { usage() }
let inputURL = URL(fileURLWithPath: inputPath)

do {
    let clock = Date()
    let audio = try AudioIO.read(inputURL)
    print("· \(inputURL.lastPathComponent) — \(Report.formatDuration(audio.durationSeconds)), "
          + "\(Int(audio.sampleRate)) Hz, \(audio.channels.count) ch")

    if analyzeOnly {
        let analysis = Analyzer.analyze(channels: audio.channels, sampleRate: audio.sampleRate)
        print(String(format: "  integrated  %.2f LUFS", analysis.integratedLUFS))
        print(String(format: "  true peak   %.2f dBTP", analysis.truePeakDBTP))
        print(String(format: "  range       %.2f LU", analysis.loudnessRangeLU))
        print(String(format: "  crest       %.2f dB", analysis.crestFactorDB))
        print(String(format: "  correlation %.3f (low %.3f)", analysis.correlation, analysis.lowCorrelation))
        let bands = zip(Analysis.bandLabels, analysis.normalizedBands)
            .map { String(format: "%@:%+.1f", $0.0, $0.1) }
            .joined(separator: " ")
        print("  bands       \(bands)")
        for resonance in analysis.resonances {
            print(String(format: "  resonance   %.0f Hz  +%.1f dB", resonance.frequency, resonance.excessDB))
        }
        exit(0)
    }

    let tracker = StageTracker()
    let announce: @Sendable (Masterer.Stage, Double) -> Void = { stage, _ in
        if tracker.announce(stage) {
            FileHandle.standardError.write("  \(stage.rawValue)…\n".data(using: .utf8)!)
        }
    }

    // The engine rather than `Masterer` directly, because the delivery pass needs its level-pass
    // cache: the ceiling correction re-runs only the limiter search, not the whole chain.
    let engine = MasteringEngine(channels: audio.channels, sampleRate: audio.sampleRate)
    let mixer = Mixer(intensity: intensity, delivery: delivery)

    var conformance: Conformance?
    let result: Masterer.Result
    if delivery == .none {
        guard let rendered = await engine.render(mixer: mixer, progress: announce) else { exit(1) }
        result = rendered
    } else {
        guard let outcome = await engine.conform(mixer: mixer, progress: announce) else { exit(1) }
        result = outcome.result
        conformance = Conformance.evaluate(outcome, source: audio.sourceFormat,
                                           outputBitDepth: delivery.bitDepth)
    }

    print("")
    print(Report(result: result, sourceFormat: audio.sourceFormat,
                 conformance: conformance).plainText())
    print("")

    let outputURL = outputPath.map { URL(fileURLWithPath: $0) }
        ?? AudioIO.defaultOutputURL(for: inputURL)
    try AudioIO.writeWAV(channels: result.channels, sampleRate: audio.sampleRate,
                         bitDepth: delivery.bitDepth, to: outputURL)
    print(String(format: "→ %@  (%.1fs)", outputURL.path, Date().timeIntervalSince(clock)))

    // Non-zero on a failed or unrunnable check, so a release script can gate on this.
    if let conformance, !conformance.passed {
        FileHandle.standardError.write("ripcord: delivery checks not met\n".data(using: .utf8)!)
        exit(3)
    }
} catch {
    FileHandle.standardError.write("ripcord: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
