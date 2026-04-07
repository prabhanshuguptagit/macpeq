import Foundation
import os

let logger = Logger(subsystem: "com.macpeq", category: "audio")

func logMessage(_ message: String) {
    logger.info("\(message, privacy: .public)")
    // Also write to file for debugging
    let logFile = "/tmp/macpeq_debug.log"
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}
