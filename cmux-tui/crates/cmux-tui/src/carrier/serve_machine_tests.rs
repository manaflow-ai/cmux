//! The carrier serve lifecycle as a reducer: each test drives events and
//! checks the state and the exact effects. No process runs; the executor's
//! tests are `supervise_tests.rs`. These are the app's Swift
//! `CloudCarrierServeMachineTests` (cmux#38309), one for one, in snake case.

use super::*;

type M = ServeMachine;
const PATH: &str = "/tmp/x/cmux-link-0123456789ab.sock";

fn closed_err() -> Result<String, LinkError> {
    Err(closed())
}

fn ok_path() -> Result<String, LinkError> {
    Ok(PATH.to_owned())
}

fn env(token: &str) -> Env {
    Env::from([(TOKEN_KEY.to_owned(), token.to_owned())])
}

fn connect(waiter: WaiterId, keep_refusal: bool) -> Event {
    Event::Connect { waiter, keep_refusal }
}

fn token_ok(epoch: Epoch, read: ReadId, token: &str) -> Event {
    Event::TokenRead { epoch, read, result: TokenRead::Ok(env(token)) }
}

fn spawned_ok(child: ChildId) -> Event {
    Event::Spawned { child, failure: None }
}

fn ready_line(child: ChildId, socket: &str) -> Event {
    Event::ReadyLine { child, socket: socket.to_owned(), policy: None }
}

fn exit(child: ChildId, code: i32) -> Event {
    Event::ChildExit { child, code }
}

fn written(child: ChildId, token: &str, ok: bool) -> Event {
    Event::TokenWritten { child, token: token.to_owned(), ok }
}

fn refusal_line(child: ChildId, code: &str, detail: Option<&str>) -> Event {
    Event::RefusalLine { child, code: code.to_owned(), detail: detail.map(str::to_owned) }
}

fn ok_line(child: ChildId, vmk: Option<&str>) -> Event {
    Event::OkLine { child, vmk: vmk.map(str::to_owned) }
}

fn ready_state(token: &str) -> State {
    State::Ready(1, 1, Ready::sent(Some(token)))
}

// Machines in each state (child 1 is the first launch's).

fn idle() -> M {
    M::new(PATH)
}

fn claiming() -> M {
    let mut machine = idle();
    machine.reduce(connect(1, false));
    machine
}

fn awaiting_token() -> M {
    let mut machine = claiming();
    machine.reduce(Event::SocketClaimed(1));
    machine
}

fn spawning() -> M {
    let mut machine = awaiting_token();
    machine.reduce(token_ok(1, 1, "t-1"));
    machine.reduce(spawned_ok(1));
    machine
}

fn ready() -> M {
    let mut machine = spawning();
    machine.reduce(ready_line(1, PATH));
    machine
}

/// A ready child that stopped taking stdin while connect 2 waited: draining
/// child 1 at epoch 3.
fn draining() -> M {
    let mut machine = ready();
    machine.reduce(connect(2, false));
    machine.reduce(token_ok(1, 2, "t-2"));
    machine.reduce(written(1, "t-2", false));
    machine
}

/// A launch that failed on a bad ready line: its child 1 is still exiting.
fn idle_with_alive_child() -> M {
    let mut machine = spawning();
    machine.reduce(ready_line(1, "/tmp/elsewhere.sock"));
    machine
}

fn every_state() -> Vec<(&'static str, M)> {
    vec![
        ("idle", idle()),
        ("claiming", claiming()),
        ("awaitingToken", awaiting_token()),
        ("spawning", spawning()),
        ("ready", ready()),
        ("draining", draining()),
        ("idle with an exiting child", idle_with_alive_child()),
    ]
}

fn is_spawn(effect: &Effect) -> bool {
    matches!(effect, Effect::Spawn { .. })
}

// Table rows.

