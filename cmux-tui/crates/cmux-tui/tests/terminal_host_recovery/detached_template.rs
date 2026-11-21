//! A Cloud template terminal whose tab was closed keeps running detached, like
//! any other terminal after `tab.close`. A daemon restart must restore it
//! detached, not treat it as a first adoption: a fresh placement made from a
//! runtime that already has a public terminal id has no tab identity, every
//! later resource projection fails, and the session can no longer create a
//! terminal (`pane.run` and `tab.create_terminal` report indeterminate).
//! Port of main #33195.

use super::super::*;

#[test]
fn detached_template_terminal_survives_a_daemon_restart_without_wedging_mutations() {
    let mut harness = RecoveryHarness::start("template-detached");
    let parked = park_template_host(&mut harness);
    harness.adopt_template_terminal = true;
    harness.restart();
    assert_template_bound_and_listed(&harness, &parked);

    resource_request(
        &harness.socket,
        "template-detached-second-tab",
        "tab.create_terminal",
        serde_json::json!({"machine":"current","session":"current"}),
        Some("template-detached-second-tab"),
    );
    let listed = resource_request(
        &harness.socket,
        "template-detached-list",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let template_terminal = fs::read_to_string(harness.dir.join("bound"))
        .unwrap()
        .lines()
        .find_map(|line| line.strip_prefix("CMUX_TUI_TERMINAL_ID="))
        .unwrap()
        .to_string();
    let template_tab = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == template_terminal.as_str())
        .and_then(|terminal| terminal["tab_id"].as_str())
        .unwrap_or_else(|| panic!("template terminal has no tab: {listed}"))
        .to_string();
    resource_request(
        &harness.socket,
        "template-detached-close-tab",
        "tab.close",
        serde_json::json!({"machine":"current","session":"current","tab":template_tab}),
        Some("template-detached-close-tab"),
    );

    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    while daemon.try_wait().unwrap().is_none() {
        if Instant::now() >= deadline {
            let _ = daemon.kill();
            let _ = daemon.wait();
            panic!("daemon did not exit after SIGTERM");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);
    harness.restart();

    let created = resource_request(
        &harness.socket,
        "template-detached-create",
        "tab.create_terminal",
        serde_json::json!({"machine":"current","session":"current"}),
        Some("template-detached-create"),
    );
    assert!(created["value"]["terminal_id"].is_string(), "{created}");
    // Adoption completes asynchronously after the restart (the terminal reads
    // "adopting" until its host handshake lands), so wait for it, bounded.
    wait_for_terminal_lifecycle(&harness.socket, &parked.terminal_id, "running");
    let after = resource_request(
        &harness.socket,
        "template-detached-list-after",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let template = after
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == template_terminal.as_str())
        .unwrap_or_else(|| panic!("detached template terminal was lost: {after}"));
    assert!(
        template["tab_ids"].as_array().is_none_or(Vec::is_empty),
        "detached template terminal was placed again: {template}"
    );
    assert_eq!(template["running"], true, "{template}");
    // The session still creates terminals once the template is adopted.
    let again = resource_request(
        &harness.socket,
        "template-detached-create-after-adoption",
        "tab.create_terminal",
        serde_json::json!({"machine":"current","session":"current"}),
        Some("template-detached-create-after-adoption"),
    );
    assert!(again["value"]["terminal_id"].is_string(), "{again}");
}
