//! NEW-TERMINAL-INHERITS-CWD (cx-zld): through a real daemon, a terminal
//! that moved to another folder (`cd`, then its OSC 7 report) gives that
//! folder to every new terminal created beside it without a `cwd`: a new
//! tab, a split, a new pane and a new screen of its workspace. Like
//! Ghostty's `tab-`, `split-` and `window-inherit-working-directory`.
#![cfg(unix)]

use super::*;

/// The JSON `terminal list`, keyed by terminal id.
fn terminals(server: &HeadlessServer) -> Vec<(String, Option<String>)> {
    let listed = json_output(&json_cli(server, &["terminal", "list"]));
    listed
        .as_array()
        .unwrap_or_else(|| panic!("terminal list returns an array: {listed}"))
        .iter()
        .map(|terminal| {
            let id = terminal["id"].as_str().unwrap_or_else(|| panic!("no id: {terminal}"));
            (id.to_string(), terminal["cwd"].as_str().map(str::to_string))
        })
        .collect()
}

/// Waits until terminal `id` reports `folder`; returns what it reported last.
fn wait_for_cwd(server: &HeadlessServer, id: &str, folder: &str) -> Option<String> {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let cwd =
            terminals(server).into_iter().find(|(each, _)| each == id).and_then(|(_, cwd)| cwd);
        if cwd.as_deref() == Some(folder) || Instant::now() > deadline {
            return cwd;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn new_terminals_start_in_the_folder_the_focused_terminal_moved_to() {
    let launch = unique_temp_dir("inherit-cwd-launch");
    let target = unique_temp_dir("inherit-cwd-target");
    fs::create_dir_all(&launch).unwrap();
    fs::create_dir_all(&target).unwrap();
    // The daemon reports physical paths (macOS /tmp is /private/tmp).
    let launch = launch.canonicalize().unwrap();
    let target = target.canonicalize().unwrap();
    let target = target.to_str().unwrap();
    let server = HeadlessServer::start_in("inherit-cwd", &launch);

    assert_success(&json_cli(&server, &["tab", "create", "terminal"]));
    let first = terminals(&server);
    assert_eq!(first.len(), 1, "one terminal: {first:?}");
    let first = first[0].0.clone();
    let tree = raw_json(&server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    let workspace = &tree["workspaces"][0];
    let screen = &workspace["screens"][0];
    let pane = screen["active_pane"].as_u64().unwrap_or_else(|| panic!("no pane: {tree}"));
    let surface = screen["panes"][0]["tabs"][0]["surface"]
        .as_u64()
        .unwrap_or_else(|| panic!("no surface: {tree}"));

    // The person moves the terminal: `cd`, and the shell reports the folder (OSC 7).
    let text = format!("cd '{target}' && printf '\\033]7;file://localhost%s\\007' \"$PWD\"\n");
    raw_json(
        &server,
        serde_json::json!({"id": "cd", "cmd": "send", "surface": surface, "text": text}),
    );
    assert_eq!(
        wait_for_cwd(&server, &first, target).as_deref(),
        Some(target),
        "the first terminal moved"
    );

    let creations = [
        ("new tab", serde_json::json!({"cmd": "new-tab", "pane": pane, "cols": 80, "rows": 24})),
        (
            "split",
            serde_json::json!({"cmd": "split", "pane": pane, "dir": "right", "cols": 80, "rows": 24}),
        ),
        ("new pane", serde_json::json!({"cmd": "new-pane", "pane": pane, "cols": 80, "rows": 24})),
        (
            "new screen",
            serde_json::json!({"cmd": "new-screen", "workspace": workspace["id"], "cols": 80, "rows": 24}),
        ),
    ];
    let mut failures = Vec::new();
    for (index, (what, mut request)) in creations.into_iter().enumerate() {
        // Every creation targets the moved terminal's pane or its workspace.
        let before = terminals(&server).into_iter().map(|(id, _)| id).collect::<Vec<_>>();
        request["id"] = serde_json::json!(format!("create-{index}"));
        raw_json(&server, request);
        let created = terminals(&server)
            .into_iter()
            .filter(|(id, _)| !before.contains(id))
            .map(|(id, _)| id)
            .collect::<Vec<_>>();
        assert_eq!(created.len(), 1, "{what}: one new terminal, got {created:?}");
        let cwd = wait_for_cwd(&server, &created[0], target);
        if cwd.as_deref() != Some(target) {
            failures.push(format!("{what} started in {cwd:?}"));
        }
    }
    assert!(failures.is_empty(), "new terminals must start in {target}: {failures:?}");
}
