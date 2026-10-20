//! `browser`: a streamed browser tab (cnx-ios/verify/browser-stream.md).
//!
//! The phone opens `browser {tab, url?}`. hostd keeps one Mac browser host
//! per tab: `cmux-remote-browser-host --serve`, the CEF fork host the cmux-next
//! app runs for its own remote tabs, speaking `cmux.rb/1` on `cmux.rd/1` over
//! the rd stream carrier on loopback. hostd connects to it, sends the rd
//! `hello` with the host's per-launch secret (the phone never sees the
//! secret), and then splices the channel:
//!
//! - host to phone: the carrier's bytes, unchanged (video shards, control).
//! - phone to host: whole stream frames, each checked by [`filter_frame`]:
//!   datagrams (input, feedback, clock probes) pass, control passes only for
//!   the rb messages a viewer sends, `rb.navigate` only to web addresses, and
//!   a second `hello` or bulk bytes never reach the host.
//!
//! A host outlives its channel, so a phone that comes back (link drop,
//! transport switch, tab switch) finds the page as it left it. A new channel
//! for the same tab takes the host over (`replaced` closes the older one).
//! At most `max_tabs` hosts run; opening another stops the least recently
//! used one.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_rd_proto::control::{Control, SecretHex};
use cmux_rd_proto::{
    MAX_DATAGRAM_DEFAULT, SERVICE_REMOTE_BROWSER, STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer,
    encode_stream_frame,
};
use cnx_link::ChannelEvent;
use cnx_link::link::{ChannelReceiver, ChannelSender};
use futures_util::future::BoxFuture;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::{Mutex, oneshot};

use crate::services::{Peer, Refusal};

/// The rd cap that carries rb input inside rd input datagrams.
const INPUT_SERVICE: &str = "input.service";

/// How long a launched host has to print its listening line (CEF's first
/// start on a cold cache takes several seconds).
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(45);

/// What a launcher starts.
#[derive(Debug, Clone)]
pub struct LaunchRequest {
    pub tab: String,
    pub url: String,
}

/// Keeps a launched host alive; dropping it stops the host.
pub trait HostGuard: Send {
    fn alive(&mut self) -> bool;
}

/// A running host: where its rd stream carrier listens and its secret.
pub struct RunningHost {
    pub addr: SocketAddr,
    pub secret: String,
    pub guard: Box<dyn HostGuard>,
}

/// Starts a host for a tab.
pub type Launcher =
    Arc<dyn Fn(LaunchRequest) -> BoxFuture<'static, Result<RunningHost, String>> + Send + Sync>;

struct Entry {
    host: RunningHost,
    last_used: Instant,
    /// The channel that views the tab now; firing it ends that splice.
    viewer: Option<(u64, oneshot::Sender<()>)>,
}

/// The `browser` service's configuration and its running hosts.
#[derive(Clone)]
pub struct BrowserConfig {
    launcher: Option<Launcher>,
    max_tabs: usize,
    hosts: Arc<Mutex<HashMap<String, Entry>>>,
    next_viewer: Arc<std::sync::atomic::AtomicU64>,
}

impl std::fmt::Debug for BrowserConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BrowserConfig")
            .field("enabled", &self.launcher.is_some())
            .field("max_tabs", &self.max_tabs)
            .finish()
    }
}

impl Default for BrowserConfig {
    fn default() -> Self {
        Self::new(None, 4)
    }
}

impl BrowserConfig {
    /// Whether this Mac can stream browser tabs (the version service's `browser-stream-v1`).
    pub fn available(&self) -> bool {
        self.launcher.is_some()
    }

    /// `launcher` None refuses every open with `unavailable`.
    pub fn new(launcher: Option<Launcher>, max_tabs: usize) -> Self {
        Self { launcher, max_tabs: max_tabs.max(1), hosts: Arc::default(), next_viewer: Arc::default() }
    }

    /// Hosts are `exe --serve` processes; each tab's CEF cache lives in
    /// `<cache_root>/<tab>`.
    pub fn process(exe: PathBuf, cache_root: PathBuf, max_tabs: usize) -> Self {
        let launcher: Launcher = Arc::new(move |request: LaunchRequest| {
            let exe = exe.clone();
            let cache_root = cache_root.clone();
            Box::pin(async move { launch_process(&exe, &cache_root, &request).await })
        });
        Self::new(Some(launcher), max_tabs)
    }

