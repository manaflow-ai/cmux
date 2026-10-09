public import CmuxiOSFeatureKit

/// A machine's identifying color, chosen from a muted palette by a stable
/// hash of its id, so every device shows a Mac in the same color. No blue
/// (REWRITE.md visual rules).
public enum MachineColor: String, CaseIterable, Hashable, Sendable {
    case graphite, green, orange, red, purple, teal, brown, pink, yellow

    public init(hostID: HostID) {
        // FNV-1a over the UTF-8 id: stable across launches and platforms,
        // unlike `hashValue`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in hostID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let all = Self.allCases
        self = all[Int(hash % UInt64(all.count))]
    }
}
