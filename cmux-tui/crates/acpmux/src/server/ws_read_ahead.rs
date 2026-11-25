//! A WebSocket's reader that keeps reading while the connection is slow to take its frames, so a
//! ping queued behind bulk frames is still answered (RFD 0050 rule 3: "never a ping queued behind
//! bulk traffic").
//!
//! tungstenite answers a ping only when the reader reads it. The listener's reader used to wait
//! on each frame's hand-off (`in_tx.send(..).await`, 256 lines deep, or an upload's drain) before
//! it read the next one, so a peer link whose daemon was busy with its queued lines heard no
//! pong: its dialer read the busy link as silent, flapped it, and grew `SilenceBudget` from load
//! (`peer_link.rs`). Now the frames read while a hand-off waits are held here, in order, up to
//! [`READ_AHEAD_BYTES`] and [`READ_AHEAD_FRAMES`]; pings and pongs are never held, so each is
//! answered as it arrives. Past either bound the reader stops, as before, and the transport's
//! own backpressure holds the sender.

use std::collections::VecDeque;
use std::future::Future;

use futures_util::{Stream, StreamExt};
use tokio_tungstenite::tungstenite::{Error as WsError, Message as Frame};

/// Bytes of frames held while the connection takes an earlier one. One frame may pass it.
pub(crate) const READ_AHEAD_BYTES: usize = 1024 * 1024;
/// Frames held while the connection takes an earlier one.
pub(crate) const READ_AHEAD_FRAMES: usize = 256;

/// Read `source` until it ends, handing each frame but pings and pongs to `deliver`, in order,
/// one at a time; while one is being handed off, later frames are read (and pings answered) up to
/// the bounds above. Stops when `deliver` says false. A read error ends reading: the frames read
/// before it are delivered first, then it is returned.
/// Each hand-off owns what it needs (an `async` closure's borrow is not `Send` for a spawned task).
pub(crate) async fn read_ahead<S, F, H>(mut source: S, mut deliver: F) -> Option<WsError>
where
    S: Stream<Item = Result<Frame, WsError>> + Unpin,
    F: FnMut(Frame) -> H,
    H: Future<Output = bool>,
{
    let mut held: VecDeque<Frame> = VecDeque::new();
    let mut held_bytes = 0usize;
    let mut ended = false;
    let mut error = None;
    loop {
        let frame = match held.pop_front() {
            Some(frame) => {
                held_bytes -= frame.len();
                frame
            }
            None if ended => return error,
            None => match source.next().await {
                Some(Ok(Frame::Ping(_) | Frame::Pong(_))) => continue,
                Some(Ok(frame)) => frame,
                Some(Err(e)) => return Some(e),
                None => return None,
            },
        };
        let handed = deliver(frame);
        tokio::pin!(handed);
        loop {
            let room = !ended && held_bytes < READ_AHEAD_BYTES && held.len() < READ_AHEAD_FRAMES;
            tokio::select! {
                biased;
                more = &mut handed => {
                    if !more {
                        return None;
                    }
                    break;
                }
                next = source.next(), if room => match next {
                    Some(Ok(Frame::Ping(_) | Frame::Pong(_))) => {}
                    Some(Ok(frame)) => {
                        held_bytes += frame.len();
                        held.push_back(frame);
                    }
                    Some(Err(e)) => (ended, error) = (true, Some(e)),
                    None => ended = true,
                },
            }
        }
    }
}

#[cfg(test)]
#[path = "ws_read_ahead_tests.rs"]
mod tests;
