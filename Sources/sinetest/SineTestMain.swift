import Foundation

// Sine wave output test - isolated speaker test

@main
struct SineTestApp {
    static func main() {
        if #available(macOS 14.2, *) {
            let test = SineWaveTest()
            
            Logger.info("========================================")
            Logger.info("SINE WAVE OUTPUT TEST")
            Logger.info("========================================")
            Logger.info("You should hear a 1kHz tone if speaker output works")
            Logger.info("Press Ctrl-C to stop")
            
            if test.start() {
                // Keep running
                RunLoop.main.run()
            } else {
                Logger.error("Failed to start test")
                exit(1)
            }
        } else {
            print("macOS 14.2+ required")
            exit(1)
        }
    }
}
