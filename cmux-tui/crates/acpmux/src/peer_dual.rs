//! Dual send: while the path the live link runs on is in doubt (no pong for more than
//! `peer_paths::DOUBT_AFTER`), the link sends each frame on that path and on the best other
//! path that answers, and the events the peer sends back on either are delivered once.
//!
//! - The other path is the probe WebSocket `peer_carriers.rs` keeps open on it. While the link
//!   is in doubt it becomes the link's shadow: it attaches every chat the link streams from the
//!   chat's cursor (`afterSeq`), and carries a copy of every request and notification the link
//!   sends from then on.
//! - Each copy carries the same `_meta.acpmux.dualId`, and a daemon that lists
//!   `server::dual_requests::FEATURE` runs a request once whichever copy came first, answering
//!   the other with the same answer (`server/dual_requests.rs`); a prompt is also kept once by
//!   the prompt ledger's `promptId`. A peer that does not list the feature gets no copies.
//! - Each reply is taken once: the first to come settles its caller, the other finds no caller.
//! - Each chat event is taken once, by its seq: either reader delivers a chat's event only past
//!   the chat's cursor, and moves the cursor as it does. The shadow delivers a chat's events
//!   only while its own stream of the chat has no gap, so the cursor never skips one.
//! - A pong on the link's path ends the doubt: the shadow detaches its chats, takes no more
//!   copies and is a plain probe again, still open. When the link's path dies instead, the link
//!   moves to the path that already answers, and its chats resume from their cursors.
//!
//! Cost: while in doubt, every frame the link sends goes out twice, and the peer streams the
//! attached chats' events twice. Nothing is copied while the link's path answers.

use super::{Peer, hidden_attach_after, page_max_seq, replayable};
use crate::no_panic::LockExt;
use crate::peer_paths::Via;
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::mpsc;

/// How often a probe checks whether the link's path is in doubt: dual send starts at most this
/// long after the doubt does, and stops at most this long after the next pong.
pub(super) const DOUBT_CHECK: Duration = Duration::from_millis(500);
/// Copies waiting to go out on the shadow; past it a copy is skipped (the link's own frame
/// still goes out).
const SHADOW_QUEUE: usize = 256;
/// How long a shadow whose link ended keeps reading answers to the copies it carried.
const ANSWER_GRACE: Duration = Duration::from_secs(5);

/// The shadow the live link copies its frames to.
pub(super) struct Shadow {
    pub via: Via,
    /// The link epoch it shadows: a later link never copies to it.
    pub link: u64,
    tx: mpsc::Sender<String>,
}

/// What dual send cost, from the peer's start: what the shadow carried and what was dropped.
#[derive(Debug, Default)]
pub struct DualStats {
    /// Times dual send started.
    pub episodes: AtomicU64,
    /// Frames copied to the shadow, and their bytes (requests, notifications, the shadow's
    /// own attaches and detaches).
    pub frames: AtomicU64,
    pub bytes: AtomicU64,
    /// Chat events read on either path and dropped as already delivered.
    pub repeats: AtomicU64,
}

impl DualStats {
    fn sent(&self, bytes: usize) {
        self.frames.fetch_add(1, Ordering::Relaxed);
        self.bytes.fetch_add(u64::try_from(bytes).unwrap_or(u64::MAX), Ordering::Relaxed);
    }
}

/// One chat on the shadow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stream {
    /// Its attach is out: the highest seq read live meanwhile.
    Attaching { attach: i64, after: u64, seen: u64 },
    /// Gapless from the cursor: its events are delivered past the cursor.
    Live,
    /// Its stream on the shadow has a gap (or the attach failed): its events are dropped.
    Off,
}

/// A probe WebSocket while it is the link's shadow.
pub(super) struct ShadowRun {
    via: Via,
    link: u64,
    pub rx: mpsc::Receiver<String>,
    streams: HashMap<String, Stream>,
    /// When its link ended: it reads answers to what it carried until [`ANSWER_GRACE`].
    orphaned_at: Option<tokio::time::Instant>,
}

