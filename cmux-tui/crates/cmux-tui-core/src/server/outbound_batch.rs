//! Write batching of the line writer (p05-ipc-088): the writer thread takes
//! every ready item, in write order, up to [`WRITE_BATCH_BYTES`] and writes
//! them with one `writev` of their buffers, headers and payloads
//! unconcatenated, as Mojo's `ChannelPosix::WriteOutgoingMessagesWithWritev`
//! (mojo/core/channel_posix.cc) writes its queued messages. Taking items
//! early does not change their order: the batch holds them as single pops
//! would have returned them. A batch ends after a chunk of a frame longer
//! than the chunk size (BULK_FRAME_MAX), so a reply queued while a 32 MiB
//! snapshot leaves waits for at most one chunk of it, as with single pops
//! (p05-ipc-072).

use super::{BoundedOutbound, OutboundItem};
use crate::diagnostics::IpcStats;
use crate::panic_free::RecoverPoison;
use cmux_ipc::HEADER_LEN;
use std::io::{ErrorKind, IoSlice, Write};

#[cfg(test)]
#[path = "outbound_batch_tests.rs"]
mod tests;

/// Bytes one write takes at most: items join a batch while it holds fewer,
/// so the last item may pass the bound and a longer item leaves alone.
pub(super) const WRITE_BATCH_BYTES: usize = 256 * 1024;

/// Items one write takes at most: at two buffers each, a batch stays within
/// `IOV_MAX` (1024 on Linux and macOS), so the kernel takes it in one call.
pub(super) const WRITE_BATCH_ITEMS: usize = 512;

impl BoundedOutbound {
    /// Waits for the next item, then takes it and every item ready behind
    /// it in write order into `batch`, until the batch holds
    /// [`WRITE_BATCH_BYTES`] or [`WRITE_BATCH_ITEMS`]. A flush or a chunk
    /// ends a batch. `false` once the queue is closed and empty.
    pub(in crate::server) fn recv_batch(&self, batch: &mut Vec<OutboundItem>) -> bool {
        batch.clear();
        let mut state = self.state.lock().recover_poison();
        loop {
            if let Some(first) = state.pop() {
                let mut bytes = first.wire_len();
                let mut ends = first.ends_batch();
                batch.push(first);
                while !ends && bytes < WRITE_BATCH_BYTES && batch.len() < WRITE_BATCH_ITEMS {
                    let Some(item) = state.pop() else { break };
                    bytes += item.wire_len();
                    ends = item.ends_batch();
                    batch.push(item);
                }
                drop(state);
                self.changed.notify_all();
                return true;
            }
            if state.closed {
                return false;
            }
            // The writer's idle wait for its own queue (p02-threads 308).
            state = self.changed.idle().wait(state).recover_poison();
        }
    }
}

impl OutboundItem {
    /// The bytes the item puts on the wire: a line with its `\n`, a frame
    /// or a chunk with its header.
    fn wire_len(&self) -> usize {
        match self {
            OutboundItem::Text(text) => text.len() + 1,
            OutboundItem::Frame(header, _) | OutboundItem::Chunk { header, .. } => {
                header.frame_len()
            }
            OutboundItem::Flush(_) => 0,
        }
    }

    fn is_flush(&self) -> bool {
        matches!(self, OutboundItem::Flush(_))
    }

    /// A flush is answered after its batch; a chunk lets the lanes run
    /// again before the next chunk, so a reply passes a long frame.
    fn ends_batch(&self) -> bool {
        matches!(self, OutboundItem::Flush(_) | OutboundItem::Chunk { .. })
    }
}

/// Writes one item as a batch of one.
#[cfg(test)]
pub(in crate::server) fn write_line_outbound_item<W: Write + ?Sized>(
    writer: &mut W,
    item: OutboundItem,
) -> std::io::Result<()> {
    write_line_outbound_batch(writer, std::slice::from_ref(&item))
}

/// Writes one batch of [`BoundedOutbound::recv_batch`], counting each of its
/// messages and each write call in `ipc` (`server-stats` `ipc`).
pub(in crate::server) fn write_counted_batch<W: Write + ?Sized>(
    writer: &mut W,
    ipc: &IpcStats,
    items: &[OutboundItem],
) -> std::io::Result<()> {
    for item in items {
        match item {
            OutboundItem::Text(text) => ipc.line_sent(text.len() + 1),
            OutboundItem::Frame(header, _) | OutboundItem::Chunk { header, .. } => {
                ipc.frame_sent(header.kind(), header.frame_len());
            }
            OutboundItem::Flush(_) => {}
        }
    }
    write_line_outbound_batch(&mut ipc.counted(writer), items)
}

/// Writes `items` in order: the items between flushes as one gathered write
/// each, and at a flush the writer's flush, then its answer.
pub(in crate::server) fn write_line_outbound_batch<W: Write + ?Sized>(
    writer: &mut W,
    items: &[OutboundItem],
) -> std::io::Result<()> {
    let mut rest = items;
    while let Some(at) = rest.iter().position(OutboundItem::is_flush) {
        let (before, after) = rest.split_at(at);
        write_gathered(writer, before)?;
        writer.flush()?;
        if let Some(OutboundItem::Flush(flushed)) = after.first() {
            let _ = flushed.send(());
        }
        rest = after.get(1..).unwrap_or_default();
    }
    write_gathered(writer, rest)
}

/// One `write_vectored` of every buffer of `items`, called again only for
/// what a short write left.
fn write_gathered<W: Write + ?Sized>(
    writer: &mut W,
    items: &[OutboundItem],
) -> std::io::Result<()> {
    let headers = items
        .iter()
        .filter_map(|item| match item {
            OutboundItem::Frame(header, _) | OutboundItem::Chunk { header, .. } => {
                Some(header.encode())
            }
            OutboundItem::Text(_) | OutboundItem::Flush(_) => None,
        })
        .collect::<Vec<[u8; HEADER_LEN]>>();
    let mut headers = headers.iter();
    let mut slices = Vec::with_capacity(items.len() * 2);
    for item in items {
        let (first, second): (&[u8], &[u8]) = match item {
            OutboundItem::Text(text) => (text.as_bytes(), b"\n"),
            OutboundItem::Frame(_, text) => {
                (headers.next().ok_or(ErrorKind::InvalidData)?, text.as_bytes())
            }
            OutboundItem::Chunk { text, range, .. } => (
                headers.next().ok_or(ErrorKind::InvalidData)?,
                text.as_bytes().get(range.clone()).ok_or(ErrorKind::InvalidData)?,
            ),
            OutboundItem::Flush(_) => continue,
        };
        slices.push(IoSlice::new(first));
        slices.push(IoSlice::new(second));
    }
    let mut slices = &mut slices[..];
    IoSlice::advance_slices(&mut slices, 0);
    while !slices.is_empty() {
        match writer.write_vectored(slices) {
            Ok(0) => return Err(ErrorKind::WriteZero.into()),
            Ok(written) => IoSlice::advance_slices(&mut slices, written),
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}
