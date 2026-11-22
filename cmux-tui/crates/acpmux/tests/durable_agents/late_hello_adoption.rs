//! A host whose hello misses the daemon start's adoption pass, as a live host on a loaded Mac
//! did (cmuxterm-hq#5545: load 118, 9 of 85 hosts past the 5 s hello), is still adopted, with
//! no prompt to its chat: before, it ran on with its agent and MCP servers and no daemon.

use super::*;

#[tokio::test]
async fn a_host_whose_hello_misses_the_start_pass_is_adopted_without_a_prompt() {
    let mut daemon = Daemon::new("latehello", "approve-all");
    let session = new_session(&daemon).await;
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    assert!(alive(harness), "a restart stop ended the agent");
    // Every hello of the next start's adoption pass misses its budget (debug builds' seam).
    daemon.env.push(("ACPMUX_TEST_ADOPT_HELLO_BUDGET_MS".into(), "0".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(alive(harness), "the agent did not survive its late adoption");
    assert_eq!(
        daemon.host_record(&session)["harness_pid"].as_i64(),
        Some(harness),
        "the same host was adopted, not a fresh one started"
    );
}
