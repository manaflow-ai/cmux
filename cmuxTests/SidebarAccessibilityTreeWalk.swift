import AppKit

/// Bounded traversal of native and legacy AppKit accessibility elements.
@MainActor
struct SidebarAccessibilityTreeWalk {
    var visited = Set<ObjectIdentifier>()
    var active = Set<ObjectIdentifier>()
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
