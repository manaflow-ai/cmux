import SwiftUI
import UIKit

/// GitHub-grade diff viewer. Place inside a NavigationStack.
///
/// Rows are precomputed `AttributedString`s (parse, syntax highlight and
/// word diff off the main actor) rendered in a `LazyVStack` with pinned
/// file headers, so 10k-line diffs scroll without per-row work in `body`.
struct DiffView: View {
    enum LayoutPreference: String, CaseIterable, Identifiable {
        case automatic, unified, split
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: String(localized: "Automatic")
            case .unified: String(localized: "Unified")
            case .split: String(localized: "Split")
            }
        }
    }

    let title: String
    let onOpenFile: ((String) -> Void)?
    @State private var model: DiffViewModel
    @State private var offset = DiffHorizontalOffset()
    @AppStorage("diff.wrapLines") private var wrap = true
    @AppStorage("diff.layout") private var layout: LayoutPreference = .automatic
    @State private var viewportWidth: CGFloat = 390
    @State private var showFileList = false
    @State private var jumpTarget: Int?

    /// - Parameters:
    ///   - loader: returns unified diff text (`git diff` output).
    ///   - contextLoader: returns the new-side contents of a diff path, which
    ///     enables "Expand N hidden lines"; nil shows the counts only.
    ///   - onOpenFile: "View file" action for a diff path.
    init(
        loader: @escaping @Sendable () async throws -> String,
        title: String,
        contextLoader: (@Sendable (String) async throws -> String)? = nil,
        onOpenFile: ((String) -> Void)? = nil
    ) {
        self.title = title
        self.onOpenFile = onOpenFile
        _model = State(initialValue: DiffViewModel(loader: loader, contextLoader: contextLoader))
    }

    /// Split by default only when there is room (iPhone landscape, iPad).
    private var isSplit: Bool {
        switch layout {
        case .automatic: viewportWidth >= 640
        case .unified: false
        case .split: true
        }
    }

    private var metrics: DiffMetrics { DiffMetrics(digits: model.maxNumberDigits) }

    /// Content width: the viewport when wrapping, else wide enough for the
    /// longest expanded line (both sides in split).
    private var contentWidth: CGFloat {
        guard !wrap else { return viewportWidth }
        let gutter = isSplit ? metrics.numberWidth + 4 : (metrics.numberWidth + 4) * 2
        let side = gutter + DiffMetrics.markerWidth + DiffMetrics.textWidth(columns: model.maxColumns)
        return max(viewportWidth, isSplit ? side * 2 + 1 : side)
    }

    var body: some View {
        content
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { if model.files.isEmpty { await model.load() } }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            DiffLoadingState()
        case .failed(let message):
            DiffFailureState(title: String(localized: "Couldn't load diff"), message: message) {
                Task { await model.load() }
            }
        case .loaded where model.files.isEmpty:
            ScrollView {
                DiffEmptyState(symbol: "checkmark.circle", title: String(localized: "No changes"),
                               message: String(localized: "The working tree matches. Nothing to review."))
                    .containerRelativeFrame(.vertical)
            }
            .refreshable { await model.load() }
        case .loaded:
            diffList
        }
    }

    private var diffList: some View {
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    DiffPinnedWidth(offset: offset, width: viewportWidth) {
                        DiffSummaryView(
                            files: model.files,
                            showFileList: $showFileList,
                            jump: { jumpTarget = $0 }
                        )
                    }
                    ForEach(model.files) { file in
                        Section {
                            fileBody(file)
                        } header: {
                            DiffPinnedWidth(offset: offset, width: viewportWidth) {
                                DiffFileHeaderView(
                                    file: file,
                                    isCollapsed: model.isCollapsed(file),
                                    isViewed: model.viewed.contains(file.index),
                                    toggleCollapsed: { withAnimation(.snappy) { model.toggleCollapsed(file) } },
                                    toggleViewed: { Haptics.selection(); withAnimation(.snappy) { model.toggleViewed(file) } },
                                    openFile: onOpenFile.flatMap { open in file.status == .deleted ? nil : { open(file.path) } }
                                )
                            }
                        }
                    }
                    Color.clear.frame(height: 40)
                }
                .frame(width: contentWidth, alignment: .leading)
            }
            .scrollIndicators(.hidden, axes: .horizontal)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x + geometry.contentInsets.leading
            } action: { _, x in
                offset.x = max(0, x)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .refreshable { await model.load() }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                withAnimation(.snappy) { proxy.scrollTo(target, anchor: .top) }
                jumpTarget = nil
            }
        }
    }

    @ViewBuilder private func fileBody(_ file: DiffFile) -> some View {
        if model.isLarge(file) {
            DiffPinnedWidth(offset: offset, width: viewportWidth) {
                VStack(spacing: 10) {
                    Text(String(localized: "Large diff (\(file.lineCount) lines) is hidden"))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryInk)
                    Button(String(localized: "Load diff")) {
                        Task { await model.loadLarge(file) }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Theme.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        } else if !model.isCollapsed(file), let rendered = model.rendered[file.index] {
            let canExpand = model.contextLoader != nil && file.status != .deleted && !file.isBinary
            let isExpanding = model.expanding.contains(file.index)
            ForEach(isSplit ? rendered.split : rendered.unified) { row in
                DiffRowView(
                    row: row,
                    metrics: metrics,
                    wrap: wrap,
                    canExpand: canExpand,
                    isExpanding: isExpanding,
                    expand: { gap in Task { await model.expand(file, gap: gap) } }
                )
            }
        } else if !model.isCollapsed(file) {
            ProgressView()
                .frame(width: viewportWidth)
                .padding(.vertical, 16)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section(String(localized: "Jump to file")) {
                    ForEach(model.files) { file in
                        Button {
                            jumpTarget = file.index
                        } label: {
                            Label(file.path, systemImage: model.viewed.contains(file.index) ? "checkmark.square" : DiffFileIcon.symbol(for: file))
                        }
                    }
                }
            } label: {
                Label(String(localized: "Files"), systemImage: "list.bullet.indent")
            }
            .disabled(model.files.isEmpty)
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker(String(localized: "Layout"), selection: $layout) {
                    ForEach(LayoutPreference.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle(String(localized: "Wrap lines"), isOn: $wrap)
                Section {
                    Button(String(localized: "Expand all"), systemImage: "rectangle.expand.vertical") {
                        withAnimation(.snappy) { model.setAllCollapsed(false) }
                    }
                    Button(String(localized: "Collapse all"), systemImage: "rectangle.compress.vertical") {
                        withAnimation(.snappy) { model.setAllCollapsed(true) }
                    }
                }
            } label: {
                Label(String(localized: "Diff options"), systemImage: "slider.horizontal.3")
            }
        }
    }
}

/// The horizontal scroll offset, observed only by pinned-width chrome so
/// horizontal scrolling never invalidates the diff rows.
@MainActor
@Observable
final class DiffHorizontalOffset {
    var x: CGFloat = 0
}

/// Keeps chrome (headers, summary) at viewport width and visually fixed
/// while the diff body scrolls horizontally.
struct DiffPinnedWidth<Content: View>: View {
    let offset: DiffHorizontalOffset
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: width)
            .offset(x: offset.x)
    }
}

enum DiffFileIcon {
    static func symbol(for file: DiffFile) -> String {
        switch file.status {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .renamed: "arrow.right.square"
        case .copied: "plus.square.on.square"
        case .modified: file.isBinary ? "doc" : "plusminus"
        }
    }
}
