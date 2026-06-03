import Foundation
import XCTest
@testable import cmux_DEV

final class LiveAnchormuxConfigTests: XCTestCase {
    func testTerminalWorkspaceSectionsGroupByHostAndKeepNewestSectionFirst() {
        let macMini = TerminalHost(
            stableID: "mac-mini",
            name: "Mac mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon
        )
        let laptop = TerminalHost(
            stableID: "laptop",
            name: "MacBook Pro",
            hostname: "lawrence-mbp",
            username: "lawrence",
            symbolName: "laptopcomputer",
            palette: .sky,
            source: .discovered,
            transportPreference: .remoteDaemon
        )

        let sections = TerminalWorkspaceDeviceSectionBuilder.makeSections(
            workspaces: [
                TerminalWorkspace(
                    hostID: macMini.id,
                    title: "logs",
                    tmuxSessionName: "logs",
                    preview: "tail -f",
                    lastActivity: Date(timeIntervalSince1970: 100)
                ),
                TerminalWorkspace(
                    hostID: laptop.id,
                    title: "btop",
                    tmuxSessionName: "btop",
                    preview: "monitoring",
                    lastActivity: Date(timeIntervalSince1970: 200)
                ),
                TerminalWorkspace(
                    hostID: macMini.id,
                    title: "deploy",
                    tmuxSessionName: "deploy",
                    preview: "ship it",
                    lastActivity: Date(timeIntervalSince1970: 150)
                ),
            ],
            hosts: [macMini, laptop],
            query: ""
        )

        XCTAssertEqual(sections.map(\.title), ["MacBook Pro", "Mac mini"])
        XCTAssertEqual(sections[0].workspaces.map(\.title), ["btop"])
        XCTAssertEqual(sections[1].workspaces.map(\.title), ["deploy", "logs"])
        XCTAssertEqual(sections[1].subtitle, "cmux-macmini")
    }

    func testUnifiedInboxSectionsGroupByMachineAndPreferAccessoryLabel() {
        let sections = UnifiedInboxWorkspaceDeviceSectionBuilder.makeSections(
            items: [
                UnifiedInboxItem(
                    kind: .workspace,
                    workspaceID: "workspace-1",
                    machineID: "machine-mini",
                    teamID: "team",
                    title: "build",
                    preview: "cargo test",
                    unreadCount: 0,
                    sortDate: Date(timeIntervalSince1970: 100),
                    accessoryLabel: "Mac mini",
                    symbolName: "terminal",
                    tmuxSessionName: "build",
                    tailscaleHostname: "cmux-macmini"
                ),
                UnifiedInboxItem(
                    kind: .workspace,
                    workspaceID: "workspace-2",
                    machineID: "machine-laptop",
                    teamID: "team",
                    title: "feature",
                    preview: "nvim",
                    unreadCount: 1,
                    sortDate: Date(timeIntervalSince1970: 200),
                    accessoryLabel: "MacBook Pro",
                    symbolName: "terminal",
                    tmuxSessionName: "feature",
                    tailscaleHostname: "lawrence-mbp"
                ),
                UnifiedInboxItem(
                    kind: .workspace,
                    workspaceID: "workspace-3",
                    machineID: "machine-mini",
                    teamID: "team",
                    title: "ops",
                    preview: "htop",
                    unreadCount: 0,
                    sortDate: Date(timeIntervalSince1970: 150),
                    accessoryLabel: "Mac mini",
                    symbolName: "terminal",
                    tmuxSessionName: "ops",
                    tailscaleHostname: "cmux-macmini"
                ),
            ]
        )

        XCTAssertEqual(sections.map(\.title), ["MacBook Pro", "Mac mini"])
        XCTAssertEqual(sections[0].items.map(\.title), ["feature"])
        XCTAssertEqual(sections[0].subtitle, "lawrence-mbp")
        XCTAssertEqual(sections[1].items.map(\.title), ["ops", "build"])
        XCTAssertEqual(sections[1].subtitle, "cmux-macmini")
    }

    func testResolveForAppRequiresEnableFlag() {
        let env = [
            "CMUX_LIVE_ANCHORMUX_HOST": "127.0.0.1",
            "CMUX_LIVE_ANCHORMUX_PORT": "9001",
            "CMUX_LIVE_ANCHORMUX_SESSION_ID": "session-123",
        ]

        XCTAssertNil(
            LiveAnchormuxConfig.resolveForApp(env: env, fileManager: .default)
        )
    }

