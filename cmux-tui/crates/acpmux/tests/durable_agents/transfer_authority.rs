//! Durable transfer authority (`hub/transfer_authority.rs`) across a real daemon restart.

use super::*;

/// Both uncommitted and committed moves survive an actual daemon restart; the latter is
/// closed and therefore skipped by queue restoration.
#[tokio::test]
async fn transfer_authority_survives_restart_and_abort_restores_the_live_root() {
    let mut daemon = Daemon::new("transfer-auth", "approve-all");
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let fresh = rpc.call("_acpmux/info", json!({"sessionId": session})).await;
    assert_eq!(fresh["transferBlocked"], false, "{fresh}");
    let begin = rpc.call("_acpmux/transfer_begin", json!({"sessionId": session})).await;
    let transfer = begin["transferId"].as_str().expect("began transfer").to_owned();
    daemon.sigterm();
    drop(rpc);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let begun = rpc.call("_acpmux/info", json!({"sessionId": session})).await;
    assert_eq!(begun["transferBlocked"], true, "restart forgot pending move: {begun}");
    rpc.call("_acpmux/transfer_abort", json!({"sessionId": session, "transferId": transfer})).await;
    let aborted = rpc.call("_acpmux/info", json!({"sessionId": session})).await;
    assert_eq!(aborted["transferBlocked"], false, "abort did not restore authority: {aborted}");
    let begin = rpc.call("_acpmux/transfer_begin", json!({"sessionId": session})).await;
    let committed = rpc.call("_acpmux/transfer_commit",
        json!({"sessionId": session, "transferId": begin["transferId"], "to": {"sessionId": session}})).await;
    assert_eq!(committed["committed"], true, "{committed}");
    daemon.sigterm();
    drop(rpc);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let closed = rpc.call("_acpmux/info", json!({"sessionId": session})).await;
    assert_eq!(closed["status"], "closed", "{closed}");
    assert_eq!(closed["transferBlocked"], true, "restart forgot committed move: {closed}");
}
