import AppKit
import CmuxBrowser
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite
struct BrowserClientCertificateCredentialPickerTests {
    private func makeProtectionSpace(
        host: String,
        port: Int = 443,
        protocolName: String = "https"
    ) -> URLProtectionSpace {
        URLProtectionSpace(
            host: host,
            port: port,
            protocol: protocolName,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
    }

    @Test
    func pickerSanitizesCredentialReleaseOrigin() {
        let webView = WKWebView(frame: .zero)
        let candidate = BrowserClientCertificateCredentialCandidate(
            title: "Client\u{202E}\n",
            serialNumber: "\u{202E}\n123",
            credential: URLCredential(user: "client-cert", password: "unused", persistence: .forSession)
        )
        let picker = BrowserClientCertificateCredentialPicker(
            webView: webView,
            presentAlert: { alert, presentedWebView, completion, _ in
                #expect(presentedWebView === webView)
                #expect(alert.informativeText.contains("https://mtls.example:8443"))
                #expect(alert.informativeText.contains("\u{202E}") == false)
                #expect(alert.informativeText.contains("\n") == false)
                let popup = alert.accessoryView as? NSPopUpButton
                let popupTitle = popup?.itemTitles.first ?? ""
                #expect(popupTitle.contains("Client"))
                #expect(popupTitle.contains("Serial 123"))
                #expect(popupTitle.contains("\u{202E}") == false)
                #expect(popupTitle.contains("\n") == false)
                completion(.alertSecondButtonReturn)
            }
        )
        var selectedCandidate: BrowserClientCertificateCredentialCandidate?

        picker.selectCredential(
            for: makeProtectionSpace(host: "mtls\u{202E}.example\n", port: 8443),
            candidates: [candidate]
        ) { selection in
            selectedCandidate = selection
        }

        #expect(selectedCandidate == nil)
    }
}
