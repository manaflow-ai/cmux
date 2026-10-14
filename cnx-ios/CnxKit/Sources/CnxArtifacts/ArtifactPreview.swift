#if os(iOS)
import AVKit
import PDFKit
import SwiftUI
import WebKit

/// The best preview for each kind: rendered HTML and Markdown with a Source
/// toggle, syntax-colored code, zoomable images, a video player, PDFs, web
/// links, folder listings. Folder rows push `TerminalArtifact` values, so the
/// enclosing stack registers `navigationDestination(for: TerminalArtifact.self)`.
public struct ArtifactPreview: View {
    let artifact: TerminalArtifact
    let source: any ArtifactSource
    @Binding var showSource: Bool
    @State private var content: Result<ArtifactContent, any Error>?
    /// Bumped by Try Again: reloads the artifact.
    @State private var attempt = 0
    @Environment(\.openURL) private var openURL

    public init(artifact: TerminalArtifact, source: any ArtifactSource, showSource: Binding<Bool>) {
        self.artifact = artifact
        self.source = source
        _showSource = showSource
    }

    private var rendersAsWeb: Bool { artifact.kind == .html || artifact.kind == .markdown }

    public var body: some View {
        Group {
            switch content {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("artifact.loading")
            case .failure(let error):
                // Never a blank page: what the Mac said, and a way to try again.
                ContentUnavailableView {
                    Label("Can't open \(artifact.name)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Try Again") {
                        content = nil
                        attempt += 1
                    }
                    .accessibilityIdentifier("artifact.retry")
                }
            case .success(let loaded):
                view(for: loaded)
            }
        }
        .navigationTitle(artifact.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if rendersAsWeb {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View", selection: $showSource) {
                        Image(systemName: "eye").tag(false).accessibilityLabel("Preview")
                        Image(systemName: "chevron.left.forwardslash.chevron.right").tag(true).accessibilityLabel("Source")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .accessibilityIdentifier("artifact.sourceToggle")
                }
            }
            if artifact.kind == .link, let url = URL(string: artifact.reference) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open in Safari", systemImage: "safari") { openURL(url) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = artifact.reference }
                    if case .success(.text(let text)) = content {
                        Button("Copy contents", systemImage: "text.document") { UIPasteboard.general.string = text }
                        ShareLink(item: text, preview: SharePreview(artifact.name)) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .task(id: ArtifactLoad(artifact: artifact, attempt: attempt)) {
            do { content = .success(try await source.load(artifact)) } catch { content = .failure(error) }
        }
    }

    @ViewBuilder
    private func view(for content: ArtifactContent) -> some View {
        switch content {
        case .text(let text):
            if artifact.kind == .html, !showSource {
                WebPreview(mode: .html(text))
            } else if artifact.kind == .markdown, !showSource {
                WebPreview(mode: .html(MarkdownHTML.render(text)))
            } else {
                CodeView(text: text, language: artifact.kind == .html ? "html" : artifact.kind == .markdown ? "md" : artifact.fileExtension,
                         highlightLine: artifact.line)
            }
        case .image(let data):
            ZoomableImage(image: UIImage(data: data))
        case .file(let url):
            AutoplayVideo(url: url)
        case .web(let url):
            WebPreview(mode: .url(url))
        case .pdf(let data):
            PDFPreview(data: data)
        case .directory(let children):
            List(children) { child in
                NavigationLink(value: child) { ArtifactRow(artifact: child) }
            }
            .listStyle(.plain)
        case .binary(let description):
            ContentUnavailableView {
                Label(artifact.name, systemImage: artifact.systemImage)
            } description: {
                Text(description).font(.footnote.monospaced())
            }
        }
    }
}

/// What `ArtifactPreview` loads: the artifact, again for each Try Again.
private struct ArtifactLoad: Hashable {
    let artifact: TerminalArtifact
    let attempt: Int
}

/// A video that starts playing when it opens (system controls on tap).
struct AutoplayVideo: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .background(.black)
            .onAppear {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            }
            .onDisappear { player?.pause() }
    }
}

/// PDFKit with continuous vertical pages.
struct PDFPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

/// WKWebView for HTML artifacts (JavaScript off) and links.
public struct WebPreview: UIViewRepresentable {
    public enum Mode: Equatable { case html(String), url(URL) }
    let mode: Mode

