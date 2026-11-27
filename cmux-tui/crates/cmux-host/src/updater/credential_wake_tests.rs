use super::*;
use serde_json::json;
use std::cell::{Cell, RefCell};

fn ls(names: &[&str]) -> String {
    let mut sessions = vec![
        json!({"sessionId": "s-idle", "name": "idle", "status": "idle"}),
        json!({"sessionId": "s-peer", "name": "peer", "peer": "mac", "credentialOnlyHere": true}),
        json!({"sessionId": "s-false", "name": "false", "credentialOnlyHere": false}),
    ];
    for name in names {
        sessions.push(
            json!({"sessionId": format!("s-{name}"), "name": name, "credentialOnlyHere": true}),
        );
    }
    json!({"sessions": sessions}).to_string()
}

type Read = Result<(Vec<String>, Option<String>), String>;

/// A `read` that answers each of `reads` in turn, then panics.
fn reads(reads: Vec<Read>) -> impl FnMut() -> Read {
    let mut reads = reads.into_iter();
    move || reads.next().expect("one read too many")
}

fn idle(names: &[&str]) -> Read {
    Ok((Vec::new(), Some(ls(names))))
}

#[test]
fn only_local_sessions_that_say_so_are_listed() {
    assert_eq!(
        only_here(&ls(&["a", "b"])),
        vec![
            Asleep { id: "s-a".to_owned(), name: "a".to_owned() },
            Asleep { id: "s-b".to_owned(), name: "b".to_owned() },
        ]
    );
    // An older acpmux's list, an empty one, and no list at all.
    assert!(only_here(&ls(&[])).is_empty());
    assert!(only_here("{\"sessions\": []}").is_empty());
    assert!(only_here("not json").is_empty());
    assert!(only_here("{}").is_empty());
}

