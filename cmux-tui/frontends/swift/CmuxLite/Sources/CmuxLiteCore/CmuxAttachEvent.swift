import Foundation

/// Represents one ordered protocol-v6 byte-attachment event.
public enum CmuxAttachEvent: Decodable, Sendable, Equatable {
    /// The initial replay used to construct a fresh terminal mirror.
    case initialReplay(
        surface: UInt64,
        columns: UInt16,
        rows: UInt16,
        bytes: Data,
        colors: CmuxTerminalColors?
    )

    /// Live PTY bytes applied after the latest replay.
    case output(surface: UInt64, bytes: Data)

    /// An authoritative resized replay that replaces the terminal mirror.
    case resizedReplay(surface: UInt64, columns: UInt16, rows: UInt16, bytes: Data)

    /// Updated terminal color and cursor metadata.
    case colorsChanged(surface: UInt64?, colors: CmuxTerminalColors)

    /// The byte attachment ended.
    case detached(surface: UInt64)

    /// A forward-compatible event not consumed by this frontend.
    case other(name: String)

    /// The subject surface for terminal events, when present.
    public var surface: UInt64? {
        switch self {
        case let .initialReplay(surface, _, _, _, _),
             let .output(surface, _),
             let .resizedReplay(surface, _, _, _),
             let .detached(surface):
            surface
        case let .colorsChanged(surface, _):
            surface
        case .other:
            nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case event
        case surface
        case cols
        case rows
        case data
        case replay
        case colors
        case foreground = "fg"
        case background = "bg"
        case cursor
        case selectionBackground = "selection_bg"
        case selectionForeground = "selection_fg"
        case cursorStyle = "cursor_style"
        case cursorBlink = "cursor_blink"
    }

    /// Decodes base64 replay and output fields while preserving stream order.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .event)

        switch name {
        case "vt-state":
            let encoded = try container.decode(String.self, forKey: .data)
            guard let bytes = Data(base64Encoded: encoded) else {
                throw CmuxProtocolError.malformedPayload("invalid vt-state base64")
            }
            self = try .initialReplay(
                surface: container.decode(UInt64.self, forKey: .surface),
                columns: container.decode(UInt16.self, forKey: .cols),
                rows: container.decode(UInt16.self, forKey: .rows),
                bytes: bytes,
                colors: container.decodeIfPresent(CmuxTerminalColors.self, forKey: .colors)
            )
        case "output":
            let encoded = try container.decode(String.self, forKey: .data)
            guard let bytes = Data(base64Encoded: encoded) else {
                throw CmuxProtocolError.malformedPayload("invalid output base64")
            }
            self = try .output(
                surface: container.decode(UInt64.self, forKey: .surface),
                bytes: bytes
            )
        case "resized":
            // The v6 server emits the replay under `data` (spec/events.md's
            // `replay` spelling was a draft note); accept `replay` too for
            // forward compatibility.
            let encoded = try container.decodeIfPresent(String.self, forKey: .data)
                ?? container.decode(String.self, forKey: .replay)
            guard let bytes = Data(base64Encoded: encoded) else {
                throw CmuxProtocolError.malformedPayload("invalid resized replay base64")
            }
            self = try .resizedReplay(
                surface: container.decode(UInt64.self, forKey: .surface),
                columns: container.decode(UInt16.self, forKey: .cols),
                rows: container.decode(UInt16.self, forKey: .rows),
                bytes: bytes
            )
        case "colors-changed":
            let colors = try CmuxTerminalColors(from: decoder)
            self = try .colorsChanged(
                surface: container.decodeIfPresent(UInt64.self, forKey: .surface),
                colors: colors
            )
        case "detached":
            self = try .detached(surface: container.decode(UInt64.self, forKey: .surface))
        default:
            self = .other(name: name)
        }
    }
}
