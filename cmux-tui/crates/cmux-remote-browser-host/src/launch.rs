//! The launch contract between `--serve` and the app that starts it
//! (remote-tab-r2.md, local host): the app runs
//! `cmux-remote-browser-host --serve --listen 127.0.0.1:0 --lifeline`, reads
//! one [`listening_line`] from stdout to learn the port the OS gave, and
//! keeps the write end of the host's stdin open. When the app closes it (the
//! tab closed, the app quit or crashed), [`watch_lifeline`] sees end of file
//! and the host quits. No polling and no process scanning: the pipe is the
//! signal.

use std::collections::VecDeque;
use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::{Arc, Mutex, PoisonError, mpsc};
use std::time::{Duration, Instant};

use cmux_rd_proto::control::Control;
use cmux_rd_proto::{STREAM_CONTROL, StreamDeframer, encode_stream_frame};

/// The stdout key of the readiness line.
pub const LISTENING_KEY: &str = "listening";

/// The one stdout line `--serve` writes once it accepts viewers: a JSON
/// object, for example `{"listening":"127.0.0.1:52144"}`, with the bound
/// address (the real port when the request was port 0).
pub fn listening_line(bound: SocketAddr) -> String {
    serde_json::json!({ LISTENING_KEY: bound.to_string() }).to_string()
}

/// Reads `input` until end of file or a read error, then calls `on_eof`
/// once. Bytes written to the lifeline are ignored.
pub fn watch_lifeline<R: Read>(mut input: R, on_eof: impl FnOnce()) {
    let mut buf = [0u8; 256];
    loop {
        match input.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
    }
    on_eof();
}

/// Reads the per-launch secret: the first line the app writes to the
/// lifeline (stdin), never the command line or the environment. `None` when
/// stdin ends first or the line is empty.
pub fn read_secret<R: std::io::BufRead>(input: &mut R) -> Option<String> {
    let mut line = String::new();
    input.read_line(&mut line).ok()?;
    let secret = line.trim_end_matches(['\n', '\r']);
    (!secret.is_empty()).then(|| secret.to_string())
}

/// Whether a viewer may join: its rd `hello` must carry the host's
/// per-launch secret as its session token. A host without a secret admits
/// nobody (there is no open mode). Checked before the welcome, so a refused
/// viewer never opens the tab or sends input.
pub fn authorize(secret: Option<&str>, hello: &Control) -> Result<(), &'static str> {
    let Some(secret) = secret.filter(|secret| !secret.is_empty()) else {
        return Err("the host has no per-launch secret");
    };
    let Control::Hello { token: Some(token), .. } = hello else {
        return Err("the viewer's hello carries no session token");
    };
    // Constant time (subtle), so timing does not leak the secret. A length
    // mismatch returns early; the length (64 hex characters) is public.
    use subtle::ConstantTimeEq;
    if bool::from(secret.as_bytes().ct_eq(token.0.as_bytes())) {
        Ok(())
    } else {
        Err("the viewer's session token is not the host's secret")
    }
}

/// `--listen` must be a loopback address: a host never serves other machines.
pub fn loopback_only(addr: SocketAddr) -> Result<SocketAddr, &'static str> {
    if addr.ip().is_loopback() { Ok(addr) } else { Err("--listen must be a loopback address") }
}

/// The result of [`admit`]: the viewer's hello and the deframer that holds the
/// bytes it sent after it, or why the viewer was turned away.
pub enum Admission {
    Admitted { hello: Control, deframer: StreamDeframer },
    Refused(String),
}

/// How long a viewer has to send its hello, in total. A caller that sends
/// nothing or trickles bytes holds one of [`MAX_PENDING_HELLOS`] admissions
/// until then (or until newer callers push it out); the app's viewer sends
/// its hello at once.
pub const HELLO_DEADLINE: Duration = Duration::from_secs(3);

/// One viewer's admission on the rd stream carrier, before the host sends a
/// welcome or opens a tab:
/// - the first frame must be an rd control `hello` that passes [`authorize`];
///   a refused hello gets an rd `refused` and nothing else;
/// - bytes that are not rd framing (a browser page's HTTP request, through a
///   no-cors fetch or a DNS-rebound name) close the connection with no reply;
/// - the hello must arrive within [`HELLO_DEADLINE`].
pub fn admit(stream: &mut TcpStream, secret: Option<&str>) -> std::io::Result<Admission> {
    admit_within(stream, secret, HELLO_DEADLINE)
}

