import SwiftUI
import UIKit

/// "N files changed  +A −D ▮▮▮▯▯" plus a collapsible file list.
struct DiffSummaryView: View {
    let files: [DiffFile]
    @Binding var showFileList: Bool
    let jump: (Int) -> Void

    var body: some View {
        let additions = files.totalAdditions
        let deletions = files.totalDeletions
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { showFileList.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(files.count == 1
                        ? String(localized: "1 file changed")
                        : String(localized: "\(files.count) files changed"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    DiffCountsLabel(additions: additions, deletions: deletions)
                    DiffStatBar(additions: additions, deletions: deletions)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryInk)
                        .rotationEffect(.degrees(showFileList ? 0 : -90))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(showFileList ? String(localized: "Hides the file list") : String(localized: "Shows the file list"))

            if showFileList {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        Button { jump(file.index) } label: {
                            HStack(spacing: 10) {
                                DiffStatusBadge(status: file.status, isBinary: file.isBinary && !DiffImageSource.isPreviewable(file))
                                DiffPathText.make(directory: file.directory, name: file.fileName, bold: false)
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 8)
                                DiffCountsLabel(additions: file.additions, deletions: file.deletions, font: Theme.mono(11, weight: .medium))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .background(Theme.background)
    }
}

/// Pinned per-file header: chevron, status, path, counts, Viewed, more menu.
struct DiffFileHeaderView: View {
    let file: DiffFile
    let isCollapsed: Bool
    let isViewed: Bool
    let toggleCollapsed: () -> Void
    let toggleViewed: () -> Void
    let openFile: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleCollapsed) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryInk)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: 14)
                    DiffStatusBadge(status: file.status, isBinary: file.isBinary && !DiffImageSource.isPreviewable(file))
                    VStack(alignment: .leading, spacing: 1) {
                        DiffPathText.make(directory: file.directory, name: file.fileName, bold: true)
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if let oldPath = file.oldPath {
                            Text(String(localized: "from \(oldPath)"))
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiaryInk)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 4)
                    if !file.isBinary {
                        DiffCountsLabel(additions: file.additions, deletions: file.deletions, font: Theme.mono(11, weight: .semibold))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.path)
            .accessibilityValue(isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded"))

            Button(action: toggleViewed) {
                Image(systemName: isViewed ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isViewed ? Theme.ink : Theme.secondaryInk)
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Viewed"))
            .accessibilityAddTraits(isViewed ? .isSelected : [])

            Menu {
                Button(String(localized: "Copy path"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = file.path
                    Haptics.success()
                }
                if let openFile {
                    Button(String(localized: "View file"), systemImage: "doc.text", action: openFile)
                }
                Button(isCollapsed ? String(localized: "Expand") : String(localized: "Collapse"),
                       systemImage: isCollapsed ? "chevron.down" : "chevron.up", action: toggleCollapsed)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .accessibilityLabel(String(localized: "More"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Theme.elevated)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
    }
}

/// "dir/" in secondary ink followed by the file name.
enum DiffPathText {
    static func make(directory: String, name: String, bold: Bool) -> Text {
        let dir = Text(verbatim: directory).foregroundStyle(Theme.secondaryInk)
        let file = Text(verbatim: name).foregroundStyle(Theme.ink).fontWeight(bold ? .semibold : .regular)
        return Text("\(dir)\(file)")
    }
}
