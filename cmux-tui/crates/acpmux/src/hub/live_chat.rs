//! A watched Claude Code chat whose conversation runs again is never left `closed`.
//!
//! Leo, 2026-11-22: "you can talk to the central coordinators (interim-coord, claude-sr2-coord,
//! claude-sr2-coord-old) to know what to do. if you can't reliably communicate back and forth from
//! the desktop app, that's a product thing we need to fix." Measured on his Mac that morning:
//! `interim-coord` (a registered `claude --resume 6e0bad7d-...` terminal chat) listed as `closed`
//! in `acpmux ls` for 35 hours while its process (79117) ran, its transcript grew every few
//! seconds, and acpmux delivered into it (`bridge_delivered`, pid 79117). The chat was closed when
//! its previous process ended (Nov 20 22:50Z); the process that resumed the conversation a day
//! later re-registered (`register.rs`), but nothing reopened the chat, and a closed chat's watch
//! (`watch.rs` `start_watch`) stops following the transcript. So the row said closed, `ls --live`
//! and every tool that read it (ask-coords, `cmux agent list`) took the coordinator for gone, and
//! a delivery into it waited its full answer window for a turn the stopped watch never showed.
//!
//! A closed watched chat reopens (`reopened`, then `revived` in its log, and its watch starts
//! again from where it stopped) when its conversation is proven live:
//! - its registration goes to a live process (`register.rs`);
//! - acpmux just delivered a prompt into its live app (`bridge.rs`);
//! - the desktop bridge's scan (`desktop_bridge.rs`) finds a live Claude Code process running its
//!   conversation and its transcript has grown past what the watch read before it stopped. The
//!   growth is the condition, not the process alone: a chat someone stopped while its app sat
//!   idle stays stopped until the conversation goes on.
//!
//! Nothing here delivers anything or proves an address: reopening only shows the transcript the
//! watch already had, so it needs no proof beyond the registry entry and the transcript itself.

use super::{Hub, Session};
use crate::claude_peers::Peer;
use crate::store::SessionStatus;
use serde_json::json;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// How many desktop bridge scans (`desktop_bridge.rs` `SCAN`, 2 s) pass between checks of the
/// closed chats whose conversation a live process runs, when the registry folder did not change:
/// a chat that resumed quietly and only later wrote its transcript reopens within this.
pub(super) const REVIVE_EVERY_SCANS: u32 = 8;

/// Whether a watched chat that is `closed`, whose watch read its transcript to `offset` and whose
/// transcript is now `len` bytes long, reopens while a live process runs its conversation: its
/// conversation went on past what the watch showed.
pub(super) fn revivable(closed: bool, offset: u64, len: Option<u64>) -> bool {
    closed && len.is_some_and(|len| len > offset)
}

/// A closed watched chat whose conversation a live process runs.
struct Candidate {
    session: Arc<Session>,
    /// Its transcript, and how far its watch read it.
    file: std::path::PathBuf,
    offset: u64,
    pid: u32,
    /// Its conversation (the agent session id).
    id: String,
    updated: u64,
}

impl Hub {
    /// Reopens closed watched chat `session` because its conversation runs in process `pid`
    /// (`why`: `registered`, `delivered`, `scan`), and starts its watch again. False when it was
    /// not closed, is being deleted, moved away or is not a watch.
    pub(super) fn revive_live_chat(
        self: &Arc<Self>,
        session: &Arc<Session>,
        pid: Option<u32>,
        why: &str,
    ) -> bool {
        if session.status() != SessionStatus::Closed
            || session.purged.load(Ordering::SeqCst)
            || session.purging.load(Ordering::SeqCst)
        {
            return false;
        }
        let (watched, moved) = session.read_meta(|m| (m.watching.is_some(), m.moved_to.is_some()));
        if !watched || moved {
            return false;
        }
        let stops = session.stops.load(Ordering::SeqCst);
        if !self.reopen(session, stops) {
            return false;
        }
        self.append(session, "mux", "revived", json!({"pid": pid, "why": why}));
        tracing::info!(
            "live chat: {} ({}) reopened: its conversation runs in process {pid:?} ({why})",
            session.read_meta(|m| m.name.clone()),
            session.id
        );
        self.start_watch(session);
        true
    }

