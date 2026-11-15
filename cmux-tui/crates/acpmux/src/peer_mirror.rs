//! The dialing side of a peer's list stream (row 8, part two): a v2 client on
//! the peer link mirrors the peer's live view into the index under the peer's
//! origin, one unit per frame, each with the mark (cursor, edition, whether
//! the walk finished) after its rows.
//!
//! - **Hydration first.** No unit goes in before the hub's hydration is
//!   ready: a closed change for a live row not yet installed would be skipped
//!   while the mark moved past it.
//! - **A resume sends no takeover.** With the origin's mark on and the origin
//!   this source's, the client resumes from the mark's cursor in its edition.
//! - **A walk begins with the takeover** (decision 222). A window means a
//!   walk: when the origin's mark is on, or another source feeds the origin,
//!   the dialer sends its takeover, which writes the mark off in its own turn,
//!   and submits the walk's first unit (`after: None`) only once the mark
//!   reads off. It never sends a first unit that names the current mark. The
//!   rows the origin held stay until the walk's reconcile. The wait ends on
//!   the writer's handling of the takeover, never on the mark alone: held with
//!   a leaving origin, the dialer starts again; replaced or followed by
//!   another source's takeover, the mirror ends, refused.
//! - **One unit in the queue.** Before each unit the dialer waits until the
//!   origin is settled (no unit of it queued, in the writer or in the storage
//!   retry, and the origin not leaving), so a unit is never refused as full
//!   and the dialer reads no further frame meanwhile.
//! - **The break rule.** Settled, the origin's mark must be the last one sent;
//!   when it is not, a unit was dropped after it was queued (the origin was
//!   held, taken over or removed) and the dialer reads no further frame of
//!   that subscription. It starts again from the mark: a resume when the mark
//!   is on, a walk when it is off. A leaving origin is waited out by the
//!   settle (woken by the writer's turns, no spin); restarts in a row back off.
use acpmux_book::index::Summary;
use acpmux_client::wire::{ListKey, ListView, Sub};
use acpmux_client::{Change, Client};
use acpmux_core::hub::{
    Hub, HubError, MAX_UNIT_CHANGES, MirrorMark, MirrorUnit, Source, UnitChange,
};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// The origin a peer's own rows carry on its link.
const PEER_LOCAL: &str = "local";

/// The longest wait between two restarts in a row.
const MAX_RESTART_BACKOFF: Duration = Duration::from_secs(5);

#[derive(Default)]
pub struct DialCounters {
    /// Units the hub queued.
    pub units: AtomicU64,
    /// Subscriptions that resumed from the mark.
    pub resumes: AtomicU64,
    /// Walks begun (a window).
    pub walks: AtomicU64,
    /// Takeovers sent before a walk.
    pub takeovers: AtomicU64,
    /// Subscriptions started again because the mark was not the last one sent.
    pub restarts: AtomicU64,
    /// Rows of another origin than the peer's own, not mirrored.
    pub foreign_rows: AtomicU64,
    /// Mirrors ended because the link's frames waiting for them passed
    /// [`MIRROR_INBOX_BYTES`]: a peer that sent past its credit.
    pub inbox_overflows: AtomicU64,
    /// Origins handed back to v1's tee: a takeover as v1 applied over the mirror's.
    pub hand_backs: AtomicU64,
}

/// The most frame bytes a link holds for its mirror: the client's credit
/// window, which bounds what a peer may send ahead, and one frame more.
pub const MIRROR_INBOX_BYTES: usize =
    acpmux_client::wire::CREDIT_WINDOW_BYTES as usize + acpmux_client::wire::MAX_REPLAY_FRAME_BYTES;

/// Why a mirror on a link ended.
#[derive(Debug)]
pub enum DialEnd {
    /// The link's stream ended.
    Eof,
    /// The client closed, or the serving end refused a request.
    Closed(String),
    /// The hub refused a unit in a way a restart does not mend.
    Refused(HubError),
}