#[test]
fn idle_connect_claims_then_reads_token() {
    let mut machine = idle();
    assert_eq!(machine.reduce(connect(1, false)), vec![Effect::ClaimSocket(1)]);
    assert_eq!(machine.state(), &State::Claiming(1));
    assert_eq!(machine.reduce(Event::SocketClaimed(1)), vec![Effect::ReadToken(1, 1)]);
    assert_eq!(machine.state(), &State::AwaitingToken(1, 1));
    assert_eq!(
        machine.reduce(token_ok(1, 1, "t-1")),
        vec![Effect::Spawn { child: 1, env: env("t-1") }]
    );
    assert_eq!(
        machine.state(),
        &State::Spawning { epoch: 1, child: 1, sent_token: Some("t-1".to_owned()) }
    );
    assert_eq!(machine.reduce(spawned_ok(1)), vec![Effect::Hold(1), Effect::ArmReadyDeadline(1)]);
}

#[test]
fn connects_while_launching_join_one_launch() {
    let mut machine = idle();
    let mut effects = machine.reduce(connect(1, false));
    effects.extend(machine.reduce(connect(2, false)));
    effects.extend(machine.reduce(Event::SocketClaimed(1)));
    effects.extend(machine.reduce(connect(3, true)));
    effects.extend(machine.reduce(token_ok(1, 1, "t-1")));
    effects.extend(machine.reduce(connect(4, false)));
    effects.extend(machine.reduce(spawned_ok(1)));
    effects.extend(machine.reduce(ready_line(1, PATH)));
    assert_eq!(effects.iter().filter(|effect| is_spawn(effect)).count(), 1);
    assert_eq!(effects.last(), Some(&Effect::Resume(vec![1, 2, 3, 4], ok_path())));
}

#[test]
fn ready_line_resumes_waiters_and_arms_refresh() {
    let mut machine = spawning();
    assert_eq!(
        machine.reduce(ready_line(1, PATH)),
        vec![
            Effect::CancelReadyDeadline,
            Effect::ArmRefresh(1, Some("t-1".to_owned())),
            Effect::Resume(vec![1], ok_path()),
        ]
    );
    assert_eq!(machine.state(), &ready_state("t-1"));
    assert_eq!(machine.refusal(), None);
    assert_eq!(machine.answer(), None, "a new child has answered nothing");
}

#[test]
fn ready_line_for_another_socket_fails_and_drains() {
    let mut machine = spawning();
    let error = LinkError::InvalidAnswer("served another socket".to_owned());
    assert_eq!(
        machine.reduce(ready_line(1, "/tmp/elsewhere.sock")),
        vec![
            Effect::CancelReadyDeadline,
            Effect::CloseStdin(1),
            Effect::Release(1),
            Effect::ArmStopDeadline(1),
            Effect::Resume(vec![1], Err(error.clone())),
        ]
    );
    assert_eq!(machine.state(), &State::Idle { last_end: Some(error), alive: Some(1) });
    // The next connect waits for that child's exit before it claims the socket.
    assert_eq!(machine.reduce(connect(2, false)), vec![]);
    assert_eq!(machine.state(), &State::Draining(3, 1));
    assert_eq!(machine.reduce(exit(1, 0)), vec![Effect::ClaimSocket(3)]);
    // A failed socket check is the same path with the check's refusal.
    let mut checked = spawning();
    let unsafe_socket = LinkError::UnsafeSocket("group-writable".to_owned());
    let effects = checked.reduce(Event::ReadyLine {
        child: 1,
        socket: PATH.to_owned(),
        policy: Some(unsafe_socket.clone()),
    });
    assert_eq!(effects.last(), Some(&Effect::Resume(vec![1], Err(unsafe_socket))));
}

#[test]
fn ok_line_before_ready_is_invalid_answer() {
    let mut machine = spawning();
    assert_eq!(
        machine.reduce(ok_line(1, Some("owner"))).last(),
        Some(&Effect::Resume(vec![1], Err(LinkError::InvalidAnswer("no ready line".to_owned()))))
    );
}

