import Foundation

/// Filter types supported by the parametric EQ
enum FilterType: String, Codable, CaseIterable {
    case peak = "Peak"
    case lowShelf = "Low Shelf"
    case highShelf = "High Shelf"
    case lowPass = "Low Pass"
    case highPass = "High Pass"
    case notch = "Notch"
}

/// Audio EQ Cookbook coefficient calculation (Robert Bristow-Johnson)
/// All coefficients are normalized so that a0 = 1.0
enum BiquadMath {
    
    /// Calculate biquad coefficients for the specified filter type
    /// - Returns: (b0, b1, b2, a1, a2) with a0 normalized to 1.0
    static func coefficients(
        type: FilterType,
        frequency: Float,
        gain: Float,
        q: Float,
        sampleRate: Float
    ) -> (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        
        let w0 = 2.0 * Float.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)
        
        var b0: Float = 1.0, b1: Float = 0.0, b2: Float = 0.0
        var a0: Float = 1.0, a1: Float = 0.0, a2: Float = 0.0
        
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
        return (b0 * a0Inv, b1 * a0Inv, b2 * a0Inv, a1 * a0Inv, a2 * a0Inv)
    }
    
    /// Create a BiquadFilter with the specified parameters
    static func makeFilter(
        type: FilterType,
        frequency: Float,
        gain: Float,
        q: Float,
        sampleRate: Float
    ) -> BiquadFilter {
        let c = coefficients(type: type, frequency: frequency, gain: gain, q: q, sampleRate: sampleRate)
        return BiquadFilter(b0: c.b0, b1: c.b1, b2: c.b2, a1: c.a1, a2: c.a2)
    }
}

/// Single biquad filter with state
/// Audio thread processes samples, state persists across callbacks
struct BiquadFilter {
    // Coefficients (normalized so a0 = 1.0)
    var b0: Float, b1: Float, b2: Float
    var a1: Float, a2: Float
    
    // State (persists across callbacks - must not reset between calls)
    var x1: Float = 0.0, x2: Float = 0.0
    var y1: Float = 0.0, y2: Float = 0.0
    
    /// Initialize with coefficients. State starts at zero.
    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2
        self.a1 = a1; self.a2 = a2
    }
    
    /// Process a single sample - no allocations, no locks
    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        // Direct Form I: y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = input
        y2 = y1; y1 = output
        return output
    }
    
    /// Process a buffer in-place
    @inline(__always)
    mutating func processBuffer(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for i in 0..<frameCount { buffer[i] = process(buffer[i]) }
    }
    
    /// Reset state (rarely needed - state must persist across callbacks)
    mutating func resetState() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }
}
