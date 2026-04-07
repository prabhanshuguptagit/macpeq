import Foundation
import CTPCircularBuffer

/// Simple lock-free SPSC ring buffer wrapping a single TPCircularBuffer.
/// Handles both interleaved and non-interleaved audio by treating the data as raw bytes.
class RingBuffer {
    private var buffer = TPCircularBuffer()
    private var initialized = false
    private var capacityBytes: Int = 0

    func initialize(capacityFrames: Int, bytesPerFrame: Int, channelCount: Int) {
        clear()
        // For interleaved: bytesPerFrame includes all channels
        // For non-interleaved: bytesPerFrame is per-channel, multiply by channelCount
        self.capacityBytes = capacityFrames * bytesPerFrame * channelCount
        _TPCircularBufferInit(&buffer, UInt32(capacityBytes), MemoryLayout<TPCircularBuffer>.size)
        initialized = true
    }

    func write(data: UnsafeRawPointer, byteCount: Int) {
        guard initialized else { return }
        TPCircularBufferProduceBytes(&buffer, data, UInt32(byteCount))
    }

    func read(data: UnsafeMutableRawPointer, byteCount: Int) -> Int {
        guard initialized else { return 0 }
        var availableBytes: UInt32 = 0
        guard let head = TPCircularBufferTail(&buffer, &availableBytes) else {
            return 0
        }
        let toRead = min(Int(availableBytes), byteCount)
        if toRead > 0 {
            memcpy(data, head, toRead)
            TPCircularBufferConsume(&buffer, UInt32(toRead))
        }
        return toRead
    }

    func skip(byteCount: Int) {
        guard initialized else { return }
        var availableBytes: UInt32 = 0
        guard let _ = TPCircularBufferTail(&buffer, &availableBytes) else { return }
        let toSkip = min(Int(availableBytes), byteCount)
        if toSkip > 0 {
            TPCircularBufferConsume(&buffer, UInt32(toSkip))
        }
    }

    func fillLevel() -> Float {
        guard initialized, capacityBytes > 0 else { return 0 }
        var availableBytes: UInt32 = 0
        _ = TPCircularBufferTail(&buffer, &availableBytes)
        return Float(availableBytes) / Float(capacityBytes)
    }

    func availableBytes() -> Int {
        guard initialized else { return 0 }
        var availableBytes: UInt32 = 0
        _ = TPCircularBufferTail(&buffer, &availableBytes)
        return Int(availableBytes)
    }

    func clear() {
        if initialized {
            TPCircularBufferCleanup(&buffer)
            buffer = TPCircularBuffer()
            initialized = false
        }
        capacityBytes = 0
    }

    deinit {
        clear()
    }
}
