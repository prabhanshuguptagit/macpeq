import Foundation
import Testing

@testable import MacPEQLib

// MARK: - Helpers

/// Compute analytical magnitude in dB for a cascade of bands at a given frequency.
/// Each band's transfer function multiplies, so gains add in dB.
private func cascadeGain(
    bands: [EQBand],
    at freq: Float,
    sampleRate: Float
) -> Float {
    bands.filter(\.enabled).reduce(0.0) { total, band in
        let coeffs = BiquadMath.coefficients(
            type: band.type,
            frequency: band.frequency,
            gain: band.gain,
            q: band.q,
            sampleRate: sampleRate
        )
        return total + BiquadMath.gainAtFrequency(freq, coeffs: coeffs, sampleRate: sampleRate)
    }
}

/// Drive a `BiquadFilter` to steady state with a pure sine and return RMS gain in dB.
/// Runs enough cycles that transients have fully decayed before measuring.
private func measuredSineGain(
    coeffs: BiquadCoefficients,
    freq: Float,
    sampleRate: Float,
    settleCycles: Int = 50,
    measureCycles: Int = 10
) -> Float {
    var filter = BiquadFilter(coeffs: coeffs)
    let totalSamples = Int(sampleRate / freq) * (settleCycles + measureCycles)
    let settleEnd = Int(sampleRate / freq) * settleCycles

    var inputRMS: Float = 0
    var outputRMS: Float = 0

    for n in 0..<totalSamples {
        let x = sin(2.0 * Float.pi * freq * Float(n) / sampleRate)
        let y = filter.process(x)
        if n >= settleEnd {
            inputRMS += x * x
            outputRMS += y * y
        }
    }
    guard inputRMS > 0 else { return -Float.infinity }
    return 10.0 * log10(outputRMS / inputRMS)
}

/// Check if two floats are approximately equal within a tolerance
private func isApproximatelyEqual(_ a: Float, _ b: Float, accuracy: Float) -> Bool {
    abs(a - b) <= accuracy
}

// MARK: - Tests

let sampleRate: Float = 48000

// -------------------------------------------------------------------------
// MARK: gainAtFrequency — analytical formula correctness
// -------------------------------------------------------------------------

/// Peak filter must hit exactly the specified gain at its center frequency.
@Test func peakGainAtCenter() {
    for gain: Float in [-12, -6, -3, 0, 3, 6, 12] {
        let coeffs = BiquadMath.coefficients(
            type: .peak, frequency: 1000, gain: gain, q: 2.0, sampleRate: sampleRate)
        let measured = BiquadMath.gainAtFrequency(1000, coeffs: coeffs, sampleRate: sampleRate)
        #expect(
            isApproximatelyEqual(measured, gain, accuracy: 0.001),
            "Peak \(gain)dB: formula gives \(measured)dB at center")
    }
}

/// Higher Q means the boost falls off faster away from the center frequency.
@Test func peakQControlsBandwidth() {
    let centerFreq: Float = 1000
    let probeFreq: Float = 800
    let gain: Float = 12.0

    let lowQ = BiquadMath.coefficients(
        type: .peak, frequency: centerFreq, gain: gain, q: 1.0, sampleRate: sampleRate)
    let highQ = BiquadMath.coefficients(
        type: .peak, frequency: centerFreq, gain: gain, q: 10.0, sampleRate: sampleRate)

    let lowQGain = BiquadMath.gainAtFrequency(probeFreq, coeffs: lowQ, sampleRate: sampleRate)
    let highQGain = BiquadMath.gainAtFrequency(probeFreq, coeffs: highQ, sampleRate: sampleRate)

    #expect(
        lowQGain > highQGain + 6.0,
        "At \(probeFreq)Hz, Q=1 should retain much more boost than Q=10; got \(lowQGain)dB vs \(highQGain)dB")
}

/// Well away from the center, a peak filter should be near 0 dB.
@Test func peakGainFarFromCenter() {
    let coeffs = BiquadMath.coefficients(
        type: .peak, frequency: 1000, gain: 12.0, q: 4.0, sampleRate: sampleRate)
    let farGain = BiquadMath.gainAtFrequency(10000, coeffs: coeffs, sampleRate: sampleRate)
    #expect(
        isApproximatelyEqual(farGain, 0.0, accuracy: 0.1),
        "Peak filter should have ~0dB gain far from center, got \(farGain)dB")
}

