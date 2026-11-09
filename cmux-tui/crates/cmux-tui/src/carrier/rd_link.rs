//! The viewer's side of the desktop's datagram link (cmuxterm-hq#7976) in
//! `cmux carrier dial --service desktop`.
//!
//! The app's viewer speaks `cmux.rd/1` frames (`u8 type` 1 control JSON or 2
//! datagram, `u32` little-endian length, payload) on this process's stdin
//! and stdout, and the dial carries them to the machine's desktop socket.
//! When the carrier answer turns the link on (`rd_link`), the dial splices
//! the link in without the viewer knowing:
//! - the viewer's `hello` gains a `link_offer` (cmux-rd-host's `dlink`);
//! - a `welcome` with `link` starts the link, and the field is taken out, so
//!   the viewer sees the welcome it always saw;
//! - `link_candidate` controls cross between the host and the link, never
//!   reaching the viewer;
//! - the viewer's datagrams go on the link while it is up, else on the
//!   stream, and the link's datagrams reach the viewer as stream datagrams.
//!
//! Control never leaves the stream, so a link that never comes up (UDP
//! blocked, no route between the two sides) or that fails changes nothing
//! the viewer can see. A host that does not know the offer ignores it.

use std::io;
use std::net::SocketAddr;
use std::os::fd::{AsRawFd, RawFd};
use std::sync::Arc;

use bytes::Bytes;
use cmux_rd_link::dlink::{DatagramLink, LinkOut, LinkState, ViewerOffer};
use cmux_remote::bridge::BridgeError;
use cmux_remote::service::ServiceStream;
use serde_json::Value;
use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const FRAME_CONTROL: u8 = 1;
const FRAME_DATAGRAM: u8 = 2;
/// The rd host's frame bound (cmux-rd-host `wire.rs`).
const MAX_FRAME: usize = 1 << 20;
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

/// The splice, apart from its I/O.
struct Splice {
    /// Before the hello went out: the offer to put in it.
    offer: Option<ViewerOffer>,
    /// After the hello went out with an offer, until a welcome answers it.
    offered: Option<ViewerOffer>,
    link: Option<DatagramLink>,
    bind: SocketAddr,
}

impl Splice {
    fn new(offer: Option<ViewerOffer>, bind: SocketAddr) -> Self {
        Self { offer, offered: None, link: None, bind }
    }

    /// One frame from the viewer.
    fn from_viewer(&mut self, ty: u8, payload: Vec<u8>, out: &mut Vec<Out>) {
        if ty == FRAME_DATAGRAM {
            match &self.link {
                Some(link) if link.is_up() => link.send_datagram(&payload),
                _ => out.push(Out::Host(frame(ty, &payload))),
            }
            return;
        }
        if ty == FRAME_CONTROL {
            if let Some(offer) = self.offer.take() {
                if let Ok(mut hello) = serde_json::from_slice::<Value>(&payload) {
                    if hello.get("t").and_then(Value::as_str) == Some("hello") {
                        if let (Some(fields), Ok(offer_value)) =
                            (hello.as_object_mut(), serde_json::to_value(&offer.offer))
                        {
                            fields.insert("link_offer".into(), offer_value);
                            out.push(Out::Host(control_frame(&hello)));
                            self.offered = Some(offer);
                            return;
                        }
                    }
                }
                // The first control was not a hello: no link this session.
            }
        }
        out.push(Out::Host(frame(ty, &payload)));
    }

