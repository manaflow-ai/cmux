import CmuxiOSCloudCore
import SwiftUI

/// New machine: an optional name and a size from the plan. Locked sizes
/// stay visible and disabled (cloud-client-contract.md 1.5).
struct CloudCreateSheet: View {
    let options: CloudCreateOptions
    let create: (String, CloudSizeOption) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var selection: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(CloudText.name, text: $name, prompt: Text(CloudText.namePrompt))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("cloud.create.name")
                }
                Section {
                    ForEach(options.sizes) { option in
                        Button {
                            selection = option.memoryMB
                        } label: {
                            HStack {
                                Text(CloudText.memoryText(option.memoryMB))
                                    .foregroundStyle(option.isLocked ? .secondary : .primary)
                                Spacer()
                                if option.isLocked {
                                    Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                                } else if selected?.memoryMB == option.memoryMB {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                                }
                            }
                        }
                        .disabled(option.isLocked)
                        .accessibilityAddTraits(selected?.memoryMB == option.memoryMB ? .isSelected : [])
                    }
                } header: {
                    Text(CloudText.sizeHeader)
                } footer: {
                    if !options.hasRoom {
                        Text(CloudText.noRoom)
                    } else if options.sizes.contains(where: \.isLocked) {
                        Text(CloudText.lockedFooter)
                    }
                }
            }
            .navigationTitle(CloudText.newMachine)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CloudText.cancel, action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(CloudText.create) {
                        if let selected { create(name, selected) }
                    }
                    .disabled(!options.canCreate || selected == nil)
                    .accessibilityIdentifier("cloud.create.confirm")
                }
            }
        }
    }

    private var selected: CloudSizeOption? {
        if let selection, let option = options.sizes.first(where: { $0.memoryMB == selection && !$0.isLocked }) { return option }
        return options.defaultOption
    }
}