#[test]
fn a_wakes_reply_is_read() {
    assert_eq!(woke(true, r#"{"sessionId":"s","woke":true,"tookMs":812}"#), Woke::Carried);
    assert_eq!(woke(true, r#"{"sessionId":"s","woke":false,"reason":"running"}"#), Woke::Carried);
    assert_eq!(
        woke(true, r#"{"sessionId":"s","woke":false,"reason":"stopped"}"#),
        Woke::Unwakeable
    );
    assert_eq!(woke(false, r#"{"sessionId":"s","woke":true}"#), Woke::Failed);
    assert_eq!(woke(true, ""), Woke::Failed);
    assert_eq!(woke(true, "{}"), Woke::Failed);
}

#[test]
fn each_listed_session_is_woken_and_holds_nothing_once_its_agent_runs() {
    let mut tries = WakeTries::new();
    let (mut asked, mut lines) = (Vec::new(), Vec::new());
    let looked = tries.look(
        &ls(&["a", "b"]),
        |id| {
            asked.push(id.to_owned());
            Woke::Carried
        },
        |line| lines.push(line.to_owned()),
    );
    assert_eq!(asked, ["s-a", "s-b"], "by id, never a peer's or an unmarked session");
    assert_eq!(looked, Looked { holding: Vec::new(), woken: 2 });
    assert_eq!(lines.len(), 2, "{lines:?}");
    // Nothing listed: nothing is asked.
    let looked = tries.look(&ls(&[]), |_| panic!("no session to wake"), |_| {});
    assert_eq!(looked, Looked::default());
}

#[test]
fn a_failed_wake_holds_the_update_for_a_bounded_number_of_looks() {
    let mut tries = WakeTries::new();
    let list = ls(&["a"]);
    for _ in 1..WAKE_TRIES {
        let looked = tries.look(&list, |_| Woke::Failed, |_| {});
        assert_eq!(looked.holding, ["a (waking its agent)"]);
    }
    // The last try gives up, says so once, and asks no more.
    let mut lines = Vec::new();
    let looked = tries.look(&list, |_| Woke::Failed, |line| lines.push(line.to_owned()));
    assert_eq!(looked, Looked::default());
    assert_eq!(lines.len(), 1, "{lines:?}");
    let looked = tries.look(&list, |_| panic!("given up on"), |_| panic!("said once"));
    assert_eq!(looked, Looked::default());
    // Once it is no longer listed (woken by its person, say), a later sleep is tried again.
    tries.look(&ls(&[]), |_| panic!("not listed"), |_| {});
    let looked = tries.look(&list, |_| Woke::Failed, |_| {});
    assert_eq!(looked.holding, ["a (waking its agent)"]);
}

#[test]
fn a_wake_that_works_after_a_failure_clears_its_tries() {
    let mut tries = WakeTries::new();
    let list = ls(&["a"]);
    assert_eq!(tries.look(&list, |_| Woke::Failed, |_| {}).holding.len(), 1);
    assert_eq!(
        tries.look(&list, |_| Woke::Carried, |_| {}),
        Looked { holding: Vec::new(), woken: 1 }
    );
    // Asleep again later: its full tries are there.
    for _ in 1..WAKE_TRIES {
        assert_eq!(tries.look(&list, |_| Woke::Failed, |_| {}).holding.len(), 1);
    }
}

#[test]
fn a_session_acpmux_does_not_wake_holds_nothing_and_is_asked_once() {
    let mut tries = WakeTries::new();
    let list = ls(&["closed", "b"]);
    let mut asked = Vec::new();
    let looked = tries.look(
        &list,
        |id| {
            asked.push(id.to_owned());
            if id == "s-closed" { Woke::Unwakeable } else { Woke::Carried }
        },
        |_| {},
    );
    assert_eq!(looked, Looked { holding: Vec::new(), woken: 1 });
    let looked = tries.look(
        &list,
        |id| {
            asked.push(id.to_owned());
            Woke::Carried
        },
        |_| {},
    );
    assert_eq!(looked.woken, 1);
    assert_eq!(asked, ["s-closed", "s-b", "s-b"]);
}

#[test]
fn a_session_not_reached_holds_the_look_and_keeps_its_tries() {
    let mut tries = WakeTries::new();
    let list = ls(&["a", "late"]);
    // Far more looks than a failed wake's tries: `late` is never given up on.
    for _ in 0..WAKE_TRIES * 3 {
        let looked = tries.look(
            &list,
            |id| if id == "s-late" { Woke::NotReached } else { Woke::Carried },
            |_| {},
        );
        assert_eq!(looked.holding, ["late (its agent is not woken yet)"]);
    }
    let looked = tries.look(&list, |_| Woke::Carried, |_| {});
    assert_eq!(looked, Looked { holding: Vec::new(), woken: 2 });
}

#[test]
fn nothing_to_wake_reads_once_and_wakes_nothing() {
    let mut tries = WakeTries::new();
    let never = |_: &str| -> Woke { panic!("no session to wake") };
    // No daemon, an idle one, and one from before the field.
    assert_eq!(tries.before_flip(reads(vec![Ok((Vec::new(), None))]), never, |_| {}), Ok(vec![]));
    assert_eq!(tries.before_flip(reads(vec![idle(&[])]), never, |_| {}), Ok(vec![]));
    // A busy session holds the flip, and no chat is woken behind it.
    let busy = Ok((vec!["turn".to_owned()], Some(ls(&["a"]))));
    assert_eq!(tries.before_flip(reads(vec![busy]), never, |_| {}), Ok(vec!["turn".to_owned()]));
    // A read that fails is the caller's error.
    let failed = Err("acpmux ls failed".to_owned());
    assert_eq!(
        tries.before_flip(reads(vec![failed]), never, |_| {}),
        Err("acpmux ls failed".to_owned())
    );
}

/// The window the wakes themselves open: a chat that was idle but awake at the first read
/// hibernates while another wakes. The flip waits for a read that shows none left.
#[test]
fn a_chat_that_goes_idle_while_others_wake_is_woken_before_the_flip() {
    let mut tries = WakeTries::new();
    let asked = RefCell::new(Vec::new());
    let held = tries.before_flip(
        reads(vec![idle(&["a"]), idle(&["x"]), idle(&[])]),
        |id| {
            asked.borrow_mut().push(id.to_owned());
            Woke::Carried
        },
        |_| {},
    );
    assert_eq!(held, Ok(vec![]));
    assert_eq!(*asked.borrow(), ["s-a", "s-x"]);
}

#[test]
fn a_turn_that_starts_during_the_wakes_holds_the_flip() {
    let mut tries = WakeTries::new();
    let held = tries.before_flip(
        reads(vec![idle(&["a"]), Ok((vec!["a".to_owned()], Some(ls(&[]))))]),
        |_| Woke::Carried,
        |_| {},
    );
    assert_eq!(held, Ok(vec!["a".to_owned()]));
}

#[test]
fn chats_that_keep_going_idle_hold_one_look_after_its_rounds() {
    let mut tries = WakeTries::new();
    let read_count = Cell::new(0);
    let held = tries.before_flip(
        || {
            read_count.set(read_count.get() + 1);
            idle(&["a"])
        },
        |_| Woke::Carried,
        |_| {},
    );
    assert_eq!(held, Ok(vec!["chats that went idle while others woke".to_owned()]));
    assert_eq!(read_count.get(), usize::from(ROUNDS));
}

#[test]
fn wakes_hold_a_bounded_number_of_looks_in_a_row() {
    let mut tries = WakeTries::new();
    let late = |_: &str| Woke::NotReached;
    for _ in 0..HELD_LOOKS {
        let held = tries.before_flip(reads(vec![idle(&["a"])]), late, |_| {});
        assert_eq!(held, Ok(vec!["a (its agent is not woken yet)".to_owned()]));
    }
    // The next look gives up: it says which chats lose theirs, and reads once more for a turn.
    let mut lines = Vec::new();
    let held = tries.before_flip(reads(vec![idle(&["a"]), idle(&["a"])]), late, |line| {
        lines.push(line.to_owned());
    });
    assert_eq!(held, Ok(vec![]));
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].contains("a (its agent is not woken yet)"), "{lines:?}");
    // The count starts again, and a look that holds nothing clears it.
    for _ in 0..HELD_LOOKS - 1 {
        assert_eq!(tries.before_flip(reads(vec![idle(&["a"])]), late, |_| {}).unwrap().len(), 1);
    }
    assert_eq!(tries.before_flip(reads(vec![idle(&[])]), late, |_| {}), Ok(vec![]));
    for _ in 0..HELD_LOOKS {
        assert_eq!(tries.before_flip(reads(vec![idle(&["a"])]), late, |_| {}).unwrap().len(), 1);
    }
}

#[test]
fn a_turn_found_when_the_wakes_are_given_up_still_holds_the_flip() {
    let mut tries = WakeTries::new();
    let late = |_: &str| Woke::NotReached;
    for _ in 0..HELD_LOOKS {
        tries.before_flip(reads(vec![idle(&["a"])]), late, |_| {}).unwrap();
    }
    let turn = Ok((vec!["turn".to_owned()], Some(ls(&["a"]))));
    let held = tries.before_flip(reads(vec![idle(&["a"]), turn]), late, |_| {});
    assert_eq!(held, Ok(vec!["turn".to_owned()]));
}
