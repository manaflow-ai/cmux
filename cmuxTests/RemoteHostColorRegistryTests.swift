import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for the per-host origin-color assignment: a host hashes to a stable
/// palette slot, collisions linear-probe to the next free slot, and the same host
/// always resolves to the same slot (so a server shows one color in every window).
@MainActor
@Suite struct RemoteHostColorRegistryTests {
    private func startSlot(_ destination: String, count: Int) -> Int {
        Int(RemoteHostColorRegistry.stableHash(destination) % UInt64(count))
    }

    @Test func stableHashIsDeterministic() {
        // Not Swift's per-process randomized Hasher: equal inputs → equal output,
        // and it varies by input.
        #expect(RemoteHostColorRegistry.stableHash("cmux-srvA") == RemoteHostColorRegistry.stableHash("cmux-srvA"))
        #expect(RemoteHostColorRegistry.stableHash("cmux-srvA") != RemoteHostColorRegistry.stableHash("cmux-srvB"))
    }

    @Test func sameHostAlwaysGetsTheSameSlot() {
        let reg = RemoteHostColorRegistry(slotCount: 16)
        let first = reg.slot(for: "user@example.com")
        let second = reg.slot(for: "user@example.com")
        #expect(first != nil)
        #expect(first == second)
    }

    @Test func firstHostLandsOnItsHashedStart() {
        let count = 16
        let reg = RemoteHostColorRegistry(slotCount: count)
        #expect(reg.slot(for: "cmux-srvA") == startSlot("cmux-srvA", count: count))
    }

    @Test func distinctHostsFillDistinctSlotsUntilFull() {
        let count = 6
        let reg = RemoteHostColorRegistry(slotCount: count)
        var slots: Set<Int> = []
        for i in 0 ..< count {
            slots.insert(reg.slot(for: "host-\(i)")!)
        }
        // Probing guarantees the first `count` distinct hosts occupy every slot.
        #expect(slots == Set(0 ..< count))
    }

    @Test func collisionProbesToADifferentSlot() {
        let count = 8
        let reg = RemoteHostColorRegistry(slotCount: count)
        // Find two destinations that hash to the SAME starting slot.
        var seen: [Int: String] = [:]
        var a = "", b = ""
        for i in 0 ..< 10000 {
            let name = "collide-\(i)"
            let s = startSlot(name, count: count)
            if let prev = seen[s] { a = prev; b = name; break }
            seen[s] = name
        }
        #expect(!a.isEmpty && !b.isEmpty)
        #expect(startSlot(a, count: count) == startSlot(b, count: count)) // genuine collision
        let sa = reg.slot(for: a)!
        let sb = reg.slot(for: b)!
        #expect(sa == startSlot(a, count: count)) // first keeps the hashed start
        #expect(sb != sa)                          // second probed to the next free slot
    }

    @Test func exhaustionReusesSlotsWithoutCrashing() {
        let count = 4
        let reg = RemoteHostColorRegistry(slotCount: count)
        var all: [Int] = []
        for i in 0 ..< (count + 3) {
            all.append(reg.slot(for: "many-\(i)")!)
        }
        // Every assignment is a valid slot; the first `count` are distinct, the rest reuse.
        #expect(all.allSatisfy { (0 ..< count).contains($0) })
        #expect(Set(all.prefix(count)).count == count)
    }

    @Test func emptyPaletteYieldsNoSlot() {
        let reg = RemoteHostColorRegistry(slotCount: 0)
        #expect(reg.slot(for: "anything") == nil)
    }

    @Test func colorHexIsStablePerHost() {
        // Uses the real built-in palette; a host resolves to a non-nil hex and the
        // same hex every time.
        let reg = RemoteHostColorRegistry()
        let hex = reg.colorHex(for: "cmux-srvA")
        #expect(hex != nil)
        #expect(hex == reg.colorHex(for: "cmux-srvA"))
    }
}