/// [`admit`] with an explicit hello deadline. Leaves the stream's read
/// timeout at the time left (the caller sets its own afterwards).
pub fn admit_within(
    stream: &mut TcpStream,
    secret: Option<&str>,
    deadline: Duration,
) -> std::io::Result<Admission> {
    let until = Instant::now() + deadline;
    let mut deframer = StreamDeframer::default();
    let mut buf = vec![0u8; 4 * 1024];
    let (kind, payload) = loop {
        match deframer.next_frame() {
            Ok(Some(frame)) => break frame,
            Ok(None) => {}
            Err(_) => return Ok(Admission::Refused("not an rd stream".into())),
        }
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Ok(Admission::Refused("no hello before the deadline".into()));
        }
        stream.set_read_timeout(Some(left))?;
        let n = match stream.read(&mut buf) {
            Ok(n) => n,
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                return Ok(Admission::Refused("no hello before the deadline".into()));
            }
            Err(e) => return Err(e),
        };
        if n == 0 {
            return Ok(Admission::Refused("left before hello".into()));
        }
        deframer.extend(&buf[..n]);
    };
    let hello = if kind == STREAM_CONTROL {
        serde_json::from_slice::<Control>(&payload).ok()
    } else {
        None
    };
    let checked = match hello {
        Some(hello) => authorize(secret, &hello).map(|()| hello),
        None => Err("the first frame is not an rd control message"),
    };
    match checked {
        Ok(hello) => Ok(Admission::Admitted { hello, deframer }),
        Err(reason) => {
            write_control(stream, &Control::Refused { reason: "unauthorized".into() })?;
            Ok(Admission::Refused(format!("refused: {reason}")))
        }
    }
}

/// A viewer [`accept_viewers`] admitted: its stream, its hello and the bytes
/// it sent after the hello.
pub struct Admitted {
    pub stream: TcpStream,
    pub hello: Control,
    pub deframer: StreamDeframer,
}

/// How many callers may wait for their hello at once. A caller past the cap
/// closes the oldest waiting one, so callers that never send a hello cannot
/// keep the app's viewer (which sends its hello at once) out by filling it.
pub const MAX_PENDING_HELLOS: usize = 32;

/// The `--serve` accept loop: admits each caller on `listener` on its own
/// thread ([`admit_within`] with `deadline`) and runs `session` for each
/// admitted viewer, one at a time, on the calling thread. A caller that
/// never sends a hello holds only its own admission, never the viewer slot,
/// so the app's viewer is admitted while it waits.
pub fn accept_viewers(
    listener: TcpListener,
    secret: Option<String>,
    deadline: Duration,
    mut session: impl FnMut(Admitted),
) {
    let (admitted, viewers) = mpsc::channel::<Admitted>();
    let pending: Arc<Mutex<VecDeque<(u64, TcpStream)>>> = Arc::default();
    let secret: Option<Arc<str>> = secret.map(Arc::from);
    // supervise-allow: the acceptor of accept_viewers; a panic drops its `admitted` sender, so once in-flight admissions end `viewers` closes and accept_viewers returns to its caller, as when the listener ends.
    let accept =
        cmux_threads::spawn("rb-accept", cmux_threads::ThreadQos::UserInitiated, move || {
            for (id, conn) in (0u64..).zip(listener.incoming()) {
                // A failed accept or a peer that reset before setsockopt ends
                // only that connection, never the listener.
                let mut stream = match conn {
                    Ok(conn) => conn,
                    Err(e) => {
                        eprintln!("serve: accept failed: {e}");
                        continue;
                    }
                };
                let waiting = match stream.set_nodelay(true).and_then(|()| stream.try_clone()) {
                    Ok(waiting) => waiting,
                    Err(e) => {
                        eprintln!("serve: connection dropped: {e}");
                        continue;
                    }
                };
                {
                    let mut pending = pending.lock().unwrap_or_else(PoisonError::into_inner);
                    if pending.len() >= MAX_PENDING_HELLOS
                        && let Some((_, oldest)) = pending.pop_front()
                    {
                        // Its admission reads end of file and refuses it.
                        let _ = oldest.shutdown(Shutdown::Both);
                    }
                    pending.push_back((id, waiting));
                }
                let (waiters, secret, admitted) =
                    (pending.clone(), secret.clone(), admitted.clone());
                let admission = move || {
                    let outcome = admit_within(&mut stream, secret.as_deref(), deadline);
                    waiters
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .retain(|(p, _)| *p != id);
                    match outcome {
                        Ok(Admission::Admitted { hello, deframer }) => {
                            let _ = admitted.send(Admitted { stream, hello, deframer });
                        }
                        Ok(Admission::Refused(reason)) => {
                            eprintln!("serve: session ended: {reason}")
                        }
                        Err(e) => eprintln!("serve: session failed: {e}"),
                    }
                };
                // supervise-allow: one viewer's admission, bounded by `deadline`; a panic drops its stream (refused) and its `pending` slot is cut by the next accept's cap.
                if let Err(e) = cmux_threads::spawn(
                    "rb-admission",
                    cmux_threads::ThreadQos::UserInitiated,
                    admission,
                ) {
                    // The closure (and its stream) is dropped; the slot it took
                    // in `pending` closes with it.
                    eprintln!("serve: connection dropped: {e}");
                    pending
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .retain(|(p, _)| *p != id);
                }
            }
        });
    if let Err(e) = accept {
        // No viewer can arrive: `viewers` ends at once with its sender dropped.
        eprintln!("serve: accept loop did not start: {e}");
    }
    for viewer in viewers {
        session(viewer);
    }
}

/// Writes one rd control frame.
pub fn write_control<W: Write>(stream: &mut W, control: &Control) -> std::io::Result<()> {
    let json = serde_json::to_vec(control).map_err(std::io::Error::other)?;
    let mut out = Vec::with_capacity(json.len() + 5);
    encode_stream_frame(STREAM_CONTROL, &json, &mut out)
        .map_err(|e| std::io::Error::other(format!("{e:?}")))?;
    stream.write_all(&out)
}
