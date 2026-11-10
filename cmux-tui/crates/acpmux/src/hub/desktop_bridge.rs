//! Claude desktop sessions and Codex desktop threads listed as chats (`claude_peers.rs`,
//! `codex_desktop.rs`): with `agents.desktopBridge.enabled`, each live Claude Code session the
//! registry lists with an entrypoint of `agents.desktopBridge.entrypoints` (the desktop app's,
//! `claude-desktop`, by default), and each live Codex thread whose originator that list names
//! (`codex_desktop`, the Codex desktop app's, when listed), gets a watched chat (`watch.rs`), so
//! it shows in `acpmux ls` and the cmux sidebar and takes prompts (`bridge.rs`). A Claude desktop
//! chat and a Codex desktop chat so reach each other: each one's `acpmux send` to the other is
//! bound to its own bridged chat ([`Hub::stamp_bridged_sender`]) and delivered into the other app.
//!
//! The chat's provenance comes from the registry entry the session wrote itself: tags
//! `bridge=claude` (what clients read: replies go to the app), `origin=<entrypoint>`, `origin.pid`, `origin.version`; it is created as a script's, never as
//! the person's or an agent's. A Codex thread's come from its row in Codex's state database:
//! `bridge=codex`, `origin=<originator>`, `origin.version`. A session already shown by a chat (watched, adopted, or this
//! daemon's own harness) gets none.
//!
//! The loop reads the registry folder only when its modification time changed, and of it only
//! the `<pid>.json` entries whose pid runs, so its cost follows the live sessions, not the
//! thousands of stale entries a busy machine keeps; a session it could not list yet (no
//! transcript before its first turn) makes the next scan read the folder again. Codex's writer-lock folder is read the same
//! way: only when it changed (a thread opened or closed), and of it only the held locks; a thread
//! with no rollout yet is tried again at each scan until it is listed. While the setting is off it
//! only rereads the setting. It ends when the daemon shuts down.

use super::Hub;
use crate::claude_peers::Peer;
use crate::codex_desktop::Thread;
use serde_json::{Value, json};
use std::sync::{Arc, Weak};
use std::time::{Duration, SystemTime};

/// How often the registry folder's modification time is checked while the bridge is on.
const SCAN: Duration = Duration::from_secs(2);
/// How often the setting is reread while the bridge is off.
const OFF: Duration = Duration::from_secs(15);

impl Hub {
    /// Lists live desktop sessions as watched chats until the daemon shuts down.
    pub async fn desktop_bridge_loop(hub: Weak<Hub>) {
        let mut seen: Option<SystemTime> = None;
        let mut codex_seen: Option<SystemTime> = None;
        loop {
            let Some(h) = hub.upgrade() else { return };
            if h.shutting_down() {
                return;
            }
            let on =
                tokio::task::spawn_blocking(crate::claude_peers::enabled).await.unwrap_or(false);
            if !on || !h.startup_settled() {
                seen = None;
                codex_seen = None;
                drop(h);
                tokio::time::sleep(if on { SCAN } else { OFF }).await;
                continue;
            }
            let config = h.harness_homes.lock().unwrap_or_else(|e| e.into_inner()).claude.clone();
            let registry = crate::claude_peers::registry(&config);
            let modified = std::fs::metadata(&registry).and_then(|m| m.modified()).ok();
            if modified.is_none() || modified != seen {
                seen = modified;
                let peers = tokio::task::spawn_blocking(move || {
                    let listed = crate::claude_peers::listed_entrypoints();
                    crate::claude_peers::live(&config)
                        .into_iter()
                        .filter(|p| p.entrypoint.as_ref().is_some_and(|e| listed.contains(e)))
                        .collect::<Vec<_>>()
                })
                .await
                .unwrap_or_default();
                // A session with no transcript yet (no turn so far) is not found: it is tried
                // again at the next scan. Its first turn rewrites its entry in place, which leaves
                // the folder's modification time as it was (seen in the Codex rehearsal).
                for peer in peers {
                    if let Err(e) = h.list_desktop_session(&peer).await {
                        seen = None;
                        tracing::debug!(
                            "desktop bridge: Claude session {} not listed yet: {e}",
                            peer.session_id
                        );
                    }
                }
            }
            h.scan_codex_desktop(&mut codex_seen).await;
            drop(h);
            tokio::time::sleep(SCAN).await;
        }
    }

