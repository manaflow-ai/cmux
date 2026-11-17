//! `acpmux register NAME`: a Claude Code session acpmux did not start (the Claude desktop app's
//! Code tab, a Claude Code terminal) takes a stable acpmux name from its own shell,
//! so `acpmux send NAME` from any machine that peers this one reaches it, through the outbox's
//! queue, retries and `--status` like any other session (Leo, 2026-11-09: "how formalized/
//! productionized is this rn, and how much further do we need to take things?").
//!
//! Who registers is what the kernel says, never what the caller types: the unix socket peer's
//! ancestry (`sender_harness::ancestors`) must hold the live Claude Code process the registry
//! lists (`claude_peers.rs`), and when the caller passes the inbox it runs under
//! (`CLAUDE_CODE_MESSAGING_SOCKET`), that process's own inbox. The nearest such ancestor is the
//! one registered. A Codex desktop thread does not register: nothing the kernel shows ties a
//! caller to its thread (a process named `codex` with `CODEX_THREAD_ID` set is anyone's to
//! make), so it is reached through the bridge setting, or started with acpmux instead. Claude Code's documented per-session token (`CLAUDE_CODE_MESSAGING_TOKEN`)
//! is kept beside the daemon (`claude_peers::save_token`) and opens each later delivery while
//! the same process runs.
//!
//! The name goes on the chat that shows the conversation: the bridge's watched chat (made here
//! when there is none), or the session itself when acpmux runs it. The watched chat is tagged
//! `bridge=<family>` and `bridge.registered=true`; while it carries that tag, `bridge.rs` delivers
//! into it and `desktop_bridge.rs` binds its shell's sends to it, with the bridge setting
//! (`agents.desktopBridge.enabled`) on or off. A name another session has is refused.

use super::{Hub, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

/// The tag a registered chat carries.
pub const REGISTERED_TAG: &str = "bridge.registered";

/// The chats `acpmux register` registered, kept by the daemon alone (`bridge-registered.json` in
/// its home, owner-only): the tag shows it, but a client can set tags (`_acpmux/tag`), so the tag
/// alone never makes a chat deliverable. Read once, at the first use.
static REGISTERED: std::sync::LazyLock<std::sync::Mutex<Option<HashSet<String>>>> =
    std::sync::LazyLock::new(Default::default);

fn registered_file() -> PathBuf {
    crate::config::home().join("bridge-registered.json")
}

fn with_registered<T>(f: impl FnOnce(&mut HashSet<String>) -> T) -> T {
    let mut kept = REGISTERED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let set = kept.get_or_insert_with(|| {
        std::fs::read(registered_file())
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<String>>(&b).ok())
            .map(|ids| ids.into_iter().collect())
            .unwrap_or_default()
    });
    f(set)
}

/// Keeps chat `id` registered, across a daemon restart. The file is written while the record's
/// lock is held, so two registrations at once never write an older set over a newer one.
fn mark_registered(id: &str) -> anyhow::Result<()> {
    with_registered(|set| -> anyhow::Result<()> {
        set.insert(id.to_owned());
        let mut ids: Vec<&String> = set.iter().collect();
        ids.sort();
        crate::agent_tools::write_private(&registered_file(), &serde_json::to_vec(&ids)?)
    })
}

/// Marks chat `id` registered for this process only (tests, which must not write the home).
#[cfg(test)]
pub(super) fn mark_registered_for_test(id: &str) {
    with_registered(|set| set.insert(id.to_owned()));
}

/// Whether `session` is a chat its own session registered: the daemon's record alone. The
/// `bridge.registered` tag only shows it; tags are a client's to edit (set, remove, or pass at
/// creation), so neither adding nor removing one changes what is registered.
pub(crate) fn is_registered(session: &Session) -> bool {
    with_registered(|set| set.contains(&session.id))
}

/// What `acpmux register` sends (`_acpmux/register`).
#[derive(Debug, Default)]
pub struct RegisterRequest {
    pub name: String,
    /// `CLAUDE_CODE_MESSAGING_SOCKET` in the caller's environment.
    pub socket: Option<PathBuf>,
    /// `CLAUDE_CODE_MESSAGING_TOKEN` in the caller's environment.
    pub token: Option<String>,
    /// The one-time code acpmux delivered into the session's inbox (`--code`): the second step.
    pub code: Option<String>,
}

