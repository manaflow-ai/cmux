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
    var visitedNodeTypes: [String] {
        retainedNodes.map { String(describing: type(of: $0)) }
    }

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
            let attributes: [(NSAccessibility.Attribute, String)] = [
                (.value, "accessibilityValue"),
                (.description, "accessibilityLabel"),
                (.title, "accessibilityTitle"),
            ]
            for (attribute, getter) in attributes {
                if let text = Self.attribute(attribute, getter: getter, of: object) as? String {
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
        guard let object = object as? NSObject else { return [] }
        let rawChildren = attribute(.children, getter: "accessibilityChildren", of: object) as? [Any]
        return rawChildren.map { NSAccessibility.unignoredChildren(from: $0) } ?? []
    }

    /// SwiftUI and AppKit can expose proxy nodes through either accessibility
    /// API. Read children and text through the same bridge, regardless of the
    /// node's concrete class, and query only advertised legacy attributes.
    private static func attribute(
        _ attribute: NSAccessibility.Attribute,
        getter: String,
        of object: NSObject
    ) -> Any? {
        let modern = NSSelectorFromString(getter)
        if object.responds(to: modern),
           let value = object.perform(modern)?.takeUnretainedValue() {
            return value
        }
        let names = NSSelectorFromString("accessibilityAttributeNames")
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: names), object.responds(to: legacy),
              let attributes = object.perform(names)?.takeUnretainedValue() as? [String],
              attributes.contains(attribute.rawValue) else { return nil }
        return object.perform(legacy, with: attribute.rawValue)?.takeUnretainedValue()
    }
}