    /// Reopens each closed watched Claude Code chat whose conversation one of `live` runs and
    /// whose transcript grew past its watch ([`revivable`]). Cheap when nothing is closed and
    /// live: one pass over the chats in memory, then one `stat` per candidate.
    pub(super) fn revive_live_chats(self: &Arc<Self>, live: &[Peer]) -> usize {
        if live.is_empty() {
            return 0;
        }
        let by_conversation: HashMap<&str, &Peer> =
            live.iter().map(|p| (p.session_id.as_str(), p)).collect();
        let mut candidates: Vec<Candidate> = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            // A conversation another open chat already shows is not shown twice.
            let open: std::collections::HashSet<String> = sessions
                .values()
                .filter_map(|s| {
                    s.read_meta(|m| {
                        (m.status != SessionStatus::Closed)
                            .then(|| m.agent_session_id.clone())
                            .flatten()
                    })
                })
                .collect();
            sessions
                .values()
                .filter_map(|s| {
                    let (file, offset, pid, id, updated) = s.read_meta(|m| {
                        if m.status != SessionStatus::Closed
                            || m.agent_session_id.as_ref().is_some_and(|id| open.contains(id))
                        {
                            return None;
                        }
                        let w = m.watching.as_ref().filter(|w| w.family == "claude")?;
                        let id = m.agent_session_id.clone()?;
                        let peer = by_conversation.get(id.as_str())?;
                        Some((w.file.clone(), w.offset, peer.pid, id, m.updated_at))
                    })?;
                    Some(Candidate { session: s.clone(), file, offset, pid, id, updated })
                })
                .collect()
        };
        // One chat per conversation: the registered one, else the newest.
        candidates.sort_by_key(|c| {
            (
                std::cmp::Reverse(super::register::is_registered(&c.session)),
                std::cmp::Reverse(c.updated),
            )
        });
        let mut shown = std::collections::HashSet::new();
        let mut revived = 0;
        for c in candidates {
            if shown.contains(&c.id) {
                continue;
            }
            let len = std::fs::metadata(&c.file).ok().map(|m| m.len());
            if revivable(true, c.offset, len)
                && self.revive_live_chat(&c.session, Some(c.pid), "scan")
            {
                shown.insert(c.id);
                revived += 1;
            }
        }
        revived
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, StoreMode};
    use crate::store::{MemoryStore, Watching};
    use std::path::PathBuf;

    #[test]
    fn a_closed_chat_reopens_only_when_its_transcript_went_on() {
        assert!(revivable(true, 100, Some(101)), "it grew");
        assert!(!revivable(true, 100, Some(100)), "nothing new: a stop stays");
        assert!(!revivable(true, 100, None), "no transcript");
        assert!(!revivable(false, 0, Some(10)), "not closed");
    }

    fn hub() -> Arc<Hub> {
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        Hub::new(cfg, Box::new(MemoryStore::default()))
    }

    fn peer(pid: u32, session_id: &str) -> Peer {
        Peer {
            pid,
            session_id: session_id.into(),
            cwd: None,
            entrypoint: Some("cli".into()),
            kind: Some("interactive".into()),
            name: None,
            version: None,
            socket: Some(PathBuf::from(format!("/tmp/cc-socks/{pid}.sock"))),
        }
    }

    /// Repro (2026-11-22): interim-coord, closed when its old process ended, stayed
    /// `closed` while `claude --resume` ran it again (pid 79117) and its transcript grew. The scan
    /// now reopens it; a stopped chat whose transcript did not move, or whose conversation no
    /// live process runs, stays closed.
    #[tokio::test]
    async fn a_closed_chat_whose_conversation_runs_again_reopens() {
        let dir = std::env::temp_dir().join(format!("acpmux-live-chat-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let hub = hub();
        let chat = |name: &str, sid: &str, file: &PathBuf, offset: u64| {
            let hub = hub.clone();
            let (name, sid, file) = (name.to_owned(), sid.to_owned(), file.clone());
            async move {
                let req = crate::hub::NewRequest { cwd: Some(dir_of(&file)), ..Default::default() };
                let s = hub.new_session(req).await.unwrap();
                {
                    let mut m = s.meta.lock().unwrap();
                    m.name = name;
                    m.agent_session_id = Some(sid);
                    m.watching = Some(Watching {
                        family: "claude".into(),
                        file,
                        offset,
                        codex_items: false,
                        open: None,
                    });
                }
                hub.set_status(&s, SessionStatus::Closed);
                assert_eq!(s.status(), SessionStatus::Closed);
                s
            }
        };
        fn dir_of(file: &std::path::Path) -> PathBuf {
            file.parent().unwrap().to_path_buf()
        }
        let grown = dir.join("grown.jsonl");
        std::fs::write(&grown, b"{}\n{}\n").unwrap();
        let still = dir.join("still.jsonl");
        std::fs::write(&still, b"{}\n").unwrap();
        let coord = chat("interim-coord", "6e0bad7d", &grown, 3).await;
        let stopped = chat("stopped-chat", "aaaa", &still, 3).await;
        let gone = chat("gone-chat", "bbbb", &grown, 0).await;

        let live = [peer(79117, "6e0bad7d"), peer(42, "aaaa")];
        assert_eq!(hub.revive_live_chats(&live), 1);
        assert_ne!(coord.status(), SessionStatus::Closed, "its conversation went on");
        assert_eq!(stopped.status(), SessionStatus::Closed, "nothing new since its stop");
        assert_eq!(gone.status(), SessionStatus::Closed, "no live process runs it");
        assert_eq!(hub.revive_live_chats(&live), 0, "once");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