/// A chat event's session and seq (`_acpmux/event` or `session/update`).
pub(super) fn event_seq(m: &str, p: &Value) -> Option<(String, u64)> {
    if !matches!(m, method::MUX_EVENT | method::SESSION_UPDATE) {
        return None;
    }
    let id = p.get("sessionId")?.as_str()?.to_owned();
    let seq = p
        .get("seq")
        .and_then(Value::as_u64)
        .or_else(|| p.pointer("/_meta/acpmux/seq").and_then(Value::as_u64))?;
    Some((id, seq))
}

/// `line` with `_meta.acpmux.dualId` set to `key` in its params, if it has object params.
pub(super) fn stamped(line: &str, key: &str) -> Option<String> {
    let mut msg: Value = serde_json::from_str(line).ok()?;
    let params = msg.get_mut("params")?.as_object_mut()?;
    let meta = params.entry("_meta").or_insert_with(|| json!({}));
    let acpmux = meta.as_object_mut()?.entry("acpmux").or_insert_with(|| json!({}));
    acpmux.as_object_mut()?.insert("dualId".to_owned(), Value::from(key));
    serde_json::to_string(&msg).ok()
}

impl Peer {
    /// Whether the peer runs a request sent on two paths once (`server/dual_requests.rs`).
    fn takes_dual(&self) -> bool {
        self.features.lock_or_recover().iter().any(|f| f == crate::server::dual_requests::FEATURE)
    }

    /// Whether the probe on `via` should be the link's shadow now: the link is connected on
    /// another path, that path is in doubt, `via` is the best other path that answers, and the
    /// peer runs a doubled request once.
    pub(super) fn dual_wanted(&self, via: Via) -> bool {
        let Some(serving) = self.serving() else { return false };
        serving != via
            && self.connected.load(Ordering::SeqCst)
            && self.takes_dual()
            && self.with_paths(|paths| paths.dual_partner(serving, crate::store::now_ms()))
                == Some(via)
    }

    /// The path that carries copies now, if any.
    pub fn dual_via(&self) -> Option<Via> {
        self.shadow.lock_or_recover().as_ref().map(|shadow| shadow.via)
    }

    /// What dual send cost so far.
    pub fn dual_stats(&self) -> &DualStats {
        &self.dual_stats
    }

    /// The probe on `via` becomes the link's shadow: copies go to it from now, and every chat
    /// with a cursor is attached on it after that cursor. Returns its state and the attach
    /// frames to send on it.
    pub(super) fn shadow_start(&self, via: Via) -> (ShadowRun, Vec<String>) {
        let link = self.link_epoch();
        let (tx, rx) = mpsc::channel(SHADOW_QUEUE);
        let mut streams = HashMap::new();
        let mut frames = Vec::new();
        {
            // Both locks, in the order `dual_claim` takes them: no event is delivered between
            // reading a chat's cursor and marking it, so the shadow's attach after that cursor
            // and the link's stream never both deliver one event.
            let mut members = self.dual_sessions.lock_or_recover();
            let cursors = self.cursors.lock_or_recover();
            for (sid, after) in replayable(&cursors) {
                let attach = self.next_id.fetch_add(1, Ordering::SeqCst);
                let line =
                    Message::request(attach, method::MUX_ATTACH, hidden_attach_after(&sid, after))
                        .to_line();
                frames.push(line.trim_end_matches('\n').to_owned());
                members.insert(sid.clone());
                streams.insert(sid, Stream::Attaching { attach, after, seen: 0 });
            }
        }
        *self.shadow.lock_or_recover() = Some(Shadow { via, link, tx });
        self.dual_stats.episodes.fetch_add(1, Ordering::Relaxed);
        for frame in &frames {
            self.dual_stats.sent(frame.len());
        }
        tracing::info!(peer = %self.name, via = via.as_str(), chats = streams.len(), "the link's path is in doubt; sending on {} too", via.as_str());
        (ShadowRun { via, link, rx, streams, orphaned_at: None }, frames)
    }

