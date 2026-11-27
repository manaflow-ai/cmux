//! recover.rs: the one recovery table. Every class is injected as the start's first failure, and the start path
//! either recovers on its own (the class has an action) or passes the error through unchanged (click-through).
//! Leo, goals/cloud-errors-self-recover: "Fix the cause".

use std::time::Duration;

use serde_json::{Value, json};

use super::super::fresh::STUCK_CODE;
use super::super::recover::{Action, Class, classify, recover, recovery};
use super::*;

/// The error a start answers for `class`, as the start path builds it. Exhaustive on purpose: a new class needs
/// its injected error here, or this does not compile.
fn injected(class: Class) -> Value {
    let error = |code: &str, details: Value| {
        json!({"code": code, "message": format!("{code} (injected)"), "details": details,
               "retryable": false})
    };
    match class {
        Class::MachineStuck => {
            error(STUCK_CODE, json!({"machine_name": "chat-fresh", "why": "bound"}))
        }
        Class::StartPending => error(
            "cloud.start_pending",
            json!({"again": "cmux cloud start-chat --target machine:vm-1 --json",
                   "machine_name": "chat-fresh", "machine_id": "vm-1", "stage": {}}),
        ),
        Class::ListUnread => {
            let mut unread = error("cloud.list_unread", json!({"last_error": null}));
            unread["retryable"] = json!(true);
            unread
        }
        Class::MachineCap => error(
            "cloud.machine_cap",
            json!({"make_room": {"machine_id": "vm-b", "name": "web", "how": "delete"}}),
        ),
        Class::SpendCap => error("cloud.spend_cap", json!({})),
        Class::SignedOut => error("cloud.signed_out", json!({"sign_in": "cmux login"})),
        Class::AccountChanged => error("cloud.account_changed", json!({})),
        Class::AppNotConnected => error("cloud.app_not_connected", json!({"app": "not_connected"})),
        Class::NoConnection => json!({"code": "unavailable",
            "message": "No Cloud connection serves claude yet. Add one in Settings > Cloud"}),
        Class::AgentSignIn => error("auth.token", json!({})),
        Class::AgentLimit => {
            error("agent.limit_reached", json!({"until_at": "2026-11-26T12:00:00Z"}))
        }
        Class::AgentRefused => error("agent_session.bad_request", json!({})),
        Class::StartFailed => error("cloud.start_failed", json!({"machine_id": "vm-1"})),
        Class::NameTaken => error("cloud.name_taken", json!({})),
        Class::MakeRoomFailed => error("cloud.make_room_failed", json!({})),
        Class::TurnFailed => error("chat.turn_failed", json!({"session_id": "sess-1"})),
        Class::TurnTimeout => error("chat.wait_timeout", json!({"session_id": "sess-1"})),
        Class::ChatUnreachable => error("chat.unreachable", json!({})),
        Class::SendFailed => error("chat.send_failed", json!({})),
        Class::PermissionWaiting => error("chat.permission_waiting", json!({})),
    }
}

/// `asked` with a deadline ten minutes after `fake`'s now, as `--wait` with a prompt has.
fn bounded(mut asked: Request, fake: &Fake) -> Request {
    asked.until = Some(fake.clock + Duration::from_secs(600));
    asked
}

/// The command a class with an action runs on, and the app's answers to its recovery and the start after it.
fn recovers(action: Action) -> (Request, Vec<Ran>) {
    match action {
        // fresh.rs: the stuck machine is read, deleted, and the chat starts on a fresh one.
        Action::FreshMachine => (
            request(&["--cwd", "/home/cmux/w"]),
            vec![
                ok(json!({"account": {"signed_in": true}, "machines": [
                    {"title": "chat-fresh", "machine_id": "vm-stuck", "status": "running"}]})),
                ok(json!({"deleted": true})),
                signed_in(),
                started(),
            ],
        ),
        // The machine the pending start named, started on again: no list wait for a `--target`.
        // With no `--cwd`, a started chat reads where it runs (the last exec).
        Action::RerunOnMachine => {
            (request(&["--name", "dev"]), vec![signed_in(), started(), exec_out("")])
        }
        Action::Rerun => (request(&["--name", "dev"]), vec![signed_in(), started(), exec_out("")]),
        // cap.rs: the offered machine is deleted, then the start runs again.
        Action::MakeRoom => (
            request(&["--make-room"]),
            vec![ok(json!({"deleted": true})), signed_in(), started(), exec_out("")],
        ),
    }
}

