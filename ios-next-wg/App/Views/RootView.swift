import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.connections.isEmpty {
                ConnectView()
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.connections.isEmpty)
        .sheet(isPresented: Binding(get: { model.pairing != .idle }, set: { if !$0 { model.dismissPairingResult() } })) {
            PairingStatusSheet()
                .presentationDetents([.height(300)])
                .presentationBackground(.regularMaterial)
        }
    }
}

/// Progress and result of a pairing attempt.
struct PairingStatusSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            switch model.pairing {
            case .pairing(let name):
                ProgressView()
                    .controlSize(.large)
                    .padding(.bottom, 6)
                Text("Pairing with \(name)")
                    .font(.title3.weight(.semibold))
                Text("Setting up an encrypted WireGuard tunnel to your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .paired(let name):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .symbolEffect(.bounce, value: name)
                Text("Paired with \(name)")
                    .font(.title3.weight(.semibold))
                PrimaryCapsuleButton(title: "Done") { model.dismissPairingResult() }
                    .padding(.top, 6)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.yellow)
                Text("Couldn't pair")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                PrimaryCapsuleButton(title: "OK") { model.dismissPairingResult() }
                    .padding(.top, 6)
            case .idle:
                EmptyView()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled(model.pairing.isInFlight)
    }
}

extension AppModel.Pairing {
    var isInFlight: Bool {
        if case .pairing = self { return true }
        return false
    }
}

/// The white capsule call to action every reference app uses.
struct PrimaryCapsuleButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 28)
                .padding(.vertical, 13)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
    }
}

/// A floating glass circle (menu, back, actions).
struct GlassCircleButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}
