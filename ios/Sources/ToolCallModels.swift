import Foundation

enum MessageToolCallStatus: String, Equatable {
    case pending
    case running
    case completed
    case failed

    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}

struct MessageToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let status: MessageToolCallStatus
    let arguments: String
    let result: String?
    let acpSeq: Double?
}

enum AssistantMessageItemKind: Equatable {
    case text(String)
    case toolCall(MessageToolCall)
}

struct AssistantMessageItem: Identifiable, Equatable {
    let id: String
    let kind: AssistantMessageItemKind
}

struct MessageContentPart: Equatable {
    let text: String
    let acpSeq: Double?
}

struct AssistantMessageItemBuilder {
    static func build(
        messageId: String,
        content: [MessageContentPart],
        toolCalls: [MessageToolCall]
    ) -> [AssistantMessageItem] {
        struct OrderedItem {
            let seq: Double?
            let index: Int
            let kind: AssistantMessageItemKind
        }

        var ordered: [OrderedItem] = []
        ordered.reserveCapacity(content.count + toolCalls.count)
        var fallbackIndex = 0

        for part in content {
            ordered.append(
                OrderedItem(
                    seq: part.acpSeq,
                    index: fallbackIndex,
                    kind: .text(part.text)
                )
            )
            fallbackIndex += 1
        }

        for toolCall in toolCalls {
            ordered.append(
                OrderedItem(
                    seq: toolCall.acpSeq,
                    index: fallbackIndex,
                    kind: .toolCall(toolCall)
                )
            )
            fallbackIndex += 1
        }

        let sorted = ordered.sorted { lhs, rhs in
            switch (lhs.seq, rhs.seq) {
            case let (left?, right?):
                if left == right {
                    return lhs.index < rhs.index
                }
                return left < right
            case (nil, nil):
                return lhs.index < rhs.index
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }

        var merged: [AssistantMessageItem] = []
        merged.reserveCapacity(sorted.count)
        var textBuffer: String?
        var itemIndex = 0

        func flushTextBuffer() {
            guard let buffer = textBuffer else { return }
            merged.append(
                AssistantMessageItem(
                    id: "\(messageId)-item-\(itemIndex)",
                    kind: .text(buffer)
                )
            )
            itemIndex += 1
            textBuffer = nil
        }

        for item in sorted {
            switch item.kind {
            case .text(let text):
                if let buffer = textBuffer {
                    textBuffer = buffer + "\n" + text
                } else {
                    textBuffer = text
                }
            case .toolCall:
                flushTextBuffer()
                merged.append(
                    AssistantMessageItem(
                        id: "\(messageId)-item-\(itemIndex)",
                        kind: item.kind
                    )
                )
                itemIndex += 1
            }
        }

        flushTextBuffer()
        return merged
    }
}

struct ToolCallPayloadFormatter {
    static func prettify(_ payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return payload }
        guard let data = trimmed.data(using: .utf8) else { return payload }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return payload
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            return payload
        }
        guard let prettyData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return payload
        }
        return String(data: prettyData, encoding: .utf8) ?? payload
    }
}
