import SwiftUI
import UIKit

struct MarkdownBlock: Identifiable {
    let id = UUID()
    let type: MarkdownBlockType
}

enum MarkdownBlockType: Equatable {
    case paragraph(String)
    case heading(String)
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
}

struct MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(omittingEmptySubsequences: false) { $0.isNewline }
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let paragraph = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty {
                blocks.append(MarkdownBlock(type: .paragraph(paragraph)))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = String(lines[index])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(type: .heading(heading)))
                index += 1
                continue
            }

            if isEmptyHeadingLine(trimmed) {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = parseFence(trimmed) {
                flushParagraph()
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let codeLine = String(lines[index])
                    let codeTrimmed = codeLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if codeTrimmed.hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(codeLine)
                    index += 1
                }
                let code = codeLines.joined(separator: "\n")
                let language = fence.isEmpty ? nil : fence
                blocks.append(MarkdownBlock(type: .codeBlock(language: language, code: code)))
                continue
            }

            if index + 1 < lines.count,
               looksLikeTableRow(line),
               let header = parseTableRow(line),
               isTableSeparator(String(lines[index + 1]), expectedColumns: header.count) {
                flushParagraph()
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let rowLine = String(lines[index])
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if rowTrimmed.isEmpty || !looksLikeTableRow(rowLine) {
                        break
                    }
                    if let row = parseTableRow(rowLine) {
                        rows.append(row)
                    }
                    index += 1
                }
                blocks.append(MarkdownBlock(type: .table(headers: header, rows: rows)))
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let prefixCount = line.prefix { $0 == "#" }.count
        let trimmed = line.dropFirst(prefixCount).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    private static func isEmptyHeadingLine(_ line: String) -> Bool {
        guard line.hasPrefix("#") else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.allSatisfy { $0 == "#" }
    }

    private static func parseFence(_ line: String) -> String? {
        guard line.hasPrefix("```") else { return nil }
        let remainder = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return String(remainder)
    }

    private static func looksLikeTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|")
    }

    private static func isTableSeparator(_ line: String, expectedColumns: Int) -> Bool {
        guard expectedColumns > 0 else { return false }
        guard let columns = parseTableColumns(line), columns.count == expectedColumns else { return false }
        for column in columns {
            let trimmed = column.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            guard trimmed.contains("-") else { return false }
            for character in trimmed {
                if character != "-" && character != ":" {
                    return false
                }
            }
        }
        return true
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        guard let columns = parseTableColumns(line) else { return nil }
        return columns.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTableColumns(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { String($0) }
        if let first = parts.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.removeFirst()
        }
        if let last = parts.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.removeLast()
        }
        return parts
    }
}

enum MarkdownInlineToken: Equatable {
    case text(String)
    case inlineCode(String)
    case link(text: String, url: String)
    case image(alt: String, url: String)
    case strong([MarkdownInlineToken])
}

struct MarkdownInlineParser {
    static func parse(_ text: String) -> [MarkdownInlineToken] {
        var tokens: [MarkdownInlineToken] = []
        var buffer = ""
        var index = text.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            tokens.append(.text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let char = text[index]
            if char == "`" {
                if let end = text[text.index(after: index)...].firstIndex(of: "`") {
                    flushBuffer()
                    let code = String(text[text.index(after: index)..<end])
                    tokens.append(.inlineCode(code))
                    index = text.index(after: end)
                    continue
                }
            }

            if char == "!" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "[",
                   let image = parseLinkToken(text, start: next, isImage: true) {
                    flushBuffer()
                    tokens.append(.image(alt: image.label, url: image.url))
                    index = image.nextIndex
                    continue
                }
            }

            if char == "[", let link = parseLinkToken(text, start: index, isImage: false) {
                flushBuffer()
                tokens.append(.link(text: link.label, url: link.url))
                index = link.nextIndex
                continue
            }

            if let strong = parseStrongToken(text, start: index) {
                flushBuffer()
                tokens.append(.strong(strong.tokens))
                index = strong.nextIndex
                continue
            }

            buffer.append(char)
            index = text.index(after: index)
        }

