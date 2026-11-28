use super::*;
use serde_json::json;

#[test]
fn a_clean_menu_setup_has_no_problems() {
    let root = json!({
        "actions": {
            "codex": {"type": "agent", "agent": "codex", "target": "currentTerminal"},
            "build": {"command": "make"}
        },
        "contextMenus": {"layouts": {"workspaceRow": {
            "items": ["renameWorkspace", "-", {"key": "group:a", "title": "Mine", "items": ["closeWorkspace"]},
                      {"key": "folder:more", "items": []}],
            "hidden": ["workspace.copyPath"]
        }}},
        "workspaceGroups": {"byCwd": {"~/src/*": {"contextMenu": [
            {"action": "renameWorkspace"}, {"action": "cmuxConfig.build"}, {"action": "codex"},
            {"action": "newWorkspace"}
        ]}}}
    });
    assert_eq!(problems(&root), Vec::new());
}

#[test]
fn a_name_repeated_elsewhere_is_found_on_its_own_line() {
    let text = r#"{
  "actions": {
    "a": { "command": "x", "target": "currentTerminal" },
    "b": {
      "command": "y",
      "target": "elsewhere"
    }
  },
  "contextMenus": {
    "layouts": {
      "pane": { "items": ["no.such.row"] },
      "tab": {
        "items": ["no.such.row"]
      }
    }
  }
}
"#;
    let root = jsonc::parse(text).unwrap();
    let lines: Vec<_> = problems(&root).iter().map(|p| (p.path.clone(), p.line(text))).collect();
    assert_eq!(
        lines,
        [
            ("actions.b.target".to_owned(), Some(6)),
            ("contextMenus.layouts.pane.no.such.row".to_owned(), Some(11)),
            ("contextMenus.layouts.tab.no.such.row".to_owned(), Some(13)),
        ]
    );
}

#[test]
fn each_skipped_entry_is_named() {
    let root = json!({
        "actions": {"a": "x", "b": {"type": "command"}, "c": {"agent": "claude --x"}, "d": {"type": "workspace"}},
        "contextMenus": {"layouts": {"pane": {"items": [1]}, "tab": {"items": ["no.such.row"]}}},
        "workspaceGroups": {"byCwd": {"g": {"contextMenu": [{"title": "x"}, {"action": "nope"}]}}}
    });
    let paths: Vec<_> = problems(&root).into_iter().map(|p| p.path).collect();
    assert_eq!(
        paths,
        [
            "actions.a",
            "actions.b",
            "actions.c",
            "actions.d",
            "contextMenus.layouts.pane",
            "contextMenus.layouts.tab.no.such.row",
            "workspaceGroups.byCwd.g.contextMenu.0",
            "workspaceGroups.byCwd.g.contextMenu.1",
        ]
    );
}