    /// Tabs with a running host (tests and diagnostics).
    pub async fn running_tabs(&self) -> Vec<String> {
        let mut hosts = self.hosts.lock().await;
        hosts.retain(|_, entry| entry.host.guard.alive());
        let mut tabs: Vec<String> = hosts.keys().cloned().collect();
        tabs.sort();
        tabs
    }

    /// The host for `tab`, launched when needed, now owned by a new viewer.
    async fn claim(
        &self,
        tab: &str,
        url: &str,
    ) -> Result<(SocketAddr, String, u64, oneshot::Receiver<()>), Refusal> {
        let launcher = self
            .launcher
            .clone()
            .ok_or_else(|| Refusal::new("no_browser_host", "this Mac does not stream browser tabs"))?;
        let mut hosts = self.hosts.lock().await;
        hosts.retain(|_, entry| entry.host.guard.alive());
        if !hosts.contains_key(tab) {
            while hosts.len() >= self.max_tabs {
                // Idle hosts go first, then the least recently used.
                let Some(oldest) = hosts
                    .iter()
                    .min_by_key(|(_, entry)| (entry.viewer.is_some(), entry.last_used))
                    .map(|(tab, _)| tab.clone())
                else {
                    break;
                };
                tracing::info!(tab = oldest, "browser: stopping the least recently used host");
                if let Some(mut entry) = hosts.remove(&oldest)
                    && let Some((_, viewer)) = entry.viewer.take()
                {
                    let _ = viewer.send(());
                }
            }
            let request = LaunchRequest { tab: tab.to_owned(), url: url.to_owned() };
            let host = launcher(request).await.map_err(|e| Refusal::new("unavailable", e))?;
            tracing::info!(tab, addr = %host.addr, "browser: host started");
            hosts.insert(tab.to_owned(), Entry { host, last_used: Instant::now(), viewer: None });
        }
        let entry = hosts.get_mut(tab).ok_or_else(|| Refusal::new("unavailable", "browser host vanished"))?;
        if let Some((_, previous)) = entry.viewer.take() {
            let _ = previous.send(());
        }
        let id = self.next_viewer.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (cancel, cancelled) = oneshot::channel();
        entry.viewer = Some((id, cancel));
        entry.last_used = Instant::now();
        Ok((entry.host.addr, entry.host.secret.clone(), id, cancelled))
    }

    async fn release(&self, tab: &str, viewer: u64) {
        let mut hosts = self.hosts.lock().await;
        if let Some(entry) = hosts.get_mut(tab) {
            entry.last_used = Instant::now();
            if entry.viewer.as_ref().is_some_and(|(id, _)| *id == viewer) {
                entry.viewer = None;
            }
        }
    }
}

