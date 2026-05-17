import Foundation

/// Filter types supported by the parametric EQ
public enum FilterType: String, Codable, CaseIterable {
    case peak = "Peak"
    case lowShelf = "Low Shelf"
    case highShelf = "High Shelf"
    case lowPass = "Low Pass"
    case highPass = "High Pass"
    case notch = "Notch"
}

/// Coefficients for a single biquad (normalized so a0 = 1.0)
/// Safe to copy and share across threads — contains no mutable state.
public struct BiquadCoefficients: Sendable {
    public var b0: Float, b1: Float, b2: Float
    public var a1: Float, a2: Float

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }
}

/// Mutable state that persists across callbacks — must only be touched on the audio thread.
public struct BiquadState {
    public var x1: Float = 0.0, x2: Float = 0.0
    public var y1: Float = 0.0, y2: Float = 0.0

    public init() {}

    public mutating func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }
}

/// Audio EQ Cookbook coefficient calculation (Robert Bristow-Johnson)
public enum BiquadMath {
    /// Calculate biquad coefficients for the specified filter type
    /// - Returns: (b0, b1, b2, a1, a2) with a0 normalized to 1.0
    public static func coefficients(
        type: FilterType,
        frequency: Float,
        gain: Float,
        q: Float,
        sampleRate: Float
    ) -> BiquadCoefficients {
        let w0 = 2.0 * Float.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)

        var b0: Float = 1.0
        var b1: Float = 0.0
        var b2: Float = 0.0
        var a0: Float = 1.0
        var a1: Float = 0.0
        var a2: Float = 0.0

        switch type {
        case .peak:
            let A = pow(10.0, gain / 40.0)
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cosW0
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha / A

        case .lowShelf:
            let A = pow(10.0, gain / 40.0)
            let sqrtA = sqrt(A)
            b0 = A * ((A + 1.0) - (A - 1.0) * cosW0 + 2.0 * sqrtA * alpha)
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0)
            b2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - 2.0 * sqrtA * alpha)
            a0 = (A + 1.0) + (A - 1.0) * cosW0 + 2.0 * sqrtA * alpha
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW0)
            a2 = (A + 1.0) + (A - 1.0) * cosW0 - 2.0 * sqrtA * alpha

        case .highShelf:
            let A = pow(10.0, gain / 40.0)
            let sqrtA = sqrt(A)
            b0 = A * ((A + 1.0) + (A - 1.0) * cosW0 + 2.0 * sqrtA * alpha)
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)
            b2 = A * ((A + 1.0) + (A - 1.0) * cosW0 - 2.0 * sqrtA * alpha)
            a0 = (A + 1.0) - (A - 1.0) * cosW0 + 2.0 * sqrtA * alpha
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW0)
            a2 = (A + 1.0) - (A - 1.0) * cosW0 - 2.0 * sqrtA * alpha

        case .lowPass:
            b0 = (1.0 - cosW0) / 2.0
            b1 = 1.0 - cosW0
            b2 = (1.0 - cosW0) / 2.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .highPass:
            b0 = (1.0 + cosW0) / 2.0
            b1 = -(1.0 + cosW0)
            b2 = (1.0 + cosW0) / 2.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .notch:
            b0 = 1.0
            b1 = -2.0 * cosW0
            b2 = 1.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        }

        let a0Inv = 1.0 / a0
        return BiquadCoefficients(
            b0: b0 * a0Inv,
            b1: b1 * a0Inv,
            b2: b2 * a0Inv,
            a1: a1 * a0Inv,
            a2: a2 * a0Inv
        )
    }

    /// Analytical magnitude response in dB at a given frequency. Given a set of coefficients, 
    /// what gain would a pure sine at frequency F experience, 
    /// without actually running any audio through the filter.
    ///
    /// Evaluates |H(e^jω)|² = |N(e^jω)|² / |D(e^jω)|² directly in rectangular form,
    /// where N and D are the numerator and denominator polynomials of the normalized
    /// biquad transfer function. Equivalent to the expanded polynomial form used in
    /// Equalizer APO's `BiQuad::gainAt`, but computed via Re/Im components to avoid
    /// sign errors in the cross terms.
    ///
    /// Coefficients must already be normalized (a0 = 1).
    public static func gainAtFrequency(
        _ freq: Float,
        coeffs: BiquadCoefficients,
        sampleRate: Float
    ) -> Float {
        let w = 2.0 * Float.pi * freq / sampleRate
        let c1 = cos(w)
        let s1 = sin(w)
        let c2 = cos(2.0 * w)
        let s2 = sin(2.0 * w)
        let b0 = coeffs.b0
        let b1 = coeffs.b1
        let b2 = coeffs.b2
        let a1 = coeffs.a1
        let a2 = coeffs.a2

        let numR = b0 + b1 * c1 + b2 * c2
        let numI = b1 * s1 + b2 * s2
        let denR = 1.0 + a1 * c1 + a2 * c2
        let denI = a1 * s1 + a2 * s2

        let num = numR * numR + numI * numI
        let den = denR * denR + denI * denI

        guard den > 0, num > 0 else { return -Float.infinity }
        return 10.0 * log10(num / den)
    }
}

/// Convenience: single biquad with owned coefficients and state
public struct BiquadFilter {
    public var coeffs: BiquadCoefficients
    public var state: BiquadState

    public init(coeffs: BiquadCoefficients) {
        self.coeffs = coeffs
        self.state = BiquadState()
    }

    @inline(__always)
    public mutating func process(_ input: Float) -> Float {
        let output =
            coeffs.b0 * input
            + coeffs.b1 * state.x1
            + coeffs.b2 * state.x2
            - coeffs.a1 * state.y1
            - coeffs.a2 * state.y2
        state.x2 = state.x1
        state.x1 = input
        state.y2 = state.y1
        state.y1 = output
        return output
    }

    public mutating func processBuffer(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount { buffer[i] = process(buffer[i]) }
    }

    public mutating func resetState() { state.reset() }
}
