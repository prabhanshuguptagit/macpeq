import Foundation
import CAtomics

/// Thread-safe parametric EQ processor.
///
/// Coefficients are double-buffered: the UI thread writes to the inactive buffer,
/// then flips an atomic index (release). The audio thread reads the active index
/// (acquire) and uses that buffer. No locks in the real-time path.
///
/// Filter state (x1, x2, y1, y2) is single-buffered and lives only on the
/// audio thread — it is never touched by the UI thread.
@available(macOS 14.2, *)
final class EQProcessor {
    let bandCount: Int
    let channelCount: Int
    private let sampleRate: Float

    // Double-buffered coefficients: [bufferIndex][channel * bandCount + band]
    private let coeffBuffers: [UnsafeMutablePointer<BiquadCoefficients>]
    private let activeIndex: UnsafeMutableRawPointer // catomic_int32_t

    // Single-buffered state: [channel * bandCount + band]
    private let states: UnsafeMutablePointer<BiquadState>

    init(bandCount: Int, channelCount: Int, sampleRate: Float) {
        self.bandCount = bandCount
        self.channelCount = channelCount
        self.sampleRate = sampleRate

        let total = bandCount * channelCount

        states = .allocate(capacity: total)
        states.initialize(repeating: BiquadState(), count: total)

        let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        coeffBuffers = [
            .allocate(capacity: total),
            .allocate(capacity: total)
        ]
        coeffBuffers[0].initialize(repeating: identity, count: total)
        coeffBuffers[1].initialize(repeating: identity, count: total)

        activeIndex = catomics_create_int32(0)
    }

    deinit {
        let total = bandCount * channelCount
        states.deinitialize(count: total)
        states.deallocate()
        coeffBuffers[0].deinitialize(count: total)
        coeffBuffers[0].deallocate()
        coeffBuffers[1].deinitialize(count: total)
        coeffBuffers[1].deallocate()
        catomics_destroy_int32(activeIndex)
    }

    /// Reset all filter state (e.g. after a device switch). Call from the audio thread only.
    func resetState() {
        let total = bandCount * channelCount
        for i in 0..<total {
            states[i].reset()
        }
    }

    /// Update coefficients from the UI/main thread. This is the ONLY method
    /// that should be called from outside the audio callback.
    func updateBands(_ bands: [EQBand]) {
        let currentActive = Int(catomics_load_int32(activeIndex))
        let inactiveIdx = 1 - currentActive
        let ptr = coeffBuffers[inactiveIdx]

        // Reset to identity (bypass)
        let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        let total = bandCount * channelCount
        for i in 0..<total {
            ptr[i] = identity
        }

        // Write enabled bands
        for (bandIdx, band) in bands.enumerated() where band.enabled && bandIdx < bandCount {
            let c = BiquadMath.coefficients(
                type: band.type,
                frequency: band.frequency,
                gain: band.gain,
                q: band.q,
                sampleRate: sampleRate
            )
            for ch in 0..<channelCount {
                ptr[ch * bandCount + bandIdx] = c
            }
        }

        // Flip the atomic index so the audio thread sees the new buffer
        catomics_store_int32(activeIndex, Int32(inactiveIdx))
    }

    /// Process a non-interleaved channel buffer in-place. Audio thread only.
    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int) {
        guard channel < channelCount else { return }
        let bufferIdx = Int(catomics_load_int32(activeIndex))
        let coeffs = coeffBuffers[bufferIdx]
        let stateBase = channel * bandCount

        for frame in 0..<frameCount {
            var sample = buffer[frame]
            for band in 0..<bandCount {
                let c = coeffs[stateBase + band]
                let s = states.advanced(by: stateBase + band)
                let x1 = s.pointee.x1
                let x2 = s.pointee.x2
                let y1 = s.pointee.y1
                let y2 = s.pointee.y2
                let output = c.b0 * sample
                           + c.b1 * x1
                           + c.b2 * x2
                           - c.a1 * y1
                           - c.a2 * y2
                s.pointee.x2 = x1
                s.pointee.x1 = sample
                s.pointee.y2 = y1
                s.pointee.y1 = output
                sample = output
            }
            buffer[frame] = sample
        }
    }

    /// Process an interleaved buffer in-place. Audio thread only.
    @inline(__always)
    func processInterleaved(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        let bufferIdx = Int(catomics_load_int32(activeIndex))
        let coeffs = coeffBuffers[bufferIdx]
        let maxCh = min(channels, channelCount)

        for frame in 0..<frameCount {
            let base = frame * channels
            for ch in 0..<maxCh {
                let stateBase = ch * bandCount
                var sample = buffer[base + ch]
                for band in 0..<bandCount {
                    let c = coeffs[stateBase + band]
                    let s = states.advanced(by: stateBase + band)
                    let x1 = s.pointee.x1
                    let x2 = s.pointee.x2
                    let y1 = s.pointee.y1
                    let y2 = s.pointee.y2
                    let output = c.b0 * sample
                               + c.b1 * x1
                               + c.b2 * x2
                               - c.a1 * y1
                               - c.a2 * y2
                    s.pointee.x2 = x1
                    s.pointee.x1 = sample
                    s.pointee.y2 = y1
                    s.pointee.y1 = output
                    sample = output
                }
                buffer[base + ch] = sample
            }
        }
    }
}
