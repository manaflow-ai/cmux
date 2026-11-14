//! The peer's mirror on its link (row 8, part two). When the peer lists
//! `listStream` and this daemon keeps the index, a v2 client on the link
//! feeds the index under the peer's name (`peer_mirror.rs`). Its frames ride
//! the link as `_acpmux/v2` notification lines beside v1's, both ways.
//!
//! The reader loop hands each frame line to the mirror of the link it came on
//! without waiting: the client's credit window bounds what the peer sends
//! ahead, so the reader never stops for the mirror and v1's lines never wait
//! behind it.
use super::*;
use crate::link_v2::{self, Adapter, Slot};
use crate::peer_mirror::DialCounters;

#[derive(Default)]
pub(super) struct MirrorLink {
    /// The daemon's links' v2 handle, read at each link's start: the index
    /// the mirror feeds is there once `acpmux.v2` holds `list` and `peers`.
    links: std::sync::OnceLock<Arc<link_v2::Shared>>,
    /// The link epoch the running mirror reads, and its frame lines' queue.
    inbox: StdMutex<Option<(u64, mpsc::UnboundedSender<String>)>>,
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

    /// A v2 frame line read on `link`: to that link's mirror, or dropped when
    /// it runs none.
    pub(super) fn mirror_frame(&self, link: u64, line: String) {
        let inbox = self.mirror.inbox.lock_or_recover();
        if let Some((epoch, frames)) = inbox.as_ref()
            && *epoch == link
        {
            let _ = frames.send(line);
        }
    }

    /// The link ended: its mirror's queue closes, and the mirror with it.
    pub(super) fn end_mirror(&self) {
        self.mirror.inbox.lock_or_recover().take();
    }

    /// Starts the mirror on `link` once its handshake is done, when the peer
    /// lists the feature and this daemon keeps the index.
    pub(super) fn start_mirror(self: &Arc<Self>, link: u64) {
        let Some(hub) = self.mirror.links.get().and_then(|links| links.v2()).map(|v2| v2.hub())
        else {
            return;
        };
        if !self.lists(link_v2::FEATURE) || self.link_epoch() != link {
            return;
        }
        let (frames, mut inbox) = mpsc::unbounded_channel::<String>();
        *self.mirror.inbox.lock_or_recover() = Some((link, frames));
        let slot = Slot::new(None);
        let (adapter, reader, writer) = Adapter::new(slot.clone());
        let me = self.clone();
        self.scope.spawn_named("peer-mirror", async move {
            let feeding = async {
                while let Some(line) = inbox.recv().await {
                    let Some(frame) = link_v2::parse(&line) else { break };
                    if !adapter.deliver(&frame).await {
                        break;
                    }
                }
                adapter.close();
            };
            let sending = async {
                loop {
                    let line = slot.next().await;
                    if me.link_epoch() != link {
                        break;
                    }
                    if me.out.send(Outbound { epoch: link, key: None, line }).await.is_err() {
                        break;
                    }
                }
            };
            let mirroring =
                crate::peer_mirror::mirror(hub, &me.name, reader, writer, &me.mirror.counters);
            tokio::select! {
                () = feeding => {}
                () = sending => {}
                end = mirroring => match end {
                    Ok(end) => tracing::info!(peer = %me.name, ?end, "the peer's list mirror ended"),
                    Err(error) => tracing::info!(peer = %me.name, %error, "the peer's list mirror ended"),
                },
            }
        });
    }
}
