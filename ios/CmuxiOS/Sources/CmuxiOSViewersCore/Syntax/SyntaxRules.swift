/// The lexical rules of one language family.
public struct SyntaxRules: Sendable {
    public var lineComments: [String]
    public var blockComment: (open: String, close: String)?
    /// Single-line string quotes.
    public var quotes: [Character]
    /// Delimiters of strings that may span lines (`"""`, `'''`, backtick).
    public var multilineStrings: [String]
    public var keywords: Set<String>
    public var keywordsIgnoreCase: Bool
    /// Capitalized identifiers are types.
    public var capitalizedTypes: Bool
    /// `key:` / `"key":` / `key =` are attributes.
    public var keyedValues: Bool
    /// Characters that may start an identifier besides letters and `_`.
    public var identifierStarts: Set<Character>
    /// A line comment marker counts only at the start or after whitespace (`#` in shell).
    public var commentNeedsSpace: Bool
    public var markup: Bool
    public var markdown: Bool

    public init(lineComments: [String] = [], blockComment: (open: String, close: String)? = nil, quotes: [Character] = ["\""],
                multilineStrings: [String] = [], keywords: Set<String> = [], keywordsIgnoreCase: Bool = false,
                capitalizedTypes: Bool = false, keyedValues: Bool = false, identifierStarts: Set<Character> = [],
                commentNeedsSpace: Bool = false, markup: Bool = false, markdown: Bool = false) {
        self.lineComments = lineComments
        self.blockComment = blockComment
        self.quotes = quotes
        self.multilineStrings = multilineStrings
        self.keywords = keywords
        self.keywordsIgnoreCase = keywordsIgnoreCase
        self.capitalizedTypes = capitalizedTypes
        self.keyedValues = keyedValues
        self.identifierStarts = identifierStarts
        self.commentNeedsSpace = commentNeedsSpace
        self.markup = markup
        self.markdown = markdown
    }
}
