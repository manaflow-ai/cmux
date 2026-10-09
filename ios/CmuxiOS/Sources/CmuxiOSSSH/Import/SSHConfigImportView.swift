import CmuxiOSFeatureKit
import CmuxiOSSSHCore
import SwiftUI
import UIKit

/// Paste a `~/.ssh/config` snippet and pick the hosts to add.
struct SSHConfigImportView: View {
    @Bindable var model: SSHConfigImportModel

    var body: some View {
        Form {
            Section {
                TextEditor(text: $model.text)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 140)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ssh.import.text")
                Button(SSHText.importPaste, systemImage: "doc.on.clipboard") {
                    if let pasted = UIPasteboard.general.string { model.text = pasted }
                }
            } footer: {
                Text(SSHText.importPrompt)
            }
            if !model.text.isEmpty {
                Section(SSHText.importFound) {
                    if model.plan.items.isEmpty {
                        Text(SSHText.importNone).foregroundStyle(.secondary)
                    }
                    ForEach(model.plan.items) { item in
                        Button { model.toggle(item) } label: {
                            HStack {
                                Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selected.contains(item.id) ? .primary : .tertiary)
                                    // The isSelected trait below carries the state.
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.entry.alias).foregroundStyle(.primary)
                                    Text(Self.detail(item)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityAddTraits(model.selected.contains(item.id) ? .isSelected : [])
                    }
                }
            }
            if let message = model.message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(SSHText.importTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(SSHText.cancel) { model.dismiss?() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(format: SSHText.importAction, Int64(model.selectedCount))) { Task { await model.commit() } }
                    .disabled(model.selectedCount == 0 || model.isWorking)
                    .accessibilityIdentifier("ssh.import.commit")
            }
        }
    }

    private static func detail(_ item: SSHConfigImport.Item) -> String {
        var parts: [String] = []
        if case .ssh(let endpoint, _) = item.draft.kind { parts.append(HostsRow.describe(endpoint)) }
        if let jump = item.entry.proxyJump, item.unresolvedJump == nil { parts.append(String(format: SSHText.viaJump, jump)) }
        if let unresolved = item.unresolvedJump { parts.append(String(format: SSHText.importUnresolved, unresolved)) }
        if item.duplicateOf != nil { parts.append(SSHText.importDuplicate) }
        return parts.joined(separator: " · ")
    }
}