/// The fault-injection table test: every class, injected as the start's failure, recovers to a started chat with
/// no click when the table has an action for it; a class with none comes back unchanged and nothing runs.
#[test]
fn every_class_recovers_on_its_own_or_passes_through_to_click_through() {
    assert!(!Class::ALL.is_empty());
    for &class in Class::ALL {
        let error = injected(class);
        assert_eq!(classify(&error), Some(class), "{class:?} is read from its own error");
        let failure = Outcome::Failed { error: error.clone(), exit: 1 };
        match recovery(class) {
            Some(action) => {
                let (asked, answers) = recovers(action);
                let mut fake = Fake::new(answers);
                let began = fake.clock;
                let asked = bounded(asked, &fake);
                let Outcome::Done(answer) = recover(&mut fake, &asked, began, failure) else {
                    panic!("{class:?} ({action:?}) did not recover: {:?}", fake.ran)
                };
                assert_eq!(answer["session_id"], "sess-1", "{class:?}");
                assert_eq!(
                    answer["recovered"],
                    json!([{"class": format!("{class:?}"), "action": format!("{action:?}")}]),
                    "{class:?} answers its recovered event"
                );
                assert!(fake.answers.is_empty(), "{class:?} used every answer: {:?}", fake.ran);
            }
            None => {
                let mut fake = Fake::new(Vec::new());
                let began = fake.clock;
                let asked = bounded(request(&["--name", "dev", "--make-room"]), &fake);
                let back = recover(&mut fake, &asked, began, failure);
                assert_eq!(back, Outcome::Failed { error, exit: 1 }, "{class:?} passes through");
                assert!(fake.ran.is_empty(), "{class:?} runs nothing: {:?}", fake.ran);
                assert_eq!(fake.paused, Duration::ZERO, "{class:?}");
            }
        }
    }
}

/// A code no class names passes through unchanged, as before the table.
#[test]
fn an_unclassified_code_passes_through() {
    let error = json!({"code": "cloud.folder_missing", "message": "no folder", "details": {}});
    assert_eq!(classify(&error), None);
    let mut fake = Fake::new(Vec::new());
    let began = fake.clock;
    let failure = Outcome::Failed { error: error.clone(), exit: 1 };
    assert_eq!(
        recover(&mut fake, &request(&[]), began, failure),
        Outcome::Failed { error, exit: 1 }
    );
}

/// A machine still starting is started on again by its id, never as a second new machine, after a pause.
#[test]
fn a_pending_start_is_started_again_on_the_machine_it_names() {
    let mut fake = Fake::new(vec![signed_in(), started(), exec_out("")]);
    let began = fake.clock;
    let failure = Outcome::Failed { error: injected(Class::StartPending), exit: 75 };
    let asked = bounded(request(&[]), &fake);
    let Outcome::Done(answer) = recover(&mut fake, &asked, began, failure) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["recovered_reruns"], 1);
    assert_eq!(
        fake.ran[1],
        strings(&[
            "cloud",
            "start-session",
            "--target",
            "machine:vm-1",
            "--agent",
            "claude",
            "--json"
        ])
    );
    assert_eq!(fake.paused, Duration::from_secs(5));
}

#[test]
fn an_explicit_provider_create_recovers_on_its_machine_without_creating_twice() {
    for provider in ["gcp", "own-host", "freestyle"] {
        let mut fake = Fake::new(vec![
            signed_in(),
            made(),
            ok(json!({"pending": true, "machine_id": "vm-1", "text": "still starting"})),
            signed_in(),
            signed_in(),
            started(),
            exec_out(""),
        ]);
        let asked = bounded(request(&["--provider", provider, "--name", "insurance"]), &fake);
        let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
        assert_eq!(answer["machine_id"], "vm-1");
        assert_eq!(answer["new_machine"], true);
        assert_eq!(answer["recovered_reruns"], 1);
        assert_eq!(
            fake.ran.iter().filter(|args| args.get(1).is_some_and(|a| a == "new-machine")).count(),
            1
        );
        assert!(
            fake.ran
                .iter()
                .filter(|args| args.get(1).is_some_and(|a| a == "start-session"))
                .all(|args| args.windows(2).any(|pair| pair == ["--target", "machine:vm-1"])
                    && !args.iter().any(|arg| arg == "--provider"))
        );
    }
}

