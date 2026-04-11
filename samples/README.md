# Reference Implementations

This directory contains third-party reference implementations of Core Audio tap usage. These are for educational/reference purposes only and are not part of the MacPEQ build.

## Contents

- **audiotee/** - Swift CLI tool capturing system audio to stdout
  - Source: https://github.com/makeusabrew/audiotee
  - Key files: `AudioTapManager.swift`, `AudioRecorder.swift`

- **CapturingSystemAudioWithCoreAudioTapsm/** - Apple's official sample code
  - Source: Apple Developer Documentation
  - Note: Contains a known bug in tap list property targeting (FB17411663)

- **sudara** - Minimal Objective-C tap example (gist)
  - Source: https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f
  - Demonstrates proper aggregate device dictionary structure

## Usage

These are standalone projects. Do not build them as part of MacPEQ.
