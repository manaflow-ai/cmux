import Foundation

/// Built-in and saved templates, and the `/` completion list. Saved
/// templates live in `UserDefaults` (client state, never synced).
@MainActor
public final class PromptTemplateLibrary {
    public let builtIns: [PromptTemplate]
    private let defaults: UserDefaults
    private let key: String
    public private(set) var saved: [PromptTemplate]

    public init(builtIns: [PromptTemplate], defaults: UserDefaults = .standard, key: String = "cmux.composer.templates.v1") {
        self.builtIns = builtIns
        self.defaults = defaults
        self.key = key
        saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([PromptTemplate].self, from: $0) } ?? []
    }

    public var all: [PromptTemplate] { saved + builtIns }

    public func template(_ id: String?) -> PromptTemplate? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Prefix matches on name first, then substring matches on name or title.
    public func matching(_ query: String, limit: Int = 8) -> [PromptTemplate] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return Array(all.prefix(limit)) }
        let prefix = all.filter { $0.name.hasPrefix(needle) }
        let rest = all.filter { !$0.name.hasPrefix(needle) && ($0.name.contains(needle) || $0.title.lowercased().contains(needle)) }
        return Array((prefix + rest).prefix(limit))
    }

    /// Saves a template from the current prompt; a saved one with the same
    /// name is replaced.
    @discardableResult
    public func save(name: String, title: String? = nil, body: String) -> PromptTemplate? {
        let slug = PromptTemplate.slug(name)
        guard !slug.isEmpty, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let template = PromptTemplate(id: saved.first { $0.name == slug }?.id ?? UUID().uuidString.lowercased(),
                                      name: slug, title: title ?? name, body: body)
        saved.removeAll { $0.name == slug }
        saved.insert(template, at: 0)
        persist()
        return template
    }

    public func delete(_ id: String) {
        guard saved.contains(where: { $0.id == id }) else { return }
        saved.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }
}
