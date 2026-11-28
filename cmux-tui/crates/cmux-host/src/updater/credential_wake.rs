//! The wake before a flip (pure): a chat's launch credential must be on a running agent when the
//! flip restarts acpmux.
//!
//! A Cloud chat's model credential comes from its owner's Mac with the agent's start and is never
//! written down on the machine (acpmux `agent_credentials.rs`): acpmux holds it in memory, and
//! the agent it starts holds it in its env. An acpmux that restarts reads it back from the agents
//! it adopts. An idle chat has no agent to read it from: acpmux hibernates the agent after two
//! idle minutes. So a flip that restarted acpmux then (an idle chat holds no update) left the
//! chat without its credential, and its next message answered "Claude is not signed in here"
//! (staging journey, 2026-11-24: a chat idle for four minutes, a flip, then the turn after the
//! machine's resume).
//!
//! acpmux says which sessions are in that state (`credentialOnlyHere` in `acpmux --json ls`), and
//! the last look before a flip wakes each one (`acpmux session wake`): its agent starts on the
//! credential and resumes its conversation, and the new acpmux adopts it and holds the credential
//! again ([`WakeTries::before_flip`]). Only the last look does this, with every other hold
//! already clear, so a chat is not woken every two minutes while something else keeps the update
//! waiting.
//!
//! Wakes take seconds each, and a chat that was idle but awake at the first read may hibernate
//! while others wake. So after a round that woke one, the sessions are read again, and the flip
//! goes only after a read that shows no turn and no session left to wake.
//!
//! Every hold here is bounded, because a chat must not keep a machine on an old build:
//! - a wake that fails holds the look; after [`WAKE_TRIES`] failed wakes of one session the
//!   update goes without it;
//! - a session the caller's time for one look did not reach ([`Woke::NotReached`]) holds the look
//!   and uses none of its tries;
//! - after [`HELD_LOOKS`] looks in a row that wakes held, the update goes with what is awake.
//!
//! A session acpmux does not wake (closed since the list was read) holds nothing. An acpmux from
//! before the field lists none, and the flip goes as it did: the first update onto a build with
//! this module is still run by the build before it.

use std::collections::BTreeMap;

use serde_json::Value;

/// How many wakes of one session may fail before an update stops waiting for it.
pub const WAKE_TRIES: u8 = 3;
/// How many times one look reads the sessions again after it woke one.
pub const ROUNDS: u8 = 3;
/// How many looks in a row the wakes may hold before the update goes without the rest.
pub const HELD_LOOKS: u8 = 6;

/// One session whose launch credential only acpmux's memory holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asleep {
    pub id: String,
    pub name: String,
}

/// The local sessions of an `acpmux --json ls` that say `credentialOnlyHere`. Empty for a list
/// that is not one, or from an acpmux older than the field.
pub fn only_here(ls: &str) -> Vec<Asleep> {
    let Ok(v) = serde_json::from_str::<Value>(ls.trim()) else { return Vec::new() };
    let Some(sessions) = v.get("sessions").and_then(Value::as_array) else { return Vec::new() };
    sessions
        .iter()
        .filter(|s| s.get("peer").is_none())
        .filter(|s| s.get("credentialOnlyHere").and_then(Value::as_bool) == Some(true))
        .filter_map(|s| {
            let id = s.get("sessionId").and_then(Value::as_str)?;
            let name = s.get("name").and_then(Value::as_str).unwrap_or(id);
            Some(Asleep { id: id.to_owned(), name: name.to_owned() })
        })
        .collect()
}

/// What one wake of a session did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Woke {
    /// Its agent runs: the credential is in that agent's env.
    Carried,
    /// acpmux starts no agent for it now (it was closed): nothing to wait for.
    Unwakeable,
    /// The wake did not run, timed out, or its start failed.
    Failed,
    /// Not tried: the look's time ran out, or the updater was told to stop.
    NotReached,
}

/// Reads an `acpmux --json session wake ID`: whether the command exited 0, and its JSON reply
/// (`{woke, reason?}`, acpmux `hub/pause.rs`).
pub fn woke(ok: bool, reply: &str) -> Woke {
    if !ok {
        return Woke::Failed;
    }
    let Ok(v) = serde_json::from_str::<Value>(reply.trim()) else { return Woke::Failed };
    match (v.get("woke").and_then(Value::as_bool), v.get("reason").and_then(Value::as_str)) {
        (Some(true), _) | (Some(false), Some("running")) => Woke::Carried,
        (Some(false), _) => Woke::Unwakeable,
        (None, _) => Woke::Failed,
    }
}

/// What the wakes keep between looks: each session's failed wakes, and how many looks in a row
/// they held. One per updater process (an operator's `cmux host update check` starts its own).
#[derive(Debug, Default)]
pub struct WakeTries {
    failed: BTreeMap<String, u8>,
    held: u8,
}

/// What one round's wakes did.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Looked {
    /// The sessions that still hold the update (a failed wake, or one not reached), by name.
    pub holding: Vec<String>,
    /// How many agents the round started.
    pub woken: usize,
}

