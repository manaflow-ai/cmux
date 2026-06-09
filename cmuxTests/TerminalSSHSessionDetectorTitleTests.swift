import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers `TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle:)`, the
/// pure helper that extracts the remote cwd from a `user@host:cwd` shell title.
/// This path is the only signal for the remote working directory during a
/// local-terminal SSH session (Ghostty rejects remote OSC 7 pwd reports), so the
/// Files panel's remote root depends on it parsing exactly these shapes.
@Suite("SSH remote working directory from terminal title")
struct TerminalSSHSessionDetectorTitleTests {
    @Test("Home title yields tilde")
    func homeTitleYieldsTilde() {
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "user@host:~") == "~"
        )
    }

    @Test("Absolute path is returned verbatim")
    func absolutePathReturnedVerbatim() {
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "user@host:/var/www") == "/var/www"
        )
    }

    @Test("Tilde-prefixed subpath is preserved")
    func tildeSubpathPreserved() {
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "deploy@web-01:~/projects/cmux")
                == "~/projects/cmux"
        )
    }

    @Test("Surrounding whitespace is trimmed")
    func surroundingWhitespaceTrimmed() {
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "  user@host:/srv  ") == "/srv"
        )
    }

    @Test("A colon inside the path is kept")
    func colonInsidePathKept() {
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "user@host:/a:b/c") == "/a:b/c"
        )
    }

    @Test("Title without an @ is not a remote prompt")
    func titleWithoutAtIsNil() {
        #expect(TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "localshell") == nil)
    }

    @Test("Title without a colon has no cwd")
    func titleWithoutColonIsNil() {
        #expect(TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "user@host") == nil)
    }

    @Test("Relative cwd is rejected")
    func relativeCwdIsNil() {
        #expect(TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "user@host:project") == nil)
    }

    @Test("Empty cwd is rejected")
    func emptyCwdIsNil() {
        #expect(TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "user@host:") == nil)
    }

    @Test("Tilde-username form is not treated as a path")
    func tildeUsernameFormIsNil() {
        // `~user` (home of another user) is not `~` or `~/...`, so it must not be
        // mistaken for an expandable remote root.
        #expect(TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "user@host:~user") == nil)
    }
}
