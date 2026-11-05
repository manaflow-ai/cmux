//! `agent.message.wait` (issue 36496): the claim a native terminal agent's
//! wake and prompt hooks share. Classic cmux's regressions (issue 32581:
//! stale waits, duplicate pollers, messages marked delivered before they were
//! shown) are the cases below.

use super::*;
use crate::mux::agent_message_wait::AgentMessageWait;
use serde_json::json;

fn terminal_of(mux: &Arc<Mux>) -> (SurfaceId, String) {
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = mux
        .surface(surface.id)
        .and_then(|surface| surface.terminal_public_id().cloned())
        .expect("a workspace's first tab is a terminal");
    (surface.id, terminal.as_str().to_owned())
}

fn send(mux: &Arc<Mux>, key: &str, recipient: &str, body: &str) -> String {
    let sent = public_request(
        mux,
        key,
        "agent.message.send",
        json!({"machine":"current","session":"current","recipients":[recipient],"body":body}),
        Some(key),
    );
    assert_eq!(sent["ok"], true, "{sent}");
    sent["result"]["value"]["id"].as_str().unwrap().to_owned()
}

fn mark_delivered(mux: &Arc<Mux>, key: &str, recipient: &str, ids: &[String]) {
    let marked = public_request(
        mux,
        key,
        "agent.message.mark",
        json!({
            "machine":"current","session":"current","ids":ids,"recipient":recipient,
            "state":"delivered","via":"claude.wake",
        }),
        Some(key),
    );
    assert_eq!(marked["ok"], true, "{marked}");
}

fn state_of(mux: &Arc<Mux>, recipient: &str, id: &str) -> String {
    let listed = public_request(
        mux,
        "list",
        "agent.message.list",
        json!({"machine":"current","session":"current","recipient":recipient,"limit":50}),
        None,
    );
    let message = listed["result"]
        .as_array()
        .unwrap()
        .iter()
        .find(|message| message["id"] == id)
        .cloned()
        .unwrap();
    message["deliveries"][0]["state"].as_str().unwrap().to_owned()
}

fn selectors() -> crate::ResourceSelectors {
    crate::ResourceSelectors {
        machine: Some("current".into()),
        session: Some("current".into()),
        ..Default::default()
    }
}

fn wait(mux: &Mux, request: &AgentMessageWait) -> Value {
    mux.agent_message_wait(&selectors(), request, &|| false, &|_: &Arc<ResourceWaitWake>| {})
        .unwrap()
        .unwrap()
}

fn once(recipient: &str) -> AgentMessageWait {
    AgentMessageWait { recipient: recipient.into(), respect_hold: true, ..Default::default() }
}

fn waiting(recipient: &str, poller: &str, register: bool, timeout_ms: u64) -> AgentMessageWait {
    AgentMessageWait {
        recipient: recipient.into(),
        poller: Some(poller.into()),
        register,
        respect_hold: true,
        timeout: Duration::from_millis(timeout_ms),
        ..Default::default()
    }
}

fn claimed_ids(answer: &Value) -> Vec<String> {
    assert_eq!(answer["status"], "claimed", "{answer}");
    answer["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|message| message["id"].as_str().unwrap().to_owned())
        .collect()
}

fn until(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "{what}");
        std::thread::yield_now();
    }
}

/// An idle agent's wake hook sleeps in the daemon and claims the message a
/// send queues, without a poll interval between them.
#[test]
fn an_idle_wake_wakes_on_the_send_and_claims_it() {
    let mux = test_mux();
    let (_, terminal) = terminal_of(&mux);
    let waiter = {
        let (mux, terminal) = (mux.clone(), terminal.clone());
        std::thread::spawn(move || wait(&mux, &waiting(&terminal, "p1", true, 60_000)))
    };
    until("the wait did not subscribe", || {
        mux.agent_message_waits().waiter_count_for_test(&terminal) == 1
    });
    let id = send(&mux, "send-1", &terminal, "rebase when free");
    let started = Instant::now();
    let answer = waiter.join().unwrap();
    assert!(started.elapsed() < Duration::from_secs(5), "the send did not wake the wait");
    assert_eq!(claimed_ids(&answer), [id.clone()]);
    // A claim is not a delivery: it stays queued until the hook marks it.
    assert_eq!(state_of(&mux, &terminal, &id), "queued");
}

/// The prompt hook (the person submitted first) and the wake hook never
/// hand over the same message while one claim is out.
#[test]
fn a_prompt_claim_and_a_wake_claim_never_take_the_same_message() {
    let mux = test_mux();
    let (_, terminal) = terminal_of(&mux);
    let first = send(&mux, "send-1", &terminal, "one");
    let prompt = wait(&mux, &once(&terminal));
    assert_eq!(claimed_ids(&prompt), [first.clone()]);
    // The wake hook finds nothing free while the prompt's claim is out.
    let wake = wait(&mux, &waiting(&terminal, "p1", true, 0));
    assert_eq!(wake["status"], "timeout", "{wake}");
    let second = send(&mux, "send-2", &terminal, "two");
    let wake = wait(&mux, &waiting(&terminal, "p1", false, 0));
    assert_eq!(claimed_ids(&wake), [second]);
    mark_delivered(&mux, "mark-1", &terminal, &[first.clone()]);
    assert_eq!(state_of(&mux, &terminal, &first), "delivered");
    // Marking ends the prompt's claim; the wake's is still out.
    assert_eq!(mux.agent_message_waits().lease_count_for_test(&terminal), 1);
}