#[test]
fn an_explicit_provider_never_recovers_onto_an_unverified_pending_machine() {
    let mut fake = Fake::new(vec![]);
    let began = fake.clock;
    let asked = bounded(request(&["--provider", "gcp", "--name", "chat-fresh"]), &fake);
    let error = injected(Class::StartPending);
    let failure = Outcome::Failed { error: error.clone(), exit: 75 };
    let Outcome::Failed { error: after, .. } = recover(&mut fake, &asked, began, failure) else {
        panic!("unverified pending machine must not run")
    };
    assert_eq!(after["code"], error["code"]);
    assert!(fake.ran.is_empty());
    assert_eq!(fake.paused, Duration::ZERO);
}

/// A pending start that names no machine, on a run that asked for a new one, is not started again: that would
/// make a second machine. It passes through.
#[test]
fn a_pending_start_with_no_machine_on_a_new_machine_run_passes_through() {
    let mut error = injected(Class::StartPending);
    error["details"] = json!({});
    let mut fake = Fake::new(Vec::new());
    let began = fake.clock;
    let failure = Outcome::Failed { error: error.clone(), exit: 75 };
    let asked = bounded(request(&[]), &fake);
    assert_eq!(recover(&mut fake, &asked, began, failure), Outcome::Failed { error, exit: 75 });
}

/// A run with no deadline (no `--wait` with a prompt) asked for an answer now: a pending start is not waited on
/// there, and its error says the same command again, as before the table.
#[test]
fn a_run_with_no_deadline_is_not_rerun() {
    for class in [Class::StartPending, Class::ListUnread] {
        let error = injected(class);
        let mut fake = Fake::new(Vec::new());
        let began = fake.clock;
        let failure = Outcome::Failed { error: error.clone(), exit: 75 };
        let back = recover(&mut fake, &request(&["--name", "dev"]), began, failure);
        assert_eq!(back, Outcome::Failed { error, exit: 75 }, "{class:?}");
        assert!(fake.ran.is_empty());
    }
}

/// A pending answer that may have a chat behind it (the prompt on its way, or a started chat) is not a machine
/// still starting: starting again could send the prompt twice.
#[test]
fn a_pending_answer_with_a_chat_behind_it_is_not_started_again() {
    for details in [
        json!({"machine_id": "vm-1", "sent": "unknown"}),
        json!({"machine_id": "vm-1", "answer": {"session_id": "sess-1"}}),
    ] {
        let mut error = injected(Class::StartPending);
        error["details"] = details;
        assert_eq!(classify(&error), None, "{error}");
    }
}

/// Reruns stop when the deadline has no time for the next pause: the last failure stands, with the reruns it took.
#[test]
fn reruns_end_at_the_deadline() {
    let pending = || Ran {
        code: 0,
        stdout: json!({"result": {"pending": true, "machine_id": "vm-1", "machine_name": "dev"}})
            .to_string(),
        ..Ran::default()
    };
    // Each rerun: list, start (pending), and the stage read of the machine list.
    let mut answers = Vec::new();
    for _ in 0..20 {
        answers.extend([signed_in(), pending(), signed_in()]);
    }
    let mut fake = Fake::new(answers);
    let began = fake.clock;
    let mut asked = request(&["--name", "dev"]);
    asked.until = Some(began + Duration::from_secs(60));
    let failure = Outcome::Failed { error: injected(Class::StartPending), exit: 75 };
    let Outcome::Failed { error, .. } = recover(&mut fake, &asked, began, failure) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(at(&error, "code").as_str(), Some("cloud.start_pending"), "{error}");
    assert!(at(at(&error, "details"), "recovered_reruns").as_u64().unwrap_or(0) >= 1, "{error}");
    assert!(fake.clock.saturating_duration_since(began) <= Duration::from_secs(60 + 30), "bounded");
}

/// `--make-room` is the person's consent to delete a machine: without it a cap refusal passes through, as before.
#[test]
fn a_machine_cap_without_make_room_passes_through() {
    let error = injected(Class::MachineCap);
    let mut fake = Fake::new(Vec::new());
    let began = fake.clock;
    let failure = Outcome::Failed { error: error.clone(), exit: 1 };
    assert_eq!(
        recover(&mut fake, &request(&[]), began, failure),
        Outcome::Failed { error, exit: 1 }
    );
}
