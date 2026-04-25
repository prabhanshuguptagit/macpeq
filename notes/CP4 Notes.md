# Checkpoint 4: Full Filter Bank + Automated Verification — Expanded Specification (v2)

## Goal

Extend the single hardcoded biquad from CP2/CP3 into an N-band parametric EQ with double-buffered, lock-free parameter updates. Verify correctness with automated unit tests, not by ear.

## Success Gate

Unit test passes — impulse response FFT matches theoretical magnitude response within ±0.5dB at each band's center frequency. All edge-case tests pass (0dB passthrough, extreme Q/gain, disabled bands, mid-buffer parameter swap, filter type correctness).

---

## What Changes From CP3

CP3 has two `BiquadFilter?` properties (`leftFilter`, `rightFilter`) on `AudioEngine`, with filter state saved back via `if var left = leftFilter` in the render callback. CP4 replaces this entirely with a standalone `EQProcessor` class that owns the filter bank, the double-buffer mechanism, and the output gain protection. `AudioEngine` holds a single `EQProcessor` reference and calls `process()` — it no longer knows anything about individual filters.

### Files Added

| File | Purpose |
|------|---------|
| `Audio/EQProcessor.swift` | Filter bank coordinator: double-buffered coefficients, per-channel filter state, output gain protection |
| `Model/EQBand.swift` | Band parameter struct (frequency, gain, Q, type, enabled) |
| `Model/FilterType.swift` | Already exists in `BiquadFilter.swift` — extract to its own file |
| `Tests/EQProcessorTests.swift` | Impulse response FFT verification + edge-case tests |

### Files Modified

| File | Change |
|------|--------|
| `AudioEngine.swift` | Remove `leftFilter`/`rightFilter`/`filterEnabled`. Add `eqProcessor: EQProcessor`. Simplify `handleAUHALRender` to delegate to `eqProcessor.process()`. |
| `BiquadFilter.swift` | No structural changes. `FilterType` enum moves to its own file but the type itself is unchanged. |

---

## Step 1: Define `EQBand`

```swift
// Model/EQBand.swift

import Foundation

struct EQBand: Codable, Identifiable {
    let id: UUID
    var frequency: Float   // Hz, clamped to 20–20000
    var gain: Float        // dB, clamped to -20 to +20
    var q: Float           // 0.1 to 10.0
    var type: FilterType   // peak, lowShelf, highShelf, lowPass, highPass, notch
    var enabled: Bool

    init(
        id: UUID = UUID(),
        frequency: Float,
        gain: Float = 0.0,
        q: Float = 1.0,
        type: FilterType = .peak,
        enabled: Bool = true
    ) {
        self.id = id
        self.frequency = frequency.clamped(to: 20...20000)
        self.gain = gain.clamped(to: -20...20)
        self.q = q.clamped(to: 0.1...10.0)
        self.type = type
        self.enabled = enabled
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
```

### Default Band Configuration

Hardcode 10 bands at ISO center frequencies, all at 0dB (flat). This is the runtime default — unit tests will use their own non-zero configurations to verify filter math.

```swift
static let defaultBands: [EQBand] = [
    EQBand(frequency: 31),
    EQBand(frequency: 63),
    EQBand(frequency: 125),
    EQBand(frequency: 250),
    EQBand(frequency: 500),
    EQBand(frequency: 1000),
    EQBand(frequency: 2000),
    EQBand(frequency: 4000),
    EQBand(frequency: 8000),
    EQBand(frequency: 16000),
]
```

---

## Step 2: Design the Double-Buffer Mechanism

This is the core of `EQProcessor` and the part CP4 in the PRD left most ambiguous. Here's the concrete design.

### Memory Layout

Two coefficient snapshots exist at all times. Each snapshot is a flat `UnsafeMutableBufferPointer<BiquadCoefficients>` sized `bandCount × channelCount`. The audio thread reads from one; the UI thread writes to the other; an atomic index says which is which.

