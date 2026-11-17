//! The automatic first step of `acpmux register` that `acpmux send` from an unregistered Claude
//! Code chat asks for (`_acpmux/register` with `auto`, `cli/reply_address.rs`), so the chat ends
//! up with a reply address with no person's step (ask-828b64b532).
//!
//! It is asked on every such send, so it must cost little and say each thing once:
//! - Before any proof, from what the daemon holds for the caller's inbox and token alone: the
//!   chat registered with them (nothing to do), a code still waiting for its echo, a first step
//!   for them already running (one code, never two from sends at once), or a failure kept from
//!   a recent try (said once, not re-proven on every send). Only the session's own shell holds
//!   its token, and nothing is delivered or registered here.
//! - After the proof (`register.rs`, unchanged), what to do for the conversation: a chat the
//!   bridge already reaches gets no code; a chat that has a name (registered before a restart,
//!   or listed by the bridge) is registered under that name, never renamed; any other gets the
//!   name the send asked for, when no other session has it.

use super::*;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{Duration, Instant};

/// How long a failed automatic first step is kept, answered without a new proof.
const FAILURE_TTL: Duration = Duration::from_secs(300);

/// The caller's inbox and token: what an automatic first step is known by.
type Key = (PathBuf, String);

/// First steps running, by inbox and token.
static IN_FLIGHT: std::sync::LazyLock<std::sync::Mutex<HashSet<Key>>> =
    std::sync::LazyLock::new(Default::default);

/// Recent failures, by inbox and token: why, and when.
static FAILED: std::sync::LazyLock<std::sync::Mutex<HashMap<Key, (String, Instant)>>> =
    std::sync::LazyLock::new(Default::default);

/// A first step running for one inbox and token; released when dropped.
pub(super) struct Reservation(Key);

impl Reservation {
    /// Keeps `why` for this inbox and token for [`FAILURE_TTL`].
    pub(super) fn failed(&self, why: &str) {
        let mut failed = FAILED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        failed.insert(self.0.clone(), (why.to_owned(), Instant::now()));
    }
}

impl Drop for Reservation {
    fn drop(&mut self) {
        IN_FLIGHT.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&self.0);
    }
}

/// What an automatic first step does before any proof.
pub(super) enum Step {
    /// The answer, with nothing proven, delivered or changed.
    Answer(Value),
    /// Prove the caller and go on; the reservation holds off another send's step meanwhile.
    Go(Reservation),
}

/// What the proven conversation gets.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Plan {
    /// The bridge already reaches it (its setting on, the entrypoint listed): no code, and the
    /// chat's name when it has one.
    Reachable(Option<String>),
    /// A code for this name.
    Code(String),
    /// The name asked for is another session's.
    Taken,
}

/// The chat the daemon already shows for the conversation.
#[derive(Debug, Clone)]
pub(super) struct Own {
    pub name: String,
    /// `register` registered it (`is_registered`): after a restart it needs the new token.
    pub registered: bool,
    /// The bridge watches it (a chat it listed, not one acpmux runs).
    pub watched: bool,
}

/// What `asked` (the send's name) becomes for a conversation shown as `own`, when the bridge
/// lists its entrypoint (`bridged`) and `taken` says whether another session has a name.
pub(super) fn plan(
    asked: &str,
    own: Option<Own>,
    bridged: bool,
    taken: impl Fn(&str) -> bool,
) -> Plan {
    match own {
        // Its address is its name: registering it again keeps it.
        Some(own) if own.registered => Plan::Code(own.name),
        Some(own) if bridged && own.watched => Plan::Reachable(Some(own.name)),
        Some(own) => Plan::Code(own.name),
        // The bridge lists it on its next scan, under a name of its own.
        None if bridged => Plan::Reachable(None),
        None if taken(asked) => Plan::Taken,
        None => Plan::Code(asked.to_owned()),
    }
}

