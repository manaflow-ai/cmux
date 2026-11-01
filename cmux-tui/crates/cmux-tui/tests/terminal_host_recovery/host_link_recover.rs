//! Recover of a terminal whose host link failed (`terminal_state`
//! `failed`). On Oct 30 an ssh tab showed "cmux lost its link to the shell
//! · Close the tab to end it" while ssh still ran: its host had wedged, and
//! the only way out was closing the tab and losing the session. Recover
//! (`restart-tab` on the failed tab, the app's button, the palette and
//! `cmux tab <id> restart`) ends the unreachable host, and the daemon
//! rehosts the same shell on its PTY custody copy: same shell process, same
//! terminal id and incarnation, input works again.

use cmux_tui_core::terminal_host_runtime::request_terminal_host_pty_custody;

use super::pty_custody::{process_running, run_in_new_workspace, send_line};
use super::*;

fn terminal_state(socket: &Path, surface: u64, request_id: u64) -> Option<serde_json::Value> {
    let tree = request(socket, serde_json::json!({"id": request_id, "cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"].as_u64() == Some(surface))
        .map(|tab| tab["terminal_state"].clone())
}

fn wait_for_state(socket: &Path, surface: u64, state: &str, within: Duration, first: u64) {
    let deadline = Instant::now() + test_timeout(within);
    let mut request_id = first;
    loop {
        request_id += 1;
        let now = terminal_state(socket, surface, request_id);
        if now.as_ref().is_some_and(|now| now == state) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the tab never became {state} within {within:?}: {now:?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn recover_rehosts_the_same_shell_behind_a_failed_host_link() {
    let _exclusive = exclusive_process_test();
    // The 17th reconnect completion is past the budget (16): the link fails
    // with the host still live. Five more failures keep the slow retry
    // (2 s, 4 s, 8 s, 16 s, 32 s) from bringing it back by itself for about
    // a minute, so only Recover can bring it back within the bound below.
    let harness =
        RecoveryHarness::start_with_reconnect_completion_failures("host-link-recover", 22);
    let surface = run_in_new_workspace(&harness.socket, &["/bin/sh"], "recover");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let shell = request_terminal_host_pty_custody(&record, &record_path).unwrap().child_pid;
    wait_for_state(&harness.socket, surface, "failed", Duration::from_secs(60), 100);

    let recovered = request_response(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "restart-tab", "surface": surface}),
    );
    assert_eq!(recovered["ok"], true, "Recover was refused: {recovered}");
    wait_for_state(&harness.socket, surface, "running", Duration::from_secs(20), 1_000);

    assert!(process_running(shell), "Recover ended the shell instead of rehosting it");
    let (_, rehosted) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert_ne!(rehosted.host_pid, record.host_pid, "the unreachable host still serves");
    assert_eq!(rehosted.terminal_id, record.terminal_id);
    assert_eq!(rehosted.incarnation, record.incarnation);

    let marker = format!("after-recover-{}", std::process::id());
    send_line(&harness.socket, surface, &format!("echo {marker}"));
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    close_terminal_surface(&harness.socket, surface, 3);
}