**v2 change:** Pre-gain is now part of the snapshot (a `CoefficientsSnapshot` wrapper struct), not a separate stored property. This eliminates the ordering dependency the reviewer flagged — the audio thread gets a consistent (coefficients + preGain) pair via a single atomic index load.

```
Snapshot A: CoefficientsSnapshot {
    coefficients: [band0_ch0, band0_ch1, band1_ch0, band1_ch1, ... bandN_ch1]
    preGainLinear: Float
}
Snapshot B: CoefficientsSnapshot { ... identical layout }

activeIndex (atomic): 0 or 1
  - Audio thread reads snapshot[activeIndex]
  - UI thread writes to snapshot[1 - activeIndex], then stores activeIndex = 1 - activeIndex
```

**Why `UnsafeMutableBufferPointer<BiquadCoefficients>` and not `[[BiquadCoefficients]]`?**

Swift `Array` subscript access goes through bounds checking which can trap. In an optimized build the compiler *may* elide this, but it's not guaranteed, and a trap in the audio thread is fatal. `UnsafeMutableBufferPointer` gives direct indexed access with no bounds check and no ARC overhead (since `BiquadCoefficients` is a value type with only `Float` fields).

**Why not just two `[BiquadCoefficients]` arrays with `withUnsafeMutableBufferPointer`?**

You'd need to hold the buffer pointer across the entire render callback, which means the closure can't return until processing is done. That works but is awkward to compose. Owning the raw allocation directly is simpler and makes the real-time safety guarantees explicit.

### The Atomic Index

Use `import Synchronization` (Swift 6+) for `Atomic<Int>`:

```swift
import Synchronization

private let activeIndex = Atomic<Int>(0)
```

If targeting Swift 5.x with the swift-atomics package instead:

```swift
import Atomics

private let activeIndex = ManagedAtomic<Int>(0)
```

The audio thread reads with `activeIndex.load(ordering: .acquiring)`. The UI thread stores with `activeIndex.store(newValue, ordering: .releasing)`. The acquire/release pair ensures the audio thread sees fully written coefficients after the index flip — not a partially written snapshot.

### Filter State Separation

**Coefficients** live in the double-buffered snapshots — they're what the UI thread updates. **Filter state** (`x1, x2, y1, y2`) must persist across render callbacks and must *not* be swapped when coefficients change. State lives in a *separate* flat buffer, one entry per band per channel, owned exclusively by the audio thread:

```
filterState: UnsafeMutableBufferPointer<FilterState>
  [band0_ch0, band0_ch1, band1_ch0, band1_ch1, ... bandN_ch1]

struct FilterState {
    var x1: Float = 0, x2: Float = 0
    var y1: Float = 0, y2: Float = 0
}
```

This separation means a coefficient swap doesn't reset the filter's memory of recent samples. Without this, every parameter change would cause an audible discontinuity (a click or pop) as the filter re-converges from zero state.

**When state *should* be reset:** Only on device switch (sample rate changed, old state is meaningless) or when a band is re-enabled after being disabled. `EQProcessor` exposes a `resetState()` method that zeros the entire state buffer; `AudioEngine` calls it during rebuild.

---

## Step 3: Implement `EQProcessor`

