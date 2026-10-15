#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

/// The pickers behind the tab menu's Move Tab to Workspace…, Add Tab to Group…, the tab's
/// group actions (the Mac's group chip menu) and Rename Tab Group….
struct TabMoveAndGroupSheets: ViewModifier {
    let source: WorkspaceTabsSource
    @Binding var groupName: String

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { source.movingTab }, set: { source.movingTab = $0 })) { tab in
                WorkspacePicker(tab: tab, workspaces: source.otherWorkspaces) { destination in
                    Task { await source.move(tab.id, to: destination) }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: { source.addingToGroupTab }, set: { source.addingToGroupTab = $0 })) { tab in
                TabGroupPicker(groups: source.groups(besides: tab)) { group in
                    Task { await source.editGroup(.add(group: group.id), tab.id) }
                }
                .presentationDetents([.medium])
            }
            .confirmationDialog(source.groupActionsTab?.group?.displayName ?? "Tab Group", isPresented: Binding(
                get: { source.groupActionsTab != nil },
                set: { shown in if !shown { source.groupActionsTab = nil } }
            ), titleVisibility: .visible, presenting: source.groupActionsTab) { tab in
                Button(TabGroupEdit.rename("").title) {
                    groupName = ""
                    source.renamingGroupTab = tab
                    source.groupActionsTab = nil
                }
                if tab.group?.isSaved == true {
                    Button(TabGroupEdit.unsave.title) { Task { await source.editGroup(.unsave, tab.id) } }
                } else {
                    Button(TabGroupEdit.save.title) { Task { await source.editGroup(.save, tab.id) } }
                }
                Button(TabGroupEdit.ungroup.title) { Task { await source.editGroup(.ungroup, tab.id) } }
                Button(TabGroupEdit.close.title, role: .destructive) { Task { await source.editGroup(.close, tab.id) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename Tab Group", isPresented: Binding(
                get: { source.renamingGroupTab != nil },
                set: { shown in if !shown { source.renamingGroupTab = nil } }
            ), presenting: source.renamingGroupTab) { tab in
                TextField(tab.group?.name.isEmpty == false ? tab.group!.name : "Name", text: $groupName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { Task { await source.editGroup(.rename(groupName), tab.id) } }
            }
    }
}

/// Move Tab to Workspace…: the other workspaces on this Mac.
struct WorkspacePicker: View {
    let tab: WorkspaceTab
    let workspaces: [Workspace]
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(workspaces) { workspace in
                Button {
                    dismiss()
                    pick(workspace.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.title).foregroundStyle(.primary)
                        if !workspace.directory.isEmpty {
                            Text(workspace.directory).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
                .accessibilityIdentifier("move-to.\(workspace.id)")
            }
            .navigationTitle("Move Tab to Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Add Tab to Group…: the groups of this workspace.
struct TabGroupPicker: View {
    let groups: [WorkspaceTab.TabGroupRef]
    let pick: (WorkspaceTab.TabGroupRef) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(groups, id: \.id) { group in
                Button {
                    dismiss()
                    pick(group)
                } label: {
                    HStack {
                        Circle().fill(TabGroupChip.color(group.color)).frame(width: 10, height: 10)
                        Text(group.displayName).foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Add Tab to Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

#endif