#[test]
fn refusal_before_ready_maps_start_errors() {
    let taken = format!("Unix socket path {PATH} is already leased");
    let cases = [
        ("bad_request", Some(taken.as_str()), socket_taken()),
        (
            "ticket",
            Some("no credential"),
            LinkError::Failed {
                code: "ticket".to_owned(),
                message: "ticket: no credential".to_owned(),
            },
        ),
        (
            "handshake",
            None,
            LinkError::HelperRefused { code: "handshake".to_owned(), message: String::new() },
        ),
    ];
    for (code, detail, error) in cases {
        let mut machine = spawning();
        assert_eq!(
            machine.reduce(refusal_line(1, code, detail)).last(),
            Some(&Effect::Resume(vec![1], Err(error.clone()))),
            "{code}"
        );
        assert_eq!(machine.refusal(), Some(error));
    }
}

#[test]
fn stderr_end_before_any_line_is_helper_not_running() {
    let mut machine = spawning();
    let error = LinkError::helper_not_running("dyld: missing symbol");
    let effects =
        machine.reduce(Event::StderrEnded { child: 1, stderr: "dyld: missing symbol".to_owned() });
    assert_eq!(effects.last(), Some(&Effect::Resume(vec![1], Err(error.clone()))));
    assert_eq!(machine.reduce(exit(1, 134)), vec![]);
    assert_eq!(machine.state(), &State::Idle { last_end: Some(error), alive: None });
}

#[test]
fn ready_deadline_closes_the_child() {
    let mut machine = spawning();
    assert_eq!(
        machine.reduce(Event::ReadyDeadline(1)),
        vec![
            Effect::CancelReadyDeadline,
            Effect::CloseStdin(1),
            Effect::Release(1),
            Effect::ArmStopDeadline(1),
            Effect::Resume(vec![1], Err(no_ready_line())),
        ]
    );
}

#[test]
fn spawn_failure_leaves_no_child() {
    let mut machine = awaiting_token();
    machine.reduce(token_ok(1, 1, "t-1"));
    let error = LinkError::disconnected("cmux carrier serve did not start: no file");
    assert_eq!(
        machine.reduce(Event::Spawned { child: 1, failure: Some(error.clone()) }),
        vec![Effect::Resume(vec![1], Err(error.clone()))]
    );
    assert_eq!(machine.state(), &State::Idle { last_end: Some(error), alive: None });
    assert_eq!(
        machine.reduce(connect(2, false)),
        vec![Effect::ClaimSocket(2)],
        "the next launch waits on no child"
    );
}

#[test]
fn connect_while_ready_writes_a_fresh_token_then_answers() {
    let mut machine = ready();
    assert_eq!(machine.reduce(connect(2, false)), vec![Effect::ReadToken(1, 2)]);
    assert_eq!(
        machine.reduce(token_ok(1, 2, "t-2")),
        vec![Effect::WriteToken { child: 1, token: "t-2".to_owned() }]
    );
    assert_eq!(
        machine.reduce(written(1, "t-2", true)),
        vec![Effect::Resume(vec![2], ok_path()), Effect::ArmRefresh(1, Some("t-2".to_owned()))]
    );
    assert_eq!(machine.state(), &ready_state("t-2"));
}

#[test]
fn connect_while_ready_same_token_writes_nothing() {
    let mut machine = ready();
    machine.reduce(connect(2, false));
    assert_eq!(
        machine.reduce(token_ok(1, 2, "t-1")),
        vec![Effect::Resume(vec![2], ok_path()), Effect::ArmRefresh(1, Some("t-1".to_owned()))]
    );
}

#[test]
fn two_connects_while_ready_share_one_token_read() {
    let mut machine = ready();
    assert_eq!(machine.reduce(connect(2, false)), vec![Effect::ReadToken(1, 2)]);
    assert_eq!(machine.reduce(connect(3, true)), vec![]);
    machine.reduce(token_ok(1, 2, "t-2"));
    assert_eq!(
        machine.reduce(written(1, "t-2", true)).first(),
        Some(&Effect::Resume(vec![2, 3], ok_path()))
    );
}

