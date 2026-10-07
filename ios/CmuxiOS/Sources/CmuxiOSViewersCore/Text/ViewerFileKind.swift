import Foundation

/// Which viewer shows a file.
public enum ViewerFileKind: Hashable, Sendable {
    case text(SyntaxLanguage)
    case markdown
    case image
    case pdf
    /// Anything else: QuickLook.
    case other

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico"]
    static let otherExtensions: Set<String> = [
        "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "dmg", "pkg", "ipa", "app", "a", "o", "so", "dylib", "exe", "bin",
        "mp3", "m4a", "wav", "aac", "flac", "mp4", "mov", "m4v", "avi", "mkv", "key", "pages", "numbers", "docx", "xlsx",
        "pptx", "doc", "xls", "ppt", "rtf", "usdz", "sqlite", "db",
    ]

    /// Classifies by name, then MIME, then content: a NUL byte in the first
    /// 8000 bytes means binary (`other`).
    public static func classify(name: String, mime: String? = nil, prefix: Data? = nil) -> ViewerFileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" || ext == "mdx" { return .markdown }
        if ext == "pdf" || mime == "application/pdf" { return .pdf }
        if imageExtensions.contains(ext) || (mime?.hasPrefix("image/") == true && mime != "image/svg+xml") { return .image }
        if otherExtensions.contains(ext) { return .other }
        if let prefix, prefix.prefix(8000).contains(0) { return .other }
        let language = SyntaxLanguage.detect(fileName: name)
        if language != .plain { return .text(language) }
        if let mime, !mime.hasPrefix("text/"), mime != "application/json", mime != "application/octet-stream", prefix == nil {
            return .other
        }
        return .text(.plain)
    }
}
