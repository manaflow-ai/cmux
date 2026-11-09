//! Reading classic's session: what each panel becomes, the limits a hostile
//! file meets, scrollback from checkpoints after a crash, and which file a
//! run reads.

use std::path::Path;

use cmux_classic_import::decode::{self, Error};
use cmux_classic_import::model::{Agent, Layout, Orientation, Snapshot};
use cmux_classic_import::read;
use cmux_classic_import::source::Finder;
use serde_json::{Value, json};

const PANEL_A: &str = "aaaaaaaa-0000-4000-8000-00000000000a";
const PANEL_B: &str = "bbbbbbbb-0000-4000-8000-00000000000b";

fn session(workspaces: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({"version": 1, "createdAt": 5.5, "windows": [{"tabManager": {"workspaces": workspaces}}]})).unwrap()
}

fn decode_one(workspace: Value) -> Snapshot {
    decode::decode(&session(json!([workspace])), None, "/Users/me").unwrap()
}

fn terminal(id: &str, terminal: Value) -> Value {
    json!({"id": id, "type": "terminal", "terminal": terminal})
}

#[test]
fn a_split_keeps_its_axis_divider_and_selection_and_a_panel_nothing_shows_closes_up() {
    let snapshot = decode_one(json!({
        "stableId": "w", "currentDirectory": "/tmp",
        "panels": [
            terminal(PANEL_A, json!({"workingDirectory": "/a"})),
            terminal(PANEL_B, json!({"workingDirectory": "/b"})),
            {"id": "md", "type": "markdown"},
        ],
        "layout": {"type": "split", "split": {
            "orientation": "vertical", "dividerPosition": 0.99,
            "first": {"type": "pane", "pane": {"panelIds": [PANEL_A, "gone", PANEL_B], "selectedPanelId": PANEL_B}},
            "second": {"type": "pane", "pane": {"panelIds": ["md"]}},
        }},
    }));
    let workspace = &snapshot.windows[0].workspaces[0];
    assert!(workspace.left_out_panels);
    let Layout::Pane(pane) = &workspace.layout else { panic!("{:?}", workspace.layout) };
    assert_eq!(pane.tabs.len(), 2);
    assert_eq!(pane.selected_tab, 1);

    let split = decode_one(json!({
        "stableId": "w", "currentDirectory": "/tmp",
        "panels": [terminal(PANEL_A, json!({})), terminal(PANEL_B, json!({}))],
        "layout": {"type": "split", "split": {
            "orientation": "vertical", "dividerPosition": 0.99,
            "first": {"type": "pane", "pane": {"panelIds": [PANEL_A]}},
            "second": {"type": "pane", "pane": {"panelIds": [PANEL_B]}},
        }},
    }));
    let Layout::Split { orientation, ratio, .. } = &split.windows[0].workspaces[0].layout else {
        panic!()
    };
    assert_eq!((*orientation, *ratio), (Orientation::Vertical, 0.95));
}

#[test]
fn browser_tabs_agents_and_ended_agents_come_over() {
    let snapshot = decode_one(json!({
        "stableId": "w", "currentDirectory": "/proj",
        "panels": [
            {"id": "b", "type": "browser", "title": "Page title", "browser": {"urlString": "https://cmux.com"}},
            {"id": "e", "type": "browser", "browser": {"urlString": ""}},
            terminal("c", json!({"agent": {"kind": "claude", "sessionId": "s-1"}})),
            terminal("x", json!({"resumeBinding": {"source": "agent-hook", "kind": "codex", "checkpointId": "s-2", "cwd": "/x"}})),
            terminal("cli", json!({"resumeBinding": {"source": "cli", "kind": "codex", "checkpointId": "s-3"}})),
            terminal("ssh", json!({"resumeBinding": {"source": "agent-hook", "kind": "codex", "checkpointId": "s-4", "launchFlavor": {"kind": "ssh"}}})),
            terminal("other", json!({"agent": {"kind": "aider", "sessionId": "s-5"}})),
        ],
    }));
    let tabs =
        snapshot.windows[0].workspaces[0].layout.tabs().into_iter().cloned().collect::<Vec<_>>();
    assert_eq!(tabs.len(), 6);
    assert_eq!(tabs[0].url.as_deref(), Some("https://cmux.com"));
    assert_eq!(tabs[0].title, None);
    assert_eq!(
        tabs[1].agent,
        Some(Agent { harness: "claude".into(), session_id: "s-1".into(), working_directory: None })
    );
    assert_eq!(tabs[2].agent.as_ref().unwrap().working_directory.as_deref(), Some("/x"));
    assert!(tabs[3..].iter().all(|tab| tab.agent.is_none()));
}