/// All filter types with 0 dB gain must have 0 dB magnitude everywhere.
@Test func zeroGainIsTransparent() {
    let testFreqs: [Float] = [50, 200, 1000, 5000, 16000]
    let filterTypes: [FilterType] = [.peak, .lowShelf, .highShelf]

    for type in filterTypes {
        let coeffs = BiquadMath.coefficients(
            type: type, frequency: 1000, gain: 0.0, q: 1.0, sampleRate: sampleRate)
        for freq in testFreqs {
            let gain = BiquadMath.gainAtFrequency(freq, coeffs: coeffs, sampleRate: sampleRate)
            #expect(
                isApproximatelyEqual(gain, 0.0, accuracy: 0.001),
                "\(type) at 0dB: expected 0dB at \(freq)Hz, got \(gain)dB")
        }
    }
}

/// Low shelf should boost/cut lows and leave highs alone.
@Test func lowShelfShape() {
    for gain: Float in [-6, 6] {
        let coeffs = BiquadMath.coefficients(
            type: .lowShelf, frequency: 200, gain: gain, q: 0.707, sampleRate: sampleRate)
        let gainLow = BiquadMath.gainAtFrequency(30, coeffs: coeffs, sampleRate: sampleRate)
        let gainHigh = BiquadMath.gainAtFrequency(8000, coeffs: coeffs, sampleRate: sampleRate)

        // Gain at low freq should be close to the specified gain
        #expect(
            isApproximatelyEqual(gainLow, gain, accuracy: 1.5),
            "Low shelf \(gain)dB: low-freq gain should be ~\(gain)dB, got \(gainLow)dB")
        // High frequencies should be largely unaffected
        #expect(
            isApproximatelyEqual(gainHigh, 0.0, accuracy: 0.5),
            "Low shelf \(gain)dB: high-freq gain should be ~0dB, got \(gainHigh)dB")
    }
}

/// High shelf should boost/cut highs and leave lows alone.
@Test func highShelfShape() {
    for gain: Float in [-6, 6] {
        let coeffs = BiquadMath.coefficients(
            type: .highShelf, frequency: 4000, gain: gain, q: 0.707, sampleRate: sampleRate)
        let gainLow = BiquadMath.gainAtFrequency(200, coeffs: coeffs, sampleRate: sampleRate)
        let gainHigh = BiquadMath.gainAtFrequency(16000, coeffs: coeffs, sampleRate: sampleRate)

        #expect(
            isApproximatelyEqual(gainHigh, gain, accuracy: 1.5),
            "High shelf \(gain)dB: high-freq gain should be ~\(gain)dB, got \(gainHigh)dB")
        #expect(
            isApproximatelyEqual(gainLow, 0.0, accuracy: 0.5),
            "High shelf \(gain)dB: low-freq gain should be ~0dB, got \(gainLow)dB")
    }
}

/// Low-pass must pass DC and attenuate well above cutoff.
@Test func lowPassRolloff() {
    let coeffs = BiquadMath.coefficients(
        type: .lowPass, frequency: 1000, gain: 0, q: 0.707, sampleRate: sampleRate)
    let gainPass = BiquadMath.gainAtFrequency(100, coeffs: coeffs, sampleRate: sampleRate)
    let gainStop = BiquadMath.gainAtFrequency(8000, coeffs: coeffs, sampleRate: sampleRate)

    #expect(
        isApproximatelyEqual(gainPass, 0.0, accuracy: 1.0),
        "LPF: passband gain should be ~0dB, got \(gainPass)dB")
    #expect(
        gainStop < -30,
        "LPF: 3 octaves above cutoff should be < -30dB, got \(gainStop)dB")
}

/// High-pass must pass high frequencies and attenuate well below cutoff.
@Test func highPassRolloff() {
    let coeffs = BiquadMath.coefficients(
        type: .highPass, frequency: 1000, gain: 0, q: 0.707, sampleRate: sampleRate)
    let gainPass = BiquadMath.gainAtFrequency(16000, coeffs: coeffs, sampleRate: sampleRate)
    let gainStop = BiquadMath.gainAtFrequency(125, coeffs: coeffs, sampleRate: sampleRate)

    #expect(
        isApproximatelyEqual(gainPass, 0.0, accuracy: 1.0),
        "HPF: passband gain should be ~0dB, got \(gainPass)dB")
    #expect(
        gainStop < -30,
        "HPF: 3 octaves below cutoff should be < -30dB, got \(gainStop)dB")
}

/// Notch must have very deep attenuation at the notch frequency.
@Test func notchAttenuation() {
    let coeffs = BiquadMath.coefficients(
        type: .notch, frequency: 1000, gain: 0, q: 10.0, sampleRate: sampleRate)
    let gainNotch = BiquadMath.gainAtFrequency(1000, coeffs: coeffs, sampleRate: sampleRate)
    #expect(
        gainNotch < -40,
        "Notch: attenuation at center should be < -40dB, got \(gainNotch)dB")
}

