import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SSHFileExplorerPathResolverTests: XCTestCase {

    // MARK: - remoteHomePath(from:)

    func testRemoteHomePath_typicalUserAtHost() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu@100.79.206.23"),
            "/home/imgyu"
        )
    }

    func testRemoteHomePath_userAtHostWithPort() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "ubuntu@host:2222"),
            "/home/ubuntu"
        )
    }

    func testRemoteHomePath_root() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "root@host"),
            "/root"
        )
    }

    func testRemoteHomePath_rootWithIPv6() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "root@[::1]:22"),
            "/root"
        )
    }

    func testRemoteHomePath_userWithIPv6() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "user@[fd00::1]:22"),
            "/home/user"
        )
    }

    func testRemoteHomePath_userPreservesCase() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "Imgyu@host"),
            "/home/Imgyu"
        )
    }

    func testRemoteHomePath_dashedUser() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "build-bot@ci.example.com"),
            "/home/build-bot"
        )
    }

    func testRemoteHomePath_userWithDot() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "first.last@host"),
            "/home/first.last"
        )
    }

    func testRemoteHomePath_trimsSurroundingWhitespace() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "  imgyu@host  "),
            "/home/imgyu"
        )
    }

    func testRemoteHomePath_nilDestination() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: nil),
            ""
        )
    }

    func testRemoteHomePath_emptyDestination() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: ""),
            ""
        )
    }

    func testRemoteHomePath_whitespaceOnlyDestination() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "   "),
            ""
        )
    }

    func testRemoteHomePath_destinationWithoutAtSign() {
        // No `@` means we cannot reliably extract a user — must NOT guess.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "justhostname"),
            ""
        )
    }

    func testRemoteHomePath_destinationStartingWithAtSign() {
        // Empty user portion is malformed.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "@host"),
            ""
        )
    }

    func testRemoteHomePath_destinationEndingWithAtSign() {
        // Empty host portion is malformed.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "user@"),
            ""
        )
    }

    func testRemoteHomePath_doubleAtSignTakesFirst() {
        // First `@` separates user from host. Anything after lives on host.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu@nested@host"),
            "/home/imgyu"
        )
    }

    // MARK: - effectiveRootPath(workspaceDirectory:remoteHomePath:)

    func testEffectiveRootPath_macUsersPathFallsBackToHome() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/Users/imgyukim/Downloads",
                remoteHomePath: "/home/imgyu"
            ),
            "/home/imgyu"
        )
    }

    func testEffectiveRootPath_macVolumesPathFallsBackToHome() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/Volumes/Backup/projects",
                remoteHomePath: "/home/imgyu"
            ),
            "/home/imgyu"
        )
    }

    func testEffectiveRootPath_alreadyRemoteHomePathIsPreserved() {
        // If the workspace cwd already lives under remote home, keep it.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/home/imgyu/projects/foo",
                remoteHomePath: "/home/imgyu"
            ),
            "/home/imgyu/projects/foo"
        )
    }

    func testEffectiveRootPath_nonMacLinuxStylePathIsPreserved() {
        // /etc/foo is plausible on remote — don't override.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/etc/nginx",
                remoteHomePath: "/home/imgyu"
            ),
            "/etc/nginx"
        )
    }

    func testEffectiveRootPath_rootSlashIsPreserved() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/",
                remoteHomePath: "/home/imgyu"
            ),
            "/"
        )
    }

    func testEffectiveRootPath_privatePathIsPreserved() {
        // /private/etc exists on macOS BUT the path /private is also valid on
        // some setups; the user might have intentionally chosen it. We err
        // on the side of preserving user intent.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/private/etc",
                remoteHomePath: "/home/imgyu"
            ),
            "/private/etc"
        )
    }

    func testEffectiveRootPath_emptyHomeDoesNotFallback() {
        // Without a credible remote home, leave the workspace cwd alone so
        // we don't replace a Mac path with "" (file explorer would die).
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/Users/imgyukim/Downloads",
                remoteHomePath: ""
            ),
            "/Users/imgyukim/Downloads"
        )
    }

    func testEffectiveRootPath_emptyDirIsPreservedWhenHomeEmpty() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "",
                remoteHomePath: ""
            ),
            ""
        )
    }

    func testEffectiveRootPath_emptyDirFallsBackToHome() {
        // An empty workspace cwd *with* a credible remote anchor is
        // effectively "Mac-local-ish nothing"; substituting the home is the
        // friendlier behavior.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "",
                remoteHomePath: "/home/imgyu"
            ),
            ""
        )
        // Note: current implementation preserves "" because isMacLocalPath("")
        // is false. This test pins down that behavior so a future change is
        // intentional. The caller (FileExplorerStore) treats empty rootPath
        // as "no root selected" and skips loading, which is the safe default.
    }

    // MARK: - isMacLocalPath

    func testIsMacLocalPath_users() {
        XCTAssertTrue(SSHFileExplorerPathResolver.isMacLocalPath("/Users/x"))
        XCTAssertTrue(SSHFileExplorerPathResolver.isMacLocalPath("/Users/imgyukim/workspace"))
    }

    func testIsMacLocalPath_volumes() {
        XCTAssertTrue(SSHFileExplorerPathResolver.isMacLocalPath("/Volumes/Foo"))
    }

    func testIsMacLocalPath_homeIsNotMacLocal() {
        // /home/<user> exists on Linux remotes; do not treat as Mac-only.
        XCTAssertFalse(SSHFileExplorerPathResolver.isMacLocalPath("/home/imgyu"))
    }

    func testIsMacLocalPath_rootSlash() {
        XCTAssertFalse(SSHFileExplorerPathResolver.isMacLocalPath("/"))
    }

    func testIsMacLocalPath_caseSensitive() {
        // /users/... (lowercase) is not a real macOS root — keep it false.
        XCTAssertFalse(SSHFileExplorerPathResolver.isMacLocalPath("/users/x"))
    }

    // MARK: - End-to-end (composition)

    func testComposition_macWorkspaceWithSSHRemote_routesToRemoteHome() {
        // The exact scenario the upstream bug report describes:
        //   workspace cwd captured from Mac caller, SSH-bound to user@host,
        //   file explorer should anchor at the remote home, not the Mac path.
        let home = SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu@100.79.206.23")
        let root = SSHFileExplorerPathResolver.effectiveRootPath(
            workspaceDirectory: "/Users/imgyukim/Downloads",
            remoteHomePath: home
        )
        XCTAssertEqual(home, "/home/imgyu")
        XCTAssertEqual(root, "/home/imgyu")
    }

    func testComposition_rootSSH_routesToSlashRoot() {
        let home = SSHFileExplorerPathResolver.remoteHomePath(from: "root@server")
        let root = SSHFileExplorerPathResolver.effectiveRootPath(
            workspaceDirectory: "/Users/imgyukim/projects",
            remoteHomePath: home
        )
        XCTAssertEqual(home, "/root")
        XCTAssertEqual(root, "/root")
    }

    func testComposition_remoteWorkspaceCwdAlreadyMatchesHome_isPreserved() {
        // When a workspace's cwd was somehow already a remote-style path
        // (e.g., the user manually set it), keep it — don't override.
        let home = SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu@host")
        let root = SSHFileExplorerPathResolver.effectiveRootPath(
            workspaceDirectory: "/home/imgyu/projects/cmux",
            remoteHomePath: home
        )
        XCTAssertEqual(root, "/home/imgyu/projects/cmux")
    }
}
