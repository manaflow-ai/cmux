import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Per-session scroll ownership", .serialized, .timeLimit(.minutes(1)))
struct GhosttyCopyModeScrollbackTests {
    @Test(arguments: [1000, 1002, 1003])
    func copyModeTakesWheelOwnershipFromMouseReporting(mode: Int) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let healthy = try ScrollbackTestTerminal()
            defer { healthy.close() }
            try await healthy.start()
            let affected = try ScrollbackTestTerminal()
            defer { affected.close() }
            try await affected.start()
            try affected.output("\u{1b}[?\(mode)h\u{1b}[?1006h")
            let runtime = try #require(affected.surface.surface)
            #expect(ghostty_surface_mouse_captured(runtime))

            let healthyBottom = try healthy.scrollbar().offset
            let affectedBottom = try affected.scrollbar().offset
            try healthy.wheel()
            try affected.wheel()
            #expect(try healthy.scrollbar().offset < healthyBottom)
            #expect(try affected.scrollbar().offset == affectedBottom)
            #expect(try await healthy.inputBeforeBarrier().isEmpty)
            #expect(try await affected.inputBeforeBarrier().contains("\u{1b}[<64;"))

            #expect(affected.surface.toggleKeyboardCopyMode())
            #expect(affected.view.isKeyboardCopyModeActive)
            try affected.page(up: true)
            #expect(try affected.scrollbar().offset < affectedBottom)
            try affected.page(up: false)
            #expect(try affected.scrollbar().offset == affectedBottom)
            #expect(try await affected.inputBeforeBarrier().isEmpty,
                    "Page Up and Page Down in Copy Mode must stay local")

            for precise in [false, true] {
                let before = try affected.scrollbar().offset
                try affected.selectCopyModeLine()
                try affected.wheel(precise: precise)
                #expect(try affected.scrollbar().offset < before,
                        "Copy Mode must let this session reach its existing history")
                #expect(ghostty_surface_has_selection(runtime), "Wheel navigation must retain the copy selection")
                #expect(try await affected.inputBeforeBarrier().isEmpty,
                        "Copy Mode scrolling must not send wheel reports to the running program")
                try affected.wheel(up: false, precise: precise)
                #expect(try await affected.inputBeforeBarrier().isEmpty)
            }

            #expect(ghostty_surface_mouse_captured(runtime), "The application's DEC modes must survive Copy Mode")
            #expect(affected.surface.toggleKeyboardCopyMode())
            #expect(!affected.view.isKeyboardCopyModeActive)
            try affected.wheel()
            #expect(try await affected.inputBeforeBarrier().contains("\u{1b}[<64;"),
                    "Leaving Copy Mode must restore the application's mouse ownership")
        }
    }

    @Test func alternateScreenKeepsItsModesAndPrimaryHistory() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let terminal = try ScrollbackTestTerminal()
            defer { terminal.close() }
            try await terminal.start()
            let primary = try terminal.scrollbar()
            try terminal.output("\u{1b}[?1049h\u{1b}[?1007hAlternate screen")
            let alternate = try terminal.scrollbar()
            #expect(alternate.total == alternate.len)
            #expect(terminal.surface.toggleKeyboardCopyMode())
            #expect(terminal.view.isKeyboardCopyModeActive)
            try terminal.wheel()
            try terminal.page(up: true)
            try terminal.page(up: false)
            #expect(try await terminal.inputBeforeBarrier().isEmpty,
                    "Copy Mode must not turn a wheel gesture into application cursor keys")
            #expect(try terminal.scrollbar().total == alternate.total)
            #expect(terminal.surface.toggleKeyboardCopyMode())
            try terminal.wheel()
            #expect(try await terminal.inputBeforeBarrier().contains("\u{1b}[A"))
            try terminal.output("\u{1b}[?1049l")
            #expect(try terminal.scrollbar().total == primary.total)
            try terminal.wheel()
            #expect(try terminal.scrollbar().offset < primary.offset)
        }
    }

    @Test func copyModeKeepsWheelOwnershipAcrossScreenSwitch() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let terminal = try ScrollbackTestTerminal()
            defer { terminal.close() }
            try await terminal.start()
            #expect(terminal.surface.toggleKeyboardCopyMode())
            try terminal.output("\u{1b}[?1049h\u{1b}[?1007hAlternate screen")
            let alternate = try terminal.scrollbar()
            #expect(alternate.total == alternate.len)

            // Program output must not return user-owned input to the program
            // before the copy cursor is reconciled by the next rendered frame.
            try terminal.wheel()
            #expect(try await terminal.inputBeforeBarrier().isEmpty)
            #expect(try terminal.scrollbar().offset == alternate.offset)
            #expect(terminal.surface.toggleKeyboardCopyMode())
            try terminal.wheel()
            #expect(try await terminal.inputBeforeBarrier().contains("\u{1b}[A"))
        }
    }
}
