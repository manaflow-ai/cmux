//! The lines the macOS app sends for its Layout and TabMove requests reach the daemon as sent.
//! Spec/fixtures/layout-tab-move-requests/lines.json records them before their
//! migration to the generated `<Name>Request` types; LayoutTabMoveRequestWireGoldenTests
//! (CmuxNextDaemonTests) proves the app encodes exactly these lines. Here every line goes through
//! the server's own `Request` parse, and the fullest lines read back field by field. Chromium keeps
//! the same idea in mojo/public/tools/bindings golden tests: one recorded message checked on both
//! ends.
use super::super::tabs_wire::{
    MoveTabParams, MoveTabToNewWorkspaceParams, MoveTabToSplitParams, MoveTabToWorkspaceParams,
};
use super::super::*;
use super::MoveTabToColumnParams;
use crate::model::{ColumnDock, DockEdge, DockMode, DockRole};

const FIXTURE: &str = include_str!("../../../../spec/fixtures/layout-tab-move-requests/lines.json");

/// `(name, line)` of every recorded request.
fn entries() -> Vec<(String, Value)> {
    let fixture: Value =
        serde_json::from_str(FIXTURE).expect("spec/fixtures/layout-tab-move-requests/lines.json");
    fixture["requests"]
        .as_array()
        .expect("requests in lines.json")
        .iter()
        .map(|entry| (entry["name"].as_str().expect("name").to_owned(), entry["line"].clone()))
        .collect()
}

fn line(name: &str) -> Value {
    entries()
        .into_iter()
        .find(|(entry, _)| entry == name)
        .unwrap_or_else(|| panic!("no {name} in lines.json"))
        .1
}

/// The command as the connection reads it: one JSON text through `line_parses::parse`.
fn parse(name: &str) -> Command {
    parse_line(name, &line(name))
}

fn parse_line(name: &str, line: &Value) -> Command {
    let text = line.to_string();
    crate::line_parses::parse::<Request>(&text)
        .unwrap_or_else(|error| panic!("{name}: {error}"))
        .cmd
}

#[test]
fn every_recorded_line_parses_as_its_command() {
    let lines = entries();
    assert_eq!(lines.len(), 40, "lines.json has {} lines", lines.len());
    for (name, line) in lines {
        let request = crate::line_parses::parse::<Request>(&line.to_string())
            .unwrap_or_else(|error| panic!("{name}: {error}"));
        assert_eq!(request.id, Some(json!(1)), "{name}");
        assert_eq!(Some(request.cmd.wire_name()), line["cmd"].as_str(), "{name}");
    }
}

#[test]
fn layout_lines_fill_their_params() {
    let Command::SetSplitRatio { split, ratio, transaction } =
        parse("set-split-ratio in a drag transaction")
    else {
        panic!("not set-split-ratio")
    };
    assert_eq!((split, ratio, transaction), (5, 0.25, Some(41)));
    let Command::SetViewportPaneWidth { pane, width, transaction } =
        parse("set-viewport-pane-width in a drag transaction")
    else {
        panic!("not set-viewport-pane-width")
    };
    assert_eq!((pane, width, transaction), (4, 0.5, Some(42)));
    let Command::UndoLayout { pane, revision, confirm_close } =
        parse("undo-layout confirming a close")
    else {
        panic!("not undo-layout")
    };
    assert_eq!((pane, revision, confirm_close), (4, Some(17), true));
    let Command::SetColumnDock { pane, dock, edge, mode, permanent, pinned, role, transaction } =
        parse("set-column-dock with every field")
    else {
        panic!("not set-column-dock")
    };
    assert_eq!(
        (pane, dock, edge.as_deref(), mode.as_deref()),
        (4, true, Some("right"), Some("overlay"))
    );
    assert_eq!(
        (role.as_deref(), pinned, permanent, transaction),
        (Some("agent_chat"), Some(true), None, Some(44))
    );
    let Command::SetColumnDock { dock, edge, mode, .. } = parse("set-column-dock undocking") else {
        panic!("not set-column-dock")
    };
    assert_eq!((dock, edge, mode), (false, None, None));
    let Command::SwapPane { dir, target, .. } = parse("swap-pane by direction") else {
        panic!("not swap-pane")
    };
    assert_eq!((dir.as_deref(), target), (Some("up"), None));
    let Command::SwapPane { dir, target, .. } = parse("swap-pane with a pane") else {
        panic!("not swap-pane")
    };
    assert_eq!((dir, target), (None, Some(6)));
    let Command::ZoomPane { pane, mode } = parse("zoom-pane with every field") else {
        panic!("not zoom-pane")
    };
    assert_eq!((pane, mode.as_deref()), (Some(4), Some("on")));
}

