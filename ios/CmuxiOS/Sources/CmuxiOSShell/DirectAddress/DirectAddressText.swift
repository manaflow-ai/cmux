import CmuxiOSFeatureKit
import Foundation

/// Strings of the "Add direct address" form (lane B4).
enum DirectAddressText {
    static var title: String {
        String(localized: "shell.direct.title", defaultValue: "Add Direct Address", bundle: .module)
    }
    static var name: String {
        String(localized: "shell.direct.name", defaultValue: "Name", bundle: .module)
    }
    static var namePlaceholder: String {
        String(localized: "shell.direct.name.placeholder", defaultValue: "Optional", bundle: .module)
    }
    static var address: String {
        String(localized: "shell.direct.address", defaultValue: "Address", bundle: .module)
    }
    static var addressPlaceholder: String {
        String(localized: "shell.direct.address.placeholder", defaultValue: "100.101.102.103 or mac.tailnet.ts.net", bundle: .module)
    }
    static var port: String {
        String(localized: "shell.direct.port", defaultValue: "Port", bundle: .module)
    }
    static var hostKey: String {
        String(localized: "shell.direct.hostKey", defaultValue: "Host Key", bundle: .module)
    }
    static var hostKeyPlaceholder: String {
        String(localized: "shell.direct.hostKey.placeholder", defaultValue: "Paste the key shown on the Mac", bundle: .module)
    }
    static var footer: String {
        String(
            localized: "shell.direct.footer",
            defaultValue: "A Tailscale, WireGuard or local network address of a Mac running cmux. The connection is encrypted and opens only if the Mac proves this key.",
            bundle: .module
        )
    }
    static var save: String {
        String(localized: "shell.direct.save", defaultValue: "Save", bundle: .module)
    }
    static var cancel: String {
        String(localized: "shell.direct.cancel", defaultValue: "Cancel", bundle: .module)
    }
    static func refused(_ reason: String) -> String {
        String(localized: "shell.direct.refused", defaultValue: "Could not save: \(reason)", bundle: .module)
    }

    static func issue(_ issue: DirectAddressIssue) -> String {
        switch issue {
        case .addressMissing:
            String(localized: "shell.direct.issue.addressMissing", defaultValue: "Enter an address.", bundle: .module)
        case .addressInvalid:
            String(localized: "shell.direct.issue.addressInvalid", defaultValue: "Enter a host name or IP address without a scheme or path.", bundle: .module)
        case .addressHasPort:
            String(localized: "shell.direct.issue.addressHasPort", defaultValue: "Put the port in the Port field.", bundle: .module)
        case .portInvalid:
            String(localized: "shell.direct.issue.portInvalid", defaultValue: "Port must be 1 to 65535.", bundle: .module)
        case .hostKeyMissing:
            String(localized: "shell.direct.issue.hostKeyMissing", defaultValue: "Paste the Mac's host key.", bundle: .module)
        case .hostKeyInvalid:
            String(localized: "shell.direct.issue.hostKeyInvalid", defaultValue: "This is not a valid host key.", bundle: .module)
        }
    }
}
