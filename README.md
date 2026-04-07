# MacPEQ

System-wide parametric EQ for macOS using Core Audio process taps. No virtual audio drivers, no kernel extensions.

⚠️ **This is vibe-coded and unstable. Don't expect it to work.**

Requires **macOS 14.2+** (Sonoma).

## Build

```
swift build
.build/debug/MacPEQ
```

Click the waveform icon in the menu bar → Start.

## Status

Work in progress. The audio tap pipeline sets up but captured audio isn't flowing through yet.