/// High-Q notch must be narrow — it should not significantly attenuate frequencies
/// an octave away from the center. Otherwise it's a wide band-stop, not a notch.
@Test func highQNotchIsNarrow() {
    let centerFreq: Float = 1000
    let octaveAway: Float = 500  // one octave below 1000Hz
    let coeffs = BiquadMath.coefficients(
        type: .notch, frequency: centerFreq, gain: 0, q: 10.0, sampleRate: sampleRate)

    let gainCenter = BiquadMath.gainAtFrequency(centerFreq, coeffs: coeffs, sampleRate: sampleRate)
    #expect(gainCenter < -40, "Notch at center should be deep, got \(gainCenter)dB")

    // One octave away: minimal attenuation
    let gainOctaveAway = BiquadMath.gainAtFrequency(octaveAway, coeffs: coeffs, sampleRate: sampleRate)
    #expect(
        abs(gainOctaveAway) < 1.0,
        "High-Q notch at 1000Hz should not attenuate at 500Hz (octave away), got \(gainOctaveAway)dB")

    let gainAboveOctave = BiquadMath.gainAtFrequency(2000, coeffs: coeffs, sampleRate: sampleRate)
    #expect(
        abs(gainAboveOctave) < 1.0,
        "High-Q notch at 1000Hz should not attenuate at 2000Hz (octave away), got \(gainAboveOctave)dB")
}

@Test func analyticalMatchesMeasuredSine() {
    let cases: [(FilterType, Float, Float, Float, Float, String)] = [
        (.peak, 1000, -8.0, 5.0, 1000, "peak at center"),
        (.peak, 500, 6.0, 2.0, 500, "peak boost at center"),
        (.peak, 4000, -3.0, 10.0, 4000, "high-Q peak cut at center"),
        (.lowShelf, 200, 6.0, 0.707, 200, "low shelf at transition freq"),
        (.highShelf, 4000, -6.0, 0.707, 4000, "high shelf at transition freq"),
        (.lowPass, 1000, 0.0, 0.707, 100, "LPF well into passband"),
        (.highPass, 1000, 0.0, 0.707, 8000, "HPF well into passband"),
        (.notch, 1000, 0.0, 10.0, 2000, "notch probed away from center"),
    ]

    for (type, frequency, gain, q, probeFreq, description) in cases {
        let coeffs = BiquadMath.coefficients(
            type: type, frequency: frequency, gain: gain, q: q, sampleRate: sampleRate)
        let analytical = BiquadMath.gainAtFrequency(
            probeFreq, coeffs: coeffs, sampleRate: sampleRate)
        let measured = measuredSineGain(coeffs: coeffs, freq: probeFreq, sampleRate: sampleRate)

        #expect(
            isApproximatelyEqual(analytical, measured, accuracy: 0.2),
            "\(description): \(type) \(gain)dB @ \(frequency)Hz Q=\(q) probed@\(probeFreq)Hz: analytical=\(analytical)dB measured=\(measured)dB"
        )
    }
}

/// Disabled band must contribute nothing to the cascade.
@Test func disabledBandContributesNothing() {
    let bands = [
        EQBand(frequency: 500, gain: 6.0, q: 2.0, type: .peak),
        EQBand(frequency: 1000, gain: -8.0, q: 4.0, type: .peak),
        EQBand(frequency: 4000, gain: 3.0, q: 1.0, type: .peak),
    ]

    var bandsWithOneDisabled = bands
    bandsWithOneDisabled[1].enabled = false

    let withDisabled = cascadeGain(bands: bandsWithOneDisabled, at: 1000, sampleRate: sampleRate)
    let withoutBand = cascadeGain(bands: [bands[0], bands[2]], at: 1000, sampleRate: sampleRate)

    #expect(
        isApproximatelyEqual(withDisabled, withoutBand, accuracy: 0.01),
        "Disabled band must not contribute to cascade gain")
}

// -------------------------------------------------------------------------
// MARK: BiquadFilter sample processing
// -------------------------------------------------------------------------

/// Identity coefficients (b0=1, rest 0) must pass signal through unchanged.
@Test func identityCoefficientsArePassthrough() {
    let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
    var filter = BiquadFilter(coeffs: identity)

    for _ in 0..<1000 {
        let x = Float.random(in: -1...1)
        let y = filter.process(x)
        #expect(
            isApproximatelyEqual(y, x, accuracy: 1e-6),
            "Identity filter must pass signal unchanged")
    }
}