#[test]
fn refresh_due_reads_and_writes_only_while_ready() {
    let mut machine = ready();
    assert_eq!(machine.reduce(Event::RefreshDue(1)), vec![Effect::ReadToken(1, 2)]);
    assert_eq!(machine.reduce(Event::RefreshDue(1)), vec![], "one read at a time");
    assert_eq!(
        machine.reduce(token_ok(1, 2, "t-2")),
        vec![Effect::WriteToken { child: 1, token: "t-2".to_owned() }]
    );
    assert_eq!(
        machine.reduce(written(1, "t-2", true)),
        vec![Effect::ArmRefresh(1, Some("t-2".to_owned()))]
    );
    for (name, state) in every_state() {
        if state.is_ready() {
            continue;
        }
        let mut other = state;
        let epoch = other.epoch();
        assert_eq!(other.reduce(Event::RefreshDue(epoch)), vec![], "{name}");
    }
}

#[test]
fn ok_line_sets_answer_and_publishes() {
    let mut machine = ready();
    assert_eq!(machine.reduce(ok_line(1, Some("owner"))), vec![Effect::Publish(Caller::Owner)]);
    assert_eq!(machine.answer(), Some(Caller::Owner));
    assert_eq!(machine.reduce(ok_line(1, Some("team"))), vec![Effect::Publish(Caller::Team)]);
    assert_eq!(machine.answer(), Some(Caller::Team));
}

#[test]
fn ok_line_without_vmk_is_unknown() {
    let mut machine = ready();
    machine.reduce(ok_line(1, Some("owner")));
    assert_eq!(
        machine.reduce(ok_line(1, None)),
        vec![Effect::Publish(Caller::Unknown)],
        "a line without vmk is never owner"
    );
    assert_eq!(machine.answer(), Some(Caller::Unknown));
}

#[test]
fn refusal_while_ready_is_reported_until_next_connect() {
    let mut machine = ready();
    assert_eq!(machine.reduce(refusal_line(1, "parked_timeout", None)), vec![]);
    let parked = LinkError::NotUp { state: "parked_timeout".to_owned() };
    assert_eq!(machine.refusal(), Some(parked.clone()));
    assert_eq!(machine.reduce(refusal_line(1, "bad_request", Some("token line"))), vec![]);
    assert_eq!(machine.refusal(), Some(parked), "a refused stdin line is not a refused connection");
    machine.reduce(connect(2, false));
    assert_eq!(machine.refusal(), None);
}

#[test]
fn keeping_refusal_does_not_clear_it() {
    let mut machine = ready();
    machine.reduce(refusal_line(1, "relay", None));
    machine.reduce(connect(2, true));
    assert_eq!(machine.refusal(), Some(LinkError::disconnected("relay")));
}

#[test]
fn child_exit_while_ready_goes_idle_with_exited_refusal() {
    let mut machine = ready();
    assert_eq!(machine.reduce(exit(1, 0)), vec![Effect::CancelRefresh, Effect::Release(1)]);
    let status = LinkError::helper_not_running("cmux carrier serve exited with status 0");
    assert_eq!(machine.state(), &State::Idle { last_end: Some(status.clone()), alive: None });
    assert_eq!(machine.refusal(), Some(status), "the end names the exit status");
    // The listener failing for good names itself, not only the exit.
    let mut listener = ready();
    listener.reduce(refusal_line(1, "socket", Some("accept failed")));
    listener.reduce(exit(1, 6));
    assert_eq!(
        listener.refusal(),
        Some(LinkError::helper_not_running("cmux carrier serve stopped listening: accept failed"))
    );
}

/// cloud-chat-replies-staging 2026-11-15T02:32:30Z: the link ended for 3
/// minutes with only "cmux carrier serve exited". A ready child's exit
/// names its status and its last stderr line that was not an event, and a
/// signal's 128 + n, so the next such row says which exit it was.
#[test]
fn a_ready_childs_exit_names_its_status_and_last_stderr_line() {
    let mut machine = ready();
    let tail = "thread 'main' panicked at serve.rs:1\n  note: backtrace\n\n";
    assert_eq!(machine.reduce(Event::StderrEnded { child: 1, stderr: tail.to_owned() }), vec![]);
    assert!(machine.is_ready(), "in ready the exit follows the end of stderr");
    machine.reduce(exit(1, 101));
    assert_eq!(
        machine.refusal(),
        Some(LinkError::helper_not_running(
            "cmux carrier serve exited with status 101; its last stderr line: note: backtrace"
        ))
    );
    let mut killed = ready();
    killed.reduce(exit(1, 128 + 9));
    assert_eq!(
        killed.refusal(),
        Some(LinkError::helper_not_running("cmux carrier serve exited with status 137"))
    );
    let mut unknown = ready();
    unknown.reduce(exit(1, -1));
    assert_eq!(
        unknown.refusal(),
        Some(LinkError::helper_not_running("cmux carrier serve exited with an unknown status"))
    );
    // A long line is clipped.
    let mut long = ready();
    long.reduce(Event::StderrEnded { child: 1, stderr: "x".repeat(400) });
    long.reduce(exit(1, 0));
    let Some(LinkError::HelperNotRunning { reason }) = long.refusal() else {
        panic!("helper not running")
    };
    assert!(reason.ends_with(&format!("{}…", "x".repeat(300))), "{reason}");
}

