import AppKit
import SwiftUI
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
        let first = RemoteHostColorRegistry.stableHash("cmux-srvA")
        let second = RemoteHostColorRegistry.stableHash("cmux-srvA")
        #expect(first == second)
        #expect(first != RemoteHostColorRegistry.stableHash("cmux-srvB"))
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

    /// The color each slot resolves to, in slot order, read through `colorHex(for:)` with a fresh
    /// registry per host so no probing moves it. This checks the palette the registry really hands out.
    private func paletteInSlotOrder() -> [String] {
        let count = RemoteHostColorRegistry().slotCount
        var bySlot: [Int: String] = [:]
        var i = 0
        while bySlot.count < count, i < 100_000 {
            let name = "slot-probe-\(i)"
            i += 1
            let slot = startSlot(name, count: count)
            guard bySlot[slot] == nil, let hex = RemoteHostColorRegistry().colorHex(for: name) else { continue }
            bySlot[slot] = hex
        }
        return (0 ..< count).compactMap { bySlot[$0] }
    }

    @Test func hostColorsStayDistinguishableOnTheSidebarRail() {
        // The rail draws each color brightened. Two servers read as the same red when the
        // workspace tab palette's Red and Crimson, or Magenta and Rose, came out that way:
        // Magenta and Rose differ by 2.4 in OKLab (x100) on the rail. Every pair here must
        // differ by at least 11, palette neighbors by at least 25 because a host bumped by a
        // collision takes the next slot, and each color must stand out from the grey sidebar.
        let palette = paletteInSlotOrder()
        #expect(palette.count == 16)
        let rails = palette.map { hex -> (String, Self.RGB) in
            let color = WorkspaceTabColorSettings.displayNSColor(hex: hex, colorScheme: .light, forceBright: true)
            #expect(color != nil, "\(hex) does not parse")
            return (hex, color.map(Self.srgb) ?? (0, 0, 0))
        }
        for i in rails.indices {
            for j in rails.indices where j > i {
                let distance = Self.deltaE(rails[i].1, rails[j].1)
                #expect(distance >= 11, "\(rails[i].0) and \(rails[j].0) differ by \(distance) on the rail")
            }
            let next = rails[(i + 1) % rails.count]
            let neighbor = Self.deltaE(rails[i].1, next.1)
            #expect(neighbor >= 25, "neighbors \(rails[i].0) and \(next.0) differ by \(neighbor)")
        }
        // The sidebar material reads as mid grey behind the rail.
        let sidebarGrey: Self.RGB = (169.0 / 255, 169.0 / 255, 169.0 / 255)
        for (hex, rgb) in rails {
            let distance = Self.deltaE(rgb, sidebarGrey)
            #expect(distance >= 15, "\(hex) differs from the grey sidebar by \(distance)")
        }
        for scheme in [ColorScheme.light, .dark] {
            let selection = Self.srgb(cmuxAccentNSColor(for: scheme))
            for (hex, rgb) in rails {
                let distance = Self.deltaE(rgb, selection)
                #expect(distance >= 12, "\(hex) differs from the \(scheme) selection by \(distance)")
            }
        }
    }

    @Test func colorHexIsStablePerHost() {
        // Uses the real built-in palette; a host resolves to a non-nil hex and the
        // same hex every time.
        let reg = RemoteHostColorRegistry()
        let hex = reg.colorHex(for: "cmux-srvA")
        #expect(hex != nil)
        #expect(hex == reg.colorHex(for: "cmux-srvA"))
    }

    // MARK: - Color measurement

    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func srgb(_ color: NSColor) -> RGB {
        let c = color.usingColorSpace(.sRGB) ?? color
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func oklab(_ rgb: RGB) -> (Double, Double, Double) {
        let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    private static func deltaE(_ a: RGB, _ b: RGB) -> Double {
        let x = oklab(a), y = oklab(b)
        let dl = x.0 - y.0, da = x.1 - y.1, db = x.2 - y.2
        return 100 * (dl * dl + da * da + db * db).squareRoot()
    }
}
