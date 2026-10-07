import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Foundation
import Testing

@Suite struct SSHKnownHostsTests {
    static let keyA = SSHHostKey(openSSHString: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
    static let keyB = SSHHostKey(openSSHString: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKdM0f2Ue8qIq1pD2kDBsGg9N0bJ9m8Iq0d5o3x7Y1zF")

    @Test func parsesPlainLinesAndSkipsOthers() {
        let lines = SSHKnownHostsLine.parse("Box.lan,[box.lan]:2222 " + Self.keyA.openSSHString + " comment")
        #expect(lines.map(\.identity) == ["box.lan", "[box.lan]:2222"])
        #expect(lines.first?.key == Self.keyA)
        #expect(SSHKnownHostsLine.parse("# comment").isEmpty)
        #expect(SSHKnownHostsLine.parse("|1|abc= ssh-ed25519 AAAA").isEmpty)
        #expect(SSHKnownHostsLine.parse("@revoked box ssh-ed25519 AAAA").isEmpty)
        #expect(SSHKnownHostsLine.parse("box ssh-ed25519 not*base64").isEmpty)
    }

    @Test func fileRoundTripsPinsInOrder() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = SSHKnownHostsFile(url: url)
        await file.pin(Self.keyA, for: "b.lan")
        await file.pin(Self.keyB, for: "[A.lan]:2222")
        await file.pin(Self.keyB, for: "b.lan")
        let reopened = SSHKnownHostsFile(url: url)
        #expect(await reopened.entries().map(\.identity) == ["b.lan", "[a.lan]:2222"])
        #expect(await reopened.pinnedKey(for: "B.LAN") == Self.keyB)
        await reopened.forget(identity: "b.lan")
        #expect(await SSHKnownHostsFile(url: url).pinnedKey(for: "b.lan") == nil)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "[a.lan]:2222 " + Self.keyB.openSSHString + "\n")
    }

    @Test func fingerprintMatchesOpenSSHFormat() {
        #expect(Self.keyA.sha256Fingerprint.hasPrefix("SHA256:"))
        #expect(!Self.keyA.sha256Fingerprint.contains("="))
    }
}