#[test]
fn child_exit_with_pending_connects_relaunches() {
    let mut machine = ready();
    machine.reduce(connect(2, false));
    assert_eq!(
        machine.reduce(exit(1, 0)),
        vec![Effect::CancelRefresh, Effect::Release(1), Effect::ClaimSocket(3)]
    );
    assert_eq!(machine.state(), &State::Claiming(3));
    assert_eq!(machine.waiters(), &[2]);
    assert_eq!(machine.reduce(token_ok(1, 2, "t-2")), vec![], "the old child's read is dropped");
}

#[test]
fn write_failed_is_treated_as_exit() {
    let mut machine = ready();
    machine.reduce(connect(2, false));
    machine.reduce(token_ok(1, 2, "t-2"));
    assert_eq!(
        machine.reduce(written(1, "t-2", false)),
        vec![
            Effect::CancelRefresh,
            Effect::CloseStdin(1),
            Effect::ArmStopDeadline(1),
            Effect::Release(1)
        ]
    );
    assert_eq!(
        machine.state(),
        &State::Draining(3, 1),
        "the relaunch waits for the old child's exit"
    );
    assert_eq!(machine.reduce(exit(1, 0)), vec![Effect::ClaimSocket(3)]);
}

/// What a stop and a park both do from each state.
fn ending_effects(name: &str) -> Vec<Effect> {
    match name {
        "idle" => vec![],
        "claiming" | "awaitingToken" => vec![Effect::Resume(vec![1], closed_err())],
        "spawning" => vec![
            Effect::CancelReadyDeadline,
            Effect::CloseStdin(1),
            Effect::Release(1),
            Effect::Resume(vec![1], closed_err()),
            Effect::ArmStopDeadline(1),
        ],
        "ready" => vec![
            Effect::CancelRefresh,
            Effect::CloseStdin(1),
            Effect::Release(1),
            Effect::ArmStopDeadline(1),
        ],
        "draining" => vec![
            Effect::CloseStdin(1),
            Effect::Release(1),
            Effect::Resume(vec![2], closed_err()),
            Effect::ArmStopDeadline(1),
        ],
        _ => vec![Effect::CloseStdin(1), Effect::Release(1), Effect::ArmStopDeadline(1)],
    }
}

#[test]
fn stop_from_each_state_is_terminal() {
    for (name, state) in every_state() {
        let mut machine = state;
        let child = machine.child();
        assert_eq!(machine.reduce(Event::Stop), ending_effects(name), "{name}");
        let expected = match child {
            Some(child) => State::Stopping(child, StopReason::Closed),
            None => State::Stopped(StopReason::Closed),
        };
        assert_eq!(machine.state(), &expected, "{name}");
        assert!(machine.waiters().is_empty(), "{name}");
        assert_eq!(machine.refusal(), Some(closed()), "{name}");
        assert_eq!(machine.reduce(Event::Stop), vec![], "{name}: a second stop does nothing");
        assert_eq!(machine.reduce(Event::AccountEnded), vec![], "{name}");
    }
}

