import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for recovering an SSH upload destination from a foreground mosh session.
@Suite struct TerminalMoshSessionDetectorTests {
    @Test func detectsUpstreamWrapperMarker() throws {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "mosh-client"),
            ],
            argumentsByPID: [
                2145: [
                    "/opt/homebrew/bin/mosh-client",
                    "-# -6 --predict=adaptive lawrence@example.com |",
                    "2001:db8::1", "60002",
                ],
            ]
        )

        let detected = try #require(session)
        #expect(detected.destination == "lawrence@example.com")
        #expect(detected.useIPv6)
        #expect(!detected.useIPv4)
        #expect(detected.port == nil)
    }

    @Test func detectsForkingLauncherFromItsOwnArguments() throws {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "ttys004",
            processes: [
                .init(pid: 2140, pgid: 2140, tpgid: 2140, tty: "ttys004", executableName: "mosh"),
                .init(pid: 2145, pgid: 2140, tpgid: 2140, tty: "ttys004", executableName: "mosh-client"),
            ],
            argumentsByPID: [
                2140: ["/Users/test/.local/bin/mosh", "-p", "60001", "lawrence@example.com"],
                2145: ["mosh-client", "192.0.2.1", "60001"],
            ]
        )

        let detected = try #require(session)
        #expect(detected.destination == "lawrence@example.com")
        #expect(detected.port == nil)
    }

    @Test func prefersClientMarkerOverForkingLauncher() throws {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "ttys004",
            processes: [
                .init(pid: 2140, pgid: 2140, tpgid: 2140, tty: "ttys004", executableName: "mosh"),
                .init(pid: 2145, pgid: 2140, tpgid: 2140, tty: "ttys004", executableName: "mosh-client"),
            ],
            argumentsByPID: [
                2140: ["mosh", "stale@example.com"],
                2145: ["mosh-client", "-# vps-he |", "192.0.2.1", "60002"],
            ]
        )

        #expect(session?.destination == "vps-he")
    }

    @Test func ignoresDirectClientWithoutRecoverableDestination() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "mosh-client"),
            ],
            argumentsByPID: [
                2145: ["mosh-client", "192.0.2.1", "60001"],
            ]
        )

        #expect(session == nil)
    }

    @Test func ignoresBackgroundLauncher() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "ttys004",
            processes: [
                .init(pid: 2140, pgid: 2140, tpgid: 1967, tty: "ttys004", executableName: "mosh"),
            ],
            argumentsByPID: [
                2140: ["mosh", "lawrence@example.com"],
            ]
        )

        #expect(session == nil)
    }
}
