import SwiftUI
import UIKit

struct MarkdownDebugView: View {
    @State private var tableHeaderLeading: Double = Double(MarkdownLayoutConfig.default.tableHeaderPaddingLeading)
    @State private var tableHeaderTrailing: Double = Double(MarkdownLayoutConfig.default.tableHeaderPaddingTrailing)
    @State private var tableBodyLeading: Double = Double(MarkdownLayoutConfig.default.tableBodyPaddingLeading)
    @State private var tableBodyTrailing: Double = Double(MarkdownLayoutConfig.default.tableBodyPaddingTrailing)
    @State private var tableRowVertical: Double = Double(MarkdownLayoutConfig.default.tableRowVerticalPadding)
    @State private var tableBlockVertical: Double = Double(MarkdownLayoutConfig.default.tableBlockVerticalPadding)
    @State private var codeBlockVertical: Double = Double(MarkdownLayoutConfig.default.codeBlockVerticalPadding)
    @State private var paragraphSpacing: Double = Double(MarkdownLayoutConfig.default.paragraphSpacing)
    @State private var assistantTopPadding: Double = Double(MarkdownLayoutConfig.default.assistantMessageTopPadding)
    @State private var assistantBottomPadding: Double = Double(MarkdownLayoutConfig.default.assistantMessageBottomPadding)
    @State private var inlineCodeFontDelta: Double = Double(MarkdownLayoutConfig.default.inlineCodeFontSizeDelta)
    @State private var lineHeightMultiple: Double = Double(MarkdownLayoutConfig.default.lineHeightMultiple)
    @State private var didCopyLayout = false
    @State private var inputText: String = ""
    @State private var inputMeasuredHeight: CGFloat = DebugInputBarMetrics.editorHeight(
        forLineCount: 1,
        topInsetExtra: 4,
        bottomInsetExtra: 5.333333333333333
    )
    @State private var inputCaretFrameInWindow: CGRect = .zero

    private var layout: MarkdownLayoutConfig {
        MarkdownLayoutConfig(
            tableHeaderPaddingLeading: CGFloat(tableHeaderLeading),
            tableHeaderPaddingTrailing: CGFloat(tableHeaderTrailing),
            tableBodyPaddingLeading: CGFloat(tableBodyLeading),
            tableBodyPaddingTrailing: CGFloat(tableBodyTrailing),
            tableRowVerticalPadding: CGFloat(tableRowVertical),
            tableBlockVerticalPadding: CGFloat(tableBlockVertical),
            codeBlockVerticalPadding: CGFloat(codeBlockVertical),
            paragraphSpacing: CGFloat(paragraphSpacing),
            assistantMessageTopPadding: CGFloat(assistantTopPadding),
            assistantMessageBottomPadding: CGFloat(assistantBottomPadding),
            inlineCodeFontSizeDelta: CGFloat(inlineCodeFontDelta),
            lineHeightMultiple: CGFloat(lineHeightMultiple)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Layout Controls") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Button("Copy Layout") {
                                copyLayout()
                            }
                            if didCopyLayout {
                                Text("Copied")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("Table Header Padding")
                            .font(.subheadline.weight(.semibold))
                        SliderRow(label: "Header Left", value: $tableHeaderLeading, range: 0...24)
                        SliderRow(label: "Header Right", value: $tableHeaderTrailing, range: 0...24)

                        Divider()

                        Text("Table Body Padding")
                            .font(.subheadline.weight(.semibold))
                        SliderRow(label: "Body Left", value: $tableBodyLeading, range: 0...24)
                        SliderRow(label: "Body Right", value: $tableBodyTrailing, range: 0...24)
                        SliderRow(label: "Row Y", value: $tableRowVertical, range: 0...20)

                        Divider()

                        Text("Block Padding (Y)")
                            .font(.subheadline.weight(.semibold))
                        SliderRow(label: "Table Y", value: $tableBlockVertical, range: 0...20)
                        SliderRow(label: "Code Block Y", value: $codeBlockVertical, range: 0...20)

                        Divider()

                        Text("Paragraph Spacing")
                            .font(.subheadline.weight(.semibold))
                        SliderRow(label: "Paragraph Gap", value: $paragraphSpacing, range: 0...48)

                        Divider()

                        Text("Assistant Message Padding (Y)")
                            .font(.subheadline.weight(.semibold))
                        SliderRow(label: "Top", value: $assistantTopPadding, range: 0...24)
                        SliderRow(label: "Bottom", value: $assistantBottomPadding, range: 0...24)

                        Divider()

                        Text("Typography")
                            .font(.subheadline.weight(.semibold))
                        SliderRow(label: "Inline Mono Δ", value: $inlineCodeFontDelta, range: -2...2, step: 0.1)
                        SliderRow(label: "Line Height", value: $lineHeightMultiple, range: 1.0...1.4, step: 0.02)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Conversation Preview")
                        .font(.headline)

                    ForEach(debugMessages) { message in
                        MessageBubble(
                            message: message,
                            showTail: false,
                            showTimestamp: false,
                            markdownLayout: layout
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .navigationTitle("Markdown Debug")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            MarkdownDebugInputBar(
                text: $inputText,
                measuredHeight: $inputMeasuredHeight,
                caretFrameInWindow: $inputCaretFrameInWindow
            )
        }
    }

    private func copyLayout() {
        UIPasteboard.general.string = layoutClipboardText
        didCopyLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopyLayout = false
        }
    }

    private var layoutClipboardText: String {
        let headerLeading = Int(tableHeaderLeading.rounded())
        let headerTrailing = Int(tableHeaderTrailing.rounded())
        let bodyLeading = Int(tableBodyLeading.rounded())
        let bodyTrailing = Int(tableBodyTrailing.rounded())
        let rowVertical = Int(tableRowVertical.rounded())
        let tableVertical = Int(tableBlockVertical.rounded())
        let codeVertical = Int(codeBlockVertical.rounded())
        let paragraphGap = Int(paragraphSpacing.rounded())
        let assistantTop = Int(assistantTopPadding.rounded())
        let assistantBottom = Int(assistantBottomPadding.rounded())
        let inlineDelta = String(format: "%.2f", inlineCodeFontDelta)
        let lineHeight = String(format: "%.2f", lineHeightMultiple)

        return """
        MarkdownLayoutConfig(
            tableHeaderPaddingLeading: \(headerLeading),
            tableHeaderPaddingTrailing: \(headerTrailing),
            tableBodyPaddingLeading: \(bodyLeading),
            tableBodyPaddingTrailing: \(bodyTrailing),
            tableRowVerticalPadding: \(rowVertical),
            tableBlockVerticalPadding: \(tableVertical),
            codeBlockVerticalPadding: \(codeVertical),
            paragraphSpacing: \(paragraphGap),
            assistantMessageTopPadding: \(assistantTop),
            assistantMessageBottomPadding: \(assistantBottom),
            inlineCodeFontSizeDelta: \(inlineDelta),
            lineHeightMultiple: \(lineHeight)
        )
        """
    }
}

private let markdownBaselineStrategy = InputStrategy(
    id: "markdown-baseline",
    title: "Markdown baseline",
    detail: "",
    topInsetExtra: 4,
    bottomInsetExtra: 5.333333333333333,
    scrollMode: .automatic,
    pinCaretToBottom: true,
    scrollRangeToVisible: false,
    allowCaretOverflow: false,
    showsActionButton: true,
    alignment: .bottomLeading
)

private struct MarkdownDebugInputBar: View {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var caretFrameInWindow: CGRect

