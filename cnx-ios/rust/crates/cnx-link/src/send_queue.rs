//! What the signaling socket sends next.
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
//! 3. relay input: what the tunnel's pacer sends as interactive
//!    (keystrokes, TCP ACKs, small requests, and terminal output at a
//!    terminal's pace, full-size segments included, so a keystroke can
//!    wait behind a few such segments);
//! 4. relay bulk (large transfers) and media (video): they share what is
//!    left by bytes, whichever sent fewer bytes goes next, so neither
//!    starves the other.
//!
//! Relay classes are bounded by bytes. Past its bound a class drops its
//! oldest frame: relay frames are datagrams, and what they carry (TCP in the
//! tunnel, the media lane's RTP with its own resends) already copes with
//! loss, while a stale frame only delays the fresh ones behind it. Media
//! older than [`MEDIA_MAX_AGE`] is dropped too: a late video packet is
//! worthless.

use std::collections::VecDeque;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use futures_util::{Sink, SinkExt};
use tokio::sync::Notify;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;

use crate::signaling::{RelayClass, SignalingError};

/// Bytes each relay class may hold. Control frames are small (a marker,
/// a 148-byte initiation); input is about 200 keystroke datagrams; bulk is
/// about 200 full-size datagrams, a fifth of a second of a 10 Mbit/s
/// stream: more only adds latency.
pub(crate) const CONTROL_BYTES: usize = 16 * 1024;
pub(crate) const INPUT_BYTES: usize = 64 * 1024;
pub(crate) const BULK_BYTES: usize = 256 * 1024;
pub(crate) const MEDIA_BYTES: usize = 256 * 1024;
/// Media queued longer than this is dropped (the tunnel's own pacer drops
/// media after 50 ms; the relay adds the backend's round trip).
pub(crate) const MEDIA_MAX_AGE: Duration = Duration::from_millis(250);

/// A message that is not a relay frame.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Signal {
    Text(String),
    Ping,
}

#[derive(Default)]
struct Class {
    frames: VecDeque<(Instant, Vec<u8>)>,
    bytes: usize,
    dropped: u64,
}

impl Class {
    /// Queue `frame`, then drop the oldest frames while the class is past
    /// `limit` (a single frame larger than `limit` is still kept).
    fn push(&mut self, frame: Vec<u8>, limit: usize) {
        self.bytes += frame.len();
        self.frames.push_back((Instant::now(), frame));
        while self.bytes > limit && self.frames.len() > 1 {
            let (_, oldest) = self.frames.pop_front().expect("more than one frame");
            self.bytes -= oldest.len();
            self.dropped += 1;
        }
    }

    fn pop(&mut self) -> Option<Vec<u8>> {
        let (_, frame) = self.frames.pop_front()?;
        self.bytes -= frame.len();
        Some(frame)
    }

    /// Drop frames queued longer than `max_age`, oldest first.
    fn expire(&mut self, max_age: Duration) {
        let now = Instant::now();
        while let Some((queued_at, frame)) = self.frames.front()
            && now.saturating_duration_since(*queued_at) > max_age
        {
            self.bytes -= frame.len();
            self.frames.pop_front();
            self.dropped += 1;
        }
    }
}

impl Queues {
    /// Bulk or media, whichever sent fewer bytes while both waited.
    fn pop_bulk_or_media(&mut self) -> Option<Vec<u8>> {
        let (bulk, media) = (index(RelayClass::Bulk), index(RelayClass::Media));
        self.relay[media].expire(MEDIA_MAX_AGE);
        let both = !self.relay[bulk].frames.is_empty() && !self.relay[media].frames.is_empty();
        let from =
            if self.relay[media].frames.is_empty() || (both && self.bulk_lead <= 0) { bulk } else { media };
        let frame = self.relay[from].pop()?;
        if both {
            let len = frame.len() as i64;
            self.bulk_lead += if from == bulk { len } else { -len };
        } else {
            self.bulk_lead = 0;
        }
        Some(frame)
    }
}

#[derive(Default)]
struct Queues {
    signals: VecDeque<Signal>,
    relay: [Class; 4],
    /// Bytes bulk sent minus bytes media sent while both had frames queued.
    bulk_lead: i64,
    /// Close requested: what is still queued is not sent.
    closing: bool,
    /// The writer is gone: nothing is accepted any more.
    closed: bool,
}