        flushBuffer()
        return tokens
    }

    private static func parseStrongToken(
        _ text: String,
        start: String.Index
    ) -> (tokens: [MarkdownInlineToken], nextIndex: String.Index)? {
        let marker = text[start]
        guard marker == "*" || marker == "_" else { return nil }
        let second = text.index(after: start)
        guard second < text.endIndex, text[second] == marker else { return nil }
        let contentStart = text.index(after: second)
        guard let closingRange = text[contentStart...].range(of: String(repeating: marker, count: 2)) else {
            return nil
        }
        let content = String(text[contentStart..<closingRange.lowerBound])
        guard !content.isEmpty else { return nil }
        let innerTokens = parse(content)
        return (tokens: innerTokens, nextIndex: closingRange.upperBound)
    }

    private static func parseLinkToken(
        _ text: String,
        start: String.Index,
        isImage: Bool
    ) -> (label: String, url: String, nextIndex: String.Index)? {
        guard text[start] == "[" else { return nil }
        guard let closeBracket = text[start...].firstIndex(of: "]") else { return nil }
        let label = String(text[text.index(after: start)..<closeBracket])
        let parenStart = text.index(after: closeBracket)
        guard parenStart < text.endIndex, text[parenStart] == "(" else { return nil }
        let urlStart = text.index(after: parenStart)
        guard let closeParen = text[urlStart...].firstIndex(of: ")") else { return nil }
        let url = String(text[urlStart..<closeParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        let nextIndex = text.index(after: closeParen)
        if isImage, label.isEmpty, url.isEmpty {
            return nil
        }
        return (label: label, url: url, nextIndex: nextIndex)
    }
}

struct MarkdownLinkPolicy: Equatable {
    let allowedSchemes: Set<String>
    let allowedHosts: Set<String>?

    static let `default` = MarkdownLinkPolicy(
        allowedSchemes: ["https", "http"],
        allowedHosts: nil
    )
}

enum MarkdownImagePolicy: Equatable {
    case disabled
    case tapToLoad(allowedSchemes: Set<String>, allowedHosts: Set<String>?)
    case allow(allowedSchemes: Set<String>, allowedHosts: Set<String>?)

    static let `default` = MarkdownImagePolicy.tapToLoad(
        allowedSchemes: ["https"],
        allowedHosts: nil
    )
}

struct MarkdownRenderPolicy: Equatable {
    let linkPolicy: MarkdownLinkPolicy
    let imagePolicy: MarkdownImagePolicy
    let linkSafetyPolicy: MarkdownLinkSafetyPolicy

    static let assistantDefault = MarkdownRenderPolicy(
        linkPolicy: .default,
        imagePolicy: .default,
        linkSafetyPolicy: .default
    )
}

enum MarkdownLinkConfirmationMode: Equatable {
    case always
    case unsafeOnly
}

struct MarkdownLinkSafetyPolicy: Equatable {
    let confirmationMode: MarkdownLinkConfirmationMode
    let safeSchemes: Set<String>
    let safeHosts: Set<String>
    let safeHostSuffixes: [String]

    static let `default` = MarkdownLinkSafetyPolicy(
        confirmationMode: .always,
        safeSchemes: ["https"],
        safeHosts: [],
        safeHostSuffixes: []
    )

    func requiresConfirmation(url: URL) -> Bool {
        switch confirmationMode {
        case .always:
            return true
        case .unsafeOnly:
            return !isSafe(url: url)
        }
    }

    func isSafe(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              safeSchemes.contains(scheme) else { return false }
        guard let host = url.host?.lowercased() else { return false }
        if safeHosts.contains(host) {
            return true
        }
        for suffix in safeHostSuffixes {
            let normalizedSuffix = suffix.lowercased()
            if host == normalizedSuffix || host.hasSuffix(".\(normalizedSuffix)") {
                return true
            }
        }
        return false
    }
}

struct MarkdownLayoutConfig: Equatable {
    let tableHeaderPaddingLeading: CGFloat
    let tableHeaderPaddingTrailing: CGFloat
    let tableBodyPaddingLeading: CGFloat
    let tableBodyPaddingTrailing: CGFloat
    let tableRowVerticalPadding: CGFloat
    let tableBlockVerticalPadding: CGFloat
    let codeBlockVerticalPadding: CGFloat
    let paragraphSpacing: CGFloat
    let assistantMessageTopPadding: CGFloat
    let assistantMessageBottomPadding: CGFloat
    let inlineCodeFontSizeDelta: CGFloat
    let lineHeightMultiple: CGFloat

    static let `default` = MarkdownLayoutConfig(
        tableHeaderPaddingLeading: 16,
        tableHeaderPaddingTrailing: 10,
        tableBodyPaddingLeading: 16,
        tableBodyPaddingTrailing: 10,
        tableRowVerticalPadding: 12,
        tableBlockVerticalPadding: 12,
        codeBlockVerticalPadding: 12,
        paragraphSpacing: 8,
        assistantMessageTopPadding: 12,
        assistantMessageBottomPadding: 12,
        inlineCodeFontSizeDelta: -1,
        lineHeightMultiple: 1.12
    )
}

struct MarkdownURLValidator {
    static func isAllowed(url: URL, allowedSchemes: Set<String>, allowedHosts: Set<String>?) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return false }
        if let hosts = allowedHosts {
            guard let host = url.host?.lowercased() else { return false }
            return hosts.contains(host)
        }
        return true
    }
}

