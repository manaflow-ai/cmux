import CmuxiOSSSHCore
import Foundation

/// Localized strings of the SSH screens.
enum SSHText {
    // Hosts list
    static var hostsTitle: String { String(localized: "ssh.hosts.title", defaultValue: "Hosts", bundle: .module) }
    static var pairedMacs: String { String(localized: "ssh.hosts.section.paired", defaultValue: "Paired Macs", bundle: .module) }
    static var sshHosts: String { String(localized: "ssh.hosts.section.ssh", defaultValue: "SSH", bundle: .module) }
    static var directHosts: String { String(localized: "ssh.hosts.section.direct", defaultValue: "Direct", bundle: .module) }
    static var addHost: String { String(localized: "ssh.hosts.add", defaultValue: "Add SSH Host", bundle: .module) }
    static var importConfig: String { String(localized: "ssh.hosts.import", defaultValue: "Import from SSH Config", bundle: .module) }
    static var keys: String { String(localized: "ssh.hosts.keys", defaultValue: "Keys", bundle: .module) }
    static var add: String { String(localized: "ssh.common.add", defaultValue: "Add", bundle: .module) }
    static var edit: String { String(localized: "ssh.common.edit", defaultValue: "Edit", bundle: .module) }
    static var browser: String { String(localized: "ssh.common.browser", defaultValue: "Browser", bundle: .module) }
    static var files: String { String(localized: "ssh.common.files", defaultValue: "Files", bundle: .module) }
    static var delete: String { String(localized: "ssh.common.delete", defaultValue: "Delete", bundle: .module) }
    static var cancel: String { String(localized: "ssh.common.cancel", defaultValue: "Cancel", bundle: .module) }
    static var save: String { String(localized: "ssh.common.save", defaultValue: "Save", bundle: .module) }
    static var ok: String { String(localized: "ssh.common.ok", defaultValue: "OK", bundle: .module) }
    static var emptyTitle: String { String(localized: "ssh.hosts.empty.title", defaultValue: "No SSH Hosts", bundle: .module) }
    static var emptyBody: String {
        String(localized: "ssh.hosts.empty.body", defaultValue: "Add a server you reach over SSH, or import hosts from your SSH config.", bundle: .module)
    }
    static var offline: String { String(localized: "ssh.hosts.offline", defaultValue: "Hosts are offline", bundle: .module) }
    static var reachable: String { String(localized: "ssh.hosts.reachable", defaultValue: "Reachable", bundle: .module) }
    static var unreachable: String { String(localized: "ssh.hosts.unreachable", defaultValue: "Unreachable", bundle: .module) }
    static var viaJump: String { String(localized: "ssh.hosts.via", defaultValue: "via %@", bundle: .module) }
    static var deleteConfirmTitle: String { String(localized: "ssh.hosts.delete.title", defaultValue: "Delete “%@”?", bundle: .module) }
    static var deleteConfirmBody: String {
        String(localized: "ssh.hosts.delete.body", defaultValue: "Its saved password and pinned host key are removed from this device. Hosts that jump through it connect directly.", bundle: .module)
    }
    static var cannotOpen: String { String(localized: "ssh.hosts.cannot-open", defaultValue: "Can’t Connect", bundle: .module) }

