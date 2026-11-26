use super::*;

#[test]
fn sidebar_tree_gives_workspace_tab_and_terminal_rows() {
    let tree = json!({"workspaces": [
        {"id": 1, "key": "ws_a", "name": "billing", "short_id": "a1", "active": false,
         "screens": [{"panes": [{"id": 3, "layout": {"type": "leaf", "pane": 3},
            "tabs": [
                {"surface": 7, "terminal_id": "term_7", "title": "cargo test", "cwd": "/src/billing"},
                {"surface": 8, "terminal_id": "term_8", "title": "old", "dead": true},
                {"surface": 9, "title": "Docs", "url": "https://example.com/docs"}
            ]}]}]},
        {"id": 2, "key": "ws_b", "name": "search", "active": true,
         "screens": [{"panes": [{"tabs": [{"surface": 11, "terminal_id": "term_11", "title": "zsh"}]}]}]}
    ]});
    let (rows, terminals) = sidebar_rows(&tree);
    let titles = rows.iter().map(|row| row.title.as_str()).collect::<Vec<_>>();
    assert_eq!(titles, ["billing", "cargo test", "old", "Docs", "search", "zsh"]);
    assert!(rows.iter().all(|row| row.kind == Kind::Workspace && !row.found));
    assert_eq!(rows[0].subtitle, "3 tab(s)");
    assert_eq!(rows[3].record["url"], "https://example.com/docs");
    // `--json` carries the opaque IDs; the numeric surface and the sidebar's short handle
    // stay on the legacy wire (the short handle still matches a typed handle).
    assert_eq!(rows[1].record["terminal_id"], "term_7");
    assert!(rows.iter().all(|row| row.record.get("surface").is_none()));
    assert!(rows.iter().all(|row| row.record.get("short_id").is_none()));
    assert!(rows[0].handles.contains(&"a1".to_owned()));
    // The active workspace's terminal first; a dead terminal and a browser tab are not searched.
    assert_eq!(terminals.iter().map(|terminal| terminal.surface).collect::<Vec<_>>(), [11, 7]);
    assert_eq!(terminals[1].workspace, "billing");
}