impl RegisterRequest {
    pub fn from_params(params: &Value) -> Result<Self, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).filter(|s| !s.is_empty());
        let name = text("name").ok_or_else(|| RpcError::invalid_params("name is required"))?;
        crate::session_name::validate(name).map_err(RpcError::invalid_params)?;
        let token = text("token").map(str::to_owned);
        if token.as_ref().is_some_and(|t| t.len() > 4096 || t.contains(['\n', '\r'])) {
            return Err(RpcError::invalid_params("token is not a Claude Code messaging token"));
        }
        let code = text("code").map(str::to_owned);
        if code.as_ref().is_some_and(|c| c.len() > 128) {
            return Err(RpcError::invalid_params("code is not a register code"));
        }
        Ok(Self { name: name.to_owned(), socket: text("socket").map(PathBuf::from), token, code })
    }
}

/// The conversation the caller runs in.
enum Found {
    Claude(crate::claude_peers::Peer),
}

/// The nearest of `ancestry` that `live` lists, with `socket` its inbox when one is given.
pub(super) fn nearest_claude(
    ancestry: &[u32],
    live: &[crate::claude_peers::Peer],
    socket: Option<&std::path::Path>,
) -> Option<crate::claude_peers::Peer> {
    ancestry.iter().find_map(|pid| {
        live.iter()
            .find(|p| p.pid == *pid && socket.is_none_or(|s| p.socket.as_deref() == Some(s)))
            .cloned()
    })
}

/// `ancestry` (the caller first) up to, not including, this daemon's own pid.
fn below_daemon(mut ancestry: Vec<u32>) -> Vec<u32> {
    let me = std::process::id();
    if let Some(at) = ancestry.iter().position(|p| *p == me) {
        ancestry.truncate(at);
    }
    ancestry
}

