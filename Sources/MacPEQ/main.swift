import Foundation
import MacPEQLib

// MacPEQ — System-Wide Parametric EQ
// Usage: swift run MacPEQ (or open MacPEQ.app)
// Press Ctrl-C to stop

func signalHandler(signal: Int32) {
    _ = signal
    exit(0)
}

// bx5 eq settings from Peace/EqualizerAPO
let defaultBands: [EQBand] = [
    EQBand(frequency: 30,  gain: -1.4, q: 5.0,   type: .peak),
    EQBand(frequency: 60,  gain: -3.0,   q: 2,   type: .peak),
    EQBand(frequency: 63,  gain: -5.0,   q: 5.0,   type: .peak),
    EQBand(frequency: 118, gain: -8.0,   q: 12.0, type: .peak),
    EQBand(frequency: 175, gain: -4.0,   q: 14.0, type: .peak),
    EQBand(frequency: 244, gain: -3.0,   q: 10.0, type: .peak),
    EQBand(frequency: 333, gain: -0.2,   q: 1.4,  type: .peak),
]

guard #available(macOS 14.2, *) else {
    print("Error: macOS 14.2+ required for Core Audio process taps")
    exit(1)
}

signal(SIGINT, signalHandler)
signal(SIGTERM, signalHandler)

Logger.info("MacPEQ starting")

// Wrap main logic in a function to scope the @available check
@available(macOS 14.2, *)
func run() {
    // `AudioEngine.shared` is set inside the initializer, so keeping `engine` in
    // scope here is what holds the engine alive for the lifetime of the process.
    let engine = AudioEngine()

    guard engine.start() else {
        Logger.error("Failed to start engine")
        exit(1)
    }

    engine.updateEQ(bands: defaultBands)
    Logger.info("EQ active: telephone effect (300Hz HP + 3400Hz LP)")

    RunLoop.main.run()
}

if #available(macOS 14.2, *) {
    run()
}
