import SwiftUI
import AVFoundation

@main
struct MacPEQApp: App {
    @StateObject private var audioEngine = { if #available(macOS 14.2, *) { return AudioEngine() } else { fatalError("macOS 14.2+ required") } }()

    var body: some Scene {
        MenuBarExtra("MacPEQ", systemImage: "waveform") {
            VStack(spacing: 8) {
                Text("MacPEQ — CP1 Passthrough")
                    .font(.headline)
                Divider()
                Text("State: \(audioEngine.stateDescription)")
                if let error = audioEngine.lastError {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                Divider()
                if audioEngine.state == .idle || audioEngine.state == .disabled {
                    Button("Start") { audioEngine.start() }
                }
                if audioEngine.state == .running {
                    Button("Stop") { audioEngine.stop() }
                }
                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding()
        }
    }

    init() {
        // Request audio capture permission on launch
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            logMessage("[MacPEQ] Audio capture permission: \(granted ? "granted" : "DENIED")")
        }
        // Auto-start if --autostart flag is passed
        if CommandLine.arguments.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                audioEngine.start()
            }
        }
    }
}
