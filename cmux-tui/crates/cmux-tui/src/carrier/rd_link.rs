//! The viewer's side of the desktop's datagram link (cmuxterm-hq#7976) in
//! `cmux carrier dial --service desktop`.
//!
//! The app's viewer speaks `cmux.rd/1` frames (`u8 type` 1 control JSON or 2
//! datagram, `u32` little-endian length, payload) on this process's stdin
//! and stdout, and the dial carries them to the machine's desktop socket.
//! When the carrier answer turns the link on (`rd_link`), the dial speaks the
//! host's link protocol (`cmux-rd-host` `hybrid.rs`, cap `link.udp`) for the
//! viewer, without the viewer knowing:
//! - the viewer's `hello` gains the cap `link.udp`;
//! - the `welcome` loses it again, so the viewer sees the caps it asked for;
//! - once the host says `started` (its media session runs), the dial sends
//!   `link_offer`, and `link_answer` starts the link;
//! - `link_answer`, `link_candidate` and `link_state` stay between the dial
//!   and the host, never reaching the viewer;
//! - the viewer's datagrams go on the link while it is up, else on the
//!   stream, and the link's datagrams reach the viewer as stream datagrams.
//!
//! Control never leaves the stream, so a link that never comes up (UDP
//! blocked, no route between the two sides) or that fails changes nothing the
//! viewer can see. A host without the cap answers a welcome without it, and
//! the dial then only passes bytes through.

use std::io;
use std::net::SocketAddr;
use std::os::fd::{AsRawFd, RawFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use bytes::Bytes;
use cmux_rd_link::dlink::{DatagramLink, LinkOut, LinkState, TurnName, ViewerOffer};
use cmux_remote::bridge::BridgeError;
use cmux_remote::service::ServiceStream;
use serde_json::{Value, json};
use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{Notify, mpsc};

const FRAME_CONTROL: u8 = 1;
const FRAME_DATAGRAM: u8 = 2;
/// The rd host's frame bound (cmux-rd-host `wire.rs`).
const MAX_FRAME: usize = 1 << 20;
/// The host's cap for the link (cmux-rd-core `caps::LINK_UDP`).
const LINK_CAP: &str = "link.udp";
/// `CMUX_RD_LINK=0` keeps every datagram on the stream whatever the platform says.
pub(super) const KILL_SWITCH: &str = "CMUX_RD_LINK";

/// Accumulates bytes and yields complete frames.
#[derive(Default)]
struct Frames {
    buf: Vec<u8>,
}

impl Frames {
    fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    fn next(&mut self) -> io::Result<Option<(u8, Vec<u8>)>> {
        let Some((&ty, rest)) = self.buf.split_first() else { return Ok(None) };
        let Some((len, body)) = rest.split_first_chunk::<4>() else { return Ok(None) };
        let len = u32::from_le_bytes(*len) as usize;
        if len > MAX_FRAME {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "rd frame too large"));
        }
        let Some(payload) = body.get(..len) else { return Ok(None) };
        let payload = payload.to_vec();
        self.buf.drain(..5 + len);
        Ok(Some((ty, payload)))
    }
}

fn frame(ty: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.push(ty);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    out
}

fn control_frame(value: &Value) -> Vec<u8> {
    frame(FRAME_CONTROL, &serde_json::to_vec(value).unwrap_or_default())
}

/// Where one piece of the splice's output goes.
#[derive(Debug, PartialEq, Eq)]
enum Out {
    /// Bytes for the host (the carrier stream).
    Host(Vec<u8>),
    /// Bytes for the viewer (stdout).
    Viewer(Vec<u8>),
    /// A link state change, for the log.
    Note(String),
}

/// How far the negotiation got.
enum Phase {
    /// Before the viewer's hello: the offer to make, if the platform turned the link on.
    Hello(Option<ViewerOffer>),
    /// The hello went out with the cap; the welcome says whether the host has it.
    Asked(ViewerOffer),
    /// The host has the cap; the offer goes out once its media session runs.
    Granted(ViewerOffer),
    /// `link_offer` went out; `link_answer` starts the link.
    Offered(ViewerOffer),
    /// The link started, or this session has none.
    Done,
}

/// The splice, apart from its I/O.
struct Splice {
    phase: Phase,
    /// The dial added the cap, so the link's controls are the dial's. A
    /// viewer that asked for the cap itself gets every byte as sent.
    spliced: bool,
    link: Option<DatagramLink>,
    bind: SocketAddr,
}

/// `caps` of a hello or welcome, as a mutable list.
fn caps_of(control: &mut Value) -> Option<&mut Vec<Value>> {
    control.get_mut("caps")?.as_array_mut()
}