impl Hub {
    /// Registers the conversation the process `peer_pid` runs in under `req.name`.
    pub async fn register_caller(
        self: &Arc<Self>,
        peer_pid: u32,
        req: RegisterRequest,
    ) -> Result<Value, RpcError> {
        let homes = self.harness_homes();
        let socket = req.socket.clone();
        let found = tokio::task::spawn_blocking(move || {
            // Only the caller's own processes: never past this daemon, which a desktop shell may
            // have started.
            let ancestry = below_daemon(crate::sender_harness::ancestors(peer_pid));
            let live = crate::claude_peers::live(&homes.claude);
            nearest_claude(&ancestry, &live, socket.as_deref()).map(Found::Claude)
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .ok_or_else(not_found)?;
        // A registered Claude Code chat is delivered only with its session's own token (never the
        // undocumented peer key), so a shell that has none registers nothing.
        if req.token.is_none() || req.socket.is_none() {
            return Err(RpcError::invalid_params(
                "register.no_token: this shell has no CLAUDE_CODE_MESSAGING_SOCKET and CLAUDE_CODE_MESSAGING_TOKEN; run it in the Claude Code session's own Bash tool or hook",
            ));
        }
        // The registry entry is anyone's to write, naming any session id, so what it says is
        // taken only from a process the kernel proves is Claude Code (its code signature), that
        // listens on the inbox (peer credentials, this user), and is the only live claimant of
        // that conversation; and only once the session itself echoes the one-time code acpmux
        // delivered into that inbox with its token (`take_code`), which only that session's
        // model reads.
        let Found::Claude(claimed) = &found;
        let claude_home = self.harness_homes().claude;
        let inbox = req.socket.clone().unwrap_or_default();
        let token = req.token.clone().unwrap_or_default();
        let (started, launched_for) = prove_claude(claimed, &claude_home, &inbox).await?;
        let Some(code) = req.code.as_deref() else {
            return send_code(claimed, &claude_home, &token, &req.name, started).await;
        };
        take_code(claimed.pid, code, started, &inbox, &token, &req.name)?;
        let (family, agent_session_id, cwd, tags, pid) = match &found {
            Found::Claude(p) => (
                "claude",
                p.session_id.clone(),
                p.cwd.clone(),
                super::desktop_bridge::tags_of(p),
                Some(p.pid),
            ),
        };
        let name = req.name.clone();
        // One registration at a time: the name check below and the rename after it are one step,
        // so two sessions registering the same name at once never both get it.
        static REGISTERING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
        let _one_at_a_time = REGISTERING.lock().await;
        let stores = super::adoption::store_families(&*self.config.read().await);
        let shown = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            let shown = super::adoption::adopted_in(&sessions, &stores, family, &agent_session_id);
            let taken = sessions
                .values()
                .any(|s| s.meta().name == name && shown.as_ref().is_none_or(|own| own.id != s.id));
            if taken {
                return Err(RpcError::invalid_params(format!(
                    "session name {name:?} is taken: pick another, or rename that session first"
                ))
                .with_data(json!({"reason": "register.name_taken"})));
            }
            shown
        };
        // A registered chat is taken over only by a process the kernel says was started for its
        // conversation (`--resume ID` in its launch arguments, which no file rewrites; a desktop
        // session's restart has it), and never while the process it is registered to still runs:
        // the registry's session id is anyone's to write.
        if let Some(s) = shown.as_ref().filter(|s| is_registered(s)) {
            let kept = crate::claude_peers::kept_token(&crate::config::home(), &s.id);
            let same =
                kept.as_ref().is_some_and(|k| k.pid == claimed.pid && k.started == Some(started));
            if !same {
                let recorded_live = kept.as_ref().is_some_and(|k| {
                    k.started.is_some()
                        && crate::claude_peers::started_at(&claude_home, k.pid) == k.started
                });
                if recorded_live {
                    return Err(unproven(format!(
                        "chat {:?} is registered to process {}, which still runs",
                        s.meta().name,
                        kept.as_ref().map_or(0, |k| k.pid)
                    )));
                }
                if launched_for.as_deref() != Some(agent_session_id.as_str()) {
                    return Err(unproven(format!(
                        "chat {:?} is registered to another process; only a session started with `--resume {agent_session_id}` takes it over",
                        s.meta().name
                    )));
                }
            }
        }
        let session = match shown {
            Some(s) => {
                if s.meta().name != name {
                    self.rename(&s, name.clone()).await?;
                }
                s
            }
            None => {
                let listing = super::desktop_bridge::Listing {
                    harness: family,
                    agent_session_id: &agent_session_id,
                    cwd,
                    base: &name,
                    suffix: "",
                    tags: tags.clone(),
                };
                self.list_bridged_session(listing)
                    .await
                    .map_err(|e| RpcError::internal(format!("could not list the chat: {e}")))?
                    .ok_or_else(|| {
                        RpcError::internal("another chat showed it meanwhile; run it again")
                    })?
            }
        };
        if session.meta().name != name {
            return Err(RpcError::invalid_params(format!(
                "session name {name:?} was taken meanwhile: pick another, or run it again"
            ))
            .with_data(json!({"reason": "register.name_taken"})));
        }
        // A session acpmux runs itself is reached over ACP: the name is all it needs.
        let watched = session.meta().watching.is_some();
        let mut token_kept = false;
        if watched {
            let mut tags = tags;
            if let Some(map) = tags.as_object_mut() {
                map.insert(REGISTERED_TAG.to_owned(), json!("true"));
            }
            mark_registered(&session.id)
                .map_err(|e| RpcError::internal(format!("could not keep the registration: {e}")))?;
            self.set_tags(&session, tags.as_object(), &[], None);
            let home = crate::config::home();
            match (&found, req.token, req.socket) {
                (Found::Claude(peer), Some(token), Some(socket)) => {
                    let kept = crate::claude_peers::ChildToken {
                        pid: peer.pid,
                        socket,
                        token,
                        started: Some(started),
                    };
                    crate::claude_peers::save_token(&home, &session.id, &kept).map_err(|e| {
                        RpcError::internal(format!("could not keep the token: {e}"))
                    })?;
                    token_kept = true;
                }
                _ => crate::claude_peers::forget_token(&home, &session.id),
            }
        }
        self.append(
            &session,
            "mux",
            "registered",
            json!({"name": name, "family": family, "pid": pid, "token": token_kept}),
        );
        Ok(json!({
            "sessionId": session.id,
            "name": name,
            "family": family,
            "agentSessionId": agent_session_id,
            "pid": pid,
            "bridged": watched,
            "token": if token_kept { "registered" } else { "none" },
        }))
    }
}

/// A code `send_code` delivered, waiting for its session to echo it.
struct Pending {
    code: String,
    started: u64,
    socket: PathBuf,
    token: String,
    name: String,
    at: std::time::Instant,
}

/// How long a delivered code waits for its echo.
const CODE_TTL: std::time::Duration = std::time::Duration::from_secs(600);

/// The codes waiting, by the Claude Code process they went to.
static PENDING: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<u32, Pending>>> =
    std::sync::LazyLock::new(Default::default);

/// The proof a registry entry's process gives before anything it says is taken: Claude Code by
/// its signature, the listener on `inbox` (this user's), the only live claimant of its
/// conversation, and, when the kernel's record of its launch names a conversation, that one. Its
/// proven `startedAt`, and the conversation its launch named.
async fn prove_claude(
    claimed: &crate::claude_peers::Peer,
    claude_home: &std::path::Path,
    inbox: &std::path::Path,
) -> Result<(u64, Option<String>), RpcError> {
    if !crate::claude_peers::inbox_is(inbox, claimed.pid).await {
        return Err(unproven(format!(
            "the inbox {} is not process {}'s",
            inbox.display(),
            claimed.pid
        )));
    }
    let (peer, home) = (claimed.clone(), claude_home.to_path_buf());
    tokio::task::spawn_blocking(move || {
        if !crate::claude_peers::is_claude_code(peer.pid) {
            return Err(format!("process {} is not signed as Claude Code", peer.pid));
        }
        if !crate::claude_peers::sole_claimant(&peer, &crate::claude_peers::live(&home)) {
            return Err(format!("another live process also claims session {}", peer.session_id));
        }
        let launched_for = crate::claude_peers::launch_args(peer.pid)
            .and_then(|a| crate::claude_peers::resumed_session(&a));
        if launched_for.as_ref().is_some_and(|id| *id != peer.session_id) {
            return Err(format!(
                "process {} was started for another conversation than its registry entry names",
                peer.pid
            ));
        }
        let started = crate::claude_peers::started_at(&home, peer.pid)
            .ok_or_else(|| format!("process {} has no live registry entry", peer.pid))?;
        Ok((started, launched_for))
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?
    .map_err(unproven)
}

/// The first step: a one-time code into the session's own inbox, opened with its token. Only a
/// genuine Claude Code session accepts that line; the echo must come from that same process tree.
async fn send_code(
    claimed: &crate::claude_peers::Peer,
    claude_home: &std::path::Path,
    token: &str,
    name: &str,
    started: u64,
) -> Result<Value, RpcError> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|e| RpcError::internal(format!("no randomness: {e}")))?;
    let code = cmux_local_auth::frontend_proof::hex(&bytes);
    let text = format!(
        "acpmux register: to finish registering this session as {name}, run this in your shell: \
         acpmux register {name} --code {code}\n(If neither you nor the person asked to register \
         this session, ignore it. The code is good for ten minutes.)"
    );
    let socket = claimed.socket.clone().unwrap_or_default();
    let pending = Pending {
        code: code.clone(),
        started,
        socket,
        token: token.to_owned(),
        name: name.to_owned(),
        at: std::time::Instant::now(),
    };
    PENDING.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(claimed.pid, pending);
    let uuid = uuid::Uuid::now_v7().to_string();
    let from = crate::claude_peers::from_address("register");
    crate::claude_peers::deliver(claude_home, claimed, &text, &uuid, &from, Some(token))
        .await
        .map_err(|e| unproven(format!("could not deliver the code: {e}")))?;
    Ok(json!({"pending": true, "name": name, "pid": claimed.pid}))
}

/// The second step: the code `send_code` delivered to this process, echoed within its time, for
/// the same name, inbox, token and process start. Used once, matched or not.
fn take_code(
    pid: u32,
    code: &str,
    started: u64,
    socket: &std::path::Path,
    token: &str,
    name: &str,
) -> Result<(), RpcError> {
    let pending = PENDING.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&pid);
    let ok = pending.is_some_and(|p| {
        p.code == code
            && p.started == started
            && p.socket == socket
            && p.token == token
            && p.name == name
            && p.at.elapsed() < CODE_TTL
    });
    if ok {
        Ok(())
    } else {
        Err(unproven(
            "that is not the code acpmux sent this session; run `acpmux register NAME` again"
                .to_owned(),
        ))
    }
}