fn index(class: RelayClass) -> usize {
    match class {
        RelayClass::Control => 0,
        RelayClass::Input => 1,
        RelayClass::Bulk => 2,
        RelayClass::Media => 3,
    }
}

fn limit(class: RelayClass) -> usize {
    match class {
        RelayClass::Control => CONTROL_BYTES,
        RelayClass::Input => INPUT_BYTES,
        RelayClass::Bulk => BULK_BYTES,
        RelayClass::Media => MEDIA_BYTES,
    }
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
        {
            let mut queues = self.lock();
            if queues.closed || queues.closing {
                return Err(SignalingError::Closed);
            }
            queues.signals.push_back(signal);
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
            queues.relay[index(class)].push(frame, limit(class));
        }
        self.ready.notify_one();
        Ok(())
    }

    /// Ask the writer to close the socket once the signals already queued
    /// are sent.
    pub(crate) fn close(&self) {
        self.lock().closing = true;
        self.ready.notify_one();
    }

    /// Relay frames of `class` dropped so far.
    pub(crate) fn dropped(&self, class: RelayClass) -> u64 {
        self.lock().relay[index(class)].dropped
    }

    /// Relay bytes of `class` waiting.
    #[cfg(test)]
    pub(crate) fn queued_bytes(&self, class: RelayClass) -> usize {
        self.lock().relay[index(class)].bytes
    }

    /// The next message, by priority; `Some(None)` once closing and the
    /// signals queued before the close are out (relay frames are dropped).
    fn pop(&self) -> Option<Option<Message>> {
        let mut queues = self.lock();
        if let Some(signal) = queues.signals.pop_front() {
            return Some(Some(match signal {
                Signal::Text(text) => Message::Text(text.into()),
                Signal::Ping => Message::Ping(Vec::new().into()),
            }));
        }
        if queues.closing {
            return Some(None);
        }
        let frame = queues.relay[..2].iter_mut().find_map(Class::pop).or_else(|| queues.pop_bulk_or_media());
        frame.map(|frame| Some(Message::Binary(frame.into())))
    }

    fn finish(&self) {
        let mut queues = self.lock();
        queues.closed = true;
        queues.signals.clear();
        for class in &mut queues.relay {
            class.frames.clear();
            class.bytes = 0;
        }
    }

    /// Send what is queued on `sink`, by priority, until a close or a send
    /// fails; then close the sink.
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

    #[test]
    fn bulk_and_media_share_the_socket_by_bytes() {
        let queue = SendQueue::default();
        for _ in 0..100 {
            queue.push_relay(vec![0xB0; 1200], RelayClass::Bulk).unwrap();
            queue.push_relay(vec![0x3D; 600], RelayClass::Media).unwrap();
        }
        let (mut bulk, mut media) = (0usize, 0usize);
        for _ in 0..60 {
            match queue.pop() {
                Some(Some(Message::Binary(frame))) if frame[0] == 0xB0 => bulk += frame.len(),
                Some(Some(Message::Binary(frame))) if frame[0] == 0x3D => media += frame.len(),
                other => panic!("unexpected {other:?}"),
            }
        }
        // Neither class starves the other: their bytes stay within a frame.
        assert!(bulk.abs_diff(media) <= 1200, "bulk {bulk} bytes, media {media} bytes");
        // Media is bounded and drops its oldest like bulk.
        for _ in 0..1000 {
            queue.push_relay(vec![0x3D; 1200], RelayClass::Media).unwrap();
        }
        assert!(queue.queued_bytes(RelayClass::Media) <= MEDIA_BYTES);
        assert!(queue.dropped(RelayClass::Media) > 0);
    }

    #[tokio::test(start_paused = true)]
    async fn stale_media_is_dropped() {
        let queue = SendQueue::default();
        queue.push_relay(vec![0x3D; 600], RelayClass::Media).unwrap();
        tokio::time::advance(MEDIA_MAX_AGE + Duration::from_millis(1)).await;
        queue.push_relay(vec![0x3E; 600], RelayClass::Media).unwrap();
        assert_eq!(queue.pop(), Some(Some(Message::Binary(vec![0x3E; 600].into()))));
        assert_eq!(queue.dropped(RelayClass::Media), 1);
        assert_eq!(queue.pop(), None);
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