/// Mirrors the peer's live view over `reader`/`writer`, an ordered byte stream
/// to the peer's v2 connection, into `hub` under `origin`.
pub async fn mirror<R, W>(
    hub: Arc<Hub>,
    origin: &str,
    mut reader: R,
    mut writer: W,
    counters: &DialCounters,
) -> std::io::Result<DialEnd>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    if let Err(error) = hub.wait_hydrated().await {
        return Ok(DialEnd::Refused(error));
    }
    let mut dial = Dial::new(hub, origin, counters);
    dial.start();
    let mut buf = vec![0_u8; 16 * 1024];
    let mut pending = Vec::new();
    loop {
        while let Some(bytes) = dial.client.take_send() {
            writer.write_all(&bytes).await?;
        }
        let mut batch = Vec::new();
        while let Some(change) = dial.client.next_change() {
            batch.push(change);
        }
        if !batch.is_empty() {
            if let Some(end) = dial.frame(batch).await {
                return Ok(end);
            }
            continue;
        }
        if dial.client.is_closed() {
            return Ok(DialEnd::Closed("the client closed".into()));
        }
        if pending.is_empty() {
            let n = reader.read(&mut buf).await?;
            if n == 0 {
                return Ok(DialEnd::Eof);
            }
            pending.extend_from_slice(buf.get(..n).unwrap_or_default());
        }
        let consumed = dial.client.received(&pending);
        pending.drain(..consumed.min(pending.len()));
    }
}

struct Dial<'a> {
    hub: Arc<Hub>,
    origin: &'a str,
    counters: &'a DialCounters,
    client: Client<Summary>,
    sid: String,
    subscriptions: u64,
    cursor: u64,
    edition: u32,
    whole: bool,
    /// The mark of the last unit the hub queued, or the origin's mark when
    /// the subscription started.
    last_sent: Option<MirrorMark>,
    /// Restarts since a unit last went in.
    restarts: u32,
    /// [`MAX_UNIT_CHANGES`]; the cut tests take smaller units to reach more cuts.
    unit_changes: usize,
}

impl<'a> Dial<'a> {
    fn new(hub: Arc<Hub>, origin: &'a str, counters: &'a DialCounters) -> Self {
        let mut client = Client::connected_v2();
        client.connected();
        Self {
            hub,
            origin,
            counters,
            client,
            sid: String::new(),
            subscriptions: 0,
            cursor: 0,
            edition: 0,
            whole: false,
            last_sent: None,
            restarts: 0,
            unit_changes: MAX_UNIT_CHANGES,
        }
    }

    /// Subscribes from the origin's mark: a resume when it is on and the
    /// origin is this source's, else a walk.
    fn start(&mut self) {
        if !self.sid.is_empty() {
            let _ = self.client.unsubscribe(&self.sid);
        }
        self.subscriptions += 1;
        self.sid = format!("mirror-{}", self.subscriptions);
        let mark = self.hub.mirror_mark(self.origin);
        let owned = self.hub.source(self.origin) == Some(Source::Mirror);
        let mut sub = Sub::new(self.sid.clone(), "list");
        sub.view = Some(ListView::Live);
        self.last_sent = mark;
        let resume = mark.filter(|_| owned);
        if let Some(mark) = resume {
            sub = sub.from_cursor_in_edition(mark.cursor, mark.edition);
            (self.cursor, self.edition, self.whole) = (mark.cursor, mark.edition, mark.whole);
            // A mark that is not whole goes on with a walk the link cut; only a
            // whole one resumes the peer's changes.
            if mark.whole {
                self.counters.resumes.fetch_add(1, Ordering::Relaxed);
            }
        } else {
            (self.cursor, self.edition, self.whole) = (0, 0, false);
        }
        let held = self.held_keys();
        let whole = resume.is_some_and(|mark| mark.whole);
        if let Err(error) = self.client.subscribe_mirror(sub, held, whole) {
            tracing::warn!(origin = self.origin, %error, "the peer mirror's subscription failed");
        }
    }

    /// The keys of the origin's rows as the peer names them, for the walk's
    /// reconcile.
    ///
    /// Read from the origin's own range of the index: a dial costs what the
    /// origin holds, not what the index holds. The client needs the set at
    /// subscribe even for a resume: a resume answered with a window walks on
    /// the same subscription, and the walk's end (`finish_mirror_walk`) finds
    /// the rows to drop among these keys.
    fn held_keys(&self) -> Vec<ListKey> {
        self.hub
            .snapshot()
            .origin_rows(self.origin)
            .map(|row| ListKey {
                last_activity: row.last_activity,
                chat_id: row.chat_id.clone(),
                origin: PEER_LOCAL.to_owned(),
            })
            .collect()
    }

