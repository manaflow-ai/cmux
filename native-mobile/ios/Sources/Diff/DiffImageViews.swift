import ImageIO
import SwiftUI
import UIKit

/// Where each side of an image diff comes from, by diff scope (GitHub shows
/// changed images as a before/after pair instead of "Binary file not shown").
enum DiffImageSource: Equatable, Sendable {
    /// `git.show`: the file at a commit-ish, or in the index when `rev` is nil.
    case git(path: String, rev: String?)
    /// The working-tree file (`fs.read`).
    case disk(path: String)

    static func plan(_ file: DiffFile, scope: DiffScope) -> (old: DiffImageSource?, new: DiffImageSource?) {
        let oldPath = file.oldPath ?? file.path
        let old: DiffImageSource
        let new: DiffImageSource
        switch scope {
        case .workingTree:
            old = .git(path: oldPath, rev: nil)
            new = .disk(path: file.path)
        case .staged:
            old = .git(path: oldPath, rev: "HEAD")
            new = .git(path: file.path, rev: nil)
        case .base(let ref):
            old = .git(path: oldPath, rev: ref)
            new = .disk(path: file.path)
        }
        return (file.status == .added ? nil : old, file.status == .deleted ? nil : new)
    }

    /// Binary files whose extension is a raster image.
    static func isPreviewable(_ file: DiffFile) -> Bool {
        file.isBinary && FilePreviewKind.detect(path: file.path) == .image
    }
}

/// Loads one side of an image diff: bytes, or nil when that side doesn't exist.
typealias DiffImageLoader = @Sendable (DiffImageSource) async throws -> Data

/// Before/after cards for a changed image, stacked for a phone's width.
struct DiffImagePairView: View {
    let file: DiffFile
    let plan: (old: DiffImageSource?, new: DiffImageSource?)
    let loader: DiffImageLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let old = plan.old {
                DiffImageCard(title: String(localized: "Before"), tint: DiffColors.delText, source: old, loader: loader)
            }
            if let new = plan.new {
                DiffImageCard(title: String(localized: "After"), tint: DiffColors.addText, source: new, loader: loader)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiffImageCard: View {
    let title: String
    let tint: Color
    let source: DiffImageSource
    let loader: DiffImageLoader

    @State private var image: UIImage?
    @State private var info: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(tint)
                if let info { Text(info).font(.footnote).foregroundStyle(Theme.secondaryInk) }
            }
            ZStack {
                CheckerboardBackground()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Theme.secondaryInk).padding()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 280)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.6), lineWidth: 1.5))
            .accessibilityElement()
            .accessibilityLabel(Text("\(title), \(info ?? "")"))
        }
        .task(id: source) { await load() }
    }

    private func load() async {
        do {
            let data = try await loader(source)
            let decoded = await Task.detached { DiffImageDecoder.decode(data) }.value
            guard let decoded else {
                failure = String(localized: "Can't show this image")
                return
            }
            image = decoded.image
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            info = "\(decoded.width) × \(decoded.height) · \(size)"
        } catch {
            failure = error.localizedDescription
        }
    }
}

enum DiffImageDecoder {
    /// Decodes at most 1600 px on the long side (a 12 MP screenshot would
    /// otherwise hold ~50 MB per card); reports the original pixel size.
    static func decode(_ data: Data) -> (image: UIImage, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (UIImage(cgImage: cg), width, height)
    }
}

/// Shows transparency, like GitHub's image diff.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            let dark = Color(uiColor: .tertiarySystemFill)
            for row in 0..<Int(ceil(size.height / cell)) {
                for col in 0..<Int(ceil(size.width / cell)) where (row + col).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(dark))
                }
            }
        }
    }
}
