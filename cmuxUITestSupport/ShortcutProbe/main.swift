import AppKit

final class ShortcutProbeDelegate: NSObject, NSApplicationDelegate {
    private let statusLabel = NSTextField(labelWithString: "Waiting for Cmd-Option-F")
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = NSView(frame: window.contentLayoutRect)
        statusLabel.setAccessibilityIdentifier("ShortcutProbeStatus")
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 24, weight: .medium)
        statusLabel.frame = NSRect(x: 30, y: 80, width: 460, height: 40)
        contentView.addSubview(statusLabel)
        window.contentView = contentView
        window.title = "Foreground Shortcut Probe"

        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let shortcutItem = NSMenuItem(
            title: "Receive Cmd-Option-F",
            action: #selector(receiveShortcut),
            keyEquivalent: "f"
        )
        shortcutItem.keyEquivalentModifierMask = [.command, .option]
        shortcutItem.target = self
        applicationMenu.addItem(shortcutItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)
        NSApp.mainMenu = mainMenu

        window.center()
        window.makeKeyAndOrderFront(nil)
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    @objc private func receiveShortcut() {
        statusLabel.stringValue = "Received Cmd-Option-F"
        statusLabel.setAccessibilityLabel("Received Cmd-Option-F")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let application = NSApplication.shared
let delegate = ShortcutProbeDelegate()
application.delegate = delegate
_ = application.setActivationPolicy(.regular)
application.run()
