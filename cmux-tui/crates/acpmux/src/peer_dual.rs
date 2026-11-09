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
//! - Only requests with no effect bound to the connection go on both paths
//!   (`server::dual_requests::METHODS`: a prompt and a cancel, keyed by their ids, and reads).
//!   A `session/load`, an attach or anything else that replays or subscribes goes only on the
//!   link's path; when that path dies under it, it is sent again on the next link
//!   (`Peer::resend_switched`), never raced.
//! - Each reply is taken once: the first to come settles its caller, the other finds no caller.
//! - Each chat event is taken once and in order, by one merger (`Peer::merge_event`) that both
//!   readers go through and that holds its lock from the claim through the hand-off to the hub.
//!   It delivers a chat's next seq only: the link's stream is ordered, so an event it brings
//!   lets through what the shadow brought below it first; the shadow's events wait past a gap
//!   until the seq before them comes. A shadow stream that lags (`_acpmux/lagged`) or whose gap
//!   outlives [`GAP_BOUND`] is not trusted until it is attached again from the cursor. The
//!   cursor never skips a seq.
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
use std::collections::{BTreeMap, HashMap};
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
/// How long the events the shadow brought past a gap in a chat wait for the seq before them:
/// past it, the shadow's stream of the chat is attached again from the cursor.
pub(super) const GAP_BOUND: Duration = Duration::from_secs(2);
/// Events held past a gap in one chat at most; one more and the chat is attached again.
const MOST_AHEAD: usize = 1024;
/// The notification a daemon sends a connection that missed some of what it streamed.
const LAGGED: &str = "_acpmux/lagged";

/// Events the shadow brought past a gap in a chat's stream, waiting for the seq before them.
/// One per peer, behind one lock (`Peer::dual_merge`) that both readers hold from a claim
/// through its hand-off to the hub.
#[derive(Default)]
pub(super) struct Merger {
    ahead: HashMap<String, BTreeMap<u64, (String, Value)>>,
    /// Since when each chat has a gap.
    since: HashMap<String, tokio::time::Instant>,
}

impl Merger {
    fn forget(&mut self, sid: &str) {
        self.ahead.remove(sid);
        self.since.remove(sid);
    }
}

/// Where a chat event came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Source {
    /// The link's own stream: ordered, so nothing before one of its events is still to come.
    Link,
    /// The shadow's live stream of a chat: its events go only in order from the cursor.
    Shadow,
    /// A page the shadow's attach answered with: every event after the attach's cursor.
    ShadowPage,
}

/// What became of an event the merger got.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Merged {
    /// Delivered, or dropped as delivered already.
    Done,
    /// Held past a gap.
    Ahead,
    /// The shadow's stream of the chat has a gap too long to hold: attach it again.
    Gap,
    /// The hub is gone.
    Closed,
}

/// Whether a request `m` is bound to the connection it went on: it replays or subscribes a
/// chat there, so it goes only on the link's path, and again on the next link after a switch.
pub(super) fn bound(m: &str) -> bool {
    matches!(m, method::SESSION_LOAD | method::SESSION_RESUME | method::MUX_ATTACH)
}

/// Whether `line` is a request or notification sent on both paths: decided by its content,
/// by the rule the daemon dedupes by (`dual_requests::dual_safe`).
pub(super) fn copied(line: &str) -> bool {
    let Ok(msg) = serde_json::from_str::<Value>(line) else { return false };
    let Some(m) = msg.get("method").and_then(Value::as_str) else { return false };
    crate::server::dual_requests::dual_safe(m, msg.get("params").unwrap_or(&Value::Null))
}

/// A `dualId` only this link writes: one a client put in what is forwarded is dropped.
pub(super) fn drop_foreign_id(params: &mut Value) {
    if let Some(mux) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove("dualId");
    }
}

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
    /// Chats whose attach did not cover their stream (one page of many, or the live stream ran
    /// past it) and that made no progress: when each is attached again, and how many times.
    retry: HashMap<String, (tokio::time::Instant, u32)>,
    /// When its link ended: it reads answers to what it carried until [`ANSWER_GRACE`].
    orphaned_at: Option<tokio::time::Instant>,
}