```swift
// Audio/EQProcessor.swift

import Foundation
import Synchronization  // Swift 6+ Atomic

/// Biquad coefficients only — no filter state
struct BiquadCoefficients {
    var b0: Float, b1: Float, b2: Float
    var a1: Float, a2: Float
    var enabled: Bool
}

/// Per-band per-channel filter memory
struct FilterState {
    var x1: Float = 0, x2: Float = 0
    var y1: Float = 0, y2: Float = 0
}

/// Groups coefficients + pre-gain into a single snapshot so the audio thread
/// gets a consistent pair from one atomic index load.
struct CoefficientsSnapshot {
    let buffer: UnsafeMutableBufferPointer<BiquadCoefficients>
    var preGainLinear: Float

    init(capacity: Int) {
        buffer = .allocate(capacity: capacity)
        let passthrough = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0, enabled: false)
        buffer.initialize(repeating: passthrough)
        preGainLinear = 1.0
    }

    func deallocate() {
        buffer.deallocate()
    }
}

final class EQProcessor {

    // MARK: - Configuration (set once at init, never changes on audio thread)

    let bandCount: Int
    let channelCount: Int
    private let sampleRate: Float

    // MARK: - Double-buffered coefficients + pre-gain

    /// Two snapshots, each containing coefficients (bandCount × channelCount)
    /// and the associated pre-gain value. The audio thread gets both from a
    /// single atomic index load — no ordering dependency between separate fields.
    private var snapshots: (CoefficientsSnapshot, CoefficientsSnapshot)

    /// Which snapshot the audio thread reads. 0 or 1.
    private let activeIndex = Atomic<Int>(0)

    // MARK: - Filter state (audio thread only)

    /// Persistent filter memory. Same layout as coefficients.
    private let filterState: UnsafeMutableBufferPointer<FilterState>

    // MARK: - Debug-only audio thread guard

    /// Set by process() on entry, cleared on exit. resetState() asserts this
    /// is false. Stripped in release builds via #if DEBUG.
    #if DEBUG
    private let _audioThreadActive = Atomic<Bool>(false)
    #endif

    // MARK: - Bypass

    /// When true, process() copies input to output unchanged.
    /// Atomic so the UI thread can toggle without the double-buffer dance.
    private let _bypassed = Atomic<Bool>(false)
    var bypassed: Bool {
        get { _bypassed.load(ordering: .relaxed) }
        set { _bypassed.store(newValue, ordering: .relaxed) }
    }

    // MARK: - Init / Deinit

    init(bandCount: Int, channelCount: Int, sampleRate: Float) {
        self.bandCount = bandCount
        self.channelCount = channelCount
        self.sampleRate = sampleRate

        let count = bandCount * channelCount

        // Allocate coefficient snapshots (each includes pre-gain)
        self.snapshots = (
            CoefficientsSnapshot(capacity: count),
            CoefficientsSnapshot(capacity: count)
        )

        // Allocate filter state
        self.filterState = .allocate(capacity: count)
        self.filterState.initialize(repeating: FilterState())
    }

    deinit {
        snapshots.0.deallocate()
        snapshots.1.deallocate()
        filterState.deallocate()
    }

    // MARK: - UI Thread: Update Bands

    /// Called from the UI thread (or any non-audio thread).
    /// Writes new coefficients to the INACTIVE snapshot, then flips the atomic index.
    /// Recomputes all bands unconditionally — 10 bands × trig functions is <1µs,
    /// not worth the complexity of dirty tracking.
    ///
    /// Band count must match `self.bandCount`. If it doesn't (e.g., a preset with
    /// a different band count), the caller must pad/truncate before calling.
    /// In debug builds, a mismatch traps. In release builds, it logs and returns
    /// to avoid crashing the app.
    func updateBands(_ bands: [EQBand]) {
        guard bands.count == bandCount else {
            assertionFailure("Band count mismatch: expected \(bandCount), got \(bands.count)")
            return
        }

        let current = activeIndex.load(ordering: .relaxed)
        let inactive = 1 - current

        // Get the inactive snapshot
        var snapshot = inactive == 0 ? snapshots.0 : snapshots.1

        // Compute coefficients and write to inactive snapshot
        for (i, band) in bands.enumerated() {
            let c: BiquadCoefficients
            if band.enabled {
                let raw = BiquadMath.coefficients(
                    type: band.type,
                    frequency: band.frequency,
                    gain: band.gain,
                    q: band.q,
                    sampleRate: sampleRate
                )
                c = BiquadCoefficients(
                    b0: raw.b0, b1: raw.b1, b2: raw.b2,
                    a1: raw.a1, a2: raw.a2,
                    enabled: true
                )
            } else {
                c = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0, enabled: false)
            }

            // Write same coefficients for every channel at this band index
            for ch in 0..<channelCount {
                snapshot.buffer[i * channelCount + ch] = c
            }
        }

        // Compute pre-gain for output protection (Stage 1).
        // Approximate worst-case gain as sum of all positive band gains.
        // This is conservative (real peaks are lower due to Q spreading),
        // but safe and cheap.
        var worstCaseGainDB: Float = 0
        for band in bands where band.enabled && band.gain > 0 {
            worstCaseGainDB += band.gain
        }
        snapshot.preGainLinear = worstCaseGainDB > 0
            ? powf(10.0, -worstCaseGainDB / 20.0)
            : 1.0

        // Write the snapshot back (it's a value type)
        if inactive == 0 {
            snapshots.0 = snapshot
        } else {
            snapshots.1 = snapshot
        }

        // Flip — the audio thread will pick this up on its next callback.
        // Release ordering ensures all coefficient + pre-gain writes above
        // are visible to the audio thread's acquiring load.
        activeIndex.store(inactive, ordering: .releasing)
    }

    // MARK: - Audio Thread: Process

    /// Process a buffer of audio samples IN PLACE.
    /// Called from the AUHAL render callback. No allocations, no locks, no ARC.
    ///
    /// - Parameters:
    ///   - buffer: Pointer to Float samples for a single channel
    ///   - frameCount: Number of frames in the buffer
    ///   - channel: Channel index (0 = left, 1 = right, etc.)
    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int) {
        guard !_bypassed.load(ordering: .relaxed) else { return }
        guard channel < channelCount else { return }

        #if DEBUG
        _audioThreadActive.store(true, ordering: .relaxed)
        defer { _audioThreadActive.store(false, ordering: .relaxed) }
        #endif

        // Single atomic load gets us both coefficients and pre-gain — consistent pair.
        let idx = activeIndex.load(ordering: .acquiring)
        let snapshot = idx == 0 ? snapshots.0 : snapshots.1
        let preGain = snapshot.preGainLinear

        // Run each enabled band in series, with pre-gain folded into the first
        // sample read and hard clamp applied after the last band.
        // This avoids separate passes over the buffer for pre-gain and clamping.
        for band in 0..<bandCount {
            let slot = band * channelCount + channel
            let c = snapshot.buffer[slot]
            guard c.enabled else { continue }

            var state = filterState[slot]
            for i in 0..<frameCount {
                var x = buffer[i]
                // Apply pre-gain on first enabled band only
                if band == 0 && preGain < 1.0 {
                    // Note: this branch is constant for the entire buffer,
                    // so the branch predictor handles it. Alternatively,
                    // do a separate pre-gain pass before the loop — the
                    // compiler will likely vectorize it. Both approaches
                    // are valid; this one avoids the extra traversal.
                }
                let y = c.b0 * x + c.b1 * state.x1 + c.b2 * state.x2
                        - c.a1 * state.y1 - c.a2 * state.y2
                state.x2 = state.x1; state.x1 = x
                state.y2 = state.y1; state.y1 = y
                buffer[i] = y
            }
            filterState[slot] = state
        }

        // Stage 1: Apply pre-gain before filter bank to prevent clipping.
        // Done as a separate pass for clarity and because vDSP_vsmul can
        // vectorize this. The cost of an extra pass over a 512-sample buffer
        // is negligible vs. the biquad math.
        //
        // IMPORTANT: pre-gain must be applied BEFORE the filter bank,
        // so we actually need to do this first. Restructured below.
    }

    // MARK: - State Management

    /// Reset all filter state to zero. Call on device switch or sample rate change.
    /// Must NOT be called while the audio thread is in process().
    /// AudioEngine ensures this by calling it only during teardown/rebuild,
    /// when the AUHAL is stopped.
    func resetState() {
        #if DEBUG
        assert(!_audioThreadActive.load(ordering: .relaxed),
               "resetState() called while audio thread is processing — this is a race condition")
        #endif

        for i in 0..<filterState.count {
            filterState[i] = FilterState()
        }
    }
}
```