/// A tab key: what the phone names the tab by (`s<surface>` for a daemon
/// browser surface). Also a cache folder name.
pub fn valid_tab(tab: &str) -> bool {
    !tab.is_empty()
        && tab.len() <= 64
        && !tab.starts_with('.')
        && tab.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// Addresses a phone may load in a Mac browser tab: the web, and the blank
/// page. Never `file:`, `chrome:`, `javascript:` or `data:`.
pub fn allowed_url(url: &str) -> bool {
    let lower = url.trim().to_ascii_lowercase();
    (lower.starts_with("https://") || lower.starts_with("http://")) && url.len() <= 8192
        || lower == "about:blank"
}

/// rb messages a viewer may send (cmux.rb/1 section 4, direction V). The
/// rest are host messages, or features this service does not carry yet
/// (uploads, clipboard, permissions, cookie sync).
const VIEWER_MESSAGES: &[&str] = &[
    "rb.open",
    "rb.close",
    "rb.visibility",
    "rb.screen",
    "rb.vsync",
    "rb.history",
    "rb.navigate",
    "rb.menu.result",
    "rb.dialog.result",
    "rb.open_tab.result",
    "rb.find",
    "rb.find.stop",
];

/// What happens to one phone-to-host stream frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameVerdict {
    Forward,
    Drop(&'static str),
}

/// Checks one stream frame the phone sent toward the host.
pub fn filter_frame(kind: u8, payload: &[u8]) -> FrameVerdict {
    match kind {
        STREAM_DATAGRAM => FrameVerdict::Forward,
        STREAM_CONTROL => {
            let Ok(control) = serde_json::from_slice::<Value>(payload) else {
                return FrameVerdict::Drop("control is not JSON");
            };
            match control.get("t").and_then(Value::as_str) {
                Some("stop") => FrameVerdict::Forward,
                Some("service") => {
                    if control.get("service").and_then(Value::as_str) != Some(SERVICE_REMOTE_BROWSER) {
                        return FrameVerdict::Drop("not an rb message");
                    }
                    let body = control.get("body").unwrap_or(&Value::Null);
                    let Some(t) = body.get("t").and_then(Value::as_str) else {
                        return FrameVerdict::Drop("rb message without t");
                    };
                    if !VIEWER_MESSAGES.contains(&t) {
                        return FrameVerdict::Drop("rb message a viewer may not send");
                    }
                    if t == "rb.navigate" && !body.get("url").and_then(Value::as_str).is_some_and(allowed_url)
                    {
                        return FrameVerdict::Drop("rb.navigate to an address that is not on the web");
                    }
                    FrameVerdict::Forward
                }
                // hostd sent the hello; a second one (with or without a token)
                // never reaches the host.
                Some("hello") => FrameVerdict::Drop("hostd sends the hello"),
                _ => FrameVerdict::Drop("rd control a viewer may not send"),
            }
        }
        _ => FrameVerdict::Drop("bulk transfers are not carried"),
    }
}

/// The rd `hello` hostd sends for the phone.
pub fn hello_frame(secret: &str, peer: &Peer) -> Vec<u8> {
    let hello = Control::Hello {
        user: "cnx-hostd".into(),
        install: peer.device_id.clone(),
        class: "viewer".into(),
        interactive: true,
        udp_port: None,
        max_datagram: MAX_DATAGRAM_DEFAULT,
        token: Some(SecretHex(secret.to_owned())),
        service: SERVICE_REMOTE_BROWSER.into(),
        caps: vec![INPUT_SERVICE.into()],
    };
    let mut out = Vec::new();
    let json = serde_json::to_vec(&hello).unwrap_or_default();
    let _ = encode_stream_frame(STREAM_CONTROL, &json, &mut out);
    out
}

/// `browser {tab, url?}`: see the module docs.
pub async fn serve(
    config: &BrowserConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let tab = args.get("tab").and_then(Value::as_str).unwrap_or("default");
    if !valid_tab(tab) {
        return Err(Refusal::new("bad_request", "invalid tab"));
    }
    let url = match args.get("url").and_then(Value::as_str).filter(|u| !u.trim().is_empty()) {
        Some(url) if allowed_url(url) => url.trim().to_owned(),
        Some(_) => return Err(Refusal::new("forbidden", "only http, https and about:blank load")),
        None => "about:blank".to_owned(),
    };
    let (addr, secret, viewer, cancelled) = config.claim(tab, &url).await?;
    // `video: "track"`: the page's video on the link's media lane (a WebRTC
    // track or RTP inside the WireGuard tunnel) when the link has one;
    // otherwise (an older phone, or the lane off) on this channel.
    let track = (args.get("video").and_then(Value::as_str) == Some("track"))
        .then_some(peer.video.as_ref())
        .flatten()
        .filter(|video| !video.is_closed());
    // The phone's tag for this tab's lane frames (cnx_link::media::tag).
    let video_tag = args.get("video_tag").and_then(Value::as_u64).and_then(|tag| u32::try_from(tag).ok());
    let track = track.map(|video| (video, video_tag));
    let result = splice(addr, &secret, peer, sender, receiver, cancelled, track).await;
    config.release(tab, viewer).await;
    result
}

async fn splice(
    addr: SocketAddr,
    secret: &str,
    peer: &Peer,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
    mut cancelled: oneshot::Receiver<()>,
    track: Option<(&cnx_link::media::VideoOut, Option<u32>)>,
) -> Result<(), Refusal> {
    let video_tag = track.and_then(|(_, tag)| tag);
    // A tagged phone keeps only its own tab's lane frames (the lane changes
    // tabs without telling it when); an older phone sent no tag.
    let lane_frame = |frame: cmux_rd_core::reassembly::CompleteFrame| {
        let access_unit = Bytes::from(frame.body.access_unit);
        cnx_link::media::OutgoingFrame {
            access_unit: match video_tag {
                Some(tag) => cnx_link::media::tag::append(&access_unit, tag),
                None => access_unit,
            },
            capture_us: frame.body.t_capture_us,
        }
    };
    let stream = TcpStream::connect(addr)
        .await
        .map_err(|e| Refusal::new("unavailable", format!("browser host: {e}")))?;
    let _ = stream.set_nodelay(true);
    let (mut host_read, mut host_write) = stream.into_split();
    host_write
        .write_all(&hello_frame(secret, peer))
        .await
        .map_err(|e| Refusal::new("unavailable", format!("browser host: {e}")))?;
    let mut deframer = StreamDeframer::default();
    let mut buffer = vec![0u8; 64 * 1024];
    let mut dropped = 0u64;
    // Track mode (browser_track.rs): hostd is the main stream's viewer and
    // the page's frames ride the media lane. A newer browser channel on the
    // same link takes the lane over; this one then carries its video on
    // the channel again (the host deframer stays, so frames stay whole).
    let mut claim = track.map(|(video, _)| video.claim());
    let mut host_deframer = claim.as_ref().map(|_| StreamDeframer::default());
    let mut bridge = crate::browser_track::TrackBridge::new();
    let epoch = Instant::now();
    let now_us = || u64::try_from(epoch.elapsed().as_micros()).unwrap_or(u64::MAX);
    let mut last_report_us = 0u64;
    if claim.is_some() {
        tracing::info!("browser: video on the link's media lane");
    }
    loop {
        if claim.as_ref().is_some_and(|c| !c.owns()) {
            tracing::info!("browser: another tab took the media lane; video returns to the channel");
            claim = None;
            // The phone's own viewer starts on the channel at a keyframe.
            bridge.request_keyframe();
            let recovery = bridge.feedback(false, now_us());
            if host_write.write_all(&recovery).await.is_err() {
                return Ok(());
            }
        }
        let wake = if claim.is_some() { bridge.next_deadline_us(now_us()) } else { now_us() + 3_600_000_000 };
        let sleep = tokio::time::sleep(Duration::from_micros(wake.saturating_sub(now_us())));
        // While the lane's window is full the host's ack is held; reopen the
        // frame gate the moment it drains, not at the next wake.
        let uncongested = claim.as_ref().filter(|c| c.state().congested).map(|c| c.uncongested());
        let keyframe = async {
            match claim.as_mut() {
                // A lagged receiver missed requests: still one request.
                Some(c) => {
                    !matches!(c.keyframes.recv().await, Err(tokio::sync::broadcast::error::RecvError::Closed))
                }
                None => std::future::pending().await,
            }
        };
        let uncongested = async {
            // A lane whose sender ended stays "congested" forever; never
            // wake for it (the claim goes when its channel does).
            let drained = match uncongested {
                Some(drained) => drained.await,
                None => false,
            };
            if !drained {
                std::future::pending::<()>().await;
            }
        };
        tokio::select! {
            read = host_read.read(&mut buffer) => match read {
                Ok(0) | Err(_) => return Ok(()),
                Ok(n) => {
                    let Some(host_deframer) = host_deframer.as_mut() else {
                        if sender.send(Bytes::copy_from_slice(&buffer[..n])).await.is_err() {
                            return Ok(());
                        }
                        continue;
                    };
                    host_deframer.extend(&buffer[..n]);
                    let mut to_phone = Vec::new();
                    let mut frames = Vec::new();
                    loop {
                        match host_deframer.next_frame() {
                            Ok(Some((STREAM_DATAGRAM, payload))) => {
                                match (claim.as_ref(), cmux_rd_proto::DatagramHeader::decode(&payload)) {
                                    (Some(c), Ok((header, body))) if crate::browser_track::TrackBridge::takes(&header) => {
                                        let target = c.state().target_bps;
                                        frames.extend(bridge.on_datagram(&header, body, payload.len() + 5, target, now_us()));
                                    }
                                    _ => {
                                        let _ = encode_stream_frame(STREAM_DATAGRAM, &payload, &mut to_phone);
                                    }
                                }
                            }
                            Ok(Some((kind, payload))) => {
                                let _ = encode_stream_frame(kind, &payload, &mut to_phone);
                            }
                            Ok(None) => break,
                            Err(_) => return Err(Refusal::new("unavailable", "the browser host sent an invalid rd stream")),
                        }
                    }
                    if let Some(c) = claim.as_ref() {
                        for frame in frames {
                            if c.send(lane_frame(frame)).await.is_err() {
                                break;
                            }
                        }
                    }
                    if !to_phone.is_empty() && sender.send(Bytes::from(to_phone)).await.is_err() {
                        return Ok(());
                    }
                }
            },
            event = receiver.recv() => match event {
                Some(ChannelEvent::Data(bytes)) => {
                    deframer.extend(&bytes);
                    let mut out = Vec::new();
                    loop {
                        match deframer.next_frame() {
                            // In track mode hostd answers for the main stream.
                            Ok(Some((STREAM_DATAGRAM, payload)))
                                if claim.is_some() && crate::browser_track::phone_datagram_superseded(&payload) => {}
                            Ok(Some((kind, payload))) => match filter_frame(kind, &payload) {
                                FrameVerdict::Forward => {
                                    let _ = encode_stream_frame(kind, &payload, &mut out);
                                }
                                FrameVerdict::Drop(reason) => {
                                    dropped += 1;
                                    if dropped <= 8 {
                                        tracing::warn!(reason, "browser: dropped a phone frame");
                                    }
                                }
                            },
                            Ok(None) => break,
                            Err(_) => return Err(Refusal::new("bad_request", "not an rd stream")),
                        }
                    }
                    if !out.is_empty() && host_write.write_all(&out).await.is_err() {
                        return Ok(());
                    }
                }
                _ => return Ok(()),
            },
            requested = keyframe => {
                if requested {
                    bridge.request_keyframe();
                }
            }
            () = sleep => {}
            () = uncongested => {}
            _ = &mut cancelled => {
                return Err(Refusal::new("replaced", "another viewer opened this tab"));
            }
        }
        if let Some(c) = claim.as_ref() {
            let now = now_us();
            if now.saturating_sub(last_report_us) >= 5_000_000 {
                last_report_us = now;
                let state = c.state();
                tracing::info!(
                    frames = bridge.frames,
                    held_acks = bridge.held_acks,
                    host_datagrams = bridge.datagrams,
                    target_kbps = state.target_bps / 1000,
                    in_flight = state.in_flight_bytes,
                    congested = state.congested,
                    feedback_delay_ms = state.feedback_delay_us / 1000,
                    loss = state.loss,
                    packets = state.packets_sent,
                    nacks = state.nacks_received,
                    keyframe_requests = state.keyframe_requests,
                    "browser: media lane"
                );
            }
            for frame in bridge.tick(now) {
                let _ = c.send(lane_frame(frame)).await;
            }
            let feedback = bridge.feedback(c.state().congested, now);
            if !feedback.is_empty() && host_write.write_all(&feedback).await.is_err() {
                return Ok(());
            }
        }
    }
}

/// Supervised mode: the app starts browser hosts (its own bundled
/// `cmux-remote-browser-host`, the one its remote tabs use). hostd asks with
/// `need_browser {request, tab, url}` on stdout and the app answers on stdin
/// with `browser {request, addr, secret}` or `browser_failed`; it reports a
/// host that exited with `browser_gone {tab}`, and hostd asks it to stop one
/// with `browser_stop {tab}`.
/// The app's answer: the host's address and secret, or why it did not start.
type BrowserAnswer = Result<(String, String), String>;

pub struct BrowserBroker {
    emit: Arc<dyn Fn(&crate::control::Event) + Send + Sync>,
    next: std::sync::atomic::AtomicU64,
    pending: std::sync::Mutex<HashMap<u64, oneshot::Sender<BrowserAnswer>>>,
    alive: std::sync::Mutex<HashMap<String, Arc<std::sync::atomic::AtomicBool>>>,
}

impl BrowserBroker {
    pub fn new(emit: Arc<dyn Fn(&crate::control::Event) + Send + Sync>) -> Self {
        Self {
            emit,
            next: std::sync::atomic::AtomicU64::new(1),
            pending: std::sync::Mutex::default(),
            alive: std::sync::Mutex::default(),
        }
    }

    /// The app's answer to `need_browser` `request`.
    pub fn answer(&self, request: u64, result: BrowserAnswer) {
        let waiter = self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&request);
        if let Some(waiter) = waiter {
            let _ = waiter.send(result);
        }
    }

    /// The app's host for `tab` exited.
    pub fn gone(&self, tab: &str) {
        let flag = self.alive.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(tab);
        if let Some(flag) = flag {
            flag.store(false, std::sync::atomic::Ordering::SeqCst);
        }
    }

    /// A launcher that asks the app.
    pub fn launcher(self: &Arc<Self>) -> Launcher {
        let broker = Arc::clone(self);
        Arc::new(move |request: LaunchRequest| {
            let broker = Arc::clone(&broker);
            Box::pin(async move { broker.launch(request).await })
        })
    }

    async fn launch(self: Arc<Self>, request: LaunchRequest) -> Result<RunningHost, String> {
        let id = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(id, tx);
        (self.emit)(&crate::control::Event::NeedBrowser {
            request: id,
            tab: request.tab.clone(),
            url: request.url,
        });
        let answer = tokio::time::timeout(LAUNCH_TIMEOUT + Duration::from_secs(15), rx).await;
        self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&id);
        let (addr, secret) = match answer {
            Ok(Ok(result)) => result?,
            Ok(Err(_)) => return Err("the app dropped the browser request".into()),
            Err(_) => return Err("the app did not start a browser host in time".into()),
        };
        let addr = addr
            .parse::<SocketAddr>()
            .ok()
            .filter(|a| a.ip().is_loopback())
            .ok_or_else(|| "the app's browser host is not on loopback".to_owned())?;
        let alive = Arc::new(std::sync::atomic::AtomicBool::new(true));
        self.alive
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(request.tab.clone(), Arc::clone(&alive));
        Ok(RunningHost {
            addr,
            secret,
            guard: Box::new(SuppliedGuard { tab: request.tab, alive, broker: Arc::clone(&self) }),
        })
    }
}