impl Splice {
    /// Takes the phase when `want` matches it, leaving `Done`; else leaves it.
    fn take(&mut self, want: fn(&Phase) -> bool) -> Option<Phase> {
        want(&self.phase).then(|| std::mem::replace(&mut self.phase, Phase::Done))
    }

    fn new(offer: Option<ViewerOffer>, bind: SocketAddr) -> Self {
        Self { phase: Phase::Hello(offer), spliced: false, link: None, bind }
    }

    /// One frame from the viewer.
    fn on_viewer(&mut self, ty: u8, payload: Vec<u8>, out: &mut Vec<Out>) {
        if ty == FRAME_DATAGRAM {
            match &self.link {
                Some(link) if link.is_up() => link.send_datagram(&payload),
                _ => out.push(Out::Host(frame(ty, &payload))),
            }
            return;
        }
        // Only the first control may ask for the cap: when it is not a hello,
        // or the viewer asked for it itself, the dial stays out of the way.
        if ty == FRAME_CONTROL
            && let Some(Phase::Hello(offer)) = self.take(|p| matches!(p, Phase::Hello(_)))
            && let Some(offer) = offer
            && let Ok(mut hello) = serde_json::from_slice::<Value>(&payload)
            && hello.get("t").and_then(Value::as_str) == Some("hello")
        {
            if let Some(fields) = hello.as_object_mut() {
                fields.entry("caps").or_insert_with(|| json!([]));
            }
            if let Some(caps) = caps_of(&mut hello)
                && !caps.iter().any(|c| c == LINK_CAP)
            {
                caps.push(json!(LINK_CAP));
                out.push(Out::Host(control_frame(&hello)));
                self.phase = Phase::Asked(offer);
                self.spliced = true;
                return;
            }
        }
        out.push(Out::Host(frame(ty, &payload)));
    }

    /// One frame from the host.
    fn on_host(&mut self, ty: u8, payload: Vec<u8>, out: &mut Vec<Out>) {
        if ty != FRAME_CONTROL || !self.spliced {
            out.push(Out::Viewer(frame(ty, &payload)));
            return;
        }
        let Ok(mut control) = serde_json::from_slice::<Value>(&payload) else {
            out.push(Out::Viewer(frame(ty, &payload)));
            return;
        };
        let kind = control.get("t").and_then(Value::as_str).map(str::to_owned);
        match kind.as_deref() {
            // The dial's own messages: the viewer never asked for the cap.
            Some("link_candidate") => {
                if let (Some(link), Some(candidate)) =
                    (&mut self.link, control.get("candidate").and_then(Value::as_str))
                {
                    link.add_remote_candidate(candidate);
                }
            }
            Some("link_state") => {
                let up = control.get("up").and_then(Value::as_bool).unwrap_or(false);
                let reason = control.get("reason").and_then(Value::as_str).unwrap_or("");
                out.push(Out::Note(if up {
                    "host_up".into()
                } else {
                    format!("host_down {reason}")
                }));
            }
            Some("link_answer") => {
                if let Some(Phase::Offered(offer)) = self.take(|p| matches!(p, Phase::Offered(_))) {
                    let key = control.get("key").and_then(Value::as_str).unwrap_or("");
                    match offer.start(key, self.bind) {
                        Ok(link) => {
                            out.push(Out::Note("answered".into()));
                            self.link = Some(link);
                            self.poll(out);
                        }
                        Err(why) => out.push(Out::Note(format!("not_started {why}"))),
                    }
                }
            }
            Some("welcome") => {
                if let Some(Phase::Asked(offer)) = self.take(|p| matches!(p, Phase::Asked(_))) {
                    let granted = caps_of(&mut control).is_some_and(|caps| {
                        let before = caps.len();
                        caps.retain(|c| c != LINK_CAP);
                        caps.len() != before
                    });
                    if granted {
                        self.phase = Phase::Granted(offer);
                    } else {
                        out.push(Out::Note("not_answered".into()));
                    }
                }
                out.push(Out::Viewer(control_frame(&control)));
            }
            Some("started") => {
                if let Some(Phase::Granted(offer)) = self.take(|p| matches!(p, Phase::Granted(_))) {
                    out.push(Out::Host(control_frame(&json!({
                        "t": "link_offer", "session": offer.session(), "key": offer.key(), "candidates": []
                    }))));
                    out.push(Out::Note("offered".into()));
                    self.phase = Phase::Offered(offer);
                }
                out.push(Out::Viewer(frame(ty, &payload)));
            }
            _ => out.push(Out::Viewer(frame(ty, &payload))),
        }
    }

