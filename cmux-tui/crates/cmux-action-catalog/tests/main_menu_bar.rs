//! Every action the catalog places in a main menu (`main_menu`) is a row of that menu in the app's
//! menu bar, or a command palette row by a decision this file names with its reason.
//!
//! The app's menu bar is compact: `MainMenu.compactActionIDs` in `MainMenu.swift` lists the rows each
//! top menu shows, and `MainMenu.make` places a few by hand (`registry.makeMenuItem(for:)`). A
//! placement on neither went missing with no sign: Screen Sharing (`macScreen.open`, `main_menu:
//! Some("file")`) was in no menu. This test fails until each placement is shown or listed in
//! [`PALETTE_ONLY`].

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

const MAIN_MENU_SWIFT: &str = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/MainMenu.swift";

const COMPACT: &str =
    "Most actions stay out of the compact menu bar; the command palette lists every action";

/// Placements the menu bar leaves out on purpose, as (menu, reason, ids). Each stays a command
/// palette row (`MainMenuPlacementTests.removedMainMenuActionsResolveFromPaletteSearch`).
#[rustfmt::skip]
const PALETTE_ONLY: &[(&str, &str, &[&str])] = &[
    (
        "app",
        "One Quit: Quit cmux is the cmux menu's only quit; the quits that end sessions are palette rows",
        &["quitKeepSessions", "quitEndSessions", "quitEndEverything"],
    ),
    (
        "app",
        COMPACT,
        &[
            "reloadConfiguration", "palette.openCmuxSettingsFile", "palette.openGhosttySettings",
            "palette.makeDefaultBrowser", "palette.makeDefaultTerminal", "settings.customizeMenus",
            "palette.applyUpdateIfAvailable", "palette.switchAppChannel", "updates.rollback",
            "palette.pro.upgrade",
        ],
    ),
    (
        "file",
        COMPACT,
        &[
            "window.closeOthers", "closeAllWindows", "palette.openFolderInVSCodeInline",
            "reopenPreviousSession", "nextSidebarTab", "prevSidebarTab", "moveWorkspaceUp",
            "moveWorkspaceDown", "palette.moveWorkspaceToTop", "selectWorkspaceByNumber",
            "moveWorkspaceToWindow", "moveWorkspaceToNewWindow", "renameWorkspace",
            "palette.clearWorkspaceName", "editWorkspaceDescription", "palette.closeOtherWorkspaces",
            "palette.closeWorkspacesBelow", "palette.closeWorkspacesAbove", "workspace.closeAll",
            "workspace.closeAllInAllWindows", "palette.toggleWorkspacePin",
            "palette.markWorkspaceRead", "palette.markWorkspaceUnread", "newWorkspaceGroup",
            "space.newWindow", "closeOtherTabsInPane", "navigate.next", "navigate.previous",
            "nextSurface", "prevSurface", "moveSurfaceLeft", "moveSurfaceRight",
            "moveSurfaceToPreviousPane", "moveSurfaceToNextPane", "moveSurfaceToPaneLeft",
            "moveSurfaceToPaneRight", "moveSurfaceToPaneUp", "moveSurfaceToPaneDown", "tab.search",
            "home.show", "home.tab", "home.channels", "home.newMessage", "home.invite",
            "home.inviteToTeam", "home.newChief", "importFromBrowser", "password.importCSV",
            "browserPrint", "browser.importFromFiles", "openDiffViewer",
            "palette.openDirectoryDiffViewer", "openMarkdownFile", "palette.addHarness",
            "computerUseFocus", "computerUseFocusCallingTerminal", "computerUseStop",
            "newCloudWorkspace", "newCloudMachine", "window.stash", "bookmark.import",
            "bookmark.importFromBrowser", "bookmark.export",
        ],
    ),
    (
        "edit",
        "Edit keeps the standard responder-chain rows: as menu key equivalents these would claim keys \
         terminal keybinds and panels expect",
        &[
            "sendCtrlFToTerminal", "find", "findInDirectory", "findNext", "findPrevious", "hideFind",
            "useSelectionForFind", "palette.toggleDictation",
        ],
    ),
    (
        "view",
        COMPACT,
        &[
            "newColumn", "newColumnLeft", "newRow", "newPaneAutoLayout",
            "equalizeSplits", "resizePaneLeft", "resizePaneRight", "resizePaneUp", "resizePaneDown",
            "toggleCanvasLayout", "canvasOverview", "canvasTidy", "canvasRevealFocusedPane",
            "palette.newSimulatorPane", "home.switchView", "home.toggleChiefPet",
            "home.previousConversation", "home.nextConversation", "toggleBrowserDeveloperTools",
            "showBrowserJavaScriptConsole", "inspectBrowserElement", "toggleBrowserFocusMode",
            "toggleBrowserDesignMode", "toggleReactGrab", "splitBrowserRight", "splitBrowserDown",
            "palette.browserOpenDefault", "saveFilePreview", "browser.extensions.menu",
            "browser.extensions.manage", "browser.extensions.webStore",
            "browser.extensions.loadUnpacked", "agentPaneZoomIn", "agentPaneZoomOut",
            "agentPaneZoomReset", "appearance.uiScale.increase", "appearance.uiScale.decrease",
            "appearance.uiScale.reset", "terminal.increaseFontSize", "terminal.decreaseFontSize",
            "terminal.resetFontSize", "layout.undo", "bookmark.addPage", "bookmark.addAllTabs",
            "bookmark.open", "bookmark.toggleBar", "bookmark.manager",
        ],
    ),
    (
        "window",
        COMPACT,
        &[
            "search.chats", "palette.openTaskManager", "palette.sleepyMode", "space.newIncognito",
            "space.selectByNumber", "palette.openCloudPane", "screenshots.open", "showNotifications",
            "agent.jumpToNextNeedingInput", "jumpToUnread", "attention.goTo", "jumpToLastPrompt",
            "toggleUnread", "markAllNotificationsRead", "clearAllNotifications", "agentActivity.open",
            "palette.mobileConnect", "focusHistoryBack", "focusHistoryForward", "focusHistoryLast",
            "focusHistoryBackSession", "recentlyFocused", "recentlyClosed", "history.commands", "history.show",
            "agentHistory.show", "history.search", "history.resumeAgentSession", "history.clear",
            "stash.show",
        ],
    ),
    (
        "file",
        "Step A of an app FFI change (docs/ci/app-ffi-release.md): the pinned FFI has no File placement \
         yet; step B, after the re-pin, puts it under New Agent Chat in MainMenu.compactActionIDs",
        &["palette.newCloudChat"],
    ),
    (
        "help",
        "Help keeps to the Support rows; diagnostics, links and sharing stay palette rows",
        &[
            "cloudDiagnostics", "help.featureFlags", "help.troubleshooting", "help.discord",
            "help.followOnX", "help.github", "help.revealLogs", "help.copyLogs", "app.shareCmux",
        ],
    ),
];