    /// One frame's changes, in units of at most [`MAX_UNIT_CHANGES`], each
    /// with the mark after its last change.
    async fn frame(&mut self, batch: Vec<Change<Summary>>) -> Option<DialEnd> {
        let mut changes = Vec::new();
        // The mark after each change, for a unit that ends there.
        let mut marks = Vec::new();
        for change in batch {
            match change {
                Change::Window(window) if window.sid == self.sid => {
                    match self.begin_walk().await {
                        Ok(true) => {}
                        // Started again from the mark: the rest of this
                        // subscription is not read.
                        Ok(false) => return None,
                        Err(end) => return Some(end),
                    }
                    (self.cursor, self.edition, self.whole) =
                        (window.cursor, window.edition, false);
                    changes.extend(window.rows.into_iter().filter_map(|row| self.row(row)));
                }
                Change::Page(page) if page.sid == self.sid => {
                    changes.extend(page.rows.into_iter().filter_map(|row| self.row(row)));
                }
                Change::Summary { sid, seq, summary, .. }
                | Change::Left { sid, seq, summary, .. }
                    if sid == self.sid =>
                {
                    self.cursor = self.cursor.max(seq);
                    changes.extend(self.row(summary));
                }
                Change::Gone { sid, seq, origin, chat_id, .. } if sid == self.sid => {
                    self.cursor = self.cursor.max(seq);
                    if origin == PEER_LOCAL {
                        changes.push(UnitChange::Gone { chat_id });
                    } else {
                        self.counters.foreign_rows.fetch_add(1, Ordering::Relaxed);
                    }
                }
                Change::Origin { sid, seq, .. }
                | Change::Queue { sid, seq, .. }
                | Change::Folder { sid, seq, .. }
                | Change::FolderGone { sid, seq, .. }
                    if sid == self.sid =>
                {
                    self.cursor = self.cursor.max(seq);
                }
                Change::ResumeEnd { sid, cursor } if sid == self.sid => {
                    self.cursor = self.cursor.max(cursor.0);
                }
                Change::Whole { sid, cursor } if sid == self.sid => {
                    self.cursor = self.cursor.max(cursor.0);
                    self.whole = true;
                }
                // The serving end dropped the subscription and the client
                // reopened it under `new_sid`: from the drop's cursor in the
                // same edition when the drop names one, else as first asked
                // (from the mark, or a walk). The marks sent so far stay.
                Change::Dropped { sid, new_sid: Some(new_sid), .. } if sid == self.sid => {
                    self.sid = new_sid;
                }
                // A drop the client did not reopen. The list client reopens
                // every drop of a subscription it holds, so this arm is a
                // guard: no further frame comes on the sid, and the dialer
                // starts again from the mark, sending nothing of this batch.
                Change::Dropped { sid, new_sid: None, .. } if sid == self.sid => {
                    self.restart().await;
                    return None;
                }
                Change::Error { code, sid, .. }
                    if sid.as_deref().is_none_or(|sid| sid == self.sid) =>
                {
                    return Some(DialEnd::Closed(code));
                }
                _ => {}
            }
            marks.resize(changes.len(), self.mark());
        }
        let mark = self.mark();
        if changes.is_empty() && self.last_sent == Some(mark) {
            return None;
        }
        if changes.is_empty() {
            return self.unit(Vec::new(), mark).await.err();
        }
        let mut changes = changes.into_iter();
        for (n, chunk) in marks.chunks(self.unit_changes).enumerate() {
            let last = n + 1 == marks.len().div_ceil(self.unit_changes);
            // A frame's last unit carries the frame's mark: a `whole` or a
            // resume's end after the last row moves it too.
            let unit_mark = if last { mark } else { chunk.last().copied().unwrap_or(mark) };
            let unit = changes.by_ref().take(chunk.len()).collect();
            match self.unit(unit, unit_mark).await {
                Ok(true) => {}
                // Started again: the rest of the frame is not read.
                Ok(false) => return None,
                Err(end) => return Some(end),
            }
        }
        None
    }

    fn mark(&self) -> MirrorMark {
        MirrorMark { cursor: self.cursor, edition: self.edition, whole: self.whole }
    }

