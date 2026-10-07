import CmuxiOSFeatureKit
import CmuxiOSOnboardingCore
import SwiftUI

/// Optional step after pairing (lane E5, behind `keepAwake`): one toggle per
/// trusted Mac that supports keep-awake. Each toggle is an intent with a
/// receipt; a refusal shows inline and the toggle returns to the Mac's value.
struct KeepAwakeStep: View {
    let model: OnboardingModel
    @State private var devices: [DeviceRecord] = []
    @State private var reports: [HostID: KeepAwakeReport] = [:]
    @State private var pending: Set<HostID> = []
    @State private var error: String?

    private var macs: [KeepAwakeCardMac] { KeepAwakeCardProjection(devices: devices, reports: reports).macs }

    var body: some View {
        OnboardingStepScaffold(title: KeepAwakeStepText.title, message: KeepAwakeStepText.body) {
            VStack(spacing: 14) {
                Image(systemName: "cup.and.saucer")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(OnboardingColors.secondaryText)
                    .accessibilityHidden(true)
                if macs.isEmpty {
                    Text(KeepAwakeStepText.noMacs)
                        .font(.footnote)
                        .foregroundStyle(OnboardingColors.secondaryText)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(macs) { mac in
                            row(mac)
                            if mac.id != macs.last?.id { Divider().padding(.leading, 14) }
                        }
                    }
                    .background(OnboardingColors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let error {
                    Text(verbatim: error)
                        .font(.footnote)
                        .foregroundStyle(OnboardingColors.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
        } footer: {
            Button(OnboardingText.continueTitle) { model.advance() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.keepAwake.continue")
            Button(OnboardingText.skip) { model.skipStep() }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .accessibilityIdentifier("onboarding.keepAwake.skip")
        }
        // Mirrors the registry and the Macs' reports while the step is visible.
        .task { for await snapshot in await model.dependencies.devices.updates() { devices = snapshot.value } }
        .task {
            guard let hook = model.dependencies.keepAwake else { return }
            for await value in await hook.reports() { reports = value }
        }
    }

    @ViewBuilder private func row(_ mac: KeepAwakeCardMac) -> some View {
        switch mac.availability {
        case .available(let isOn):
            Toggle(mac.name, isOn: Binding(get: { isOn }, set: { next in Task { await set(mac.id, next) } }))
                .disabled(pending.contains(mac.id))
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .accessibilityIdentifier("onboarding.keepAwake." + mac.id.rawValue)
        case .checking, .unavailable:
            LabeledContent(mac.name) {
                Text(mac.availability == .checking ? KeepAwakeStepText.checking : KeepAwakeStepText.unavailable)
                    .foregroundStyle(OnboardingColors.secondaryText)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
        }
    }

    private func set(_ host: HostID, _ enabled: Bool) async {
        guard let hook = model.dependencies.keepAwake, !pending.contains(host) else { return }
        pending.insert(host)
        error = nil
        let refusal = await hook.set(host, enabled)
        pending.remove(host)
        if let refusal {
            error = refusal
            model.haptics.warning()
        } else {
            model.choose(enabled ? "on" : "off")
        }
    }
}
