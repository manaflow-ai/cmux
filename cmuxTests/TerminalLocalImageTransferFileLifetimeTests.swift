import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalLocalImageTransferFileLifetimeTests {
    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lS2cWQAAAABJRU5ErkJggg=="

    private struct HostedTerminal {
        let surface: TerminalSurface
        let window: NSWindow
        let surfaceView: GhosttyNSView
    }

    @Test(
        "A local image transfer keeps its materialized file after the path reaches the terminal",
        arguments: [TerminalImageTransferMode.drop, TerminalImageTransferMode.paste]
    )
    func localImageTransferKeepsMaterializedFile(mode: TerminalImageTransferMode) throws {
        let hostedTerminal = try makeHostedTerminal()
        defer { hostedTerminal.window.orderOut(nil) }

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("cmux-test-local-image-transfer-\(UUID().uuidString)")
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let item = NSPasteboardItem()
        item.setData(
            try #require(Data(base64Encoded: Self.onePixelPNGBase64)),
            forType: .png
        )
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))

        let prepared = TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: mode
        )
        guard case .fileURLs(let fileURLs) = prepared,
              let imageURL = fileURLs.first else {
            Issue.record("expected a materialized image file, got \(prepared)")
            return
        }
        defer {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
        }
        #expect(GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile(imageURL))
        #expect(hostedTerminal.surfaceView.resolvedImageTransferTarget(mode: mode) == .local)

        #expect(
            hostedTerminal.surfaceView.executePreparedImageTransfer(
                prepared,
                mode: mode,
                onCancel: {}
            )
        )

        #expect(
            FileManager.default.fileExists(atPath: imageURL.path),
            "The inserted path must still resolve when the terminal program reads it"
        )
        #expect(GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile(imageURL))
    }

    @Test(
        "Copied image pixels take precedence over an auxiliary URL",
        arguments: ["folder", "web", "missing-image"]
    )
    func imagePixelsTakePrecedenceOverURL(urlKind: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-image-priority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TerminalPasteboardService(temporaryDirectory: directory)
        let pasteboard = NSPasteboard(name: .init("cmux-image-priority-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let png = try #require(Data(base64Encoded: Self.onePixelPNGBase64))
        let item = NSPasteboardItem()
        #expect(item.setData(png, forType: .png))
        let auxiliaryURL: URL
        if urlKind == "web" {
            auxiliaryURL = try #require(URL(string: "https://example.com/copied-image"))
            #expect(item.setString(auxiliaryURL.absoluteString, forType: .URL))
        } else {
            auxiliaryURL = urlKind == "folder"
                ? directory
                : directory.appendingPathComponent("missing.png")
            #expect(item.setString(auxiliaryURL.absoluteString, forType: .fileURL))
        }
        #expect(pasteboard.writeObjects([item]))

        let prepared = TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: .paste,
            pasteboardService: service
        )
        guard case .fileURLs(let urls) = prepared else {
            Issue.record("Expected an image attachment, got \(prepared)")
            return
        }
        let imageURL = try #require(urls.first)
        #expect(urls.count == 1)
        #expect(imageURL != auxiliaryURL)
        #expect(imageURL.pathExtension == "png")
        #expect(service.isOwnedTemporaryImageFile(imageURL))
        #expect(try Data(contentsOf: imageURL) == png)
    }

    @Test("Finder file and folder pastes preserve their URL identity", arguments: [false, true])
    func fileOnlyPasteKeepsURLs(isDirectory: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-priority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = isDirectory ? directory : directory.appendingPathComponent("image.png")
        if !isDirectory {
            try #require(Data(base64Encoded: Self.onePixelPNGBase64)).write(to: source)
        }
        let pasteboard = NSPasteboard(name: .init("cmux-file-priority-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([source as NSURL]))
        let service = TerminalPasteboardService(temporaryDirectory: directory)
        #expect(TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: .paste,
            pasteboardService: service
        ) == .fileURLs([source.standardizedFileURL]))
    }

    private func makeHostedTerminal() throws -> HostedTerminal {
        _ = NSApplication.shared
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        return HostedTerminal(
            surface: surface,
            window: window,
            surfaceView: hostedView.surfaceView
        )
    }
}
