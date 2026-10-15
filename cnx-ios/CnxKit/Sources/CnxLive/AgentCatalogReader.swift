import CmuxAgentBrands
import CnxAgentChat
import CnxModel
import Foundation

extension AgentCatalog {
    /// The catalog from acpmux's `_acpmux/harnesses` reply (`harnesses` keyed by id, `defaultHarness`)
    /// and, when the Mac answered it, `_acpmux/models` (`harnesses: [{harness, models}]`).
    ///
    /// As the Mac's New Agent Chat: terminal harnesses (they run in a terminal tab) are not chat agents;
    /// a launcher that can't run (`unavailable`) is Unavailable with its reason, a failed probe alone is
    /// not. A phone also never starts the families acpmux refuses to a remote connection.
    public init(harnesses reply: JSONValue, models: JSONValue? = nil) {
        guard case .object(let entries)? = reply["harnesses"] else {
            self.init(harnesses: [])
            return
        }
        let defaultID = reply["defaultHarness"]?.stringValue
        var modelLists: [String: [AgentModelChoice]] = [:]
        for row in models?["harnesses"]?.arrayValue ?? [] {
            guard let id = row["harness"]?.stringValue else { continue }
            modelLists[id] = (row["models"]?.arrayValue ?? []).compactMap { model in
                guard let modelID = model["id"]?.stringValue, !modelID.isEmpty else { return nil }
                let name = model["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? modelID
                return AgentModelChoice(id: modelID, name: name, unavailableReason: model["unavailable"]?.stringValue)
            }
        }
        var choices: [AgentHarnessChoice] = []
        for (id, entry) in entries {
            if entry["kind"]?.stringValue == "terminal" { continue }
            let family = entry["family"]?.stringValue ?? id
            let reason: String? = if Self.refusedFamilies.contains(family) {
                Self.refusedReason
            } else {
                Self.launcherReason(entry["unavailable"])
            }
            let start = entry["start"]?["model"]?.stringValue ?? entry["model"]?.stringValue
            choices.append(AgentHarnessChoice(
                id: id, name: Self.displayName(id: id, family: family, entry: entry), family: family,
                isDefault: id == defaultID, unavailableReason: reason,
                models: modelLists[id] ?? [], defaultModel: start
            ))
        }
        // The Mac's default first, then by name (the catalog is keyed, so unordered).
        choices.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        self.init(harnesses: choices)
    }

    static func launcherReason(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue { return text.isEmpty ? "Unavailable" : text }
        if let text = value["reason"]?.stringValue ?? value["message"]?.stringValue { return text }
        if case .bool(false) = value { return nil }
        if case .null = value { return nil }
        return "Unavailable"
    }

    /// A profile file's `displayName`, else the brand catalog's name for the id or family,
    /// else the id. A variant profile keeps its id visible (`Claude Code (claude-cr)`).
    static func displayName(id: String, family: String, entry: JSONValue) -> String {
        if let name = entry["displayName"]?.stringValue, !name.isEmpty { return name }
        let names = Dictionary(AgentBrandCatalog.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        if let name = names[id] { return name }
        if let name = names[family] { return "\(name) (\(id))" }
        return id
    }
}
