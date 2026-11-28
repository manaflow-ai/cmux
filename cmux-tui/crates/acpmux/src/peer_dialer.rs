//! The peer's mirror on its link (row 8, part two). When the peer lists
//! `listStream` and this daemon keeps the index, a v2 client on the link
//! feeds the index under the peer's name (`peer_mirror.rs`). Its frames ride
//! the link as `_acpmux/v2` notification lines beside v1's, both ways.
//!
//! The reader loop hands each frame line to the mirror of the link it came on
//! without waiting, so v1's lines never wait behind it. The client's credit
//! window bounds what a peer may send ahead; a peer that sends past it fills
//! the link's inbox to [`MIRROR_INBOX_BYTES`], and the next frame ends that
//! mirror rather than the reader stopping or the queue growing.
//!
//! A mirror that ends on a link still up, or a link that comes up without the feature, hands
//! the origin back to v1's tee ([`Peer::hand_back`]): a takeover as v1 writes the mark off, and
//! once it applies the tee walks the origin's rows. A link that ends leaves the origin to the
//! next link.
use super::*;
use crate::link_v2::{self, Adapter, Slot};
use crate::peer_mirror::{DialCounters, MIRROR_INBOX_BYTES};
use acpmux_core::hub::{Hub as Index, Source};
use std::sync::atomic::{AtomicU64, Ordering};

/// One link's frame lines on their way to its mirror, counted in frame bytes.
/// The count is this inbox's own: a task of an earlier link that still hands a
/// line takes it off that link's count, never this one's.
pub(super) struct Inbox {
    link: u64,
    frames: mpsc::UnboundedSender<String>,
    held: Arc<AtomicU64>,
    counters: Arc<DialCounters>,
}

/// The mirror's end of an inbox.
pub(super) struct Lines {
    lines: mpsc::UnboundedReceiver<String>,
    held: Arc<AtomicU64>,
}

impl Lines {
    pub(super) async fn recv(&mut self) -> Option<String> {
        self.lines.recv().await
    }

    #[cfg(test)]
    fn try_recv(&mut self) -> Option<String> {
        self.lines.try_recv().ok()
    }

    /// A line the reader took is out of the inbox once the client holds it.
    pub(super) fn handed(&self, line: &str) {
        self.held.fetch_sub(link_v2::frame_bytes(line) as u64, Ordering::Relaxed);
    }
}

/// What became of a frame line offered to a link's inbox.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Offer {
    Queued,
    /// The inbox was past its bound: it is closed, and the mirror ends.
    Overflow,
    /// No mirror reads that link (another epoch, or it ended).
    Dropped,
}

impl Inbox {
    pub(super) fn new(link: u64, counters: Arc<DialCounters>) -> (Self, Lines) {
        // Bounded in bytes by `offer`, not by the channel (RFD 0124 R4): past
        // [`MIRROR_INBOX_BYTES`] the mirror ends and `inbox_overflows` counts it.
        let (frames, lines) = mpsc::unbounded_channel();
        let held = Arc::new(AtomicU64::new(0));
        (Self { link, frames, held: held.clone(), counters }, Lines { lines, held })
    }

    /// Frame bytes read off the link and not yet handed to the client.
    pub(super) fn held(&self) -> u64 {
        self.held.load(Ordering::Relaxed)
    }

    pub(super) fn offer(&self, link: u64, line: String) -> Offer {
        if link != self.link {
            return Offer::Dropped;
        }
        let bytes = link_v2::frame_bytes(&line) as u64;
        let held = self.held.fetch_add(bytes, Ordering::Relaxed) + bytes;
        if held > MIRROR_INBOX_BYTES as u64 {
            self.held.fetch_sub(bytes, Ordering::Relaxed);
            self.counters.inbox_overflows.fetch_add(1, Ordering::Relaxed);
            return Offer::Overflow;
        }
        match self.frames.send(line) {
            Ok(()) => Offer::Queued,
            Err(_) => {
                self.held.fetch_sub(bytes, Ordering::Relaxed);
                Offer::Dropped
            }
        }
    }
}

#[derive(Default)]
pub(super) struct MirrorLink {
    /// The daemon's links' v2 handle, read at each link's start: the index
    /// the mirror feeds is there once `acpmux.v2` holds `list` and `peers`.
    links: std::sync::OnceLock<Arc<link_v2::Shared>>,
    /// The running mirror's frame lines, for the link epoch it reads.
    inbox: StdMutex<Option<Inbox>>,
    pub(super) counters: Arc<DialCounters>,
}