struct SuppliedGuard {
    tab: String,
    alive: Arc<std::sync::atomic::AtomicBool>,
    broker: Arc<BrowserBroker>,
}

impl HostGuard for SuppliedGuard {
    fn alive(&mut self) -> bool {
        self.alive.load(std::sync::atomic::Ordering::SeqCst)
    }
}

impl Drop for SuppliedGuard {
    fn drop(&mut self) {
        if self.alive.swap(false, std::sync::atomic::Ordering::SeqCst) {
            {
                let mut alive = self.broker.alive.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                if alive.get(&self.tab).is_some_and(|flag| Arc::ptr_eq(flag, &self.alive)) {
                    alive.remove(&self.tab);
                }
            }
            (self.broker.emit)(&crate::control::Event::BrowserStop { tab: self.tab.clone() });
        }
    }
}

/// A host process: its stdin is the lifeline (the host quits at end of
/// file), and `kill_on_drop` stops it with hostd.
struct ProcessGuard {
    child: tokio::process::Child,
    _lifeline: tokio::process::ChildStdin,
    _stdout: BufReader<tokio::process::ChildStdout>,
}

impl HostGuard for ProcessGuard {
    fn alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }
}

fn new_secret() -> String {
    format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple())
}

/// Runs `exe --serve --listen 127.0.0.1:0 --lifeline --url URL` with the
/// launch contract of `cmux-remote-browser-host` (launch.rs): the secret is
/// the first stdin line, the host prints `{"listening":"ADDR"}`.
async fn launch_process(
    exe: &std::path::Path,
    cache_root: &std::path::Path,
    request: &LaunchRequest,
) -> Result<RunningHost, String> {
    let cache = cache_root.join(&request.tab);
    std::fs::create_dir_all(&cache).map_err(|e| format!("cache {}: {e}", cache.display()))?;
    let log = std::fs::File::create(cache.join("host.log")).map_err(|e| format!("host log: {e}"))?;
    let mut child = tokio::process::Command::new(exe)
        .args(["--serve", "--listen", "127.0.0.1:0", "--lifeline", "--url", &request.url])
        .env("CMUX_RB_CACHE_DIR", &cache)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(log))
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("starting {}: {e}", exe.display()))?;
    let secret = new_secret();
    let mut lifeline = child.stdin.take().ok_or("no host stdin")?;
    lifeline.write_all(format!("{secret}\n").as_bytes()).await.map_err(|e| format!("host stdin: {e}"))?;
    let mut stdout = BufReader::new(child.stdout.take().ok_or("no host stdout")?);
    let mut line = String::new();
    let read = tokio::time::timeout(LAUNCH_TIMEOUT, stdout.read_line(&mut line))
        .await
        .map_err(|_| "the browser host did not start in time".to_owned())?;
    if !matches!(read, Ok(n) if n > 0) {
        return Err("the browser host exited before listening".into());
    }
    let addr = serde_json::from_str::<Value>(line.trim())
        .ok()
        .and_then(|v| v.get("listening").and_then(Value::as_str).and_then(|a| a.parse::<SocketAddr>().ok()))
        .filter(|a| a.ip().is_loopback())
        .ok_or_else(|| format!("unexpected host output: {}", line.trim()))?;
    Ok(RunningHost {
        addr,
        secret,
        guard: Box::new(ProcessGuard { child, _lifeline: lifeline, _stdout: stdout }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn control(value: Value) -> Vec<u8> {
        serde_json::to_vec(&value).unwrap()
    }

    fn rb(body: Value) -> Vec<u8> {
        control(serde_json::json!({"t": "service", "service": "rb/1", "body": body}))
    }

    #[test]
    fn viewer_messages_pass_and_host_ones_do_not() {
        assert_eq!(filter_frame(STREAM_DATAGRAM, &[0x10, 4]), FrameVerdict::Forward);
        for body in [
            serde_json::json!({"t": "rb.screen", "seq": 1, "screen": {}}),
            serde_json::json!({"t": "rb.history", "op": "back"}),
            serde_json::json!({"t": "rb.navigate", "url": "https://example.com/a"}),
            serde_json::json!({"t": "rb.navigate", "url": "about:blank"}),
        ] {
            assert_eq!(filter_frame(STREAM_CONTROL, &rb(body)), FrameVerdict::Forward);
        }
        assert_eq!(
            filter_frame(STREAM_CONTROL, &control(serde_json::json!({"t": "stop"}))),
            FrameVerdict::Forward
        );
        for (frame, kind) in [
            (rb(serde_json::json!({"t": "rb.navigate", "url": "file:///etc/passwd"})), STREAM_CONTROL),
            (rb(serde_json::json!({"t": "rb.navigate", "url": "javascript:alert(1)"})), STREAM_CONTROL),
            (rb(serde_json::json!({"t": "rb.navigate", "url": "chrome://settings"})), STREAM_CONTROL),
            (rb(serde_json::json!({"t": "rb.page", "url": "x"})), STREAM_CONTROL),
            (rb(serde_json::json!({"t": "rb.clipboard.push", "seq": 1, "items": []})), STREAM_CONTROL),
            (
                control(serde_json::json!({"t": "service", "service": "desktop", "body": {"t": "rb.open"}})),
                STREAM_CONTROL,
            ),
            (control(serde_json::json!({"t": "hello", "token": "00"})), STREAM_CONTROL),
            (control(serde_json::json!({"t": "start", "key": "k", "mode": "m"})), STREAM_CONTROL),
            (b"not json".to_vec(), STREAM_CONTROL),
            (vec![0; 16], cmux_rd_proto::STREAM_BULK),
        ] {
            assert!(
                matches!(filter_frame(kind, &frame), FrameVerdict::Drop(_)),
                "{}",
                String::from_utf8_lossy(&frame)
            );
        }
    }

    #[tokio::test]
    async fn the_broker_asks_the_app_and_tells_it_to_stop() {
        let events = Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen = Arc::clone(&events);
        let broker = Arc::new(BrowserBroker::new(Arc::new(move |event: &crate::control::Event| {
            seen.lock().unwrap().push(serde_json::to_value(event).unwrap());
        })));
        let launch = broker.launcher();
        let pending =
            tokio::spawn(launch(LaunchRequest { tab: "s4".into(), url: "https://example.com".into() }));
        while events.lock().unwrap().is_empty() {
            tokio::task::yield_now().await;
        }
        let asked = events.lock().unwrap()[0].clone();
        assert_eq!(asked["type"], "need_browser");
        assert_eq!(asked["tab"], "s4");
        let request = asked["request"].as_u64().unwrap();
        broker.answer(request, Ok(("127.0.0.1:4100".into(), "secret".into())));
        let mut host = pending.await.unwrap().unwrap();
        assert_eq!(host.addr.port(), 4100);
        assert!(host.guard.alive());
        broker.gone("s4");
        assert!(!host.guard.alive());
        drop(host);
        // Already gone: no stop request.
        assert_eq!(events.lock().unwrap().len(), 1);

        let pending = tokio::spawn(launch(LaunchRequest { tab: "s5".into(), url: "about:blank".into() }));
        while events.lock().unwrap().len() < 2 {
            tokio::task::yield_now().await;
        }
        let request = events.lock().unwrap()[1]["request"].as_u64().unwrap();
        broker.answer(request, Ok(("10.0.0.1:4100".into(), "secret".into())));
        assert!(pending.await.unwrap().is_err(), "a non-loopback host is refused");

        let pending = tokio::spawn(launch(LaunchRequest { tab: "s6".into(), url: "about:blank".into() }));
        while events.lock().unwrap().len() < 3 {
            tokio::task::yield_now().await;
        }
        let request = events.lock().unwrap()[2]["request"].as_u64().unwrap();
        broker.answer(request, Ok(("127.0.0.1:4101".into(), "secret".into())));
        drop(pending.await.unwrap().unwrap());
        let stop = events.lock().unwrap()[3].clone();
        assert_eq!(stop, serde_json::json!({"type": "browser_stop", "tab": "s6"}));
    }

    struct Alive;
    impl HostGuard for Alive {
        fn alive(&mut self) -> bool {
            true
        }
    }

    fn fake_launcher() -> Launcher {
        Arc::new(|_request: LaunchRequest| {
            Box::pin(async {
                Ok(RunningHost {
                    addr: "127.0.0.1:9".parse().unwrap(),
                    secret: "s".into(),
                    guard: Box::new(Alive),
                })
            })
        })
    }

    /// transport-verify-20261019.md defect 7: the host limit stopped the
    /// shown tab's page. A host the phone shows is stopped last, and its
    /// viewer hears `evicted` (the page reopens), not `replaced`.
    #[tokio::test]
    async fn the_host_limit_stops_a_hidden_tab_before_the_shown_one() {
        let config = BrowserConfig::new(Some(fake_launcher()), 2);
        let shown = config.claim("s1", "about:blank").await.unwrap();
        let mut hidden = config.claim("s2", "about:blank").await.unwrap();
        // s2 opened last (it was used more recently), but the phone hides it.
        hidden.visible.store(false, std::sync::atomic::Ordering::SeqCst);
        let _third = config.claim("s3", "about:blank").await.unwrap();
        assert_eq!(config.running_tabs().await, vec!["s1".to_owned(), "s3".to_owned()]);
        assert_eq!(hidden.stopped.try_recv(), Ok(Stop::Evicted));
        drop(shown);
    }

    #[tokio::test]
    async fn a_second_viewer_of_a_tab_replaces_the_first() {
        let config = BrowserConfig::new(Some(fake_launcher()), 2);
        let mut first = config.claim("s1", "about:blank").await.unwrap();
        let _second = config.claim("s1", "about:blank").await.unwrap();
        assert_eq!(first.stopped.try_recv(), Ok(Stop::Replaced));
    }

    #[test]
    fn the_phone_says_which_tab_is_shown() {
        assert_eq!(visibility(&rb(serde_json::json!({"t": "rb.visibility", "visible": true}))), Some(true));
        assert_eq!(visibility(&rb(serde_json::json!({"t": "rb.visibility", "visible": false}))), Some(false));
        assert_eq!(visibility(&rb(serde_json::json!({"t": "rb.screen", "visible": true}))), None);
        assert_eq!(visibility(b"not json"), None);
    }

    #[test]
    fn tabs_and_urls() {
        assert!(valid_tab("s12"));
        assert!(valid_tab("t-abc_1.x"));
        assert!(!valid_tab("../x"));
        assert!(!valid_tab(".x"));
        assert!(!valid_tab(""));
        assert!(!valid_tab("a/b"));
        assert!(allowed_url("https://example.com"));
        assert!(allowed_url("HTTP://example.com"));
        assert!(allowed_url("about:blank"));
        assert!(!allowed_url("about:config"));
        assert!(!allowed_url("data:text/html,x"));
        assert!(!allowed_url("file:///"));
    }

    #[test]
    fn hello_carries_the_secret_and_the_rb_service() {
        let frame = hello_frame(
            "ab".repeat(32).as_str(),
            &Peer { device_id: "phone".into(), session_id: "s".into(), video: None },
        );
        let mut deframer = StreamDeframer::default();
        deframer.extend(&frame);
        let (kind, payload) = deframer.next_frame().unwrap().unwrap();
        assert_eq!(kind, STREAM_CONTROL);
        let value: Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(value["t"], "hello");
        assert_eq!(value["service"], "rb/1");
        assert_eq!(value["token"], "ab".repeat(32));
        assert_eq!(value["caps"][0], INPUT_SERVICE);
    }
}
