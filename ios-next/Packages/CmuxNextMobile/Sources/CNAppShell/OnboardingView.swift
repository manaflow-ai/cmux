#if os(iOS)
import CNDesign
import CNSettingsUI
import SwiftUI

/// Signed in without a paired Mac: the host CLI steps and the pairing code.
struct OnboardingView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .font(.system(size: 40, weight: .regular))
                            .foregroundStyle(.cn(\.icon))
                            .accessibilityHidden(true)
                        Text("cmux runs your terminals, agents and browser on your Mac. Pair it once and this iPhone connects to it directly, or through a relay when it has to.")
                            .font(.subheadline)
                            .foregroundStyle(.cn(\.textSecondary))
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                PairMacForm(hosts: model.hosts, apiBase: model.auth.backend.configuration.baseURL.absoluteString) { host in
                    model.selectHost(host.id)
                }
                Section {
                    if let email = model.auth.state.user?.email {
                        LabeledContent("Signed in as", value: email)
                    }
                    Button("Sign Out", role: .destructive) { Task { await model.auth.signOut() } }
                }
            }
            .navigationTitle("Connect your Mac")
            .refreshable {
                await model.hosts.refresh()
                model.reconcileSelection()
            }
        }
        .tint(.cn(\.ink))
    }
}
#endif