    // Editor
    static var newHost: String { String(localized: "ssh.editor.new", defaultValue: "New Host", bundle: .module) }
    static var editHost: String { String(localized: "ssh.editor.edit", defaultValue: "Edit Host", bundle: .module) }
    static var name: String { String(localized: "ssh.editor.name", defaultValue: "Name", bundle: .module) }
    static var address: String { String(localized: "ssh.editor.address", defaultValue: "Host", bundle: .module) }
    static var addressPrompt: String { String(localized: "ssh.editor.address.prompt", defaultValue: "server.example.com", bundle: .module) }
    static var port: String { String(localized: "ssh.editor.port", defaultValue: "Port", bundle: .module) }
    static var user: String { String(localized: "ssh.editor.user", defaultValue: "User", bundle: .module) }
    static var server: String { String(localized: "ssh.editor.section.server", defaultValue: "Server", bundle: .module) }
    static var authentication: String { String(localized: "ssh.editor.section.auth", defaultValue: "Authentication", bundle: .module) }
    static var method: String { String(localized: "ssh.editor.method", defaultValue: "Method", bundle: .module) }
    static var methodKey: String { String(localized: "ssh.editor.method.key", defaultValue: "Key", bundle: .module) }
    static var methodPassword: String { String(localized: "ssh.editor.method.password", defaultValue: "Password", bundle: .module) }
    static var key: String { String(localized: "ssh.editor.key", defaultValue: "Key", bundle: .module) }
    static var noKey: String { String(localized: "ssh.editor.key.none", defaultValue: "None", bundle: .module) }
    static var generateKey: String { String(localized: "ssh.editor.key.generate", defaultValue: "Generate New Key", bundle: .module) }
    static var password: String { String(localized: "ssh.editor.password", defaultValue: "Password", bundle: .module) }
    static var passwordSaved: String { String(localized: "ssh.editor.password.saved", defaultValue: "Saved in Keychain", bundle: .module) }
    static var passwordFooter: String {
        String(localized: "ssh.editor.password.footer", defaultValue: "Stored only in this device’s Keychain. A key is safer: install one with the password once.", bundle: .module)
    }
    static var keyFooter: String {
        String(localized: "ssh.editor.key.footer", defaultValue: "The private key never leaves this device. Add its public key to the server’s authorized_keys, or install it with a password below.", bundle: .module)
    }
    static var jumpHost: String { String(localized: "ssh.editor.jump", defaultValue: "Jump Host", bundle: .module) }
    static var noJumpHost: String { String(localized: "ssh.editor.jump.none", defaultValue: "None", bundle: .module) }
    static var routing: String { String(localized: "ssh.editor.section.routing", defaultValue: "Routing", bundle: .module) }
    static var jumpFooter: String {
        String(localized: "ssh.editor.jump.footer", defaultValue: "Connect through another SSH host first (ProxyJump).", bundle: .module)
    }
    static var installKey: String { String(localized: "ssh.editor.install", defaultValue: "Install Key with Password", bundle: .module) }
    static var installPassword: String { String(localized: "ssh.editor.install.password", defaultValue: "Server password", bundle: .module) }
    static var install: String { String(localized: "ssh.editor.install.action", defaultValue: "Install", bundle: .module) }
    static var installFooter: String {
        String(localized: "ssh.editor.install.footer", defaultValue: "Logs in once with the password, adds the public key to authorized_keys, then checks that the key works. The password is not saved.", bundle: .module)
    }
    static var installJumpUnsupported: String {
        String(localized: "ssh.editor.install.jump", defaultValue: "Installing through a jump host isn’t supported yet. Add the public key on the server.", bundle: .module)
    }
    static var installed: String { String(localized: "ssh.editor.install.done", defaultValue: "Key installed and verified.", bundle: .module) }
    static var userRequired: String { String(localized: "ssh.editor.user.required", defaultValue: "Enter the user to log in as.", bundle: .module) }
    static var portInvalid: String { String(localized: "ssh.editor.port.invalid", defaultValue: "Port must be a number from 1 to 65535.", bundle: .module) }