    func testResolveForAppUsesExplicitConfigPathWithoutTokens() throws {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            create: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let configPath = directory.appendingPathComponent("anchormux.json")
        let configData = """
        {
          "host": "127.0.0.1",
          "port": 43210,
          "session_id": "desktop-surface-1"
        }
        """.data(using: .utf8)!
        try configData.write(to: configPath)

        let env = [
            "CMUX_LIVE_ANCHORMUX_ENABLED": "1",
            "CMUX_LIVE_ANCHORMUX_CONFIG_PATH": configPath.path,
        ]

        let resolved = LiveAnchormuxConfig.resolveForApp(
            env: env,
            fileManager: .default
        )

        XCTAssertEqual(resolved?.host, "127.0.0.1")
        XCTAssertEqual(resolved?.port, 43210)
        XCTAssertEqual(resolved?.sessionID, "desktop-surface-1")
        XCTAssertNil(resolved?.readyToken)
        XCTAssertNil(resolved?.desktopToken)
        XCTAssertEqual(resolved?.configPath, configPath.path)
        XCTAssertEqual(resolved?.workspaceItems.count, 1)
        XCTAssertEqual(resolved?.workspaceItems.first?.sessionID, "desktop-surface-1")
    }

    func testResolveForLiveTestReadsTokensFromEnvironment() {
        let env = [
            "CMUX_LIVE_ANCHORMUX_HOST": "127.0.0.1",
            "CMUX_LIVE_ANCHORMUX_PORT": "9002",
            "CMUX_LIVE_ANCHORMUX_SESSION_ID": "desktop-surface-2",
            "CMUX_LIVE_ANCHORMUX_READY_TOKEN": "IOS_READY_1",
            "CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN": "DESKTOP_READY_1",
        ]

        let resolved = LiveAnchormuxConfig.resolveForLiveTest(
            env: env,
            fileManager: .default
        )

        XCTAssertEqual(resolved?.host, "127.0.0.1")
        XCTAssertEqual(resolved?.port, 9002)
        XCTAssertEqual(resolved?.sessionID, "desktop-surface-2")
        XCTAssertEqual(resolved?.readyToken, "IOS_READY_1")
        XCTAssertEqual(resolved?.desktopToken, "DESKTOP_READY_1")
        XCTAssertNil(resolved?.configPath)
        XCTAssertEqual(resolved?.workspaceItems.first?.sessionID, "desktop-surface-2")
    }

    func testResolveForAppReadsWorkspaceItemsAndAutoOpenSession() throws {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            create: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let configPath = directory.appendingPathComponent("anchormux-items.json")
        let configData = """
        {
          "host": "127.0.0.1",
          "port": 52200,
          "session_id": "desktop-surface-primary",
          "auto_open_session_id": "desktop-surface-2",
          "workspace_items": [
            {
              "workspace_id": "workspace-1",
              "session_id": "desktop-surface-1",
              "machine_id": "anchormux-live-mac",
              "title": "Build logs",
              "preview": "SYNC_TOKEN_1",
              "accessory_label": "Desktop",
              "unread_count": 0,
              "sort_date_ms": 1700000000000
            },
            {
              "workspace_id": "workspace-2",
              "session_id": "desktop-surface-2",
              "machine_id": "anchormux-live-mac",
              "title": "btop",
              "preview": "SYNC_TOKEN_2",
              "accessory_label": "Desktop",
              "unread_count": 1,
              "sort_date_ms": 1700000001000
            }
          ]
        }
        """.data(using: .utf8)!
        try configData.write(to: configPath)

        let env = [
            "CMUX_LIVE_ANCHORMUX_ENABLED": "1",
            "CMUX_LIVE_ANCHORMUX_CONFIG_PATH": configPath.path,
        ]

        let resolved = LiveAnchormuxConfig.resolveForApp(
            env: env,
            fileManager: .default
        )

        XCTAssertEqual(resolved?.workspaceItems.count, 2)
        XCTAssertEqual(resolved?.workspaceItems.first?.title, "btop")
        XCTAssertEqual(resolved?.workspaceItems.first?.preview, "SYNC_TOKEN_2")
        XCTAssertEqual(resolved?.autoOpenSessionID, "desktop-surface-2")
        XCTAssertEqual(resolved?.configPath, configPath.path)
        XCTAssertEqual(resolved?.autoOpenInboxItem()?.tmuxSessionName, "desktop-surface-2")
    }

