//! An ancestor's answer logged before a restart that never reached the agent (#23322): resent
//! as before, or asked again under MDM's off.

use super::*;

/// An agent asks; the daemon stops; an ancestor's answer to it is logged but never reached the
/// agent, naming its ancestor beside its outcome (`answeredBy`, as an ask logs it) or, `nested`,
/// inside it (`_acpmuxAnsweredBy`, as a re-asked prompt's answer was logged before review 84 of
/// #23322). `withdrawn`: the agent's withdrawal of it is logged after the answer, as one that came while
/// the answer was queued is. The stopped daemon, the session and the permission id.
async fn an_undelivered_ancestor_answer(
    tag: &str,
    nested: bool,
    withdrawn: bool,
) -> (Daemon, String, String) {
    let mut daemon = Daemon::new(tag, "ask");
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "ask: deploy"}]}),
        )
        .await;
    let asked =
        daemon.wait_event(&session, "permission_request", |e| e["kind"] == "permission_request");
    let permission_id = asked["msg"]["permissionId"].as_str().unwrap().to_owned();
    daemon.sigterm();
    drop(client);
    let by = json!({"session": "an-ancestor", "name": "parent"});
    let mut decision = json!({"permissionId": permission_id,
                              "outcome": {"outcome": "selected", "optionId": "yes"}});
    if nested {
        decision["outcome"]["_acpmuxAnsweredBy"] = by;
    } else {
        decision["answeredBy"] = by;
    }
    log_while_down(&daemon, &session, "permission_decision", decision);
    if withdrawn {
        let events = daemon.events(&session);
        let started = events.iter().rev().find(|e| e["kind"] == "host_started").unwrap();
        let withdrawal = json!({"agentRequestId": asked["msg"]["agentRequestId"],
                                "incarnation": started["msg"]["incarnation"]});
        log_while_down(&daemon, &session, "permission_withdrawn", withdrawal);
    }
    (daemon, session, permission_id)
}

/// `an_undelivered_ancestor_answer`; `managed_off`: MDM forces full access off; the next daemon
/// adopts the agent. Whether the logged answer reached the agent (`chose yes`), and whether the
/// prompt was asked again.
async fn an_undelivered_ancestor_answer_after_a_restart(
    managed_off: bool,
    nested: bool,
) -> (bool, bool) {
    let (resent, asked_again, _) =
        an_undelivered_ancestor_answer_after_a_restart_in(managed_off, nested, false).await;
    (resent, asked_again)
}