impl WakeTries {
    pub const fn new() -> Self {
        Self { failed: BTreeMap::new(), held: 0 }
    }

    /// One round over `ls`: wakes each session it lists through `wake` (by id), one at a time.
    /// `log` gets a line per session that was woken, cannot be, or is given up on.
    pub fn look(
        &mut self,
        ls: &str,
        mut wake: impl FnMut(&str) -> Woke,
        mut log: impl FnMut(&str),
    ) -> Looked {
        let asleep = only_here(ls);
        // A session no longer listed was woken, closed or lost its agent some other way: a later
        // sleep of it starts its tries again.
        self.failed.retain(|id, _| asleep.iter().any(|s| &s.id == id));
        let mut looked = Looked::default();
        for session in asleep {
            if self.failed.get(&session.id).is_some_and(|tries| *tries >= WAKE_TRIES) {
                continue;
            }
            match wake(&session.id) {
                Woke::Carried => {
                    self.failed.remove(&session.id);
                    looked.woken += 1;
                    log(&format!(
                        "woke {}: its agent carries its launch credential across the restart",
                        session.name
                    ));
                }
                Woke::Unwakeable => {
                    self.failed.insert(session.id, WAKE_TRIES);
                    log(&format!(
                        "{} starts no agent now: its launch credential is not kept",
                        session.name
                    ));
                }
                Woke::Failed => {
                    let tries = self.failed.entry(session.id).or_insert(0);
                    *tries += 1;
                    if *tries >= WAKE_TRIES {
                        log(&format!(
                            "{} did not wake in {WAKE_TRIES} tries: the update goes without its launch credential",
                            session.name
                        ));
                    } else {
                        looked.holding.push(format!("{} (waking its agent)", session.name));
                    }
                }
                Woke::NotReached => {
                    looked.holding.push(format!("{} (its agent is not woken yet)", session.name));
                }
            }
        }
        looked
    }

    /// The last look before a flip: what holds it, by name; empty when the flip may go.
    ///
    /// `read` is one look at acpmux: its busy sessions, and its session list (`acpmux --json
    /// ls`; None when no daemon runs). An error is the caller's (it counts as busy). A busy
    /// session holds the flip and no session is woken. Otherwise every session whose credential
    /// only acpmux holds is woken through `wake`, and after a round that woke one the sessions
    /// are read again: the flip goes after a read with no busy session and none left to wake.
    pub fn before_flip(
        &mut self,
        mut read: impl FnMut() -> Result<(Vec<String>, Option<String>), String>,
        mut wake: impl FnMut(&str) -> Woke,
        mut log: impl FnMut(&str),
    ) -> Result<Vec<String>, String> {
        let mut rounds = 0;
        let holding = loop {
            let (busy, ls) = read()?;
            if !busy.is_empty() {
                return Ok(busy);
            }
            let Some(ls) = ls else { break Vec::new() };
            let looked = self.look(&ls, &mut wake, &mut log);
            if !looked.holding.is_empty() || looked.woken == 0 {
                break looked.holding;
            }
            rounds += 1;
            if rounds == ROUNDS {
                break vec!["chats that went idle while others woke".to_owned()];
            }
        };
        if holding.is_empty() {
            self.held = 0;
            return Ok(holding);
        }
        self.held += 1;
        if self.held <= HELD_LOOKS {
            return Ok(holding);
        }
        self.held = 0;
        log(&format!(
            "the wakes held {HELD_LOOKS} looks: the update goes, and these keep no launch credential: {}",
            holding.join(", ")
        ));
        // The wakes took time: a turn that started meanwhile still holds the flip.
        Ok(read()?.0)
    }
}

#[cfg(test)]
mod tests {
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
        assert_eq!(
            woke(true, r#"{"sessionId":"s","woke":false,"reason":"running"}"#),
            Woke::Carried
        );
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
        assert_eq!(
            tries.before_flip(reads(vec![Ok((Vec::new(), None))]), never, |_| {}),
            Ok(vec![])
        );
        assert_eq!(tries.before_flip(reads(vec![idle(&[])]), never, |_| {}), Ok(vec![]));
        // A busy session holds the flip, and no chat is woken behind it.
        let busy = Ok((vec!["turn".to_owned()], Some(ls(&["a"]))));
        assert_eq!(
            tries.before_flip(reads(vec![busy]), never, |_| {}),
            Ok(vec!["turn".to_owned()])
        );
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
            assert_eq!(
                tries.before_flip(reads(vec![idle(&["a"])]), late, |_| {}).unwrap().len(),
                1
            );
        }
        assert_eq!(tries.before_flip(reads(vec![idle(&[])]), late, |_| {}), Ok(vec![]));
        for _ in 0..HELD_LOOKS {
            assert_eq!(
                tries.before_flip(reads(vec![idle(&["a"])]), late, |_| {}).unwrap().len(),
                1
            );
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
}