struct AssistantMarkdownView: View {
    let text: String
    let policy: MarkdownRenderPolicy
    let layout: MarkdownLayoutConfig
    @State private var pendingLink: URL?

    init(
        text: String,
        policy: MarkdownRenderPolicy = .assistantDefault,
        layout: MarkdownLayoutConfig = .default
    ) {
        self.text = text
        self.policy = policy
        self.layout = layout
    }

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        let items = makeRenderItems(blocks)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                renderItem(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            handleLinkTap(url)
        })
        .alert("Open Link?", isPresented: Binding(
            get: { pendingLink != nil },
            set: { isPresented in
                if !isPresented {
                    pendingLink = nil
                }
            }
        )) {
            Button("Cancel", role: .cancel) {
                pendingLink = nil
            }
            Button("Open") {
                openPendingLink()
            }
        } message: {
            Text(pendingLink?.absoluteString ?? "")
        }
    }

    @ViewBuilder
    private func renderItem(_ item: MarkdownRenderItem) -> some View {
        switch item.type {
        case .textGroup(let blocks):
            MarkdownTextGroupView(
                blocks: blocks,
                policy: policy,
                paragraphSpacing: layout.paragraphSpacing,
                lineHeightMultiple: layout.lineHeightMultiple,
                inlineCodeFontSizeDelta: layout.inlineCodeFontSizeDelta,
                onOpenURL: handleURLTap
            )
        case .inlineText(let tokens, let baseFont):
            MarkdownInlineView(
                tokens: tokens,
                policy: policy,
                baseFont: baseFont,
                lineHeightMultiple: layout.lineHeightMultiple,
                inlineCodeFontSizeDelta: layout.inlineCodeFontSizeDelta,
                onOpenURL: handleURLTap
            )
        case .codeBlock(let language, let code):
            MarkdownCodeBlockView(language: language, code: code)
                .padding(.vertical, layout.codeBlockVerticalPadding)
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows, policy: policy, layout: layout)
                .padding(.vertical, layout.tableBlockVerticalPadding)
        }
    }

    private func makeRenderItems(_ blocks: [MarkdownBlock]) -> [MarkdownRenderItem] {
        var items: [MarkdownRenderItem] = []
        var pendingTextBlocks: [MarkdownTextBlock] = []

        func flushTextGroup() {
            guard !pendingTextBlocks.isEmpty else { return }
            items.append(
                MarkdownRenderItem(
                    type: .textGroup(pendingTextBlocks)
                )
            )
            pendingTextBlocks.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            switch block.type {
            case .paragraph(let text):
                let tokens = MarkdownInlineParser.parse(text)
                let baseFont = MarkdownAttributedStringBuilder.baseFont(style: .body, weight: .regular)
                if containsImage(tokens) {
                    flushTextGroup()
                    items.append(
                        MarkdownRenderItem(
                            type: .inlineText(tokens: tokens, baseFont: baseFont)
                        )
                    )
                } else {
                    pendingTextBlocks.append(MarkdownTextBlock(tokens: tokens, baseFont: baseFont))
                }
            case .heading(let text):
                let tokens = MarkdownInlineParser.parse(text)
                let baseFont = MarkdownAttributedStringBuilder.baseFont(style: .body, weight: .semibold)
                if containsImage(tokens) {
                    flushTextGroup()
                    items.append(
                        MarkdownRenderItem(
                            type: .inlineText(tokens: tokens, baseFont: baseFont)
                        )
                    )
                } else {
                    pendingTextBlocks.append(MarkdownTextBlock(tokens: tokens, baseFont: baseFont))
                }
            case .codeBlock(let language, let code):
                flushTextGroup()
                items.append(
                    MarkdownRenderItem(
                        type: .codeBlock(language: language, code: code)
                    )
                )
            case .table(let headers, let rows):
                flushTextGroup()
                items.append(
                    MarkdownRenderItem(
                        type: .table(headers: headers, rows: rows)
                    )
                )
            }
        }

        flushTextGroup()
        return items
    }

    private func containsImage(_ tokens: [MarkdownInlineToken]) -> Bool {
        tokens.contains { token in
            if case .image = token {
                return true
            }
            return false
        }
    }

    private func handleLinkTap(_ url: URL) -> OpenURLAction.Result {
        handleURLTap(url)
        return .handled
    }

    private func handleURLTap(_ url: URL) {
        if policy.linkSafetyPolicy.requiresConfirmation(url: url) {
            pendingLink = url
            return
        }
        openURL(url)
    }

    private func openPendingLink() {
        guard let url = pendingLink else { return }
        pendingLink = nil
        openURL(url)
    }

    private func openURL(_ url: URL) {
        UIApplication.shared.open(url) { success in
            if !success {
                print("⚠️ Failed to open URL: \(url)")
            }
        }
    }
}

