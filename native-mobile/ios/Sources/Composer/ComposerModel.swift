import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// A file waiting to be sent with the next message.
struct ComposerAttachment: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable { case image, video, file }
    let id = UUID()
    var name: String
    var data: Data
    var kind: Kind
    var thumbnail: Data?

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// The GUI input box for a terminal: text plus attachments. Sending uploads
/// attachments to the Mac first, then types the message with the uploaded
/// paths appended, then presses Return; agents like Claude Code and Codex
/// pick up file paths typed into their prompt.
@MainActor
@Observable
final class ComposerModel {
    var text = ""
    var attachments: [ComposerAttachment] = []
    private(set) var isSending = false
    private(set) var uploadProgress: Double?
    var error: String?

    var canSend: Bool { !isSending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    func add(_ attachment: ComposerAttachment) {
        attachments.append(attachment)
        Haptics.selection()
    }

    func remove(_ attachment: ComposerAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// Uploads, types and submits. Returns false (keeping the draft) on failure.
    @discardableResult
    func send(to session: TerminalSession, services: ServiceClient?) async -> Bool {
        guard canSend else { return false }
        isSending = true
        defer { isSending = false; uploadProgress = nil }
        var paths: [String] = []
        if !attachments.isEmpty {
            guard let services else {
                error = String(localized: "Attachments need a connection to your Mac.")
                return false
            }
            for (index, attachment) in attachments.enumerated() {
                uploadProgress = Double(index) / Double(attachments.count)
                do {
                    paths.append(try await services.upload(name: attachment.name, data: attachment.data))
                } catch {
                    self.error = String(localized: "Couldn't upload \(attachment.name): \(error.localizedDescription)")
                    return false
                }
            }
        }
        var message = Self.plainPunctuation(text.trimmingCharacters(in: .newlines))
        if !paths.isEmpty {
            let quoted = paths.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
            message = message.isEmpty ? quoted : message + " " + quoted
        }
        if message.contains("\n") {
            session.paste(message)
        } else {
            session.send(text: message)
        }
        session.sendKeys(["enter"])
        text = ""
        attachments = []
        Haptics.tap()
        return true
    }

    /// iOS smart punctuation turns `--` into an em dash and quotes into
    /// curly ones; a shell needs the ASCII originals.
    static func plainPunctuation(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2014}", with: "--")
            .replacingOccurrences(of: "\u{2013}", with: "--")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
    }

    static func thumbnail(for data: Data, maxPixel: CGFloat = 240) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxPixel / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.jpegData(withCompressionQuality: 0.8) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