#[test]
fn ssh_and_cloud_vm_workspaces_say_where_they_ran() {
    let snapshot = decode::decode(
        &session(json!([
            {"stableId": "ssh", "remote": {"destination": " me@host ", "port": 2222}},
            {"stableId": "flag", "remote": {"destination": "-oProxyCommand=x"}},
            {"stableId": "vm", "cloudVM": {"vmID": "vm-1"}},
            {"stableId": "old-vm", "remote": {"transport": "websocket", "destination": "x"}},
            {"stableId": "old-vm-id", "remote": {"managedCloudVMID": " vm-2 ", "destination": "x"}},
        ])),
        None,
        "/h",
    )
    .unwrap();
    let workspaces = &snapshot.windows[0].workspaces;
    assert_eq!(workspaces[0].remote.as_ref().unwrap().ssh_destination(), "me@host:2222");
    assert!(workspaces[1].remote.is_none());
    assert_eq!(workspaces[2].cloud_vm.as_deref(), Some("vm-1"));
    assert_eq!((workspaces[3].cloud_vm.as_deref(), &workspaces[3].remote), (Some(""), &None));
    assert_eq!(workspaces[4].cloud_vm.as_deref(), Some("vm-2"));
}

#[test]
fn too_many_workspaces_a_deep_layout_oversized_scrollback_or_a_huge_key_are_refused() {
    let many: Vec<Value> =
        (0..1_001).map(|_| json!({"currentDirectory": "/tmp", "panels": []})).collect();
    assert_eq!(decode::decode(&session(Value::Array(many)), None, "/h"), Err(Error::TooComplex));

    let pane = json!({"type": "pane", "pane": {"panelIds": []}});
    let mut layout = pane.clone();
    for _ in 0..65 {
        layout = json!({"type": "split", "split": {"first": layout, "second": pane}});
    }
    let deep = session(json!([{"currentDirectory": "/tmp", "panels": [], "layout": layout}]));
    assert_eq!(decode::decode(&deep, None, "/h"), Err(Error::TooComplex));

    let big = terminal("t", json!({"scrollback": "x".repeat(4 * 1024 * 1024 + 1)}));
    let scrollback = session(json!([{"currentDirectory": "/tmp", "panels": [big]}]));
    assert_eq!(decode::decode(&scrollback, None, "/h"), Err(Error::TooComplex));

    let key = format!("{{\"windows\":[],\"{}\":true}}", "k".repeat(64 * 1024 + 1));
    assert_eq!(decode::decode(key.as_bytes(), None, "/h"), Err(Error::TooComplex));
}

#[test]
fn a_thousand_workspaces_still_decode() {
    let workspaces: Vec<Value> =
        (0..1_000).map(|index| json!({"stableId": format!("w-{index}"), "currentDirectory": format!("/tmp/{index}"), "panels": []})).collect();
    let snapshot = decode::decode(&session(Value::Array(workspaces)), None, "/h").unwrap();
    assert_eq!(snapshot.workspaces().count(), 1_000);
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// After a crash the last save is an autosave with no scrollback: each
/// terminal's comes from its checkpoint. A quit save's own scrollback wins.
#[test]
fn a_crashed_classics_scrollback_comes_from_its_checkpoints_and_a_quit_saves_own_wins() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("cmux/session-com.cmuxterm.app.json");
    let checkpoints = root.path().join("cmux/session-com.cmuxterm.app-scrollback");
    let upper = PANEL_A.to_uppercase();
    write(
        &checkpoints.join(format!("{upper}.json")),
        &json!({"panelId": PANEL_A, "scrollback": "from checkpoint"}).to_string(),
    );
    write(
        &checkpoints.join(format!("{}.json", PANEL_B.to_uppercase())),
        &json!({"panelId": PANEL_A, "scrollback": "wrong panel"}).to_string(),
    );
    let autosave = session(
        json!([{"stableId": "w", "panels": [terminal(PANEL_A, json!({})), terminal(PANEL_B, json!({}))]}]),
    );
    std::fs::write(&file, &autosave).unwrap();
    assert_eq!(decode::checkpoint_folder(&file).as_deref(), Some(checkpoints.as_path()));
    let snapshot = decode::read_file(&file, "/h").unwrap().unwrap();
    let tabs =
        snapshot.windows[0].workspaces[0].layout.tabs().into_iter().cloned().collect::<Vec<_>>();
    assert_eq!(tabs[0].scrollback.as_deref(), Some("from checkpoint"));
    assert_eq!(tabs[1].scrollback, None);

    let quit = session(
        json!([{"stableId": "w", "panels": [terminal(PANEL_A, json!({})), terminal(PANEL_B, json!({"scrollback": "own"}))]}]),
    );
    std::fs::write(&file, &quit).unwrap();
    let snapshot = decode::read_file(&file, "/h").unwrap().unwrap();
    let tabs =
        snapshot.windows[0].workspaces[0].layout.tabs().into_iter().cloned().collect::<Vec<_>>();
    assert_eq!((tabs[0].scrollback.as_deref(), tabs[1].scrollback.as_deref()), (None, Some("own")));
    assert_eq!(
        decode::checkpoint_folder(
            &root.path().join("cmux/session-history/session-com.cmuxterm.app-1-w1.json")
        ),
        None
    );
}