**Wait — the process() method above has a structural issue with the pre-gain placement.** Let me fix that. The pre-gain must happen before any biquad processing, and the clamp must happen after all bands. Here's the corrected version:

```swift
    // MARK: - Audio Thread: Process (corrected)

    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int) {
        guard !_bypassed.load(ordering: .relaxed) else { return }
        guard channel < channelCount else { return }

        #if DEBUG
        _audioThreadActive.store(true, ordering: .relaxed)
        defer { _audioThreadActive.store(false, ordering: .relaxed) }
        #endif

        // Single atomic load gets both coefficients and pre-gain.
        let idx = activeIndex.load(ordering: .acquiring)
        let snapshot = idx == 0 ? snapshots.0 : snapshots.1

        // Stage 1: Pre-gain to prevent clipping
        let preGain = snapshot.preGainLinear
        if preGain < 1.0 {
            for i in 0..<frameCount {
                buffer[i] *= preGain
            }
        }

        // Run each enabled band in series
        for band in 0..<bandCount {
            let slot = band * channelCount + channel
            let c = snapshot.buffer[slot]
            guard c.enabled else { continue }

            // Process in-place using Direct Form I
            var state = filterState[slot]
            for i in 0..<frameCount {
                let x = buffer[i]
                let y = c.b0 * x + c.b1 * state.x1 + c.b2 * state.x2
                        - c.a1 * state.y1 - c.a2 * state.y2
                state.x2 = state.x1; state.x1 = x
                state.y2 = state.y1; state.y1 = y
                buffer[i] = y
            }
            filterState[slot] = state
        }

        // Stage 2: Hard safety clamp (fallback)
        for i in 0..<frameCount {
            let s = buffer[i]
            if s > 1.0 { buffer[i] = 1.0 }
            else if s < -1.0 { buffer[i] = -1.0 }
        }
    }
```

