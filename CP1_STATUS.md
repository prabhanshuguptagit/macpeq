# MacPEQ Checkpoint 1 Status

**Date:** 2026-04-10
**Status:** ⚠️ FUNCTIONAL BUT WITH KNOWN ISSUES

## What Works ✅

### Core Audio Pipeline
The fundamental passthrough loop is operational:

```
System Audio → CATapDescription → IOProc → RingBuffer → AUHAL → Speakers
```

**Verified components:**
1. **Tap Creation**: `CATapDescription` with `initStereoGlobalTapButExcludeProcesses` creates successfully
2. **Aggregate Device**: Created with tap as input source, IOProc registered
3. **IOProc Callback**: Fires ~100x/sec (10ms intervals), receives Float32 interleaved stereo @ 48kHz
4. **Ring Buffer**: SPSC lock-free buffer, 16384 frames (~340ms), maintains 25-35% fill level
5. **AUHAL Output**: Successfully drives speakers with data from ring buffer
6. **Peak Correlation**: IOProc input peaks match AUHAL output peaks exactly (±0.0001)

### Sample Flow Verification
| Component | Peak Values | Timing | Health |
|-----------|-------------|--------|--------|
| IOProc (tap input) | 0.08 - 1.68 | ~10ms intervals | ✅ Data flowing |
| Ring Buffer Fill | 0.28 - 0.31 | Stable | ✅ No overflow/underflow |
| AUHAL (speaker output) | 0.08 - 1.68 | ~10ms intervals | ✅ Matches input |

### Build & Deploy
- ✅ SPM builds successfully
- ✅ App bundle codesigned and runs
- ✅ Permission prompt appears for "System Audio Recording"
- ✅ File-based logging to `/tmp/macpeq.log` for diagnostics

## Known Issues 🔧

### 1. Mute Behavior (macOS 15 Specific)
**Problem**: `CATapMuteBehavior.muted` silences the tap itself on macOS 15, not just original audio

| Setting | Result | Usable? |
|---------|--------|---------|
| `.muted` | Tap delivers silence (all zeros) | ❌ No |
| `.mutedWhenTapped` | Intermittent, may silence Firefox | ❌ Unreliable |
| `.unmuted` | Both original + processed audio play | ⚠️ Double audio |

**Workaround**: Currently using `.unmuted` - creates phasey/chorus effect from double audio

**Root Cause**: Likely macOS 15 beta behavior change or undocumented requirement

### 2. Audio Quality Issues
**Symptoms Reported:**
- "Granulated/frozen" sound
- Intermittent dropouts
- Phase/echo effect (from double audio)

**Suspected Causes:**
1. **Clock drift**: Tap and output device may have independent clocks
2. **Double audio**: Original audio not suppressed + processed audio delayed
3. **Ring buffer sizing**: 16384 frames may be too large for low-latency
4. **Memory barriers**: Simple ring buffer may need atomic operations for thread safety

### 3. Permission Reliability
- Permission must be granted via System Settings → Privacy & Security → Screen & System Audio Recording
- Reset with: `tccutil reset ScreenCapture com.macpeq.MacPEQ`
- VS Code terminal may not trigger prompt - use Terminal.app

## Architecture Decisions

### What's Implemented
1. **Global stereo tap** - captures all system audio
2. **Aggregate device** - contains tap as input source
3. **C-style IOProc callback** - avoids closure capture issues
4. **Simple ring buffer** - power-of-2 sized with masking
5. **AUHAL output** - direct HAL unit to default device

### What's Deferred
- Sample rate conversion (assumes 48kHz everywhere)
- Format conversion (assumes Float32 interleaved)
- Proper mute behavior (needs investigation)
- Device switching (CP2)
- EQ processing (CP3+)

## Code Structure

```
Sources/MacPEQ/
├── main.swift           # CLI entry, signal handling
├── Logger.swift         # File + stderr logging
├── AudioEngine.swift    # Core coordinator (600+ lines)
└── RingBuffer.swift     # Simple SPSC ring buffer

Sources/sinetest/        # Isolated speaker test
├── main.swift
├── SineWaveTest.swift
└── Logger.swift
```

## Success Criteria for CP1

| Criterion | Status | Notes |
|-----------|--------|-------|
| Audio flows tap→speakers | ✅ PASS | Peaks match, timing stable |
| No audible glitches | ⚠️ PARTIAL | Granulated sound reported |
| Sustained 10+ min | ⏸️ NOT TESTED | Needs long-running test |
| No latency creep | ✅ PASS | Ring fill stable at ~30% |
| Console logging | ✅ PASS | /tmp/macpeq.log captures all |

## Next Steps

### Immediate (CP1 Cleanup)
1. [ ] Add atomic operations to ring buffer for thread safety
2. [ ] Test sustained 10+ minute playback
3. [ ] Investigate clock drift compensation
4. [ ] Try device-specific tap vs global tap for mute behavior

### Checkpoint 2 (Device Switching)
1. [ ] Property listener on `kAudioHardwarePropertyDefaultOutputDevice`
2. [ ] Teardown/rebuild sequence on device change
3. [ ] Clear ring buffer during switch to prevent noise
4. [ ] Handle sample rate changes between devices

### Checkpoint 3+ (EQ)
1. [ ] Single biquad filter in render path
2. [ ] Hardcoded +6dB @ 1kHz test
3. [ ] Frequency response verification

## Debugging Commands

```bash
# Build and run
swift build && ./.build/debug/MacPEQ

# Monitor logs
tail -f /tmp/macpeq.log | grep -E "peak|ringFill|FROZEN|underflow"

# Check permissions
tccutil reset ScreenCapture com.macpeq.MacPEQ

# Sine wave test (isolated speaker)
swift run sinetest
```

## References
- Sudara's gist: https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f
- AudioTee: https://github.com/makeusabrew/audiotee
- Apple AudioTapSample (Xcode)
- PRD: ./PRD.md