    /// Lists the live Codex desktop threads, when the lock folder changed since `seen`. A thread
    /// that could not be listed yet (no rollout before its first turn) leaves `seen` unset, so
    /// the next scan tries again.
    async fn scan_codex_desktop(self: &Arc<Self>, seen: &mut Option<SystemTime>) {
        let home = self.harness_homes.lock().unwrap_or_else(|e| e.into_inner()).codex.clone();
        let locks = crate::codex_desktop::lock_dir(&home);
        let modified = std::fs::metadata(&locks).and_then(|m| m.modified()).ok();
        if modified.is_some() && modified == *seen {
            return;
        }
        *seen = modified;
        let (listed, threads) = tokio::task::spawn_blocking(move || {
            let listed = crate::claude_peers::listed_entrypoints();
            let threads = crate::codex_desktop::live(&home, &listed);
            (listed.iter().any(|l| l == crate::codex_desktop::DESKTOP_ORIGINATOR), threads)
        })
        .await
        .unwrap_or_default();
        // Not listed: the setting is read again at the next scan, so listing it takes effect.
        if !listed {
            *seen = None;
        }
        for thread in threads {
            if let Err(e) = self.list_codex_thread(&thread).await {
                *seen = None;
                tracing::debug!("desktop bridge: Codex thread {} not listed yet: {e}", thread.id);
            }
        }
    }

    /// A watched chat for Codex `thread`, unless a chat already shows its conversation.
    async fn list_codex_thread(self: &Arc<Self>, thread: &Thread) -> Result<(), String> {
        let base = codex_name_of(thread);
        let suffix = thread.id.chars().take(8).collect::<String>();
        let listing = Listing {
            harness: "codex",
            agent_session_id: &thread.id,
            cwd: thread.cwd.clone(),
            base: &base,
            suffix: &suffix,
            tags: codex_tags_of(thread),
        };
        self.list_bridged(listing).await
    }

    /// A watched chat for `peer`, unless a chat already shows its conversation.
    async fn list_desktop_session(self: &Arc<Self>, peer: &Peer) -> Result<(), String> {
        let (base, suffix) = (name_of(peer), peer.pid.to_string());
        let listing = Listing {
            harness: "claude",
            agent_session_id: &peer.session_id,
            cwd: peer.cwd.clone(),
            base: &base,
            suffix: &suffix,
            tags: tags_of(peer),
        };
        self.list_bridged(listing).await
    }

    /// A watched chat for `listing`'s conversation, created as a script's, unless a chat (watched,
    /// adopted, or this daemon's own harness) already shows it.
    async fn list_bridged(self: &Arc<Self>, listing: Listing<'_>) -> Result<(), String> {
        self.list_bridged_session(listing).await.map(drop)
    }

    /// [`Self::list_bridged`], answering with the chat it made (`None`: a chat shows it already).
    pub(super) async fn list_bridged_session(
        self: &Arc<Self>,
        listing: Listing<'_>,
    ) -> Result<Option<Arc<super::Session>>, String> {
        let stores = super::adoption::store_families(&*self.config.read().await);
        let (shown, name) = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            let shown = super::adoption::adopted_in(
                &sessions,
                &stores,
                listing.harness,
                listing.agent_session_id,
            )
            .is_some();
            let taken = |n: &str| sessions.values().any(|s| s.meta().name == n);
            (shown, unique_name(listing.base, listing.suffix, taken))
        };
        if shown {
            return Ok(None);
        }
        let req = super::NewRequest {
            harness: Some(listing.harness.to_owned()),
            name: Some(name),
            cwd: listing.cwd,
            adopt: Some(crate::adopt::AdoptRequest {
                harness: Some(listing.harness.to_owned()),
                agent_session_id: listing.agent_session_id.to_owned(),
                if_live: crate::adopt::IfLive::Refuse,
                cwd_map: Vec::new(),
                watch: true,
            }),
            created_by: Some(crate::store::CreatedBy {
                kind: crate::store::CreatorKind::Script,
                workspace: None,
                session: None,
            }),
            ..Default::default()
        };
        let session = self.new_session(req).await.map_err(|e| e.message)?;
        self.set_tags(&session, listing.tags.as_object(), &[], None);
        Ok(Some(session))
    }
}

/// One conversation the bridge lists as a watched chat.
pub(super) struct Listing<'a> {
    pub(super) harness: &'static str,
    pub(super) agent_session_id: &'a str,
    pub(super) cwd: Option<std::path::PathBuf>,
    /// Its name, and what follows it when another chat has that name.
    pub(super) base: &'a str,
    pub(super) suffix: &'a str,
    pub(super) tags: Value,
}