### Key Design Decisions Explained

**Why recompute all bands in `updateBands()`, not just the dirty one?**

Ten bands of `BiquadMath.coefficients()` is roughly 10 × (2 trig calls + a few multiplies) — under 1µs on Apple Silicon. Dirty tracking adds a `Set<UUID>` lookup, a conditional branch, and a code path that's harder to reason about for zero measurable benefit. The audio thread doesn't care whether one coefficient changed or ten; it reads the whole snapshot regardless.

**Why is `preGainLinear` part of the snapshot (v2 change)?**

The v1 design stored `preGainLinear` as a separate property, relying on the release/acquire ordering of `activeIndex` to synchronize it. This works *only if* `preGainLinear` is written before `activeIndex.store()` and read after `activeIndex.load()`. The original code read `preGainLinear` *before* the acquiring load, which broke that guarantee — the audio thread could see the new pre-gain with old coefficients, or vice versa. Moving it into the snapshot eliminates this entirely: one atomic load → one consistent (coefficients, preGain) pair.

**Why `assertionFailure` + `return` instead of `precondition` in `updateBands()`?**

`precondition` traps in release builds. If a preset with the wrong band count ever reaches `updateBands()`, that would crash the app. The new version traps in debug (so you catch it during development) but gracefully no-ops in release (the EQ stays on the previous coefficients, which is better than crashing). The caller is responsible for padding/truncating bands before calling.

**Why clamp instead of `fminf`/`fmaxf`?**

The branch-based clamp (`if s > 1.0`) compiles to a single `fcsel` on ARM, same as `fminf`/`fmaxf`. Either is fine. The branch version is more readable and the compiler will optimize it identically.

**Why a debug-only audio thread guard?**

The reviewer pointed out that `resetState()` must not be called while the audio thread is in `process()`, but this contract was enforced only by a comment. The atomic flag `_audioThreadActive` makes it a runtime assertion in debug builds. Stripped in release via `#if DEBUG` so there's zero cost in production.

---

## Step 4: Integrate Into `AudioEngine`

### Remove CP2 Properties

Delete from `AudioEngine.swift`:

```swift
// DELETE these:
private var leftFilter: BiquadFilter?
private var rightFilter: BiquadFilter?
private var filterEnabled: Bool = true
```