/// A busy agent (working) still gets a wake: Claude Code shows the reminder
/// at its next step. One waiting on the person (blocked: a permission,
/// question or plan prompt) gets nothing until the person answers.
#[test]
fn a_wait_holds_while_the_agent_waits_on_the_person_and_resumes_after() {
    let mux = test_mux();
    let (surface, terminal) = terminal_of(&mux);
    mux.report_agent(surface, AgentState::Working, AgentSource::Hook, Some("hook-session".into()))
        .unwrap();
    let id = send(&mux, "send-1", &terminal, "busy is fine");
    assert_eq!(claimed_ids(&wait(&mux, &waiting(&terminal, "p1", true, 0))), [id.clone()]);
    mark_delivered(&mux, "mark-1", &terminal, &[id]);

    mux.report_agent(surface, AgentState::Blocked, AgentSource::Hook, Some("hook-session".into()))
        .unwrap();
    let held = send(&mux, "send-2", &terminal, "wait for the answer");
    let answer = wait(&mux, &waiting(&terminal, "p1", false, 0));
    assert_eq!(answer["status"], "timeout", "{answer}");
    assert_eq!(answer["held"], "waiting_on_person", "{answer}");
    // The person submitting a prompt is not the hold: their prompt carries it.
    let prompt = AgentMessageWait { respect_hold: false, ..once(&terminal) };
    assert_eq!(claimed_ids(&wait(&mux, &prompt)), [held.clone()]);
    mux.agent_message_waits().release(&terminal, &[held]);

    let waiter = {
        let (mux, terminal) = (mux.clone(), terminal.clone());
        std::thread::spawn(move || wait(&mux, &waiting(&terminal, "p1", false, 60_000)))
    };
    until("the held wait did not subscribe", || {
        mux.agent_message_waits().waiter_count_for_test(&terminal) == 1
    });
    // The answer ends the hold; its state change wakes the wait.
    mux.report_agent(surface, AgentState::Working, AgentSource::Hook, Some("hook-session".into()))
        .unwrap();
    assert_eq!(waiter.join().unwrap()["status"], "claimed");
}

/// Every Stop starts a wake hook: the newest supersedes the older, which
/// ends instead of claiming beside it, and never takes the place back.
#[test]
fn a_newer_poller_supersedes_the_older_and_the_older_cannot_return() {
    let mux = test_mux();
    let (_, terminal) = terminal_of(&mux);
    let older = {
        let (mux, terminal) = (mux.clone(), terminal.clone());
        std::thread::spawn(move || wait(&mux, &waiting(&terminal, "old", true, 60_000)))
    };
    until("the older wait did not subscribe", || {
        mux.agent_message_waits().waiter_count_for_test(&terminal) == 1
    });
    assert_eq!(wait(&mux, &waiting(&terminal, "new", true, 0))["status"], "timeout");
    assert_eq!(older.join().unwrap()["status"], "superseded");
    // The superseded hook's re-arm (no register) does not unseat the newer one.
    assert_eq!(wait(&mux, &waiting(&terminal, "old", false, 0))["status"], "superseded");
    let id = send(&mux, "send-1", &terminal, "only the newest claims");
    assert_eq!(claimed_ids(&wait(&mux, &waiting(&terminal, "new", false, 0))), [id]);
}

/// A daemon restart forgets pollers and claims (both are memory only): the
/// first hook that re-arms without registering takes the vacant place, and
/// the claim the old daemon handed out is offered again.
#[test]
fn a_re_arming_poller_takes_a_vacant_place_after_a_restart() {
    let mux = test_mux();
    let (_, terminal) = terminal_of(&mux);
    let id = send(&mux, "send-1", &terminal, "survives");
    // Before the restart: a claim is out to the poller.
    assert_eq!(claimed_ids(&wait(&mux, &waiting(&terminal, "p1", true, 0))), [id.clone()]);
    // The restart: the daemon's memory of pollers and leases is gone.
    mux.agent_message_waits().forget_recipient(&terminal);
    let answer = wait(&mux, &waiting(&terminal, "p1", false, 0));
    assert_eq!(claimed_ids(&answer), [id.clone()]);
    assert_eq!(state_of(&mux, &terminal, &id), "queued");
}

/// A claim whose hook died before it showed and marked the messages lapses,
/// and the messages are offered again: at least once, never lost.
#[test]
fn a_lapsed_claim_offers_its_messages_again() {
    let mux = test_mux();
    let (_, terminal) = terminal_of(&mux);
    let id = send(&mux, "send-1", &terminal, "not lost");
    assert_eq!(claimed_ids(&wait(&mux, &once(&terminal))), [id.clone()]);
    assert_eq!(wait(&mux, &once(&terminal))["status"], "timeout");
    mux.agent_message_waits().expire_for_test(&terminal);
    assert_eq!(claimed_ids(&wait(&mux, &once(&terminal))), [id.clone()]);
    assert_eq!(state_of(&mux, &terminal, &id), "queued");
}