private enum MarkdownInlineSegmentType: Equatable {
    case text([MarkdownInlineToken])
    case image(alt: String, url: String)
}

private struct MarkdownInlineSegment: Identifiable, Equatable {
    let id: UUID
    let type: MarkdownInlineSegmentType
}

private struct MarkdownTextBlock: Equatable {
    let tokens: [MarkdownInlineToken]
    let baseFont: UIFont
}

private enum MarkdownRenderItemType: Equatable {
    case textGroup([MarkdownTextBlock])
    case inlineText(tokens: [MarkdownInlineToken], baseFont: UIFont)
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
}

private struct MarkdownRenderItem: Identifiable, Equatable {
    let id = UUID()
    let type: MarkdownRenderItemType
}

private struct MarkdownInlineView: View {
    let tokens: [MarkdownInlineToken]
    let policy: MarkdownRenderPolicy
    let baseFont: UIFont
    let lineHeightMultiple: CGFloat
    let inlineCodeFontSizeDelta: CGFloat
    let onOpenURL: (URL) -> Void

    var body: some View {
        let segments = splitSegments(tokens)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(segments) { segment in
                switch segment.type {
                case .text(let textTokens):
                    SelectableTextView(
                        attributedText: MarkdownAttributedStringBuilder.buildInline(
                            tokens: textTokens,
                            policy: policy,
                            baseFont: baseFont,
                            lineHeightMultiple: lineHeightMultiple,
                            inlineCodeFontSizeDelta: inlineCodeFontSizeDelta
                        ),
                        onOpenURL: onOpenURL
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .image(let alt, let url):
                    MarkdownImageView(alt: alt, url: url, policy: policy.imagePolicy)
                }
            }
        }
    }

