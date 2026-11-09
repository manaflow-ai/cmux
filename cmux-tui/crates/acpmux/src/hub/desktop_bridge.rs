//! Claude desktop sessions listed as chats (`claude_peers.rs`): with
//! `agents.desktopBridge.enabled`, each live Claude Code session the registry lists with an
//! entrypoint of `agents.desktopBridge.entrypoints` (the desktop app's, `claude-desktop`, by
//! default) gets a watched chat (`watch.rs`), so it shows in `acpmux ls` and the cmux sidebar and
//! takes prompts (`bridge.rs`).
//!
//! The chat's provenance comes from the registry entry the session wrote itself: tags
//! `bridge=claude` (what clients read: replies go to the app), `origin=<entrypoint>`, `origin.pid`, `origin.version`; it is created as a script's, never as
//! the person's or an agent's. A session already shown by a chat (watched, adopted, or this
//! daemon's own harness) gets none.
//!
//! The loop reads the registry folder only when its modification time changed, and of it only
//! the `<pid>.json` entries whose pid runs, so its cost follows the live sessions, not the
//! thousands of stale entries a busy machine keeps. While the setting is off it only rereads the
//! setting. It ends when the daemon shuts down.

use super::Hub;
use crate::claude_peers::Peer;
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
        loop {
            let Some(h) = hub.upgrade() else { return };
            if h.shutting_down() {
                return;
            }
            let on =
                tokio::task::spawn_blocking(crate::claude_peers::enabled).await.unwrap_or(false);
            if !on || !h.startup_settled() {
                seen = None;
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
                // again at the registry's next change, which its first turn makes.
                for peer in peers {
                    if let Err(e) = h.list_desktop_session(&peer).await {
                        tracing::debug!(
                            "desktop bridge: Claude session {} not listed yet: {e}",
                            peer.session_id
                        );
                    }
                }
            }
            drop(h);
            tokio::time::sleep(SCAN).await;
        }
    }

    /// A watched chat for `peer`, unless a chat already shows its conversation.
    async fn list_desktop_session(self: &Arc<Self>, peer: &Peer) -> Result<(), String> {
        let stores = super::adoption::store_families(&*self.config.read().await);
        let (shown, name) = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            let shown = super::adoption::adopted_in(&sessions, &stores, "claude", &peer.session_id)
                .is_some();
            let taken = |n: &str| sessions.values().any(|s| s.meta().name == n);
            (shown, unique_name(peer, taken))
        };
        if shown {
            return Ok(());
        }
        let req = super::NewRequest {
            harness: Some("claude".to_owned()),
            name: Some(name),
            cwd: peer.cwd.clone(),
            adopt: Some(crate::adopt::AdoptRequest {
                harness: Some("claude".to_owned()),
                agent_session_id: peer.session_id.clone(),
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
        let tags = tags_of(peer);
        self.set_tags(&session, tags.as_object(), &[], None);
        Ok(())
    }
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
        let chats: Vec<(String, String)> = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            sessions
                .values()
                .filter_map(|s| {
                    let meta = s.meta();
                    meta.watching.as_ref().filter(|w| w.family == "claude")?;
                    meta.tags.get("bridge").filter(|t| t.value == "claude")?;
                    Some((s.id.clone(), meta.agent_session_id?))
                })
                .collect()
        };
        if chats.is_empty() {
            return;
        }
        let config = self.harness_homes.lock().unwrap_or_else(|e| e.into_inner()).claude.clone();
        let found = tokio::task::spawn_blocking(move || {
            if !crate::claude_peers::enabled() {
                return None;
            }
            let ancestry = crate::sender_harness::ancestors(pid);
            let listed = crate::claude_peers::listed_entrypoints();
            let live = crate::claude_peers::live(&config);
            bound_chat(&ancestry, &chats, &live, &listed)
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
/// a pid in `ancestry` and an entrypoint in `listed`.
fn bound_chat(
    ancestry: &[u32],
    chats: &[(String, String)],
    live: &[Peer],
    listed: &[String],
) -> Option<String> {
    let peer = live.iter().find(|p| {
        ancestry.contains(&p.pid) && p.entrypoint.as_ref().is_some_and(|e| listed.contains(e))
    })?;
    chats.iter().find(|(_, sid)| *sid == peer.session_id).map(|(id, _)| id.clone())
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

/// [`name_of`], with the app's pid after it when another chat has that name already (two
/// desktop sessions in one folder, or a chat named like the session), and a count after that
/// while that is taken too, so each is addressed alone.
fn unique_name(peer: &Peer, taken: impl Fn(&str) -> bool) -> String {
    let name = name_of(peer);
    if !taken(&name) {
        return name;
    }
    let with_pid = format!("{name} ({})", peer.pid);
    (1..)
        .map(|n| if n == 1 { with_pid.clone() } else { format!("{with_pid} {n}") })
        .find(|n| !taken(n))
        .unwrap_or(with_pid)
}

/// Provenance tags, from the registry entry the session wrote.
fn tags_of(peer: &Peer) -> Value {
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
        assert_eq!(unique_name(&peer(None), |_| false), "desktop cmux");
        assert_eq!(unique_name(&peer(None), |n| n == "desktop cmux"), "desktop cmux (42)");
        let both = |n: &str| n == "desktop cmux" || n == "desktop cmux (42)";
        assert_eq!(unique_name(&peer(None), both), "desktop cmux (42) 2");
    }

    #[test]
    fn a_send_is_bound_only_to_the_chat_whose_live_app_is_its_ancestor() {
        let chats = vec![("chat-1".to_owned(), "sid".to_owned())];
        let live = vec![peer(None)];
        let listed = vec!["claude-desktop".to_owned()];
        // acpmux (50) under bash (45) under the desktop session's claude (42).
        assert_eq!(bound_chat(&[50, 45, 42, 1], &chats, &live, &listed).as_deref(), Some("chat-1"));
        // Another process tree: nothing.
        assert_eq!(bound_chat(&[50, 45, 7], &chats, &live, &listed), None);
        // An entrypoint the setting does not list: nothing.
        assert_eq!(bound_chat(&[50, 42], &chats, &live, &["cli".to_owned()]), None);
        // A live app with no chat the bridge made: nothing.
        let other = vec![("chat-2".to_owned(), "other".to_owned())];
        assert_eq!(bound_chat(&[50, 42], &other, &live, &listed), None);
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
