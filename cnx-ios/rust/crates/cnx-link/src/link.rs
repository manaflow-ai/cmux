//! One link: a reliable ordered byte stream carrying multiplexed channels
//! (PROTOCOL.md "Link"). The transport underneath (a WebRTC data channel or
//! a TCP stream inside WireGuard) is invisible here.

use std::any::Any;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tokio_util::codec::{FramedRead, FramedWrite};

use crate::frame::{Frame, FrameCodec, FrameType, MAX_PAYLOAD};

/// Events queued per channel before the link reader waits for the owner.
const CHANNEL_DEPTH: usize = 1024;
/// Frames queued for the writer.
const WRITE_DEPTH: usize = 1024;
/// Control frames (ping, pong) queued ahead of data. A keepalive ping must
/// not wait behind megabytes of queued channel data: on a 4 Mbit/s relay a
/// 10 MiB write held the ping for 20 s and closed a healthy link.
const CONTROL_DEPTH: usize = 64;

/// Which end of the link this is: the phone opens odd channel ids, the Mac
/// even ones. Channel 0 carries pings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Phone,
    Mac,
}

impl Role {
    fn first_channel(self) -> u32 {
        match self {
            Self::Phone => 1,
            Self::Mac => 2,
        }
    }

    /// Whether the peer may open `channel`.
    fn peer_owns(self, channel: u32) -> bool {
        channel != 0
            && match self {
                Self::Phone => channel.is_multiple_of(2),
                Self::Mac => !channel.is_multiple_of(2),
            }
    }
}

#[derive(Debug, Clone)]
pub struct LinkConfig {
    /// Interval between keepalive pings; `None` disables them.
    pub keepalive: Option<Duration>,
    /// How long the link may go without receiving anything (a pong or any
    /// other frame) after a keepalive ping before it closes.
    pub keepalive_timeout: Duration,
}

impl Default for LinkConfig {
    fn default() -> Self {
        Self { keepalive: Some(Duration::from_secs(15)), keepalive_timeout: Duration::from_secs(20) }
    }
}

/// `open` payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenRequest {
    pub service: String,
    #[serde(default)]
    pub args: serde_json::Value,
}

/// `close` payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloseInfo {
    pub code: String,
    #[serde(default)]
    pub reason: String,
}

