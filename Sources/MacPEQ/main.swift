import Foundation

// MacPEQ - CP2: Single Biquad Filter
// Config: +6dB peak at 1kHz, Q=1.0
// Usage: swift run MacPEQ (or open MacPEQ.app)
// Press Ctrl-C to stop

fileprivate var gEngine: Any?

func signalHandler(signal: Int32) {
    _ = signal
    exit(0)
}

// Check macOS version first
if #available(macOS 14.2, *) {
    // Set up signal handler for clean shutdown
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)
    
    var engine: AudioEngine?
    
    Logger.info("MacPEQ starting - CP2: Single Biquad Filter")
    
    engine = AudioEngine()
    gEngine = engine
    
    if engine?.start() ?? false {
        RunLoop.main.run()
    } else {
        Logger.error("Failed to start engine")
        exit(1)
    }
} else {
    print("Error: macOS 14.2+ required for Core Audio process taps")
    exit(1)
}
