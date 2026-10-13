#if os(iOS)
import CnxDesign
import SwiftUI
import UIKit

/// Viewer preferences shared by the file list and file screens (SPEC 12.1 `ellipsis` menu).
@MainActor
@Observable
public final class DiffViewerState {
    public enum Layout: String, CaseIterable, Sendable { case unified = "Unified", split = "Split" }

    public var changeSet: DiffChangeSet
    public var layout: Layout = .unified
    public var wrapLines = false
    public var hideWhitespace = false
    public var showViewed = true
    public var viewed: Set<String> = []

    public init(changeSet: DiffChangeSet) {
        self.changeSet = changeSet
    }

    public func toggleViewed(_ file: DiffFile) {
        if viewed.contains(file.id) { viewed.remove(file.id) } else { viewed.insert(file.id) }
    }
}

/// SPEC 12.1: the Changes file list (GitHub mobile style).
public struct DiffChangesScreen: View {
    @State private var state: DiffViewerState
    /// The open file. State driven, not `NavigationLink(value:)`: this screen
    /// is pushed inside stacks with a typed path (the workspace's
    /// `[Workspace]`), where a value of another type is never pushed.
    @State private var openFile: DiffFileRoute?

    public init(changeSet: DiffChangeSet) {
        _state = State(initialValue: DiffViewerState(changeSet: changeSet))
    }

    public var body: some View {
        List {
            Section {
                summary
                    .listRowSeparator(.hidden, edges: .top)
                ForEach(visibleFiles) { file in
                    HStack(spacing: 8) {
                        DiffFileRow(file: file, isViewed: state.viewed.contains(file.id)) {
                            withAnimation(.cnxSnap) { state.toggleViewed(file) }
                        }
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                    .onTapGesture { openFile = DiffFileRoute(fileID: file.id) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openFile = DiffFileRoute(fileID: file.id) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Changes").font(.headline)
                    Text("\(state.changeSet.subtitle) · \(Self.files(state.changeSet.files.count))").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { DiffOptionsMenu(state: state) }
        }
        .navigationDestination(item: $openFile) { route in
            DiffFileScreen(state: state, fileID: route.fileID)
        }
    }

    static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

    private var visibleFiles: [DiffFile] {
        state.showViewed ? state.changeSet.files : state.changeSet.files.filter { !state.viewed.contains($0.id) }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Self.files(state.changeSet.files.count)) changed").font(.headline)
            HStack(spacing: 8) {
                DiffCounts(additions: state.changeSet.additions, deletions: state.changeSet.deletions)
                DiffStatBar(additions: state.changeSet.additions, deletions: state.changeSet.deletions)
                Spacer()
                Text("\(state.viewed.count) of \(state.changeSet.files.count) viewed").font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 6)
    }
}

struct DiffFileRoute: Hashable, Identifiable {
    var id: String { fileID }
    let fileID: String
}

/// `+12 −4` in diff colors.
public struct DiffCounts: View {
    let additions: Int
    let deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(Color.cnxDiffAddText)
            Text("−\(deletions)").foregroundStyle(Color.cnxDiffDelText)
        }
        .font(.footnote.monospacedDigit().weight(.medium))
        .accessibilityElement()
        .accessibilityLabel(Text("\(additions) additions, \(deletions) deletions"))
    }
}

/// GitHub's five squares.
struct DiffStatBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = max(additions + deletions, 1)
        let green = Int((Double(additions) / Double(total) * 5).rounded())
        let red = min(5 - green, Int((Double(deletions) / Double(total) * 5).rounded()))
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < green ? Color.cnxDiffAddText : (index < green + red ? Color.cnxDiffDelText : Color.cnxFillSelected))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let status: DiffFile.Status

    var body: some View {
        Text(status.rawValue)
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .background(color.opacity(0.18), in: .rect(cornerRadius: 5))
            .accessibilityLabel(Text(label))
    }

    private var color: Color {
        switch status {
        case .modified: .cnxWarning
        case .added: .cnxSuccess
        case .deleted: .cnxDanger
        case .renamed: .secondary
        }
    }

    private var label: String {
        switch status {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
    }
}

struct DiffFileRow: View {
    let file: DiffFile
    let isViewed: Bool
    let toggleViewed: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(status: file.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName).font(.body).lineLimit(1)
                if !file.directory.isEmpty {
                    Text(file.directory).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            DiffCounts(additions: file.additions, deletions: file.deletions)
            ViewedToggle(isViewed: isViewed, action: toggleViewed)
        }
        .frame(minHeight: 44)
        .opacity(isViewed ? 0.6 : 1)
    }
}

struct ViewedToggle: View {
    let isViewed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(isViewed ? Color.cnxSuccess : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isViewed ? "Viewed" : "Mark as viewed")
        .sensoryFeedback(.selection, trigger: isViewed)
    }
}

struct DiffOptionsMenu: View {
    @Bindable var state: DiffViewerState

    var body: some View {
        Menu {
            Picker("Layout", selection: $state.layout) {
                ForEach(DiffViewerState.Layout.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.inline)
            Toggle("Wrap lines", systemImage: "text.word.spacing", isOn: $state.wrapLines)
            Toggle("Hide whitespace", systemImage: "space", isOn: $state.hideWhitespace)
            Toggle("Show viewed files", systemImage: "checkmark.circle", isOn: $state.showViewed)
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Diff options")
    }
}
#endif
