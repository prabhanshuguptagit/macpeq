## Step 8: Automated Tests

### Test File Structure

```swift
// Tests/EQProcessorTests.swift

import XCTest
import Accelerate

final class EQProcessorTests: XCTestCase {
    let sampleRate: Float = 48000

    // MARK: - Helpers

    /// Compute magnitude in dB at a given frequency from an FFT of an impulse response.
    ///
    /// Note: vDSP_fft_zrip applies an implicit factor of 2 to its output.
    /// This doesn't affect relative measurements (measured vs. theoretical both
    /// go through the same FFT), but absolute dB values will be offset by ~6dB.
    /// If you ever compare against hardcoded dB values, normalize first:
    ///   real[i] /= Float(fftSize / 2)
    ///   imag[i] /= Float(fftSize / 2)
    func magnitudeAtFrequency(
        _ freq: Float,
        realParts: UnsafePointer<Float>,
        imagParts: UnsafePointer<Float>,
        fftSize: Int,
        sampleRate: Float
    ) -> Float {
        let binWidth = sampleRate / Float(fftSize)
        let bin = Int(round(freq / binWidth))
        guard bin > 0, bin < fftSize / 2 else { return -Float.infinity }
        let re = realParts[bin]
        let im = imagParts[bin]
        let magnitude = sqrtf(re * re + im * im)
        return 20.0 * log10f(magnitude + 1e-30)  // avoid log(0)
    }

    /// Compute theoretical magnitude in dB for a single biquad at a frequency
    func theoreticalMagnitude(_ band: EQBand, sampleRate: Float) -> Float {
        let c = BiquadMath.coefficients(
            type: band.type,
            frequency: band.frequency,
            gain: band.gain,
            q: band.q,
            sampleRate: sampleRate
        )
        let w = 2.0 * Float.pi * band.frequency / sampleRate
        let cosW = cos(w)
        let cos2W = cos(2.0 * w)

        let num = c.b0 * c.b0 + c.b1 * c.b1 + c.b2 * c.b2
                + 2.0 * (c.b0 * c.b1 + c.b1 * c.b2) * cosW
                + 2.0 * c.b0 * c.b2 * cos2W
        let den = 1.0 + c.a1 * c.a1 + c.a2 * c.a2
                + 2.0 * (c.a1 + c.a1 * c.a2) * cosW
                + 2.0 * c.a2 * cos2W

        return 10.0 * log10f(num / den)
    }

    /// Run an impulse through the processor and return the FFT
    func processImpulse(
        processor: EQProcessor,
        fftSize: Int = 4096,
        channel: Int = 0
    ) -> (real: [Float], imag: [Float]) {
        var impulse = [Float](repeating: 0, count: fftSize)
        impulse[0] = 1.0

        impulse.withUnsafeMutableBufferPointer { buf in
            processor.process(
                buffer: buf.baseAddress!,
                frameCount: fftSize,
                channel: channel
            )
        }

        // Perform real FFT using vDSP
        let log2n = vDSP_Length(log2f(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            XCTFail("Failed to create FFT setup")
            return ([], [])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = fftSize / 2
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)

        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )

                impulse.withUnsafeBufferPointer { impBuf in
                    impBuf.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: halfN
                    ) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        return (real, imag)
    }

    /// Create a processor with the given bands, padded to `totalBands` with disabled entries
    func makeProcessor(bands: [EQBand], totalBands: Int = 10, channelCount: Int = 1) -> EQProcessor {
        var allBands = bands
        while allBands.count < totalBands {
            allBands.append(EQBand(frequency: 1000, gain: 0, enabled: false))
        }
        let processor = EQProcessor(bandCount: totalBands, channelCount: channelCount, sampleRate: sampleRate)
        processor.updateBands(allBands)
        return processor
    }
}
```

### Test 1: Impulse Response Matches Theory (THE GATE)