impl CloseInfo {
    pub fn new(code: impl Into<String>, reason: impl Into<String>) -> Self {
        Self { code: code.into(), reason: reason.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelEvent {
    Data(Bytes),
    Closed(CloseInfo),
}

#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum LinkError {
    #[error("the link is closed: {0}")]
    Closed(String),
    #[error("the channel is closed")]
    ChannelClosed,
    #[error("timed out")]
    Timeout,
}

enum WriterMsg {
    Frame(Frame),
    Shutdown,
}

struct Inner {
    role: Role,
    out: mpsc::Sender<WriterMsg>,
    /// Ping and pong frames; the writer sends these before queued data.
    control: mpsc::Sender<Frame>,
    /// When the reader last received a frame. Any inbound frame proves the
    /// peer is alive, so a busy link never times out on a slow pong.
    last_rx: Mutex<Instant>,
    channels: Mutex<HashMap<u32, mpsc::Sender<ChannelEvent>>>,
    next_channel: AtomicU32,
    next_nonce: AtomicU64,
    pings: Mutex<HashMap<u64, oneshot::Sender<Instant>>>,
    rtt: watch::Sender<Option<Duration>>,
    closed: watch::Sender<Option<String>>,
    incoming: tokio::sync::Mutex<mpsc::Receiver<IncomingChannel>>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
    /// Keeps the transport (peer connection, tunnel) alive with the link.
    transport: Mutex<Option<Box<dyn Any + Send>>>,
}

impl Inner {
    fn lock_channels(&self) -> std::sync::MutexGuard<'_, HashMap<u32, mpsc::Sender<ChannelEvent>>> {
        self.channels.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn closed_reason(&self) -> Option<String> {
        self.closed.borrow().clone()
    }

    async fn send_frame(&self, frame: Frame) -> Result<(), LinkError> {
        if let Some(reason) = self.closed_reason() {
            return Err(LinkError::Closed(reason));
        }
        self.out
            .send(WriterMsg::Frame(frame))
            .await
            .map_err(|_| LinkError::Closed(self.closed_reason().unwrap_or_else(|| "writer stopped".into())))
    }

    fn try_send_frame(&self, frame: Frame) {
        let _ = self.out.try_send(WriterMsg::Frame(frame));
    }

    /// Queue a ping or pong ahead of channel data.
    async fn send_control(&self, frame: Frame) -> Result<(), LinkError> {
        if let Some(reason) = self.closed_reason() {
            return Err(LinkError::Closed(reason));
        }
        self.control
            .send(frame)
            .await
            .map_err(|_| LinkError::Closed(self.closed_reason().unwrap_or_else(|| "writer stopped".into())))
    }

    fn received(&self) {
        *self.last_rx.lock().unwrap_or_else(PoisonError::into_inner) = Instant::now();
    }

    fn last_received(&self) -> Instant {
        *self.last_rx.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Mark the link closed (once) and tell every channel.
    fn shut(&self, reason: &str) {
        let first = self.closed.send_if_modified(|state| {
            if state.is_none() {
                *state = Some(reason.to_owned());
                true
            } else {
                false
            }
        });
        if !first {
            return;
        }
        tracing::debug!(reason, "link closed");
        let channels: Vec<_> = self.lock_channels().drain().map(|(_, tx)| tx).collect();
        for tx in channels {
            let _ = tx.try_send(ChannelEvent::Closed(CloseInfo::new("link_closed", reason)));
        }
        self.pings.lock().unwrap_or_else(PoisonError::into_inner).clear();
        let _ = self.out.try_send(WriterMsg::Shutdown);
        // Dropping the transport tears down the peer connection or tunnel.
        let transport = self.transport.lock().unwrap_or_else(PoisonError::into_inner).take();
        drop(transport);
    }
}

/// A channel the peer opened.
pub struct IncomingChannel {
    pub service: String,
    pub args: serde_json::Value,
    pub channel: Channel,
}

/// A running link. Cheap to clone; every clone is the same link. Call
/// [`Link::close`] to end it; it also ends when the transport does.
#[derive(Clone)]
pub struct Link {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for Link {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Link").field("role", &self.inner.role).finish_non_exhaustive()
    }
}

impl Link {
    /// Run a link over `stream`. `transport` is kept alive until the link
    /// closes (a peer connection, a tunnel, a task guard).
    pub fn new<S>(stream: S, role: Role, config: LinkConfig, transport: Option<Box<dyn Any + Send>>) -> Self
    where
        S: AsyncRead + AsyncWrite + Send + 'static,
    {
        let (read_half, write_half) = tokio::io::split(stream);
        let (out_tx, out_rx) = mpsc::channel(WRITE_DEPTH);
        let (control_tx, control_rx) = mpsc::channel(CONTROL_DEPTH);
        let (incoming_tx, incoming_rx) = mpsc::channel(64);
        let inner = Arc::new(Inner {
            role,
            out: out_tx,
            control: control_tx,
            last_rx: Mutex::new(Instant::now()),
            channels: Mutex::new(HashMap::new()),
            next_channel: AtomicU32::new(role.first_channel()),
            next_nonce: AtomicU64::new(1),
            pings: Mutex::new(HashMap::new()),
            rtt: watch::channel(None).0,
            closed: watch::channel(None).0,
            incoming: tokio::sync::Mutex::new(incoming_rx),
            tasks: Mutex::new(Vec::new()),
            transport: Mutex::new(transport),
        });
        let writer = tokio::spawn(write_loop(
            Arc::clone(&inner),
            FramedWrite::new(write_half, FrameCodec),
            out_rx,
            control_rx,
        ));
        let reader =
            tokio::spawn(read_loop(Arc::clone(&inner), FramedRead::new(read_half, FrameCodec), incoming_tx));
        let mut tasks = vec![writer, reader];
        if let Some(interval) = config.keepalive {
            let link = Self { inner: Arc::clone(&inner) };
            tasks.push(tokio::spawn(async move {
                let mut closed = link.inner.closed.subscribe();
                loop {
                    tokio::select! {
                        () = tokio::time::sleep(interval) => {}
                        _ = closed.wait_for(Option::is_some) => return,
                    }
                    let sent = Instant::now();
                    let ping = link.ping();
                    tokio::pin!(ping);
                    loop {
                        // Wait for the pong, but count any inbound frame as
                        // life: a pong can trail a full transmit queue.
                        let deadline = link.inner.last_received().max(sent) + config.keepalive_timeout;
                        tokio::select! {
                            result = &mut ping => {
                                if result.is_err() {
                                    return;
                                }
                                break;
                            }
                            () = tokio::time::sleep_until(deadline) => {
                                let quiet_since = link.inner.last_received().max(sent);
                                if quiet_since + config.keepalive_timeout <= Instant::now() {
                                    link.inner.shut("keepalive timed out");
                                    return;
                                }
                            }
                        }
                    }
                }
            }));
        }
        *inner.tasks.lock().unwrap_or_else(PoisonError::into_inner) = tasks;
        Self { inner }
    }

    pub fn role(&self) -> Role {
        self.inner.role
    }

    /// Open a channel to `service`. A refusal arrives as a `Closed` event.
    pub async fn open(&self, service: &str, args: serde_json::Value) -> Result<Channel, LinkError> {
        let id = self.inner.next_channel.fetch_add(2, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel(CHANNEL_DEPTH);
        self.inner.lock_channels().insert(id, tx);
        let payload = serde_json::to_vec(&OpenRequest { service: service.to_owned(), args })
            .expect("open request serializes");
        if let Err(error) = self.inner.send_frame(Frame::new(id, FrameType::Open, payload)).await {
            self.inner.lock_channels().remove(&id);
            return Err(error);
        }
        Ok(Channel::new(id, Arc::clone(&self.inner), rx))
    }

    /// The next channel the peer opened, or `None` once the link is closed.
    pub async fn accept(&self) -> Option<IncomingChannel> {
        self.inner.incoming.lock().await.recv().await
    }

    /// Round-trip one ping.
    pub async fn ping(&self) -> Result<Duration, LinkError> {
        let nonce = self.inner.next_nonce.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.inner.pings.lock().unwrap_or_else(PoisonError::into_inner).insert(nonce, tx);
        let started = Instant::now();
        self.inner.send_control(Frame::new(0, FrameType::Ping, nonce.to_be_bytes().to_vec())).await?;
        let answered = rx
            .await
            .map_err(|_| LinkError::Closed(self.inner.closed_reason().unwrap_or_else(|| "closed".into())))?;
        let rtt = answered.saturating_duration_since(started);
        self.inner.rtt.send_replace(Some(rtt));
        Ok(rtt)
    }

    /// The latest measured round-trip time.
    pub fn rtt(&self) -> watch::Receiver<Option<Duration>> {
        self.inner.rtt.subscribe()
    }

    /// `Some(reason)` once closed.
    pub fn closed_state(&self) -> watch::Receiver<Option<String>> {
        self.inner.closed.subscribe()
    }

    pub fn is_closed(&self) -> bool {
        self.inner.closed_reason().is_some()
    }

    /// Resolves with the reason once the link is closed.
    pub async fn closed(&self) -> String {
        let mut state = self.inner.closed.subscribe();
        match state.wait_for(Option::is_some).await {
            Ok(reason) => reason.clone().unwrap_or_default(),
            Err(_) => "closed".into(),
        }
    }

    /// Close the link and its transport.
    pub fn close(&self, reason: &str) {
        self.inner.shut(reason);
    }
}

async fn write_loop<W>(
    inner: Arc<Inner>,
    mut sink: FramedWrite<W, FrameCodec>,
    mut rx: mpsc::Receiver<WriterMsg>,
    mut control: mpsc::Receiver<Frame>,
) where
    W: AsyncWrite + Send + Unpin,
{
    loop {
        // Control frames first, then data; feed what is queued, flush once.
        let message = tokio::select! {
            biased;
            Some(frame) = control.recv() => WriterMsg::Frame(frame),
            message = rx.recv() => match message {
                Some(message) => message,
                None => return,
            },
        };
        let WriterMsg::Frame(frame) = message else {
            let _ = sink.close().await;
            return;
        };
        let mut result = sink.feed(frame).await;
        while result.is_ok() {
            if let Ok(frame) = control.try_recv() {
                result = sink.feed(frame).await;
                continue;
            }
            match rx.try_recv() {
                Ok(WriterMsg::Frame(frame)) => result = sink.feed(frame).await,
                Ok(WriterMsg::Shutdown) => {
                    let _ = sink.flush().await;
                    let _ = sink.close().await;
                    return;
                }
                Err(_) => break,
            }
        }
        if let Err(error) = result.and(sink.flush().await) {
            inner.shut(&format!("write failed: {error}"));
            return;
        }
    }
}

async fn read_loop<R>(
    inner: Arc<Inner>,
    mut source: FramedRead<R, FrameCodec>,
    incoming: mpsc::Sender<IncomingChannel>,
) where
    R: AsyncRead + Send + Unpin,
{
    let reason = loop {
        let frame = match source.next().await {
            Some(Ok(frame)) => frame,
            Some(Err(error)) => break format!("read failed: {error}"),
            None => break "peer closed the link".to_owned(),
        };
        inner.received();
        match frame.kind {
            FrameType::Ping => {
                let _ = inner.control.try_send(Frame::new(0, FrameType::Pong, frame.payload));
            }
            FrameType::Pong => {
                if let Ok(bytes) = <[u8; 8]>::try_from(&frame.payload[..]) {
                    let nonce = u64::from_be_bytes(bytes);
                    let waiter = inner.pings.lock().unwrap_or_else(PoisonError::into_inner).remove(&nonce);
                    if let Some(waiter) = waiter {
                        let _ = waiter.send(Instant::now());
                    }
                }
            }
            FrameType::Open => {
                if !inner.role.peer_owns(frame.channel) || inner.lock_channels().contains_key(&frame.channel)
                {
                    refuse(&inner, frame.channel, "bad_channel", "channel id is not the peer's or in use");
                    continue;
                }
                let Ok(request) = serde_json::from_slice::<OpenRequest>(&frame.payload) else {
                    refuse(&inner, frame.channel, "bad_request", "open payload is not JSON");
                    continue;
                };
                let (tx, rx) = mpsc::channel(CHANNEL_DEPTH);
                inner.lock_channels().insert(frame.channel, tx);
                let channel = Channel::new(frame.channel, Arc::clone(&inner), rx);
                let accepted = IncomingChannel { service: request.service, args: request.args, channel };
                if incoming.send(accepted).await.is_err() {
                    // Nobody accepts; the channel's drop refuses it.
                }
            }
            FrameType::Data => {
                let tx = inner.lock_channels().get(&frame.channel).cloned();
                if let Some(tx) = tx
                    && tx.send(ChannelEvent::Data(frame.payload)).await.is_err()
                {
                    inner.lock_channels().remove(&frame.channel);
                }
            }
            FrameType::Close => {
                let info = serde_json::from_slice::<CloseInfo>(&frame.payload)
                    .unwrap_or_else(|_| CloseInfo::new("closed", ""));
                let tx = inner.lock_channels().remove(&frame.channel);
                if let Some(tx) = tx {
                    let _ = tx.send(ChannelEvent::Closed(info)).await;
                }
            }
        }
    };
    inner.shut(&reason);
}

fn refuse(inner: &Inner, channel: u32, code: &str, reason: &str) {
    let payload = serde_json::to_vec(&CloseInfo::new(code, reason)).expect("close serializes");
    inner.try_send_frame(Frame::new(channel, FrameType::Close, payload));
}

/// Sending half of a channel.
pub struct ChannelSender {
    id: u32,
    inner: Arc<Inner>,
    closed: AtomicBool,
}

impl ChannelSender {
    pub fn id(&self) -> u32 {
        self.id
    }

    /// Send bytes; large writes are split into several frames.
    pub async fn send(&self, data: Bytes) -> Result<(), LinkError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::ChannelClosed);
        }
        if data.is_empty() {
            return Ok(());
        }
        let mut rest = data;
        while !rest.is_empty() {
            let chunk = rest.split_to(rest.len().min(MAX_PAYLOAD));
            self.inner.send_frame(Frame::new(self.id, FrameType::Data, chunk)).await?;
        }
        Ok(())
    }

    /// Close the channel with `code` and `reason`. Idempotent.
    pub async fn close(&self, code: &str, reason: &str) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.inner.lock_channels().remove(&self.id);
        let payload = serde_json::to_vec(&CloseInfo::new(code, reason)).expect("close serializes");
        let _ = self.inner.send_frame(Frame::new(self.id, FrameType::Close, payload)).await;
    }
}

