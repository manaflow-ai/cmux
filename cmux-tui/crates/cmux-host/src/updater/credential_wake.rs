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
//! again. Only the last look does this, with every other hold already clear, so a chat is not
//! woken every two minutes while something else keeps the update waiting.
//!
//! A wake that fails holds the update for that look. After [`WAKE_TRIES`] failed wakes of one
//! session the update goes without it: a chat whose agent cannot start must not keep a machine
//! on an old build. A session acpmux does not wake (closed since the list was read) holds
//! nothing. An acpmux from before the field lists none, and the flip goes as it did.

use std::collections::BTreeMap;

use serde_json::Value;

/// How many wakes of one session may fail before an update stops waiting for it.
pub const WAKE_TRIES: u8 = 3;

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

/// What one `acpmux --json session wake ID` did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Woke {
    /// Its agent runs: the credential is in that agent's env.
    Carried,
    /// acpmux starts no agent for it now (it was closed): nothing to wait for.
    Unwakeable,
    /// The wake did not run, timed out, or its start failed.
    Failed,
}

/// Reads a wake's result: whether the command exited 0, and its JSON reply (`{woke, reason?}`,
/// acpmux `hub/pause.rs`).
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

/// The failed wakes of each session, kept between looks.
#[derive(Debug, Default)]
pub struct WakeTries(BTreeMap<String, u8>);

/// What one look's wakes did.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Looked {
    /// The sessions whose wake failed and that still hold the update, by name.
    pub holding: Vec<String>,
    /// How many agents the look started.
    pub woken: usize,
}

impl WakeTries {
    pub const fn new() -> Self {
        Self(BTreeMap::new())
    }

    /// One look at `ls`: wakes each session it lists through `wake` (by id), one at a time.
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
        self.0.retain(|id, _| asleep.iter().any(|s| &s.id == id));
        let mut looked = Looked::default();
        for session in asleep {
            if self.0.get(&session.id).is_some_and(|tries| *tries >= WAKE_TRIES) {
                continue;
            }
            match wake(&session.id) {
                Woke::Carried => {
                    self.0.remove(&session.id);
                    looked.woken += 1;
                    log(&format!(
                        "woke {}: its agent carries its launch credential across the restart",
                        session.name
                    ));
                }
                Woke::Unwakeable => {
                    self.0.insert(session.id, WAKE_TRIES);
                    log(&format!(
                        "{} starts no agent now: its launch credential is not kept",
                        session.name
                    ));
                }
                Woke::Failed => {
                    let tries = self.0.entry(session.id).or_insert(0);
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
            }
        }
        looked
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
}
