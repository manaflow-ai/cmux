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

/// Whether `session` is a chat its own session registered: the daemon's record, and its tag.
pub(super) fn is_registered(session: &Session) -> bool {
    session.meta().tags.get(REGISTERED_TAG).is_some_and(|t| t.value == "true")
        && with_registered(|set| set.contains(&session.id))
}

/// What `acpmux register` sends (`_acpmux/register`).
#[derive(Debug, Default)]
pub struct RegisterRequest {
    pub name: String,
    /// `CLAUDE_CODE_MESSAGING_SOCKET` in the caller's environment.
    pub socket: Option<PathBuf>,
    /// `CLAUDE_CODE_MESSAGING_TOKEN` in the caller's environment.
    pub token: Option<String>,
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
        Ok(Self { name: name.to_owned(), socket: text("socket").map(PathBuf::from), token })
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
        // The registry entry is anyone's to write, naming any session id: the process must also
        // be the one listening on its inbox, run by this user, the only live claimant of that
        // conversation, and the writer of its transcript since it started.
        let Found::Claude(claimed) = &found;
        let claude_home = self.harness_homes().claude;
        let inbox = req.socket.clone().unwrap_or_default();
        if !crate::claude_peers::inbox_is(&inbox, claimed.pid).await {
            return Err(unproven(format!(
                "the inbox {} is not process {}'s",
                inbox.display(),
                claimed.pid
            )));
        }
        let (peer, home) = (claimed.clone(), claude_home.clone());
        tokio::task::spawn_blocking(move || {
            let live = crate::claude_peers::live(&home);
            crate::claude_peers::proves_conversation(&home, &peer, &live)
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(unproven)?;
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
                    let started = crate::claude_peers::started_at(&claude_home, peer.pid);
                    let kept =
                        crate::claude_peers::ChildToken { pid: peer.pid, socket, token, started };
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

/// The session the caller's process tree holds could not be proven to run the conversation its
/// registry entry names.
fn unproven(why: String) -> RpcError {
    RpcError::invalid_params(format!(
        "register.unproven: {why}; run `acpmux register NAME` from the session's own Bash tool after its first turn"
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
