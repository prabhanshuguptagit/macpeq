import Foundation

// MacPEQ — System-Wide Parametric EQ
// Usage: swift run MacPEQ (or open MacPEQ.app)
// Press Ctrl-C to stop

func signalHandler(signal: Int32) {
    _ = signal
    exit(0)
}

// Telephone effect: high-pass at 300Hz + low-pass at 3400Hz
let defaultBands: [EQBand] = [
    EQBand(frequency: 300,  gain: 0, q: 0.7, type: .highPass),
    EQBand(frequency: 3400, gain: 0, q: 0.7, type: .lowPass),
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