```swift
func testImpulseResponseMatchesTheory() {
    let bands: [EQBand] = [
        EQBand(frequency: 1000, gain: 6.0, q: 1.0, type: .peak),
        EQBand(frequency: 4000, gain: -3.0, q: 2.0, type: .peak),
    ]

    // v2 change: use channelCount: 1 so there's no pre-gain ambiguity.
    // We're testing filter math in isolation — pre-gain is tested separately.
    let processor = makeProcessor(bands: bands, channelCount: 1)

    let fftSize = 4096
    let (real, imag) = processImpulse(processor: processor, fftSize: fftSize)

    for band in bands where band.enabled {
        let measured = magnitudeAtFrequency(
            band.frequency,
            realParts: real, imagParts: imag,
            fftSize: fftSize, sampleRate: sampleRate
        )
        let expected = theoreticalMagnitude(band, sampleRate: sampleRate)

        // The processor applies pre-gain, which shifts the entire response
        // down uniformly. Compute the shift and remove it from the measurement.
        let preGainDB: Float = -bands.filter { $0.enabled && $0.gain > 0 }
            .reduce(0) { $0 + $1.gain }
        let adjusted = measured - preGainDB

        XCTAssertEqual(adjusted, expected, accuracy: 0.5,
            "Band \(band.frequency)Hz: measured \(adjusted)dB, expected \(expected)dB")
    }
}
```

**v2 note on the reviewer's pre-gain concern:** The reviewer suggested bypassing pre-gain in tests to verify filter math in isolation. That's the cleanest approach. Two options:

1. **Preferred:** Add a `@testable` internal initializer or a `testMode` flag that disables pre-gain. Then this test needs no pre-gain compensation math at all.
2. **Acceptable:** Keep the pre-gain compensation math as above. It's a uniform offset, so the arithmetic is simple and correct.

If you go with option 1:

```swift
// In EQProcessor, internal-only:
#if DEBUG
/// For testing: process without pre-gain so impulse response tests
/// verify filter math in isolation.
var disablePreGain: Bool = false
#endif

// In process(), change the pre-gain block:
let preGain = snapshot.preGainLinear
#if DEBUG
if !disablePreGain && preGain < 1.0 {
#else
if preGain < 1.0 {
#endif
    for i in 0..<frameCount {
        buffer[i] *= preGain
    }
}
```

Then the test becomes:

```swift
func testImpulseResponseMatchesTheory() {
    let bands: [EQBand] = [
        EQBand(frequency: 1000, gain: 6.0, q: 1.0, type: .peak),
        EQBand(frequency: 4000, gain: -3.0, q: 2.0, type: .peak),
    ]

    let processor = makeProcessor(bands: bands, channelCount: 1)
    processor.disablePreGain = true  // test filter math in isolation

    let fftSize = 4096
    let (real, imag) = processImpulse(processor: processor, fftSize: fftSize)

    for band in bands where band.enabled {
        let measured = magnitudeAtFrequency(
            band.frequency,
            realParts: real, imagParts: imag,
            fftSize: fftSize, sampleRate: sampleRate
        )
        let expected = theoreticalMagnitude(band, sampleRate: sampleRate)

        XCTAssertEqual(measured, expected, accuracy: 0.5,
            "Band \(band.frequency)Hz: measured \(measured)dB, expected \(expected)dB")
    }
}
```

### Test 1b: Pre-Gain Is Correct (NEW — tests pre-gain in isolation)

```swift
func testPreGainAppliedCorrectly() {
    // Two bands at +6dB each → worst-case +12dB → preGain = 10^(-12/20) ≈ 0.251
    let bands: [EQBand] = [
        EQBand(frequency: 1000, gain: 6.0, q: 1.0, type: .peak),
        EQBand(frequency: 4000, gain: 6.0, q: 1.0, type: .peak),
    ]

    let processor = makeProcessor(bands: bands, channelCount: 1)

    // Feed a DC-ish signal (all 1.0) through the processor.
    // We can't easily isolate pre-gain from the biquad math on arbitrary signals,
    // so instead: process an impulse with and without pre-gain, verify the
    // uniform offset matches the expected pre-gain.
    let fftSize = 4096

    // With pre-gain (normal)
    let (realWith, imagWith) = processImpulse(processor: processor, fftSize: fftSize)

    // Without pre-gain
    processor.disablePreGain = true
    processor.resetState()
    let (realWithout, imagWithout) = processImpulse(processor: processor, fftSize: fftSize)

    // The difference at any frequency should be the pre-gain in dB
    let expectedPreGainDB: Float = -12.0  // -(6+6)
    let testFreq: Float = 500  // pick a frequency away from the band centers

    let magWith = magnitudeAtFrequency(testFreq, realParts: realWith, imagParts: imagWith,
                                        fftSize: fftSize, sampleRate: sampleRate)
    let magWithout = magnitudeAtFrequency(testFreq, realParts: realWithout, imagParts: imagWithout,
                                           fftSize: fftSize, sampleRate: sampleRate)

    let measuredPreGainDB = magWith - magWithout
    XCTAssertEqual(measuredPreGainDB, expectedPreGainDB, accuracy: 0.1,
        "Pre-gain offset: measured \(measuredPreGainDB)dB, expected \(expectedPreGainDB)dB")
}
```

