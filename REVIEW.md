# Code Review - CP1 Implementation

## File: AudioEngine.swift (686 lines)

### Strengths ✅
1. **Clear lifecycle management** - `start()` → `stop()` with proper cleanup chain
2. **Comprehensive logging** - Every major operation logged with metadata
3. **Error handling** - OSStatus codes logged, early returns on failures
4. **State isolation** - Private vars properly encapsulated
5. **C callback compatibility** - File-scope `ioProcCallback` avoids closure issues

### Issues Found 🔧

#### 1. Thread Safety - RingBuffer (CRITICAL)
**Problem**: `head` and `tail` are regular Ints, modified from different threads without synchronization

**Current code:**
```swift
// IOProc thread writes:
head = (head + toWrite) & capacityMask

// AUHAL thread reads:
tail = (tail + toRead) & capacityMask
```

**Risk**: On Apple Silicon, weak memory ordering could cause:
- Reader sees partially written data
- Writer overtakes reader (corruption)
- Lost wakeups (stalled audio)

**Fix options:**
- Option A: Use `OSAtomic` (deprecated) or `stdatomic.h` via C interop
- Option B: Use `DispatchQueue` serial queue (adds latency)
- Option C: Single-buffer + ping-pong (double buffer)

**Recommendation**: For CP1, document the risk and fix in CP2 with atomics.

#### 2. Memory Management
**Issue**: `AudioEngine` passed as `Unmanaged` to C callbacks

```swift
Unmanaged.passUnretained(self).toOpaque()
```

**Risk**: If `AudioEngine` is deallocated while callbacks are in flight, crash.

**Current mitigation**: `isRunning` flag and `stop()` before deinit
**Better fix**: Use `AudioObjectAddPropertyListenerBlock` with dispatch queues instead of C callbacks

#### 3. Sample Rate Assumptions
**Hardcoded**: 48000 Hz throughout

```swift
private let sampleRate: Double = 48000  // Never READ from tap format!
```

**Risk**: Bluetooth headphones often use 44.1kHz or variable rates
**Fix**: Read `kAudioTapPropertyFormat` and set up `AudioConverter` if mismatch

#### 4. Magic Numbers
```swift
let ringBufferFrames: Int = 16384  // Why 16384? Should be 4x expected callback size
let bytesPerSample = MemoryLayout<Float>.size  // Assumes Float32, not validated
```

**Fix**: Calculate based on actual tap format

#### 5. Mute Behavior Workaround
```swift
tapDesc.muteBehavior = .unmuted  // TODO: Fix .muted on macOS 15
```

**Technical debt**: Using `.unmuted` causes double audio (original + processed)
**Impact**: Phase cancellation, echo effect
**Fix needed**: Investigate if device-specific tap has better `.muted` behavior

### Architecture Questions 🤔

#### Q: Should we use `AVAudioEngine` instead of raw HAL?
**Current**: Raw `AudioComponentInstanceNew` + `AudioUnit` + `AudioDeviceStart`
**Alternative**: `AVAudioEngine.installTap` + `mainMixerNode`

**Analysis:**
- AVAudioEngine: Higher level, easier device switching, but less control over tap
- Current approach: Full control, matches sudara/audiotee working examples
- **Verdict**: Stay with raw HAL for CP1-CP3, consider AVAudioEngine for UI polish

#### Q: IOProc vs Direct Read?
**Current**: `AudioDeviceCreateIOProcID` + `AudioDeviceStart`
**Alternative**: `AudioDeviceRead` in dedicated thread

**Analysis:**
- IOProc is Core Audio's preferred callback method
- Threaded read would need careful timing to match hardware clock
- **Verdict**: Keep IOProc, it's working

## File: RingBuffer.swift (74 lines)

### Review
Simple implementation, but **not thread-safe** as noted above.

### Suggested fix for CP2:
```swift
import Darwin.atomics  // or import stdatomic shim

final class RingBuffer {
    private var head: atomic_int = 0  // atomic
    private var tail: atomic_int = 0  // atomic
    
    func write(...) {
        // CAS loop or atomic store with release barrier
    }
    
    func read(...) {
        // Atomic load with acquire barrier
    }
}
```

## File: main.swift (46 lines)

### Review
Clean, minimal. Proper version check with `@available`.

### Minor issue:
Global `gEngine` could be eliminated by using a singleton pattern or proper signal handling.

## File: Logger.swift (51 lines)

### Review
Good approach with dual output (stderr + file). 

### Suggested improvement:
Add log level filtering (DEBUG/INFO/ERROR) to reduce noise in production.

## Overall Assessment

### Complexity Score: 7/10
- Audio HAL APIs are complex (inherent)
- 686 lines for single-file coordinator is manageable
- Could benefit from splitting: `TapManager`, `OutputRouter`, `AudioEngine`

### Technical Debt Summary

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| P0 | Ring buffer atomics | Medium | Fixes audio glitches |
| P1 | Sample rate detection | Low | Prevents 44.1kHz issues |
| P1 | Mute behavior fix | High | Clean passthrough |
| P2 | Split AudioEngine | Medium | Maintainability |
| P2 | Add unit tests | High | CP4 FFT verification |

## Recommendations for CP2

1. **Fix thread safety first** - Use atomics in RingBuffer
2. **Add format negotiation** - Read tap ASBD, setup converter if needed
3. **Device property listener** - Register for default device changes
4. **Simplify logging** - Remove sample-level debug, keep operational metrics

## Metrics

```bash
# Code size
wc -l Sources/MacPEQ/*.swift
# 686 AudioEngine.swift
#  74 RingBuffer.swift
#  51 Logger.swift
#  46 main.swift

# Build time
swift build 2>&1 | tail -1
# Build complete! (0.9s)

# Binary size
du -h .build/debug/MacPEQ
# 1.8M
```

## Conclusion

CP1 architecture is sound but has thread safety issues that likely explain the "granulated" audio. The core loop (Tap→IOProc→Ring→AUHAL) is proven. Before CP2 (device switching), we should:

1. Make ring buffer atomic (prevents corruption during device switch)
2. Add sample rate negotiation (required for Bluetooth devices)
3. Clean up logging (reduce noise)

The code is ready for CP2 pending these fixes, OR we can proceed with CP2 and fix atomics in parallel (device switching tests will stress the ring buffer more).