    public init(mode: Mode) { self.mode = mode }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if case .html = mode {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        load(web)
        context.coordinator.mode = mode
        return web
    }

    public func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.mode != mode else { return }
        context.coordinator.mode = mode
        load(web)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator { var mode: Mode? }

    private func load(_ web: WKWebView) {
        switch mode {
        case .html(let html): web.loadHTMLString(html, baseURL: nil)
        case .url(let url): web.load(URLRequest(url: url))
        }
    }
}

/// Pinch and double-tap zoom.
struct ZoomableImage: View {
    let image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(1, base * $0.magnification) }
                    .onEnded { _ in base = scale })
                .onTapGesture(count: 2) {
                    withAnimation(.smooth) { scale = scale > 1 ? 1 : 2.5; base = scale }
                }
                .accessibilityLabel("Image")
        } else {
            ContentUnavailableView("Not an image", systemImage: "photo")
        }
    }
}

/// Code with a line-number gutter and syntax colors (SPEC 11.4 CodeView).
struct CodeView: View {
    let text: String
    let language: String
    var highlightLine: Int?
    @State private var wrap = false

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(index + 1)")
                                .foregroundStyle(.tertiary)
                                .frame(width: 40, alignment: .trailing)
                                .padding(.trailing, 12)
                            Text(SyntaxHighlighter.highlight(line, language: language))
                                .fixedSize(horizontal: !wrap, vertical: true)
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(index + 1 == highlightLine ? Color.yellow.opacity(0.15) : .clear)
                        .id(index + 1)
                    }
                }
                .padding(.vertical, 12)
                .padding(.trailing, 16)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.topLeading)
            .onAppear { if let highlightLine { proxy.scrollTo(highlightLine, anchor: .center) } }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Toggle(isOn: $wrap) { Label("Wrap lines", systemImage: "text.word.spacing") }
            }
        }
    }
}

/// A small tokenizer: comments, strings, numbers, keywords, types, HTML tags.
struct SyntaxHighlighter {
    static let keywordColor = Color(red: 0.99, green: 0.37, blue: 0.64)
    static let stringColor = Color(red: 0.99, green: 0.42, blue: 0.36)
    static let commentColor = Color(red: 0.42, green: 0.47, blue: 0.53)
    static let numberColor = Color(red: 0.82, green: 0.75, blue: 0.43)
    static let typeColor = Color(red: 0.36, green: 0.85, blue: 0.95)
    static let tagColor = Color(red: 0.36, green: 0.85, blue: 0.95)

    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case",
        "switch", "match", "fn", "pub", "use", "impl", "mut", "self", "Self", "static", "public", "private", "true",
        "false", "nil", "None", "Some", "async", "await", "try", "guard", "in", "where", "const", "type", "def",
        "from", "export", "function", "new", "package", "name", "version", "edition", "mod", "crate", "as",
    ]

    static func highlight(_ line: String, language: String) -> AttributedString {
        var result = AttributedString(line)
        guard !line.isEmpty else { return result }
        let commentPrefix = ["py", "sh", "toml", "yml", "yaml", "rb"].contains(language) ? "#" : "//"
        if language == "html" || language == "md" {
            return highlightMarkup(line, language: language)
        }
        let characters = Array(line)
        var index = 0
        func color(_ start: Int, _ end: Int, _ color: Color) {
            let lower = result.index(result.startIndex, offsetByCharacters: start)
            let upper = result.index(result.startIndex, offsetByCharacters: end)
            result[lower..<upper].foregroundColor = color
        }
        while index < characters.count {
            let rest = String(characters[index...])
            if rest.hasPrefix(commentPrefix) || rest.hasPrefix("///") {
                color(index, characters.count, commentColor)
                break
            }
            let character = characters[index]
            if character == "\"" || character == "'" && language != "rs" {
                var end = index + 1
                while end < characters.count, characters[end] != character {
                    end += characters[end] == "\\" ? 2 : 1
                }
                end = min(end + 1, characters.count)
                color(index, end, stringColor)
                index = end
            } else if character.isNumber {
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." || characters[end] == "_" { end += 1 }
                color(index, end, numberColor)
                index = end
            } else if character.isLetter || character == "_" || character == "#" || character == "@" {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                let word = String(characters[index..<end])
                if keywords.contains(word) || word.hasPrefix("#") || word.hasPrefix("@") {
                    color(index, end, keywordColor)
                } else if let first = word.first, first.isUppercase {
                    color(index, end, typeColor)
                }
                index = end
            } else {
                index += 1
            }
        }
        return result
    }

    private static func highlightMarkup(_ line: String, language: String) -> AttributedString {
        var result = AttributedString(line)
        if language == "md" {
            if line.hasPrefix("#") { result.foregroundColor = keywordColor }
            else if line.hasPrefix("```") || line.hasPrefix("    ") { result.foregroundColor = stringColor }
            else if line.hasPrefix(">") { result.foregroundColor = commentColor }
            return result
        }
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            if characters[index] == "<" {
                var end = index
                while end < characters.count, characters[end] != ">" { end += 1 }
                end = min(end + 1, characters.count)
                let lower = result.index(result.startIndex, offsetByCharacters: index)
                let upper = result.index(result.startIndex, offsetByCharacters: end)
                result[lower..<upper].foregroundColor = tagColor
                // Attribute values inside the tag.
                var quote = index
                while quote < end {
                    if characters[quote] == "\"" {
                        var close = quote + 1
                        while close < end, characters[close] != "\"" { close += 1 }
                        let qLower = result.index(result.startIndex, offsetByCharacters: quote)
                        let qUpper = result.index(result.startIndex, offsetByCharacters: min(close + 1, end))
                        result[qLower..<qUpper].foregroundColor = stringColor
                        quote = close + 1
                    } else {
                        quote += 1
                    }
                }
                index = end
            } else {
                index += 1
            }
        }
        return result
    }
}