/// The wait before attaching again a chat whose last attach made no progress: doubling from
/// [`RETRY_FIRST`] up to [`RETRY_MOST`].
const RETRY_FIRST: Duration = Duration::from_millis(250);
const RETRY_MOST: Duration = Duration::from_secs(5);

fn retry_wait(tries: u32) -> Duration {
    RETRY_FIRST.saturating_mul(1u32 << tries.min(5)).min(RETRY_MOST)
}

/// A load, resume or attach of a chat in flight (`Peer::replay_start`): its chat leaves the
/// merger until it answers.
pub(super) struct ReplayMark<'a> {
    peer: &'a Peer,
    sid: String,
    done: bool,
}

impl ReplayMark<'_> {
    /// It answered: under the merger's lock, the chat's replay is through and its cursor past
    /// it, so a later shadow may take the chat again.
    pub(super) async fn finish(mut self) {
        let _merger = self.peer.dual_merge.lock().await;
        self.peer.replay_end(&self.sid);
        self.done = true;
    }
}

impl Drop for ReplayMark<'_> {
    /// Its caller left before the answer: the mark goes without the merger's lock (a drop
    /// cannot wait for it); the chat stays out of the merger until a shadow starts again.
    fn drop(&mut self) {
        if !self.done {
            self.peer.replay_end(&self.sid);
        }
    }
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
    pub(super) fn takes_dual(&self) -> bool {
        self.features.lock_or_recover().iter().any(|f| f == crate::server::dual_requests::FEATURE)
    }

    /// Whether the probe on `via` should be the link's shadow now: the link is connected on
    /// another path, that path is in doubt, `via` is the best other path that answers, and the
    /// peer runs a doubled request once.
    pub(super) fn dual_wanted(&self, via: Via) -> bool {
        let Some(serving) = self.serving() else { return false };
        // Both paths must be the daemon's one peer principal (`dual_requests::PEER_LINK`): each
        // presented the peer token when it opened. A path that withholds it is served as the
        // Web there, held to other rules, and its dual ids are ignored.
        let principal = |via| self.token_paths.lock_or_recover().get(&via).copied() == Some(true);
        serving != via
            && self.connected.load(Ordering::SeqCst)
            && self.takes_dual()
            && principal(serving)
            && self.with_paths(|paths| {
                paths.dual_partner_among(serving, crate::store::now_ms(), principal)
            }) == Some(via)
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
    pub(super) async fn shadow_start(&self, via: Via) -> (ShadowRun, Vec<String>) {
        // The merger first: an event the link is handing to the hub is through before a cursor
        // is read here, so the shadow never brings the next one ahead of it.
        let mut merger = self.dual_merge.lock().await;
        merger.ahead.clear();
        merger.since.clear();
        let link = self.link_epoch();
        let (tx, rx) = mpsc::channel(SHADOW_QUEUE);
        let mut streams = HashMap::new();
        let mut frames = Vec::new();
        {
            // Both locks, in the order `merge_event` takes them: no event is delivered between
            // reading a chat's cursor and marking it, so the shadow's attach after that cursor
            // and the link's stream never both deliver one event.
            let mut members = self.dual_sessions.lock_or_recover();
            let cursors = self.cursors.lock_or_recover();
            // A chat a load or an attach replays now stays the link's alone: its replay is
            // below the cursor, and no repeat (`Peer::replay_start`).
            let replaying = self.replaying.lock_or_recover();
            for (sid, after) in replayable(&cursors) {
                if replaying.contains_key(&sid) {
                    continue;
                }
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
        drop(merger);
        self.dual_stats.episodes.fetch_add(1, Ordering::Relaxed);
        for frame in &frames {
            self.dual_stats.sent(frame.len());
        }
        tracing::info!(peer = %self.name, via = via.as_str(), chats = streams.len(), "the link's path is in doubt; sending on {} too", via.as_str());
        let retry = HashMap::new();
        (ShadowRun { via, link, rx, streams, retry, orphaned_at: None }, frames)
    }

    /// The link's frame `text` (pending key `key`) on link `link`: with a shadow, stamped with
    /// its dual id and copied to the shadow. Returns the text to send on the link.
    pub(super) fn dual_copy(&self, text: String, key: Option<&str>, link: u64) -> String {
        let shadow = self.shadow.lock_or_recover();
        let Some(shadow) = shadow.as_ref().filter(|shadow| shadow.link == link) else {
            return text;
        };
        // One bound to its connection (a load, an attach) goes on the link's path alone.
        if !copied(&text) {
            return text;
        }
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

    /// The chat event `seq` of chat `sid` (`method`, `params`) from `source`, read on link
    /// `link`: handed to the hub once and in order, under the merger's lock from the claim to
    /// the hand-off.
    ///
    /// A chat no shadow streams goes as before: from the link only, its cursor moved first (so
    /// a shadow that starts meanwhile attaches after it). A chat both stream is delivered only
    /// past its cursor: the link's event and what the shadow held below it, in seq order; the
    /// shadow's only as the cursor's next seq, else held past the gap.
    pub(super) async fn merge_event(
        &self,
        sid: &str,
        seq: u64,
        method: String,
        params: Value,
        source: Source,
        link: u64,
    ) -> Merged {
        let mut merger = self.dual_merge.lock().await;
        let cursor = {
            let mut members = self.dual_sessions.lock_or_recover();
            let mut cursors = self.cursors.lock_or_recover();
            let replaying = self.replaying.lock_or_recover().contains_key(sid);
            match cursors.get_mut(sid) {
                Some(cursor) if members.contains(sid) && !replaying => Some(*cursor),
                cursor => {
                    members.remove(sid);
                    merger.forget(sid);
                    if source != Source::Link {
                        return Merged::Done;
                    }
                    if let Some(cursor) = cursor {
                        *cursor = (*cursor).max(seq);
                    }
                    None
                }
            }
        };
        let Some(cursor) = cursor else {
            return if self.deliver(link, method, params).await {
                Merged::Done
            } else {
                Merged::Closed
            };
        };
        if seq > 0 && seq <= cursor {
            self.dual_stats.repeats.fetch_add(1, Ordering::Relaxed);
            return Merged::Done;
        }
        if source == Source::Shadow && seq != cursor + 1 {
            let ahead = merger.ahead.entry(sid.to_owned()).or_default();
            if ahead.len() >= MOST_AHEAD {
                merger.forget(sid);
                return Merged::Gap;
            }
            ahead.insert(seq, (method, params));
            merger.since.entry(sid.to_owned()).or_insert_with(tokio::time::Instant::now);
            return Merged::Ahead;
        }
        // In seq order: what the shadow held below this event, this event, then what it held
        // right after.
        let mut ready: Vec<(u64, (String, Value))> = Vec::new();
        if let Some(ahead) = merger.ahead.get_mut(sid) {
            let rest = ahead.split_off(&seq);
            ready.extend(std::mem::replace(ahead, rest));
        }
        ready.push((seq, (method, params)));
        let mut last = seq;
        if let Some(ahead) = merger.ahead.get_mut(sid) {
            ahead.remove(&seq);
            while let Some(next) = ahead.remove(&(last + 1)) {
                last += 1;
                ready.push((last, next));
            }
        }
        if merger.ahead.get(sid).is_some_and(BTreeMap::is_empty) {
            merger.forget(sid);
        } else if merger.ahead.contains_key(sid) {
            // A gap past the new cursor: its wait starts now.
            merger.since.insert(sid.to_owned(), tokio::time::Instant::now());
        }
        for (seq, (method, params)) in ready {
            if let Some(cursor) = self.cursors.lock_or_recover().get_mut(sid) {
                *cursor = (*cursor).max(seq);
            }
            if !self.deliver(link, method, params).await {
                return Merged::Closed;
            }
        }
        // The link is past everything a shadow gave this chat: it alone streams it again.
        if source == Source::Link && self.shadow.lock_or_recover().is_none() {
            self.dual_sessions.lock_or_recover().remove(sid);
            merger.forget(sid);
        }
        Merged::Done
    }

    /// The chats whose gap outlived [`GAP_BOUND`]: what the shadow held past it is dropped, and
    /// each is to be attached again on the shadow from its cursor.
    pub(super) async fn dual_gaps(&self) -> Vec<String> {
        let mut merger = self.dual_merge.lock().await;
        let members = self.dual_sessions.lock_or_recover().clone();
        let stale: Vec<String> = merger
            .since
            .iter()
            .filter(|(_, at)| at.elapsed() >= GAP_BOUND)
            .map(|(sid, _)| sid.clone())
            .collect();
        for sid in &stale {
            merger.forget(sid);
        }
        stale.into_iter().filter(|sid| members.contains(sid)).collect()
    }

    /// Attach `sid` again on the shadow from its cursor: its stream there is not trusted until
    /// the attach answers. The frame to send on the shadow, if the chat still has a cursor.
    pub(super) async fn shadow_resubscribe(
        &self,
        run: &mut ShadowRun,
        sid: &str,
    ) -> Option<String> {
        let mut merger = self.dual_merge.lock().await;
        merger.forget(sid);
        // A chat the link alone streams now (a load or attach took it) is not taken again.
        let member = self.dual_sessions.lock_or_recover().contains(sid);
        let after = self.cursors.lock_or_recover().get(sid).copied().filter(|c| *c > 0);
        drop(merger);
        let Some(after) = after.filter(|_| member) else {
            run.streams.insert(sid.to_owned(), Stream::Off);
            run.retry.remove(sid);
            return None;
        };
        let attach = self.next_id.fetch_add(1, Ordering::SeqCst);
        let line =
            Message::request(attach, method::MUX_ATTACH, hidden_attach_after(sid, after)).to_line();
        let line = line.trim_end_matches('\n').to_owned();
        self.dual_stats.sent(line.len());
        run.streams.insert(sid.to_owned(), Stream::Attaching { attach, after, seen: 0 });
        tracing::debug!(peer = %self.name, chat = sid, after, "the shadow's stream of a chat has a gap; attaching it again");
        Some(line)
    }

    /// A request that replays chat `sid` went out (a `session/load` or an attach sends its
    /// history again, which is no repeat): the link alone streams it from now.
    ///
    /// Under the merger's lock: the chat leaves dedup, what the shadow held of it goes, and it
    /// is marked in flight, so neither a shadow that starts now nor the merger takes it until
    /// the mark ends; its replay goes to the hub as it comes and moves its cursor.
    pub(super) async fn replay_start(&self, sid: &str) -> ReplayMark<'_> {
        let mut merger = self.dual_merge.lock().await;
        merger.forget(sid);
        self.dual_sessions.lock_or_recover().remove(sid);
        *self.replaying.lock_or_recover().entry(sid.to_owned()).or_default() += 1;
        ReplayMark { peer: self, sid: sid.to_owned(), done: false }
    }

    fn replay_end(&self, sid: &str) {
        let mut replaying = self.replaying.lock_or_recover();
        if let Some(n) = replaying.get_mut(sid) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                replaying.remove(sid);
            }
        }
    }

    /// The chats due to be attached again on the shadow ([`ShadowRun::retry`]).
    pub(super) async fn shadow_retries(&self, run: &mut ShadowRun) -> Vec<String> {
        let now = tokio::time::Instant::now();
        let due: Vec<String> = run
            .retry
            .iter()
            .filter(|(sid, (at, _))| {
                *at <= now && matches!(run.streams.get(*sid), Some(Stream::Off))
            })
            .map(|(sid, _)| sid.clone())
            .collect();
        let mut frames = Vec::new();
        for sid in due {
            frames.extend(self.shadow_resubscribe(run, &sid).await);
        }
        frames
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
    /// Returns frames to send on the shadow: attaches again of chats whose stream there lagged
    /// or has a gap.
    pub(super) async fn shadow_frame(&self, run: &mut ShadowRun, text: &str) -> Vec<String> {
        let Ok(msg) = Message::parse(text) else { return Vec::new() };
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
                            return Vec::new();
                        }
                    };
                    return self.shadow_page(run, &sid, after, seen, &page).await;
                }
                // Only a success from the shadow settles a call: an error there may be the
                // shadow connection's own (a rule it is held to that the link is not), so the
                // link's answer, or its end, settles the caller instead.
                let key = id.to_string();
                if let Some(e) = error {
                    tracing::debug!(peer = %self.name, key = %key, "the shadow's copy failed; waiting on the link: {}", e.message);
                    return Vec::new();
                }
                let tx = self.pending.lock().await.remove(&key);
                self.on_wire.lock_or_recover().remove(&key);
                self.dual_keys.lock_or_recover().remove(&key);
                if let Some(tx) = tx {
                    let _ = tx.send(Ok(result.unwrap_or(Value::Null)));
                }
                Vec::new()
            }
            Message::Notification { method: m, params } if m == LAGGED => {
                // The shadow missed some of what it streamed: the lagged chat, or without one
                // named every chat, is attached again from its cursor.
                let named = params
                    .as_ref()
                    .and_then(|p| p.get("sessionId"))
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                let chats: Vec<String> = match named {
                    Some(sid) => {
                        run.streams.contains_key(&sid).then_some(sid).into_iter().collect()
                    }
                    None => run.streams.keys().cloned().collect(),
                };
                let mut frames = Vec::new();
                for sid in chats {
                    frames.extend(self.shadow_resubscribe(run, &sid).await);
                }
                frames
            }
            // A prompt the shadow's copy ran was accepted there: told on that connection only.
            Message::Notification { method: m, params } if m == method::MUX_PROMPT_ACCEPTED => {
                let p = params.unwrap_or(Value::Null);
                self.note_prompt_accepted(&p);
                self.deliver(run.link, m, p).await;
                Vec::new()
            }
            Message::Notification { method: m, params } => {
                let p = params.unwrap_or(Value::Null);
                let Some((sid, seq)) = event_seq(&m, &p) else { return Vec::new() };
                match run.streams.get_mut(&sid) {
                    Some(Stream::Live) => {}
                    Some(Stream::Attaching { seen, .. }) => {
                        *seen = (*seen).max(seq);
                        return Vec::new();
                    }
                    _ => return Vec::new(),
                }
                match self.merge_event(&sid, seq, m, p, Source::Shadow, run.link).await {
                    Merged::Gap => self.shadow_resubscribe(run, &sid).await.into_iter().collect(),
                    Merged::Done | Merged::Ahead | Merged::Closed => Vec::new(),
                }
            }
            Message::Request { .. } => Vec::new(),
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
    ) -> Vec<String> {
        let through = page_max_seq(page).unwrap_or(after).max(after);
        let whole = page.get("hasMore") != Some(&Value::Bool(true)) && seen <= through;
        if let Some(events) = page.get("events").and_then(Value::as_array) {
            for event in events {
                let Some(seq) = event.get("seq").and_then(Value::as_u64) else { continue };
                let method = method::MUX_EVENT.to_owned();
                self.merge_event(sid, seq, method, event.clone(), Source::ShadowPage, run.link)
                    .await;
            }
        }
        if whole {
            run.streams.insert(sid.to_owned(), Stream::Live);
            run.retry.remove(sid);
            return Vec::new();
        }
        // One page of many, or the live stream ran past it: attached again from the cursor, at
        // once while each attach moves the cursor, else after a wait that doubles.
        run.streams.insert(sid.to_owned(), Stream::Off);
        let cursor = self.cursors.lock_or_recover().get(sid).copied().unwrap_or(after);
        if cursor > after {
            run.retry.remove(sid);
            return self.shadow_resubscribe(run, sid).await.into_iter().collect();
        }
        let tries = run.retry.get(sid).map_or(0, |(_, tries)| tries + 1);
        run.retry.insert(sid.to_owned(), (tokio::time::Instant::now() + retry_wait(tries), tries));
        Vec::new()
    }

    /// Hand a chat event to the hub; false when the hub is gone.
    async fn deliver(&self, link: u64, method: String, params: Value) -> bool {
        self.notices
            .send((
                self.name.clone(),
                self.generation,
                super::PeerNotice::Notification { method, params, link },
            ))
            .await
            .is_ok()
    }
}
