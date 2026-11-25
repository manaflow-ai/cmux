//! A store this daemon could not read in full never ends the agents it hides. An update restarts
//! acpmux; one chat folder under `sessions/` is group-writable (a copy under umask 002, a
//! restore), so the store's list fails and the daemon knows no chat; or one chat's
//! `session.json` does not parse (a value a newer build wrote, after a rollback). Adoption took
//! every host whose chat it did not know for a purged chat's and ended it: the update killed
//! each running agent mid-turn. A host is ended as a purged chat's only when the list read every
//! chat and named none of its; otherwise it keeps running, and the start after the store is
//! fixed adopts it with its turn.

use super::*;

/// The gated turn's harness lives on for `within` after the daemon started.
fn still_alive_after(harness: i64, within: Duration) -> bool {
    !gone_within(harness, within)
}

/// The gated turn ends once its host is adopted again, with its output exactly once.
async fn adopted_and_finished(daemon: &Daemon, session: &str, harness: i64) {
    daemon.wait_event(session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(alive(harness), "a second agent replaced the kept one");
    let gate = daemon.home.join(format!("gate-{session}"));
    std::fs::write(&gate, b"go").unwrap();
    let result = daemon.wait_event(session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(result["msg"]["status"], "completed", "{result}");
    let events = daemon.events(session);
    assert_eq!(events.iter().filter(|e| chunk(e, "after-gate")).count(), 1, "{events:#?}");
}

#[tokio::test]
async fn a_store_list_that_fails_at_start_ends_no_agent() {
    use std::os::unix::fs::PermissionsExt;
    let mut daemon = Daemon::new("unreadlist", "approve-all");
    let (session, host, client) = gated_turn(&daemon).await;
    let harness = host["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(client);
    // A folder under sessions/ that the store refuses (group-writable): its list fails.
    let stray = daemon.home.join("sessions").join("stray");
    std::fs::create_dir(&stray).unwrap();
    std::fs::set_permissions(&stray, std::fs::Permissions::from_mode(0o775)).unwrap();
    daemon.start();
    assert!(
        still_alive_after(harness, Duration::from_secs(10)),
        "a daemon whose store list failed ended the agent of a chat it could not read"
    );
    // The folder is fixed; the next start adopts the agent with its turn.
    std::fs::remove_dir(&stray).unwrap();
    daemon.sigterm();
    daemon.start();
    adopted_and_finished(&daemon, &session, harness).await;
}

#[tokio::test]
async fn a_chat_whose_metadata_does_not_read_keeps_its_agent() {
    let mut daemon = Daemon::new("unreadmeta", "approve-all");
    let (session, host, client) = gated_turn(&daemon).await;
    let harness = host["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(client);
    // A status this build does not know, as a newer build may write it before a rollback.
    let meta = daemon.saved_meta_path(&session);
    let saved = std::fs::read_to_string(&meta).unwrap();
    let mut edited: Value = serde_json::from_str(&saved).unwrap();
    edited["status"] = json!("a-status-from-a-newer-build");
    std::fs::write(&meta, edited.to_string()).unwrap();
    daemon.start();
    assert!(
        still_alive_after(harness, Duration::from_secs(10)),
        "a daemon ended the agent of a chat whose metadata it could not read"
    );
    // Back on a build that reads it: adopted with its turn.
    daemon.sigterm();
    std::fs::write(daemon.saved_meta_path(&session), saved).unwrap();
    daemon.start();
    adopted_and_finished(&daemon, &session, harness).await;
}
