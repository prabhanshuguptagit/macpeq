import Foundation
import CTPCircularBuffer

/// Lock-free SPSC ring buffer using TPCircularBuffer
/// Thread-safe: single producer (IOProc), single consumer (AUHAL render callback)
final class RingBuffer {
    private var circularBuffer: TPCircularBuffer
    private let bytesPerFrame: Int
    let capacityFrames: Int32
    let channels: Int
    
    /// Initialize with capacity in frames (will be rounded up to next power of 2)
    init(capacityFrames: Int32, channels: Int, bytesPerSample: Int = MemoryLayout<Float>.size) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.bytesPerFrame = channels * bytesPerSample
        
        // TPCircularBuffer will round up to next power of 2 internally
        self.circularBuffer = TPCircularBuffer()
        let capacityBytes = UInt32(Int(capacityFrames) * bytesPerFrame)
        // Use the actual function instead of macro
        let success = _TPCircularBufferInit(&circularBuffer, capacityBytes, MemoryLayout<TPCircularBuffer>.size)
        
        // Pre-zero the buffer memory
        var availableBytes: UInt32 = 0
        if let head = TPCircularBufferHead(&circularBuffer, &availableBytes) {
            memset(head, 0, Int(capacityBytes))
            TPCircularBufferProduce(&circularBuffer, capacityBytes)
            TPCircularBufferConsume(&circularBuffer, capacityBytes)
        }
        
        Logger.info("RingBuffer initialized", metadata: [
            "capacityFrames": "\(capacityFrames)",
            "capacityBytes": "\(capacityBytes)",
            "channels": "\(channels)",
            "success": "\(success)"
        ])
    }
    
    deinit {
        TPCircularBufferCleanup(&circularBuffer)
    }
    
    /// Write audio samples. Called from IOProc (producer thread).
    /// Returns number of frames actually written.
    @discardableResult
    func write(_ samples: UnsafePointer<Float>, frameCount: Int) -> Int {
        let bytesToWrite = UInt32(frameCount * bytesPerFrame)
        var availableBytes: UInt32 = 0
        
        guard let head = TPCircularBufferHead(&circularBuffer, &availableBytes) else {
            return 0
        }
        
        let writeBytes = min(bytesToWrite, availableBytes)
        if writeBytes > 0 {
            memcpy(head, samples, Int(writeBytes))
            TPCircularBufferProduce(&circularBuffer, writeBytes)
        }
        
        return Int(writeBytes) / bytesPerFrame
    }
    
    /// Read audio samples. Called from AUHAL render callback (consumer thread).
    /// Returns number of frames actually read.
    @discardableResult
    func read(into dest: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        let bytesToRead = UInt32(frameCount * bytesPerFrame)
        var availableBytes: UInt32 = 0
        
        guard let tail = TPCircularBufferTail(&circularBuffer, &availableBytes) else {
            return 0
        }
        
        let readBytes = min(bytesToRead, availableBytes)
        if readBytes > 0 {
            memcpy(dest, tail, Int(readBytes))
            TPCircularBufferConsume(&circularBuffer, readBytes)
        }
        
        return Int(readBytes) / bytesPerFrame
    }
    
    /// Get available frames to read (consumer side)
    func availableFrames() -> Int {
        var availableBytes: UInt32 = 0
        _ = TPCircularBufferTail(&circularBuffer, &availableBytes)
        return Int(availableBytes) / bytesPerFrame
    }
    
    /// Get available space to write (producer side)
    func availableSpace() -> Int {
        var availableBytes: UInt32 = 0
        _ = TPCircularBufferHead(&circularBuffer, &availableBytes)
        return Int(availableBytes) / bytesPerFrame
    }
    
    /// Get fill ratio (0.0 to 1.0)
    func fillRatio() -> Float {
        let available = availableFrames()
        return Float(available) / Float(capacityFrames)
    }
    
    /// Manual drift compensation: drop one frame if buffer is too full (>70%)
    /// Returns true if a frame was dropped
    @discardableResult
    func compensateDriftIfNeeded() -> Bool {
        let ratio = fillRatio()
        
        // If buffer is getting too full, drop a frame (writer is faster than reader)
        if ratio > 0.7 {
            var availableBytes: UInt32 = 0
            if let tail = TPCircularBufferTail(&circularBuffer, &availableBytes) {
                if availableBytes >= UInt32(bytesPerFrame) {
                    TPCircularBufferConsume(&circularBuffer, UInt32(bytesPerFrame))
                    Logger.debug("Drift compensation: dropped 1 frame", metadata: ["fillRatio": "\(ratio)"])
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Clear the buffer - use when switching devices
    func clear() {
        // Consume all available data
        var availableBytes: UInt32 = 0
        while let _ = TPCircularBufferTail(&circularBuffer, &availableBytes) {
            if availableBytes == 0 { break }
            TPCircularBufferConsume(&circularBuffer, availableBytes)
        }
    }
}