```swift
// DELETE this method:
private func initFilters(sampleRate: Float) { ... }
```

### Add `EQProcessor`

```swift
private var eqProcessor: EQProcessor?
```

Create it in `performStart()`, after the tap format is known but before `startAudio()`:

```swift
// After ring buffer creation, before setupIOProc():
eqProcessor = EQProcessor(
    bandCount: 10,
    channelCount: Int(tapFormat.mChannelsPerFrame),
    sampleRate: Float(tapFormat.mSampleRate)
)
// Load default bands (all flat)
eqProcessor?.updateBands(EQBand.defaultBands)
```

### Simplify `handleAUHALRender`

Replace the entire CP2 filter block with:

```swift
private func handleAUHALRender(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    let bufferList = UnsafeMutableAudioBufferListPointer(buffers)
    let requestedFrames = Int(frames)

    var channelOffset = 0
    for buffer in bufferList {
        guard let data = buffer.mData else { continue }

        let dest = data.assumingMemoryBound(to: Float.self)
        let channelsInBuffer = Int(buffer.mNumberChannels)

        // Read from ring buffer
        let readFrames = ringBuffer?.read(into: dest, frameCount: requestedFrames) ?? 0

        // Zero-fill underrun
        if readFrames < requestedFrames {
            let zeroBytes = (requestedFrames - readFrames) * channelsInBuffer * MemoryLayout<Float>.size
            memset(dest.advanced(by: readFrames * channelsInBuffer), 0, zeroBytes)
        }

        // Apply EQ — process each channel in this buffer
        if readFrames > 0, let eq = eqProcessor {
            if channelsInBuffer == 1 {
                // Non-interleaved: one buffer = one channel
                eq.process(buffer: dest, frameCount: readFrames, channel: channelOffset)
            } else {
                // Interleaved: per-sample processing (rare path)
                processInterleaved(
                    data: dest,
                    frameCount: readFrames,
                    channelsInBuffer: channelsInBuffer,
                    channelOffset: channelOffset,
                    eq: eq
                )
            }
        }
        channelOffset += channelsInBuffer
    }
    return noErr
}

/// Interleaved processing helper. Processes per-sample per-channel.
/// The interleaved path is rare with Core Audio taps (almost always non-interleaved),
/// so simplicity is preferred over performance here. If profiling shows this matters,
/// add a pre-allocated scratch buffer for deinterleave→process→reinterleave.
private func processInterleaved(
    data: UnsafeMutablePointer<Float>,
    frameCount: Int,
    channelsInBuffer: Int,
    channelOffset: Int,
    eq: EQProcessor
) {
    let processChannels = min(channelsInBuffer, eq.channelCount - channelOffset)
    guard processChannels > 0 else { return }

    for ch in 0..<processChannels {
        for frame in 0..<frameCount {
            let idx = frame * channelsInBuffer + ch
            var tmpBuf = data[idx]
            eq.process(buffer: &tmpBuf, frameCount: 1, channel: channelOffset + ch)
            data[idx] = tmpBuf
        }
    }
}
```

### Handle Device Switch

