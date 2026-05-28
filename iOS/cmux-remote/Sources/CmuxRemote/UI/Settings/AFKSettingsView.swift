import SwiftUI
import CmuxKit

struct AFKSettingsView: View {
    @EnvironmentObject var store: AFKPolicyStore

    var body: some View {
        Form {
            Section(L10n.string("afk.section.auto_handle", defaultValue: "Auto-handle")) {
                ForEach(store.policy.autoApproveRules) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rule.label).font(.headline)
                            Text(actionLabel(rule.action)).font(.caption).foregroundStyle(.secondary)
                            if let regex = rule.match.commandRegex {
                                Text(regex).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            } else if let regex = rule.match.toolNameRegex {
                                Text(regex).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Toggle(rule.label, isOn: Binding(
                            get: { rule.enabled },
                            set: { newValue in
                                store.update { policy in
                                    if let idx = policy.autoApproveRules.firstIndex(where: { $0.id == rule.id }) {
                                        policy.autoApproveRules[idx].enabled = newValue
                                    }
                                }
                            }
                        ))
                        .labelsHidden()
                        .accessibilityLabel(Text(rule.label))
                    }
                }
                .onDelete { indices in
                    store.update { policy in
                        policy.autoApproveRules.remove(atOffsets: indices)
                    }
                }
            }
            Section(L10n.string("afk.section.watchdog", defaultValue: "Watchdog")) {
                Stepper(
                    L10n.format(
                        "afk.watchdog.alert_after",
                        defaultValue: "Alert if stuck %lld min",
                        Int64(store.policy.watchdogStuckMinutes)
                    ),
                    value: Binding(
                        get: { store.policy.watchdogStuckMinutes },
                        set: { newValue in store.update { $0.watchdogStuckMinutes = newValue } }
                    ),
                    in: 1...60
                )
                Toggle(L10n.string("afk.watchdog.notify", defaultValue: "Notify when stuck"), isOn: Binding(
                    get: { store.policy.notifyOnStuck },
                    set: { newValue in store.update { $0.notifyOnStuck = newValue } }
                ))
            }
            Section(L10n.string("afk.section.snooze", defaultValue: "Snooze")) {
                Stepper(
                    L10n.format(
                        "afk.snooze.default_minutes",
                        defaultValue: "Default %lld min",
                        Int64(store.policy.snoozeMinutes)
                    ),
                    value: Binding(
                        get: { store.policy.snoozeMinutes },
                        set: { newValue in store.update { $0.snoozeMinutes = newValue } }
                    ),
                    in: 1...120
                )
            }
            Section(L10n.string("afk.section.security", defaultValue: "Security")) {
                Toggle(L10n.string("afk.security.require_face_id", defaultValue: "Require Face ID for destructive actions"), isOn: Binding(
                    get: { store.policy.requireBiometricForDestructive },
                    set: { newValue in store.update { $0.requireBiometricForDestructive = newValue } }
                ))
            }
            Section(L10n.string("afk.section.summary", defaultValue: "AFK summary")) {
                Stepper(
                    L10n.format(
                        "afk.summary.daily_digest_time",
                        defaultValue: "Send daily digest at %02lld:00",
                        Int64(store.policy.afkSummaryHour)
                    ),
                    value: Binding(
                        get: { store.policy.afkSummaryHour },
                        set: { newValue in store.update { $0.afkSummaryHour = newValue } }
                    ),
                    in: 0...23
                )
            }
        }
        .navigationTitle(L10n.string("afk.title", defaultValue: "Away From Keyboard"))
    }

    private func actionLabel(_ action: AFKPolicy.Action) -> String {
        switch action {
        case .autoApprove: return L10n.string("afk.action.auto_approve", defaultValue: "Auto-approve")
        case .autoDeny: return L10n.string("afk.action.auto_deny", defaultValue: "Auto-deny")
        case .alwaysAskNoQuietHours: return L10n.string("afk.action.always_ask", defaultValue: "Always ask")
        case .escalateToWatch: return L10n.string("afk.action.escalate", defaultValue: "Escalate")
        }
    }
}
