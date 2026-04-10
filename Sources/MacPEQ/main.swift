import Foundation

// CP1: Simple CLI audio passthrough test
// Usage: swift run MacPEQ
// Press Ctrl-C to stop

// Global engine reference for signal handler
fileprivate var gEngine: Any?

func signalHandler(signal: Int32) {
    print("\nReceived signal \(signal), shutting down...")
    if #available(macOS 14.2, *), let engine = gEngine as? AudioEngine {
        engine.stop()
    }
    exit(0)
}

// Check macOS version first
if #available(macOS 14.2, *) {
    // Set up signal handler for clean shutdown
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)
    
    var engine: AudioEngine?
    
    Logger.info("MacPEQ CP1 - Audio Passthrough Test")
    Logger.info("This will tap system audio and pass it through to the default output.")
    Logger.info("Permission prompt should appear - grant 'System Audio Recording' to continue.")
    Logger.info("Press Ctrl-C to stop.\n")
    
    engine = AudioEngine()
    gEngine = engine
    
    if engine?.start() ?? false {
        Logger.info("Engine started. Playing audio now should work (with 1-2 second initial latency).")
        
        // Keep running
        RunLoop.main.run()
    } else {
        Logger.error("Failed to start engine")
        exit(1)
    }
} else {
    print("Error: macOS 14.2+ required for Core Audio process taps")
    exit(1)
}