/// Where the daemon carries the bridged chat a send came from (`_meta.acpmux`), from the request
/// path through the outbox to the prompt's provenance (`server/requests.rs`). Never taken from a
/// client: [`Hub::stamp_bridged_sender`] drops one any connection but the outbox sent.
pub const BRIDGED_KEY: &str = "bridgedSender";

/// The bridged chat a prompt's params name ([`BRIDGED_KEY`]), as the daemon stamped it.
pub fn bridged_sender(params: &Value) -> Option<&str> {
    params.pointer("/_meta/acpmux")?.get(BRIDGED_KEY)?.as_str()
}

impl Hub {
    /// A desktop chat's own send, bound to its bridged chat: `acpmux send` run from a Claude
    /// desktop session's shell proves no acpmux session (it has no caller token), so it would
    /// read as a self-declared, unauthenticated label nothing can answer. When the unix socket
    /// peer's ancestry (the kernel's pids, `sender_harness::ancestors`) holds the live Claude
    /// Code process the registry lists for a chat the bridge made (tag `bridge=claude`, its
    /// session id, an entrypoint the setting lists), the send is that chat's: its inbox thread
    /// names the chat, and `inbox_reply` or `acpmux send` to it goes back into the app
    /// (`bridge.rs`). The registry and the tag alone prove nothing; only the pid the kernel
    /// reports for the connection does, as for the caller token's process tree.
    ///
    /// A Codex desktop thread's shell is bound the same way to the chat the bridge made for the
    /// thread (tag `bridge=codex`): the ancestry holds a process the thread's Codex started for
    /// it, by the environment Codex gave it (`codex_desktop::thread_in`), and the thread is live
    /// with an originator the setting lists. One Codex runs many threads, so its pid alone would
    /// name none of them.
    ///
    /// `peer_pid` is the connection's (`sender_harness::check_trust`); `outbox` is the daemon's
    /// own outbox delivering a send it bound on arrival, the one connection whose stamp is kept.
    /// Nothing is read while the bridge is off or lists no chat.
    pub(crate) async fn stamp_bridged_sender(
        &self,
        prompt: &mut Value,
        peer_pid: Option<u32>,
        outbox: bool,
        proven_caller: bool,
    ) {
        let Some(mux) = prompt.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) else {
            return;
        };
        if !outbox {
            mux.remove(BRIDGED_KEY);
        }
        let Some(pid) = peer_pid.filter(|_| !proven_caller) else { return };
        let mut registered: Vec<String> = Vec::new();
        let (claude, codex): (Vec<(String, String)>, Vec<(String, String)>) = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            let chats = sessions.values().filter_map(|s| {
                let meta = s.meta();
                let family = meta.watching.as_ref()?.family.clone();
                meta.tags.get("bridge").filter(|t| t.value == family)?;
                if super::register::is_registered(s) {
                    registered.push(s.id.clone());
                }
                Some((family, (s.id.clone(), meta.agent_session_id?)))
            });
            let (claude, codex): (Vec<_>, Vec<_>) = chats
                .filter(|(family, _)| family == "claude" || family == "codex")
                .partition(|(family, _)| family == "claude");
            let chats = |all: Vec<(String, (String, String))>| all.into_iter().map(|(_, c)| c);
            (chats(claude).collect(), chats(codex).collect())
        };
        if claude.is_empty() && codex.is_empty() {
            return;
        }
        let homes = self.harness_homes.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let found = tokio::task::spawn_blocking(move || {
            // A registered chat (`register.rs`) is bound whatever the setting says; with the
            // setting off, only registered chats are.
            let on = crate::claude_peers::enabled();
            let (claude, codex): (Vec<_>, Vec<_>) = if on {
                (claude, codex)
            } else {
                let mine = |c: &(String, String)| registered.contains(&c.0);
                (
                    claude.into_iter().filter(mine).collect(),
                    codex.into_iter().filter(mine).collect(),
                )
            };
            if claude.is_empty() && codex.is_empty() {
                return None;
            }
            let ancestry = crate::sender_harness::ancestors(pid);
            let listed = crate::claude_peers::listed_entrypoints();
            if !claude.is_empty() {
                let live = crate::claude_peers::live(&homes.claude);
                // A registered chat binds only the process its registration recorded (pid,
                // inbox, start: `claude_peers::token_for`), when it is its conversation's only
                // live claimant; any entry may name a registered chat's session id.
                let acpmux_home = crate::config::home();
                let registered_by = |id: &str, peer: &Peer| {
                    registered.iter().any(|r| r == id)
                        && crate::claude_peers::sole_claimant(peer, &live)
                        && crate::claude_peers::token_for(
                            &acpmux_home,
                            id,
                            peer,
                            crate::claude_peers::started_at(&homes.claude, peer.pid),
                        )
                        .is_some()
                };
                if let Some(id) =
                    bound_chat(&ancestry, &claude, &live, &listed, &registered, registered_by)
                {
                    return Some(id);
                }
            }
            if codex.is_empty() {
                return None;
            }
            let thread = crate::codex_desktop::sender_thread(&ancestry)?;
            let (id, _) = codex.iter().find(|(_, sid)| *sid == thread)?;
            crate::codex_desktop::find(&homes.codex, &thread, &listed).map(|_| id.clone())
        })
        .await
        .ok()
        .flatten();
        if let (Some(id), Some(mux)) =
            (found, prompt.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut))
        {
            mux.insert(BRIDGED_KEY.into(), json!(id));
        }
    }
}

