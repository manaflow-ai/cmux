import SwiftUI
import UIKit

/// The first screen: no Mac paired yet.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 40, weight: .light))
                .padding(.bottom, 18)
            Text("Connect your Mac")
                .font(.title3.weight(.semibold))
            Text("Open cmux on your Mac, choose Open Mobile Pairing from the command palette, and scan the code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
                .padding(.top, 8)
            PrimaryCapsuleButton(title: "Scan QR code") { scanning = true }
                .padding(.top, 26)
            Button("Paste pairing link") { pasteLink() }
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.top, 16)
            Spacer()
            Label("End-to-end encrypted with WireGuard", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .fullScreenCover(isPresented: $scanning) {
            ScannerView { link in
                scanning = false
                model.pair(link: link)
            }
        }
    }

    private func pasteLink() {
        guard let text = UIPasteboard.general.string else { return }
        model.pair(link: text)
    }
}
