import CmuxTerminalCore
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Agent key hint physical keyboard store")
struct AgentKeyHintPhysicalKeyboardStoreTests {
    nonisolated private static let builtIn = KeyboardDevice(name: "Built-in", vendorID: 0, productID: 0, isBuiltIn: true)

    /// A reader serving a fixed setup whose Caps Lock and Control are
    /// swapped, and a `karabiner.json` stamp the test can change.
    private final class FixtureReader: AgentKeyHintPhysicalKeyboardReading {
        private struct State {
            var stamp = AgentKeyHintFileStamp(modificationDate: Date(timeIntervalSince1970: 1), size: 1)
            var reads = 0
            var userKeyMapping: HIDKeyMapping? = .identity
        }

        // Read on the store's background task and written by the test on
        // the main actor; a short lock keeps them consistent.
        private let state = OSAllocatedUnfairLock(initialState: State())

        var reads: Int { state.withLock(\.reads) }

        func touchKarabinerFile() {
            state.withLock { $0.stamp.size = ($0.stamp.size ?? 0) + 1 }
        }

        func setUserKeyMapping(_ mapping: HIDKeyMapping?) {
            state.withLock { $0.userKeyMapping = mapping }
        }

        func karabinerStamp() -> AgentKeyHintFileStamp {
            state.withLock(\.stamp)
        }

        func read() -> (setup: PhysicalKeyboardSetup, karabinerStamp: AgentKeyHintFileStamp) {
            let (stamp, mapping) = state.withLock { state -> (AgentKeyHintFileStamp, HIDKeyMapping?) in
                state.reads += 1
                return (state.stamp, state.userKeyMapping)
            }
            let setup = PhysicalKeyboardSetup(
                connectedKeyboards: [AgentKeyHintPhysicalKeyboardStoreTests.builtIn],
                karabiner: nil,
                userKeyMapping: mapping,
                modifierKeys: SystemModifierKeyMappings(mappings: [
                    .init(vendorID: 0, productID: 0): HIDKeyMapping(destinations: [
                        .capsLock: .leftControl, .leftControl: .capsLock,
                    ]),
                ]),
                application: KarabinerFrontmostApplication(bundleIdentifier: nil, executablePath: nil)
            )
            return (setup, stamp)
        }
    }

    private final class Clock {
        var time: TimeInterval = 1000
    }

    private func settle(_ store: AgentKeyHintPhysicalKeyboardStore) async {
        await store.readTask?.value
    }

    @Test
    func firstAskReadsInTheBackgroundThenAdvises() async {
        let reader = FixtureReader()
        let clock = Clock()
        let store = AgentKeyHintPhysicalKeyboardStore(reader: reader, now: { clock.time })
        #expect(store.advice(forAgentKeys: ["ctrl+o"]).isEmpty)
        await settle(store)
        #expect(reader.reads == 1)
        #expect(store.advice(forAgentKeys: ["ctrl+o"]).first?.chords.map(\.glyphs) == ["⇪O"])
    }

    @Test
    func karabinerChangeTriggersAReadAfterTheCheckInterval() async {
        let reader = FixtureReader()
        let clock = Clock()
        let store = AgentKeyHintPhysicalKeyboardStore(reader: reader, now: { clock.time })
        _ = store.advice(forAgentKeys: ["ctrl+o"])
        await settle(store)

        reader.touchKarabinerFile()
        clock.time += AgentKeyHintPhysicalKeyboardStore.karabinerCheckInterval / 2
        _ = store.advice(forAgentKeys: ["ctrl+o"])
        await settle(store)
        #expect(reader.reads == 1)

        clock.time += AgentKeyHintPhysicalKeyboardStore.karabinerCheckInterval
        _ = store.advice(forAgentKeys: ["ctrl+o"])
        await settle(store)
        #expect(reader.reads == 2)
    }

    @Test
    func otherSourcesAreReadAtMostOnceAMinute() async {
        let reader = FixtureReader()
        let clock = Clock()
        let store = AgentKeyHintPhysicalKeyboardStore(reader: reader, now: { clock.time })
        _ = store.advice(forAgentKeys: ["ctrl+o"])
        await settle(store)

        for _ in 0..<5 {
            clock.time += AgentKeyHintPhysicalKeyboardStore.karabinerCheckInterval + 1
            _ = store.advice(forAgentKeys: ["ctrl+o"])
            await settle(store)
        }
        #expect(reader.reads == 1)

        clock.time += AgentKeyHintPhysicalKeyboardStore.rereadInterval
        _ = store.advice(forAgentKeys: ["ctrl+o"])
        await settle(store)
        #expect(reader.reads == 2)
    }

    @Test
    func hidutilTimeoutLeavesThePrintedKeys() async {
        let reader = FixtureReader()
        reader.setUserKeyMapping(nil)
        let clock = Clock()
        let store = AgentKeyHintPhysicalKeyboardStore(reader: reader, now: { clock.time })
        _ = store.advice(forAgentKeys: ["ctrl+o"])
        await settle(store)
        #expect(reader.reads == 1)
        #expect(store.advice(forAgentKeys: ["ctrl+o"]).isEmpty)
    }

    @Test
    func aHungCommandIsStoppedAndReadsAsUnknown() {
        let start = ProcessInfo.processInfo.systemUptime
        let output = AgentKeyHintPhysicalKeyboardReader.runForOutput(
            URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            timeout: 0.2
        )
        #expect(output == nil)
        #expect(ProcessInfo.processInfo.systemUptime - start < 5)

        #expect(AgentKeyHintPhysicalKeyboardReader.runForOutput(
            URL(fileURLWithPath: "/bin/echo"),
            arguments: ["(null)"],
            timeout: 2
        ) == "(null)\n")
        #expect(AgentKeyHintPhysicalKeyboardReader.runForOutput(
            URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            timeout: 2
        ) == nil)
    }
}
