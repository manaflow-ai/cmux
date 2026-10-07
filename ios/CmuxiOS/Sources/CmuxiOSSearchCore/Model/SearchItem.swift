/// One searchable thing: a value projection of an owner's mirror (or a
/// catalog entry), with its text prepared for matching.
public struct SearchItem: Identifiable, Hashable, Sendable {
    /// Stable across snapshots (`ws:<host>/<id>`, `feed:<id>`, ...), so the
    /// list diffs by it.
    public var id: String
    public var category: SearchCategory
    public var title: String
    public var subtitle: String?
    public var symbolName: String
    public var destination: SearchDestination
    public var fields: [SearchField]
    /// Added to the match score (needs input, unread).
    public var boost: Int
    /// A short status ("Needs input", "Running").
    public var badge: String?
    /// The owner is unreachable; the row shows dimmed but still opens.
    public var isDimmed: Bool

    public init(
        id: String, category: SearchCategory, title: String, subtitle: String? = nil, symbolName: String,
        destination: SearchDestination, keywords: [String] = [], details: [SearchField] = [],
        boost: Int = 0, badge: String? = nil, isDimmed: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.destination = destination
        var fields = [SearchField(SearchText(title), weight: SearchField.titleWeight, role: .title)]
        if let subtitle, !subtitle.isEmpty {
            fields.append(SearchField(SearchText(subtitle, limit: SearchField.longTextLimit),
                                      weight: SearchField.subtitleWeight, fuzzy: false, role: .subtitle))
        }
        for keyword in keywords where !keyword.isEmpty {
            fields.append(SearchField(SearchText(keyword), weight: SearchField.keywordWeight))
        }
        fields.append(contentsOf: details)
        self.fields = fields
        self.boost = boost
        self.badge = badge
        self.isDimmed = isDimmed
    }
}
