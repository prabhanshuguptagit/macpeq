# MacPEQ — System-Wide Parametric EQ for macOS

## Implementation PRD (Agent Handoff)

---

## 1. What This Is

MacPEQ is a macOS menu-bar app that intercepts **all system audio** via Core Audio process taps, applies a fully parametric EQ (10+ biquad bands in series), and forwards the processed signal to the current default output device — transparently, with zero virtual audio drivers, no kernel extensions, and no SIP workarounds.

**Target:** macOS 14.2+ (hard requirement — `CATapDescription` and `AudioHardwareCreateProcessTap` don't exist before this).

**Language:** Swift. **UI:** SwiftUI + Canvas.

---

## 2. Architecture

```
MacPEQ
├── AudioEngine                    [owns everything on audio threads]
│   ├── TapManager                 [CATapDescription + aggregate device lifecycle]
│   ├── OutputRouter               [AUHAL output unit, default device tracking, rebuild on switch]
│   ├── RingBuffer                 [TPCircularBuffer wrapper, lock-free SPSC]
│   └── EQProcessor                [biquad filter bank, double-buffered coefficients]
├── EQState                        [ObservableObject — source of truth for band parameters]
├── PresetManager                  [load/save/bundle presets, per-device association]
└── UI
    ├── MenuBarController          [MenuBarExtra — bypass, preset picker, open window]
    ├── EQWindowView
    │   ├── FrequencyResponseView  [Canvas — log-frequency curve, dB grid]
    │   ├── BandHandleView         [draggable dots — gain/freq/Q adjustment]
    │   └── PresetsPanel           [dropdown + save/import/export]
    └── SettingsView               [launch at login, per-device toggle]
```

### AudioEngine State Machine

`AudioEngine` must track its lifecycle as an explicit state enum. All state transitions happen on a dedicated serial queue (`audioEngineQueue`). The state guards against re-entrant rebuilds (e.g., rapid device switching).

```
           ┌──────────┐
           │  idle     │  (no tap, no audio)
           └────┬─────┘
                │ start()
                ▼
           ┌──────────┐
           │ building  │  (creating tap, aggregate, AUHAL)
           └────┬─────┘
                │ success          │ failure
                ▼                  ▼
           ┌──────────┐     ┌──────────┐
           │ running   │     │ disabled  │  (show error in UI, allow retry)
           └────┬─────┘     └──────────┘
                │ device change / error
                ▼
           ┌──────────────┐
           │ tearingDown   │  (stop AUHAL, destroy aggregate, destroy tap)
           └────┬─────────┘
                │ done
                ▼
           ┌──────────┐
           │ building  │  (rebuild for new device)
           └──────────┘
```

**Rules:**
- `start()` is only valid from `idle` or `disabled`.
- Device-change listener only triggers a rebuild if current state is `running`.
- If a rebuild request arrives while already in `building` or `tearingDown`, queue it (at most one pending).
- `disabled` state is recoverable — user can tap "Retry" in the menu bar, or the app retries automatically on the next device change.

### File / Target Layout

```
MacPEQ/
├── MacPEQ.xcodeproj
├── MacPEQ/
│   ├── MacPEQApp.swift            [App entry point, MenuBarExtra]
│   ├── Info.plist                 [NSAudioCaptureUsageDescription, LSUIElement=YES]
│   ├── Audio/
│   │   ├── AudioEngine.swift      [top-level coordinator]
│   │   ├── TapManager.swift       [CATapDescription, aggregate device]
│   │   ├── OutputRouter.swift     [AUHAL unit, device-change listener]
│   │   ├── RingBuffer.swift       [TPCircularBuffer Swift wrapper]
│   │   ├── EQProcessor.swift      [filter bank, double-buffered params]
│   │   ├── BiquadFilter.swift     [single biquad: coefficients + state]
│   │   └── BiquadMath.swift       [Audio EQ Cookbook coefficient computation]
│   ├── Model/
│   │   ├── EQBand.swift           [frequency, gain, Q, type, enabled]
│   │   ├── EQState.swift          [ObservableObject, array of EQBand]
│   │   ├── FilterType.swift       [enum: peak, lowShelf, highShelf, lowPass, highPass, notch]
│   │   └── Preset.swift           [Codable: name, bands, optional deviceUID]
│   ├── Presets/
│   │   ├── PresetManager.swift    [load/save/bundle/import/export]
│   │   └── StockPresets.swift     [Flat, Bass Boost, Treble Boost, Vocal, Loudness, Speaker Comp]
│   ├── Views/
│   │   ├── MenuBarController.swift
│   │   ├── EQWindowView.swift
│   │   ├── FrequencyResponseView.swift
│   │   ├── BandHandleView.swift
│   │   ├── PresetsPanel.swift
│   │   └── SettingsView.swift
│   └── Utilities/
│       └── AudioConstants.swift   [sample rates, buffer sizes, ISO frequencies]
├── MacPEQTests/
│   └── EQProcessorTests.swift     [impulse response FFT verification]
└── Package.swift or SPM deps     [TPCircularBuffer]
```

---

## 3. Tech Choices

| Concern | Choice | Reason |
|---|---|---|
| Audio tap | Core Audio HAL API directly | Full control over tap + aggregate device. No abstractions. |
| Ring buffer | TPCircularBuffer (C, via SPM) | Lock-free SPSC, battle-tested in pro audio apps. |
| Filter math | Custom biquad (Robert Bristow-Johnson Audio EQ Cookbook) | Full control over all filter types. No opaque Apple AU. |
| UI framework | SwiftUI + `Canvas` | Canvas gives per-pixel draw for the EQ curve. |
| Presets | JSON files in `~/Library/Application Support/MacPEQ/presets/` | Human-readable, drag-drop exportable. |
| Login item | `SMAppService.mainApp` | Modern API. No deprecated Login Items. |
| FFT (tests only) | `vDSP` / Accelerate | Already on macOS, no external dep. |

---

## 4. What NOT To Do

These are explicit anti-patterns. Do not deviate.

1. **Do NOT use `AVAudioEngine`** for the main audio path. It abstracts too much and makes tap + output routing impossible to control precisely.
2. **Do NOT use a virtual audio device** (BlackHole-style). The entire point is that Core Audio taps eliminate this need.
3. **Do NOT process audio on the main thread** or any thread you don't own. All DSP happens inside the Core Audio IOProc / render callback.
4. **Do NOT allocate memory inside render callbacks.** No `malloc`, no Swift `Array` resizing, no `String` creation, no `print()`. Pre-allocate everything.
5. **Do NOT use locks in the audio thread.** Use double-buffering + atomic flag for parameter updates.
6. **Do NOT target the `tapID` when setting `kAudioAggregateDevicePropertyTapList`** — always target `aggregateDeviceID`. (Apple's own sample code has this bug — confirmed via Feedback FB17411663.)
7. **Do NOT call `AVCaptureDevice.requestAccess(for: .audio)`** to request tap permission. That API requests *microphone* access, which is a completely different permission. The system audio tap permission is triggered automatically when the IOProc starts. See the Permissions section in section 6.

---

## 5. Checkpoints

Each checkpoint has a **binary pass/fail gate**. Do not advance to the next checkpoint until the current one passes.

---

### Checkpoint 1: Audio Passthrough (Pure POC, No UI, No EQ)

**Goal:** Tap system audio → ring buffer → AUHAL output. Zero processing. Prove the loop works.

**Success gate:** Play music from any app. Audio plays through the default output device with no audible difference — no echo, no doubling, no glitches — **sustained for at least 10 minutes** without latency creep or clicks. Console logs confirm both the IOProc callback and the AUHAL render callback are firing. Ring buffer fill level stays stable (not trending toward full or empty).

**Implementation steps:**

1. Create a macOS app target (SwiftUI shell). Add `NSAudioCaptureUsageDescription` to `Info.plist` (enter manually — it's not in Xcode's dropdown). This is the usage string shown in the system permission prompt.
   - Note: There is **no public API** to proactively check or request system audio tap permission. The system will prompt the user automatically the first time the aggregate device IOProc starts reading tap data. If the user denies, you get silence (not an error). See the Permissions section in section 6 for details.
2. Read the default output device ID:
   ```
   var deviceID: AudioDeviceID
   var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
   var address = AudioObjectPropertyAddress(
       mSelector: kAudioHardwarePropertyDefaultOutputDevice,
       mScope: kAudioObjectPropertyScopeGlobal,
       mElement: kAudioObjectPropertyElementMain
   )
   AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceID)
   ```
3. Create a `CATapDescription` using `initStereoGlobalTapButExcludeProcesses(_:)`.
   - **Exclude your own process** (`ProcessInfo.processInfo.processIdentifier`) to prevent feedback if the app ever produces sound.
   - This convenience init automatically sets `exclusive = true` (meaning the process list is treated as an exclusion list) and configures stereo output. If you use a different init (e.g., `initWithProcesses:andDeviceUID:withStream:`), you must set `setExclusive(true)` manually.
   - Set mute behavior: `tapDescription.setMuteBehavior(.muted)` — this is critical. The `CATapMuteBehavior` enum has three values: `.unmuted` (original signal still plays — you hear both), `.muted` (original signal is silenced — only your processed output plays), `.mutedWhenTapped` (mutes only while actively tapping). For an EQ app that replaces the output, use `.muted`.
   - Set private: `tapDescription.setPrivate(true)` — required when the aggregate device will also be private.
4. Call `AudioHardwareCreateProcessTap(tapDescription, &tapID)`.
5. Get the tap's UUID string: `let tapUID = tapDescription.uuid.uuidString`
6. Build an aggregate device dictionary. **The tap list is an array of dictionaries, not an array of UID strings:**
   ```swift
   let aggregateDict: [String: Any] = [
       kAudioAggregateDeviceNameKey: "MacPEQ",
       kAudioAggregateDeviceUIDKey: "com.macpeq.aggregate",
       kAudioAggregateDeviceTapListKey: [
           [
               kAudioSubTapUIDKey: tapUID,
               kAudioSubTapDriftCompensationKey: true
           ]
       ],
       kAudioAggregateDeviceTapAutoStartKey: false,
       kAudioAggregateDeviceIsPrivateKey: true
   ]
   ```
   **Critical:** `kAudioSubTapDriftCompensationKey: true` tells Core Audio to handle clock drift between the tap and the aggregate device at the HAL level. This is the correct way to handle drift — do NOT rely solely on manual frame drop/duplicate.
7. Call `AudioHardwareCreateAggregateDevice(&aggregateDict, &aggregateDeviceID)`.
   - Handle OSStatus `1852797029` — this means an aggregate device with the same UID already exists (stale from a previous crash or unclean shutdown). To recover, you need the stale device's `AudioObjectID` (which you don't have from the crash). Look it up by translating the UID string to a device ID using `kAudioHardwarePropertyTranslateUIDToDevice` on `kAudioObjectSystemObject`, then call `AudioHardwareDestroyAggregateDevice` with the resolved ID, then retry creation.
   - If this error persists after destroy+retry (as some developers have reported), use a unique UID per session — e.g., append a UUID suffix to `"com.macpeq.aggregate"`. This avoids the collision entirely at the cost of potentially leaking stale aggregate devices in the HAL's registry (they clean up on reboot).
8. Read `kAudioTapPropertyFormat` from the tap → `AudioStreamBasicDescription`. Log the format. **Expect Float32, non-interleaved.** If the format differs (e.g., interleaved, Int16 — possible with some Bluetooth devices), set up an `AudioConverter` in the IOProc to convert to Float32 non-interleaved before writing to the ring buffer. If converter setup fails, log the error and enter disabled state (see Failure Modes in section 6).
9. Register an IOProc on the aggregate device via `AudioDeviceCreateIOProcIDWithBlock`. Inside:
   - Copy the input buffer list into a `TPCircularBuffer`.
   - Log frame count on first few callbacks to confirm data flowing.
10. Create an AUHAL output unit:
    - Component: `kAudioUnitType_Output` / `kAudioUnitSubType_HALOutput`
    - Set `kAudioOutputUnitProperty_CurrentDevice` to the default output device ID.
    - Enable output (element 0), disable input (element 1).
    - Read the output device's native sample rate. **Compare against the tap format sample rate.**
      - If they match → set the AUHAL stream format to match. Proceed normally.
      - If they differ (e.g., tap delivers 48kHz, USB DAC wants 44.1kHz) → set up an `AudioConverter` for sample rate conversion in the AUHAL render callback, between the ring buffer read and the output write. Use `AudioConverterFillComplexBuffer` with the ring buffer as the data source. Pre-allocate the conversion buffer during setup, not in the callback.
      - If the converter setup fails → log, enter disabled state.
11. Set a render callback on the AUHAL unit that pulls from the ring buffer → writes to the output buffer list.
12. Start both: `AudioDeviceStart(aggregateDeviceID, ioProcID)` and `AudioOutputUnitStart(auhalUnit)`.

**Known gotchas:**
- Always target `aggregateDeviceID` (not `tapID`) when setting/getting `kAudioAggregateDevicePropertyTapList`.
- Sample rate mismatch between tap and output device is **common** (e.g., 48kHz tap + 44.1kHz USB DAC). The AudioConverter handles this transparently. Do NOT assume rates will match — always check and set up conversion if needed.
- The ring buffer size should be at least 4× the expected buffer size to handle timing jitter between the two callback clocks.
- **Clock drift is handled primarily by `kAudioSubTapDriftCompensationKey: true`** in the aggregate device dictionary (step 6). This enables HAL-level drift compensation. Additionally, add ring buffer fill-level monitoring in the AUHAL render callback as a health check (see "Clock Drift Handling" in section 6). If fill level drifts despite HAL compensation, something else is wrong.
- **Stereo global tap + multi-channel output device = volume attenuation.** When using `initStereoGlobalTapButExcludeProcesses` with an output device that has more than 2 channels (e.g., a 4-channel audio interface), the tapped buffer's volume will be attenuated proportionally. For a 4-channel device, expect ~6dB attenuation. This is a known Core Audio bug also present in ScreenCaptureKit. For most users (built-in speakers, headphones, AirPods — all stereo), this won't matter. If supporting multi-channel interfaces, compensate by scaling the input buffer or use a device-specific tap (`initWithProcesses:andDeviceUID:withStream:`) instead.

---

### Checkpoint 2: Single Biquad Filter (Validate DSP Path)

**Goal:** Insert a single hardcoded filter between the ring buffer and AUHAL output. Prove DSP works in the real-time path.

**Success gate:** Hardcode a +6dB peak at 1kHz (Q=1.0). Play broadband audio or pink noise. The 1kHz boost is clearly audible. Disable the filter → flat. Re-enable → boost returns.

**Implementation steps:**

1. Implement `BiquadFilter` struct:
   ```swift
   struct BiquadFilter {
       // Coefficients
       var b0: Float = 1.0, b1: Float = 0.0, b2: Float = 0.0
       var a1: Float = 0.0, a2: Float = 0.0
       // State (persists across callbacks)
       var x1: Float = 0.0, x2: Float = 0.0
       var y1: Float = 0.0, y2: Float = 0.0

       mutating func process(_ input: Float) -> Float {
           let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
           x2 = x1; x1 = input
           y2 = y1; y1 = output
           return output
       }
   }
   ```
2. Implement coefficient calculation using the Audio EQ Cookbook (Robert Bristow-Johnson). Support at minimum: **peak/bell, low shelf, high shelf, low-pass, high-pass**.
3. In the AUHAL render callback, after pulling from ring buffer, run each sample through the filter.
4. **Filter state is per-channel.** Stereo = two independent `BiquadFilter` instances with separate state.
5. Hardcode: `frequency = 1000, gain = +6, Q = 1.0, type = .peak`.

**Known gotchas:**
- Render callback is a real-time thread. The `BiquadFilter.process()` method must be pure arithmetic — no allocations, no locks, no Swift runtime overhead.
- Log `kAudioTapPropertyFormat` — processing must be in the same format. If the tap delivers Float32 non-interleaved, process Float32 non-interleaved. Mismatch → noise or silence.
- Filter state must NOT be reset between callbacks. The `x1, x2, y1, y2` values carry signal continuity.

**Implementation notes:**
- **N-channel gap (deferred to CP4):** The non-interleaved path only processes buffer indices 0 and 1. Channels 3+ pass through unfiltered. This is acceptable for CP2 (stereo proof-of-concept) but must be addressed when generalizing to `[[BiquadFilter]]` for arbitrary channel counts in CP4.
- **Filter state persistence:** Use `if var left = leftFilter` binding in the render callback, then save mutated filter back to the property. The compiler elides copies for small structs (7 floats) in optimized builds.
---


### Checkpoint 3: Device Switching

**Goal:** App survives output device changes (speakers → AirPods → headphones → USB DAC → back) without crashing or going silent.

**Success gate:** Switch devices while audio is playing. Audio resumes on the new device within ~300ms. No crash, no stuck silence.

**Implementation steps:**

1. Register a property listener on `kAudioObjectSystemObject` for `kAudioHardwarePropertyDefaultOutputDevice`.
2. In the listener callback (fires on an arbitrary Core Audio thread — **dispatch to your own serial queue**, never main):
   - Stop the AUHAL output unit → release it.
   - Stop the aggregate device IOProc → destroy the aggregate device.
   - Destroy the tap.
   - **Clear the ring buffer** (stale samples from the old device's sample rate will cause noise).
   - Re-read the new default output device ID.
   - Rebuild everything in order: tap → aggregate device → ring buffer → AUHAL.
   - Log the new tap format. **If sample rates differ between tap and output device, set up an AudioConverter** (same as CP1 step 10).
3. Test with: built-in speakers → Bluetooth headphones → AirPods → USB DAC → back to speakers.

**Known gotchas:**
- AirPods may negotiate different sample rates depending on mode (24kHz SCO vs 48kHz A2DP). Your rebuild must handle this — read the new tap format, set up AudioConverter if rates differ.
- The serial queue for rebuilds prevents races if the user switches devices rapidly.
- Don't rebuild on main thread — the Core Audio calls can block.
- If aggregate device creation fails with `1852797029` during rebuild, the previous destroy didn't complete cleanly. Handle the same way as CP1 step 7 — destroy stale, retry.

---

### Checkpoint 4: Full Filter Bank + Automated Verification

**Goal:** Extend to N biquad bands in series. Verify correctness with a unit test, not by ear.

**Success gate:** Unit test passes — impulse response FFT matches theoretical magnitude response within ±0.5dB at each band's center frequency.

**Implementation steps:**

1. Define `EQBand`:
   ```swift
   struct EQBand: Codable, Identifiable {
       let id: UUID
       var frequency: Float   // Hz, 20–20000
       var gain: Float        // dB, -20 to +20
       var q: Float           // 0.1 to 10.0
       var type: FilterType   // peak, lowShelf, highShelf, lowPass, highPass, notch
       var enabled: Bool
   }
   ```
2. Refactor the single filter from CP3 into `EQProcessor`:
   ```swift
   class EQProcessor {
       // One BiquadFilter per band per channel
       // Double-buffered coefficients: audioThread reads active buffer,
       // UI thread writes to inactive buffer, then swaps via atomic flag
       func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int)
       func updateBands(_ bands: [EQBand])  // called from UI thread
   }
   ```
3. Hardcode 10 bands at ISO frequencies: 31, 63, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
4. **Thread-safe parameter updates:** Double-buffer the coefficient arrays. UI thread writes to the inactive buffer and flips an atomic flag. Audio thread reads the active buffer. No locks.
5. **Add output gain protection** (see "Output Gain Protection" in section 6). Implement both stages: auto-gain reduction as the primary mechanism, plus hard safety clamp as fallback. This is mandatory from CP4 onward — without it, stacking boosts produces values >1.0 which clip at the DAC.

**Automated verification (unit test — THIS IS THE GATE):**

```swift
// EQProcessorTests.swift
func testImpulseResponse() {
    let processor = EQProcessor()
    let bands: [EQBand] = [
        EQBand(frequency: 1000, gain: 6.0, q: 1.0, type: .peak, enabled: true),
        EQBand(frequency: 4000, gain: -3.0, q: 2.0, type: .peak, enabled: true),
        // ... more bands
    ]
    processor.updateBands(bands)

    // Feed an impulse: 1.0 followed by zeros
    let fftSize = 4096
    var impulse = [Float](repeating: 0, count: fftSize)
    impulse[0] = 1.0

    // Process through the filter bank (single channel)
    processor.process(buffer: &impulse, frameCount: fftSize, channel: 0)

    // FFT the output using vDSP
    // ... (use vDSP_fft_zrip or vDSP_DFT)
    // Measure magnitude at each band's center frequency
    // Compare against theoretical H(z) magnitude from biquad coefficients

    for band in bands where band.enabled {
        let measuredDB = magnitudeAtFrequency(band.frequency, fftOutput, sampleRate: 48000)
        let expectedDB = theoreticalMagnitude(band, sampleRate: 48000)
        XCTAssertEqual(measuredDB, expectedDB, accuracy: 0.5,
            "Band at \(band.frequency)Hz: measured \(measuredDB)dB, expected \(expectedDB)dB")
    }
}
```

Use `vDSP` from `Accelerate` — no external FFT library needed. The impulse response test gives you the full frequency response in one shot. Compare against the theoretical `H(z)` magnitude computed analytically from the biquad coefficients.

**By the time this passes, you have high confidence the filter math is correct. CP5 (drawing the curve) is then just visualizing something already proven.**

---

### Checkpoint 5: Minimal UI — EQ Curve Display

**Goal:** Render the frequency response curve and band handles. EQ is still controlled by hardcoded values, but the curve is reactive and will update when parameters change.

**Success gate:** Curve visually matches the hardcoded band configuration. The shape should match what the CP4 unit test proved mathematically.

**Implementation steps:**

1. Build `FrequencyResponseView` using SwiftUI `Canvas`:
   - X-axis: log-scaled frequency, 20Hz → 20kHz.
   - Y-axis: linear dB, ±20dB (or ±12dB).
   - For each pixel column, map x → frequency, compute combined magnitude response of all bands at that frequency using the `H(z)` formula, draw the curve.
   - Grid lines at each decade (100, 1k, 10k) and at 0dB, ±6dB, ±12dB.
2. Render band handles as circles/dots at each band's center frequency on the curve.
3. Wire to `EQState` (`ObservableObject` with `@Published` band array). Curve redraws reactively.
4. Add a bypass toggle that disables all processing in the render callback (raw passthrough).

**Computing magnitude response for display:**
```
For a biquad with coefficients (b0, b1, b2, a0=1, a1, a2) at frequency f and sample rate fs:
  w = 2π * f / fs
  numerator   = b0² + b1² + b2² + 2(b0*b1 + b1*b2)cos(w) + 2*b0*b2*cos(2w)
  denominator = 1   + a1² + a2² + 2(a1 + a1*a2)cos(w)     + 2*a2*cos(2w)
  magnitude_dB = 10 * log10(numerator / denominator)
Sum all band magnitudes in dB for the combined curve.
```

---

### Checkpoint 6: Interactive EQ — Drag to Edit

**Goal:** Band handles become interactive. User drags to shape the EQ in real time.

**Success gate:** Drag a handle up → hear that frequency region louder immediately (latency <10ms). No glitches, no audio dropouts during interaction.

**Implementation steps:**

1. **Vertical drag** on a band handle → adjusts gain. Range: ±20dB. Snap to 0.5dB increments.
2. **Horizontal drag** → adjusts frequency. Range: 20Hz–20kHz. Log-scaled movement (dragging the same pixel distance at 100Hz moves fewer Hz than at 10kHz).
3. **Scroll wheel** on a handle → adjusts Q. Range: 0.1 to 10.0.
4. **Right-click / secondary click** → context menu:
   - Change filter type (peak, low shelf, high shelf, low-pass, high-pass, notch)
   - Enable/disable band
   - Reset band to default
5. Parameter changes flow: `BandHandleView` → `EQState` (main thread) → `EQProcessor.updateBands()` (writes to inactive coefficient buffer, flips atomic flag) → audio thread picks up on next callback.
6. **While dragging:** show a floating label with gain value (e.g., "+3.5 dB"). **On hover:** show frequency + Q (e.g., "1.0 kHz, Q=1.4").

---

### Checkpoint 7: Presets

**Goal:** Save, load, and switch EQ configurations.

**Implementation steps:**

1. `Preset` struct:
   ```swift
   struct Preset: Codable, Identifiable {
       let id: UUID
       var name: String
       var bands: [EQBand]
       var deviceUID: String?  // nil = global, set = per-device (CP9)
   }
   ```
2. Bundle stock presets:
   - **Flat** — all bands at 0dB
   - **Bass Boost** — +4dB shelf below 200Hz
   - **Treble Boost** — +3dB shelf above 4kHz
   - **Vocal Presence** — +3dB peak at 2-4kHz
   - **Loudness** — Fletcher-Munson compensation (boost lows and highs at low volume)
   - **Speaker Compensation** — gentle curve for laptop speakers (cut 200Hz mud, slight high-shelf boost)
3. User presets saved to `~/Library/Application Support/MacPEQ/presets/` as JSON.
4. Preset picker: dropdown in the EQ window. Switching presets **animates** the curve — interpolate band gains over ~150ms (lerp the gain values, recompute coefficients each frame).
5. "Save Current as Preset" flow (name prompt → save).
6. Import/export: JSON file via file picker or drag-drop.

---

### Checkpoint 8: Menu Bar Presence + Launch at Login

**Goal:** MacPEQ lives in the menu bar. No Dock icon. Survives window close.

**Implementation steps:**

1. Set `LSUIElement = YES` in `Info.plist` (no Dock icon).
2. `MenuBarExtra` in SwiftUI:
   - Icon: small EQ waveform icon
   - Label: current preset name
   - Popover contents: bypass toggle, preset dropdown, "Open EQ Window" button, "Quit" button
3. "Launch at Login" toggle in settings using `SMAppService.mainApp`.
4. The main EQ window opens from the menu bar item and **closing it does not quit the app** — audio engine keeps running.

---

### Checkpoint 9: Per-Output-Device Settings (Optional / Stretch)

**Goal:** Different EQ curves for different output devices (laptop speakers vs headphones vs external DAC).

**Implementation steps:**

1. On device switch (existing CP2 listener), read the new device's UID via `kAudioDevicePropertyDeviceUID`.
2. Check if a preset is associated with that UID. If yes → load it. If no → keep current global preset.
3. UI: "Per Device" toggle in settings. When on, shows current device name and lets user assign/create a preset for it.
4. Storage: persist device↔preset associations in a JSON map file alongside presets.

---

## 6. Critical Implementation Details

### Audio EQ Cookbook Reference

For computing biquad coefficients. Source: Robert Bristow-Johnson.

All filter types use these intermediates:
```
A  = 10^(dBgain/40)        (for peaking and shelving only)
w0 = 2*pi*f0/Fs
alpha = sin(w0)/(2*Q)
```

**Peak/Bell:**
```
b0 =   1 + alpha*A
b1 =  -2*cos(w0)
b2 =   1 - alpha*A
a0 =   1 + alpha/A
a1 =  -2*cos(w0)
a2 =   1 - alpha/A
```
Normalize all by dividing by a0.

**Low Shelf:**
```
b0 =    A*( (A+1) - (A-1)*cos(w0) + 2*sqrt(A)*alpha )
b1 =  2*A*( (A-1) - (A+1)*cos(w0)                   )
b2 =    A*( (A+1) - (A-1)*cos(w0) - 2*sqrt(A)*alpha )
a0 =        (A+1) + (A-1)*cos(w0) + 2*sqrt(A)*alpha
a1 =   -2*( (A-1) + (A+1)*cos(w0)                   )
a2 =        (A+1) + (A-1)*cos(w0) - 2*sqrt(A)*alpha
```

**High Shelf:**
```
b0 =    A*( (A+1) + (A-1)*cos(w0) + 2*sqrt(A)*alpha )
b1 = -2*A*( (A-1) + (A+1)*cos(w0)                   )
b2 =    A*( (A+1) + (A-1)*cos(w0) - 2*sqrt(A)*alpha )
a0 =        (A+1) - (A-1)*cos(w0) + 2*sqrt(A)*alpha
a1 =    2*( (A-1) - (A+1)*cos(w0)                   )
a2 =        (A+1) - (A-1)*cos(w0) - 2*sqrt(A)*alpha
```

**Low-Pass:**
```
b0 =  (1 - cos(w0))/2
b1 =   1 - cos(w0)
b2 =  (1 - cos(w0))/2
a0 =   1 + alpha
a1 =  -2*cos(w0)
a2 =   1 - alpha
```

**High-Pass:**
```
b0 =  (1 + cos(w0))/2
b1 = -(1 + cos(w0))
b2 =  (1 + cos(w0))/2
a0 =   1 + alpha
a1 =  -2*cos(w0)
a2 =   1 - alpha
```

**Notch:**
```
b0 =   1
b1 =  -2*cos(w0)
b2 =   1
a0 =   1 + alpha
a1 =  -2*cos(w0)
a2 =   1 - alpha
```

### Double-Buffered Parameter Updates

```
Audio thread                          UI thread
─────────────                         ─────────
reads activeBuffer[activeIndex]       writes to coefficients[1 - activeIndex]
(pure read, no sync needed)           flips activeIndex (atomic store)
                                      ↓
next callback sees new activeIndex → reads new coefficients
```

Use Swift's `Atomic` (from the Synchronization module in Swift 6, or `UnsafeAtomic` from swift-atomics package). Do NOT use the deprecated `OSAtomic` family. The key constraint: the audio thread never blocks.

### Swift Real-Time Thread Safety

Swift's convenience features can silently violate real-time constraints. Inside render callbacks and `BiquadFilter.process()`:

**Banned in the audio callback:**
- `Array` subscript access (uses bounds checking → potential trap/allocation). Use `UnsafeMutableBufferPointer` instead.
- Passing or capturing class references (triggers ARC retain/release).
- `String` creation, interpolation, or `print()`.
- Any closure that captures a reference type.
- `DispatchQueue`, `Task`, or any async construct.

**Required:**
- Mark hot-path functions with `@inline(__always)`.
- Use `UnsafeMutablePointer<Float>` for all buffer access.
- `BiquadFilter` must be a `struct` (value type, no ARC). The array of filters should be stored in a pre-allocated `UnsafeMutableBufferPointer`, not a Swift `Array`.
- The `EQProcessor.process()` method should take raw pointers, not Swift arrays.
- Test with Instruments → "Audio Thread Guard" or "Realtime Thread Guard" to detect violations.

### UI→DSP Update Throttling

During drag interactions, the UI can fire parameter updates at 60–120Hz (one per frame). Coefficient recalculation for 10 bands is cheap but unnecessary at that rate — the audio thread only picks up new coefficients once per buffer callback (~every 10ms at 512 frames/48kHz).

**Throttle rule:** `EQState` should coalesce parameter changes and call `EQProcessor.updateBands()` at most once per audio buffer period (~10ms). Use a `DispatchSource` timer or a simple "dirty flag + timer" pattern on the serial queue. This prevents wasted coefficient recalculations and ensures the double-buffer swap is never contended.

### Ring Buffer Sizing

- Minimum: `4 × maxBufferFrames × bytesPerFrame × channelCount`
- Typical buffer sizes: 512 or 1024 frames at 48kHz
- Ring buffer of 16384 frames (~340ms at 48kHz) gives plenty of headroom

### Self-Exclusion from Tap

When creating the `CATapDescription`, exclude your own process:
```swift
let myPID = ProcessInfo.processInfo.processIdentifier
let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [myPID])
tap.setMuteBehavior(.muted)
tap.setPrivate(true)
```
This prevents feedback loops if MacPEQ ever produces incidental audio (system alerts, accessibility sounds, etc.).

### Sample Rate Conversion

The tap and the output device may run at different nominal sample rates (common: tap delivers 48kHz, USB DAC expects 44.1kHz). This is not the same as clock drift — it's a fundamental rate mismatch that must be handled with a resampler.

**Strategy:**
1. During setup, compare `tapFormat.mSampleRate` with the output device's native sample rate.
2. If they match → no conversion needed. Process at the common rate.
3. If they differ → create an `AudioConverter` using `AudioConverterNew(&tapFormat, &outputFormat)`.
4. **EQ processing always runs at the tap's sample rate** (since the biquad coefficients are computed for that rate).
5. Sample rate conversion happens *after* EQ processing, in the AUHAL render callback, via `AudioConverterFillComplexBuffer`. The converter pulls from the ring buffer (which contains EQ-processed audio at the tap rate) and outputs at the device rate.
6. Pre-allocate the converter's intermediate buffer during setup. Size it based on the ratio: `outputFrames * (tapRate / outputRate) * 1.1` (10% margin for rounding).

**When the converter is active, `kAudioSubTapDriftCompensationKey` still handles clock drift** — the converter handles the rate ratio, while HAL drift compensation handles the independent clock drift. Ring buffer fill monitoring remains active as a safety net.

### Output Gain Protection

Stacking multiple bands of positive gain will push samples above 1.0, which clips at the DAC. Two-stage protection:

**Stage 1 — Auto gain reduction (primary):**
Before processing, compute the worst-case peak gain from the current band configuration. If net gain is positive, apply a compensating negative pre-gain to the signal before the filter bank. This keeps the signal in range without distortion.
```
peakGainDB = max theoretical gain across all frequencies (can approximate as sum of all positive band gains)
if peakGainDB > 0:
    preGain = 10^(-peakGainDB / 20)
    apply preGain to input before filter bank
```
Recalculate whenever band parameters change (in `updateBands()`), not per-sample.

**Stage 2 — Hard safety clamp (fallback):**
```swift
output = max(-1.0, min(1.0, output))
```
This catches anything the auto-gain missed (e.g., transient peaks, edge cases). It's a safety net, not the primary limiter. If this clamp is firing frequently, the auto-gain calculation needs tuning.

Do NOT use `tanh()` or other soft clippers as the primary limiter — they color the signal at all levels, not just at clipping threshold. A transparent EQ should not introduce nonlinear distortion on normal-level signals.

Both stages are mandatory from CP4 onward.

---

### Runtime Guarantees

These are the performance contracts the implementation must meet:

| Guarantee | Target |
|---|---|
| End-to-end latency (tap input → speaker output) | < 20ms under normal operation |
| Audio dropouts during parameter changes | Zero — double-buffered updates are glitch-free |
| Memory allocation in audio thread | Zero — all buffers pre-allocated |
| CPU usage (10 bands, stereo, 48kHz) | < 3% on Apple Silicon, < 8% on Intel |
| Device switch recovery time | < 300ms to audio resumption |
| Ring buffer target fill level | 50% of capacity (balanced between latency and underrun safety) |

**Latency budget breakdown:**
```
Tap IOProc buffer:    ~10ms  (512 frames @ 48kHz)
Ring buffer transit:   ~2ms  (target: 1-2 buffer periods ahead)
AUHAL output buffer:  ~10ms  (512 frames @ 48kHz)
─────────────────────────────
Total:                ~22ms  (acceptable; reduce buffer sizes to 256 for ~12ms)
```

The ring buffer should NOT be filled to capacity during normal operation. A full ring buffer means ~340ms of latency. Target fill: 1-2 buffer periods worth of frames. Monitor this.

---

### Clock Drift Handling

The tap IOProc and the AUHAL output run on independent clock domains. Even if both report the same nominal sample rate (e.g., 48000Hz), their actual hardware clocks will drift relative to each other over time.

**Primary mechanism: `kAudioSubTapDriftCompensationKey`**

The aggregate device dictionary should include `kAudioSubTapDriftCompensationKey: true` in the tap list entry (see CP1 step 6). This tells Core Audio's HAL to perform drift compensation at the aggregate device level — the same mechanism used for multi-device aggregate devices. This is the correct, Apple-supported approach and handles drift transparently.

**Secondary mechanism: ring buffer fill monitoring (safety net)**

Even with HAL-level drift compensation, monitor the ring buffer fill level as a health check:
```swift
let available = TPCircularBufferAvailableBytes(&ringBuffer)
let fillRatio = Float(available) / Float(ringBufferCapacity)
```

- If `fillRatio > 0.7` (drifting full despite drift compensation): **drop** one frame from the ring buffer read. Log a warning — this suggests drift compensation isn't working as expected.
- If `fillRatio < 0.3` (drifting empty): **duplicate** the last frame. Log a warning.
- If corrections happen more than once per second, something is wrong (likely a sample rate mismatch, not drift — check the AudioConverter path).

**When to implement:** CP1. Enable `kAudioSubTapDriftCompensationKey` from day one, and add fill-level monitoring as a diagnostic. The manual frame drop/dup should rarely if ever fire when HAL drift compensation is active.

---

### Failure Modes

Define explicit behavior for every failure the agent must handle:

| Failure | Behavior |
|---|---|
| Audio capture permission denied | There is no public API to detect this. If the user denies permission, the tap delivers silence — not an error. **Detect by monitoring:** if the IOProc is firing but the ring buffer contains only zeros for >3 seconds while system audio should be playing, assume permission was denied. Show a dialog: "MacPEQ needs permission to process system audio. Open System Settings > Privacy & Security > Screen & System Audio Recording and enable MacPEQ." Include a button that opens the relevant System Settings pane via URL scheme. Menu bar icon shows "no permission" state. |
| `AudioHardwareCreateProcessTap` fails | Log the `OSStatus` error code. Show a user-facing alert: "MacPEQ couldn't tap system audio. This requires macOS 14.2+." Retry once after 1 second. If retry fails, enter disabled state. |
| `AudioHardwareCreateAggregateDevice` fails | Log the `OSStatus`. **Special case:** error code `1852797029` means an aggregate device with the same UID already exists (e.g., from a previous crash without cleanup). Destroy the stale device first with `AudioHardwareDestroyAggregateDevice`, then retry. For other errors: alert, retry once, disabled state. |
| AUHAL unit fails to initialize | Log error. Fall back to disabled state. Do not crash. |
| Sample rate mismatch (tap ≠ output device) | This is normal and expected (e.g., 48kHz tap + 44.1kHz DAC). Set up an `AudioConverter` for rate conversion in the render path (see CP1 step 10). If converter setup fails, log both rates and enter disabled state with user alert. |
| Format is not Float32 non-interleaved | Log the actual format. Attempt conversion via `AudioConverterNew` / `AudioConverterConvertBuffer` in the IOProc before writing to the ring buffer. If conversion setup fails, enter disabled state. |
| Device disappears mid-stream (USB unplug, Bluetooth disconnect) | The device change listener will fire. Existing CP2 rebuild logic handles this. If the new default device is also unavailable (unlikely), enter disabled state. |
| Ring buffer underflow (AUHAL reads but no data) | Output silence (zero the output buffer). Do not crash. Log a warning. This self-corrects when the tap catches up. |
| Ring buffer overflow (tap writes but AUHAL isn't reading) | Let TPCircularBuffer overwrite. Log a warning. This indicates a stuck AUHAL — trigger a rebuild. |
| Preset file corrupted / unparsable | Fall back to Flat preset. Log the error. Do not crash. |
| App Support directory not writable | Fall back to in-memory presets only. Log the error. User presets won't persist across launches — inform user. |

**General principle:** Never crash. Degrade to passthrough (no EQ) or disabled state. Always log the `OSStatus` code.

---

### Permissions

System audio tap permissions on macOS are poorly documented and behave differently from microphone permissions. This section consolidates what's known from real implementations (AudioCap, audiotee, SoundPusher).

**Key facts:**

1. **`NSAudioCaptureUsageDescription`** must be in `Info.plist`. This is the usage string shown in the permission prompt. Without it, the tap will silently produce no data. Enter it manually in Xcode — it's not in the dropdown.

2. **There is no public API to check or request system audio tap permission.** Unlike microphone access (`AVCaptureDevice.requestAccess(for: .audio)`), the tap permission has no equivalent. Do NOT call `AVCaptureDevice.requestAccess(for: .audio)` — that requests *microphone* access, which is a completely separate permission and not what MacPEQ needs.

3. **The permission prompt appears automatically** the first time the app starts reading from the aggregate device (i.e., when `AudioDeviceStart` is called and the IOProc begins receiving data). The system shows a dialog asking the user to allow "Screen & System Audio Recording" for your app.

4. **If the user denies permission, you get silence — not an error.** The IOProc will fire normally, the buffers will contain valid data structures, but all samples will be zero. There is no `OSStatus` error or callback notification. The only way to detect denial is to monitor for sustained silence (see Failure Modes table).

5. **The permission appears under "Privacy & Security > Screen & System Audio Recording"** in System Settings — not under "Microphone." To direct the user there programmatically: `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)`.

6. **A purple dot appears in the menu bar** while the tap is active, similar to the green dot for camera access. This is system-level and cannot be suppressed. Users should expect to see it.

7. **AudioCap's TCC probing approach** (using private TCC framework APIs) can proactively check permission state, but this is not App Store safe and may break in future macOS versions. For MacPEQ, rely on the automatic prompt + silence detection approach.

8. **Code signing matters.** The app must be properly signed for the permission prompt to appear. When running from Xcode during development, Xcode's signature is used. Some third-party terminals (iTerm, VS Code terminal) may not trigger the permission prompt — use Terminal.app or run the built .app bundle directly if testing the permission flow.

9. **Tapping a device with input streams requires ADDITIONAL microphone permission** (confirmed by SoundPusher). If the user's default output device also has input streams (e.g., some USB audio interfaces, combined input/output devices), the system will prompt for microphone access in addition to system audio recording. MacPEQ uses a global stereo tap (not a device-specific tap), so this should not typically apply — but be aware of it if the agent switches to a device-specific tap for any reason.

---

### Additional Unit Tests (CP4)

Beyond the core impulse response test, add these edge-case tests:

| Test | What it validates |
|---|---|
| All bands at 0dB gain → output equals input (within floating-point epsilon) | Passthrough correctness |
| Single band at extreme gain (+20dB, -20dB) | No numerical overflow/NaN |
| Q at extremes (0.1 and 10.0) | Filter stability at extreme resonance |
| All bands enabled simultaneously at +6dB each | Output stays finite, limiter engages |
| Disabled bands have zero effect | `enabled: false` truly bypasses |
| Band parameter update mid-buffer | Double-buffer swap doesn't corrupt audio |

---

## 7. Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| TPCircularBuffer | SPM: `https://github.com/michaeltyson/TPCircularBuffer` | Lock-free ring buffer |
| Accelerate (vDSP) | System framework | FFT for unit tests, potentially for SIMD filter processing |
| CoreAudio / AudioToolbox | System frameworks | HAL API, AUHAL, process taps, AudioConverter |
| SMAppService | System framework | Launch at login |

No third-party UI dependencies. No virtual audio drivers. No kernel extensions.

---

## 8. Checkpoint Dependency Graph

```
CP1 (passthrough) ─── must pass ──→ CP2 (device switching) ─── must pass ──→ CP3 (single biquad)
                                                                                      │
                                                                              must pass ↓
                                                                           CP4 (filter bank + unit test)
                                                                                      │
                                                                          unit test GATE ↓
                                                               CP5 (curve display) ──→ CP6 (interactive)
                                                                                              │
                                                                                      ┌───────┤
                                                                                      ↓       ↓
                                                                               CP7 (presets)  CP8 (menu bar)
                                                                                      │       │
                                                                                      └───┬───┘
                                                                                          ↓
                                                                               CP9 (per-device, optional)
```

**Hard gates:**
- CP1 must pass before CP2 starts.
- CP4 unit test must pass before any UI work (CP5+) begins.
- CP7 and CP8 can be done in parallel after CP6.

---

## 9. Verification Checklist Per Checkpoint

| CP | Verification Method |
|---|---|
| 1 | Manual: play audio for 10+ minutes, confirm no doubling/echo/latency creep. Console logs confirm callbacks firing. Ring buffer fill level stable. |
| 2 | Manual: play pink noise, confirm audible 1kHz boost. Toggle filter, confirm difference. |
| 3 | Manual: switch output devices while playing. Audio resumes <300ms, no crash. Test at least 3 different device types. |
| 4 | **Automated unit tests** — impulse→FFT→magnitude comparison ±0.5dB, plus edge-case tests (0dB passthrough, extreme Q/gain, disabled bands). All must pass. |
| 5 | Visual: curve shape matches CP4 test expectations. |
| 6 | Manual: drag handle, hear change in real time. No glitch or dropout. |
| 7 | Manual: save preset, quit app, reopen, load preset — bands match. Import/export round-trips. |
| 8 | Manual: close EQ window, audio keeps processing. Menu bar controls work. App launches at login. |
| 9 | Manual: switch between devices, confirm different EQ loads for each. |

---

## 10. Reference Implementations

These are real, working implementations of Core Audio taps that the agent should consult if stuck on the tap/aggregate device setup. They confirm the API patterns used in this PRD.

| Reference | URL | What it demonstrates |
|---|---|---|
| **sudara's gist** (Obj-C) | https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f | Minimal tap example. Shows `CATapDescription`, `setMuteBehavior`, `kAudioSubTapDriftCompensationKey`, aggregate device dictionary structure with tap list as array of dictionaries. |
| **audiotee** (Swift CLI) | https://github.com/makeusabrew/audiotee | Full capture-to-stdout tool. `AudioTapManager` and `AudioRecorder` are the key classes. Shows IOProc callback, format handling, sample rate conversion via AudioConverter. |
| **AudioCap** (Swift/SwiftUI) | https://github.com/insidegui/AudioCap | GUI app for recording system/process audio. Shows the complete tap→aggregate→IOProc→file flow. Also demonstrates TCC permission probing (private API — reference only, don't use in production). |
| **SoundPusher** (C++/Obj-C) | https://github.com/q-p/SoundPusher | Established audio app using taps since v1.5. Key insight: aggregate device should contain ONLY the tap, not also the device being tapped. Also confirms that tapping a device with input streams requires additional microphone permission. |
| **Apple docs** | https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps | Official documentation. Contains the `kAudioAggregateDevicePropertyTapList` bug (uses tapID instead of aggregateDeviceID). Read the CoreAudio C headers directly for better documentation than the web docs. |

**Note on the Apple documentation bug:** Apple's own sample code for modifying `kAudioAggregateDevicePropertyTapList` incorrectly uses `tapID` as the target `AudioObjectID` in both `AudioObjectGetPropertyData` and `AudioObjectSetPropertyData`. The correct target is `aggregateDeviceID`. This has been filed as Feedback FB17411663. All third-party implementations work around this.


Here's a section you can drop into Section 6 (Critical Implementation Details):

---

### Internal Audio Format Convention

The entire internal pipeline uses a single canonical format:

**Float32, non-interleaved, stereo (2 channels), at the tap's native sample rate.**

This applies to: the ring buffer contents, all EQ processing, and the data passed between components. Format conversions happen only at the two boundaries of the pipeline:

**Entry (tap IOProc):** If `kAudioTapPropertyFormat` reports anything other than Float32 non-interleaved (possible with some Bluetooth devices), convert via `AudioConverterNew` before writing to the ring buffer. After conversion, the ring buffer always contains the canonical format.

**Exit (AUHAL render callback):** Set the AUHAL input scope (element 0, `kAudioUnitScope_Input`) to Float32, non-interleaved, stereo, at the appropriate rate:
- If tap rate matches the output device rate → set to tap rate. No converter needed.
- If tap rate differs → the AudioConverter (see "Sample Rate Conversion" section) resamples from the ring buffer's tap rate to the device rate. Set the AUHAL input scope to the device's native rate.

**Do not set the AUHAL output scope format** (element 0, `kAudioUnitScope_Output`). The AUHAL reads this from the hardware device automatically and handles final conversion (e.g., to Int24, interleaved) internally. Overriding it causes format mismatches that produce noise or silence.

```
Tap IOProc          →  [convert if needed]  →  Ring Buffer  →  EQ  →  [resample if needed]  →  AUHAL input scope  →  [AUHAL internal]  →  Hardware
Float32/NI/2ch/tapRate                         canonical        canonical                       Float32/NI/2ch/devRate                      device-native
```