    /// The link's events.
    fn poll(&mut self, out: &mut Vec<Out>) {
        let Some(link) = &mut self.link else { return };
        let mut produced = Vec::new();
        link.poll(&mut produced);
        for item in produced {
            match item {
                LinkOut::Datagram(d) => out.push(Out::Viewer(frame(FRAME_DATAGRAM, &d))),
                LinkOut::Candidate(candidate) => out.push(Out::Host(control_frame(
                    &json!({"t": "link_candidate", "candidate": candidate}),
                ))),
                LinkOut::State(LinkState::Up) => out.push(Out::Note("up".into())),
                LinkOut::State(LinkState::Quiet) => out.push(Out::Note("quiet".into())),
                LinkOut::State(LinkState::Failed(why)) => {
                    out.push(Out::Note(format!("failed {why}")));
                }
            }
        }
        if self.link.as_ref().is_some_and(|l| l.failed().is_some()) {
            self.link = None;
        }
    }

    fn link_fd(&self) -> Option<RawFd> {
        self.link.as_ref().and_then(DatagramLink::fd)
    }
}

/// The link's event descriptor, duplicated: the reactor watches a descriptor
/// this bridge owns, so the link may close its own at any time.
struct Fd {
    of: RawFd,
    owned: std::os::fd::OwnedFd,
}

impl Fd {
    fn dup(of: RawFd) -> Option<Self> {
        // SAFETY: `of` is the link's open event descriptor; the borrow ends here.
        let borrowed = unsafe { std::os::fd::BorrowedFd::borrow_raw(of) };
        Some(Self { of, owned: borrowed.try_clone_to_owned().ok()? })
    }
}

impl AsRawFd for Fd {
    fn as_raw_fd(&self) -> RawFd {
        self.owned.as_raw_fd()
    }
}

/// Waits until the link's event descriptor is readable (forever without one).
async fn link_ready(fd: &Option<AsyncFd<Fd>>) {
    match fd {
        Some(fd) => {
            if let Ok(mut guard) = fd.readable().await {
                // The link's own poll drains the descriptor.
                guard.clear_ready();
            }
        }
        None => std::future::pending().await,
    }
}

/// What the bridge needs of the carrier stream: [`ServiceStream`], or a
/// test's stand-in that can stall.
pub(super) trait Remote {
    async fn send(&self, bytes: Bytes) -> Result<(), BridgeError>;
    /// The next payload, and whether the stream ended (finished or reset) with
    /// it; `None` once it has ended.
    async fn receive(&self) -> Result<Option<(Bytes, bool)>, BridgeError>;
    async fn close(&self) -> Result<(), BridgeError>;
    async fn failure(&self) -> BridgeError;
}

impl Remote for ServiceStream {
    async fn send(&self, bytes: Bytes) -> Result<(), BridgeError> {
        Ok(ServiceStream::send(self, bytes).await?)
    }

    async fn receive(&self) -> Result<Option<(Bytes, bool)>, BridgeError> {
        Ok(ServiceStream::receive(self)
            .await?
            .map(|chunk| (chunk.payload.clone(), chunk.finished || chunk.reset)))
    }

    async fn close(&self) -> Result<(), BridgeError> {
        Ok(ServiceStream::close(self).await?)
    }

    async fn failure(&self) -> BridgeError {
        self.wait_for_failure().await.into()
    }
}

/// Bytes queued for one side past which the bridge stops reading what would
/// add to them; the other direction keeps moving.
const QUEUE_LIMIT: usize = 1 << 20;

enum ToHost {
    Bytes(Vec<u8>),
    /// The viewer closed its input: half-close the stream after what is queued.
    Close,
}

