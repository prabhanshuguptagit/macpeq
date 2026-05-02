import Foundation
import Accelerate
import CAtomics

/// Thread-safe parametric EQ processor backed by vDSP's multichannel biquad cascade.
///
/// Architecture:
/// - One `vDSP_biquadm_Setup` owns coefficients + filter state for ALL channels and
///   ALL bands in a single SIMD-accelerated cascade. This is ~5–10× faster than
///   a hand-rolled scalar Direct Form I biquad loop in Swift.
/// - The UI thread calls `updateBands(_:)`, which writes new target coefficients
///   and an active-mask into pending buffers, then sets a dirty flag (atomic store).
/// - The audio thread calls `processInterleaved(...)`. At the top of each call,
///   if the dirty flag is set, the audio thread atomically clears it and pushes
///   the pending state into the setup via:
///     - `vDSP_biquadm_SetTargetsSingle` — ramped coefficient changes (no zipper noise)
///     - `vDSP_biquadm_SetActiveFilters` — bypassed bands skip processing entirely
/// - The vDSP setup is therefore mutated only from the audio thread, satisfying
///   Apple's "should only be used in one thread at a time" rule.
///
/// The pending buffers are a single-writer/single-reader handoff guarded by the
/// dirty flag — safe for one UI thread + one audio thread. Multiple concurrent
/// `updateBands` callers must be serialized externally (the existing
/// `audioQueue.async` wrapper in `AudioEngine.updateEQ` already does this).
@available(macOS 14.2, *)
final class EQProcessor {
    let bandCount: Int
    let channelCount: Int
    private let sampleRate: Float

    // vDSP biquad cascade — owns coefficients AND filter state internally.
    private let setup: vDSP_biquadm_Setup

    // Pending coefficients (5 floats per section, M*N sections).
    // Layout matches vDSP: per-channel groups of N sections, each {b0,b1,b2,a1,a2}.
    // Float (not Double) because we use SetTargetsSingle for ramped updates.
    private let pendingCoeffs: UnsafeMutablePointer<Float>
    // Pending active mask: one Bool (C `bool`) per band.
    private let pendingActive: UnsafeMutablePointer<Bool>
    // Atomic dirty flag (catomic_int32_t).
    private let pendingDirty: UnsafeMutableRawPointer

    // Per-channel scratch — vDSP_biquadm is non-interleaved (float**),
    // but the render callback gives us interleaved data.
    private var channelScratch: [UnsafeMutablePointer<Float>] = []
    private let channelScratchCapacity: Int

    // Persistent channel-pointer arrays handed to vDSP_biquadm. Allocated once
    // to avoid per-callback allocation. Sized to channelCount (what setup expects).
    // Non-optional element type — vDSP wants `UnsafePointer<Float>*`, not
    // `Optional<UnsafePointer<Float>>*`.
    private var inPtrStorage: ContiguousArray<UnsafePointer<Float>>
    private var outPtrStorage: ContiguousArray<UnsafeMutablePointer<Float>>

    // Ramping params for SetTargetsSingle. rate=0.995, threshold=0.0001 ramps to
    // ~99.99% of target in roughly 1500 samples (~30ms @ 48kHz) — smooth enough
    // to kill zipper noise on slider drags, fast enough that big jumps don't lag.
    private let rampRate: Float = 0.995
    private let rampThreshold: Float = 0.0001

    init?(bandCount: Int, channelCount: Int, sampleRate: Float, maxFrames: Int) {
        guard bandCount > 0, channelCount > 0, maxFrames > 0 else { return nil }
        self.bandCount = bandCount
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.channelScratchCapacity = maxFrames

        let totalSections = bandCount * channelCount
        let coeffCount = totalSections * 5

        // vDSP_biquadm_CreateSetup takes Double* (it's the only flavor — the
        // single/double distinction in this API is about the *signal* precision,
        // not the coefficients).
        let initialDouble = UnsafeMutablePointer<Double>.allocate(capacity: coeffCount)
        defer { initialDouble.deallocate() }
        for i in 0..<totalSections {
            initialDouble[i*5 + 0] = 1.0  // b0
            initialDouble[i*5 + 1] = 0.0  // b1
            initialDouble[i*5 + 2] = 0.0  // b2
            initialDouble[i*5 + 3] = 0.0  // a1
            initialDouble[i*5 + 4] = 0.0  // a2
        }
        guard let s = vDSP_biquadm_CreateSetup(initialDouble,
                                               vDSP_Length(bandCount),
                                               vDSP_Length(channelCount)) else {
            return nil
        }
        self.setup = s

        // Pending buffer: identity coefficients to start.
        pendingCoeffs = .allocate(capacity: coeffCount)
        pendingCoeffs.initialize(repeating: 0, count: coeffCount)
        for i in 0..<totalSections { pendingCoeffs[i*5 + 0] = 1.0 }

        pendingActive = .allocate(capacity: bandCount)
        pendingActive.initialize(repeating: false, count: bandCount)

        pendingDirty = catomics_create_int32(0)

        // Channel scratch + persistent pointer arrays.
        for _ in 0..<channelCount {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            p.initialize(repeating: 0, count: maxFrames)
            channelScratch.append(p)
        }
        inPtrStorage = ContiguousArray(channelScratch.map { UnsafePointer($0) })
        outPtrStorage = ContiguousArray(channelScratch)
    }