    // Keys
    static var keysTitle: String { String(localized: "ssh.keys.title", defaultValue: "SSH Keys", bundle: .module) }
    static var keysEmpty: String { String(localized: "ssh.keys.empty", defaultValue: "No keys yet. Generate one and add its public key to your servers.", bundle: .module) }
    static var generate: String { String(localized: "ssh.keys.generate", defaultValue: "Generate Key", bundle: .module) }
    static var keyName: String { String(localized: "ssh.keys.name", defaultValue: "Name", bundle: .module) }
    static var keyType: String { String(localized: "ssh.keys.type", defaultValue: "Type", bundle: .module) }
    static var typeEd25519: String { String(localized: "ssh.keys.type.ed25519", defaultValue: "Ed25519 (Keychain)", bundle: .module) }
    static var typeEnclave: String { String(localized: "ssh.keys.type.enclave", defaultValue: "P-256 (Secure Enclave)", bundle: .module) }
    static var typeFooter: String {
        String(localized: "ssh.keys.type.footer", defaultValue: "Ed25519 works with every server. A Secure Enclave key can never be copied off this iPhone, but some servers don’t accept ECDSA keys.", bundle: .module)
    }
    static var requireFaceID: String { String(localized: "ssh.keys.biometry", defaultValue: "Require Face ID for Each Use", bundle: .module) }
    static var enclaveUnavailable: String { String(localized: "ssh.keys.enclave.unavailable", defaultValue: "This device has no Secure Enclave.", bundle: .module) }
    static var copyPublicKey: String { String(localized: "ssh.keys.copy", defaultValue: "Copy Public Key", bundle: .module) }
    static var sharePublicKey: String { String(localized: "ssh.keys.share", defaultValue: "Share Public Key", bundle: .module) }
    static var copied: String { String(localized: "ssh.keys.copied", defaultValue: "Copied", bundle: .module) }
    static var defaultKeyName: String { String(localized: "ssh.keys.default-name", defaultValue: "iPhone", bundle: .module) }
    static var deleteKeyTitle: String { String(localized: "ssh.keys.delete.title", defaultValue: "Delete “%@”?", bundle: .module) }
    static var deleteKeyBody: String {
        String(localized: "ssh.keys.delete.body", defaultValue: "The private key is erased from this device and can’t be recovered.", bundle: .module)
    }
    static var deleteKeyInUse: String {
        String(localized: "ssh.keys.delete.in-use", defaultValue: "%lld hosts log in with this key and will need another.", bundle: .module)
    }
    static var kindSecureEnclave: String { String(localized: "ssh.keys.kind.enclave", defaultValue: "Secure Enclave", bundle: .module) }
    static var kindImported: String { String(localized: "ssh.keys.kind.imported", defaultValue: "Imported", bundle: .module) }
    static var kindGenerated: String { String(localized: "ssh.keys.kind.generated", defaultValue: "Keychain", bundle: .module) }

    // Import
    static var importTitle: String { String(localized: "ssh.import.title", defaultValue: "Import Hosts", bundle: .module) }
    static var importPrompt: String {
        String(localized: "ssh.import.prompt", defaultValue: "Paste Host blocks from ~/.ssh/config. HostName, Port, User and ProxyJump are read; keys stay on your computer.", bundle: .module)
    }
    static var importPaste: String { String(localized: "ssh.import.paste", defaultValue: "Paste", bundle: .module) }
    static var importFound: String { String(localized: "ssh.import.found", defaultValue: "Found", bundle: .module) }
    static var importNone: String { String(localized: "ssh.import.none", defaultValue: "No concrete Host entries found.", bundle: .module) }
    static var importDuplicate: String { String(localized: "ssh.import.duplicate", defaultValue: "Already added", bundle: .module) }
    static var importUnresolved: String { String(localized: "ssh.import.unresolved", defaultValue: "Jump host %@ not found; connects directly", bundle: .module) }
    static var importAction: String { String(localized: "ssh.import.action", defaultValue: "Import %lld", bundle: .module) }
    static var importResult: String { String(localized: "ssh.import.result", defaultValue: "Imported %lld hosts. Choose a key or password for each before connecting.", bundle: .module) }