### Test 2: All Bands at 0dB = Passthrough

```swift
func testZeroGainIsPassthrough() {
    var bands = [EQBand]()
    for freq: Float in [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] {
        bands.append(EQBand(frequency: freq, gain: 0, q: 1.0, type: .peak))
    }

    let processor = EQProcessor(bandCount: 10, channelCount: 1, sampleRate: sampleRate)
    processor.updateBands(bands)

    let size = 1024
    var input = [Float](repeating: 0, count: size)
    // Fill with known signal (not impulse — use arbitrary values)
    for i in 0..<size { input[i] = sinf(Float(i) * 0.1) }
    let expected = input  // copy before processing

    input.withUnsafeMutableBufferPointer { buf in
        processor.process(buffer: buf.baseAddress!, frameCount: size, channel: 0)
    }

    for i in 0..<size {
        XCTAssertEqual(input[i], expected[i], accuracy: 1e-6,
            "Sample \(i): \(input[i]) != \(expected[i])")
    }
}
```

### Test 3: Extreme Gain — No NaN/Inf

```swift
func testExtremeGainNoOverflow() {
    let bands: [EQBand] = [
        EQBand(frequency: 1000, gain: 20.0, q: 0.1, type: .peak)  // max gain, min Q
    ]
    let processor = makeProcessor(bands: bands)

    var signal = [Float](repeating: 0, count: 4096)
    signal[0] = 1.0

    signal.withUnsafeMutableBufferPointer { buf in
        processor.process(buffer: buf.baseAddress!, frameCount: 4096, channel: 0)
    }

    for i in 0..<4096 {
        XCTAssertFalse(signal[i].isNaN, "NaN at sample \(i)")
        XCTAssertFalse(signal[i].isInfinite, "Inf at sample \(i)")
        XCTAssertTrue(signal[i] >= -1.0 && signal[i] <= 1.0,
            "Sample \(i) out of range: \(signal[i])")
    }
}
```

### Test 4: Extreme Q — Filter Stability

```swift
func testExtremeQStability() {
    // Note on buffer size: for Q=10 at the lowest frequency (31Hz), the decay
    // time is roughly Q / (π × f) × sampleRate ≈ 10 / (π × 31) × 48000 ≈ 4931 samples.
    // 8192 provides sufficient margin. If testing extreme Q at frequencies below 31Hz
    // (outside our 20Hz–20kHz range), increase the buffer.
    for q: Float in [0.1, 10.0] {
        let bands: [EQBand] = [
            EQBand(frequency: 1000, gain: 6.0, q: q, type: .peak)
        ]
        let processor = makeProcessor(bands: bands)

        var signal = [Float](repeating: 0, count: 8192)
        signal[0] = 1.0

        signal.withUnsafeMutableBufferPointer { buf in
            processor.process(buffer: buf.baseAddress!, frameCount: 8192, channel: 0)
        }

        // Check last 1000 samples have decayed (filter is stable, not oscillating)
        let tail = signal[(8192 - 1000)...]
        let maxTail = tail.max() ?? 0
        XCTAssertLessThan(abs(maxTail), 0.01,
            "Filter not decaying at Q=\(q): tail max = \(maxTail)")
    }
}
```

### Test 5: Disabled Bands Have Zero Effect