/// A pause parks the serve: the child and the parked connects end as a stop
/// ends them, but the next connect (the resume) drains the parked child and
/// launches a fresh one.
#[test]
fn park_from_each_state_ends_the_child_and_keeps_the_serve() {
    for (name, state) in every_state() {
        let mut machine = state;
        let child = machine.child();
        assert_eq!(machine.reduce(Event::Park), ending_effects(name), "{name}");
        assert_eq!(
            machine.state(),
            &State::Idle { last_end: Some(closed()), alive: child },
            "{name}"
        );
        assert!(!machine.is_terminal(), "{name}");
        assert!(machine.waiters().is_empty(), "{name}");
        assert_eq!(machine.refusal(), Some(closed()), "{name}");
        let epoch = machine.epoch();
        let next = epoch.wrapping_add(1);
        if let Some(child) = child {
            assert_eq!(
                machine.reduce(connect(9, false)),
                vec![],
                "{name}: the resume waits for the parked child"
            );
            assert_eq!(machine.state(), &State::Draining(next, child), "{name}");
            assert_eq!(
                machine.reduce(Event::StopDeadline(child)),
                vec![Effect::Terminate(child)],
                "{name}: SIGTERM bounds the wait"
            );
            assert_eq!(machine.reduce(exit(child, 15)), vec![Effect::ClaimSocket(next)], "{name}");
        } else {
            assert_eq!(
                machine.reduce(connect(9, false)),
                vec![Effect::ClaimSocket(next)],
                "{name}"
            );
        }
        assert_eq!(machine.waiters(), &[9], "{name}");
        // An account end after the park is still terminal.
        assert!(
            machine.reduce(Event::AccountEnded).contains(&Effect::Resume(vec![9], closed_err())),
            "{name}"
        );
        assert!(machine.is_terminal(), "{name}");
    }
}

/// A parked child that ignores its stdin closing gets SIGTERM at its
/// deadline even when no resume came yet; a deadline for a child that
/// already exited does nothing.
#[test]
fn parked_child_is_terminated_at_its_deadline() {
    let mut machine = ready();
    machine.reduce(Event::Park);
    assert_eq!(machine.reduce(Event::StopDeadline(1)), vec![Effect::Terminate(1)]);
    assert_eq!(machine.reduce(exit(1, 15)), vec![]);
    assert_eq!(machine.state(), &State::Idle { last_end: Some(closed()), alive: None });
    assert_eq!(machine.reduce(Event::StopDeadline(1)), vec![], "no SIGTERM after the exit");
}

#[test]
fn connect_after_stop_fails_without_effects() {
    for (name, state) in every_state() {
        let mut machine = state;
        machine.reduce(Event::Stop);
        let after = machine.state().clone();
        assert_eq!(
            machine.reduce(connect(9, false)),
            vec![Effect::Resume(vec![9], closed_err())],
            "{name}"
        );
        assert_eq!(
            machine.reduce(connect(10, true)),
            vec![Effect::Resume(vec![10], closed_err())],
            "{name}"
        );
        assert_eq!(machine.state(), &after, "{name}");
    }
}

#[test]
fn stopping_escalates_to_terminate_at_deadline() {
    let mut machine = ready();
    machine.reduce(Event::Stop);
    assert_eq!(machine.reduce(Event::StopDeadline(1)), vec![Effect::Terminate(1)]);
    assert_eq!(machine.reduce(exit(1, 15)), vec![]);
    assert_eq!(machine.state(), &State::Stopped(StopReason::Closed));
    assert_eq!(machine.reduce(Event::StopDeadline(1)), vec![], "no SIGTERM after the exit");
}