impl Drop for ChannelSender {
    fn drop(&mut self) {
        if !self.closed.swap(true, Ordering::AcqRel) {
            self.inner.lock_channels().remove(&self.id);
            refuse(&self.inner, self.id, "dropped", "");
        }
    }
}

/// Receiving half of a channel.
pub struct ChannelReceiver {
    rx: mpsc::Receiver<ChannelEvent>,
    done: bool,
}

impl ChannelReceiver {
    /// The next event; `None` after `Closed` was delivered.
    pub async fn recv(&mut self) -> Option<ChannelEvent> {
        if self.done {
            return None;
        }
        match self.rx.recv().await {
            Some(event) => {
                if matches!(event, ChannelEvent::Closed(_)) {
                    self.done = true;
                }
                Some(event)
            }
            None => {
                self.done = true;
                Some(ChannelEvent::Closed(CloseInfo::new("link_closed", "")))
            }
        }
    }
}

/// One multiplexed channel.
pub struct Channel {
    pub sender: ChannelSender,
    pub receiver: ChannelReceiver,
}

impl Channel {
    fn new(id: u32, inner: Arc<Inner>, rx: mpsc::Receiver<ChannelEvent>) -> Self {
        Self {
            sender: ChannelSender { id, inner, closed: AtomicBool::new(false) },
            receiver: ChannelReceiver { rx, done: false },
        }
    }

