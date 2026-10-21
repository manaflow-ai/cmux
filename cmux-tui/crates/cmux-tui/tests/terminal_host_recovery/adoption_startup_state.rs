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