/// The name of a code in `pending` still waiting for its echo from `socket` with `token`.
pub(super) fn pending_name(
    pending: &HashMap<u32, Pending>,
    socket: &Path,
    token: &str,
) -> Option<String> {
    pending
        .values()
        .find(|p| p.socket == socket && p.token == token && p.at.elapsed() < CODE_TTL)
        .map(|p| p.name.clone())
}

impl Hub {
    /// [`Step`] for the caller's `socket` and `token`, from the tokens `register` kept in `home`
    /// (`claude_peers::save_token`), the codes waiting, the steps running and recent failures.
    pub(super) fn auto_answer(&self, home: &Path, socket: &Path, token: &str) -> Step {
        let registered: Vec<(String, String)> = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            sessions
                .values()
                .filter(|s| is_registered(s))
                .map(|s| (s.id.clone(), s.read_meta(|m| m.name.clone())))
                .collect()
        };
        if let Some((_, name)) = registered.into_iter().find(|(id, _)| {
            crate::claude_peers::kept_token(home, id)
                .is_some_and(|k| k.socket == socket && k.token == token)
        }) {
            return Step::Answer(json!({"registered": true, "name": name}));
        }
        // Held while the step is reserved: `send_code` records its code under this lock before
        // the reservation goes, so a send at the same time sees one or the other.
        let pending = PENDING.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(name) = pending_name(&pending, socket, token) {
            return Step::Answer(json!({"pending": true, "resent": false, "name": name}));
        }
        let key: Key = (socket.to_path_buf(), token.to_owned());
        {
            let mut failed = FAILED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            failed.retain(|_, (_, at)| at.elapsed() < FAILURE_TTL);
            if let Some((why, _)) = failed.get(&key) {
                return Step::Answer(json!({"failed": why, "repeat": true}));
            }
        }
        let mut running = IN_FLIGHT.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if !running.insert(key.clone()) {
            return Step::Answer(json!({"pending": true, "resent": false}));
        }
        Step::Go(Reservation(key))
    }

    /// [`Plan`] for the proven conversation `claimed`, asked as `asked`.
    pub(super) async fn auto_plan(&self, claimed: &crate::claude_peers::Peer, asked: &str) -> Plan {
        let entrypoint = claimed.entrypoint.clone();
        let bridged = tokio::task::spawn_blocking(move || {
            crate::claude_peers::enabled()
                && entrypoint
                    .is_some_and(|e| crate::claude_peers::listed_entrypoints().contains(&e))
        })
        .await
        .unwrap_or(false);
        let stores = crate::hub::adoption::store_families(&*self.config.read().await);
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        let shown =
            crate::hub::adoption::adopted_in(&sessions, &stores, "claude", &claimed.session_id);
        let own = shown.as_ref().map(|s| Own {
            name: s.read_meta(|m| m.name.clone()),
            registered: is_registered(s),
            watched: s.read_meta(|m| m.watching.is_some()),
        });
        let taken = |name: &str| sessions.values().any(|s| s.read_meta(|m| m.name == name));
        plan(asked, own, bridged, taken)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, StoreMode};
    use crate::store::MemoryStore;

    fn hub() -> Arc<Hub> {
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        Hub::new(cfg, Box::new(MemoryStore::default()))
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acpmux-auto-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn pending(name: &str, socket: &str, token: &str, age: u64) -> Pending {
        Pending {
            code: "c0de".into(),
            started: 7,
            socket: PathBuf::from(socket),
            token: token.into(),
            name: name.into(),
            at: Instant::now().checked_sub(Duration::from_secs(age)).unwrap_or_else(Instant::now),
        }
    }

    fn answer(step: Step) -> Value {
        match step {
            Step::Answer(v) => v,
            Step::Go(_) => panic!("expected an answer, got a step to prove"),
        }
    }

    /// A send from an unregistered chat asks for the first step on every send; a code still
    /// waiting for its echo there is found, so no second one is delivered.
    #[test]
    fn a_waiting_code_is_found_by_its_inbox_and_token_until_it_expires() {
        let sock = Path::new("/tmp/cc-socks/1.sock");
        let mut codes = HashMap::new();
        codes.insert(1, pending("claude-desktop-03214b87", "/tmp/cc-socks/1.sock", "tok", 5));
        assert_eq!(pending_name(&codes, sock, "tok").as_deref(), Some("claude-desktop-03214b87"));
        assert_eq!(pending_name(&codes, sock, "other"), None, "another token");
        assert_eq!(pending_name(&codes, Path::new("/tmp/cc-socks/2.sock"), "tok"), None);
        let old = CODE_TTL.as_secs() + 1;
        codes.insert(1, pending("claude-desktop-03214b87", "/tmp/cc-socks/1.sock", "tok", old));
        assert_eq!(pending_name(&codes, sock, "tok"), None, "expired: a new code goes");
    }

    /// A chat registered with the caller's inbox and token answers at once, with its name; a
    /// restarted process (a new token) is not taken for it.
    #[tokio::test]
    async fn a_chat_registered_with_the_callers_token_is_answered_with_no_proof() {
        let home = scratch("registered");
        let hub = hub();
        let cwd = Some(home.clone());
        let session =
            hub.new_session(crate::hub::NewRequest { cwd, ..Default::default() }).await.unwrap();
        session.meta.lock().unwrap().name = "desktop-zoe".into();
        mark_registered_for_test(&session.id);
        let sock = home.join("inbox.sock");
        let kept = crate::claude_peers::ChildToken {
            pid: 42,
            socket: sock.clone(),
            token: "tok-registered".into(),
            started: Some(7),
        };
        crate::claude_peers::save_token(&home, &session.id, &kept).unwrap();
        let v = answer(hub.auto_answer(&home, &sock, "tok-registered"));
        assert_eq!(v, json!({"registered": true, "name": "desktop-zoe"}));
        assert!(
            matches!(hub.auto_answer(&home, &sock, "tok-after-restart"), Step::Go(_)),
            "a new token proves again"
        );
    }

    /// Repro: two sends at once both missed the waiting-code check and both delivered a code
    /// (the second replacing the first). The first reserves the step; the second is told a code
    /// is coming; once the first is done another may go.
    #[test]
    fn two_sends_at_once_start_one_step() {
        let hub = hub();
        let (home, sock) = (scratch("race"), Path::new("/tmp/cc-socks/race.sock"));
        let first = hub.auto_answer(&home, sock, "tok-race");
        assert!(matches!(first, Step::Go(_)));
        let second = answer(hub.auto_answer(&home, sock, "tok-race"));
        assert_eq!(second, json!({"pending": true, "resent": false}));
        assert!(matches!(hub.auto_answer(&home, sock, "tok-other"), Step::Go(_)), "own key");
        drop(first);
        assert!(matches!(hub.auto_answer(&home, sock, "tok-race"), Step::Go(_)), "released");
    }

    /// A failure (an unsigned process, a chat with no transcript yet, a taken name) is kept for
    /// its inbox and token, so the next sends neither prove again nor warn again.
    #[test]
    fn a_failure_is_answered_again_without_a_new_proof() {
        let hub = hub();
        let (home, sock) = (scratch("failed"), Path::new("/tmp/cc-socks/failed.sock"));
        let Step::Go(step) = hub.auto_answer(&home, sock, "tok-failed") else { panic!() };
        step.failed("register.unproven: process 42 is not signed as Claude Code");
        drop(step);
        let v = answer(hub.auto_answer(&home, sock, "tok-failed"));
        assert_eq!(v["repeat"], true, "{v}");
        assert!(v["failed"].as_str().unwrap().contains("not signed"), "{v}");
    }

    /// The answer comes before any proof: a caller no Claude Code process runs (pid 1 here,
    /// which the proof would refuse as `register.no_session`) is told of its waiting code.
    #[tokio::test]
    async fn an_automatic_step_with_a_waiting_code_is_answered_before_the_proof() {
        let hub = hub();
        let sock = "/tmp/cc-socks/early.sock";
        PENDING
            .lock()
            .unwrap()
            .insert(900_101, pending("claude-desktop-0badc0de", sock, "tok-early", 1));
        let req = |auto| RegisterRequest {
            name: "claude-desktop-0badc0de".into(),
            socket: Some(PathBuf::from(sock)),
            token: Some("tok-early".into()),
            code: None,
            auto,
        };
        let v = hub.register_caller(1, req(true)).await.unwrap();
        assert_eq!(v, json!({"pending": true, "resent": false, "name": "claude-desktop-0badc0de"}));
        let err = hub.register_caller(1, req(false)).await.unwrap_err();
        assert!(err.message.contains("no Claude Code session"), "typed register proves: {err:?}");
        PENDING.lock().unwrap().remove(&900_101);
    }

    fn own(name: &str, registered: bool, watched: bool) -> Option<Own> {
        Some(Own { name: name.into(), registered, watched })
    }

    /// Repro: after a Claude Code restart (a new token) the registered chat `desktop-zoe` got a
    /// code for `claude-desktop-<id8>`, and finishing it renamed the chat, breaking its address.
    /// A chat with a name is registered under that name; a chat the bridge reaches gets no code.
    #[test]
    fn a_chat_with_a_name_keeps_it_and_one_the_bridge_reaches_gets_no_code() {
        let none = |_: &str| false;
        let asked = "claude-desktop-03214b87";
        let p = plan(asked, own("desktop-zoe", true, true), false, none);
        assert_eq!(p, Plan::Code("desktop-zoe".into()), "registered, restarted");
        let p = plan(asked, own("desktop-zoe", true, true), true, none);
        assert_eq!(
            p,
            Plan::Code("desktop-zoe".into()),
            "registered needs its token, bridge or not"
        );
        let p = plan(asked, own("my-folder", false, true), true, none);
        assert_eq!(p, Plan::Reachable(Some("my-folder".into())), "the bridge lists it");
        let p = plan(asked, own("my-folder", false, true), false, none);
        assert_eq!(p, Plan::Code("my-folder".into()), "listed before, setting off now");
        assert_eq!(plan(asked, None, true, none), Plan::Reachable(None), "listed on its next scan");
        assert_eq!(plan(asked, None, false, none), Plan::Code(asked.into()));
        let taken = |name: &str| name == asked;
        assert_eq!(plan(asked, None, false, taken), Plan::Taken, "another session's name");
        let p = plan(asked, own(asked, false, false), false, taken);
        assert_eq!(p, Plan::Code(asked.into()), "its own name is not taken from it");
    }

    /// Repro: an older daemon ignores `auto` and delivers a code on every send; the CLI asks
    /// only a daemon that lists the feature (`cli/reply_address.rs`).
    #[tokio::test]
    async fn initialize_lists_the_automatic_register_feature() {
        let hub = hub();
        let (input, incoming) = tokio::sync::mpsc::channel(8);
        let (output, mut outgoing) = tokio::sync::mpsc::channel(8);
        let task = tokio::spawn(crate::server::serve_connection(hub.clone(), incoming, output));
        let hello = crate::rpc::Message::request(1, "initialize", json!({"protocolVersion": 1}));
        input.send(hello.to_line()).await.unwrap();
        // timeout: Test-only deadline detects a missing reply; no user request is cancelled.
        let line =
            tokio::time::timeout(Duration::from_secs(10), outgoing.recv()).await.unwrap().unwrap();
        drop(input);
        task.abort();
        let reply: Value = serde_json::from_str(&line).unwrap();
        let features = reply["result"]["_meta"]["acpmux"]["features"].as_array().unwrap();
        assert!(features.iter().any(|f| f == AUTO_FEATURE), "{reply}");
    }
}
