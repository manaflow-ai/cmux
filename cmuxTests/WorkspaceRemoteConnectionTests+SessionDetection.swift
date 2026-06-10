import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Foreground SSH and Eternal Terminal session detection
extension WorkspaceRemoteConnectionTests {
    func testDetectsForegroundSSHSessionForTTY() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=/tmp/cmux-ssh-%C",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-p", "2200",
                    "-i", "/Users/test/.ssh/id_ed25519",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(
            session,
            DetectedSSHSession(
                destination: "lawrence@example.com",
                port: 2200,
                identityFile: "/Users/test/.ssh/id_ed25519",
                configFile: nil,
                jumpHost: nil,
                controlPath: "/tmp/cmux-ssh-%C",
                useIPv4: false,
                useIPv6: false,
                forwardAgent: false,
                compressionEnabled: false,
                sshOptions: [
                    "StrictHostKeyChecking=accept-new",
                ]
            )
        )
    }

    func testDetectsForegroundSSHSessionWithShortControlPathFlag() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-S", "/tmp/cmux-ssh-%C",
                    "-p", "2200",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.controlPath, "/tmp/cmux-ssh-%C")
        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertTrue(scpArgs.contains("ControlPath=/tmp/cmux-ssh-%C"))
        XCTAssertFalse(scpArgs.contains("-S"))
    }

    func testDetectsForegroundEternalTerminalSessionForTTY() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "/opt/homebrew/bin/et",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(
            session,
            DetectedSSHSession(
                destination: "lawrence@example.com",
                port: nil,
                identityFile: nil,
                configFile: nil,
                jumpHost: nil,
                controlPath: nil,
                useIPv4: false,
                useIPv6: false,
                forwardAgent: false,
                compressionEnabled: false,
                sshOptions: []
            )
        )
    }

    func testDetectsEternalTerminalSessionWithoutTreatingETPortAsSSHPort() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "-u", "lawrence",
                    "-p", "2022",
                    "--jport", "2023",
                    "example.com:2024",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
        XCTAssertNil(session?.port)

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@example.com:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionWithBracketedIPv6ServerPortForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "-u", "lawrence",
                    "[2001:db8::1]:2022",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@[2001:db8::1]")

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertNil(session?.port)
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@[2001:db8::1]:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionWithFullIPv6ServerPortForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "-u", "lawrence",
                    "2001:db8:0:0:0:0:0:1:2022",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@[2001:db8:0:0:0:0:0:1]")

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertNil(session?.port)
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@[2001:db8:0:0:0:0:0:1]:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionPreservesAmbiguousCompressedIPv6LiteralForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "-u", "lawrence",
                    "2001:db8::1:2022",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@2001:db8::1:2022")

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertNil(session?.port)
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@[2001:db8::1:2022]:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionIgnoresOptionsAfterDestination() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "lawrence@example.com",
                    "--ssh-option", "Port=2200",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
        XCTAssertNil(session?.port)

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertEqual(scpArgs.last, "lawrence@example.com:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionStripsNativeJumpHostServerPortForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "--jumphost", "relay@bastion.example.com:2022",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.jumpHost, "relay@bastion.example.com")

        let scpArgs = session?.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        ) ?? []
        XCTAssertNil(session?.port)
        XCTAssertFalse(scpArgs.contains("-P"))
        XCTAssertTrue(scpArgs.contains("-J"))
        XCTAssertTrue(scpArgs.contains("relay@bastion.example.com"))
        XCTAssertFalse(scpArgs.contains("relay@bastion.example.com:2022"))
        XCTAssertEqual(scpArgs.last, "lawrence@example.com:/tmp/cmux-drop-123.png")
    }

    func testDetectsEternalTerminalSessionSSHOptionsForSCP() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "et"),
            ],
            argumentsByPID: [
                2145: [
                    "et",
                    "--ssh-option", "Port=2200",
                    "--ssh-option=IdentityFile=/Users/test/.ssh/id_ed25519",
                    "--ssh-option", "ControlPath=/tmp/cmux-ssh-%C",
                    "--ssh-option", "StrictHostKeyChecking=accept-new",
                    "--jumphost", "bastion.example.com",
                    "--command", "uptime",
                    "-x",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(
            session,
            DetectedSSHSession(
                destination: "lawrence@example.com",
                port: 2200,
                identityFile: "/Users/test/.ssh/id_ed25519",
                configFile: nil,
                jumpHost: "bastion.example.com",
                controlPath: "/tmp/cmux-ssh-%C",
                useIPv4: false,
                useIPv6: false,
                forwardAgent: false,
                compressionEnabled: false,
                sshOptions: [
                    "StrictHostKeyChecking=accept-new",
                ]
            )
        )
    }

    func testDetectedSSHSessionBracketsIPv6LiteralSCPDestination() {
        let session = DetectedSSHSession(
            destination: "lawrence@2001:db8::1",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        let scpArgs = session.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/cmux-drop-123.png"
        )

        XCTAssertEqual(scpArgs.last, "lawrence@[2001:db8::1]:/tmp/cmux-drop-123.png")
    }

    func testDetectsForegroundSSHSessionWithLowercaseAgentFlag() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-a",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
        XCTAssertFalse(session?.forwardAgent ?? true)
    }

    func testDetectsForegroundSSHSessionIgnoringBindInterfaceValue() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "/dev/ttys004",
            processes: [
                .init(pid: 2145, pgid: 1967, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: [
                    "ssh",
                    "-B", "en0",
                    "lawrence@example.com",
                ],
            ]
        )

        XCTAssertEqual(session?.destination, "lawrence@example.com")
    }

    func testIgnoresBackgroundSSHProcessForTTY() {
        let session = TerminalSSHSessionDetector.detectForTesting(
            ttyName: "ttys004",
            processes: [
                .init(pid: 2145, pgid: 2145, tpgid: 1967, tty: "ttys004", executableName: "ssh"),
            ],
            argumentsByPID: [
                2145: ["ssh", "lawrence@example.com"],
            ]
        )

        XCTAssertNil(session)
    }

}
