import SwiftUI
import UIKit

/// The first screen: no Mac paired yet.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false
    @State private var typingCode = false

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
            Button("Enter code manually") { typingCode = true }
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.top, 16)
            PairingInlineStatus()
                .padding(.top, 22)
                .padding(.horizontal, 40)
            Spacer()
            Label("End-to-end encrypted with WireGuard", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .sheet(isPresented: $typingCode) {
            CodeEntrySheet()
                .presentationDetents([.medium])
                .presentationBackground(.regularMaterial)
        }
        .fullScreenCover(isPresented: $scanning) {
            ScannerView { link in
                scanning = false
                model.pair(link: link)
            }
        }
    }
}

/// The pairing attempt in progress or its failure, under the buttons.
struct PairingInlineStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.pairing {
        case .pairing(let name):
            HStack(spacing: 8) {
                ProgressView()
                Text("Pairing with \(name)…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        default:
            EmptyView()
        }
    }
}