/// Filter output must never be NaN or infinite, even with extreme parameters.
@Test func noNaNOrInfWithExtremeParams() {
    let extremeCases: [(FilterType, Float, Float, Float)] = [
        (.peak, 20, 20.0, 0.1),  // very low freq, high gain, low Q
        (.peak, 19000, -20.0, 10.0),  // near Nyquist, deep cut, high Q
        (.peak, 1000, 0.0, 0.1),  // zero gain, very low Q
        (.lowPass, 20, 0.0, 10.0),  // LPF at bottom of range
        (.highPass, 19000, 0.0, 10.0),  // HPF near Nyquist
    ]

    for (type, freq, gain, q) in extremeCases {
        let coeffs = BiquadMath.coefficients(
            type: type, frequency: freq, gain: gain, q: q, sampleRate: sampleRate)
        var filter = BiquadFilter(coeffs: coeffs)

        var signal = [Float](repeating: 0, count: 4096)
        signal[0] = 1.0
        for i in 1..<4096 {
            signal[i] = sin(2.0 * Float.pi * 440 * Float(i) / sampleRate)
        }

        for i in 0..<signal.count {
            let y = filter.process(signal[i])
            #expect(!y.isNaN, "\(type) \(gain)dB @ \(freq)Hz: NaN at sample \(i)")
            #expect(!y.isInfinite, "\(type) \(gain)dB @ \(freq)Hz: Inf at sample \(i)")
        }
    }
}

/// After reset, the filter must behave identically to a freshly created one.
@Test func stateResetRestoresFreshBehavior() {
    let coeffs = BiquadMath.coefficients(
        type: .peak, frequency: 1000, gain: 6.0, q: 2.0, sampleRate: sampleRate)

    var fresh = BiquadFilter(coeffs: coeffs)
    let impulse: [Float] = [1] + Array(repeating: 0, count: 63)
    let freshOut = impulse.map { fresh.process($0) }

    var warmed = BiquadFilter(coeffs: coeffs)
    for _ in 0..<500 { _ = warmed.process(Float.random(in: -1...1)) }
    warmed.resetState()

    let resetOut = impulse.map { warmed.process($0) }

    for i in 0..<freshOut.count {
        #expect(
            isApproximatelyEqual(freshOut[i], resetOut[i], accuracy: 1e-5),
            "After reset, sample \(i) differs: fresh=\(freshOut[i]) reset=\(resetOut[i])")
    }
}

/// High-Q peak filters must decay fully — i.e. the filter is stable.
@Test func highQPeakIsStable() {
    let coeffs = BiquadMath.coefficients(
        type: .peak, frequency: 1000, gain: 6.0, q: 10.0, sampleRate: sampleRate)
    var filter = BiquadFilter(coeffs: coeffs)

    // Impulse, then silence. At Q=10/1kHz, decay time ≈ Q/(π·f) ≈ 3ms = ~150 samples.
    // 4096 samples is more than enough.
    var output = [Float](repeating: 0, count: 4096)
    output[0] = 1.0
    for i in 0..<output.count { output[i] = filter.process(output[i]) }

    let tail = output[3000...].map { abs($0) }.max() ?? 0
    #expect(
        tail < 0.001,
        "High-Q peak filter not stable: tail max amplitude = \(tail)")
}

// -------------------------------------------------------------------------
// MARK: Cascade correctness (multiple bands)
// -------------------------------------------------------------------------

/// Cascading two filters: gains must add in dB at frequencies where each
/// filter is at its center or far enough away not to interact.
@Test func twoBandCascadeGainsAdd() {
    let band1 = EQBand(frequency: 500, gain: 6.0, q: 1.0, type: .peak)
    let band2 = EQBand(frequency: 4000, gain: -4.0, q: 1.0, type: .peak)

    let c1 = BiquadMath.coefficients(
        type: band1.type, frequency: band1.frequency,
        gain: band1.gain, q: band1.q, sampleRate: sampleRate)
    let c2 = BiquadMath.coefficients(
        type: band2.type, frequency: band2.frequency,
        gain: band2.gain, q: band2.q, sampleRate: sampleRate)

    // At 500Hz: band1 at center (+6), band2 far away (~0). Total ≈ +6dB.
    let g1_at500 = BiquadMath.gainAtFrequency(500, coeffs: c1, sampleRate: sampleRate)
    let g2_at500 = BiquadMath.gainAtFrequency(500, coeffs: c2, sampleRate: sampleRate)
    #expect(
        isApproximatelyEqual(g1_at500 + g2_at500, 6.0, accuracy: 0.5),
        "Cascade: gain at 500Hz should be ~+6dB, got \(g1_at500 + g2_at500)dB")

    // At 4000Hz: band2 at center (-4), band1 far away (~0). Total ≈ -4dB.
    let g1_at4k = BiquadMath.gainAtFrequency(4000, coeffs: c1, sampleRate: sampleRate)
    let g2_at4k = BiquadMath.gainAtFrequency(4000, coeffs: c2, sampleRate: sampleRate)
    #expect(
        isApproximatelyEqual(g1_at4k + g2_at4k, -4.0, accuracy: 0.5),
        "Cascade: gain at 4kHz should be ~-4dB, got \(g1_at4k + g2_at4k)dB")
}

