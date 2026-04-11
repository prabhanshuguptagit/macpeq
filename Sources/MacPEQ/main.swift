import Foundation

// CP1: Simple CLI audio passthrough test
// Usage: swift run MacPEQ
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
    
    Logger.info("MacPEQ CP1 - Audio Passthrough Test")
    
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
