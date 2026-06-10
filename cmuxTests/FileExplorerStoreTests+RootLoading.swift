import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Mock Provider


// MARK: - Root loading and remote providers
extension FileExplorerStoreTests {
    func testLoadRootPopulatesNodes() async throws {
        let provider = MockFileExplorerProvider()
        provider.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "src", path: "/home/user/project/src", isDirectory: true),
            FileExplorerEntry(name: "README.md", path: "/home/user/project/README.md", isDirectory: false),
        ])

        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/home/user/project")

        try await waitFor("root nodes loaded") { store.rootNodes.count == 2 }

        // Directories should sort before files
        XCTAssertEqual(store.rootNodes[0].name, "src")
        XCTAssertTrue(store.rootNodes[0].isDirectory)
        XCTAssertEqual(store.rootNodes[1].name, "README.md")
        XCTAssertFalse(store.rootNodes[1].isDirectory)
    }

    func testDisplayRootPathUsesTilde() {
        let provider = MockFileExplorerProvider(homePath: "/home/user")
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.rootPath = "/home/user/project"
        XCTAssertEqual(store.displayRootPath, "~/project")
    }

    func testRemoteWorkspaceRootRequestResolvesSSHHomeInsteadOfKeepingLocalPath() async throws {
        let transport = MockSSHFileExplorerTransport(homePath: .success("/home/dev"))
        transport.listings["/home/dev"] = .success([
            FileExplorerEntry(name: "project", path: "/home/dev/project", isDirectory: true),
        ])
        let connection = SSHFileExplorerConnection(
            destination: "dev@ubuntu-host",
            port: 2222,
            identityFile: "/Users/alice/.ssh/id_ed25519",
            sshOptions: ["ControlPath /tmp/cmux-ssh-%C"]
        )

        let store = FileExplorerStore()
        store.setProviderForTesting(LocalFileExplorerProvider())
        store.setRootPath("/Users/alice")

        store.applyWorkspaceRoot(
            .remoteSSH(
                workspaceId: UUID(),
                connection: connection,
                displayTarget: "dev@ubuntu-host:2222",
                rootPath: nil,
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote home resolved and loaded") {
            store.rootPath == "/home/dev" &&
                store.rootNodes.map(\.name) == ["project"]
        }

        XCTAssertTrue(store.provider is SSHFileExplorerProvider)
        XCTAssertEqual(store.rootPath, "/home/dev")
        XCTAssertEqual(store.displayRootPath, "ssh://dev@ubuntu-host:2222:/home/dev")
        XCTAssertEqual(transport.resolvedHomeConnections, [connection])
        XCTAssertEqual(transport.listedPaths, ["/home/dev"])
    }

    func testSwitchingFromLocalToRemoteRepointsTreeToRemoteHome() async throws {
        let transport = MockSSHFileExplorerTransport(homePath: .success("/home/dev"))
        transport.listings["/home/dev"] = .success([
            FileExplorerEntry(name: ".ssh", path: "/home/dev/.ssh", isDirectory: true),
        ])
        let localProvider = MockFileExplorerProvider(homePath: "/Users/alice")
        localProvider.listings["/Users/alice"] = .success([
            FileExplorerEntry(name: "Desktop", path: "/Users/alice/Desktop", isDirectory: true),
        ])

        let store = FileExplorerStore()
        store.setProviderForTesting(localProvider)
        store.setRootPath("/Users/alice")
        try await waitFor("local root loaded") {
            store.rootPath == "/Users/alice" &&
                store.rootNodes.map(\.name) == ["Desktop"]
        }

        store.applyWorkspaceRoot(
            .remoteSSH(
                workspaceId: UUID(),
                connection: SSHFileExplorerConnection(
                    destination: "dev@ubuntu-host",
                    port: nil,
                    identityFile: nil,
                    sshOptions: []
                ),
                displayTarget: "dev@ubuntu-host",
                rootPath: nil,
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote root replaces local root") {
            store.rootPath == "/home/dev" &&
                store.rootNodes.map(\.name) == [".ssh"]
        }

        XCTAssertTrue(store.provider is SSHFileExplorerProvider)
        XCTAssertEqual(transport.resolvedHomeConnections.map(\.destination), ["dev@ubuntu-host"])
    }

    func testRemoteWorkspaceRootTracksRequestedWorkingDirectory() async throws {
        let transport = MockSSHFileExplorerTransport(homePath: .success("/home/dev"))
        transport.listings["/srv/app"] = .success([
            FileExplorerEntry(name: "Package.swift", path: "/srv/app/Package.swift", isDirectory: false),
        ])
        let store = FileExplorerStore()

        store.applyWorkspaceRoot(
            .remoteSSH(
                workspaceId: UUID(),
                connection: SSHFileExplorerConnection(
                    destination: "dev@ubuntu-host",
                    port: nil,
                    identityFile: nil,
                    sshOptions: []
                ),
                displayTarget: "dev@ubuntu-host",
                rootPath: "/srv/app",
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote requested cwd loaded") {
            store.rootPath == "/srv/app" &&
                store.rootNodes.map(\.name) == ["Package.swift"]
        }

        XCTAssertEqual(transport.resolvedHomeConnections, [])
        XCTAssertEqual(transport.listedPaths, ["/srv/app"])
        XCTAssertEqual(store.displayRootPath, "ssh://dev@ubuntu-host:/srv/app")
    }

    func testRemoteFilePreviewMaterializesThroughSSHProvider() async throws {
        let transport = MockSSHFileExplorerTransport(homePath: .success("/home/dev"))
        transport.listings["/srv/app"] = .success([
            FileExplorerEntry(name: "README.md", path: "/srv/app/README.md", isDirectory: false),
        ])
        transport.downloads["/srv/app/README.md"] = .success(Data("# Remote\n".utf8))
        let store = FileExplorerStore()
        store.applyWorkspaceRoot(
            .remoteSSH(
                workspaceId: UUID(),
                connection: SSHFileExplorerConnection(
                    destination: "dev@ubuntu-host",
                    port: nil,
                    identityFile: nil,
                    sshOptions: []
                ),
                displayTarget: "dev@ubuntu-host",
                rootPath: "/srv/app",
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote requested cwd loaded") {
            store.rootNodes.map(\.name) == ["README.md"]
        }
        let localURL = try await store.materializeRemoteFileForPreview(path: "/srv/app/README.md")

        XCTAssertEqual(transport.downloadedPaths, ["/srv/app/README.md"])
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8), "# Remote\n")
        XCTAssertTrue(localURL.path.contains("cmux-remote-file-previews"))
    }

    func testCancelledRootLoadDoesNotClearRemoteUnavailableStatus() async throws {
        let provider = DeferredListFileExplorerProvider()
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/home/dev")

        try await waitFor("root listing started") {
            provider.listCallPaths == ["/home/dev"]
        }

        store.applyWorkspaceRoot(
            .remoteSSH(
                workspaceId: UUID(),
                connection: SSHFileExplorerConnection(
                    destination: "dev@ubuntu-host",
                    port: nil,
                    identityFile: nil,
                    sshOptions: []
                ),
                displayTarget: "dev@ubuntu-host",
                rootPath: nil,
                isAvailable: false,
                unavailableDetail: nil
            ),
            sshTransport: MockSSHFileExplorerTransport()
        )

        let unavailableMessage = String(
            localized: "fileExplorer.status.sshUnavailable",
            defaultValue: "SSH files unavailable"
        )
        XCTAssertEqual(store.rootStatusMessage, unavailableMessage)

        provider.resumeListing(returning: [
            FileExplorerEntry(name: "stale", path: "/home/dev/stale", isDirectory: true),
        ])

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.rootStatusMessage, unavailableMessage)
        XCTAssertTrue(store.rootNodes.isEmpty)
    }

    // MARK: - Expansion state persistence

}
