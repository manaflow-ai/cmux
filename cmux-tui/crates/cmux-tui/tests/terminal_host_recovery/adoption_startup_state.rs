//! A replacement owner adopts its surviving hosts after its first answer
//! (answers_before_adoption.rs), so the start steps that ran on adopted
//! surfaces must hold for a terminal that adopts later: a renamed tab keeps
//! its name, and an incognito workspace's shell still ends with its workspace.

use super::*;

fn terminal_ids(socket: &Path) -> Vec<String> {
    request(socket, serde_json::json!({"cmd":"list-terminals"}))["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|terminal| terminal["terminal_id"].as_str().map(str::to_string))
        .collect()
}

fn listed_lifecycle(socket: &Path, terminal_id: &str) -> Option<String> {
    request(socket, serde_json::json!({"cmd":"list-terminals"}))["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|terminal| terminal["terminal_id"] == terminal_id)
        .map(|terminal| terminal["lifecycle"].as_str().unwrap_or_default().to_string())
}

#[test]
fn a_renamed_tab_keeps_its_name_when_its_host_adopts_after_a_restart() {
    let mut harness = RecoveryHarness::start("adopted-tab-name");
    let created = request(
        &harness.socket,
        serde_json::json!({"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":"named"}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let surface = created["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"cmd":"rename-surface","surface":surface,"name":"build"}),
    );
    wait_for_host_records(&harness.host_root(), 1);
    harness.sigkill();

    harness.restart();
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
    let tree = request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}));
    let names = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .map(|tab| tab["name"].clone())
        .collect::<Vec<_>>();
    assert!(names.contains(&serde_json::json!("build")), "the tab lost its name: {names:?}");
}

#[test]
fn an_incognito_shell_ends_with_its_workspace_when_its_host_adopts_after_a_restart() {
    let mut harness = RecoveryHarness::start("adopted-incognito");
    let before = terminal_ids(&harness.socket);
    resource_request(
        &harness.socket,
        "incognito-create",
        "workspace.create",
        serde_json::json!({"machine":"current","session":"current","name":"secret",
                           "initial_content":"terminal","ephemeral":true}),
        Some("incognito-create"),
    );
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let incognito = loop {
        if let Some(id) = terminal_ids(&harness.socket).into_iter().find(|id| !before.contains(id))
        {
            break id;
        }
        assert!(Instant::now() < deadline, "the incognito workspace started no terminal");
        std::thread::sleep(Duration::from_millis(25));
    };
    wait_for_terminal_lifecycle(&harness.socket, &incognito, "running");
    wait_for_host_records(&harness.host_root(), 1);
    harness.sigkill();

    harness.restart();
    // Give a host that adopts on its own thread the time to do so.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    let mut lifecycle = listed_lifecycle(&harness.socket, &incognito);
    while lifecycle.as_deref() == Some("adopting") && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
        lifecycle = listed_lifecycle(&harness.socket, &incognito);
    }
    std::thread::sleep(Duration::from_millis(500));
    lifecycle = listed_lifecycle(&harness.socket, &incognito);
    assert!(
        !matches!(lifecycle.as_deref(), Some("running" | "adopting")),
        "the incognito shell outlived its workspace: {lifecycle:?}"
    );
}

/// Whether the public session snapshot presents some terminal in `dir`.
fn snapshot_presents_cwd(socket: &Path, dir: &str) -> bool {
    let snapshot = resource_request(
        socket,
        "adopted-cwd-snapshot",
        "session.snapshot",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    snapshot["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|terminal| terminal["cwd"].as_str() == Some(dir))
}

/// A shell's directory report that the host replays when a replacement owner
/// adopts it is published at adoption (#12978): an idle shell makes no output
/// and nothing else may change the graph, so no later step would publish it.
/// The session snapshot used to publish pending directories itself; a read
/// writes nothing now, so the adoption must.
#[test]
fn an_idle_shell_presents_its_reported_directory_after_its_host_adopts() {
    let mut harness = RecoveryHarness::start("adopted-cwd");
    let dir = fs::canonicalize(std::env::temp_dir())
        .unwrap()
        .join(format!("cmux-adopted-cwd-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let dir_text = dir.to_string_lossy().into_owned();
    let script = format!("printf '\\033]7;file://localhost{dir_text}\\007'; exec cat");
    request(
        &harness.socket,
        serde_json::json!({"cmd":"run","argv":["/bin/sh","-c",script],"new_workspace":true,"name":"idle"}),
    );
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while !snapshot_presents_cwd(&harness.socket, &dir_text) {
        assert!(Instant::now() < deadline, "the shell's report never reached the snapshot");
        std::thread::sleep(Duration::from_millis(50));
    }
    let terminal_id = terminal_ids(&harness.socket).into_iter().next().unwrap();
    wait_for_host_records(&harness.host_root(), 1);
    harness.sigkill();

    harness.restart();
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while !snapshot_presents_cwd(&harness.socket, &dir_text) {
        assert!(
            Instant::now() < deadline,
            "the adopted shell presents its launch directory, not its reported {dir_text}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = fs::remove_dir_all(&dir);
}