fn main_menu_swift() -> String {
    // affected-reads: Packages/macOS/CmuxNext/Sources/CmuxNextApp/MainMenu.swift
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..").join(MAIN_MENU_SWIFT);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// The quoted strings of `line`.
fn quoted(line: &str) -> Vec<String> {
    line.split('"').skip(1).step_by(2).map(str::to_owned).collect()
}

/// `MainMenu.compactActionIDs`: each top menu's rows, in order.
fn compact_rows(swift: &str) -> BTreeMap<String, Vec<String>> {
    let start = swift
        .find("static let compactActionIDs")
        .unwrap_or_else(|| panic!("{MAIN_MENU_SWIFT}: no `static let compactActionIDs`"));
    let mut rows: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut menu: Option<String> = None;
    for line in swift[start..].lines().skip(1) {
        let line = line.trim();
        if line == "]" {
            break;
        }
        if let Some(rest) = line.strip_prefix('.') {
            let (name, ids) =
                rest.split_once(':').unwrap_or_else(|| panic!("{MAIN_MENU_SWIFT}: {line}"));
            menu = Some(name.to_owned());
            rows.entry(name.to_owned()).or_default().extend(quoted(ids));
        } else if let Some(menu) = &menu {
            rows.entry(menu.clone()).or_default().extend(quoted(line));
        }
    }
    assert!(!rows.is_empty(), "{MAIN_MENU_SWIFT}: compactActionIDs lists no rows");
    rows
}

/// The rows `MainMenu.make` places by hand (About, Quit, Zoom under Minimize).
fn hand_placed(swift: &str) -> BTreeSet<String> {
    swift
        .split("registry.makeMenuItem(for: \"")
        .skip(1)
        .filter_map(|rest| rest.split_once('"').map(|(id, _)| id.to_owned()))
        .collect()
}

#[test]
fn every_main_menu_placement_is_shown_or_palette_only_by_reason() {
    let swift = main_menu_swift();
    let compact = compact_rows(&swift);
    let hand = hand_placed(&swift);
    let mut problems = Vec::new();

    // A compact row whose action is not in that menu is dropped by `compactMainMenuItems`.
    let mut shown = BTreeSet::new();
    for (menu, ids) in &compact {
        for id in ids {
            match cmux_action_catalog::find(id) {
                None => problems.push(format!("compactActionIDs[.{menu}] lists {id}, not a catalog action")),
                Some(action) if action.main_menu != Some(menu.as_str()) => problems.push(format!(
                    "compactActionIDs[.{menu}] lists {id}, whose main_menu is {:?}: the menu drops it",
                    action.main_menu
                )),
                Some(_) => {}
            }
            if !shown.insert(id.clone()) {
                problems.push(format!("compactActionIDs lists {id} twice: the bar shows it twice"));
            }
        }
    }
    shown.extend(hand.iter().cloned());

    let mut palette_only = BTreeSet::new();
    for (menu, reason, ids) in PALETTE_ONLY {
        assert!(!reason.trim().is_empty(), "a PALETTE_ONLY group in {menu} has no reason");
        for id in *ids {
            if !palette_only.insert(*id) {
                problems.push(format!("PALETTE_ONLY lists {id} twice"));
            }
            match cmux_action_catalog::find(id) {
                None => problems
                    .push(format!("PALETTE_ONLY lists {id}, not a catalog action: delete it")),
                Some(action) if action.main_menu != Some(*menu) => problems.push(format!(
                    "PALETTE_ONLY lists {id} under {menu}, but its main_menu is {:?}",
                    action.main_menu
                )),
                Some(_) => {}
            }
            if shown.contains(*id) {
                problems.push(format!(
                    "{id} is in the menu bar and in PALETTE_ONLY: delete it from PALETTE_ONLY"
                ));
            }
        }
    }

    for action in cmux_action_catalog::actions() {
        let Some(menu) = action.main_menu else { continue };
        if !shown.contains(action.id) && !palette_only.contains(action.id) {
            problems.push(format!(
                "{} has main_menu {menu:?} but is in no menu: add it to compactActionIDs[.{menu}] in \
                 {MAIN_MENU_SWIFT}, or to PALETTE_ONLY here with the reason it stays out",
                action.id
            ));
        }
    }
    assert!(
        problems.is_empty(),
        "{} main menu placement problems:\n{}",
        problems.len(),
        problems.join("\n")
    );
}

/// Screen Sharing is a File row beside Connect to Machine… and Add Device….
#[test]
fn screen_sharing_is_in_file_beside_the_device_rows() {
    let file = compact_rows(&main_menu_swift()).remove("file").expect("a File menu");
    let at = |id: &str| {
        file.iter()
            .position(|row| row == id)
            .unwrap_or_else(|| panic!("{id} not in File: {file:?}"))
    };
    let screen = at("macScreen.open");
    assert_eq!(at("remote.connect"), screen + 1, "{file:?}");
    assert_eq!(at("device.add"), screen + 2, "{file:?}");
    assert_eq!(cmux_action_catalog::find("macScreen.open").and_then(|a| a.main_menu), Some("file"));
}