/// Markdown to HTML for the preview (headings, lists, quotes, code, tables, inline styles).
struct MarkdownHTML {
    static func render(_ markdown: String) -> String {
        var html = ""
        var inCode = false
        var inList = false
        var tableRows: [[String]] = []
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            html += "<table>"
            for (index, row) in tableRows.enumerated() where !(index == 1 && row.allSatisfy { $0.allSatisfy { "-: ".contains($0) } }) {
                let tag = index == 0 ? "th" : "td"
                html += "<tr>" + row.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
            }
            html += "</table>"
            tableRows = []
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw
            if line.hasPrefix("```") {
                html += inCode ? "</code></pre>" : "<pre><code>"
                inCode.toggle()
                continue
            }
            if inCode { html += escape(line) + "\n"; continue }
            if line.hasPrefix("|") {
                tableRows.append(line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            }
            flushTable()
            let isItem = line.hasPrefix("- ") || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            if inList, !isItem { html += "</ul>"; inList = false }
            if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }), level > 0, level <= 6, line.dropFirst(level).hasPrefix(" ") {
                html += "<h\(level)>\(inline(String(line.dropFirst(level + 1))))</h\(level)>"
            } else if isItem {
                if !inList { html += "<ul>"; inList = true }
                let text = line.hasPrefix("- ") ? String(line.dropFirst(2)) : String(line[line.range(of: ". ")!.upperBound...])
                html += "<li>\(inline(text))</li>"
            } else if line.hasPrefix("> ") {
                html += "<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>"
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                html += ""
            } else {
                html += "<p>\(inline(line))</p>"
            }
        }
        flushTable()
        if inList { html += "</ul>" }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; margin: 20px; line-height: 1.5; }
        h1 { font-size: 1.6em; } h2 { font-size: 1.3em; margin-top: 1.4em; }
        code { font-family: ui-monospace, monospace; font-size: 0.9em; background: rgba(127,127,127,.16); padding: 1px 5px; border-radius: 6px; }
        pre { background: rgba(127,127,127,.12); padding: 12px; border-radius: 12px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding-left: 12px; border-left: 3px solid rgba(127,127,127,.4); color: gray; }
        table { border-collapse: collapse; } th, td { border-bottom: 0.5px solid rgba(127,127,127,.4); padding: 6px 10px; text-align: left; }
        </style></head><body>\(html)</body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ text: String) -> String {
        var out = escape(text)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }
}
#endif
