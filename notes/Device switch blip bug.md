# Device Switch Blip — Remaining Issue & Investigation Notes

## Current State (what works)
- Pre-muted taps on all output devices at startup: eliminates blip for most transitions
- 50ms debounce on device change events: prevents double-rebuilds from macOS firing
  intermediate device change events, eliminates tearing artifacts
- Same-device check in rebuildForNewDevice: skips unnecessary rebuilds
- Ring buffer pre-fill (~10ms): prevents underrun on first render callbacks after rebuild
- AUHAL handles sample rate conversion: tap format rate (possibly stale) is passed
  directly to AUHAL, which does SRC to the output device rate internally
- Tap format rate used for EQ filters (they process data at ring buffer rate)
- Pipeline-only teardown (taps survive across device switches)

## Remaining Problem
~300ms blip of raw (unprocessed) audio when switching UMC1820 → MacBook speakers sometimes.

**Characteristics:**
- Only happens UMC→MacBook direction, not Galaxy Buds→MacBook or MacBook→UMC
- Intermittent (not every switch)
- Sounds like: burst of raw audio on MacBook → brief silence → audio resumes processed
- The burst happens BEFORE our listener callback fires — it's at the HAL level

**What the logs showed:**
- Pre-muted tap on MacBook exists and is valid (probeStatus=0) at switch time
- Old device's tap survives aggregate destruction (still valid after cleanup)
- Taps are not being invalidated by any lifecycle event

## Root Cause Theory
The pre-muted tap on the MacBook was created at startup while UMC was the active
default device. A standalone muted exclusive tap on a non-active device may not
effectively intercept audio at the HAL level. When the system switches to MacBook,
there's a window where:

1. HAL routes audio to MacBook speakers (instant, hardware-level)
2. The pre-created muted tap may not be intercepting (it's standalone, not in an aggregate)
3. Our listener fires, we rebuild, audio goes through our pipeline

The test script (test_premute_all.swift) appeared to work, but may not have been
tested specifically with the UMC→MacBook transition, or the timing was lucky.

## What We Tried

### 1. Delayed mute (pre-premute era)
Created unmuted tap first, built pipeline, then swapped to muted tap.
**Result:** Didn't help — the blip happens before our code runs at all.

### 2. Pre-muted taps on all devices at startup ✅ (current approach)
Create muted taps on every output device when engine starts. Hot-plug listener
creates taps on newly connected devices.
**Result:** Works for most transitions. Blip still occurs on UMC→MacBook.

### 3. Re-reading tap format after aggregate creation
Theory: aggregate forces tap onto device clock, updating stale sample rate.
**Result:** Rate sometimes updates, sometimes doesn't. Not reliable.

### 4. Using device rate for AUHAL stream format
Override tapFormat.mSampleRate with output device's nominal rate.
**Result:** Pitched audio — AUHAL was told 48kHz but fed 44.1kHz samples.

### 5. Patching tapFormat.mSampleRate without changing AUHAL
Changed tapFormat to device rate, hoping AUHAL + aggregate would handle it.
**Result:** Same pitch problem — tap still delivers at its original rate.

### 6. Pass tap format as-is to AUHAL ✅ (current approach)
Let AUHAL see the tap's rate and do SRC internally to device rate.
**Result:** Correct pitch. This is what the test script does.

### 7. Debounce device changes ✅ (current, 50ms)
Wait for device change events to settle before rebuilding.
**Result:** Eliminates tearing from double-rebuilds on intermediate devices.

### 8. Destroying and recreating tap on new device at switch time
Theory: fresh tap on now-active device would mute immediately.
**Result:** Made things WORSE — glitch in both directions. Destroying the tap
creates a window where no tap exists at all.

### 9. Ring buffer pre-fill ✅ (current, ~10ms target)
Start IOProc before AUHAL, wait for ring buffer to fill.
**Result:** Eliminates underrun artifacts on rebuild.

## Ideas Not Yet Tried

### A. Create lightweight aggregate devices for all muted taps
Instead of standalone taps, create a minimal aggregate device for each tap
(no IOProc, just aggregate + tap binding). This might make the tap actually
intercept audio at the HAL level even when it's not the active pipeline device.
**Risk:** Resource-heavy, may hit Core Audio limits on aggregate devices.

### B. Move tap creation to Core Audio listener thread
Currently tap refresh happens after dispatch to stateQueue. Moving it to the
CA listener callback (which fires synchronously on the CA thread) would be
faster, but CA thread shouldn't do heavy work.
**Risk:** Blocking CA thread could cause system-wide audio glitches.

### C. Use initStereoGlobalTapButExcludeProcesses instead of device-specific taps
A global tap follows the default device automatically — no per-device taps needed.
But this was considered earlier and rejected (reason not documented).
**Risk:** May not support exclusive/muted behavior the same way.

### D. Investigate whether the UMC's 12-channel tap is the differentiator
The UMC tap has 12 channels. When MacBook becomes active, the system may not
route through a 12-channel tap designed for a different device topology.
Galaxy Buds (2ch, BT) and MacBook (2ch) may share enough topology that taps
work cross-device. Test: set UMC to 2ch output mode if possible.

### E. Profile the exact timing
Add CFAbsoluteTimeGetCurrent() logging in the CA listener callback itself
(before dispatch) to measure exactly how long between the HAL switch and
our first opportunity to act. If the burst is happening in <5ms, no
software approach can prevent it.