/// Every result event of an older epoch, or of a child that is not the
/// current one, changes nothing.
#[test]
fn every_result_event_of_an_old_epoch_is_dropped() {
    let mut stopped = ready();
    stopped.reduce(Event::Stop);
    let mut states = every_state();
    states.push(("stopping", stopped));
    for (name, state) in states {
        let old = state.epoch().wrapping_sub(1);
        let other = state.epoch().wrapping_add(50);
        let events = [
            Event::SocketClaimed(old),
            token_ok(old, 1, "x"),
            Event::TokenRead { epoch: old, read: 2, result: TokenRead::Fenced },
            Event::TokenRead {
                epoch: old,
                read: 1,
                result: TokenRead::Failed(LinkError::Unsupported),
            },
            Event::Spawned { child: other, failure: Some(LinkError::Unsupported) },
            Event::HeldResult { child: other, held: false },
            ready_line(other, PATH),
            ok_line(other, Some("owner")),
            refusal_line(other, "socket", None),
            Event::StderrEnded { child: other, stderr: String::new() },
            Event::ReadyDeadline(old),
            exit(other, 0),
            Event::RefreshDue(old),
            written(other, "x", false),
            Event::StopDeadline(other),
        ];
        for event in events {
            let mut machine = state.clone();
            let label = format!("{name}: {event:?}");
            assert_eq!(machine.reduce(event), vec![], "{label}");
            assert_eq!(machine.state(), state.state(), "{label}");
            assert_eq!(machine.epoch(), state.epoch(), "{label}");
            assert_eq!(machine.waiters(), state.waiters(), "{label}");
        }
        // A stale successful spawn is the one exception: its child is closed and reaped.
        let mut machine = state.clone();
        assert_eq!(
            machine.reduce(spawned_ok(other)),
            vec![Effect::CloseStdin(other), Effect::TerminateAfterGrace(other)],
            "{name}"
        );
        assert_eq!(machine.state(), state.state(), "{name}");
    }
}

#[test]
fn held_result_nil_in_spawning_stops() {
    let mut machine = spawning();
    assert_eq!(machine.reduce(Event::HeldResult { child: 1, held: true }), vec![]);
    assert_eq!(
        machine.reduce(Event::HeldResult { child: 1, held: false }),
        vec![
            Effect::CancelReadyDeadline,
            Effect::CloseStdin(1),
            Effect::Release(1),
            Effect::Resume(vec![1], closed_err()),
            Effect::ArmStopDeadline(1),
        ]
    );
    assert_eq!(machine.state(), &State::Stopping(1, StopReason::AccountEnded));
}

#[test]
fn token_read_fenced_from_any_phase_stops() {
    let mut launching = awaiting_token();
    assert_eq!(
        launching.reduce(Event::TokenRead { epoch: 1, read: 1, result: TokenRead::Fenced }),
        vec![Effect::Resume(vec![1], closed_err())]
    );
    assert_eq!(launching.state(), &State::Stopped(StopReason::AccountEnded));
    let mut ready = ready();
    ready.reduce(Event::RefreshDue(1));
    ready.reduce(Event::TokenRead { epoch: 1, read: 2, result: TokenRead::Fenced });
    assert_eq!(ready.state(), &State::Stopping(1, StopReason::AccountEnded));
}

// Regressions of #37210's review rounds, and the gaps the model found.

/// Ready child 1 exits with connect 2 parked; child 3 relaunches and gets ready.
fn relaunched_ready() -> M {
    let mut machine = ready();
    machine.reduce(connect(2, false));
    machine.reduce(exit(1, 0));
    machine.reduce(Event::SocketClaimed(3));
    machine.reduce(token_ok(3, 3, "t-2"));
    machine.reduce(spawned_ok(3));
    machine.reduce(ready_line(3, PATH));
    machine
}

#[test]
fn r4_ok_line_from_a_previous_child_is_ignored() {
    let mut machine = relaunched_ready();
    assert_eq!(machine.reduce(ok_line(1, Some("owner"))), vec![]);
    assert_eq!(machine.answer(), None);
}

#[test]
fn r4_failed_token_lookup_keeps_the_ready_child() {
    let mut machine = ready();
    machine.reduce(connect(2, false));
    assert_eq!(
        machine.reduce(Event::TokenRead {
            epoch: 1,
            read: 2,
            result: TokenRead::Failed(LinkError::Unsupported)
        }),
        vec![Effect::Resume(vec![2], ok_path()), Effect::ArmRefresh(1, Some("t-1".to_owned()))]
    );
    assert!(machine.is_ready());
}

#[test]
fn r5_stop_while_awaiting_token_spawns_nothing() {
    let mut machine = awaiting_token();
    machine.reduce(Event::Stop);
    assert_eq!(machine.reduce(token_ok(1, 1, "old-account")), vec![]);
    assert_eq!(machine.state(), &State::Stopped(StopReason::Closed));
}