```swift
func testDisabledBandsArePassthrough() {
    var bands = [EQBand]()
    // All bands have large gains but are disabled
    for freq: Float in [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] {
        bands.append(EQBand(frequency: freq, gain: 12.0, q: 1.0, type: .peak, enabled: false))
    }

    let processor = EQProcessor(bandCount: 10, channelCount: 1, sampleRate: sampleRate)
    processor.updateBands(bands)

    var signal = [Float](repeating: 0, count: 512)
    for i in 0..<512 { signal[i] = sinf(Float(i) * 0.3) }
    let expected = signal

    signal.withUnsafeMutableBufferPointer { buf in
        processor.process(buffer: buf.baseAddress!, frameCount: 512, channel: 0)
    }

    for i in 0..<512 {
        XCTAssertEqual(signal[i], expected[i], accuracy: 1e-6)
    }
}
```

### Test 6: All Bands Boosted — Clamp Engages

```swift
func testAllBandsBoostedStaysFinite() {
    var bands = [EQBand]()
    for freq: Float in [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] {
        bands.append(EQBand(frequency: freq, gain: 6.0, q: 1.0, type: .peak))
    }

    let processor = EQProcessor(bandCount: 10, channelCount: 1, sampleRate: sampleRate)
    processor.updateBands(bands)

    // Full-scale sine wave (worst case for clipping)
    var signal = [Float](repeating: 0, count: 4096)
    for i in 0..<4096 { signal[i] = sinf(2.0 * .pi * 1000.0 * Float(i) / sampleRate) }

    signal.withUnsafeMutableBufferPointer { buf in
        processor.process(buffer: buf.baseAddress!, frameCount: 4096, channel: 0)
    }

    for i in 0..<4096 {
        XCTAssertTrue(signal[i] >= -1.0 && signal[i] <= 1.0,
            "Clipping at sample \(i): \(signal[i])")
    }
}
```

### Test 7: Parameter Swap Produces New Response (renamed from "Mid-Stream Swap")

**v2 change:** Renamed to accurately describe what it tests. This verifies that updating coefficients takes effect on the next `process()` call and doesn't produce NaN/Inf. It does *not* test true concurrent access (UI thread writing while audio thread reads simultaneously) — that would be a stress/fuzz test, not a unit test.

```swift
func testParameterSwapProducesNewResponse() {
    var flatBands = [EQBand]()
    var boostedBands = [EQBand]()
    for freq: Float in [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] {
        flatBands.append(EQBand(frequency: freq, gain: 0))
        boostedBands.append(EQBand(frequency: freq, gain: 6.0))
    }

    let processor = EQProcessor(bandCount: 10, channelCount: 1, sampleRate: sampleRate)
    processor.updateBands(flatBands)

    // Process a buffer
    var buf1 = [Float](repeating: 0, count: 512)
    buf1[0] = 1.0
    buf1.withUnsafeMutableBufferPointer { buf in
        processor.process(buffer: buf.baseAddress!, frameCount: 512, channel: 0)
    }

    // Swap coefficients (simulates UI thread updating)
    processor.updateBands(boostedBands)

    // Process another buffer — should use new coefficients, no crash, no NaN
    var buf2 = [Float](repeating: 0, count: 512)
    buf2[0] = 1.0
    buf2.withUnsafeMutableBufferPointer { buf in
        processor.process(buffer: buf.baseAddress!, frameCount: 512, channel: 0)
    }

    // Verify no corruption
    for i in 0..<512 {
        XCTAssertFalse(buf2[i].isNaN, "NaN after parameter swap at \(i)")
        XCTAssertFalse(buf2[i].isInfinite, "Inf after parameter swap at \(i)")
    }

    // Verify the second buffer is different from the first
    // (boosted bands should change the impulse response)
    let firstEnergy = buf1.reduce(0) { $0 + $1 * $1 }
    let secondEnergy = buf2.reduce(0) { $0 + $1 * $1 }
    XCTAssertNotEqual(firstEnergy, secondEnergy, accuracy: 0.001,
        "Parameter swap had no effect")
}
```

### Test 8: Filter Type Correctness — Shelves (NEW)

**v2 addition:** The original tests only used `.peak` filters. This test verifies that shelf filters produce the expected response shape, catching sign errors or formula bugs in `BiquadMath.coefficients()`.

