import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import CmuxLink
import SwiftUI

/// One device: rename, facts, live connection (path, carrier, RTT) and
/// Remove with a destructive confirmation. Changes need a live registry.
struct DeviceDetailView: View {
    @Bindable var model: DeviceSettingsModel
    let deviceID: DeviceRecord.ID
    @State private var draftName = ""
    @State private var confirmingRemove = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let device = model.device(deviceID) {
                form(device)
            } else {
                ContentUnavailableView(SettingsText.deviceRemoved, systemImage: "checkmark.circle")
            }
        }
        .task { await model.observe() }
        .alert(
            SettingsText.deviceActionFailed,
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
            presenting: model.actionError
        ) { _ in
            Button(SettingsText.ok, role: .cancel) {}
        } message: { error in
            Text(SettingsText.message(for: error))
        }
    }

    private func form(_ device: DeviceRecord) -> some View {
        Form {
            Section {
                TextField(SettingsText.deviceName, text: $draftName)
                    .submitLabel(.done)
                    .onSubmit { rename(device) }
                    .disabled(!model.connection.isLive || model.pendingDeviceID != nil)
                    .accessibilityIdentifier("shell.settings.deviceName")
            } header: {
                Text(SettingsText.deviceName)
            } footer: {
                if !model.connection.isLive { Text(SettingsText.devicesOffline) }
            }
            Section {
                LabeledContent(SettingsText.kind, value: SettingsText.title(of: device.platform))
                LabeledContent(SettingsText.statusLabel, value: SettingsText.trustTitle(device))
                LabeledContent(SettingsText.lastSeen) {
                    Text(device.lastSeen.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? SettingsText.never)
                }
            }
            Section(SettingsText.connection) {
                if let badge = model.badge(for: device.id) {
                    LabeledContent(SettingsText.path, value: SettingsText.title(of: badge.path.kind))
                    LabeledContent(SettingsText.carrier, value: badge.path.carrier.rawValue)
                    LabeledContent(SettingsText.roundTrip, value: SettingsText.milliseconds(badge.rttMilliseconds))
                } else {
                    Text(SettingsText.notConnected)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if device.isThisDevice {
                    Text(SettingsText.signOutToRemove)
                        .foregroundStyle(.secondary)
                } else {
                    Button(SettingsText.removeDevice, role: .destructive) { confirmingRemove = true }
                        .disabled(!model.connection.isLive || model.pendingDeviceID != nil)
                        .accessibilityIdentifier("shell.settings.removeDevice")
                }
            } footer: {
                if !device.isThisDevice { Text(SettingsText.removeDeviceFooter) }
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draftName = device.name }
        .confirmationDialog(SettingsText.removeDeviceConfirm(device.name), isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button(SettingsText.removeDevice, role: .destructive) {
                Task { if await model.revoke(deviceID) { dismiss() } }
            }
        }
    }

    private func rename(_ device: DeviceRecord) {
        let name = draftName
        Task {
            if !(await model.rename(device.id, to: name)) {
                draftName = model.device(device.id)?.name ?? device.name
            }
        }
    }
}
