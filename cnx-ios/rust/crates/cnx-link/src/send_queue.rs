//! What the signaling socket sends next.
//!
//! RED: still the old unbounded first-in-first-out queue; the tests below
//! describe the priority order and bounds the next commit implements.
//!
//! One WebSocket carries both signaling (JSON text: offers, answers, ICE,
//! `wg-*`, `bye`) and the WireGuard relay frames. Until a direct route is
//! confirmed every WireGuard datagram, video included, is also copied onto
//! the relay, so the socket can be offered far more than it can send. The
//! writer therefore takes, in strict priority:
//!
//! 1. signals and socket pings: never dropped, never behind a relay frame;
//! 2. relay control: the "your UDP reaches me" marker, handshake messages
//!    and keepalives (they confirm and keep the route);
//! 3. relay input: small data datagrams (keystrokes, TCP ACKs, small
//!    requests);
//! 4. relay bulk: full-size data datagrams (terminal output, files, video).
//!
//! Relay classes are bounded by bytes. Past its bound a class drops its
//! oldest frame: relay frames are datagrams, and what they carry (TCP in the
//! tunnel, the media lane's RTP with its own resends) already copes with
//! loss, while a stale frame only delays the fresh ones behind it.

use std::collections::VecDeque;
use std::sync::{Mutex, PoisonError};

use futures_util::{Sink, SinkExt};
use tokio::sync::Notify;
use tokio_tungstenite::tungstenite::Message;

use crate::signaling::{RelayClass, SignalingError};

/// Bytes each relay class may hold. Control frames are small (a marker,
/// a 148-byte initiation); input is about 200 keystroke datagrams; bulk is
/// about 200 full-size datagrams, a fifth of a second of a 10 Mbit/s
/// stream: more only adds latency.
pub(crate) const CONTROL_BYTES: usize = 16 * 1024;
pub(crate) const INPUT_BYTES: usize = 64 * 1024;
pub(crate) const BULK_BYTES: usize = 256 * 1024;

/// A message that is not a relay frame.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Signal {
    Text(String),
    Ping,
}

#[derive(Default)]
struct Queues {
    /// Everything, in the order it was queued (the old unbounded channel).
    all: VecDeque<(Option<RelayClass>, Message)>,
    closing: bool,
    closed: bool,
}

/// The outgoing side of one signaling socket.
#[derive(Default)]
pub(crate) struct SendQueue {
    queues: Mutex<Queues>,
    ready: Notify,
}

impl SendQueue {
    fn lock(&self) -> std::sync::MutexGuard<'_, Queues> {
        self.queues.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn push_signal(&self, signal: Signal) -> Result<(), SignalingError> {
        let message = match signal {
            Signal::Text(text) => Message::Text(text.into()),
            Signal::Ping => Message::Ping(Vec::new().into()),
        };
        {
            let mut queues = self.lock();
            if queues.closed || queues.closing {
                return Err(SignalingError::Closed);
            }
            queues.all.push_back((None, message));
        }
        self.ready.notify_one();
        Ok(())
    }

    pub(crate) fn push_relay(&self, frame: Vec<u8>, class: RelayClass) -> Result<(), SignalingError> {
        {
            let mut queues = self.lock();
            if queues.closed || queues.closing {
                return Err(SignalingError::Closed);
            }
            queues.all.push_back((Some(class), Message::Binary(frame.into())));
        }
        self.ready.notify_one();
        Ok(())
    }

    pub(crate) fn close(&self) {
        self.lock().closing = true;
        self.ready.notify_one();
    }

    pub(crate) fn dropped(&self, _class: RelayClass) -> u64 {
        0
    }

    pub(crate) fn queued_bytes(&self, class: RelayClass) -> usize {
        self.lock().all.iter().filter(|(c, _)| *c == Some(class)).map(|(_, m)| m.len()).sum()
    }

    fn pop(&self) -> Option<Option<Message>> {
        let mut queues = self.lock();
        if let Some((_, message)) = queues.all.pop_front() {
            return Some(Some(message));
        }
        if queues.closing {
            return Some(None);
        }
        None
    }

    fn finish(&self) {
        let mut queues = self.lock();
        queues.closed = true;
        queues.all.clear();
    }