    deinit {
        vDSP_biquadm_DestroySetup(setup)
        pendingCoeffs.deinitialize(count: bandCount * channelCount * 5)
        pendingCoeffs.deallocate()
        pendingActive.deinitialize(count: bandCount)
        pendingActive.deallocate()
        catomics_destroy_int32(pendingDirty)
        for p in channelScratch {
            p.deinitialize(count: channelScratchCapacity)
            p.deallocate()
        }
    }

    /// Reset all filter state. Safe to call while audio is stopped, or on the
    /// audio thread between callbacks.
    func resetState() {
        vDSP_biquadm_ResetState(setup)
    }

    // MARK: - UI thread

    /// Update bands from any thread. Writes pending state and flags it dirty;
    /// the audio thread applies the change at the top of its next callback.
    func updateBands(_ bands: [EQBand]) {
        // Compute coefficients once per band — both channels get identical EQ.
        var perBandCoeffs = [BiquadCoefficients](
            repeating: BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0),
            count: bandCount
        )
        var perBandActive = [Bool](repeating: false, count: bandCount)

        for (bandIdx, band) in bands.enumerated() where bandIdx < bandCount {
            if band.enabled {
                perBandCoeffs[bandIdx] = BiquadMath.coefficients(
                    type: band.type,
                    frequency: band.frequency,
                    gain: band.gain,
                    q: band.q,
                    sampleRate: sampleRate
                )
                perBandActive[bandIdx] = true
            }
            // Disabled bands: leave coefficients at identity. SetActiveFilters
            // will skip them anyway, but identity coefficients mean that if the
            // user re-enables a band, the ramp starts from a sane (transparent)
            // state rather than whatever was there before.
        }

        // Write into pending coefficient buffer (vDSP layout: per-channel cascade).
        for ch in 0..<channelCount {
            for band in 0..<bandCount {
                let dst = (ch * bandCount + band) * 5
                let c = perBandCoeffs[band]
                pendingCoeffs[dst + 0] = c.b0
                pendingCoeffs[dst + 1] = c.b1
                pendingCoeffs[dst + 2] = c.b2
                pendingCoeffs[dst + 3] = c.a1
                pendingCoeffs[dst + 4] = c.a2
            }
        }
        for band in 0..<bandCount {
            pendingActive[band] = perBandActive[band]
        }

        // Publish — release semantics in CAtomics ensure the writes above are
        // visible to the audio thread before it sees the dirty flag.
        catomics_store_int32(pendingDirty, 1)
    }

    // MARK: - Audio thread

    /// Apply any pending coefficient/active-mask changes to the live setup.
    /// Called from `processInterleaved` — audio thread only.
    @inline(__always)
    private func applyPendingIfNeeded() {
        // Atomic exchange: read prior value AND clear in one op, so a concurrent
        // updateBands that flips the flag again right after we read can't be lost.
        let wasDirty = catomics_exchange_int32(pendingDirty, 0)
        guard wasDirty == 1 else { return }

        // Ramped coefficient update — vDSP interpolates toward these targets
        // sample-by-sample on subsequent biquadm calls.
        vDSP_biquadm_SetTargetsSingle(
            setup,
            pendingCoeffs,
            rampRate,
            rampThreshold,
            0, 0,                                // start section, start channel
            vDSP_Length(bandCount),              // section count
            vDSP_Length(channelCount)            // channel count
        )

        // Active-section mask. Inactive sections are skipped entirely — this is
        // where the disabled-band CPU savings come from.
        vDSP_biquadm_SetActiveFilters(setup, pendingActive)
    }

    /// Process an interleaved buffer in-place. Audio thread only.
    func processInterleaved(buffer: UnsafeMutablePointer<Float>,
                            frameCount: Int,
                            channels: Int) {
        guard frameCount > 0, frameCount <= channelScratchCapacity else { return }
        applyPendingIfNeeded()

        let chToProcess = min(channels, channelCount)
        let n = Int32(frameCount)
        let interleavedStride = Int32(channels)

        // 1. Deinterleave EQ'd channels into per-channel scratch.
        // cblas_scopy is a strided vectorized copy — much faster than a Swift loop.
        for ch in 0..<chToProcess {
            cblas_scopy(n,
                        buffer.advanced(by: ch), interleavedStride,
                        channelScratch[ch], 1)
        }

        // 2. Run the cascade. In-place is allowed (in == out).
        // (inPtrStorage / outPtrStorage are sized to channelCount; if
        // chToProcess < channelCount, the unused channel pointers point at
        // scratch[0] — their output is overwritten and never read.)
        inPtrStorage.withUnsafeMutableBufferPointer { inBuf in
            outPtrStorage.withUnsafeMutableBufferPointer { outBuf in
                vDSP_biquadm(setup,
                             inBuf.baseAddress!, vDSP_Stride(1),
                             outBuf.baseAddress!, vDSP_Stride(1),
                             vDSP_Length(frameCount))
            }
        }

        // 3. Re-interleave EQ'd channels back into the output buffer.
        // Pass-through channels (>= chToProcess) were never touched so the
        // originals remain in `buffer` at their interleaved positions.
        for ch in 0..<chToProcess {
            cblas_scopy(n,
                        channelScratch[ch], 1,
                        buffer.advanced(by: ch), interleavedStride)
        }
    }
}
