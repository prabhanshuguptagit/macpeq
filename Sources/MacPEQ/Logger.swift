import Foundation

/// Simple structured logger that writes to stderr and a file for visibility
enum Logger {
    static let dateFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()
    
    // File logging for when running as LSUIElement (no terminal)
    static let logFilePath = "/tmp/macpeq.log"
    
    static func log(_ level: String, _ message: String, metadata: [String: String] = [:]) {
        let timestamp = dateFormatter.string(from: Date())
        var metaStr = ""
        if !metadata.isEmpty {
            metaStr = metadata.map { "\($0)=\($1)" }.joined(separator: " ")
            metaStr = " [\(metaStr)]"
        }
        let line = "[\(timestamp)] [\(level)] \(message)\(metaStr)\n"
        
        if let data = line.data(using: .utf8) {
            // Write to stderr
            FileHandle.standardError.write(data)
            
            // Also append to file
            if FileManager.default.fileExists(atPath: logFilePath) {
                if let fh = FileHandle(forWritingAtPath: logFilePath) {
                    _ = try? fh.seekToEnd()
                    try? fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logFilePath))
            }
        }
    }
    
    static func info(_ message: String, metadata: [String: String] = [:]) {
        log("INFO", message, metadata: metadata)
    }
    
    static func debug(_ message: String, metadata: [String: String] = [:]) {
        log("DEBUG", message, metadata: metadata)
    }
    
    static func error(_ message: String, metadata: [String: String] = [:]) {
        log("ERROR", message, metadata: metadata)
    }
    
    static func warning(_ message: String, metadata: [String: String] = [:]) {
        log("WARNING", message, metadata: metadata)
    }
}
