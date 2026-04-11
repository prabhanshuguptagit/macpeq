import Foundation

// MacPEQ - CP3: Device Switching
// Config: +6dB peak at 1kHz, Q=1.0
// Usage: swift run MacPEQ (or open MacPEQ.app)
// Switch output devices while playing - audio should resume within ~300ms
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
    
    Logger.info("MacPEQ starting - CP3: Device Switching")
    
    engine = AudioEngine()
    AudioEngine.shared = engine  // For device change callbacks
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
