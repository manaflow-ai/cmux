import CmuxVNCWebRTC
import SwiftUI
import VisionKit

/// Pairs a Mac running `cmux-vnc-host`: scan its QR code or paste its link,
/// then (optionally) save the Mac account the Screen Sharing sign-in uses.
struct PairView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var link: String
    @State private var username = ""
    @State private var password = ""
    @State private var scanning = false

    private var pairing: VNCPairing? { URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(VNCPairing.init(link:)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if DataScannerViewController.isSupported {
                        Button("Scan Pairing Code", systemImage: "qrcode.viewfinder") { scanning = true }
                    }
                    TextField("cmux-vnc://pair?…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button("Paste Link", systemImage: "doc.on.clipboard") { link = UIPasteboard.general.string ?? link }
                } header: {
                    Text("Pairing link")
                } footer: {
                    if let pairing {
                        Text("Pairs with “\(pairing.name)”. The connection goes over WebRTC: no VPN or tailnet needed.")
                    } else {
                        Text("Run cmux-vnc-host on the Mac; it shows a QR code and a link.")
                    }
                }
                Section {
                    TextField("User name", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Mac sign-in (optional)")
                } footer: {
                    Text("Screen Sharing on the Mac still asks for an account. Leave empty to be asked when you connect.")
                }
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        guard let pairing else { return }
                        store.pair(pairing, username: username, password: password.isEmpty ? nil : password)
                        dismiss()
                    }
                    .disabled(pairing == nil)
                }
            }
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    link = code
                    scanning = false
                }
                .ignoresSafeArea()
            }
        }
    }
}

/// VisionKit's live scanner, QR codes only; reports the first pairing link.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in items {
                if let value = code.payloadStringValue, value.hasPrefix("cmux-vnc://") {
                    found(value)
                    return
                }
            }
        }
    }
}