/// The session the caller's process tree holds could not be proven to run the conversation its
/// registry entry names.
fn unproven(why: String) -> RpcError {
    RpcError::invalid_params(format!(
        "register.unproven: {why}; run `acpmux register NAME` from the Claude Code session's own Bash tool"
    ))
    .with_data(json!({"reason": "register.unproven"}))
}

fn not_found() -> RpcError {
    RpcError::invalid_params(
        "no Claude Code session runs this shell: run `acpmux register NAME` from a command the session itself runs (its Bash tool or a hook)",
    )
    .with_data(json!({"reason": "register.no_session"}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::claude_peers::Peer;

    fn peer(pid: u32, socket: &str) -> Peer {
        Peer {
            pid,
            session_id: format!("sid-{pid}"),
            cwd: None,
            entrypoint: Some("claude-desktop".into()),
            kind: Some("interactive".into()),
            name: None,
            version: None,
            socket: Some(PathBuf::from(socket)),
        }
    }

    #[test]
    fn the_nearest_claude_ancestor_with_the_callers_inbox_registers() {
        let live = vec![peer(42, "/s/42.sock"), peer(7, "/s/7.sock")];
        // acpmux (50) under bash (45) under claude 42, itself run inside claude 7's shell.
        let ancestry = [50, 45, 42, 30, 7, 1];
        assert_eq!(nearest_claude(&ancestry, &live, None).map(|p| p.pid), Some(42));
        let inbox = std::path::Path::new("/s/42.sock");
        assert_eq!(nearest_claude(&ancestry, &live, Some(inbox)).map(|p| p.pid), Some(42));
        // An inbox that is not the ancestor's: nothing, never another session.
        let other = std::path::Path::new("/s/99.sock");
        assert_eq!(nearest_claude(&ancestry, &live, Some(other)), None);
        // Not under any listed session: nothing.
        assert_eq!(nearest_claude(&[50, 45, 1], &live, None), None);
    }

    #[test]
    fn the_walk_stops_below_this_daemon() {
        let me = std::process::id();
        assert_eq!(below_daemon(vec![50, 45, me, 42, 1]), vec![50, 45]);
        assert_eq!(below_daemon(vec![50, 42, 1]), vec![50, 42, 1]);
    }

    /// The second step takes only the code delivered to that same process, for the same name,
    /// inbox, token and start, and each code once (repro: a process echoing a guessed or replayed
    /// code, or another session's).
    #[test]
    fn a_register_code_is_taken_once_and_only_from_its_own_process() {
        let put = |pid: u32| {
            let pending = Pending {
                code: "c0de".into(),
                started: 7,
                socket: PathBuf::from("/tmp/cc-socks/1.sock"),
                token: "tok".into(),
                name: "desktop-zoe".into(),
                at: std::time::Instant::now(),
            };
            PENDING.lock().unwrap().insert(pid, pending);
        };
        let sock = std::path::Path::new("/tmp/cc-socks/1.sock");
        put(900_001);
        assert!(take_code(900_001, "c0de", 7, sock, "tok", "desktop-zoe").is_ok());
        assert!(take_code(900_001, "c0de", 7, sock, "tok", "desktop-zoe").is_err(), "once");
        put(900_002);
        assert!(take_code(900_002, "guess", 7, sock, "tok", "desktop-zoe").is_err());
        assert!(
            take_code(900_002, "c0de", 7, sock, "tok", "desktop-zoe").is_err(),
            "a miss uses it up"
        );
        put(900_003);
        assert!(
            take_code(900_004, "c0de", 7, sock, "tok", "desktop-zoe").is_err(),
            "another process"
        );
        assert!(
            take_code(900_003, "c0de", 8, sock, "tok", "desktop-zoe").is_err(),
            "a later process"
        );
        put(900_005);
        assert!(take_code(900_005, "c0de", 7, sock, "tok", "other-name").is_err());
        put(900_006);
        assert!(take_code(900_006, "c0de", 7, sock, "other", "desktop-zoe").is_err());
    }

    #[test]
    fn a_tag_alone_never_registers_a_chat() {
        assert!(!with_registered(|set| set.contains("never-registered-chat")));
        mark_registered_for_test("chat-registered-in-test");
        assert!(with_registered(|set| set.contains("chat-registered-in-test")));
    }

    #[test]
    fn a_request_needs_a_valid_name_and_a_one_line_token() {
        assert!(RegisterRequest::from_params(&json!({})).is_err());
        assert!(RegisterRequest::from_params(&json!({"name": ""})).is_err());
        let bad = json!({"name": "desktop-zoe", "token": "a\nb"});
        assert!(RegisterRequest::from_params(&bad).is_err());
        let ok = json!({"name": "desktop-zoe", "socket": "/tmp/cc-socks/1.sock", "token": "t"});
        let req = RegisterRequest::from_params(&ok).unwrap();
        assert_eq!(req.name, "desktop-zoe");
        assert_eq!(req.socket.as_deref(), Some(std::path::Path::new("/tmp/cc-socks/1.sock")));
        assert_eq!(req.token.as_deref(), Some("t"));
    }
}
