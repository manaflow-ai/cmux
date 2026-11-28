use super::*;

/// "No such session" from the target's machine is final; a peer that is down is not.
#[test]
fn a_no_session_answer_is_final_and_an_unreachable_peer_is_not() {
    let e = RpcError::not_found("no session matches \"host/proc-title\"");
    assert_eq!(next(&e), Next::NoSession);
    let flagged =
        RpcError::invalid_params("no session: x").with_data(json!({"reason": "no_session"}));
    assert_eq!(next(&flagged), Next::NoSession);
    let down = RpcError::internal("down").with_data(json!({"reason": "peer_unreachable"}));
    assert_eq!(next(&down), Next::Unsent);
    assert_eq!(next(&RpcError::internal("connection reset")), Next::Retry);
}

/// A session whose folder is gone keeps the delivery: the folder may come back, so it is
/// tried again, and the refusal names the folder.
#[test]
fn a_missing_folder_is_tried_again_and_named() {
    use crate::hub::worktree_care::folder_missing;
    let gone = folder_missing("probe", std::path::Path::new("/tmp/probe-gone"), "is gone");
    assert_eq!(next(&gone), Next::Retry);
    assert!(gone.message.starts_with("session.folder_missing"), "{}", gone.message);
    assert!(gone.message.contains("/tmp/probe-gone"), "{}", gone.message);
}

/// How many attempts one message to a session whose folder stays gone makes in two hours on
/// the outbox's own schedule, with no peer's reconnect ending a wait (`deliver`'s
/// `wake_on_ready`): the schedule, then a doubling tail.
#[test]
fn a_missing_folder_is_tried_eleven_times_in_two_hours() {
    use crate::hub::worktree_care::folder_missing;
    let d = super::retry_delay_tests::delivery(0, false);
    let refusal = folder_missing("probe", std::path::Path::new("/tmp/x"), "is gone");
    let (mut delays, mut tail, mut now, mut attempts) = (RETRY_DELAYS_SECS.iter(), 0, 0, 0);
    let two_hours = 2 * 60 * 60 * 1000;
    while now <= two_hours && !expired(&d, now) {
        attempts += 1;
        assert_eq!(next(&refusal), Next::Retry);
        let Some(secs) = retry_delay(&mut delays, &mut tail, &d, now) else { break };
        now += retry_sleep(&d, secs, now).as_millis() as u64;
    }
    assert_eq!(attempts, 11);
}
