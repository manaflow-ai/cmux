public import CmuxiOSFeatureKit
import CmuxiOSPlatform
public import SwiftUI

/// The Keep Mac Awake toggle for one Mac, for the host detail screen
/// (C11/B6 own that screen; this is the stub they embed).
public struct KeepAwakeRow: View {
    let host: HostID
    let name: String
    @Bindable var model: KeepAwakeModel

    public init(host: HostID, name: String, model: KeepAwakeModel) {
        self.host = host
        self.name = name
        self.model = model
    }

    public var body: some View {
        let state = model.states[host]
        let usable = model.connection.isLive && state?.isSupported == true && !model.busy.contains(host)
        Toggle(isOn: Binding(
            get: { state?.isEnabled ?? false },
            set: { value in Task { await model.set(host, enabled: value) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Label(PlatformText.keepAwakeTitle, systemImage: "cup.and.saucer")
                Text(status(state)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(!usable)
        .accessibilityIdentifier("platform.keepAwake." + host.rawValue)
    }

    private func status(_ state: KeepAwakeState?) -> String {
        guard model.connection.isLive else { return PlatformText.keepAwakeOffline }
        guard let state, state.isSupported else { return PlatformText.keepAwakeUnsupported(name) }
        switch state.isEnabled {
        case true?: return PlatformText.keepAwakeOn(name)
        case false?: return PlatformText.keepAwakeOff(name)
        case nil: return PlatformText.keepAwakeChecking
        }
    }
}
