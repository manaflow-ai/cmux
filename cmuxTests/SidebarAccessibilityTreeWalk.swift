import AppKit

/// Bounded traversal of native and legacy AppKit accessibility elements.
@MainActor
struct SidebarAccessibilityTreeWalk {
    var visited = Set<ObjectIdentifier>()
    var active = Set<ObjectIdentifier>()
    var textValues = Set<String>()
    private var retainedNodes: [AnyObject] = []
    var cycle: [String]?
    var maxDepth = 0

    mutating func visit(_ node: Any, depth: Int = 0, path: [String] = []) {
        guard cycle == nil else { return }
        guard depth < 256 else {
            cycle = path + ["<depth-limit>"]
            return
        }
        let object = node as AnyObject
        let identity = ObjectIdentifier(object)
        let name = String(describing: type(of: object))
        guard active.insert(identity).inserted else {
            cycle = path + [name]
            return
        }
        defer { active.remove(identity) }
        guard visited.insert(identity).inserted else { return }
        // Legacy AppKit proxies can be transient; retain every visited object
        // so a later allocation cannot reuse its ObjectIdentifier.
        retainedNodes.append(object)
        if let object = object as? NSObject {
            for name in ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"] {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { continue }
                if let text = object.perform(selector)?.takeUnretainedValue() as? String {
                    textValues.insert(text)
                }
            }
        }
        maxDepth = max(maxDepth, depth)
        for child in Self.children(of: object) {
            visit(child, depth: depth + 1, path: path + [name])
        }
    }

    private static func children(of object: AnyObject) -> [Any] {
        let rawChildren: [Any]?
        if let view = object as? NSView {
            rawChildren = view.accessibilityChildren()
        } else if let element = object as? NSAccessibilityElement {
            rawChildren = element.accessibilityChildren()
        } else if let object = object as? NSObject {
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            rawChildren = object.responds(to: selector)
                ? object.perform(selector, with: NSAccessibility.Attribute.children.rawValue)?
                    .takeUnretainedValue() as? [Any]
                : nil
        } else {
            rawChildren = nil
        }
        return rawChildren.map { NSAccessibility.unignoredChildren(from: $0) } ?? []
    }
}