    private func splitSegments(_ tokens: [MarkdownInlineToken]) -> [MarkdownInlineSegment] {
        var segments: [MarkdownInlineSegment] = []
        var buffer: [MarkdownInlineToken] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(
                MarkdownInlineSegment(
                    id: UUID(),
                    type: .text(buffer)
                )
            )
            buffer.removeAll(keepingCapacity: true)
        }

        for token in tokens {
            switch token {
            case .image(let alt, let url):
                flush()
                segments.append(
                    MarkdownInlineSegment(
                        id: UUID(),
                        type: .image(alt: alt, url: url)
                    )
                )
            default:
                buffer.append(token)
            }
        }

        flush()
        return segments
    }
}

private struct MarkdownTextGroupView: View {
    let blocks: [MarkdownTextBlock]
    let policy: MarkdownRenderPolicy
    let paragraphSpacing: CGFloat
    let lineHeightMultiple: CGFloat
    let inlineCodeFontSizeDelta: CGFloat
    let onOpenURL: (URL) -> Void

    var body: some View {
        SelectableTextView(
            attributedText: buildText(),
            onOpenURL: onOpenURL
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buildText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            let spacing = isLast ? 0 : paragraphSpacing
            let paragraph = MarkdownAttributedStringBuilder.buildParagraph(
                tokens: block.tokens,
                policy: policy,
                baseFont: block.baseFont,
                paragraphSpacing: spacing,
                paragraphSpacingBefore: index == 0 ? 0 : paragraphSpacing,
                lineHeightMultiple: lineHeightMultiple,
                inlineCodeFontSizeDelta: inlineCodeFontSizeDelta,
                addTrailingNewline: !isLast
            )
            result.append(paragraph)
        }
        return result
    }
}