In `rebuildForNewDevice()`, after creating the new `EQProcessor` (or reusing the old one if band count hasn't changed):

```swift
// If sample rate changed, we need a new EQProcessor
let newRate = Float(tapFormat.mSampleRate)
if eqProcessor == nil || Float(tapFormat.mSampleRate) != previousSampleRate {
    let bands = currentBands ?? EQBand.defaultBands  // preserve user's band settings
    eqProcessor = EQProcessor(
        bandCount: bands.count,
        channelCount: Int(tapFormat.mChannelsPerFrame),
        sampleRate: newRate
    )
    eqProcessor?.updateBands(bands)
} else {
    // Same rate, just reset state (old state from different clock domain)
    eqProcessor?.resetState()
}
```

The key insight: band *parameters* (what the user set) survive a device switch. Only the coefficients (which depend on sample rate) and the filter state (which depends on the signal history) get recalculated/reset.

---

## Step 5: Output Gain Protection Details

### Stage 1 — Auto Pre-Gain (Primary)

Computed in `updateBands()`. The worst-case gain estimate is the sum of all positive band gains. This is deliberately conservative — in practice, peaks with different center frequencies and finite Q values don't stack linearly. But overshooting the pre-gain just means slightly quieter output, which is harmless, whereas undershooting means clipping, which is audible.

Example: if the user has three bands at +6dB each, worst-case estimate is +18dB, so `preGainLinear = 10^(-18/20) ≈ 0.126`. The signal is scaled down by ~18dB before the filter bank, then the filter bank boosts it back up, netting roughly 0dB at the peaks. In practice the net gain will be slightly negative (the estimate was conservative), which is fine.

A more accurate approach would compute the actual composite magnitude response at a set of probe frequencies and use the true peak. This is more expensive (~50 probe points × 10 bands × H(z) evaluation) but still cheap enough for `updateBands()` (off the audio thread). It can be added as a refinement later without changing the architecture.

### Stage 2 — Hard Clamp (Fallback)

Applied per-sample after the entire filter bank. If this fires on more than a handful of samples per second, the pre-gain estimate needs tuning. Log when it fires (via a non-blocking counter, not `print()`).

### Where Not to Put It

Do NOT fold the pre-gain into the first biquad's coefficients (e.g., scaling `b0`). This couples gain protection to coefficient updates and makes the filter math harder to verify independently. Keep it as a separate linear multiply pass before the filter bank.

---

## Step 6: Interleaved vs Non-Interleaved Handling

The tap format from Core Audio taps is almost always **non-interleaved** — each buffer in the `AudioBufferList` has `mNumberChannels = 1` and contains samples for a single channel. The `handleAUHALRender` loop naturally handles this: each iteration increments `channelOffset`, calls `eq.process(channel: channelOffset)`, and the `EQProcessor` indexes into the right filter state slot.

For the rare interleaved case (some Bluetooth codecs), samples are packed `[L0, R0, L1, R1, ...]` in a single buffer with `mNumberChannels = 2`. The `processInterleaved` helper handles this with per-sample channel extraction. This is less efficient than bulk deinterleave→process→reinterleave, but the interleaved path is uncommon enough that the simplicity tradeoff is acceptable. If profiling shows this matters, add a pre-allocated scratch buffer to `EQProcessor` for deinterleaving.

### Channel Count Changes on Device Switch

A stereo device (2 channels) → mono Bluetooth device (1 channel) means the `EQProcessor` must be recreated with `channelCount = 1`. The band parameters are preserved; only coefficients and state are rebuilt. This is handled in the rebuild path (Step 4 above).

Going from 2 channels to a >2 channel device (e.g., a 4-channel USB interface): the `EQProcessor` should be created with `channelCount` matching the tap format. Bands are duplicated identically across all channels (same EQ curve everywhere). Channels beyond the `EQProcessor`'s channel count pass through unfiltered — the render callback checks `channel < eq.channelCount` before processing.

---

## Step 7: UI→DSP Update Throttling

During drag interactions (CP6), the UI fires parameter changes at display refresh rate (60–120Hz). The audio thread only picks up new coefficients once per buffer callback (~93Hz at 512 frames / 48kHz). Recomputing coefficients faster than the audio thread consumes them wastes CPU.

**Implementation (deferred to CP6 but designed for here):**

`EQState` (the `ObservableObject` that CP5/CP6 will introduce) holds a dirty flag. On any band parameter change, it sets the flag. A `DispatchSourceTimer` on the `stateQueue` fires every ~10ms. If the flag is set, it calls `eqProcessor.updateBands()` and clears the flag. This coalesces rapid changes into at most one coefficient update per audio buffer period.

For CP4 (no UI yet), `updateBands()` is called directly and infrequently (at startup, in tests), so no throttling is needed. But the `EQProcessor` API is already designed so that `updateBands()` can be called at any rate — the atomic swap means even unthrottled calls are safe, just wasteful.

---
## Step 8: Automated Tests
See CP4_Testing.md (only when you get to this step).

---

## Step 9: Verification Procedure

1. **All tests pass (Tests 1–9).** This is the hard gate — do not proceed to CP5 until every test is green.
2. **Manual smoke test:** Run the app with the 10-band EQ at default (flat). Play music for 5 minutes. Confirm no audible difference from CP3 passthrough (since all gains are 0dB). Then edit one band to +6dB at 1kHz in code, rebuild, confirm audible boost. Toggle bypass, confirm difference.
3. **Device switch with EQ active:** Switch output devices while EQ is processing. Confirm audio resumes with EQ intact on the new device (same curve shape, possibly different coefficients if sample rate changed).

---

## Summary of v2 Changes

| Change | Source | Rationale |
|--------|--------|-----------|
| `preGainLinear` moved into `CoefficientsSnapshot` | Reviewer + own analysis | Eliminates ordering dependency. Audio thread gets consistent (coefficients, preGain) pair from a single atomic load. The original code read preGain *before* the acquiring load, which could see new preGain with old coefficients. |
| Debug-only `_audioThreadActive` assertion on `resetState()` | Reviewer | The "don't call while processing" contract was enforced only by a comment. Now it's a runtime assertion in debug builds, zero cost in release. |
| `precondition` → `assertionFailure` + `guard return` in `updateBands()` | Own analysis | `precondition` traps in release. If a preset with wrong band count ever reaches this, the app crashes. Now it traps in debug (catches bugs early) and no-ops in release (better than crashing). |
| Test 1 pre-gain isolation via `disablePreGain` flag | Reviewer | Tests filter math independently of gain protection. The original test mirrored the implementation's pre-gain math rather than verifying it independently. |
| Test 1b: dedicated pre-gain test | Reviewer | Tests pre-gain as its own concern rather than tangled with impulse response verification. |
| Test 7 renamed to `testParameterSwapProducesNewResponse` | Reviewer | The old name ("mid-stream swap") oversold what it verified. It's sequential, not concurrent. Name now matches reality. |
| Tests 8–9: shelf / LP / HP filter type verification | Own analysis | Original tests only used `.peak`. Six filter types with different coefficient formulas, but only one was tested. Catches sign errors and copy-paste bugs in `BiquadMath`. |
| FFT scaling comment on `magnitudeAtFrequency` | Own analysis | `vDSP_fft_zrip` applies a factor of 2. Doesn't affect relative measurements but would confuse anyone comparing against hardcoded dB values. |
| Test 4 buffer size comment | Reviewer | Documents the decay time math so future authors don't blindly shrink the buffer for low-frequency extreme-Q tests. |
| `makeProcessor` helper | Cleanup | Reduces boilerplate for padding bands to 10 across all tests. |

### Not changed (and why)

| Item | Why left alone |
|------|----------------|
| Per-channel coefficient duplication | Correct tradeoff for simpler audio-thread indexing. Would only change if adding per-channel EQ. |
| Interleaved path performance | Rare path, acknowledged in comments, correct behavior. Optimize if profiling shows need. |
| Test 7 true concurrency test | That's a stress/fuzz test, not a unit test. Good to add later but not part of the CP4 gate. |
| Branch-based clamp vs `fminf`/`fmaxf` | Compiles identically on ARM. Readable as-is. |

---

## Relationship to Later Checkpoints

- **CP5 (Curve Display)** will read band parameters from `EQState` and compute `H(z)` for display. The `theoreticalMagnitude()` function from the test helpers is the same math CP5 needs — extract it to `BiquadMath` as a public method.
- **CP6 (Interactive Drag)** will call `eqProcessor.updateBands()` via `EQState`. The throttling mechanism described in Step 7 should be implemented at that point.
- **CP7 (Presets)** will serialize `[EQBand]` to JSON. `EQBand` is already `Codable`.
- **CP8 (Menu Bar)** will toggle `eqProcessor.bypassed` from the menu popover.