    func testResolveForAppPrefersConfigFileWorkspaceItemsOverEnvironmentFallback() throws {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            create: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let configPath = directory.appendingPathComponent("anchormux-precedence.json")
        let configData = """
        {
          "host": "127.0.0.1",
          "port": 54400,
          "session_id": "desktop-surface-config",
          "auto_open_session_id": "desktop-surface-config",
          "workspace_items": [
            {
              "workspace_id": "workspace-config",
              "session_id": "desktop-surface-config",
              "machine_id": "anchormux-live-mac",
              "title": "Shared Desktop Session",
              "preview": "ANCHORMUX_SYNC_CONFIG",
              "accessory_label": "Desktop",
              "unread_count": 0,
              "sort_date_ms": 1700000002000
            }
          ]
        }
        """.data(using: .utf8)!
        try configData.write(to: configPath)

        let env = [
            "CMUX_LIVE_ANCHORMUX_ENABLED": "1",
            "CMUX_LIVE_ANCHORMUX_CONFIG_PATH": configPath.path,
            "CMUX_LIVE_ANCHORMUX_HOST": "127.0.0.1",
            "CMUX_LIVE_ANCHORMUX_PORT": "9009",
            "CMUX_LIVE_ANCHORMUX_SESSION_ID": "desktop-surface-env",
        ]

        let resolved = LiveAnchormuxConfig.resolveForApp(
            env: env,
            fileManager: .default
        )

        XCTAssertEqual(resolved?.port, 54400)
        XCTAssertEqual(resolved?.sessionID, "desktop-surface-config")
        XCTAssertEqual(resolved?.workspaceItems.count, 1)
        XCTAssertEqual(resolved?.workspaceItems.first?.title, "Shared Desktop Session")
        XCTAssertEqual(resolved?.workspaceItems.first?.preview, "ANCHORMUX_SYNC_CONFIG")
        XCTAssertEqual(resolved?.autoOpenSessionID, "desktop-surface-config")
        XCTAssertEqual(resolved?.configPath, configPath.path)
    }

    @MainActor
    func testConfigStoreReloadsWorkspaceItemsWhenConfigFileChanges() throws {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            create: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let configPath = directory.appendingPathComponent("anchormux-store.json")
        try """
        {
          "host": "127.0.0.1",
          "port": 54401,
          "session_id": "desktop-surface-1",
          "workspace_items": [
            {
              "workspace_id": "workspace-1",
              "session_id": "desktop-surface-1",
              "machine_id": "anchormux-live-mac",
              "title": "Initial",
              "preview": "one",
              "sort_date_ms": 1700000002000
            }
          ]
        }
        """.write(to: configPath, atomically: true, encoding: .utf8)

        let env = [
            "CMUX_LIVE_ANCHORMUX_ENABLED": "1",
            "CMUX_LIVE_ANCHORMUX_CONFIG_PATH": configPath.path,
        ]
        let initialConfig = try XCTUnwrap(
            LiveAnchormuxConfig.resolveForApp(env: env, fileManager: .default)
        )
        let store = LiveAnchormuxConfigStore(config: initialConfig, fileManager: .default)

        try """
        {
          "host": "127.0.0.1",
          "port": 54401,
          "session_id": "desktop-surface-2",
          "workspace_items": [
            {
              "workspace_id": "workspace-1",
              "session_id": "desktop-surface-1",
              "machine_id": "anchormux-live-mac",
              "title": "Initial",
              "preview": "one",
              "sort_date_ms": 1700000002000
            },
            {
              "workspace_id": "workspace-2",
              "session_id": "desktop-surface-2",
              "machine_id": "anchormux-live-mac",
              "title": "Second",
              "preview": "two",
              "sort_date_ms": 1700000003000
            }
          ]
        }
        """.write(to: configPath, atomically: false, encoding: .utf8)

        store.reloadFromDiskForTesting()

        XCTAssertEqual(store.config.workspaceItems.count, 2)
        XCTAssertEqual(store.config.workspaceItems.first?.title, "Second")
    }
}
