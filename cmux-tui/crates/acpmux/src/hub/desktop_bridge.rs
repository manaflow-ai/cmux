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
            let shown =
                super::adoption::adopted_in(&sessions, &stores, "claude", &peer.session_id).is_some();
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
    fn provenance_tags_come_from_the_registry_entry() {
        assert_eq!(
            tags_of(&peer(None)),
            json!({"bridge": "claude", "origin": "claude-desktop", "origin.pid": "42", "origin.version": "2.1.310"})
        );
    }
}
