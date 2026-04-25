# Why Not Use Global Taps?

## The Short Version

Global taps (`CATapDescription.initStereoGlobalTapButExcludeProcesses`) have a **confirmed bug** where audio volume is incorrectly divided by the number of output channels on the device. A 12-channel interface like the UMC1820 causes 6x volume attenuation. This is an Apple HAL bug, not fixable by us.

## The Architecture

CoreAudio provides exactly **two** tap APIs:

| API | Device Targeting | Follows Default Device | Volume Bug |
|-----|------------------|------------------------|------------|
| `initStereoGlobalTapButExcludeProcesses` | Nil (follows default) | ✅ Automatic | ❌ Divides by channel count |
| `init(processes:deviceUID:stream:)` | Specific UID required | ❌ Fixed to one device | ✅ Correct volume |

There is no third option. You cannot create a "device-following but not global" tap.

## The Bug Details

From Sudara's [CoreAudio Taps example](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f):

> Note: I believe there is a bug in the CoreAudio Tap API. If the default output device has 2 output channels this works as expected. But if you have a device with 4 output channels then the volume of the resulting buffer will be halved. You can extrapolate this to any number of channels.

**Math:**
- MacBook stereo (2ch): Audio is correct
- UMC1820 (12ch): Audio is divided by 6 (12/2)
- Any device with N channels: Volume ÷ (N/2)

## Why Not Just Compensate?

One could multiply the output by the channel count to compensate. **This is dangerous.**

If Apple fixes this bug in a future macOS update, the "fix" becomes a **6x volume blast** that could damage speakers and hearing.

Detecting the bug at runtime is fragile and may fail on new hardware or macOS versions.

## Our Choice

We use **device-specific taps** (`init(processes:deviceUID:stream:)`) despite the inconvenience.

**Benefits:**
- Correct volume on all devices (2ch or 12ch)
- No reliance on Apple bugs
- Predictable, stable behavior

**Trade-off:**
- Must destroy and recreate the tap/aggregate/AUHAL pipeline on device switches
- ~50-100ms audio gap during device changes

For an EQ app, a brief dropout when switching output devices is preferable to incorrect audio levels or the risk of future volume explosions.

## Related Issues

This same bug exists in **ScreenCaptureKit** on macOS 14.2+ (where CoreAudio Taps were introduced). It did not exist in macOS 14.1.

Apple has not acknowledged or fixed this as of the current implementation date.

## Additional Concern: Sample Rate Conversion (SRC) Quality

Global taps have a **fixed format** (typically 48kHz stereo). When the output device runs at a different sample rate (44.1kHz, 96kHz, etc.), AUHAL performs SRC.

From [CONNERLABS: Resampling in Mac OS](https://connerlabs.org/resampling-in-mac-os/):

> I don't know about you, but I wouldn't trust any resampling algorithm I hadn't written or at least tested myself. They're notoriously hard to get right. And a "right" one consumes so much CPU power that there's a real incentive to downgrade the performance deliberately.
>
> Here's the official line from the Coreaudio mailing list [...] This was a comment posed to the list (which was replayed verbatim from Benchmark's Elias Gwinn)
>
>> If the user changes CoreAudio's sample-rate in AudioMIDI Setup to something different than what iTunes is locked to, CoreAudio will convert the sample rate of the audio that it is receiving from iTunes. In this case, the audio may be undergoing two levels of sample-rate conversion (once by iTunes and once by CoreAudio). **(The SRC in iTunes is of very high quality (virtually inaudible), but the SRC in CoreAudio is horrible and will cause significant distortion.)** If the user wants to change the sample rate of CoreAudio, iTunes should be restarted so that it can lock to the correct sample rate.
>
> This is the response from an Apple employee:
>
> iTunes uses the AudioConverter API internally but we set the quality to "max" and **AUHAL probably uses the default (I don't know)**. One SRC at max quality followed by one at the default quality is not so great when analyzing sine tone playback.

**Key takeaway:** AUHAL's default quality SRC is considered "horrible" by audio professionals and can cause "significant distortion." Device-specific taps avoid this because they match the device's native format, eliminating SRC entirely.

## See Also

- `AudioEngine.swift` - Device-specific tap implementation
- Sudara's gist: https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f
- WWDC 2023: "What's new in voice processing" (introduced CoreAudio Taps)