/// A damaged session file is skipped for its `-previous` copy; a folder
/// that is gone opens the home folder.
#[test]
fn a_damaged_session_falls_back_to_its_copy_and_a_missing_folder_opens_home() {
    let root = tempfile::tempdir().unwrap();
    let support = root.path().join("support");
    let home = root.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    write(&support.join("cmux/session-com.cmuxterm.app.json"), "{damaged");
    let previous = support.join("cmux/session-com.cmuxterm.app-previous.json");
    std::fs::write(
        &previous,
        session(json!([{"stableId": "w", "currentDirectory": "/no/such/folder", "panels": []}])),
    )
    .unwrap();
    let finder = Finder::new(&support, Some("com.cmuxterm.app"));
    let save = read::read(&finder, None, &home).unwrap().unwrap();
    assert_eq!(save.source.path, previous.to_string_lossy());
    assert_eq!(save.source.created_at, Some(5.5));
    assert_eq!(save.snapshot.windows[0].workspaces[0].working_directory, home.to_string_lossy());
    assert_eq!(save.backups.len(), 2);
    assert_eq!(save.skipped.len(), 1);

    // One file only, damaged: that is the error.
    let only = support.join("cmux/session-com.cmuxterm.app.json");
    assert!(matches!(read::read(&finder, Some(&only), &home), Err(Error::Json(_))));
    // Nothing saved: no save, no error.
    let empty = Finder::new(&root.path().join("none"), None);
    assert_eq!(read::read(&empty, None, &home), Ok(None));
}

#[test]
fn the_newest_snapshot_is_any_classic_channels_never_another_apps() {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("cmux");
    write(&folder.join("session-com.cmuxterm.app.nightly.json"), "{}");
    write(&folder.join("session-com.other.app.json"), "{}");
    assert_eq!(
        decode::newest_snapshot(root.path()),
        folder.join("session-com.cmuxterm.app.nightly.json")
    );
    let empty = tempfile::tempdir().unwrap();
    assert_eq!(
        decode::newest_snapshot(empty.path()),
        empty.path().join("cmux/session-com.cmuxterm.app.json")
    );
}

/// A panel the layout names again (256 times in each of 16 panes) is placed
/// once, where it is first named: its scrollback is copied once, not once
/// per reference past every input budget.
#[test]
fn a_panel_named_again_in_the_layout_is_placed_once() {
    let scrollback = "x".repeat(2 * 1024 * 1024);
    let pane = json!({"type": "pane", "pane": {"panelIds": vec![PANEL_A; 256]}});
    let mut layout = pane.clone();
    for _ in 0..15 {
        layout = json!({"type": "split", "split": {"first": layout, "second": pane}});
    }
    let snapshot = decode_one(json!({
        "stableId": "w", "currentDirectory": "/tmp",
        "panels": [terminal(PANEL_A, json!({"scrollback": scrollback})), terminal(PANEL_B, json!({}))],
        "layout": {"type": "split", "split": {"first": layout,
            "second": {"type": "pane", "pane": {"panelIds": [PANEL_A, PANEL_B], "selectedPanelId": PANEL_B}}}},
    }));
    let tabs = snapshot.windows[0].workspaces[0].layout.tabs();
    assert_eq!(tabs.len(), 2);
    assert_eq!(tabs[0].scrollback.as_deref().map(str::len), Some(2 * 1024 * 1024));
    assert_eq!(tabs[1].scrollback, None);
    let Layout::Split { second, .. } = &snapshot.windows[0].workspaces[0].layout else { panic!() };
    let Layout::Pane(last) = second.as_ref() else { panic!("{second:?}") };
    assert_eq!(last.tabs.len(), 1);
    assert_eq!(last.selected_tab, 0);
}

/// Ids longer than a ledger step takes (256 bytes) never name a workspace or
/// a group: the workspace takes its derived key and comes over ungrouped.
#[test]
fn ids_too_long_for_the_ledger_are_not_keys() {
    let long = "k".repeat(257);
    let session = serde_json::to_vec(&json!({"version": 1, "windows": [{"tabManager": {
        "workspaces": [
            {"stableId": long, "workspaceId": "short", "currentDirectory": "/tmp", "panels": []},
            {"stableId": long, "currentDirectory": "/tmp", "groupId": long, "panels": []},
            {"stableId": "k".repeat(256), "currentDirectory": "/tmp", "panels": []},
        ],
        "workspaceGroups": [{"id": long, "name": "g"}, {"id": "g", "name": "g"}],
    }}]}))
    .unwrap();
    let snapshot = decode::decode(&session, None, "/h").unwrap();
    let window = &snapshot.windows[0];
    let keys: Vec<&str> =
        window.workspaces.iter().map(|workspace| workspace.key.as_str()).collect();
    assert_eq!(keys[0], "short");
    assert!(keys[1].starts_with("derived:"), "{}", keys[1]);
    assert_eq!(keys[2].len(), 256);
    assert_eq!(window.workspaces[1].group_id, None);
    let groups: Vec<&str> = window.groups.iter().map(|group| group.id.as_str()).collect();
    assert_eq!(groups, ["g"]);
}
