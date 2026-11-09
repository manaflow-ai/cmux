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

use bytes::Bytes;
use cmux_rd_link::dlink::{DatagramLink, LinkOut, LinkState, ViewerOffer};
use cmux_remote::bridge::BridgeError;
use cmux_remote::service::ServiceStream;
use serde_json::{Value, json};
use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

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
        if self.buf.len() < 5 {
            return Ok(None);
        }
        let len = u32::from_le_bytes([self.buf[1], self.buf[2], self.buf[3], self.buf[4]]) as usize;
        if len > MAX_FRAME {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "rd frame too large"));
        }
        if self.buf.len() < 5 + len {
            return Ok(None);
        }
        let ty = self.buf[0];
        let payload = self.buf[5..5 + len].to_vec();
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
            if hello.get("caps").is_none() {
                hello["caps"] = json!([]);
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

/// One piece of the carrier stream's input.
pub(super) struct Chunk {
    pub payload: Bytes,
    /// The host finished or reset the stream.
    pub finished: bool,
}

/// The carrier stream, as the bridge uses it.
#[allow(async_fn_in_trait)]
pub(super) trait Remote {
    async fn send(&self, bytes: Bytes) -> Result<(), BridgeError>;
    async fn receive(&self) -> Result<Option<Chunk>, BridgeError>;
    async fn close(&self) -> Result<(), BridgeError>;
    /// Resolves when the stream failed.
    async fn failed(&self) -> BridgeError;
}

impl Remote for Arc<ServiceStream> {
    async fn send(&self, bytes: Bytes) -> Result<(), BridgeError> {
        Ok(ServiceStream::send(self, bytes).await?)
    }
    async fn receive(&self) -> Result<Option<Chunk>, BridgeError> {
        Ok(ServiceStream::receive(self)
            .await?
            .map(|c| Chunk { finished: c.finished || c.reset, payload: c.payload }))
    }
    async fn close(&self) -> Result<(), BridgeError> {
        Ok(ServiceStream::close(self).await?)
    }
    async fn failed(&self) -> BridgeError {
        self.wait_for_failure().await.into()
    }
}

/// Bytes queued for one direction above which the bridge stops reading that
/// direction's source; the other direction keeps going.
const QUEUE_LIMIT: usize = 4 << 20;

/// What the stream's writer does next.
enum ToHost {
    Bytes(Vec<u8>),
    /// The viewer closed its input: close the stream after what is queued.
    Close,
}

/// One direction's queue: what is waiting, and a wakeup when it shrinks.
struct Queue {
    bytes: std::sync::atomic::AtomicUsize,
    drained: tokio::sync::Notify,
}

impl Queue {
    fn new() -> Self {
        Self { bytes: 0.into(), drained: tokio::sync::Notify::new() }
    }
    fn open(&self) -> bool {
        self.bytes.load(std::sync::atomic::Ordering::Relaxed) < QUEUE_LIMIT
    }
    fn add(&self, n: usize) {
        self.bytes.fetch_add(n, std::sync::atomic::Ordering::Relaxed);
    }
    fn done(&self, n: usize) {
        self.bytes.fetch_sub(n, std::sync::atomic::Ordering::Relaxed);
        self.drained.notify_one();
    }
}

/// Copies the desktop between the viewer (`reader`, `writer`) and the
/// carrier stream, with the datagram link spliced in when `stun` is `Some`
/// (the platform turned it on). Ends as `bridge_raw_stream` does.
///
/// Three parts run at once: one reads the viewer, the stream and the link,
/// and one writer per direction drains its own queue. A viewer that stops
/// reading stalls only what goes to the viewer: the viewer's feedback and
/// input keep reaching the host, and a stream failure still ends the bridge.
pub(super) async fn bridge<C, R, W>(
    remote: C,
    mut reader: R,
    mut writer: W,
    stun: Option<Vec<String>>,
    log: impl Fn(&str),
) -> Result<(), BridgeError>
where
    C: Remote,
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let offer = match stun {
        Some(stun) => match ViewerOffer::new(stun) {
            Ok(offer) => Some(offer),
            Err(why) => {
                log(&format!("not_offered {why}"));
                None
            }
        },
        None => None,
    };
    let mut splice = Splice::new(offer, SocketAddr::from(([0, 0, 0, 0], 0)));
    let (host_q, viewer_q) = (Queue::new(), Queue::new());
    let (to_host, mut host_rx) = tokio::sync::mpsc::unbounded_channel::<ToHost>();
    let (to_viewer, mut viewer_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    let (remote, host_q, viewer_q) = (&remote, &host_q, &viewer_q);

    // Owns both senders: when it returns, the writers finish what is queued and end.
    let read = async move {
        let (mut from_viewer, mut from_host) = (Frames::default(), Frames::default());
        let mut link_fd: Option<AsyncFd<Fd>> = None;
        let mut buffer = vec![0_u8; 64 * 1024];
        let mut viewer_open = true;
        let failure = remote.failed();
        tokio::pin!(failure);
        loop {
            let mut out = Vec::new();
            let mut finished = false;
            tokio::select! {
                biased;
                error = &mut failure => return Err(error),
                read = reader.read(&mut buffer), if viewer_open && host_q.open() => {
                    let size = read?;
                    if size == 0 {
                        viewer_open = false;
                        let _ = to_host.send(ToHost::Close);
                    } else {
                        from_viewer.push(&buffer[..size]);
                        while let Some((ty, payload)) = from_viewer.next()? {
                            splice.on_viewer(ty, payload, &mut out);
                        }
                    }
                }
                chunk = remote.receive(), if viewer_q.open() => {
                    match chunk? {
                        Some(chunk) => {
                            from_host.push(&chunk.payload);
                            while let Some((ty, payload)) = from_host.next()? {
                                splice.on_host(ty, payload, &mut out);
                            }
                            finished = chunk.finished;
                        }
                        None => finished = true,
                    }
                }
                () = link_ready(&link_fd), if viewer_q.open() => splice.poll(&mut out),
                // A full queue shrank: its source may read again.
                () = host_q.drained.notified(), if !host_q.open() => {}
                () = viewer_q.drained.notified(), if !viewer_q.open() => {}
            }
            for item in out {
                match item {
                    Out::Host(bytes) => {
                        host_q.add(bytes.len());
                        let _ = to_host.send(ToHost::Bytes(bytes));
                    }
                    Out::Viewer(bytes) => {
                        viewer_q.add(bytes.len());
                        let _ = to_viewer.send(bytes);
                    }
                    Out::Note(note) => log(&note),
                }
            }
            // The link starts after an answer and ends on failure: follow its descriptor.
            let fd = splice.link_fd();
            if fd != link_fd.as_ref().map(|f| f.get_ref().of) {
                link_fd = fd.and_then(Fd::dup).and_then(|fd| AsyncFd::new(fd).ok());
            }
            if finished {
                // Dropping the senders ends both writers once their queues are written.
                return Ok::<(), BridgeError>(());
            }
        }
    };
    let host_writer = async move {
        while let Some(item) = host_rx.recv().await {
            match item {
                ToHost::Bytes(bytes) => {
                    let n = bytes.len();
                    remote.send(Bytes::from(bytes)).await?;
                    host_q.done(n);
                }
                ToHost::Close => remote.close().await?,
            }
        }
        Ok::<(), BridgeError>(())
    };
    let viewer_writer = async move {
        while let Some(bytes) = viewer_rx.recv().await {
            writer.write_all(&bytes).await?;
            viewer_q.done(bytes.len());
            while let Ok(more) = viewer_rx.try_recv() {
                writer.write_all(&more).await?;
                viewer_q.done(more.len());
            }
            writer.flush().await?;
        }
        writer.flush().await?;
        writer.shutdown().await?;
        Ok::<(), BridgeError>(())
    };
    tokio::try_join!(read, host_writer, viewer_writer).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_rd_proto::control::Control;
    use std::time::{Duration, Instant};

    /// Every interface: the link's host routes are this machine's non-loopback addresses.
    fn bind() -> SocketAddr {
        "0.0.0.0:0".parse().unwrap()
    }

    fn hello() -> Vec<u8> {
        serde_json::to_vec(&json!({
            "t": "hello", "user": "u", "install": "i", "class": "user", "interactive": true,
            "udp_port": null, "max_datagram": 1200, "service": "desktop", "caps": ["tile"],
            "future_field": 7
        }))
        .unwrap()
    }

    fn controls(out: &[Out], host: bool) -> Vec<(u8, Value)> {
        let mut frames = Frames::default();
        for item in out {
            match item {
                Out::Host(bytes) if host => frames.push(bytes),
                Out::Viewer(bytes) if !host => frames.push(bytes),
                _ => {}
            }
        }
        let mut parsed = Vec::new();
        while let Some((ty, payload)) = frames.next().unwrap() {
            parsed.push((ty, serde_json::from_slice(&payload).unwrap_or(Value::Null)));
        }
        parsed
    }

    fn viewer_frames(out: &[Out]) -> Vec<(u8, Vec<u8>)> {
        let mut frames = Frames::default();
        for item in out {
            if let Out::Viewer(bytes) = item {
                frames.push(bytes);
            }
        }
        let mut parsed = Vec::new();
        while let Some(f) = frames.next().unwrap() {
            parsed.push(f);
        }
        parsed
    }

    fn welcome(caps: &[&str]) -> Vec<u8> {
        serde_json::to_vec(&json!({
            "t": "welcome", "encoder": "openh264", "width": 1280, "height": 800,
            "max_datagram": 1126, "carrier": "stream", "service": "desktop", "caps": caps
        }))
        .unwrap()
    }

    fn started() -> Vec<u8> {
        serde_json::to_vec(&json!({"t": "started", "session": 1})).unwrap()
    }

    #[test]
    fn without_the_platforms_word_the_splice_changes_no_byte() {
        let mut splice = Splice::new(None, bind());
        let mut out = Vec::new();
        splice.on_viewer(FRAME_CONTROL, hello(), &mut out);
        splice.on_viewer(FRAME_DATAGRAM, b"input".to_vec(), &mut out);
        splice.on_host(FRAME_CONTROL, welcome(&["tile"]), &mut out);
        splice.on_host(FRAME_CONTROL, started(), &mut out);
        assert_eq!(
            out,
            vec![
                Out::Host(frame(FRAME_CONTROL, &hello())),
                Out::Host(frame(FRAME_DATAGRAM, b"input")),
                Out::Viewer(frame(FRAME_CONTROL, &welcome(&["tile"]))),
                Out::Viewer(frame(FRAME_CONTROL, &started())),
            ]
        );
    }

    #[test]
    fn the_hello_gains_the_cap_and_keeps_every_other_field() {
        let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new()).unwrap()), bind());
        let mut out = Vec::new();
        splice.on_viewer(FRAME_CONTROL, hello(), &mut out);
        let sent = controls(&out, true);
        assert_eq!(sent.len(), 1);
        let hello = &sent[0].1;
        assert_eq!(hello["future_field"], 7);
        assert_eq!(hello["caps"], json!(["tile", "link.udp"]));
        // The rd host's own parser reads it.
        let parsed: Control = serde_json::from_value(hello.clone()).unwrap();
        assert!(
            matches!(parsed, Control::Hello { caps, .. } if caps.contains(&LINK_CAP.to_owned()))
        );
    }

    #[test]
    fn a_host_without_the_cap_keeps_every_datagram_on_the_stream() {
        let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new()).unwrap()), bind());
        let mut out = Vec::new();
        splice.on_viewer(FRAME_CONTROL, hello(), &mut out);
        out.clear();
        splice.on_host(FRAME_CONTROL, welcome(&["tile"]), &mut out);
        splice.on_host(FRAME_CONTROL, started(), &mut out);
        assert!(out.contains(&Out::Note("not_answered".into())));
        assert!(controls(&out, true).is_empty(), "no offer: {out:?}");
        assert!(splice.link.is_none());
        out.clear();
        splice.on_viewer(FRAME_DATAGRAM, b"input".to_vec(), &mut out);
        assert_eq!(out, vec![Out::Host(frame(FRAME_DATAGRAM, b"input"))]);
    }

    #[test]
    fn the_offer_waits_for_started_and_the_link_carries_datagrams_both_ways() {
        let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new()).unwrap()), bind());
        let mut out = Vec::new();
        splice.on_viewer(FRAME_CONTROL, hello(), &mut out);
        out.clear();
        splice.on_host(FRAME_CONTROL, welcome(&["tile", "link.udp"]), &mut out);
        // The viewer sees the caps it asked for, and nothing goes to the host yet:
        // the host reads `start` next.
        let seen = controls(&out, false);
        assert_eq!(seen[0].1["caps"], json!(["tile"]));
        assert!(controls(&out, true).is_empty());
        out.clear();
        splice.on_host(FRAME_CONTROL, started(), &mut out);
        let offer = controls(&out, true);
        assert_eq!(offer.len(), 1);
        let Ok(Control::LinkOffer { session, key, .. }) =
            serde_json::from_value(offer[0].1.clone())
        else {
            panic!("not a link_offer the host parses: {:?}", offer[0].1);
        };
        assert_eq!(viewer_frames(&out), vec![(FRAME_CONTROL, started())]);
        // The host's side, as hybrid.rs answers.
        let (mut host, host_key) = DatagramLink::respond(&session, &key, bind()).unwrap();
        out.clear();
        let answer = serde_json::to_vec(&Control::LinkAnswer { key: host_key }).unwrap();
        splice.on_host(FRAME_CONTROL, answer, &mut out);
        let state = serde_json::to_vec(&Control::LinkState { up: true, reason: None }).unwrap();
        splice.on_host(FRAME_CONTROL, state, &mut out);
        assert!(viewer_frames(&out).is_empty(), "link controls never reach the viewer: {out:?}");
        // Bring the link up, candidates crossing as the stream would carry them.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut pending = out;
        while Instant::now() < deadline
            && !(host.is_up() && splice.link.as_ref().is_some_and(DatagramLink::is_up))
        {
            for (ty, c) in controls(&pending, true) {
                if ty == FRAME_CONTROL && c["t"] == "link_candidate" {
                    host.add_remote_candidate(c["candidate"].as_str().unwrap());
                }
            }
            pending = Vec::new();
            splice.poll(&mut pending);
            let mut host_out = Vec::new();
            host.poll(&mut host_out);
            for item in host_out {
                if let LinkOut::Candidate(c) = item {
                    let msg = serde_json::to_vec(&Control::LinkCandidate { candidate: c }).unwrap();
                    let mut ignored = Vec::new();
                    splice.on_host(FRAME_CONTROL, msg, &mut ignored);
                    assert!(
                        viewer_frames(&ignored).is_empty(),
                        "link_candidate never reaches the viewer"
                    );
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(host.is_up(), "host side up");
        // Viewer datagrams now take the link, not the stream.
        let mut out = Vec::new();
        splice.on_viewer(FRAME_DATAGRAM, b"input".to_vec(), &mut out);
        assert!(controls(&out, true).is_empty(), "nothing on the stream: {out:?}");
        host.send_datagram(b"frame");
        let deadline = Instant::now() + Duration::from_secs(5);
        let (mut got_input, mut got_frame) = (false, false);
        while Instant::now() < deadline && !(got_input && got_frame) {
            let mut produced = Vec::new();
            host.poll(&mut produced);
            got_input |= produced.contains(&LinkOut::Datagram(b"input".to_vec()));
            let mut out = Vec::new();
            splice.poll(&mut out);
            got_frame |= viewer_frames(&out).contains(&(FRAME_DATAGRAM, b"frame".to_vec()));
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(got_input && got_frame, "input {got_input} frame {got_frame}");
    }

    /// A carrier stream in memory: what the bridge sends, and what the host says.
    struct FakeRemote {
        sent: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
        incoming: tokio::sync::Mutex<tokio::sync::mpsc::UnboundedReceiver<Vec<u8>>>,
    }

    impl Remote for FakeRemote {
        async fn send(&self, bytes: Bytes) -> Result<(), BridgeError> {
            let _ = self.sent.send(bytes.to_vec());
            Ok(())
        }
        async fn receive(&self) -> Result<Option<Chunk>, BridgeError> {
            Ok(self
                .incoming
                .lock()
                .await
                .recv()
                .await
                .map(|payload| Chunk { payload: Bytes::from(payload), finished: false }))
        }
        async fn close(&self) -> Result<(), BridgeError> {
            Ok(())
        }
        async fn failed(&self) -> BridgeError {
            std::future::pending().await
        }
    }

    #[tokio::test]
    async fn a_viewer_that_stops_reading_still_gets_its_feedback_to_the_host() {
        let (sent_tx, mut sent) = tokio::sync::mpsc::unbounded_channel();
        let (host, incoming) = tokio::sync::mpsc::unbounded_channel();
        let remote = FakeRemote { sent: sent_tx, incoming: tokio::sync::Mutex::new(incoming) };
        // The viewer's output pipe holds 64 bytes and nobody reads it.
        let (viewer_out, _never_read) = tokio::io::duplex(64);
        let (mut viewer_in, bridge_in) = tokio::io::duplex(64 * 1024);
        let bridge = super::bridge(remote, bridge_in, viewer_out, None, |_| {});
        tokio::pin!(bridge);
        let test = async {
            // The host sends more than the pipe holds: the write to the viewer blocks.
            host.send(frame(FRAME_DATAGRAM, &vec![7u8; 16 * 1024])).unwrap();
            tokio::time::sleep(Duration::from_millis(50)).await;
            // The viewer's feedback still reaches the host.
            viewer_in.write_all(&frame(FRAME_DATAGRAM, b"feedback")).await.unwrap();
            tokio::time::timeout(Duration::from_secs(2), sent.recv()).await
        };
        tokio::select! {
            ended = &mut bridge => panic!("the bridge ended: {:?}", ended.err().map(|e| e.to_string())),
            got = test => assert_eq!(got.ok().flatten(), Some(frame(FRAME_DATAGRAM, b"feedback"))),
        }
    }

    #[test]
    fn a_viewer_that_asks_for_the_cap_itself_is_left_alone() {
        let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new()).unwrap()), bind());
        let own = serde_json::to_vec(&json!({"t": "hello", "caps": ["link.udp"]})).unwrap();
        let mut out = Vec::new();
        splice.on_viewer(FRAME_CONTROL, own.clone(), &mut out);
        splice.on_host(FRAME_CONTROL, welcome(&["link.udp"]), &mut out);
        assert_eq!(
            out,
            vec![
                Out::Host(frame(FRAME_CONTROL, &own)),
                Out::Viewer(frame(FRAME_CONTROL, &welcome(&["link.udp"]))),
            ]
        );
    }
}