/// The chat (of `chats`, `(chat id, Claude session id)`) whose live registry entry (`live`) has
/// a pid in `ancestry` and an entrypoint in `listed`; a chat of `registered` only by the process
/// its registration recorded (`registered_by`, `register.rs`), whatever the entrypoint. The nearest
/// ancestor wins: a Claude Code run inside another's shell is its own sender.
fn bound_chat(
    ancestry: &[u32],
    chats: &[(String, String)],
    live: &[Peer],
    listed: &[String],
    registered: &[String],
    registered_by: impl Fn(&str, &Peer) -> bool,
) -> Option<String> {
    ancestry.iter().find_map(|pid| {
        let peer = live.iter().find(|p| p.pid == *pid)?;
        let (id, _) = chats.iter().find(|(_, sid)| *sid == peer.session_id)?;
        // A registered chat binds only the process its registration recorded: an entrypoint the
        // setting lists is anyone's to write, so it never stands in for that proof.
        let bound = if registered.iter().any(|r| r == id) {
            registered_by(id, peer)
        } else {
            peer.entrypoint.as_ref().is_some_and(|e| listed.contains(e))
        };
        bound.then(|| id.clone())
    })
}

/// The chat's name: the session's own, else the app and the folder it works in.
fn name_of(peer: &Peer) -> String {
    if let Some(name) = peer.name.as_deref().filter(|n| !n.trim().is_empty()) {
        return name.to_owned();
    }
    let folder = peer
        .cwd
        .as_deref()
        .and_then(|c| c.file_name())
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_else(|| "chat".to_owned());
    format!("desktop {folder}")
}

/// A Codex thread's chat name: the one the person gave it, else the app and its folder.
fn codex_name_of(thread: &Thread) -> String {
    if let Some(name) = thread.name.as_deref().filter(|n| !n.trim().is_empty()) {
        return name.to_owned();
    }
    let folder = thread
        .cwd
        .as_deref()
        .and_then(|c| c.file_name())
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_else(|| "chat".to_owned());
    format!("codex {folder}")
}

/// `name`, with `suffix` (the app's pid, a thread id's start) after it when another chat has
/// that name already (two desktop sessions in one folder, or a chat named like the session),
/// and a count after that while that is taken too, so each is addressed alone.
fn unique_name(name: &str, suffix: &str, taken: impl Fn(&str) -> bool) -> String {
    if !taken(name) {
        return name.to_owned();
    }
    let with_pid = format!("{name} ({suffix})");
    (1..)
        .map(|n| if n == 1 { with_pid.clone() } else { format!("{with_pid} {n}") })
        .find(|n| !taken(n))
        .unwrap_or(with_pid)
}

/// Provenance tags, from the registry entry the session wrote.
pub(super) fn tags_of(peer: &Peer) -> Value {
    let mut tags = json!({
        "bridge": "claude",
        "origin": peer.entrypoint.as_deref().unwrap_or("claude"),
        "origin.pid": peer.pid.to_string(),
    });
    if let (Some(v), Some(map)) = (peer.version.as_deref(), tags.as_object_mut()) {
        map.insert("origin.version".to_owned(), json!(v));
    }
    tags
}