/// `an_undelivered_ancestor_answer_after_a_restart`, `withdrawn` as `an_undelivered_ancestor_answer`
/// takes it; also whether the agent was answered cancelled (`chose cancelled`).
async fn an_undelivered_ancestor_answer_after_a_restart_in(
    managed_off: bool,
    nested: bool,
    withdrawn: bool,
) -> (bool, bool, bool) {
    let tag = match (managed_off, nested, withdrawn) {
        (false, _, false) => "anc",
        (false, _, true) => "ancwd",
        (true, false, false) => "ancoff",
        (true, true, false) => "ancnest",
        (true, _, true) => "ancoffwd",
    };
    let (mut daemon, session, permission_id) =
        an_undelivered_ancestor_answer(tag, nested, withdrawn).await;
    if managed_off {
        std::fs::write(daemon.home.join("start-mode.json"), r#"{"fullAccessManaged":false}"#)
            .unwrap();
    }
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let events = daemon.events(&session);
        let resent = events.iter().any(|e| chunk(e, "chose yes"));
        let asked_again = events.iter().any(|e| {
            e["kind"] == "permission_reissued" && e["msg"]["permissionId"] == json!(permission_id)
        });
        let cancelled = events.iter().any(|e| chunk(e, "chose cancelled"));
        if resent || asked_again || cancelled || Instant::now() > deadline {
            return (resent, asked_again, cancelled);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Review 82 of #23322: under MDM's off, an ancestor's answer the agent never got before a
/// restart is not resent unchecked: the prompt is asked again, so it is decided under the
/// bound now.
#[tokio::test]
async fn under_an_mdm_off_an_undelivered_ancestor_answer_is_asked_again_after_a_restart() {
    let (resent, asked_again) = an_undelivered_ancestor_answer_after_a_restart(true, false).await;
    assert!(!resent, "an ancestor's answer decided before the off reached the agent after it");
    assert!(asked_again, "the prompt was not asked again");
}

/// Review 84 of #23322: an ancestor's answer logged with its ancestor inside its outcome (a
/// re-asked prompt's) is known as an ancestor's after the next restart too.
#[tokio::test]
async fn under_an_mdm_off_an_ancestor_answer_logged_inside_its_outcome_is_asked_again() {
    let (resent, asked_again) = an_undelivered_ancestor_answer_after_a_restart(true, true).await;
    assert!(!resent, "an ancestor's answer decided before the off reached the agent after it");
    assert!(asked_again, "the prompt was not asked again");
}

/// Review 84 of #23322: a restart's resend of an ancestor's answer is checked and written under
/// the family gate, so an MDM off push that lands between its check and its write waits until
/// it is written.
#[tokio::test]
async fn an_off_push_waits_for_an_ancestor_answer_resent_after_a_restart() {
    let (mut daemon, _, _) = an_undelivered_ancestor_answer("ancgate", false, false).await;
    let paused = daemon.home.join("replay-paused");
    let marker = paused.to_string_lossy().into_owned();
    daemon.env.push(("ACPMUX_TEST_PAUSE_REPLAYED_ANSWER".into(), marker));
    daemon.start();
    let deadline = Instant::now() + Duration::from_secs(20);
    while !paused.exists() {
        assert!(Instant::now() < deadline, "the resend never reached its check");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let off = json!({"enabled": true, "discovery": false, "roots": [], "managedRoots": [],
                     "allowFullAccess": false, "allowFullAccessManaged": true});
    let started = Instant::now();
    let pushed = daemon.rpc().await.call("_acpmux/chat_settings", off).await;
    assert_eq!(pushed["applied"], true, "{pushed}");
    let took = started.elapsed();
    assert!(
        took >= Duration::from_millis(1500),
        "an off push returned after {took:?}, while an answer checked under the old bound was unwritten"
    );
}

/// Review 88 of #23322: under MDM's off, a restart's undelivered ancestor answer whose prompt a
/// Stop cancelled while the restart waited for the family gate is not asked again.
#[tokio::test]
async fn under_an_mdm_off_a_stop_during_a_restart_cancels_an_undelivered_ancestor_answer() {
    let (mut daemon, session, permission_id) =
        an_undelivered_ancestor_answer("ancstop", false, false).await;
    std::fs::write(daemon.home.join("start-mode.json"), r#"{"fullAccessManaged":false}"#).unwrap();
    let paused = daemon.home.join("recovery-paused");
    let marker = paused.to_string_lossy().into_owned();
    daemon.env.push(("ACPMUX_TEST_PAUSE_RECOVERED_ANSWER".into(), marker));
    daemon.start();
    let deadline = Instant::now() + Duration::from_secs(20);
    while !paused.exists() {
        assert!(Instant::now() < deadline, "the restart never reached the answer");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let stopped = daemon.rpc().await.call("session/cancel", json!({"sessionId": session})).await;
    assert!(stopped.is_object(), "{stopped}");
    tokio::time::sleep(Duration::from_secs(5)).await;
    let asked_again = daemon.events(&session).iter().any(|e| {
        e["kind"] == "permission_reissued" && e["msg"]["permissionId"] == json!(permission_id)
    });
    assert!(!asked_again, "a prompt a Stop cancelled during the restart was asked again");
}

/// With MDM unset, nothing changes: the logged answer reaches the adopted agent.
#[tokio::test]
async fn with_mdm_unset_an_undelivered_ancestor_answer_is_sent_after_a_restart() {
    let (resent, _) = an_undelivered_ancestor_answer_after_a_restart(false, false).await;
    assert!(resent, "the logged answer did not reach the adopted agent");
}

/// Review 130 of #23322: under MDM's off, an ancestor's answer the agent withdrew its question
/// from while the answer was queued (the withdrawal logged after the decision) is neither resent
/// nor asked again after a restart: the agent is answered cancelled.
#[tokio::test]
async fn under_an_mdm_off_a_withdrawn_ancestor_answer_is_not_asked_again_after_a_restart() {
    let (resent, asked_again, cancelled) =
        an_undelivered_ancestor_answer_after_a_restart_in(true, false, true).await;
    assert!(!resent, "an ancestor's answer decided before the off reached the agent after it");
    assert!(!asked_again, "a question its agent withdrew was asked again after a restart");
    assert!(cancelled, "the agent was not answered");
}

/// With MDM unset, the same withdrawn ancestor answer is resent as before.
#[tokio::test]
async fn with_mdm_unset_a_withdrawn_ancestor_answer_is_resent_as_before() {
    let (resent, asked_again, _) =
        an_undelivered_ancestor_answer_after_a_restart_in(false, false, true).await;
    assert!(resent, "with MDM unset the logged answer was not resent");
    assert!(!asked_again);
}
