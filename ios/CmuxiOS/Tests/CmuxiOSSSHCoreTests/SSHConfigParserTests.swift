@testable import CmuxiOSSSHCore
import Testing

@Suite struct SSHConfigParserTests {
    let parser = SSHConfigParser()

    @Test func readsHostBlocksAndTrailingDefaults() {
        let entries = parser.parse("""
        # work machines
        Host devbox
            HostName devbox.tail0.ts.net
            User dev
            Port 2222

        Host bastion
          hostname=jump.example.com
          ProxyJump none

        Host *
            User fallback
            Port 22
        """)
        #expect(entries == [
            SSHConfigEntry(alias: "devbox", hostName: "devbox.tail0.ts.net", port: 2222, user: "dev"),
            SSHConfigEntry(alias: "bastion", hostName: "jump.example.com", port: 22, user: "fallback"),
        ])
    }

    @Test func firstObtainedValueWinsInFileOrder() {
        let entries = parser.parse("""
        Host *
            User early
        Host box
            User late
            HostName box.lan
        """)
        #expect(entries == [SSHConfigEntry(alias: "box", hostName: "box.lan", user: "early")])
    }

    @Test func skipsWildcardsNegationsAndMatchBlocks() {
        let entries = parser.parse("""
        Host *.corp !secret.corp web?
            User corp
        Host a b
            Port 2200
        Match host a
            User matched
        Host api.corp
        """)
        #expect(entries.map(\.alias) == ["a", "b", "api.corp"])
        #expect(entries[0].user == nil)
        #expect(entries[0].port == 2200)
        #expect(entries[2].user == "corp")
    }

    @Test func proxyJumpKeepsTheFirstHopAndQuotedValues() {
        let entries = parser.parse("""
        Host inner
            HostName "10.0.0.5"
            ProxyJump me@jump.example.com:2022,second
            User "with space"
        """)
        #expect(entries.first?.proxyJump == "me@jump.example.com:2022")
        #expect(entries.first?.hostName == "10.0.0.5")
        #expect(entries.first?.user == "with space")
    }

    @Test func invalidPortIsIgnoredAndHostNameTokenExpands() {
        let entries = parser.parse("""
        Host box
            Port 99999
            HostName %h.example.com
            User a=b
        """)
        #expect(entries.first?.port == nil)
        #expect(entries.first?.hostName == "box.example.com")
        #expect(entries.first?.user == "a=b")
    }

    @Test func tokenizesEqualsAndComments() {
        #expect(SSHConfigParser.tokenize("Port=22")! == ("port", ["22"]))
        #expect(SSHConfigParser.tokenize("  User = dev # me")! == ("user", ["dev"]))
        #expect(SSHConfigParser.tokenize("   # only a comment") == nil)
        #expect(SSHConfigParser.tokenize("") == nil)
    }

    @Test func globMatching() {
        #expect(SSHConfigBlock.glob("*.corp", "API.corp"))
        #expect(SSHConfigBlock.glob("web?", "web1"))
        #expect(!SSHConfigBlock.glob("web?", "web12"))
        #expect(SSHConfigBlock(patterns: ["*", "!secret"]).matches("box"))
        #expect(!SSHConfigBlock(patterns: ["*", "!secret"]).matches("secret"))
    }
}
