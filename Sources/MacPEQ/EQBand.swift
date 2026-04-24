import Foundation

/// Parameters for a single EQ band
struct EQBand: Codable, Identifiable {
    let id: UUID
    var frequency: Float   // Hz, 20–20000
    var gain: Float        // dB, -20 to +20
    var q: Float           // 0.1 to 10.0
    var type: FilterType
    var enabled: Bool

    init(
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