    /// Submits one unit once the origin is settled: `Ok(true)` when it was
    /// queued, `Ok(false)` when the dialer started again from the mark.
    async fn unit(&mut self, changes: Vec<UnitChange>, mark: MirrorMark) -> Result<bool, DialEnd> {
        self.hub.wait_mirror_settled(self.origin).await;
        if self.hub.mirror_mark(self.origin) != self.last_sent {
            self.restart().await;
            return Ok(false);
        }
        let unit =
            MirrorUnit { origin: self.origin.to_owned(), after: self.last_sent, changes, mark };
        match self.hub.submit_unit(Source::Mirror, unit) {
            Ok(()) => {
                self.last_sent = Some(mark);
                self.restarts = 0;
                self.counters.units.fetch_add(1, Ordering::Relaxed);
                Ok(true)
            }
            // Settled, the slot was free; a full slot means another dialer
            // feeds the origin. Start again from the mark.
            Err(HubError::UnitQueueFull) => {
                self.restart().await;
                Ok(false)
            }
            Err(error) => Err(DialEnd::Refused(error)),
        }
    }

    /// A window: the walk's first unit names no mark, so the mark must be off
    /// and the origin this source's before it goes in. `Ok(false)` when the
    /// takeover did not take effect and the dialer started again.
    async fn begin_walk(&mut self) -> Result<bool, DialEnd> {
        self.counters.walks.fetch_add(1, Ordering::Relaxed);
        self.hub.wait_mirror_settled(self.origin).await;
        if self.hub.mirror_mark(self.origin).is_some()
            || self.hub.source(self.origin) != Some(Source::Mirror)
        {
            let origin = self.origin;
            let before = self.hub.takeover_turns(origin);
            if let Err(error) = self.hub.takeover(origin, Source::Mirror) {
                return Err(DialEnd::Refused(error));
            }
            self.counters.takeovers.fetch_add(1, Ordering::Relaxed);
            // The writer handles the takeover in a turn of its own, and each
            // turn wakes this wait: it applies (the mark goes off) or is held
            // with the origin. A takeover of another source queued right
            // behind replaces this one and applies in its place.
            self.hub.wait_mirror_until(|hub| hub.takeover_turns(origin) != before).await;
            let after = self.hub.takeover_turns(origin);
            if after.refused != before.refused {
                // Past the bound on origins: no takeover of this origin
                // applies, and the mirror ends (its link then hands the origin
                // back to v1's tee).
                return Err(DialEnd::Refused(HubError::OriginLimit));
            }
            if after.applied == before.applied {
                // Held: the origin is leaving, or its record waits for the
                // storage retry. The start again waits that out, then takes
                // over or resumes as the mark says then.
                self.restart().await;
                return Ok(false);
            }
            match self.hub.source(origin) {
                Some(Source::Mirror) if self.hub.mirror_mark(origin).is_none() => {}
                // Another source's takeover applied after this one: the
                // origin is that source's now, and this mirror ends.
                Some(owner) if owner != Source::Mirror => {
                    return Err(DialEnd::Refused(HubError::SourceRefused {
                        origin: origin.to_owned(),
                        incoming: Source::Mirror,
                        owner,
                    }));
                }
                _ => {
                    self.restart().await;
                    return Ok(false);
                }
            }
        }
        self.last_sent = None;
        Ok(true)
    }

    /// Starts again from the mark, after a back-off when restarts come in a
    /// row.
    async fn restart(&mut self) {
        self.counters.restarts.fetch_add(1, Ordering::Relaxed);
        if self.restarts > 0 {
            let wait = Duration::from_millis(50)
                .saturating_mul(1 << self.restarts.min(7))
                .min(MAX_RESTART_BACKOFF);
            tokio::time::sleep(wait).await;
        }
        self.restarts = self.restarts.saturating_add(1);
        self.start();
    }

    /// A peer's own row under this origin; another origin's is not mirrored.
    fn row(&self, mut summary: Summary) -> Option<UnitChange> {
        if summary.origin != PEER_LOCAL {
            self.counters.foreign_rows.fetch_add(1, Ordering::Relaxed);
            return None;
        }
        summary.origin = self.origin.to_owned();
        Some(UnitChange::Summary(Box::new(summary)))
    }
}

#[cfg(test)]
#[path = "peer_mirror_cut_tests.rs"]
mod cut_tests;
#[cfg(test)]
#[path = "peer_mirror_tests.rs"]
mod tests;
