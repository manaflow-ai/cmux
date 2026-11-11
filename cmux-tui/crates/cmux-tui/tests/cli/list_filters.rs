//! `workspace list --name/--cwd`, `pane list --name/--cwd` and
//! `terminal list --cwd` through a real daemon: an agent finds a workspace
//! by name or folder without listing everything and filtering itself, and
//! two workspaces that share a name both come back.
#![cfg(unix)]

use super::*;

/// The `id`s of a JSON list, sorted.
fn ids(output: &Output) -> Vec<String> {
    assert_success(output);
    let listed = json_output(output);
    let mut ids = listed
        .as_array()
        .unwrap_or_else(|| panic!("a list is an array: {listed}"))
        .iter()
        .map(|row| row["id"].as_str().unwrap_or_else(|| panic!("no id: {row}")).to_owned())
        .collect::<Vec<_>>();
    ids.sort();
    ids
}

fn sorted(mut ids: Vec<String>) -> Vec<String> {
    ids.sort();
    ids
}

/// A workspace named `name` whose terminal runs in `folder`; its id.
fn workspace(server: &HeadlessServer, name: &str, folder: &str) -> String {
    let created = json_cli(
        server,
        &[
            "workspace",
            "create",
            "--name",
            name,
            "--cwd",
            folder,
            "--",
            "/bin/sh",
            "-c",
            "sleep 600",
        ],
    );
    assert_success(&created);
    json_output(&created)["value"]["workspace_id"]
        .as_str()
        .unwrap_or_else(|| panic!("no workspace id: {created:?}"))
        .to_owned()
}

#[test]
fn list_filters_find_workspaces_panes_and_terminals_by_name_and_folder() {
    let server = HeadlessServer::start("list-filters");
    // The daemon reports physical paths (macOS /tmp is /private/tmp).
    let root = unique_temp_dir("list-filters-root");
    fs::create_dir_all(root.join("app/src")).unwrap();
    fs::create_dir_all(root.join("app-old")).unwrap();
    let root = root.canonicalize().unwrap();
    let path = |rest: &str| root.join(rest).to_str().unwrap().to_owned();
    let (app, src, old) = (path("app"), path("app/src"), path("app-old"));

    let dup_app = workspace(&server, "dup", &app);
    let dup_old = workspace(&server, "dup", &old);
    let solo_src = workspace(&server, "solo", &src);

    // Before: a shared name is ambiguous as a selector.
    let ambiguous = json_cli(&server, &["workspace", "name:dup", "show"]);
    assert!(!ambiguous.status.success(), "name:dup resolved: {ambiguous:?}");
    assert_eq!(json_error(&ambiguous)["code"], "selector.ambiguous", "{ambiguous:?}");

    let list = |extra: &[&str]| {
        let mut args = vec!["workspace", "list"];
        args.extend_from_slice(extra);
        ids(&json_cli(&server, &args))
    };
    assert_eq!(list(&["--name", "dup"]), sorted(vec![dup_app.clone(), dup_old.clone()]));
    assert_eq!(list(&["--name", "solo"]), vec![solo_src.clone()]);
    // A folder matches itself and what is inside it, never a sibling that
    // shares its prefix (`app-old`).
    assert_eq!(list(&["--cwd", &app]), sorted(vec![dup_app.clone(), solo_src.clone()]));
    assert_eq!(
        list(&["--cwd", &format!("{app}/")]),
        sorted(vec![dup_app.clone(), solo_src.clone()])
    );
    assert_eq!(list(&["--cwd", &old]), vec![dup_old.clone()]);
    assert_eq!(
        list(&["--cwd", root.to_str().unwrap()]),
        sorted(vec![dup_app.clone(), dup_old.clone(), solo_src])
    );
    // AND.
    assert_eq!(list(&["--name", "dup", "--cwd", &app]), vec![dup_app]);
    // No match is an empty list and exit 0.
    assert_eq!(list(&["--name", "nope"]), Vec::<String>::new());
    assert_eq!(list(&["--name", "solo", "--cwd", &old]), Vec::<String>::new());

    // A relative --cwd is read against the caller's folder.
    let relative = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["workspace", "list", "--cwd", "./app/../app-old"])
        .current_dir(&root)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_eq!(ids(&relative), vec![dup_old]);

    // The same folder rule on panes and terminals.
    let panes = ids(&json_cli(&server, &["pane", "list", "--cwd", &src]));
    assert_eq!(panes.len(), 1, "one pane in {src}: {panes:?}");
    let terminals = json_output(&json_cli(&server, &["terminal", "list", "--cwd", &app]));
    let folders = terminals
        .as_array()
        .unwrap_or_else(|| panic!("terminal list is an array: {terminals}"))
        .iter()
        .map(|terminal| terminal["cwd"].as_str().unwrap_or_default().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(sorted(folders), sorted(vec![app, src]));

    // A filter flag without a value is a usage error, not "no filter".
    let bare = json_cli(&server, &["workspace", "list", "--cwd"]);
    assert!(!bare.status.success(), "a bare --cwd listed: {bare:?}");
}