    /// The link's frame `text` (pending key `key`) on link `link`: with a shadow, stamped with
    /// its dual id and copied to the shadow. Returns the text to send on the link.
    pub(super) fn dual_copy(&self, text: String, key: Option<&str>, link: u64) -> String {
        let shadow = self.shadow.lock_or_recover();
        let Some(shadow) = shadow.as_ref().filter(|shadow| shadow.link == link) else {
            return text;
        };
        let n = self.dual_frames.fetch_add(1, Ordering::Relaxed);
        let dual_id = format!("{}:{link}:{n}", self.dual_nonce);
        // Without object params a copy could not be told from the first: it goes on the link only.
        let Some(stamped) = stamped(&text, &dual_id) else { return text };
        if shadow.tx.try_send(stamped.clone()).is_ok() {
            self.dual_stats.sent(stamped.len());
            if let Some(key) = key {
                self.dual_keys.lock_or_recover().insert(key.to_owned());
            }
        }
        stamped
    }

    /// Whether the event `seq` of chat `sid` is delivered: false when either path already
    /// delivered it (dual send ran on this link and its seq is not past the chat's cursor).
    /// Moves the chat's cursor before it is delivered, so the other path never delivers it too.
    pub(super) fn dual_claim(&self, sid: &str, seq: u64, from_shadow: bool) -> bool {
        let mut members = self.dual_sessions.lock_or_recover();
        let mut cursors = self.cursors.lock_or_recover();
        let cursor = cursors.get_mut(sid);
        if !members.contains(sid) || cursor.is_none() {
            members.remove(sid);
            // The link alone streams this chat (the shadow drops it). Its cursor moves here,
            // before the event is delivered, so a shadow that starts meanwhile attaches after it.
            if let Some(cursor) = cursor.filter(|_| !from_shadow) {
                *cursor = (*cursor).max(seq);
            }
            return !from_shadow;
        }
        let Some(cursor) = cursor else { return !from_shadow };
        if seq > 0 && seq <= *cursor {
            self.dual_stats.repeats.fetch_add(1, Ordering::Relaxed);
            return false;
        }
        *cursor = (*cursor).max(seq);
        // The link is past everything a shadow gave this chat: it alone streams it again.
        if !from_shadow && self.shadow.lock_or_recover().is_none() {
            members.remove(sid);
        }
        true
    }

    /// A request about chat `sid` went out (a `session/load` sends its history again, which is no
    /// repeat): the link alone streams it from now.
    pub(super) fn dual_forget(&self, sid: &str) {
        self.dual_sessions.lock_or_recover().remove(sid);
    }

    /// The link ended: dual send of this link is over.
    pub(super) fn dual_link_ended(&self) {
        self.dual_sessions.lock_or_recover().clear();
    }

    /// Whether a pending `key` waits on a shadow's answer: kept when its link ends.
    pub(super) fn dual_carried(&self, key: &str) -> bool {
        self.dual_keys.lock_or_recover().contains(key)
    }

    /// Whether the shadow should end now: the doubt cleared, or its link ended and the grace for
    /// answers to what it carried passed. Unregisters it from copies at once when its link ended.
    pub(super) fn shadow_done(&self, run: &mut ShadowRun) -> bool {
        if run.link != self.link_epoch() || self.serving() == Some(run.via) {
            self.unregister_shadow(run);
            let at = *run.orphaned_at.get_or_insert_with(tokio::time::Instant::now);
            return at.elapsed() >= ANSWER_GRACE
                || self.serving() == Some(run.via)
                || self.dual_keys.lock_or_recover().is_empty();
        }
        !self.dual_wanted(run.via)
    }

    fn unregister_shadow(&self, run: &ShadowRun) {
        let mut shadow = self.shadow.lock_or_recover();
        if shadow.as_ref().is_some_and(|s| s.via == run.via && s.link == run.link) {
            *shadow = None;
        }
    }