@Test func processBufferMatchesProcessSample() {
    let coeffs = BiquadMath.coefficients(
        type: .peak, frequency: 1000, gain: 6.0, q: 2.0, sampleRate: sampleRate)

    var signal = (0..<256).map { sin(2.0 * Float.pi * 1000 * Float($0) / sampleRate) }

    var filterA = BiquadFilter(coeffs: coeffs)
    let expected = signal.map { filterA.process($0) }

    var filterB = BiquadFilter(coeffs: coeffs)
    signal.withUnsafeMutableBufferPointer {
        filterB.processBuffer($0.baseAddress!, frameCount: 256)
    }

    for i in 0..<256 {
        #expect(isApproximatelyEqual(signal[i], expected[i], accuracy: 1e-6),
                "processBuffer mismatch at sample \(i)")
    }
}

/// Zero buffer input should produce zero output (filter should be empty state).
@Test func processBufferZeroInputProducesZeroOutput() {
    let coeffs = BiquadMath.coefficients(
        type: .peak, frequency: 1000, gain: 6.0, q: 2.0, sampleRate: sampleRate)

    var filter = BiquadFilter(coeffs: coeffs)
    var buffer = [Float](repeating: 0, count: 256)

    buffer.withUnsafeMutableBufferPointer {
        filter.processBuffer($0.baseAddress!, frameCount: 256)
    }

    // All outputs should be zero (or very close due to floating point)
    for i in 0..<256 {
        #expect(abs(buffer[i]) < 1e-6,
                "Zero input should produce zero output at sample \(i), got \(buffer[i])")
    }
}

/// Zero-length frame count should not crash and leave buffer unchanged.
@Test func processBufferZeroLengthDoesNotCrash() {
    let coeffs = BiquadMath.coefficients(
        type: .peak, frequency: 1000, gain: 6.0, q: 2.0, sampleRate: sampleRate)

    var filter = BiquadFilter(coeffs: coeffs)
    var buffer: [Float] = [1.0, 2.0, 3.0]  // non-zero values

    // This should not crash or modify the buffer
    buffer.withUnsafeMutableBufferPointer {
        filter.processBuffer($0.baseAddress!, frameCount: 0)
    }

    // Buffer should be unchanged
    #expect(buffer == [1.0, 2.0, 3.0],
            "Zero-length processBuffer should leave buffer unchanged")
}

/// State must persist correctly across multiple processBuffer calls.
/// Two calls with 128 samples each should match one call with 256 samples.
@Test func processBufferStatePersistsAcrossCalls() {
    let coeffs = BiquadMath.coefficients(
        type: .peak, frequency: 1000, gain: 6.0, q: 2.0, sampleRate: sampleRate)

    let signal = (0..<256).map { sin(2.0 * Float.pi * 440 * Float($0) / sampleRate) }

    // Single call with 256 samples
    var filterSingle = BiquadFilter(coeffs: coeffs)
    var outputSingle = signal
    outputSingle.withUnsafeMutableBufferPointer {
        filterSingle.processBuffer($0.baseAddress!, frameCount: 256)
    }

    // Two calls with 128 samples each
    var filterSplit = BiquadFilter(coeffs: coeffs)
    var outputSplit = signal
    outputSplit[0..<128].withUnsafeMutableBufferPointer {
        filterSplit.processBuffer($0.baseAddress!, frameCount: 128)
    }
    outputSplit[128..<256].withUnsafeMutableBufferPointer {
        filterSplit.processBuffer($0.baseAddress!, frameCount: 128)
    }

    // Results should be identical
    for i in 0..<256 {
        #expect(isApproximatelyEqual(outputSingle[i], outputSplit[i], accuracy: 1e-6),
                "State persistence mismatch at sample \(i): single=\(outputSingle[i]) split=\(outputSplit[i])")
    }
}
