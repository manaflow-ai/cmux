import AppKit
import SwiftUI

struct FilesFixture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Project fixture")
            HStack {
                Text("Files")
                Text("Targets")
                Text("Build Settings")
            }
            Divider()
            HStack {
                TextField("Filter files", text: .constant(""))
                Text("2")
            }
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Group")
                    Text("Context.swift")
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
func modern(_ object: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
}

@MainActor
func legacy(_ object: NSObject, _ attribute: String) -> Any? {
    let selector = NSSelectorFromString("accessibilityAttributeValue:")
    guard let names = modern(object, "accessibilityAttributeNames") as? [String],
          names.contains(attribute), object.responds(to: selector) else { return nil }
    return object.perform(selector, with: attribute)?.takeUnretainedValue()
}

@MainActor
func dumpTree(_ root: NSObject, includeContents: Bool) {
    var retained: [NSObject] = []
    var visited = Set<ObjectIdentifier>()
    func visit(_ node: NSObject, depth: Int) {
        guard depth < 20, visited.count < 200, visited.insert(ObjectIdentifier(node)).inserted else { return }
        retained.append(node)
        let children = modern(node, "accessibilityChildren") as? [Any]
        let oldChildren = legacy(node, "AXChildren") as? [Any]
        let contents = modern(node, "accessibilityContents") as? [Any]
        let oldContents = legacy(node, "AXContents") as? [Any]
        let text = modern(node, "accessibilityValue") ?? legacy(node, "AXValue")
            ?? modern(node, "accessibilityLabel") ?? legacy(node, "AXDescription")
        print("NODE depth=\(depth) type=\(type(of: node)) text=\(String(describing: text)) children=\(children?.count ?? -1) legacyChildren=\(oldChildren?.count ?? -1) contents=\(contents?.count ?? -1) legacyContents=\(oldContents?.count ?? -1)")
        if let view = node as? NSView {
            print("VIEW type=\(type(of: view)) frame=\(view.frame) visible=\(view.visibleRect) subviews=\(view.subviews.map { String(describing: type(of: $0)) })")
        }
        if let scroll = node as? NSScrollView {
            print("SCROLL viewport=\(scroll.contentView.bounds) documentFrame=\(String(describing: scroll.documentView?.frame)) documentType=\(String(describing: scroll.documentView.map { String(describing: type(of: $0)) }))")
        }
        let extra = includeContents ? (contents ?? oldContents ?? []) : []
        for child in NSAccessibility.unignoredChildren(from: (children ?? oldChildren ?? []) + extra) {
            if let child = child as? NSObject { visit(child, depth: depth + 1) }
        }
    }
    visit(root, depth: 0)
    print("TOTAL includeContents=\(includeContents) count=\(retained.count)")
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.finishLaunching()
let host = NSHostingView(rootView: FilesFixture().environment(\.accessibilityEnabled, true))
let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 300))
host.frame = NSRect(x: 360, y: 0, width: 460, height: 300)
root.addSubview(host)
let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView = root
window.orderFront(nil)
Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
    MainActor.assumeIsolated {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        print("PASSIVE active=\(app.isActive) visible=\(window.isVisible)")
        dumpTree(host, includeContents: false)
        dumpTree(host, includeContents: true)
        app.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                print("ACTIVE active=\(app.isActive) visible=\(window.isVisible)")
                dumpTree(host, includeContents: true)
                window.close()
                app.terminate(nil)
            }
        }
    }
}
app.run()