    /// One frame from the host.
    fn from_host(&mut self, ty: u8, payload: Vec<u8>, out: &mut Vec<Out>) {
        if ty != FRAME_CONTROL {
            out.push(Out::Viewer(frame(ty, &payload)));
            return;
        }
        let Ok(mut control) = serde_json::from_slice::<Value>(&payload) else {
            out.push(Out::Viewer(frame(ty, &payload)));
            return;
        };
        match control.get("t").and_then(Value::as_str) {
            Some("link_candidate") => {
                if let (Some(link), Some(candidate)) =
                    (&mut self.link, control.get("candidate").and_then(Value::as_str))
                {
                    link.add_remote_candidate(candidate);
                }
            }
            Some("welcome") => {
                let answer = control.as_object_mut().and_then(|fields| fields.remove("link"));
                if let Some(offer) = self.offered.take() {
                    match answer.map(serde_json::from_value) {
                        Some(Ok(answer)) => match offer.start(&answer, self.bind) {
                            Ok(link) => {
                                out.push(Out::Note("offered".into()));
                                self.link = Some(link);
                                self.poll(out);
                            }
                            Err(why) => out.push(Out::Note(format!("not_started {why}"))),
                        },
                        Some(Err(_)) => out.push(Out::Note("bad_answer".into())),
                        None => out.push(Out::Note("not_answered".into())),
                    }
                }
                out.push(Out::Viewer(control_frame(&control)));
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
                    &serde_json::json!({"t": "link_candidate", "candidate": candidate}),
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

/// Copies the desktop between the viewer (`reader`, `writer`) and the
/// carrier stream, with the datagram link spliced in when `stun` is `Some`
/// (the platform turned it on). Ends as `bridge_raw_stream` does.
pub(super) async fn bridge<R, W>(
    remote: Arc<ServiceStream>,
    mut reader: R,
    mut writer: W,
    stun: Option<Vec<String>>,
    log: impl Fn(&str),
) -> Result<(), BridgeError>
where
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
    let (mut from_viewer, mut from_host) = (Frames::default(), Frames::default());
    let mut link_fd: Option<AsyncFd<Fd>> = None;
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut viewer_open = true;
    let failure = remote.wait_for_failure();
    tokio::pin!(failure);
    loop {
        let mut out = Vec::new();
        let mut finished = false;
        tokio::select! {
            biased;
            error = &mut failure => return Err(error.into()),
            read = reader.read(&mut buffer), if viewer_open => {
                let size = read?;
                if size == 0 {
                    viewer_open = false;
                    remote.close().await?;
                } else {
                    from_viewer.push(&buffer[..size]);
                    while let Some((ty, payload)) = from_viewer.next()? {
                        splice.from_viewer(ty, payload, &mut out);
                    }
                }
            }
            chunk = remote.receive() => {
                match chunk? {
                    Some(chunk) => {
                        from_host.push(&chunk.payload);
                        while let Some((ty, payload)) = from_host.next()? {
                            splice.from_host(ty, payload, &mut out);
                        }
                        finished = chunk.finished || chunk.reset;
                    }
                    None => finished = true,
                }
            }
            () = link_ready(&link_fd) => splice.poll(&mut out),
        }
        for item in out {
            match item {
                Out::Host(bytes) => remote.send(Bytes::from(bytes)).await?,
                Out::Viewer(bytes) => writer.write_all(&bytes).await?,
                Out::Note(note) => log(&note),
            }
        }
        writer.flush().await?;
        // The link starts after a welcome and ends on failure: follow its descriptor.
        let fd = splice.link_fd();
        if fd != link_fd.as_ref().map(|f| f.get_ref().of) {
            link_fd = fd.and_then(Fd::dup).and_then(|fd| AsyncFd::new(fd).ok());
        }
        if finished {
            break;
        }
    }
    writer.shutdown().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_rd_link::dlink::DatagramLink;
    use std::time::{Duration, Instant};

    /// Every interface: the link's host routes are this machine's non-loopback addresses.
    fn bind() -> SocketAddr {
        "0.0.0.0:0".parse().unwrap()
    }

    fn hello() -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "t": "hello", "user": "u", "install": "i", "class": "user", "interactive": true,
            "udp_port": null, "max_datagram": 1200, "service": "desktop", "caps": [],
            "future_field": 7
        }))
        .unwrap()
    }

    fn host_bytes(out: &[Out]) -> Vec<(u8, Value)> {
        let mut frames = Frames::default();
        for item in out {
            if let Out::Host(bytes) = item {
                frames.push(bytes);
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

    fn welcome(link: Option<Value>) -> Vec<u8> {
        let mut w = serde_json::json!({
            "t": "welcome", "encoder": "openh264", "width": 1280, "height": 800,
            "max_datagram": 1126, "carrier": "stream", "service": "desktop", "caps": []
        });
        if let Some(link) = link {
            w["link"] = link;
        }
        serde_json::to_vec(&w).unwrap()
    }

    #[test]
    fn without_the_platforms_word_the_splice_changes_no_byte() {
        let mut splice = Splice::new(None, bind());
        let mut out = Vec::new();
        splice.from_viewer(FRAME_CONTROL, hello(), &mut out);
        splice.from_viewer(FRAME_DATAGRAM, b"input".to_vec(), &mut out);
        splice.from_host(FRAME_CONTROL, welcome(None), &mut out);
        assert_eq!(
            out,
            vec![
                Out::Host(frame(FRAME_CONTROL, &hello())),
                Out::Host(frame(FRAME_DATAGRAM, b"input")),
                Out::Viewer(frame(FRAME_CONTROL, &welcome(None))),
            ]
        );
    }

    #[test]
    fn the_hello_gains_an_offer_and_keeps_every_other_field() {
        let mut splice =
            Splice::new(Some(ViewerOffer::new(vec!["stun.example:3478".into()]).unwrap()), bind());
        let mut out = Vec::new();
        splice.from_viewer(FRAME_CONTROL, hello(), &mut out);
        let sent = host_bytes(&out);
        assert_eq!(sent.len(), 1);
        let hello = &sent[0].1;
        assert_eq!(hello["future_field"], 7);
        assert_eq!(hello["link_offer"]["v"], 1);
        assert_eq!(hello["link_offer"]["stun"][0], "stun.example:3478");
        // The rd host's own parser reads it.
        let parsed: cmux_rd_proto::control::Control =
            serde_json::from_value(hello.clone()).unwrap();
        assert!(matches!(
            parsed,
            cmux_rd_proto::control::Control::Hello { link_offer: Some(_), .. }
        ));
    }

    #[test]
    fn a_host_that_does_not_answer_keeps_every_datagram_on_the_stream() {
        let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new()).unwrap()), bind());
        let mut out = Vec::new();
        splice.from_viewer(FRAME_CONTROL, hello(), &mut out);
        out.clear();
        splice.from_host(FRAME_CONTROL, welcome(None), &mut out);
        assert!(out.contains(&Out::Note("not_answered".into())));
        assert!(splice.link.is_none());
        out.clear();
        splice.from_viewer(FRAME_DATAGRAM, b"input".to_vec(), &mut out);
        assert_eq!(out, vec![Out::Host(frame(FRAME_DATAGRAM, b"input"))]);
    }

    #[test]
    fn an_answered_welcome_reaches_the_viewer_without_link_and_the_link_carries_datagrams() {
        let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new()).unwrap()), bind());
        let mut out = Vec::new();
        splice.from_viewer(FRAME_CONTROL, hello(), &mut out);
        let offer: cmux_rd_proto::control::LinkOffer =
            serde_json::from_value(host_bytes(&out)[0].1["link_offer"].clone()).unwrap();
        let (mut host, answer) = DatagramLink::accept(&offer, bind()).unwrap();
        out.clear();
        splice.from_host(
            FRAME_CONTROL,
            welcome(Some(serde_json::to_value(&answer).unwrap())),
            &mut out,
        );
        let to_viewer = viewer_frames(&out);
        assert_eq!(to_viewer.len(), 1);
        let seen: Value = serde_json::from_slice(&to_viewer[0].1).unwrap();
        assert_eq!(seen["t"], "welcome");
        assert!(seen.get("link").is_none(), "{seen}");
        // Bring the link up, candidates crossing as the stream would carry them.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut host_out = Vec::new();
        let mut pending = out;
        while Instant::now() < deadline
            && !(host.is_up() && splice.link.as_ref().is_some_and(DatagramLink::is_up))
        {
            for (ty, c) in host_bytes(&pending) {
                if ty == FRAME_CONTROL && c["t"] == "link_candidate" {
                    host.add_remote_candidate(c["candidate"].as_str().unwrap());
                }
            }
            pending = Vec::new();
            splice.poll(&mut pending);
            host.poll(&mut host_out);
            for item in host_out.drain(..) {
                if let LinkOut::Candidate(c) = item {
                    let msg = serde_json::to_vec(
                        &serde_json::json!({"t":"link_candidate","candidate":c}),
                    )
                    .unwrap();
                    let mut ignored = Vec::new();
                    splice.from_host(FRAME_CONTROL, msg, &mut ignored);
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
        splice.from_viewer(FRAME_DATAGRAM, b"input".to_vec(), &mut out);
        assert!(host_bytes(&out).is_empty(), "nothing on the stream: {out:?}");
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

    #[test]
    fn an_older_hosts_welcome_parses_and_a_newer_hosts_welcome_parses_in_an_older_viewer() {
        // A host without the field: the proto's Welcome still parses (no link).
        let parsed: cmux_rd_proto::control::Control =
            serde_json::from_slice(&welcome(None)).unwrap();
        assert!(matches!(parsed, cmux_rd_proto::control::Control::Welcome { link: None, .. }));
        // A hello with an offer, as an older host's parser (no field) would read it:
        // serde ignores the unknown field.
        #[derive(serde::Deserialize)]
        #[allow(dead_code)]
        struct OldHello {
            t: String,
            user: String,
            max_datagram: usize,
        }
        let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new()).unwrap()), bind());
        let mut out = Vec::new();
        splice.from_viewer(FRAME_CONTROL, hello(), &mut out);
        let sent = host_bytes(&out);
        let old: OldHello = serde_json::from_value(sent[0].1.clone()).unwrap();
        assert_eq!(old.t, "hello");
    }
}