    // Trust
    static var trustTitle: String { String(localized: "ssh.trust.title", defaultValue: "Trust “%@”?", bundle: .module) }
    static var trustBody: String {
        String(localized: "ssh.trust.body", defaultValue: "This is the first connection to %1$@. Check that the server’s key fingerprint matches:\n\n%2$@\n%3$@", bundle: .module)
    }
    static var trust: String { String(localized: "ssh.trust.action", defaultValue: "Trust", bundle: .module) }
    static var changedTitle: String { String(localized: "ssh.trust.changed.title", defaultValue: "Host Key Changed", bundle: .module) }
    static var changedBody: String {
        String(localized: "ssh.trust.changed.body", defaultValue: "The key %1$@ presented differs from the one this device trusted. The server may have been reinstalled, or someone may be intercepting the connection.\n\nTrusted: %2$@\nPresented: %3$@", bundle: .module)
    }
    static var disconnect: String { String(localized: "ssh.trust.disconnect", defaultValue: "Disconnect", bundle: .module) }
    static var replaceKey: String { String(localized: "ssh.trust.replace", defaultValue: "Replace Key", bundle: .module) }

    // Session
    static var connecting: String { String(localized: "ssh.session.connecting", defaultValue: "Connecting…", bundle: .module) }
    static var reconnecting: String { String(localized: "ssh.session.reconnecting", defaultValue: "Connection lost. Reconnecting (%lld)…", bundle: .module) }
    static var exited: String { String(localized: "ssh.session.exited", defaultValue: "Session ended", bundle: .module) }
    static var closed: String { String(localized: "ssh.session.closed", defaultValue: "Disconnected", bundle: .module) }
    static var retry: String { String(localized: "ssh.session.retry", defaultValue: "Retry Now", bundle: .module) }
    static var reconnect: String { String(localized: "ssh.session.reconnect", defaultValue: "Reconnect", bundle: .module) }
    static var editLogin: String { String(localized: "ssh.session.edit-login", defaultValue: "Edit Login", bundle: .module) }

    static func failure(_ failure: SSHSessionFailure) -> String {
        switch failure {
        case .hostKeyRejected:
            String(localized: "ssh.failure.host-key", defaultValue: "The server’s identity wasn’t trusted.", bundle: .module)
        case .authenticationFailed:
            String(localized: "ssh.failure.auth", defaultValue: "The server refused the key or password.", bundle: .module)
        case .missingCredentials:
            String(localized: "ssh.failure.credentials", defaultValue: "Choose a key or password for this host.", bundle: .module)
        case .missingUser:
            String(localized: "ssh.failure.user", defaultValue: "This host has no user name.", bundle: .module)
        case .invalidChain:
            String(localized: "ssh.failure.chain", defaultValue: "A jump host is missing or loops back.", bundle: .module)
        case .shellRejected:
            String(localized: "ssh.failure.shell", defaultValue: "The server refused to start a shell.", bundle: .module)
        case .network:
            String(localized: "ssh.failure.network", defaultValue: "Can’t reach the server.", bundle: .module)
        }
    }

    static func refusal(_ reason: String) -> String {
        switch HostsRefusal(rawValue: reason) {
        case .pairedMac: String(localized: "ssh.refusal.paired", defaultValue: "Pair Macs from Devices.", bundle: .module)
        case .emptyName: String(localized: "ssh.refusal.name", defaultValue: "Enter a name.", bundle: .module)
        case .emptyAddress: String(localized: "ssh.refusal.address", defaultValue: "Enter the server address.", bundle: .module)
        case .unknownHost: String(localized: "ssh.refusal.unknown", defaultValue: "This host no longer exists.", bundle: .module)
        case .unknownJumpHost: String(localized: "ssh.refusal.jump", defaultValue: "The jump host no longer exists.", bundle: .module)
        case .jumpCycle: String(localized: "ssh.refusal.cycle", defaultValue: "The jump host would route back to this host.", bundle: .module)
        case .storage: String(localized: "ssh.refusal.storage", defaultValue: "Couldn’t save. Free some space and try again.", bundle: .module)
        case nil: reason
        }
    }

    static var genericError: String { String(localized: "ssh.error.generic", defaultValue: "Something went wrong. Try again.", bundle: .module) }
}