/// A Codex thread's provenance tags, from the row Codex wrote.
pub(super) fn codex_tags_of(thread: &Thread) -> Value {
    let mut tags = json!({"bridge": "codex", "origin": thread.originator});
    if let (Some(v), Some(map)) = (thread.version.as_deref(), tags.as_object_mut()) {
        map.insert("origin.version".to_owned(), json!(v));
    }
    tags
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn peer(name: Option<&str>) -> Peer {
        Peer {
            pid: 42,
            session_id: "sid".into(),
            cwd: Some(PathBuf::from("/Users/leo/fun/cmux")),
            entrypoint: Some("claude-desktop".into()),
            kind: Some("interactive".into()),
            name: name.map(str::to_owned),
            version: Some("2.1.310".into()),
            socket: None,
        }
    }

    #[test]
    fn a_chat_is_named_by_the_session_else_its_folder() {
        assert_eq!(name_of(&peer(Some("fix the sidebar"))), "fix the sidebar");
        assert_eq!(name_of(&peer(None)), "desktop cmux");
        assert_eq!(name_of(&peer(Some("  "))), "desktop cmux");
    }

    #[test]
    fn a_name_another_chat_has_gets_the_pid() {
        assert_eq!(unique_name("desktop cmux", "42", |_| false), "desktop cmux");
        assert_eq!(unique_name("desktop cmux", "42", |n| n == "desktop cmux"), "desktop cmux (42)");
        let both = |n: &str| n == "desktop cmux" || n == "desktop cmux (42)";
        assert_eq!(unique_name("desktop cmux", "42", both), "desktop cmux (42) 2");
    }

    fn thread(name: Option<&str>) -> Thread {
        Thread {
            id: "01a1bf30-e092-7232-aca1-16444234c40f".into(),
            originator: "codex_desktop".into(),
            cwd: Some(PathBuf::from("/Users/leo/fun/cmux")),
            name: name.map(str::to_owned),
            title: Some("fix the sidebar".into()),
            version: Some("0.164.0".into()),
        }
    }

    #[test]
    fn a_codex_chat_is_named_by_the_thread_else_its_folder_and_tagged_from_its_row() {
        assert_eq!(codex_name_of(&thread(Some("sidebar"))), "sidebar");
        assert_eq!(codex_name_of(&thread(None)), "codex cmux");
        assert_eq!(
            codex_tags_of(&thread(None)),
            json!({"bridge": "codex", "origin": "codex_desktop", "origin.version": "0.164.0"})
        );
    }

    #[test]
    fn a_send_is_bound_only_to_the_chat_whose_live_app_is_its_ancestor() {
        let chats = vec![("chat-1".to_owned(), "sid".to_owned())];
        let live = vec![peer(None)];
        let listed = vec!["claude-desktop".to_owned()];
        let none = |_: &str, _: &Peer| false;
        // acpmux (50) under bash (45) under the desktop session's claude (42).
        assert_eq!(
            bound_chat(&[50, 45, 42, 1], &chats, &live, &listed, &[], none).as_deref(),
            Some("chat-1")
        );
        // Another process tree: nothing.
        assert_eq!(bound_chat(&[50, 45, 7], &chats, &live, &listed, &[], none), None);
        // An entrypoint the setting does not list: nothing.
        assert_eq!(bound_chat(&[50, 42], &chats, &live, &["cli".to_owned()], &[], none), None);
        // A live app with no chat the bridge made: nothing.
        let other = vec![("chat-2".to_owned(), "other".to_owned())];
        assert_eq!(bound_chat(&[50, 42], &other, &live, &listed, &[], none), None);
        // A chat its session registered is bound whatever its entrypoint, by the process its
        // registration recorded.
        let recorded = |id: &str, p: &Peer| id == "chat-1" && p.pid == 42;
        let registered = ["chat-1".to_owned()];
        assert_eq!(
            bound_chat(&[50, 42], &chats, &live, &["cli".to_owned()], &registered, recorded)
                .as_deref(),
            Some("chat-1")
        );
        // Repro: another process writes an entry naming the registered chat's session id; with
        // the setting off it is not the recorded process, so its sends are not that chat's.
        let forged = |_: &str, p: &Peer| p.pid == 99;
        assert_eq!(
            bound_chat(&[50, 42], &chats, &live, &["cli".to_owned()], &registered, forged),
            None
        );
        // Repro: the forged entry names the default listed entrypoint (claude-desktop, the one
        // `listed` holds here); a registered chat still binds only its recorded process.
        assert_eq!(bound_chat(&[50, 42], &chats, &live, &listed, &registered, forged), None);
    }

    #[test]
    fn a_bridged_sender_is_read_from_the_daemon_stamp() {
        let params = json!({"_meta": {"acpmux": {BRIDGED_KEY: "chat-1"}}});
        assert_eq!(bridged_sender(&params), Some("chat-1"));
        assert_eq!(bridged_sender(&json!({})), None);
    }

    #[test]
    fn provenance_tags_come_from_the_registry_entry() {
        assert_eq!(
            tags_of(&peer(None)),
            json!({"bridge": "claude", "origin": "claude-desktop", "origin.pid": "42", "origin.version": "2.1.310"})
        );
    }
}
