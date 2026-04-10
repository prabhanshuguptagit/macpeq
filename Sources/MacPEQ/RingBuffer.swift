import Foundation

/// Simple lock-free SPSC ring buffer for audio data
/// Thread-safe: single producer (IOProc), single consumer (AUHAL render callback)
final class RingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let capacityMask: Int
    
    // Use atomics for head/tail to avoid locks
    private var head: Int = 0  // Write position (IOProc)
    private var tail: Int = 0  // Read position (AUHAL)
    
    init(capacityFrames: Int, channels: Int) {
        // Round up to power of 2 for efficient masking
        var cap = 1
        while cap < capacityFrames * channels {
            cap <<= 1
        }
        self.capacity = cap
        self.capacityMask = cap - 1
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.buffer.initialize(repeating: 0, count: cap)
    }
    
    deinit {
        buffer.deallocate()
    }
    
    /// Write audio samples. Called from IOProc (audio thread).
    /// Returns number of samples actually written.
    @discardableResult
    func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        let available = capacity - availableBytes()
        let toWrite = min(count, available)
        
        for i in 0..<toWrite {
            buffer[(head + i) & capacityMask] = samples[i]
        }
        head = (head + toWrite) & capacityMask
        return toWrite
    }
    
    /// Read audio samples. Called from AUHAL render callback (audio thread).
    /// Returns number of samples actually read.
    @discardableResult
    func read(into dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let available = availableBytes()
        let toRead = min(count, available)
        
        for i in 0..<toRead {
            dest[i] = buffer[(tail + i) & capacityMask]
        }
        tail = (tail + toRead) & capacityMask
        return toRead
    }
    
    /// Zero the buffer when switching devices
    func clear() {
        head = 0
        tail = 0
        buffer.initialize(repeating: 0, count: capacity)
    }
    
    /// Get available samples to read
    func availableBytes() -> Int {
        return (head - tail) & capacityMask
    }
    
    /// Get fill ratio (0.0 to 1.0)
    func fillRatio() -> Float {
        return Float(availableBytes()) / Float(capacity)
    }
}