    pub fn id(&self) -> u32 {
        self.sender.id
    }

    pub fn split(self) -> (ChannelSender, ChannelReceiver) {
        (self.sender, self.receiver)
    }

    pub async fn send(&self, data: impl Into<Bytes>) -> Result<(), LinkError> {
        self.sender.send(data.into()).await
    }

    pub async fn recv(&mut self) -> Option<ChannelEvent> {
        self.receiver.recv().await
    }

    pub async fn close(&self, code: &str, reason: &str) {
        self.sender.close(code, reason).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (Link, Link) {
        let (a, b) = tokio::io::duplex(64 * 1024);
        (
            Link::new(a, Role::Phone, LinkConfig::default(), None),
            Link::new(b, Role::Mac, LinkConfig::default(), None),
        )
    }

    #[tokio::test]
    async fn open_echo_close_and_ping() {
        let (phone, mac) = pair();
        let server = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("incoming");
            assert_eq!(incoming.service, "echo");
            assert_eq!(incoming.args["x"], 1);
            assert_eq!(incoming.channel.id() % 2, 1);
            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                incoming.channel.send(bytes).await.unwrap();
            }
            mac
        });
        let mut channel = phone.open("echo", serde_json::json!({"x": 1})).await.unwrap();
        let big = Bytes::from(vec![7u8; MAX_PAYLOAD * 2 + 3]);
        channel.send(big.clone()).await.unwrap();
        let mut got = Vec::new();
        while got.len() < big.len() {
            match channel.recv().await.unwrap() {
                ChannelEvent::Data(bytes) => got.extend_from_slice(&bytes),
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(&got[..], &big[..]);
        assert!(phone.ping().await.unwrap() < Duration::from_secs(1));
        channel.close("done", "").await;
        let mac = server.await.unwrap();
        phone.close("bye");
        assert_eq!(mac.closed().await, "peer closed the link");
    }

    /// A stream that accepts at most `chunk` bytes every `pause`, like a
    /// slow relay path.
    struct Throttled {
        inner: tokio::io::DuplexStream,
        chunk: usize,
        pause: Duration,
        sleep: Option<std::pin::Pin<Box<tokio::time::Sleep>>>,
    }

    impl AsyncRead for Throttled {
        fn poll_read(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_read(cx, buf)
        }
    }

    impl AsyncWrite for Throttled {
        fn poll_write(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
            buf: &[u8],
        ) -> std::task::Poll<std::io::Result<usize>> {
            use std::task::Poll;
            if let Some(sleep) = self.sleep.as_mut() {
                if sleep.as_mut().poll(cx).is_pending() {
                    return Poll::Pending;
                }
                self.sleep = None;
            }
            let len = buf.len().min(self.chunk);
            let result = std::pin::Pin::new(&mut self.inner).poll_write(cx, &buf[..len]);
            if matches!(result, Poll::Ready(Ok(_))) {
                let pause = self.pause;
                self.sleep = Some(Box::pin(tokio::time::sleep(pause)));
            }
            result
        }

        fn poll_flush(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_flush(cx)
        }

        fn poll_shutdown(
            mut self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
        }
    }

    use std::future::Future;

    /// A ping must not queue behind bulk data: on a slow relay a 10 MiB
    /// echo held the keepalive ping for 20 s and closed the link.
    #[tokio::test]
    async fn ping_overtakes_queued_bulk_data() {
        let (a, b) = tokio::io::duplex(64 * 1024);
        // About 1.6 MB/s from the phone.
        let a = Throttled { inner: a, chunk: 16 * 1024, pause: Duration::from_millis(10), sleep: None };
        let config = LinkConfig { keepalive: None, ..LinkConfig::default() };
        let phone = Link::new(a, Role::Phone, config.clone(), None);
        let mac = Link::new(b, Role::Mac, config, None);
        let sink = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("incoming");
            let mut total = 0;
            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                total += bytes.len();
            }
            (mac, total)
        });
        let channel = phone.open("sink", serde_json::json!({})).await.unwrap();
        // 4 MiB queued takes about 2.6 s to drain.
        for _ in 0..64 {
            channel.send(Bytes::from(vec![1u8; 64 * 1024])).await.unwrap();
        }
        let started = Instant::now();
        let rtt = phone.ping().await.unwrap();
        assert!(rtt < Duration::from_millis(1500), "ping waited {rtt:?} behind queued data");
        assert!(started.elapsed() < Duration::from_millis(1500));
        drop(channel);
        phone.close("done");
        let _ = sink.await;
    }

    /// Any inbound frame proves the peer is alive: a link receiving data
    /// stays up even when no pong comes back, and closes once it goes quiet.
    #[tokio::test]
    async fn keepalive_counts_any_inbound_frame() {
        let (a, b) = tokio::io::duplex(1024 * 1024);
        let config = LinkConfig {
            keepalive: Some(Duration::from_millis(50)),
            keepalive_timeout: Duration::from_millis(600),
        };
        let phone = Link::new(a, Role::Phone, config, None);
        // A peer that streams data frames and never answers pings.
        let (_read, write) = tokio::io::split(b);
        let mut peer = FramedWrite::new(write, FrameCodec);
        let started = Instant::now();
        while started.elapsed() < Duration::from_millis(1200) {
            peer.send(Frame::new(2, FrameType::Data, vec![0u8; 16])).await.unwrap();
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
        assert!(
            !phone.is_closed(),
            "closed while data was arriving: {:?}",
            phone.closed_state().borrow().clone()
        );
        let reason =
            tokio::time::timeout(Duration::from_secs(2), phone.closed()).await.expect("closes once quiet");
        assert_eq!(reason, "keepalive timed out");
    }

    #[tokio::test]
    async fn bad_channel_parity_is_refused() {
        let (phone, mac) = pair();
        // The Mac opening an odd id is a protocol error: simulate by having
        // the phone side receive an Open for its own parity.
        let frame = Frame::new(3, FrameType::Open, br#"{"service":"echo"}"#.to_vec());
        mac.inner.send_frame(frame).await.unwrap();
        // The phone answers with close on channel 3; the Mac has no such
        // channel so it is ignored. The link stays up.
        assert!(phone.ping().await.is_ok());
        assert!(!mac.is_closed());
    }
}