/// A wait names the agent's session; once the hooks report it ended there,
/// it claims nothing (a replaced session's late hook takes nothing). A gone
/// agent process answers stale, a terminal not in the session gone.
#[test]
fn a_wait_for_an_ended_session_a_dead_agent_or_a_closed_terminal_claims_nothing() {
    let mux = test_mux();
    let (_, terminal) = terminal_of(&mux);
    let terminal_id = TerminalPublicId::parse(&terminal).unwrap();
    send(&mux, "send-1", &terminal, "for the live session");
    mux.agent_hook_fences.lock().unwrap().insert(
        terminal_id.clone(),
        crate::journal_reducers::HookFence {
            session_id: "old-session".into(),
            sequence: 7,
            ended: true,
            ended_at_ms: Some(1),
        },
    );
    let ended =
        AgentMessageWait { agent_session_id: Some("old-session".into()), ..once(&terminal) };
    let answer = wait(&mux, &ended);
    assert_eq!(
        (answer["status"].as_str(), answer["held"].as_str()),
        (Some("timeout"), Some("session_ended"))
    );
    // The session that replaced it claims.
    let live = AgentMessageWait { agent_session_id: Some("new-session".into()), ..once(&terminal) };
    assert_eq!(wait(&mux, &live)["status"], "claimed");

    // pid 0 is never a live agent.
    let dead = AgentMessageWait { agent_pid: Some(0), ..once(&terminal) };
    assert_eq!(wait(&mux, &dead)["status"], "stale");

    // A terminal not in the session (closed, or another session's).
    let missing = "term_0123456789abcdef0123456789abcdef";
    assert_eq!(wait(&mux, &once(missing))["status"], "gone");
}

/// A canceled request or a closed connection ends a wait with no answer,
/// and its registration goes with it.
#[test]
fn a_stopped_wait_answers_nothing_and_unregisters() {
    let mux = test_mux();
    let (_, terminal) = terminal_of(&mux);
    let stopped = Arc::new(AtomicBool::new(false));
    let waiter = {
        let (mux, terminal, stopped) = (mux.clone(), terminal.clone(), stopped.clone());
        std::thread::spawn(move || {
            let wakes = Mutex::new(Vec::new());
            mux.agent_message_wait(
                &selectors(),
                &waiting(&terminal, "p1", true, 60_000),
                &|| stopped.load(Ordering::SeqCst),
                &|wake: &Arc<ResourceWaitWake>| wakes.lock().unwrap().push(wake.clone()),
            )
        })
    };
    until("the wait did not subscribe", || {
        mux.agent_message_waits().waiter_count_for_test(&terminal) == 1
    });
    stopped.store(true, Ordering::SeqCst);
    mux.agent_message_waits().notify(&terminal);
    assert!(waiter.join().unwrap().unwrap().is_none());
    assert_eq!(mux.agent_message_waits().waiter_count_for_test(&terminal), 0);
}

/// acpmux sessions keep their own delivery (the daemon pump): a wait for one
/// is refused, and the pump's deliveries are never leased here.
#[test]
fn a_wait_refuses_an_acpmux_recipient_and_over_long_timeouts() {
    let mux = test_mux();
    let error = mux
        .agent_message_wait(&selectors(), &once("acp:session-1"), &|| false, &|_: &Arc<
            ResourceWaitWake,
        >| {})
        .unwrap_err();
    assert_eq!(error.code, "validation.invalid", "{error:?}");
    let (_, terminal) = terminal_of(&mux);
    let error = mux
        .agent_message_wait(
            &selectors(),
            &waiting(&terminal, "p1", true, 3_600_000),
            &|| false,
            &|_: &Arc<ResourceWaitWake>| {},
        )
        .unwrap_err();
    assert_eq!(error.code, "validation.invalid", "{error:?}");
}

/// Through the resource router, a one-shot claim answers; a blocking one
/// needs the socket connection that can cancel it.
#[test]
fn the_router_answers_a_one_shot_claim_and_refuses_a_blocking_one() {
    let mux = test_mux();
    let (_, terminal) = terminal_of(&mux);
    let id = send(&mux, "send-1", &terminal, "hi");
    let claimed = public_request(
        &mux,
        "claim",
        "agent.message.wait",
        json!({"machine":"current","session":"current","recipient":terminal}),
        None,
    );
    assert_eq!(claimed["ok"], true, "{claimed}");
    assert_eq!(claimed["result"]["messages"][0]["id"], id.as_str(), "{claimed}");
    let blocking = public_request(
        &mux,
        "block",
        "agent.message.wait",
        json!({"machine":"current","session":"current","recipient":terminal,"timeout_ms":"1000"}),
        None,
    );
    assert_eq!(blocking["ok"], false, "{blocking}");
}
