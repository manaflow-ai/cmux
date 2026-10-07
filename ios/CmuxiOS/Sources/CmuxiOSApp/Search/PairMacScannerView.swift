import CmuxiOSPairing
import SwiftUI

/// The QR scanner the "Pair a Mac" search action presents. A scanned link
/// goes to the router, which hands `pair` links to B6.
struct PairMacScannerView: View {
    let onLink: (URL) -> Void
    let onCancel: () -> Void
    @State private var unavailable = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if unavailable {
                    Text(QRScannerView.unavailableMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    QRScannerView(onLink: onLink, onUnavailable: { unavailable = true })
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                Text(String(localized: "search.pair.hint",
                            defaultValue: "Scan the QR code shown on your Mac in cmux.", bundle: .module))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(24)
            .navigationTitle(String(localized: "search.pair.title", defaultValue: "Pair a Mac", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "search.pair.cancel", defaultValue: "Cancel", bundle: .module), action: onCancel)
                }
            }
        }
    }
}