#[test]
fn tab_move_lines_fill_their_params() {
    let Command::MoveTab(MoveTabParams { surface, pane, index, transaction }) =
        parse("move-tab in a drag transaction")
    else {
        panic!("not move-tab")
    };
    assert_eq!((surface, pane, index, transaction.as_deref()), (7, 4, 0, Some("drag-1")));
    let Command::MoveTabToWorkspace(MoveTabToWorkspaceParams { surface, workspace, transaction }) =
        parse("move-tab-to-workspace with every field")
    else {
        panic!("not move-tab-to-workspace")
    };
    assert_eq!((surface, workspace, transaction.as_deref()), (7, Some(3), Some("drag-1")));
    let Command::MoveTabToNewWorkspace(MoveTabToNewWorkspaceParams {
        surface,
        group,
        index,
        name,
        transaction,
    }) = parse("move-tab-to-new-workspace with every field")
    else {
        panic!("not move-tab-to-new-workspace")
    };
    assert_eq!(
        (surface, group.as_deref(), index, name.as_deref(), transaction.as_deref()),
        (7, Some("grp_1"), Some(0), Some("Logs"), Some("drag-1"))
    );
    let Command::MoveTabToSplit(MoveTabToSplitParams {
        edge,
        ratio,
        respawn,
        keep_focus,
        transaction,
        ..
    }) = parse("move-tab-to-split keeping focus with every field")
    else {
        panic!("not move-tab-to-split")
    };
    assert_eq!(
        (edge.as_str(), ratio, keep_focus, transaction.as_deref()),
        ("top", Some(0.5), true, Some("drag-1"))
    );
    assert!(respawn.is_none());
    let Command::MoveTabToSplit(MoveTabToSplitParams { keep_focus, .. }) =
        parse("move-tab-to-split with every field")
    else {
        panic!("not move-tab-to-split")
    };
    assert!(!keep_focus, "keep_focus is sent only by the keeping-focus request");
}

/// The fullest column drop: every member, and the pinned dock the schema's `ColumnPin` does not
/// declare yet (`pinned-dock-alone-v1`), lands in the daemon's params.
#[test]
fn a_full_move_tab_to_column_line_fills_every_param() {
    let Command::MoveTabToColumn(params) = parse("move-tab-to-column with every field") else {
        panic!("not move-tab-to-column")
    };
    let MoveTabToColumnParams {
        surface,
        pane,
        screen,
        after_column,
        width,
        dock,
        sticky,
        respawn,
        keep_focus,
        transaction,
    } = params;
    assert_eq!(
        (surface, pane, screen, after_column, width),
        (7, Some(4), None, Some(9), Some(0.5))
    );
    assert_eq!(
        dock,
        Some(ColumnDock {
            edge: DockEdge::Left,
            mode: DockMode::Docked,
            role: Some(DockRole::AgentChat),
            permanent: false,
            pinned: true,
            allow_tabs: false,
        })
    );
    assert!(sticky.is_none() && respawn.is_none() && keep_focus);
    assert_eq!(transaction.as_deref(), Some("drag-1"));
    let Command::MoveTabToColumn(by_screen) = parse("move-tab-to-column by screen") else {
        panic!("not move-tab-to-column")
    };
    assert_eq!((by_screen.screen, by_screen.pane, by_screen.dock), (Some(2), None, None));
}

/// Every respawn the app sends becomes the daemon's fresh tab: a terminal with the caller's
/// directory, id and environment keys as given (`FOO_BAR`, `camelKey`), or a browser tab.
#[test]
fn every_respawn_line_becomes_its_fresh_tab() {
    let mut seen = 0;
    for (name, line) in entries() {
        let respawn = match parse_line(&name, &line) {
            Command::MoveTabToSplit(MoveTabToSplitParams { respawn: Some(respawn), .. }) => respawn,
            Command::MoveTabToColumn(MoveTabToColumnParams { respawn: Some(respawn), .. }) => {
                respawn
            }
            _ => continue,
        };
        seen += 1;
        let sent = &line["respawn"];
        match respawn.into_respawn(true).unwrap_or_else(|error| panic!("{name}: {error}")) {
            crate::mux::SplitRespawn::Terminal(options) => {
                assert_eq!(sent["kind"], "terminal", "{name}");
                assert_eq!(options.cwd.as_deref(), sent["cwd"].as_str(), "{name}");
                assert_eq!(options.terminal_id.as_deref(), sent["terminal_id"].as_str(), "{name}");
                if let Some(env) = sent["env"].as_object() {
                    for (key, value) in env {
                        assert!(
                            options
                                .env
                                .iter()
                                .any(|(k, v)| k == key && Some(v.as_str()) == value.as_str()),
                            "{name}: {key} is not in the terminal's env {:?}",
                            options.env
                        );
                    }
                }
            }
            crate::mux::SplitRespawn::Browser(record) => {
                assert_eq!(sent["kind"], "browser", "{name}");
                assert_eq!(Some(record.url.as_str()), sent["url"].as_str(), "{name}");
                assert_eq!(Some(record.engine.as_str()), sent["engine"].as_str(), "{name}");
                assert_eq!(record.profile_id.as_deref(), sent["profile_id"].as_str(), "{name}");
            }
        }
    }
    assert_eq!(seen, 7, "respawn lines in lines.json");
}
