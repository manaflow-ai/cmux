import SwiftUI
import UIKit

/// Copy and Share buttons for an OpenSSH public key line.
struct PublicKeyActions: View {
    let publicKeyLine: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = publicKeyLine
            copied = true
        } label: {
            Label(copied ? SSHText.copied : SSHText.copyPublicKey, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        ShareLink(item: publicKeyLine) {
            Label(SSHText.sharePublicKey, systemImage: "square.and.arrow.up")
        }
    }
}