/// Copies the desktop between the viewer (`reader`, `writer`) and the
/// carrier stream, with the datagram link spliced in (the platform turned it
/// on; without it the dial uses `bridge_raw_stream`). Ends as
/// `bridge_raw_stream` does.
///
/// Writes run on their own, as `bridge_raw_stream`'s two directions do: a
/// viewer that stops reading stdout never holds its own feedback and input
/// back from the host (the host keeps a session alive for a bounded 90-second
/// reattach grace without feedback), nor the link's polling. A full queue to
/// the viewer pauses
/// reading the stream and drops the link's datagrams, which FEC and NACKs
/// already cover; a full queue to the host pauses reading the viewer.
pub(super) async fn bridge<S, R, W>(
    remote: Arc<S>,
    mut reader: R,
    mut writer: W,
    stun: Vec<String>,
    turn: Vec<TurnName>,
    log: impl Fn(&str),
) -> Result<(), BridgeError>
where
    S: Remote,
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let offer = match ViewerOffer::new(stun, turn) {
        Ok(offer) => Some(offer),
        Err(why) => {
            log(&format!("not_offered {why}"));
            None
        }
    };
    let mut splice = Splice::new(offer, SocketAddr::from(([0, 0, 0, 0], 0)));
    let (viewer_tx, mut viewer_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let (host_tx, mut host_rx) = mpsc::unbounded_channel::<ToHost>();
    let (viewer_queued, host_queued, drained) =
        (AtomicUsize::new(0), AtomicUsize::new(0), Notify::new());
    let (viewer_queued, host_queued, drained) = (&viewer_queued, &host_queued, &drained);
    let remote = &*remote;
    let to_viewer = async {
        while let Some(bytes) = viewer_rx.recv().await {
            writer.write_all(&bytes).await?;
            if viewer_rx.is_empty() {
                writer.flush().await?;
            }
            viewer_queued.fetch_sub(bytes.len(), Ordering::Relaxed);
            drained.notify_one();
        }
        writer.shutdown().await?;
        Ok::<(), BridgeError>(())
    };
    let to_host = async {
        while let Some(item) = host_rx.recv().await {
            match item {
                ToHost::Bytes(bytes) => {
                    let size = bytes.len();
                    remote.send(Bytes::from(bytes)).await?;
                    host_queued.fetch_sub(size, Ordering::Relaxed);
                    drained.notify_one();
                }
                ToHost::Close => remote.close().await?,
            }
        }
        Ok::<(), BridgeError>(())
    };
    let splice_loop = async move {
        let (mut from_viewer, mut from_host) = (Frames::default(), Frames::default());
        let mut link_fd: Option<AsyncFd<Fd>> = None;
        let mut buffer = vec![0_u8; 64 * 1024];
        let mut viewer_open = true;
        loop {
            let mut out = Vec::new();
            let mut finished = false;
            let host_full = host_queued.load(Ordering::Relaxed) >= QUEUE_LIMIT;
            let viewer_full = viewer_queued.load(Ordering::Relaxed) >= QUEUE_LIMIT;
            // Unbiased: tokio picks among ready branches at random, so steady
            // input, video or link traffic never starves the others.
            tokio::select! {
                read = reader.read(&mut buffer), if viewer_open && !host_full => {
                    let size = read?;
                    if size == 0 {
                        viewer_open = false;
                        let _ = host_tx.send(ToHost::Close);
                    } else {
                        from_viewer.push(buffer.get(..size).unwrap_or_default());
                        while let Some((ty, payload)) = from_viewer.next()? {
                            splice.on_viewer(ty, payload, &mut out);
                        }
                    }
                }
                received = remote.receive(), if !viewer_full => {
                    match received? {
                        Some((payload, ended)) => {
                            from_host.push(&payload);
                            while let Some((ty, payload)) = from_host.next()? {
                                splice.on_host(ty, payload, &mut out);
                            }
                            finished = ended;
                        }
                        None => finished = true,
                    }
                }
                () = link_ready(&link_fd) => splice.poll(&mut out),
                () = drained.notified(), if host_full || viewer_full => {}
            }
            for item in out {
                match item {
                    Out::Host(bytes) => {
                        host_queued.fetch_add(bytes.len(), Ordering::Relaxed);
                        let _ = host_tx.send(ToHost::Bytes(bytes));
                    }
                    Out::Viewer(bytes)
                        if bytes.first() == Some(&FRAME_DATAGRAM)
                            && viewer_queued.load(Ordering::Relaxed) >= QUEUE_LIMIT => {}
                    Out::Viewer(bytes) => {
                        viewer_queued.fetch_add(bytes.len(), Ordering::Relaxed);
                        let _ = viewer_tx.send(bytes);
                    }
                    Out::Note(note) => log(&note),
                }
            }
            // The link starts after a welcome and ends on failure: follow its descriptor.
            let fd = splice.link_fd();
            if fd != link_fd.as_ref().map(|f| f.get_ref().of) {
                link_fd = fd.and_then(Fd::dup).and_then(|fd| AsyncFd::new(fd).ok());
            }
            if finished {
                break;
            }
        }
        // Dropping the queues' senders lets both writers finish what is queued.
        drop((viewer_tx, host_tx));
        Ok::<(), BridgeError>(())
    };
    // Everything stays under the failure watch: a viewer that stops reading
    // must not hide a carrier reset.
    tokio::select! {
        biased;
        error = remote.failure() => Err(error),
        done = async { tokio::try_join!(splice_loop, to_viewer, to_host).map(|_| ()) } => done,
    }
}

#[cfg(test)]
mod tests;