impl Peer {
    /// Where this peer's list stream finds the index it feeds.
    pub fn set_mirror(&self, links: Arc<link_v2::Shared>) {
        let _ = self.mirror.links.set(links);
    }

    pub fn mirror_counters(&self) -> &DialCounters {
        &self.mirror.counters
    }

    /// Frame bytes the running mirror's inbox holds: none when no mirror runs.
    pub fn mirror_inbox_bytes(&self) -> u64 {
        self.mirror.inbox.lock_or_recover().as_ref().map_or(0, Inbox::held)
    }

    /// A v2 frame line read on `link`: to that link's mirror, or dropped when
    /// it runs none. Past the inbox's bound the mirror ends: its queue closes.
    pub(crate) fn mirror_frame(&self, link: u64, line: String) {
        let mut inbox = self.mirror.inbox.lock_or_recover();
        let Some(open) = inbox.as_ref() else { return };
        if open.offer(link, line) == Offer::Overflow {
            tracing::warn!(peer = %self.name, "the peer sent past its credit; its list mirror ends");
            inbox.take();
        }
    }

    pub(super) fn controls_enabled(&self) -> bool {
        self.mirror.links.get().and_then(|links| links.v2()).is_some()
    }

    fn mirror_index(&self) -> Option<Arc<Index>> {
        self.mirror.links.get().and_then(|links| links.v2()).map(|v2| v2.hub())
    }

    /// Gives the origin back to v1's tee if the mirror holds it: a takeover as v1, which writes
    /// the mark off, then, once it applies, the tee's walk of the origin's rows. A takeover held
    /// for a leaving origin applies when the removal is done. Another source's takeover that
    /// applies first keeps the origin: no walk.
    fn hand_back(self: &Arc<Self>, index: Arc<Index>) {
        if index.source(&self.name) != Some(Source::Mirror) {
            return;
        }
        let before = index.takeover_turns(&self.name).applied;
        if let Err(error) = index.takeover(&self.name, Source::V1) {
            tracing::warn!(peer = %self.name, %error, "the list mirror could not hand the peer back");
            return;
        }
        let me = self.clone();
        self.scope.spawn_named("peer-mirror-hand-back", async move {
            index
                .wait_mirror_until(|index| {
                    index.source(&me.name) != Some(Source::Mirror)
                        || index.takeover_turns(&me.name).applied != before
                })
                .await;
            if index.source(&me.name) == Some(Source::Mirror) {
                return;
            }
            me.mirror.counters.hand_backs.fetch_add(1, Ordering::Relaxed);
            if let Some(links) = me.mirror.links.get() {
                links.hand_back(&me.name);
            }
        });
    }

    /// The link ended: its mirror's queue closes, and the mirror with it.
    pub(super) fn end_mirror(&self) {
        self.mirror.inbox.lock_or_recover().take();
    }