    var body: some View {
        let minHeight = DebugInputBarMetrics.editorHeight(
            forLineCount: 1,
            topInsetExtra: markdownBaselineStrategy.topInsetExtra,
            bottomInsetExtra: markdownBaselineStrategy.bottomInsetExtra
        )
        let editorHeight = max(minHeight, measuredHeight)
        let pillHeight = max(DebugInputBarMetrics.inputHeight, editorHeight)
        InputStrategyPill(
            strategy: markdownBaselineStrategy,
            text: $text,
            measuredHeight: $measuredHeight,
            caretFrameInWindow: $caretFrameInWindow,
            editorHeight: editorHeight,
            pillHeight: pillHeight
        ) {
            text = ""
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .background(Color(UIColor.systemBackground).opacity(0.9))
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(valueLabel)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }

    private var valueLabel: String {
        if step < 1 {
            return String(format: "%.2f", value)
        }
        return String(format: "%.0f", value)
    }
}

private let debugMessages: [Message] = [
    Message(
        content: "Can you show all markdown types in one response?",
        timestamp: .minutesAgo(8),
        isFromMe: true,
        status: .read
    ),
    Message(
        content: """
# Heading One
Here is a longer paragraph with inline code like `fetch()` and a link to [OpenAI](https://openai.com).
We want enough text to judge line wrapping, spacing rhythm, and selection behavior across lines.
This should read like a realistic assistant response instead of a placeholder.

This is a second paragraph for the intro section, separated by a blank line so spacing is visible.
It should feel like a distinct chunk of thought.

## Inline Image
![Sample image](https://picsum.photos/240/120)

```swift
struct DebugExample {
    let title: String
    func greet() -> String {
        "Hello, \\(title)"
    }
}
```

Here is a table with labels above it.
The rows below should feel like a real output, so we can judge spacing, rhythm, and flow.
This sentence is here to make sure line wrapping feels right before the table.
Another line here helps us see how the paragraph gap behaves when content is longer.

This is a second paragraph before the table so you can compare spacing around block elements.
It should create a noticeable gap from the previous paragraph.

| Column A | Column B | Column C | Column D |
| --- | --- | --- | --- |
| Alpha | Bravo | Charlie | Delta |
| Echo | Foxtrot | Golf | Hotel |
| This is a longer cell to test horizontal scrolling | 12345 | true | ok |

And some text after the table to confirm spacing.
Another paragraph follows so we can see how the next block breathes.
If this line wraps, the spacing should still feel consistent.
Adding one more sentence gives the paragraph more length for visual testing.

This is a final paragraph after the table to make the gap obvious.
It should read as a separate paragraph with extra space above it.
""",
        timestamp: .minutesAgo(7),
        isFromMe: false,
        status: .read
    ),
    Message(
        content: "Thanks! Now tweak padding with the controls above.",
        timestamp: .minutesAgo(6),
        isFromMe: true,
        status: .read
    )
]

#Preview {
    NavigationStack {
        MarkdownDebugView()
    }
}
