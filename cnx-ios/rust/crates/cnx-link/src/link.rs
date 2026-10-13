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
    /// How long a keepalive ping may go unanswered before the link closes.
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
        let (incoming_tx, incoming_rx) = mpsc::channel(64);
        let inner = Arc::new(Inner {
            role,
            out: out_tx,
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
        let writer =
            tokio::spawn(write_loop(Arc::clone(&inner), FramedWrite::new(write_half, FrameCodec), out_rx));
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
                    match tokio::time::timeout(config.keepalive_timeout, link.ping()).await {
                        Ok(Ok(_)) => {}
                        Ok(Err(_)) => return,
                        Err(_) => {
                            link.inner.shut("keepalive timed out");
                            return;
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
        self.inner.send_frame(Frame::new(0, FrameType::Ping, nonce.to_be_bytes().to_vec())).await?;
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
) where
    W: AsyncWrite + Send + Unpin,
{
    while let Some(message) = rx.recv().await {
        match message {
            WriterMsg::Frame(frame) => {
                // Feed what is queued, then flush once.
                let mut result = sink.feed(frame).await;
                while result.is_ok() {
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
            WriterMsg::Shutdown => {
                let _ = sink.close().await;
                return;
            }
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
        match frame.kind {
            FrameType::Ping => inner.try_send_frame(Frame::new(0, FrameType::Pong, frame.payload)),
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
