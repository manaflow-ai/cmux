import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import SwiftUI

/// The Cloud tab: usage, then machines by state. Actions are swipe actions
/// and a context menu; delete asks first; refusals show the owner's reason.
struct CloudView: View {
    @Bindable var model: CloudModel

    var body: some View {
        content
            .navigationTitle(CloudText.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isCreating = true
                    } label: {
                        Label(CloudText.newMachine, systemImage: "plus")
                    }
                    .disabled(!model.list.isLive || !model.options.canCreate)
                    .accessibilityIdentifier("cloud.new")
                }
            }
            .sheet(isPresented: $model.isCreating) {
                CloudCreateSheet(options: model.options, create: model.create, cancel: { model.isCreating = false })
            }
            .confirmationDialog(
                model.confirmingDelete.map { CloudText.deleteTitle($0.title.isEmpty ? CloudText.unnamed : $0.title) } ?? "",
                isPresented: Binding(get: { model.confirmingDelete != nil }, set: { if !$0 { model.confirmingDelete = nil } }),
                titleVisibility: .visible,
                presenting: model.confirmingDelete
            ) { row in
                Button(CloudText.action(.delete), role: .destructive) { model.confirmDelete(row) }
                Button(CloudText.cancel, role: .cancel) {}
            } message: { _ in
                Text(CloudText.deleteMessage)
            }
            .alert(CloudText.failedTitle, isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }),
                   presenting: model.notice) { _ in
                Button(CloudText.ok, role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
            .task { await model.run() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.list.isLoaded {
            if case .offline = model.connection {
                ContentUnavailableView(CloudText.offlineTitle, systemImage: "icloud.slash", description: Text(CloudText.offlineBody))
            } else {
                ProgressView(CloudText.loading)
            }
        } else {
            List {
                if model.isMock {
                    Text(CloudText.mockData).font(.footnote).foregroundStyle(.secondary)
                }
                if !model.list.isLive {
                    Label(CloudText.offlineBody, systemImage: "icloud.slash").foregroundStyle(.secondary)
                }
                if let usage = model.list.usage {
                    Section(CloudText.usage) { CloudUsageView(usage: usage) }
                }
                ForEach(model.list.sections) { section in
                    Section(CloudText.section(section.kind)) {
                        ForEach(section.rows) { row in
                            CloudMachineRowView(row: row)
                                .swipeActions(edge: .trailing) { buttons(for: row) }
                                .contextMenu { buttons(for: row) }
                                .accessibilityIdentifier("cloud.machine.\(row.id)")
                        }
                    }
                }
            }
            .overlay {
                if model.list.isEmpty {
                    ContentUnavailableView(CloudText.emptyTitle, systemImage: "cloud", description: Text(CloudText.emptyBody))
                }
            }
        }
    }

    @ViewBuilder
    private func buttons(for row: CloudMachineRow) -> some View {
        ForEach(row.actions, id: \.self) { action in
            Button(role: action.isDestructive ? .destructive : nil) {
                model.run(action, on: row)
            } label: {
                Label(CloudText.action(action), systemImage: symbol(action))
            }
        }
    }

    private func symbol(_ action: CloudMachineAction) -> String {
        switch action {
        case .resume: "play.fill"
        case .pause: "pause.fill"
        case .delete: "trash"
        }
    }
}
