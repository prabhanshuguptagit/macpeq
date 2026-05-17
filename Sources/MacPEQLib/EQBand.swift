import Foundation

/// Parameters for a single EQ band
public struct EQBand: Codable, Identifiable, Sendable {
    public let id: UUID
    public var frequency: Float   // Hz, 20–20000
    public var gain: Float        // dB, -20 to +20
    public var q: Float           // 0.1 to 10.0
    public var type: FilterType
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        frequency: Float,
        gain: Float,
        q: Float,
        type: FilterType,
        enabled: Bool = true
    ) {
        self.id = id
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.type = type
        self.enabled = enabled
    }
}