struct MarkdownAttributedStringBuilder {
    static func buildInline(
        tokens: [MarkdownInlineToken],
        policy: MarkdownRenderPolicy,
        baseFont: UIFont,
        lineHeightMultiple: CGFloat,
        inlineCodeFontSizeDelta: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for token in tokens {
            switch token {
            case .text(let text):
                result.append(textSegment(text, font: baseFont))
            case .inlineCode(let code):
                result.append(inlineCodeSegment(code, font: baseFont, sizeDelta: inlineCodeFontSizeDelta))
            case .link(let label, let urlString):
                let display = label.isEmpty ? urlString : label
                result.append(linkSegment(display, urlString: urlString, policy: policy, font: baseFont))
            case .image:
                continue
            case .strong(let strongTokens):
                let boldFont = boldFont(for: baseFont)
                result.append(
                    buildInline(
                        tokens: strongTokens,
                        policy: policy,
                        baseFont: boldFont,
                        lineHeightMultiple: lineHeightMultiple,
                        inlineCodeFontSizeDelta: inlineCodeFontSizeDelta
                    )
                )
            }
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = lineHeightMultiple
        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    static func buildParagraph(
        tokens: [MarkdownInlineToken],
        policy: MarkdownRenderPolicy,
        baseFont: UIFont,
        paragraphSpacing: CGFloat,
        paragraphSpacingBefore: CGFloat,
        lineHeightMultiple: CGFloat,
        inlineCodeFontSizeDelta: CGFloat,
        addTrailingNewline: Bool
    ) -> NSAttributedString {
        let paragraph = NSMutableAttributedString(
            attributedString: buildInline(
                tokens: tokens,
                policy: policy,
                baseFont: baseFont,
                lineHeightMultiple: lineHeightMultiple,
                inlineCodeFontSizeDelta: inlineCodeFontSizeDelta
            )
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = paragraphSpacing
        paragraphStyle.paragraphSpacingBefore = paragraphSpacingBefore
        paragraphStyle.lineHeightMultiple = lineHeightMultiple
        paragraph.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: paragraph.length)
        )
        if addTrailingNewline {
            let newline = NSAttributedString(
                string: "\n",
                attributes: [
                    .font: baseFont,
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: UIColor.label
                ]
            )
            paragraph.append(newline)
        }
        return paragraph
    }

    static func baseFont(style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let preferred = UIFont.preferredFont(forTextStyle: style)
        return UIFont.systemFont(ofSize: preferred.pointSize, weight: weight)
    }

    private static func textSegment(_ text: String, font: UIFont) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label
            ]
        )
    }

    private static func boldFont(for font: UIFont) -> UIFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.traitBold)
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return UIFont.systemFont(ofSize: font.pointSize, weight: .bold)
    }

    private static func inlineCodeSegment(
        _ code: String,
        font: UIFont,
        sizeDelta: CGFloat
    ) -> NSAttributedString {
        let targetSize = max(1, font.pointSize + sizeDelta)
        let codeFont = UIFont.monospacedSystemFont(ofSize: targetSize, weight: .regular)
        return NSAttributedString(
            string: code,
            attributes: [
                .font: codeFont,
                .backgroundColor: UIColor.secondarySystemBackground,
                .foregroundColor: UIColor.label
            ]
        )
    }

    private static func linkSegment(
        _ text: String,
        urlString: String,
        policy: MarkdownRenderPolicy,
        font: UIFont
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.systemBlue
        ]
        if let url = URL(string: urlString),
           MarkdownURLValidator.isAllowed(
            url: url,
            allowedSchemes: policy.linkPolicy.allowedSchemes,
            allowedHosts: policy.linkPolicy.allowedHosts
           ) {
            attributes[.link] = url
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language {
                Text(language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: code.isEmpty ? " " : code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.vertical, 2)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.separator), lineWidth: 1)
        )
        }
    }

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let policy: MarkdownRenderPolicy
    let layout: MarkdownLayoutConfig
    @State private var columnWidths: [Int: CGFloat] = [:]

    private var columnCount: Int {
        let rowMax = rows.map { $0.count }.max() ?? 0
        return max(headers.count, rowMax)
    }

    var body: some View {
        let columns = max(columnCount, 1)

        ScrollView(.horizontal, showsIndicators: true) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        tableCell(
                            text: cellText(headers, column),
                            isHeader: true,
                            row: -1,
                            column: column,
                            isEvenRow: true
                        )
                    }
                }
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            tableCell(
                                text: cellText(rows[rowIndex], column),
                                isHeader: false,
                                row: rowIndex,
                                column: column,
                                isEvenRow: rowIndex % 2 == 0
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, -16)
        .coordinateSpace(name: "markdown.table")
        .onPreferenceChange(TableCellLayoutPreferenceKey.self) { layouts in
            updateColumnWidths(layouts)
        }
    }

    private func cellText(_ row: [String], _ column: Int) -> String {
        guard column < row.count else { return "" }
        return row[column]
    }

    @ViewBuilder
    private func tableCell(
        text: String,
        isHeader: Bool,
        row: Int,
        column: Int,
        isEvenRow: Bool
    ) -> some View {
        let leadingPadding = isHeader ? layout.tableHeaderPaddingLeading : layout.tableBodyPaddingLeading
        let trailingPadding = isHeader ? layout.tableHeaderPaddingTrailing : layout.tableBodyPaddingTrailing
        let attributedText = buildCellText(text: text, isHeader: isHeader)

        Text(attributedText)
            .padding(.leading, leadingPadding)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, layout.tableRowVerticalPadding)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: columnWidths[column], alignment: .leading)
            .overlay(
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 1),
                alignment: .bottom
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TableCellLayoutPreferenceKey.self,
                        value: [
                            TableCellLayout(
                                row: row,
                                column: column,
                                isHeader: isHeader,
                                minX: proxy.frame(in: .named("markdown.table")).minX,
                                width: proxy.size.width
                            )
                        ]
                    )
                }
            )
            .textSelection(.enabled)
    }

    private func buildCellText(text: String, isHeader: Bool) -> AttributedString {
        guard !text.isEmpty else { return AttributedString(" ") }
        let tokens = MarkdownInlineParser.parse(text)
        let baseFont = MarkdownAttributedStringBuilder.baseFont(
            style: .subheadline,
            weight: isHeader ? .bold : .regular
        )
        let attributed = MarkdownAttributedStringBuilder.buildInline(
            tokens: tokens,
            policy: policy,
            baseFont: baseFont,
            lineHeightMultiple: layout.lineHeightMultiple,
            inlineCodeFontSizeDelta: layout.inlineCodeFontSizeDelta
        )
        return AttributedString(attributed)
    }

    private func updateColumnWidths(_ layouts: [TableCellLayout]) {
        var next = columnWidths
        for layout in layouts {
            let width = layout.width
            let current = next[layout.column] ?? 0
            if width > current + 0.5 {
                next[layout.column] = width
            }
        }
        if next != columnWidths {
            columnWidths = next
        }
    }
}

