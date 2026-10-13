import Foundation
import ImageIO
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

    /// Attachments are held in memory and sent base64 over the link.
    nonisolated static let maximumAttachmentBytes = 200 << 20

    nonisolated static func tooLargeMessage(_ name: String) -> String {
        String(localized: "\(name) is larger than 200 MB. Copy it to your Mac another way.")
    }

    func add(_ attachment: ComposerAttachment) {
        guard attachment.data.count <= Self.maximumAttachmentBytes else {
            error = Self.tooLargeMessage(attachment.name)
            return
        }
        attachments.append(attachment)
        Haptics.selection()
    }

    func remove(_ attachment: ComposerAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    @ObservationIgnored private var sendTask: Task<Void, Never>?

    /// Starts a send the user can cancel while attachments upload.
    func startSend(to session: TerminalSession, services: ServiceClient?) {
        guard canSend, sendTask == nil else { return }
        sendTask = Task {
            await send(to: session, services: services)
            sendTask = nil
        }
    }

    /// Stops an upload in progress; the draft and attachments stay.
    func cancelSend() {
        sendTask?.cancel()
        Haptics.selection()
    }

    /// Uploads, types and submits. Returns false (keeping the draft) on failure.
    @discardableResult
    func send(to session: TerminalSession, services: ServiceClient?) async -> Bool {
        guard canSend else { return false }
        // Input sent while the terminal (re)attaches is dropped; keep the
        // draft instead of clearing it as if it went through.
        guard session.phase == .live else {
            error = String(localized: "This terminal isn't connected yet. Your message is still here; try again in a moment.")
            return false
        }
        isSending = true
        defer { isSending = false; uploadProgress = nil }
        var paths: [String] = []
        if !attachments.isEmpty {
            guard let services else {
                error = String(localized: "Attachments need a connection to your Mac.")
                return false
            }
            // Progress by bytes across every attachment (a video dominates).
            let total = max(1, attachments.reduce(0) { $0 + $1.data.count })
            var done = 0
            uploadProgress = 0
            for attachment in attachments {
                do {
                    let base = done
                    let path = try await services.upload(name: attachment.name, data: attachment.data) { [weak self] sent in
                        Task { @MainActor in self?.uploadProgress = Double(base + sent) / Double(total) }
                    }
                    try Task.checkCancellation()
                    paths.append(path)
                    done += attachment.data.count
                } catch is CancellationError {
                    return false
                } catch {
                    if Task.isCancelled { return false }
                    self.error = String(localized: "Couldn't upload \(attachment.name): \(error.localizedDescription)")
                    return false
                }
            }
        }
        var message = Self.plainPunctuation(text.trimmingCharacters(in: .newlines))
        let submit = Self.submits(text: message, hasPaths: !paths.isEmpty, isTUI: session.isTUI)
        if !paths.isEmpty {
            message = Self.appendingPaths(paths, to: message)
            if !submit { message += " " }
        }
        if message.contains("\n") {
            session.paste(message)
        } else {
            session.send(text: message)
        }
        if submit { session.sendKeys(["enter"]) }
        text = ""
        attachments = []
        Haptics.tap()
        return true
    }

    /// Whether a send presses Return. Attachments alone at a shell prompt
    /// only type their paths (Return would run the file as a command), so
    /// the user can write the command around them; an agent's prompt (a
    /// full-screen program) and any typed text submit.
    nonisolated static func submits(text: String, hasPaths: Bool, isTUI: Bool) -> Bool {
        isTUI || !hasPaths || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The message with the uploaded paths after it, one space between
    /// ("file " + path never doubles the space).
    nonisolated static func appendingPaths(_ paths: [String], to message: String) -> String {
        let quoted = paths.map(shellQuoted).joined(separator: " ")
        guard !message.isEmpty else { return quoted }
        return message.last?.isWhitespace == true ? message + quoted : message + " " + quoted
    }

    /// A host path as one shell word: bare when it only has safe characters,
    /// otherwise single-quoted (an embedded `'` becomes `'\''`).
    nonisolated static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-~")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }), !path.hasPrefix("~") { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// iOS smart punctuation turns `--` into an em dash and quotes into
    /// curly ones; a shell needs the ASCII originals.
    static func plainPunctuation(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2014}", with: "--")
            .replacingOccurrences(of: "\u{2013}", with: "--")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// JPEG for image formats agents don't read (HEIC/HEIF, TIFF); nil keeps
    /// the original (PNG, JPEG, GIF, WebP).
    static func agentReadableImage(_ data: Data, ext: String) -> Data? {
        guard ["heic", "heif", "tif", "tiff"].contains(ext.lowercased()), let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.9)
    }

    /// The photo without its GPS location (the picker hands over the
    /// original, location included; it would end up in a file on the Mac
    /// and in whatever the agent uploads). Lossless: metadata only. Nil when
    /// there is no location to remove or the data isn't an image.
    nonisolated static func strippingLocation(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyGPSDictionary] != nil else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else { return nil }
        return output as Data
    }

    static func thumbnail(for data: Data, maxPixel: CGFloat = 240) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxPixel / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.jpegData(withCompressionQuality: 0.8) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