    /// The shadow ends: no copies from now; a doubt that cleared detaches its chats (the
    /// returned frames, sent on it while it stays a probe); copies it carried whose answer never
    /// came fail as `peer_disconnected` (the peer may have run them), as on a link that drops.
    pub(super) async fn shadow_end(&self, run: ShadowRun) -> Vec<String> {
        self.unregister_shadow(&run);
        let mut frames = Vec::new();
        if run.link == self.link_epoch() {
            for sid in run.streams.keys() {
                let id = self.next_id.fetch_add(1, Ordering::SeqCst);
                let line =
                    Message::request(id, method::MUX_DETACH, json!({"sessionId": sid})).to_line();
                let line = line.trim_end_matches('\n').to_owned();
                self.dual_stats.sent(line.len());
                frames.push(line);
            }
        }
        let orphans: Vec<String> = self.dual_keys.lock_or_recover().drain().collect();
        if run.link != self.link_epoch() && !orphans.is_empty() {
            let mut pending = self.pending.lock().await;
            for key in orphans {
                if self.prompts.lock_or_recover().get(&key).is_some_and(|p| p.accepted) {
                    continue;
                }
                if let Some(tx) = pending.remove(&key) {
                    let _ = tx.send(Err(crate::rpc::RpcError::internal("peer disconnected")
                        .with_data(json!({
                            "reason": "peer_disconnected",
                            "detail": "the request went out before the link dropped; the peer may have run it",
                            "peer": self.name,
                        }))));
                }
            }
        }
        tracing::info!(
            peer = %self.name,
            via = run.via.as_str(),
            frames = self.dual_stats.frames.load(Ordering::Relaxed),
            bytes = self.dual_stats.bytes.load(Ordering::Relaxed),
            "dual send ended"
        );
        frames
    }

    /// A text frame the shadow read. Replies settle their callers (the first of the two copies
    /// to answer); chat events past their cursor are delivered; everything else is the link's.
    pub(super) async fn shadow_frame(&self, run: &mut ShadowRun, text: &str) {
        let Ok(msg) = Message::parse(text) else { return };
        match msg {
            Message::Response { id, result, error } => {
                let attaching = run.streams.iter().find_map(|(sid, stream)| match stream {
                    Stream::Attaching { attach, after, seen } if id.as_i64() == Some(*attach) => {
                        Some((sid.clone(), *after, *seen))
                    }
                    _ => None,
                });
                if let Some((sid, after, seen)) = attaching {
                    let page = match (error, result) {
                        (None, Some(page)) => page,
                        _ => {
                            run.streams.insert(sid, Stream::Off);
                            return;
                        }
                    };
                    self.shadow_page(run, &sid, after, seen, &page).await;
                    return;
                }
                let key = id.to_string();
                let tx = self.pending.lock().await.remove(&key);
                self.on_wire.lock_or_recover().remove(&key);
                self.dual_keys.lock_or_recover().remove(&key);
                let Some(tx) = tx else { return };
                let _ = tx.send(match error {
                    Some(e) => Err(e),
                    None => Ok(result.unwrap_or(Value::Null)),
                });
            }
            Message::Notification { method: m, params } => {
                let p = params.unwrap_or(Value::Null);
                let Some((sid, seq)) = event_seq(&m, &p) else { return };
                match run.streams.get_mut(&sid) {
                    Some(Stream::Live) => {}
                    Some(Stream::Attaching { seen, .. }) => {
                        *seen = (*seen).max(seq);
                        return;
                    }
                    _ => return,
                }
                if self.dual_claim(&sid, seq, true) {
                    self.deliver(run.link, m, p).await;
                }
            }
            Message::Request { .. } => {}
        }
    }

    /// The shadow's attach of `sid` after `after` answered with `page`: its events past the
    /// cursor are delivered, and the chat is live on the shadow if its stream has no gap.
    async fn shadow_page(
        &self,
        run: &mut ShadowRun,
        sid: &str,
        after: u64,
        seen: u64,
        page: &Value,
    ) {
        let through = page_max_seq(page).unwrap_or(after).max(after);
        let whole = page.get("hasMore") != Some(&Value::Bool(true)) && seen <= through;
        if let Some(events) = page.get("events").and_then(Value::as_array) {
            for event in events {
                let Some(seq) = event.get("seq").and_then(Value::as_u64) else { continue };
                if self.dual_claim(sid, seq, true) {
                    self.deliver(run.link, method::MUX_EVENT.to_owned(), event.clone()).await;
                }
            }
        }
        run.streams.insert(sid.to_owned(), if whole { Stream::Live } else { Stream::Off });
    }

    async fn deliver(&self, link: u64, method: String, params: Value) {
        let _ = self
            .notices
            .send((
                self.name.clone(),
                self.generation,
                super::PeerNotice::Notification { method, params, link },
            ))
            .await;
    }
}
