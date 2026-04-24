import Foundation

// MacPEQ - System-Wide Parametric EQ
// Usage: swift run MacPEQ (or open MacPEQ.app)
// Press Ctrl-C to stop

fileprivate var gEngine: Any?

func signalHandler(signal: Int32) {
    _ = signal
    exit(0)
}

// ISO frequencies for 10-band EQ
let defaultBands: [EQBand] = [
    // Telephone effect: high-pass ~300Hz + low-pass ~3400Hz
    EQBand(frequency: 300,  gain: 0, q: 0.7, type: .highPass),
    EQBand(frequency: 3400, gain: 0, q: 0.7, type: .lowPass),
]

// Check macOS version first
if #available(macOS 14.2, *) {
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)

    var engine: AudioEngine?

    Logger.info("MacPEQ starting")

    engine = AudioEngine()
    AudioEngine.shared = engine
    gEngine = engine

    if engine?.start() ?? false {
        // Apply default EQ bands
        engine?.updateEQ(bands: defaultBands)
        Logger.info("EQ active: telephone effect (300Hz HP + 3400Hz LP)")

        RunLoop.main.run()
    } else {
        Logger.error("Failed to start engine")
        exit(1)
    }
} else {
    print("Error: macOS 14.2+ required for Core Audio process taps")
    exit(1)
}