#[test]
fn r5_stop_while_draining_spawns_nothing() {
    let mut machine = draining();
    machine.reduce(Event::Stop);
    assert_eq!(machine.reduce(exit(1, 0)), vec![]);
    assert_eq!(machine.reduce(Event::SocketClaimed(3)), vec![]);
    assert_eq!(machine.state(), &State::Stopped(StopReason::Closed));
}

#[test]
fn astra_f2_failed_run_does_not_block_next_launch() {
    let mut machine = awaiting_token();
    machine.reduce(token_ok(1, 1, "t-1"));
    machine.reduce(Event::Spawned {
        child: 1,
        failure: Some(LinkError::disconnected("cmux carrier serve did not start")),
    });
    assert_eq!(machine.reduce(connect(2, false)), vec![Effect::ClaimSocket(2)]);
    assert_eq!(machine.state(), &State::Claiming(2));
}

#[test]
fn r6_account_end_stops_serve_in_every_phase() {
    for (name, state) in every_state() {
        let epoch = state.epoch();
        let mut machine = state;
        machine.reduce(Event::AccountEnded);
        assert!(machine.is_terminal(), "{name}");
        for event in [token_ok(epoch, 1, "new-account"), token_ok(epoch, 2, "new-account")] {
            let effects = machine.reduce(event);
            assert!(
                !effects
                    .iter()
                    .any(|effect| is_spawn(effect) || matches!(effect, Effect::WriteToken { .. })),
                "{name}"
            );
        }
    }
}

#[test]
fn r6_policy_stop_is_terminal_against_relay_ask() {
    let mut machine = ready();
    machine.reduce(Event::Stop);
    assert_eq!(machine.reduce(connect(5, true)), vec![Effect::Resume(vec![5], closed_err())]);
}

#[test]
fn r7_refresh_after_account_end_writes_no_token() {
    let mut machine = ready();
    machine.reduce(Event::RefreshDue(1));
    machine.reduce(Event::AccountEnded);
    assert_eq!(machine.reduce(token_ok(1, 2, "new-account")), vec![]);
}

#[test]
fn own_fenced_failure_hands_out_no_socket() {
    let mut machine = ready();
    machine.reduce(connect(2, false));
    let effects = machine.reduce(Event::TokenRead { epoch: 1, read: 2, result: TokenRead::Fenced });
    assert!(effects.contains(&Effect::Resume(vec![2], closed_err())));
    assert!(!effects.iter().any(|effect| matches!(effect, Effect::Resume(_, Ok(_)))));
}

#[test]
fn own_launch_racing_account_end_is_closed() {
    let mut machine = spawning();
    assert!(
        machine
            .reduce(Event::HeldResult { child: 1, held: false })
            .contains(&Effect::Resume(vec![1], closed_err()))
    );
    assert_eq!(machine.reduce(ready_line(1, PATH)), vec![]);
    assert_eq!(machine.state(), &State::Stopping(1, StopReason::AccountEnded));
}

#[test]
fn f2_connect_awaiting_token_joins_in_flight_launch() {
    let mut machine = awaiting_token();
    assert_eq!(machine.reduce(connect(2, false)), vec![]);
    assert_eq!(
        machine.reduce(token_ok(1, 1, "t-1")),
        vec![Effect::Spawn { child: 1, env: env("t-1") }]
    );
    assert_eq!(machine.waiters(), &[1, 2]);
}

#[test]
fn p1_stop_then_connect_spawns_nothing() {
    let mut machine = idle();
    machine.reduce(Event::Stop);
    assert_eq!(machine.reduce(connect(1, false)), vec![Effect::Resume(vec![1], closed_err())]);
}

#[test]
fn p2_old_childs_refusal_does_not_end_new_link() {
    let mut machine = ready();
    machine.reduce(connect(2, false));
    machine.reduce(exit(1, 6));
    machine.reduce(Event::SocketClaimed(3));
    machine.reduce(token_ok(3, 3, "t-2"));
    machine.reduce(spawned_ok(3));
    machine.reduce(ready_line(3, PATH));
    assert_eq!(machine.reduce(refusal_line(1, "socket", Some("accept failed"))), vec![]);
    assert_eq!(machine.refusal(), None);
}
