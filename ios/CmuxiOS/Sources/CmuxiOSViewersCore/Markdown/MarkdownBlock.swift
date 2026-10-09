/// One block of a Markdown document. Inline markup (emphasis, code spans,
/// links) stays in the text and is rendered by the viewer.
public indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A fenced or indented code block; `language` is the fence's info word.
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case thematicBreak
}
