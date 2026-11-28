//! A terminal whose daemon lost its host link and gave up reconnecting
//! (`terminal_state` `failed`) shows its last screen and drops every key.
//! Clients learn tab state only from tree pushes, so the daemon must push the
//! tab when the link state changes; otherwise the app keeps a "running"
//! terminal that never answers: a block cursor and no prompt.

use super::*;

fn tab_with_surface(socket: &Path, surface: u64, request_id: u64) -> Option<serde_json::Value> {
    let tree = request(socket, serde_json::json!({"id": request_id, "cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"].as_u64() == Some(surface))
        .cloned()
}

/// Forwards every `tree-changed` push of a plain subscription.
fn tree_pushes(socket: &Path) -> mpsc::Receiver<()> {
    let stream = transport::connect(socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{}", serde_json::json!({"id": 1, "cmd": "subscribe"})).unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "subscribe failed: {response}");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let _writer = writer;
        let mut line = String::new();
        while reader.read_line(&mut line).is_ok_and(|read| read > 0) {
            if line.contains("\"event\":\"tree-changed\"") && sender.send(()).is_err() {
                return;
            }
            line.clear();
        }
    });
    receiver
}

#[test]
fn a_host_link_the_daemon_gave_up_on_is_pushed_as_failed() {
    // Every reconnect completion fails, so after its retry budget the
    // hosted reader gives up on the (still running) host.
    let harness =
        RecoveryHarness::start_with_reconnect_completion_failures("host-link-failed", 1_000);
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let pushes = tree_pushes(&harness.socket);

    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    let mut request_id = 10;
    let failed = loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if pushes.recv_timeout(remaining).is_err() {
            let tab = tab_with_surface(&harness.socket, surface, request_id);
            panic!(
                "the daemon pushed no tree change showing the failed host link; tab now: {tab:?}"
            );
        }
        request_id += 1;
        let Some(tab) = tab_with_surface(&harness.socket, surface, request_id) else { continue };
        if tab["terminal_state"] == "failed" {
            break tab;
        }
    };
    // The shell may still run in its host: not an exit.
    assert_eq!(failed["dead"], false, "{failed}");

    close_terminal_surface(&harness.socket, surface, request_id + 1);
}

/// A `failed` host link is not the end: the daemon keeps retrying the live
/// host on a slow backoff and the tab is `running` again, input included,
/// without a restart (cx-6so.19).
#[test]
fn r41_a_failed_host_link_is_retried_until_the_host_answers() {
    // The 17th failure is past the reconnect budget (16): the link fails.
    // The 18th completion succeeds, so only a later retry can bring it back.
    let harness = RecoveryHarness::start_with_reconnect_completion_failures("host-link-retry", 17);
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let wait_for_state = |state: &str, first_request: u64| {
        let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
        let mut request_id = first_request;
        loop {
            request_id += 1;
            let tab = tab_with_surface(&harness.socket, surface, request_id);
            if tab.as_ref().is_some_and(|tab| tab["terminal_state"] == state) {
                return;
            }
            assert!(Instant::now() < deadline, "the tab never became {state}: {tab:?}");
            std::thread::sleep(Duration::from_millis(50));
        }
    };
    wait_for_state("failed", 100);
    wait_for_state("running", 1_000);

    let marker = format!("host-link-retry-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));

    close_terminal_surface(&harness.socket, surface, 3);
}