private struct TableCellLayout: Equatable {
    let row: Int
    let column: Int
    let isHeader: Bool
    let minX: CGFloat
    let width: CGFloat
}

private struct TableCellLayoutPreferenceKey: PreferenceKey {
    static var defaultValue: [TableCellLayout] = []

    static func reduce(value: inout [TableCellLayout], nextValue: () -> [TableCellLayout]) {
        value.append(contentsOf: nextValue())
    }
}

private struct MarkdownImageView: View {
    let alt: String
    let url: String
    let policy: MarkdownImagePolicy
    @State private var isRevealed = false

    var body: some View {
        Group {
            if let imageUrl = URL(string: url), isAllowed(url: imageUrl) {
                switch policy {
                case .disabled:
                    blockedView
                case .tapToLoad:
                    if isRevealed {
                        AsyncImage(url: imageUrl) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            case .failure:
                                failedView
                            default:
                                progressView
                            }
                        }
                    } else {
                        Button("Load image") {
                            isRevealed = true
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                case .allow:
                    AsyncImage(url: imageUrl) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            failedView
                        default:
                            progressView
                        }
                    }
                }
            } else {
                blockedView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(alt.isEmpty ? "Image" : "Image: \(alt)")
    }

    private var blockedView: some View {
        Text(alt.isEmpty ? "Image blocked" : "Image blocked: \(alt)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var failedView: some View {
        Text(alt.isEmpty ? "Image failed to load" : "Image failed to load: \(alt)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var progressView: some View {
        ProgressView()
    }

    private func isAllowed(url: URL) -> Bool {
        switch policy {
        case .disabled:
            return false
        case .tapToLoad(let schemes, let hosts),
             .allow(let schemes, let hosts):
            return MarkdownURLValidator.isAllowed(url: url, allowedSchemes: schemes, allowedHosts: hosts)
        }
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let onOpenURL: (URL) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        textView.dataDetectorTypes = []
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue
        ]
        textView.adjustsFontForContentSizeCategory = true

        // Add tap gesture to immediately dismiss keyboard (fixes lag vs code blocks)
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tapGesture.cancelsTouchesInView = false
        textView.addGestureRecognizer(tapGesture)

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = attributedText
        if uiView.textColor != .label {
            uiView.textColor = .label
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let targetSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(targetSize)
        return CGSize(width: width, height: size.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let onOpenURL: (URL) -> Void

        init(onOpenURL: @escaping (URL) -> Void) {
            self.onOpenURL = onOpenURL
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            gesture.view?.window?.endEditing(true)
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            switch textItem.content {
            case .link(let url):
                return UIAction { [weak self] _ in
                    self?.onOpenURL(url)
                }
            default:
                return defaultAction
            }
        }
    }
}