```swift
func testLowShelfShape() {
    // Low shelf at 200Hz, +6dB. Frequencies well below 200Hz should be boosted ~6dB.
    // Frequencies well above 200Hz should be ~0dB (unaffected).
    let bands: [EQBand] = [
        EQBand(frequency: 200, gain: 6.0, q: 0.707, type: .lowShelf)
    ]
    let processor = makeProcessor(bands: bands)
    processor.disablePreGain = true

    let fftSize = 4096
    let (real, imag) = processImpulse(processor: processor, fftSize: fftSize)

    // Well below shelf frequency: should be close to +6dB
    let magLow = magnitudeAtFrequency(50, realParts: real, imagParts: imag,
                                       fftSize: fftSize, sampleRate: sampleRate)
    // Well above shelf frequency: should be close to 0dB
    let magHigh = magnitudeAtFrequency(4000, realParts: real, imagParts: imag,
                                        fftSize: fftSize, sampleRate: sampleRate)

    // The FFT has a constant scaling offset (see magnitudeAtFrequency note),
    // so compare the difference rather than absolute values.
    let shelfRise = magLow - magHigh
    XCTAssertEqual(shelfRise, 6.0, accuracy: 1.0,
        "Low shelf should boost lows ~6dB relative to highs, got \(shelfRise)dB")
}

func testHighShelfShape() {
    // High shelf at 4000Hz, +6dB. Frequencies well above should be boosted ~6dB.
    // Frequencies well below should be ~0dB.
    let bands: [EQBand] = [
        EQBand(frequency: 4000, gain: 6.0, q: 0.707, type: .highShelf)
    ]
    let processor = makeProcessor(bands: bands)
    processor.disablePreGain = true

    let fftSize = 4096
    let (real, imag) = processImpulse(processor: processor, fftSize: fftSize)

    let magLow = magnitudeAtFrequency(200, realParts: real, imagParts: imag,
                                       fftSize: fftSize, sampleRate: sampleRate)
    let magHigh = magnitudeAtFrequency(16000, realParts: real, imagParts: imag,
                                        fftSize: fftSize, sampleRate: sampleRate)

    let shelfRise = magHigh - magLow
    XCTAssertEqual(shelfRise, 6.0, accuracy: 1.0,
        "High shelf should boost highs ~6dB relative to lows, got \(shelfRise)dB")
}
```

### Test 9: Low-Pass and High-Pass Shape (NEW)

```swift
func testLowPassRolloff() {
    // Low-pass at 1000Hz. Signal well above cutoff should be heavily attenuated.
    let bands: [EQBand] = [
        EQBand(frequency: 1000, gain: 0, q: 0.707, type: .lowPass)
    ]
    let processor = makeProcessor(bands: bands)
    processor.disablePreGain = true

    let fftSize = 4096
    let (real, imag) = processImpulse(processor: processor, fftSize: fftSize)

    let magAtCutoff = magnitudeAtFrequency(1000, realParts: real, imagParts: imag,
                                            fftSize: fftSize, sampleRate: sampleRate)
    let magAbove = magnitudeAtFrequency(8000, realParts: real, imagParts: imag,
                                         fftSize: fftSize, sampleRate: sampleRate)

    // At 3 octaves above cutoff, a 2nd-order LPF should be down ~36dB
    // (12dB/octave × 3 octaves). Allow generous tolerance.
    let attenuation = magAtCutoff - magAbove
    XCTAssertGreaterThan(attenuation, 20.0,
        "Low-pass should attenuate well above cutoff, only got \(attenuation)dB rolloff")
}

func testHighPassRolloff() {
    // High-pass at 1000Hz. Signal well below cutoff should be heavily attenuated.
    let bands: [EQBand] = [
        EQBand(frequency: 1000, gain: 0, q: 0.707, type: .highPass)
    ]
    let processor = makeProcessor(bands: bands)
    processor.disablePreGain = true

    let fftSize = 4096
    let (real, imag) = processImpulse(processor: processor, fftSize: fftSize)

    let magAtCutoff = magnitudeAtFrequency(1000, realParts: real, imagParts: imag,
                                            fftSize: fftSize, sampleRate: sampleRate)
    let magBelow = magnitudeAtFrequency(125, realParts: real, imagParts: imag,
                                         fftSize: fftSize, sampleRate: sampleRate)

    // At 3 octaves below cutoff, a 2nd-order HPF should be down ~36dB
    let attenuation = magAtCutoff - magBelow
    XCTAssertGreaterThan(attenuation, 20.0,
        "High-pass should attenuate well below cutoff, only got \(attenuation)dB rolloff")
}
```
