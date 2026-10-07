import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import SwiftUI

/// Devices & Macs: this device, Macs and Cloud machines, other devices. Each
/// row opens its detail (rename, connection, remove).
struct DevicesSection: View {
    let model: DeviceSettingsModel

    var body: some View {
        let sections = model.sections
        if sections.isEmpty {
            Section {
                Text(SettingsText.noDevices)
                    .foregroundStyle(.secondary)
            } header: {
                Text(SettingsText.devices)
            } footer: {
                offlineFooter
            }
        }
        ForEach(sections) { section in
            Section {
                ForEach(section.devices) { device in
                    NavigationLink {
                        DeviceDetailView(model: model, deviceID: device.id)
                    } label: {
                        DeviceRow(device: device, badge: model.badge(for: device.id))
                    }
                    .accessibilityIdentifier("shell.settings.device." + device.id)
                }
            } header: {
                Text(SettingsText.title(of: section.kind))
            } footer: {
                if section.id == sections.last?.id { offlineFooter }
            }
        }
    }

    @ViewBuilder private var offlineFooter: some View {
        if !model.connection.isLive {
            Text(SettingsText.devicesOffline)
        }
    }
}