    /// Starts the mirror on `link` once its handshake is done, when the peer
    /// lists the feature and this daemon keeps the index.
    pub(crate) fn start_mirror(self: &Arc<Self>, link: u64) {
        let Some(hub) = self.mirror_index() else {
            return;
        };
        if self.link_epoch() != link {
            return;
        }
        if !self.lists(link_v2::FEATURE) {
            self.hand_back(hub);
            return;
        }
        let (open, mut inbox) = Inbox::new(link, self.mirror.counters.clone());
        *self.mirror.inbox.lock_or_recover() = Some(open);
        let slot = Slot::new(None);
        let (adapter, reader, writer) = Adapter::new(slot.clone());
        let me = self.clone();
        self.scope.spawn_named("peer-mirror", async move {
            let feeding = async {
                while let Some(line) = inbox.recv().await {
                    let Some(frame) = link_v2::parse(&line) else { break };
                    let delivered = adapter.deliver(&frame).await;
                    inbox.handed(&line);
                    if !delivered {
                        break;
                    }
                }
                adapter.close();
            };
            let sending = async {
                loop {
                    let line = slot.next_frame().await;
                    if me.link_epoch() != link {
                        break;
                    }
                    if me.out.send(Outbound { epoch: link, key: None, line }).await.is_err() {
                        break;
                    }
                }
            };
            let mirroring = crate::peer_mirror::mirror(
                hub.clone(),
                &me.name,
                reader,
                writer,
                &me.mirror.counters,
            );
            tokio::select! {
                () = feeding => {}
                () = sending => {}
                end = mirroring => match end {
                    Ok(end) => tracing::info!(peer = %me.name, ?end, "the peer's list mirror ended"),
                    Err(error) => tracing::info!(peer = %me.name, %error, "the peer's list mirror ended"),
                },
            }
            // On a link still up no other mirror starts: refused, closed, or past its credit,
            // the mirror ended for good. A link's end moves the epoch before it closes the inbox.
            if me.link_epoch() == link {
                me.hand_back(hub);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A frame line of kind 3 whose payload is `bytes` long.
    fn line(bytes: usize) -> String {
        let pad = "a".repeat(bytes - r#"{"x":""}"#.len());
        format!(
            r#"{{"jsonrpc":"2.0","method":"_acpmux/v2","params":{{"kind":3,"payload":{{"x":"{pad}"}}}}}}"#
        ) + "\n"
    }

    #[test]
    fn a_line_counts_its_frame_bytes() {
        let line = line(1000);
        assert!(link_v2::is_frame_line(&line));
        assert_eq!(link_v2::parse(&line).map(|frame| frame.payload.len()), Some(1000));
        assert_eq!(link_v2::frame_bytes(&line), 1000 + 5);
    }

    /// A peer that ignores credit: nothing drains the inbox. Frames queue up
    /// to the bound, the first past it ends the mirror and is counted, and the
    /// bytes held never pass the bound.
    #[test]
    fn a_peer_past_its_credit_ends_the_mirror_at_the_bound() {
        let counters = Arc::new(DialCounters::default());
        let (inbox, mut lines) = Inbox::new(7, counters.clone());
        let frame = 64 * 1024;
        let mut queued = 0;
        let end = loop {
            match inbox.offer(7, line(frame)) {
                Offer::Queued => queued += 1,
                other => break other,
            }
            assert!(inbox.held() <= MIRROR_INBOX_BYTES as u64);
        };
        assert_eq!(end, Offer::Overflow);
        assert_eq!(queued, MIRROR_INBOX_BYTES / (frame + 5));
        assert_eq!(counters.inbox_overflows.load(Ordering::Relaxed), 1);
        let mut held = 0;
        while let Some(line) = lines.try_recv() {
            held += link_v2::frame_bytes(&line);
        }
        assert_eq!(held as u64, inbox.held());
        assert!(held <= MIRROR_INBOX_BYTES);
    }

    /// A peer within its credit: the mirror takes each frame, and the inbox
    /// never fills however many frames come.
    #[test]
    fn a_peer_within_its_credit_never_fills_the_inbox() {
        let counters = Arc::new(DialCounters::default());
        let (inbox, mut lines) = Inbox::new(7, counters.clone());
        for _ in 0..1000 {
            assert_eq!(inbox.offer(7, line(200 * 1024)), Offer::Queued);
            let line = lines.try_recv().expect("the queued line");
            lines.handed(&line);
        }
        assert_eq!(inbox.held(), 0);
        assert_eq!(counters.inbox_overflows.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn a_line_of_another_link_is_dropped() {
        let counters = Arc::new(DialCounters::default());
        let (inbox, _lines) = Inbox::new(7, counters.clone());
        assert_eq!(inbox.offer(8, line(100)), Offer::Dropped);
        assert_eq!(inbox.held(), 0);
    }

    /// An earlier link's task can hand a line after the next link's inbox
    /// opened (it was inside the adapter's deliver). It takes the bytes off
    /// its own inbox's count: the new inbox's count does not wrap, and it
    /// takes a frame.
    #[test]
    fn an_old_link_handing_a_line_leaves_the_new_inbox_whole() {
        let counters = Arc::new(DialCounters::default());
        let (old, mut old_lines) = Inbox::new(7, counters.clone());
        assert_eq!(old.offer(7, line(100 * 1024)), Offer::Queued);
        let buffered = old_lines.try_recv().expect("the buffered line");
        let (new, mut new_lines) = Inbox::new(8, counters.clone());
        old_lines.handed(&buffered);
        assert_eq!(new.held(), 0);
        assert_eq!(new.offer(8, line(1000)), Offer::Queued);
        assert_eq!(new.held(), 1005);
        assert!(new_lines.try_recv().is_some());
        assert_eq!(counters.inbox_overflows.load(Ordering::Relaxed), 0);
    }
}
