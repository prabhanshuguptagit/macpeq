import Foundation
import CTPCircularBuffer

/// Lock-free SPSC ring buffer using TPCircularBuffer
/// Thread-safe: single producer (IOProc), single consumer (AUHAL render callback)
final class RingBuffer {
    private var circularBuffer: TPCircularBuffer
    private let bytesPerFrame: Int
    let capacityFrames: Int32
    let channels: Int
    
    init(capacityFrames: Int32, channels: Int, bytesPerSample: Int = MemoryLayout<Float>.size) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.bytesPerFrame = channels * bytesPerSample
        self.circularBuffer = TPCircularBuffer()
        let capacityBytes = UInt32(Int(capacityFrames) * bytesPerFrame)
        _TPCircularBufferInit(&circularBuffer, capacityBytes, MemoryLayout<TPCircularBuffer>.size)
    }
    
    deinit {
        TPCircularBufferCleanup(&circularBuffer)
    }
    
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
    
    func clear() {
        // Consume all available data
        var availableBytes: UInt32 = 0
        while let _ = TPCircularBufferTail(&circularBuffer, &availableBytes) {
            if availableBytes == 0 { break }
            TPCircularBufferConsume(&circularBuffer, availableBytes)
        }
    }
}