    pub(crate) async fn write_out<S>(&self, mut sink: S)
    where
        S: Sink<Message> + Unpin,
    {
        loop {
            let message = loop {
                let ready = self.ready.notified();
                if let Some(message) = self.pop() {
                    break message;
                }
                ready.await;
            };
            let Some(message) = message else { break };
            if sink.send(message).await.is_err() {
                break;
            }
        }
        self.finish();
        let _ = sink.close().await;
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::*;

    /// A sink that takes one message per permit, so the writer backs up as
    /// on a slow uplink.
    fn gated_sink(
        permits: Arc<tokio::sync::Semaphore>,
        sent: tokio::sync::mpsc::UnboundedSender<Message>,
    ) -> impl Sink<Message, Error = ()> + Unpin {
        Box::pin(futures_util::sink::unfold(
            (permits, sent),
            |(permits, sent), message: Message| async move {
                permits.acquire().await.map_err(|_| ())?.forget();
                sent.send(message).map_err(|_| ())?;
                Ok::<_, ()>((permits, sent))
            },
        ))
    }

    async fn next(sent: &mut tokio::sync::mpsc::UnboundedReceiver<Message>) -> Message {
        tokio::time::timeout(Duration::from_secs(5), sent.recv()).await.expect("a message").expect("open")
    }

    #[tokio::test]
    async fn signaling_and_the_marker_never_wait_behind_bulk() {
        let queue = Arc::new(SendQueue::default());
        let permits = Arc::new(tokio::sync::Semaphore::new(0));
        let (sent_tx, mut sent) = tokio::sync::mpsc::unbounded_channel();
        let writer = tokio::spawn({
            let (queue, permits) = (Arc::clone(&queue), Arc::clone(&permits));
            async move { queue.write_out(gated_sink(permits, sent_tx)).await }
        });
        // A video burst is queued, then a keystroke, a marker and a signal.
        for _ in 0..2000 {
            queue.push_relay(vec![0xB0; 1200], RelayClass::Bulk).unwrap();
        }
        queue.push_relay(vec![0x1E; 120], RelayClass::Input).unwrap();
        queue.push_relay(vec![0xFF], RelayClass::Control).unwrap();
        queue.push_signal(Signal::Text("bye".into())).unwrap();
        // The writer may already hold one bulk frame; everything else
        // queued comes out signal, marker, input, then bulk.
        permits.add_permits(5);
        let mut order = Vec::new();
        for _ in 0..5 {
            order.push(next(&mut sent).await);
        }
        let position = |wanted: &Message| order.iter().position(|message| message == wanted);
        let signal = position(&Message::Text("bye".into())).expect("the signal was sent");
        let marker = position(&Message::Binary(vec![0xFF].into())).expect("the marker was sent");
        let input = position(&Message::Binary(vec![0x1E; 120].into())).expect("the input was sent");
        assert!(signal <= 1 && marker <= 2 && input <= 3, "sent in this order: {order:?}");
        assert!(signal < marker && marker < input, "{order:?}");
        queue.close();
        permits.close();
        writer.await.unwrap();
    }

    #[test]
    fn relay_classes_are_bounded_and_drop_their_oldest() {
        let queue = SendQueue::default();
        for index in 0..2000u32 {
            let mut frame = vec![0u8; 1200];
            frame[..4].copy_from_slice(&index.to_be_bytes());
            queue.push_relay(frame, RelayClass::Bulk).unwrap();
        }
        for _ in 0..10 {
            queue.push_relay(vec![1; 120], RelayClass::Input).unwrap();
        }
        assert!(queue.queued_bytes(RelayClass::Bulk) <= BULK_BYTES);
        assert!(queue.dropped(RelayClass::Bulk) > 1500, "{}", queue.dropped(RelayClass::Bulk));
        // Bulk never pushes out input.
        assert_eq!(queue.dropped(RelayClass::Input), 0);
        assert_eq!(queue.queued_bytes(RelayClass::Input), 1200);
        // The newest bulk frames are the ones kept.
        let mut last = None;
        while let Some(Some(Message::Binary(frame))) = queue.pop() {
            if frame.len() == 1200 {
                last = Some(u32::from_be_bytes(frame[..4].try_into().unwrap()));
            }
        }
        assert_eq!(last, Some(1999));
    }

    #[tokio::test]
    async fn a_closed_queue_refuses_frames() {
        let queue = Arc::new(SendQueue::default());
        let (sent_tx, _sent) = tokio::sync::mpsc::unbounded_channel();
        let permits = Arc::new(tokio::sync::Semaphore::new(100));
        queue.push_relay(vec![0; 1200], RelayClass::Bulk).unwrap();
        queue.close();
        queue.write_out(gated_sink(permits, sent_tx)).await;
        assert!(queue.push_signal(Signal::Ping).is_err());
        assert!(queue.push_relay(vec![0], RelayClass::Control).is_err());
        assert_eq!(queue.queued_bytes(RelayClass::Bulk), 0);
    }
}
