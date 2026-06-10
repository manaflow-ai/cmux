import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG


@MainActor
final class FilePreviewPanelTextSavingTests: XCTestCase {
    func testNativePreviewSessionsDetachAndManageViewsAcrossRecreation() throws {
        let url = try temporaryTextFile(contents: "preview", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        let sessions = panel.nativeViewSessions

        let pdfView = sessions.pdf.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        let imageView = sessions.image.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        let mediaView = sessions.media.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        let quickLookView = sessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )

        let host = NSView()
        host.addSubview(pdfView)
        host.addSubview(imageView)
        host.addSubview(mediaView)
        host.addSubview(quickLookView)

        XCTAssertTrue(pdfView === sessions.pdf.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        ))
        XCTAssertNil(pdfView.superview)

        XCTAssertTrue(imageView === sessions.image.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        ))
        XCTAssertNil(imageView.superview)

        XCTAssertTrue(mediaView === sessions.media.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        ))
        XCTAssertNil(mediaView.superview)

        let remountedQuickLookView = sessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        XCTAssertFalse(quickLookView === remountedQuickLookView)
        XCTAssertTrue(quickLookView.superview === host)
        sessions.quickLook.dismantle(quickLookView)
        XCTAssertNil(quickLookView.superview)
    }

    func testSaveTextContentWritesLiveTextViewContent() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        let textView = NSTextView()
        textView.string = "edited from text view"
        panel.attachTextView(textView)

        let task = try XCTUnwrap(panel.saveTextContent())
        XCTAssertTrue(panel.isSaving)
        await task.value

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "edited from text view")
        XCTAssertEqual(panel.textContent, "edited from text view")
        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isSaving)
    }

    func testSaveTextContentIgnoresConcurrentSaveRequest() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("first save")

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)

        let firstSave = try XCTUnwrap(panel.saveTextContent())
        XCTAssertTrue(panel.isSaving)

        panel.updateTextContent("second save")
        XCTAssertNil(panel.saveTextContent())

        let pipeRead = Task.detached { () throws -> String in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return String(data: handle.availableData, encoding: .utf8) ?? ""
        }

        let savedContent = try await pipeRead.value
        XCTAssertEqual(savedContent, "first save")
        await firstSave.value

        XCTAssertEqual(panel.textContent, "second save")
        XCTAssertTrue(panel.isDirty)
        XCTAssertFalse(panel.isSaving)
    }

    func testCleanSaveDoesNotCancelPendingTextLoad() async throws {
        let url = try temporaryTextFile(contents: "", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        try "loaded after clean save".write(to: url, atomically: true, encoding: .utf8)

        let loadTask = panel.loadTextContent()
        XCTAssertNil(panel.saveTextContent())
        await loadTask.value

        XCTAssertEqual(panel.textContent, "loaded after clean save")
        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isFileUnavailable)
    }

    func testSavingTextViewUsesConfiguredSaveShortcut() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "u", command: true, shift: false, option: true, control: false),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "saved by configured shortcut"
        textView.panel = panel
        panel.attachTextView(textView)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "u",
            charactersIgnoringModifiers: "u",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_U)
        ))

        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        await waitForPanelSave(panel)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved by configured shortcut")
    }

    func testSavingTextViewDoesNotUseDefaultSaveShortcutAfterRemap() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "u", command: true, shift: false, option: true, control: false),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "should not save through command s"
        textView.panel = panel
        panel.attachTextView(textView)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_S)
        ))

        XCTAssertFalse(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testSaveTextContentPreservesLoadedEncoding() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited")
        if let task = panel.saveTextContent() {
            await task.value
        }

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf16), "edited")
        XCTAssertFalse(panel.isDirty)
    }

    func testSaveTextContentWritesThroughSymlink() async throws {
        let targetURL = try temporaryTextFile(contents: "original", encoding: .utf8)
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: linkURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited through link")
        if let task = panel.saveTextContent() {
            await task.value
        }

        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "edited through link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), targetURL.path)
        XCTAssertFalse(panel.isDirty)
    }

    func testCleanSaveDoesNotWriteReadOnlyTextFile() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        if let task = panel.saveTextContent() {
            await task.value
        }

        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isFileUnavailable)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testLoadTextContentClearsDirtyStateWhenFileVanishes() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited")
        try FileManager.default.removeItem(at: url)

        await panel.loadTextContent().value

        XCTAssertEqual(panel.textContent, "")
        XCTAssertFalse(panel.isDirty)
        XCTAssertTrue(panel.isFileUnavailable)
    }

    func testTextEditorInsetsReapplyWhenMovedBetweenWindows() {
        _ = NSApplication.shared
        let textView = SavingTextView()
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5

        let firstWindow = windowHosting(textView)
        defer { closeWindow(firstWindow) }
        XCTAssertEqual(textView.textContainerInset.width, FilePreviewTextEditorLayout.textContainerInset.width)
        XCTAssertEqual(textView.textContainerInset.height, FilePreviewTextEditorLayout.textContainerInset.height)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, FilePreviewTextEditorLayout.lineFragmentPadding)

        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5

        let secondWindow = windowHosting(textView)
        defer { closeWindow(secondWindow) }
        XCTAssertEqual(textView.textContainerInset.width, FilePreviewTextEditorLayout.textContainerInset.width)
        XCTAssertEqual(textView.textContainerInset.height, FilePreviewTextEditorLayout.textContainerInset.height)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, FilePreviewTextEditorLayout.lineFragmentPadding)

        withExtendedLifetime([firstWindow, secondWindow]) {}
    }

    func testTextEditorClearThemeDoesNotDrawAppKitBackgrounds() {
        _ = NSApplication.shared
        let scrollView = NSScrollView()
        let textView = SavingTextView()
        scrollView.documentView = textView

        FilePreviewTextEditor<FilePreviewPanel>.applyTheme(
            to: scrollView,
            backgroundColor: .clear,
            foregroundColor: .white,
            drawsBackground: false
        )

        XCTAssertFalse(scrollView.drawsBackground)
        XCTAssertFalse(scrollView.contentView.drawsBackground)
        XCTAssertFalse(textView.drawsBackground)
        XCTAssertEqual(scrollView.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(scrollView.contentView.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(textView.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(textView.textColor, .white)
        XCTAssertEqual(textView.insertionPointColor, .white)
    }

    func testTextEditorOpaqueThemeDrawsAppKitBackgrounds() {
        _ = NSApplication.shared
        let scrollView = NSScrollView()
        let textView = SavingTextView()
        let backgroundColor = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1)
        scrollView.documentView = textView

        FilePreviewTextEditor<FilePreviewPanel>.applyTheme(
            to: scrollView,
            backgroundColor: backgroundColor,
            foregroundColor: .white,
            drawsBackground: true
        )

        XCTAssertTrue(scrollView.drawsBackground)
        XCTAssertTrue(scrollView.contentView.drawsBackground)
        XCTAssertTrue(textView.drawsBackground)
        XCTAssertEqual(scrollView.backgroundColor, backgroundColor)
        XCTAssertEqual(scrollView.contentView.backgroundColor, backgroundColor)
        XCTAssertEqual(textView.backgroundColor, backgroundColor)
        XCTAssertEqual(scrollView.backgroundColor.alphaComponent, 1)
        XCTAssertEqual(scrollView.contentView.backgroundColor.alphaComponent, 1)
        XCTAssertEqual(textView.backgroundColor.alphaComponent, 1)
    }

    func testPendingTextFocusAppliesWhenTextViewAttaches() throws {
        _ = NSApplication.shared
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        panel.focus()

        let textView = SavingTextView()
        let window = windowHosting(textView)
        defer { closeWindow(window) }
        panel.attachTextView(textView)

        XCTAssertTrue(window.firstResponder === textView)
        withExtendedLifetime(window) {}
    }

    func testPDFExtensionWinsOverLooseTextSniff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8).write(to: url)

        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .pdf)
        XCTAssertEqual(FilePreviewKindResolver.tabIconName(for: url), "doc.richtext")
    }

    func testUTF16TextWithBOMStillResolvesAsText() throws {
        let url = try temporaryTextFile(contents: "hello", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
        XCTAssertEqual(FilePreviewKindResolver.tabIconName(for: url), "doc.text")
    }

    func testExtensionlessTextFileResolvesToTextAfterFastInitialClassification() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try "extensionless text".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await waitForPanelPreviewMode(panel, .text)
        await waitForPanelTextContent(panel, "extensionless text")

        XCTAssertEqual(panel.displayIcon, "doc.text")
    }

    func testBinaryPlistDoesNotOpenAsEditableText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("bplist00".utf8).write(to: url)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertNotEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    func testExternalOpenApplicationResolverOrdersDefaultAppFirstAndDeduplicates() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.mov")
        let quickTimeURL = URL(fileURLWithPath: "/Applications/QuickTime Player.app")
        let vlcURL = URL(fileURLWithPath: "/Applications/VLC.app")
        let names = [
            quickTimeURL.path: "QuickTime Player",
            vlcURL.path: "VLC",
        ]
        let resolver = FileExternalOpenApplicationResolver(
            defaultApplicationURL: { _ in quickTimeURL },
            applicationURLs: { _ in [vlcURL, quickTimeURL, vlcURL] },
            displayName: { names[$0.path] ?? $0.lastPathComponent },
            shouldIncludeApplication: { _ in true }
        )

        let applications = resolver.applications(for: fileURL)

        XCTAssertEqual(applications.map(\.displayName), ["QuickTime Player", "VLC"])
        XCTAssertEqual(applications.map(\.isDefault), [true, false])
    }

    func testExternalOpenApplicationResolverFallsBackWhenDefaultAppIsFiltered() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.pdf")
        let cmuxURL = URL(fileURLWithPath: "/Applications/cmux.app")
        let previewURL = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let resolver = FileExternalOpenApplicationResolver(
            defaultApplicationURL: { _ in cmuxURL },
            applicationURLs: { _ in [cmuxURL, previewURL] },
            displayName: { $0.deletingPathExtension().lastPathComponent },
            shouldIncludeApplication: { $0 != cmuxURL }
        )

        let applications = resolver.applications(for: fileURL)

        XCTAssertEqual(applications.map(\.displayName), ["Preview"])
        XCTAssertEqual(applications.map(\.isDefault), [false])
    }

    func testExternalOpenMenuKeepsFinderTopLevelAndOpenWithItemsSearchableByAppName() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.png")
        let previewURL = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let pixelmatorURL = URL(fileURLWithPath: "/Applications/Pixelmator Pro.app")
        let primaryApplication = FileExternalOpenApplication(
            url: previewURL,
            displayName: "Preview",
            isDefault: true
        )
        let otherApplication = FileExternalOpenApplication(
            url: pixelmatorURL,
            displayName: "Pixelmator Pro",
            isDefault: false
        )

        let menu = FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: primaryApplication,
            otherApplications: [otherApplication]
        )

        let topLevelTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(topLevelTitles, [
            FileExternalOpenText.openInApplication("Preview"),
            FileExternalOpenText.revealInFinder,
            FileExternalOpenText.openWithMenu,
        ])

        let openWithItem = try XCTUnwrap(menu.items.first { $0.title == FileExternalOpenText.openWithMenu })
        let openWithTitles = try XCTUnwrap(openWithItem.submenu?.items.map(\.title))
        XCTAssertEqual(openWithTitles, ["Pixelmator Pro"])
    }

    func testExternalOpenMenuKeepsFinderTopLevelWithoutResolvedApplications() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.bin")

        let menu = FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: nil,
            otherApplications: []
        )

        let topLevelTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(topLevelTitles, [
            FileExternalOpenText.openExternally,
            FileExternalOpenText.revealInFinder,
        ])
    }

    func testCmdClickSupportedFileRoutingDefaultsToReadableRegularFilesOnly() throws {
        let suiteName = "cmux.file-preview-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile(contents: "preview me", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        XCTAssertTrue(CmdClickSupportedFileRouteSettings.isEnabled(defaults: defaults))
        XCTAssertTrue(CmdClickSupportedFileRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
        XCTAssertFalse(CmdClickSupportedFileRouteSettings.shouldRoute(path: directoryURL.path, defaults: defaults))

        defaults.set(false, forKey: CmdClickSupportedFileRouteSettings.key)
        XCTAssertFalse(CmdClickSupportedFileRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
    }

    func testCmdClickMarkdownRoutingDoesNotRequireSupportedFileRoutingSetting() throws {
        let suiteName = "cmux.markdown-preview-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile(contents: "# preview me", encoding: .utf8, pathExtension: "md")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        defaults.set(true, forKey: CmdClickMarkdownRouteSettings.key)
        defaults.set(false, forKey: CmdClickSupportedFileRouteSettings.key)

        XCTAssertTrue(CmdClickMarkdownRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
        XCTAssertFalse(CmdClickSupportedFileRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
    }

    func testCmdClickMarkdownRoutingDefaultsToReadableMarkdownFiles() throws {
        let suiteName = "cmux.markdown-preview-default-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile(contents: "# preview me", encoding: .utf8, pathExtension: "md")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(CmdClickMarkdownRouteSettings.isEnabled(defaults: defaults))
        XCTAssertTrue(CmdClickMarkdownRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
    }

    func testCmdClickFilePreviewRoutingReusesRightSidePane() throws {
        let sourceURL = try temporaryTextFile(contents: "source", encoding: .utf8)
        let firstURL = try temporaryTextFile(contents: "first", encoding: .utf8)
        let secondURL = try temporaryTextFile(contents: "second", encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        let sourcePane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sourcePanel = try XCTUnwrap(workspace.newFilePreviewSurface(
            inPane: sourcePane,
            filePath: sourceURL.path,
            focus: true
        ))

        let firstPanel = try XCTUnwrap(workspace.openOrFocusFilePreviewSplit(
            from: sourcePanel.id,
            filePath: firstURL.path
        ))
        let rightPane = try XCTUnwrap(workspace.paneId(forPanelId: firstPanel.id))
        let paneCountAfterFirstOpen = workspace.bonsplitController.allPaneIds.count
        let rightTabsAfterFirstOpen = workspace.bonsplitController.tabs(inPane: rightPane).count

        let secondPanel = try XCTUnwrap(workspace.openOrFocusFilePreviewSplit(
            from: sourcePanel.id,
            filePath: secondURL.path
        ))

        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, paneCountAfterFirstOpen)
        XCTAssertEqual(workspace.paneId(forPanelId: secondPanel.id)?.id, rightPane.id)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: rightPane).count, rightTabsAfterFirstOpen + 1)
    }

    func testCmdClickMarkdownRoutingReusesRightSidePane() throws {
        let sourceURL = try temporaryTextFile(contents: "source", encoding: .utf8)
        let firstURL = try temporaryTextFile(contents: "# first", encoding: .utf8, pathExtension: "md")
        let secondURL = try temporaryTextFile(contents: "# second", encoding: .utf8, pathExtension: "md")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        let sourcePane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sourcePanel = try XCTUnwrap(workspace.newFilePreviewSurface(
            inPane: sourcePane,
            filePath: sourceURL.path,
            focus: true
        ))

        let firstPanel = try XCTUnwrap(workspace.openOrFocusMarkdownSplit(
            from: sourcePanel.id,
            filePath: firstURL.path
        ))
        let rightPane = try XCTUnwrap(workspace.paneId(forPanelId: firstPanel.id))
        let paneCountAfterFirstOpen = workspace.bonsplitController.allPaneIds.count
        let rightTabsAfterFirstOpen = workspace.bonsplitController.tabs(inPane: rightPane).count

        let secondPanel = try XCTUnwrap(workspace.openOrFocusMarkdownSplit(
            from: sourcePanel.id,
            filePath: secondURL.path
        ))

        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, paneCountAfterFirstOpen)
        XCTAssertEqual(workspace.paneId(forPanelId: secondPanel.id)?.id, rightPane.id)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: rightPane).count, rightTabsAfterFirstOpen + 1)
    }

    private func temporaryTextFile(
        contents: String,
        encoding: String.Encoding,
        pathExtension: String = "txt"
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func waitForPanelSave(
        _ panel: FilePreviewPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if !panel.isSaving {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview save", file: file, line: line)
    }

    private func waitForPanelPreviewMode(
        _ panel: FilePreviewPanel,
        _ mode: FilePreviewMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if panel.previewMode == mode {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview mode", file: file, line: line)
    }

    private func waitForPanelTextContent(
        _ panel: FilePreviewPanel,
        _ content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if panel.textContent == content {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview text content", file: file, line: line)
    }

    private func closeWindow(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func windowHosting(_ textView: NSTextView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)
        scrollView.documentView = textView
        return window
    }
}


#endif
