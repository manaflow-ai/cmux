//! A daemon restart prunes the records of hosts that died while no daemon
//! ran and keeps their tabs. These run with the L2 respawn off
//! (`RecoveryHarness::start_without_respawn`): they cover the ended state a
//! terminal keeps when no respawn happens (the crash-loop bound, a failed
//! respawn); `terminal_respawn.rs` covers the respawn itself.

use super::*;

#[test]
fn daemon_restart_safe_prunes_dead_host_and_keeps_its_tab_dead() {
    let mut harness = RecoveryHarness::start_without_respawn("dead-host-restart");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let workspace_id = created["workspace"].as_u64().unwrap();
    let tree = request(&harness.socket, serde_json::json!({"id":2,"cmd":"list-workspaces"}));
    let workspace_key = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["id"].as_u64() == Some(workspace_id))
        .unwrap()["key"]
        .as_str()
        .unwrap()
        .to_string();
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    // Stop the mux first so it cannot observe the host Exit and update the
    // registry. The restart must reconcile a dead proof against a still-
    // Running/Adopting row without spawning a replacement shell.
    harness.signal_daemon(libc::SIGSTOP);
    // SAFETY: the record PID is the harness-owned terminal host.
    assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    harness.sigkill();
    harness.restart();

    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":3,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "exited" {
            assert_eq!(resolved["terminal_incarnation"], incarnation);
            assert_eq!(resolved["surface"], serde_json::Value::Null);
            break;
        }
        assert!(Instant::now() < deadline, "dead startup host was not projected as Exited");
        std::thread::sleep(Duration::from_millis(25));
    }
    wait_for_no_host_records(&harness.host_root());
    let recovered = request(&harness.socket, serde_json::json!({"id":4,"cmd":"list-workspaces"}));
    let workspace = recovered["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["key"].as_str() == Some(&workspace_key))
        .expect("original workspace was not recovered");
    // Invariant 3: the host's death keeps its tab, dead, and nothing respawns
    // a shell into it.
    let tab = first_tab(workspace).expect("the tab of a dead host was removed after restart");
    assert_eq!(tab["dead"], true, "a dead host's terminal was respawned: {tab}");
    let dead_surface = tab["surface"].as_u64().unwrap();
    let write = request_response(
        &harness.socket,
        serde_json::json!({
            "id":5,"cmd":"send","surface":dead_surface,"text":"must-not-respawn\\n",
        }),
    );
    assert_eq!(write["ok"], false, "{write}");
    request(
        &harness.socket,
        serde_json::json!({
            "id":6,"cmd":"close-terminal","terminal_id":terminal_id,
            "terminal_incarnation":incarnation,
        }),
    );
}

#[test]
fn daemon_restart_prunes_every_dead_host_behind_one_pane_and_keeps_its_tabs() {
    let mut harness = RecoveryHarness::start_without_respawn("dead-hosts-restart");
    let first = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let pane = first["pane"].as_u64().unwrap();
    let workspace_id = first["workspace"].as_u64().unwrap();
    let first_terminal = first["terminal_id"].as_str().unwrap().to_string();
    let second = request(
        &harness.socket,
        serde_json::json!({
            "id":2,"cmd":"run","argv":["/bin/cat"],"pane":pane,
            "cols":80,"rows":24,
        }),
    );
    let second_terminal = second["terminal_id"].as_str().unwrap().to_string();
    assert_eq!(second["pane"].as_u64(), Some(pane), "second terminal left the first pane");
    let tree = request(&harness.socket, serde_json::json!({"id":3,"cmd":"list-workspaces"}));
    let workspace_key = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["id"].as_u64() == Some(workspace_id))
        .unwrap()["key"]
        .as_str()
        .unwrap()
        .to_string();
    let records = wait_for_host_records(&harness.host_root(), 2);

    // Stop the mux first so it observes neither Exit. Startup then has to
    // reconcile two dead hosts behind the same pane. Recovery of the first
    // one must not depend on the second one already having a live surface.
    harness.signal_daemon(libc::SIGSTOP);
    for (_, record) in &records {
        // SAFETY: the record PIDs are the harness-owned terminal hosts.
        assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    }
    harness.sigkill();
    harness.restart();

    for terminal_id in [&first_terminal, &second_terminal] {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let resolved = request(
                &harness.socket,
                serde_json::json!({"id":4,"cmd":"resolve-terminal","terminal_id":terminal_id}),
            );
            if resolved["lifecycle"] == "exited" {
                assert_eq!(resolved["surface"], serde_json::Value::Null);
                break;
            }
            assert!(
                Instant::now() < deadline,
                "dead startup host {terminal_id} was not projected as Exited"
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    wait_for_no_host_records(&harness.host_root());
    let recovered = request(&harness.socket, serde_json::json!({"id":5,"cmd":"list-workspaces"}));
    let workspace = recovered["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["key"].as_str() == Some(&workspace_key))
        .expect("original workspace was not recovered");
    // Invariant 3: both tabs stay in their pane, dead.
    let tabs = workspace["screens"][0]["panes"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|pane| pane["tabs"].as_array().unwrap().clone())
        .collect::<Vec<_>>();
    assert_eq!(tabs.len(), 2, "dead hosts lost their tabs: {workspace}");
    assert!(tabs.iter().all(|tab| tab["dead"] == true), "{workspace}");
}
