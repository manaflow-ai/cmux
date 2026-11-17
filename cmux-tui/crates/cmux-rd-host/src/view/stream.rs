//! The viewer's network half: one thread that holds the secure link, reassembles and decodes
//! frames, sends feedback and input, and hands the window the newest decoded picture
//! (design D2: newest wins, no stage holds more than one frame; D7: one hop, no helper
//! process). The window thread (window.rs) presents at most one picture per display refresh
//! and turns the person's keyboard, pointer and scroll into input events for this thread.

use super::window::{self, Window};
use super::{FromHub, ToHub};
use crate::clock::now_ns;
use crate::fdwait::wait_readable;
use crate::wire::Control;
use crate::Res;
use cmux_encode::openh264::OpenH264Decoder;
use cmux_encode::{VideoDecoder, I420};
use cmux_rd_core::input::InputSender;
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_core::service::SERVICE_DESKTOP;
use cmux_rd_link::net::{Net, NetEvent};
use cmux_rd_link::{EndpointEvent, Event};
use cmux_rd_proto::{
    Arrival, DatagramHeader, DatagramKind, Feedback, InputEvent, HEADER_LEN, MAX_ARRIVALS,
    MAX_DATAGRAM_VPC,
};
use serde_json::json;
use std::os::fd::RawFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

/// The cap that asks a host for H.264 Constrained Baseline (cmux#44497), the profile OpenH264
/// decodes. A host that does not know it ignores it.
const H264_BASELINE: &str = "h264.baseline";
/// The reassembler's wait for a missing shard (the bench's default).
const DEADLINE_US: u64 = 200_000;
/// Input not yet acknowledged repeats this often.
const INPUT_REPEAT_NS: u64 = 20_000_000;
const FEEDBACK_EVERY_NS: u64 = 50_000_000;
/// At least one feedback per second keeps the session alive on an idle screen.
const KEEPALIVE_NS: u64 = 1_000_000_000;

pub struct Config {
    pub display: String,
    pub title: String,
    /// `full` scope: the window's input goes to the host.
    pub control: bool,
    pub viewer_id: String,
    pub stats_file: Option<PathBuf>,
}

pub struct Ended {
    pub reason: String,
    pub connected: bool,
}

/// A pipe a thread waits on: a byte means "look at your queue".
#[derive(Clone)]
pub struct Waker(Arc<Pipe>);

static INTERRUPTED: AtomicBool = AtomicBool::new(false);
/// The write end of the pipe a Ctrl-C wakes; -1 before [`Waker::wake_on_interrupt`].
static INTERRUPT_FD: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_interrupt(_: libc::c_int) {
    if INTERRUPTED.swap(true, Ordering::SeqCst) {
        // A second Ctrl-C while the session is still ending: stop now.
        // SAFETY: _exit(2) is async-signal-safe.
        unsafe { libc::_exit(130) };
    }
    let fd = INTERRUPT_FD.load(Ordering::SeqCst);
    if fd >= 0 {
        // SAFETY: write(2) is async-signal-safe; the pipe outlives the session.
        unsafe { libc::write(fd, [1u8].as_ptr().cast(), 1) };
    }
}

/// Restores SIGINT and SIGTERM to their defaults and forgets the pipe when dropped.
pub struct InterruptHook;

impl Drop for InterruptHook {
    fn drop(&mut self) {
        // SAFETY: resetting to SIG_DFL; the store keeps a late handler from writing anywhere.
        unsafe {
            libc::signal(libc::SIGINT, libc::SIG_DFL);
            libc::signal(libc::SIGTERM, libc::SIG_DFL);
        }
        INTERRUPT_FD.store(-1, Ordering::SeqCst);
    }
}

/// Whether Ctrl-C or SIGTERM asked the viewer to stop.
pub fn interrupted() -> bool {
    INTERRUPTED.load(Ordering::SeqCst)
}

struct Pipe {
    read: RawFd,
    write: RawFd,
}

impl Drop for Pipe {
    fn drop(&mut self) {
        // SAFETY: our own descriptors, closed once.
        unsafe {
            libc::close(self.read);
            libc::close(self.write);
        }
    }
}

impl Waker {
    pub fn new() -> Res<Self> {
        let mut fds = [0; 2];
        // SAFETY: pipe2 fills the two-element array we own.
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Self(Arc::new(Pipe { read: fds[0], write: fds[1] })))
    }

    pub fn wake(&self) {
        // SAFETY: a one-byte write to our own non-blocking pipe; a full pipe already wakes.
        unsafe { libc::write(self.0.write, [1u8].as_ptr().cast(), 1) };
    }

    pub fn fd(&self) -> RawFd {
        self.0.read
    }

    /// Ctrl-C (SIGINT) or SIGTERM wakes this pipe and sets [`interrupted`], so the viewer ends
    /// the session (Stop, bye, the report) instead of dying mid-stream.
    /// The hook lasts as long as the returned guard: dropping it restores the default
    /// handlers, so a Ctrl-C after the session never writes into a closed (reused) pipe.
    pub fn wake_on_interrupt(&self) -> Res<InterruptHook> {
        INTERRUPT_FD.store(self.0.write, Ordering::SeqCst);
        // SAFETY: the handler only stores to an atomic and writes one byte to a pipe, both
        // async-signal-safe; the zeroed sigaction is then filled in before use.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = on_interrupt as extern "C" fn(libc::c_int) as libc::sighandler_t;
            action.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut action.sa_mask);
            for sig in [libc::SIGINT, libc::SIGTERM] {
                if libc::sigaction(sig, &action, std::ptr::null_mut()) != 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
            }
        }
        Ok(InterruptHook)
    }

    /// Clears the wake-ups.
    pub fn drain(&self) {
        let mut buf = [0u8; 64];
        // SAFETY: reads into our buffer from our own non-blocking pipe until it is empty.
        while unsafe { libc::read(self.0.read, buf.as_mut_ptr().cast(), buf.len()) } > 0 {}
    }
}

/// One decoded picture (I420, BT.601 video range) and when it was complete and decoded.
pub struct Picture {
    pub image: I420,
    /// When the frame's last shard arrived (this machine's monotonic clock, ns).
    pub complete_ns: u64,
    pub decoded_ns: u64,
}

impl Picture {
    pub fn height(&self) -> usize {
        self.image.y.len().checked_div(self.image.width).unwrap_or(0)
    }
}

/// The one-picture hand-off to the window: a newer picture replaces one not yet presented
/// (counted), and the buffers go back and forth instead of being allocated per frame.
#[derive(Default)]
pub struct Mailbox {
    pub ready: Option<Picture>,
    pub spare: Option<Picture>,
    pub replaced: u64,
    pub closed: bool,
}

pub type SharedMailbox = Arc<Mutex<Mailbox>>;

/// Cisco's OpenH264 decoder, downloaded from Cisco into the per-user directory on first use
/// and loaded only after its pinned SHA-256 matches (never a source build in this binary).
pub fn open_decoder() -> Res<OpenH264Decoder> {
    let platform = cmux_encode::openh264::Platform::current()
        .ok_or("Cisco publishes no OpenH264 for this platform")?;
    let dir = cmux_encode::cisco::default_dir().ok_or("no per-user data directory (set HOME)")?;
    let path = cmux_encode::cisco::install(&dir, platform)?;
    let api = cmux_encode::openh264::load_verified(&path, platform)?;
    OpenH264Decoder::new(api)
}

struct Stats {
    frames: u64,
    decoded: u64,
    decode_errors: u64,
    bytes: u64,
    decode_ms: Vec<f64>,
    started_ns: u64,
}

/// Runs the session until it ends: the link's events, the hub's messages and the window's input.
pub fn run(
    net: Net,
    mut decoder: OpenH264Decoder,
    config: &Config,
    from_hub: &mpsc::Receiver<FromHub>,
    hub_waker: &Waker,
    to_hub: &mpsc::Sender<ToHub>,
) -> Res<Ended> {
    let mailbox: SharedMailbox = Arc::default();
    let present_waker = Waker::new()?;
    let input_waker = Waker::new()?;
    let _interrupt_hook = input_waker.wake_on_interrupt()?;
    let (input_tx, input_rx) = mpsc::channel::<InputEvent>();
    let window_done = Arc::new(AtomicBool::new(false));
    let win = Window::open(&config.display, &config.title, config.control)?;
    let window_thread = {
        let (mailbox, present_waker, input_waker, done) =
            (mailbox.clone(), present_waker.clone(), input_waker.clone(), window_done.clone());
        std::thread::Builder::new().name("rd-view-window".into()).spawn(move || {
            let report = win.run(&mailbox, &present_waker, &input_tx, &input_waker);
            done.store(true, Ordering::SeqCst);
            input_waker.wake();
            report
        })?
    };

    let mut reassembler = Reassembler::new(DEADLINE_US);
    // Every frame decodes into this; the newest of a batch is swapped into the mailbox.
    let mut current = I420::new(2, 2);
    let mut sender = InputSender::new();
    let mut arrivals: Vec<Arrival> = Vec::new();
    let mut stats = Stats {
        frames: 0,
        decoded: 0,
        decode_errors: 0,
        bytes: 0,
        decode_ms: Vec::new(),
        started_ns: now_ns(),
    };
    let (mut last_feedback_ns, mut released_since_feedback) = (0u64, false);
    let mut last_input_send_ns = 0u64;
    let (mut connected, mut started, mut welcome) = (false, false, None);
    let mut path_kind: Option<String> = None;
    let mut host_stats = None;
    let ended: String = 'run: loop {
        let timeout_ns = reassembler
            .next_nack_us(5_000, 50_000)
            .map_or(FEEDBACK_EVERY_NS, |d| d.saturating_mul(1000).saturating_sub(now_ns()))
            .min(if sender.is_empty() { FEEDBACK_EVERY_NS } else { INPUT_REPEAT_NS });
        wait_readable(&[net.event_fd(), hub_waker.fd(), input_waker.fd()], Some(timeout_ns))?;
        hub_waker.drain();
        input_waker.drain();
        for message in from_hub.try_iter() {
            match message {
                FromHub::Candidate(c) => net.add_remote_candidate(c),
                FromHub::End(reason) => break 'run reason,
            }
        }
        if window_done.load(Ordering::SeqCst) {
            break 'run "the window was closed".into();
        }
        if interrupted() {
            break 'run "stopped (Ctrl-C)".into();
        }
        for event in net.events() {
            match event {
                NetEvent::Candidate(c) => {
                    let _ = to_hub.send(ToHub::Candidate(c.to_wire()));
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    connected = true;
                    if !started {
                        started = true;
                        start_session(&net, config)?;
                    }
                }
                NetEvent::Endpoint(EndpointEvent::PathChanged {
                    kind: Some(k), rtt_us, ..
                }) => {
                    let name = k.wire_name().to_owned();
                    let relayed = cmux_hub_host::rd_doc::is_relayed(&name);
                    let _ = to_hub.send(ToHub::Path(if relayed { "relay" } else { "direct" }));
                    eprintln!(
                        "Path: {name}{}",
                        rtt_us.map_or(String::new(), |us| format!(
                            ", rtt {:.1} ms",
                            us as f64 / 1000.0
                        ))
                    );
                    path_kind = Some(name);
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    match serde_json::from_slice::<Control>(&record) {
                        Ok(Control::Welcome { encoder, width, height, caps, .. }) => {
                            eprintln!(
                                "Streaming {width}x{height} ({encoder}{})",
                                if caps.iter().any(|c| c == H264_BASELINE) {
                                    ", baseline"
                                } else {
                                    ""
                                }
                            );
                            welcome = Some(
                                json!({"encoder": encoder, "width": width, "height": height, "caps": caps}),
                            );
                        }
                        Ok(Control::Refused { reason } | Control::Ended { reason }) => {
                            break 'run format!("the host ended the stream: {reason}");
                        }
                        Ok(Control::Stats { .. }) => {
                            host_stats = serde_json::from_slice::<serde_json::Value>(&record).ok();
                        }
                        _ => {}
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                    on_datagram(
                        &d,
                        &mut reassembler,
                        &mut decoder,
                        &mut current,
                        &mut sender,
                        &mut arrivals,
                        &mut stats,
                        &mailbox,
                        &present_waker,
                        &mut released_since_feedback,
                    );
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    break 'run "the host closed the link".into();
                }
                NetEvent::Failed(reason) => break 'run format!("the link failed: {reason}"),
                _ => {}
            }
        }
        let now = now_ns();
        reassembler.tick(now / 1000);
        if started {
            maybe_feedback(
                &net,
                &mut reassembler,
                &mut arrivals,
                &stats,
                &mut last_feedback_ns,
                &mut released_since_feedback,
            );
            // The person's input goes at once; unacknowledged input repeats on a timer.
            let mut fresh = false;
            for event in input_rx.try_iter() {
                if config.control {
                    sender.push(event);
                    fresh = true;
                }
            }
            let packet = if fresh {
                sender.packet()
            } else if !sender.is_empty()
                && now.saturating_sub(last_input_send_ns) >= INPUT_REPEAT_NS
            {
                sender.repeat_packet()
            } else {
                None
            };
            if let Some(packet) = packet {
                let mut d = Vec::with_capacity(HEADER_LEN + 64);
                header(DatagramKind::Input).encode_into(&mut d);
                d.extend_from_slice(&packet.encode());
                net.send_datagram(d);
                last_input_send_ns = now;
            }
        } else {
            // Nothing to send before the stream starts.
            input_rx.try_iter().for_each(drop);
        }
    };
    if started {
        net.send_control(serde_json::to_vec(&Control::Stop)?);
    }
    mailbox.lock().unwrap_or_else(|e| e.into_inner()).closed = true;
    present_waker.wake();
    let window_report =
        window_thread.join().unwrap_or_else(|_| Err("the window thread panicked".into()));
    let window_report = window_report.unwrap_or_else(|e| {
        eprintln!("cmux-rd view: window: {e}");
        window::Report::default()
    });
    let replaced = mailbox.lock().unwrap_or_else(|e| e.into_inner()).replaced;
    let secs = (now_ns() - stats.started_ns) as f64 / 1e9;
    let report = json!({
        "view": {
            "ended": ended,
            "connected": connected,
            "path": path_kind,
            "welcome": welcome,
            "seconds": secs,
            "frames": stats.frames,
            "decoded": stats.decoded,
            "decode_errors": stats.decode_errors,
            "mbit_per_s": stats.bytes as f64 * 8.0 / secs.max(1e-3) / 1e6,
            "decode_ms": pct(&mut stats.decode_ms),
            "presented": window_report.presented,
            "replaced_before_present": replaced,
            "present_ms": pct(&mut window_report.present_ms.clone()),
            "decoded_to_presented_ms": pct(&mut window_report.decoded_to_presented_ms.clone()),
            "key_to_presented_ms": pct(&mut window_report.key_to_presented_ms.clone()),
            "refresh_paced": window_report.refresh_paced,
            "host_stats_last": host_stats,
        }
    });
    eprintln!("{report}");
    if let Some(path) = &config.stats_file {
        std::fs::write(path, format!("{report}\n"))?;
    }
    Ok(Ended { reason: ended, connected })
}

fn header(kind: DatagramKind) -> DatagramHeader {
    DatagramHeader {
        flags: 0,
        kind,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
}

/// `hello` and `start` once the link is up: the desktop service, input when controlling, and
/// Constrained Baseline for OpenH264.
fn start_session(net: &Net, config: &Config) -> Res<()> {
    let hello = Control::Hello {
        user: config.viewer_id.clone(),
        install: config.viewer_id.clone(),
        class: "user".into(),
        interactive: true,
        udp_port: None,
        max_datagram: MAX_DATAGRAM_VPC,
        token: None,
        service: SERVICE_DESKTOP.into(),
        caps: vec![H264_BASELINE.into()],
    };
    net.send_control(serde_json::to_vec(&hello)?);
    let start = Control::Start {
        key: format!("view-{}-{}", std::process::id(), now_ns()),
        mode: if config.control { "control" } else { "view" }.into(),
    };
    net.send_control(serde_json::to_vec(&start)?);
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn on_datagram(
    d: &[u8],
    reassembler: &mut Reassembler,
    decoder: &mut OpenH264Decoder,
    current: &mut I420,
    sender: &mut InputSender,
    arrivals: &mut Vec<Arrival>,
    stats: &mut Stats,
    mailbox: &SharedMailbox,
    present_waker: &Waker,
    released_since_feedback: &mut bool,
) {
    let now = now_ns();
    let Ok((h, payload)) = DatagramHeader::decode(d) else { return };
    match h.kind {
        DatagramKind::Video | DatagramKind::Fec => {
            stats.bytes += d.len() as u64;
            arrivals
                .push(Arrival { transport_seq: h.transport_seq, arrival_us: (now / 1000) as u32 });
            let released = reassembler.push(&h, payload, now / 1000);
            let last = released.len().saturating_sub(1);
            for (i, frame) in released.into_iter().enumerate() {
                *released_since_feedback = true;
                stats.frames += 1;
                // Every frame decodes (later frames reference it); only the newest of this
                // batch goes to the window.
                let t0 = now_ns();
                match decoder.decode(&frame.body.access_unit, current) {
                    Ok(true) => {
                        let t1 = now_ns();
                        stats.decode_ms.push((t1 - t0) as f64 / 1e6);
                        stats.decoded += 1;
                        if i == last {
                            hand_off(mailbox, current, now, t1);
                            present_waker.wake();
                        }
                    }
                    Ok(false) => {}
                    Err(_) => stats.decode_errors += 1,
                }
            }
        }
        DatagramKind::InputAck if payload.len() >= 4 => {
            sender.ack(u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]));
        }
        _ => {}
    }
}

/// Swaps `current` into the mailbox, replacing a picture the window has not taken (newest
/// wins). `current` gets an old buffer back for the next decode: no copy, no allocation.
fn hand_off(mailbox: &SharedMailbox, current: &mut I420, complete_ns: u64, decoded_ns: u64) {
    let mut slot = mailbox.lock().unwrap_or_else(|e| e.into_inner());
    let mut picture = match slot.ready.take() {
        Some(old) => {
            slot.replaced += 1;
            old
        }
        None => slot.spare.take().unwrap_or_else(|| Picture {
            image: I420::new(2, 2),
            complete_ns: 0,
            decoded_ns: 0,
        }),
    };
    std::mem::swap(&mut picture.image, current);
    (picture.complete_ns, picture.decoded_ns) = (complete_ns, decoded_ns);
    slot.ready = Some(picture);
}

fn maybe_feedback(
    net: &Net,
    reassembler: &mut Reassembler,
    arrivals: &mut Vec<Arrival>,
    stats: &Stats,
    last_feedback_ns: &mut u64,
    released_since_feedback: &mut bool,
) {
    let now = now_ns();
    let since = now.saturating_sub(*last_feedback_ns);
    let nack_due =
        reassembler.next_nack_us(5_000, 50_000).is_some_and(|deadline| now / 1000 >= deadline);
    if !(*released_since_feedback
        || since >= KEEPALIVE_NS
        || nack_due
        || (since >= FEEDBACK_EVERY_NS && (!arrivals.is_empty() || reassembler.need_recovery())))
    {
        return;
    }
    let nacks = reassembler.take_nacks(now / 1000, 5_000, 50_000);
    let mut recent: Vec<f64> = stats.decode_ms.iter().rev().take(30).copied().collect();
    recent.sort_by(f64::total_cmp);
    let send = |fb: &Feedback| {
        let mut d = Vec::with_capacity(HEADER_LEN + 64);
        header(DatagramKind::Feedback).encode_into(&mut d);
        d.extend_from_slice(&fb.encode());
        net.send_datagram(d);
    };
    while arrivals.len() > MAX_ARRIVALS {
        let rest = arrivals.split_off(MAX_ARRIVALS);
        let head = std::mem::replace(arrivals, rest);
        send(&Feedback {
            acked_frame: reassembler.last_released(),
            arrivals: head,
            ..Feedback::default()
        });
    }
    send(&Feedback {
        acked_frame: reassembler.last_released(),
        decode_us: recent.get(recent.len() / 2).map_or(0, |m| (m * 1000.0) as u32),
        need_recovery: reassembler.need_recovery(),
        arrivals: std::mem::take(arrivals),
        nacks,
    });
    *last_feedback_ns = now;
    *released_since_feedback = false;
}

pub fn pct(xs: &mut [f64]) -> serde_json::Value {
    if xs.is_empty() {
        return json!(null);
    }
    xs.sort_by(f64::total_cmp);
    let q = |p: f64| xs[((p / 100.0) * (xs.len() - 1) as f64).round() as usize];
    json!({"n": xs.len(), "p50": q(50.0), "p95": q(95.0), "max": xs[xs.len() - 1]})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(w: usize, h: usize, fill: u8) -> I420 {
        let mut p = I420::new(w, h);
        p.y.fill(fill);
        p
    }

    #[test]
    fn the_newest_picture_wins_and_replacements_are_counted() {
        let mailbox: SharedMailbox = Arc::default();
        let mut current = picture(4, 2, 1);
        hand_off(&mailbox, &mut current, 10, 11);
        current = picture(4, 2, 2);
        hand_off(&mailbox, &mut current, 20, 21);
        let mut slot = mailbox.lock().unwrap();
        assert_eq!(slot.replaced, 1);
        let shown = slot.ready.take().unwrap();
        assert_eq!((shown.image.y[0], shown.complete_ns, shown.height()), (2, 20, 2));
        assert_eq!(current.y[0], 1, "the replaced buffer comes back for the next decode");
        assert!(slot.ready.is_none());
    }

    #[test]
    fn a_waker_wakes_a_wait_and_drains() {
        let w = Waker::new().unwrap();
        w.wake();
        let t = now_ns();
        wait_readable(&[w.fd()], Some(1_000_000_000)).unwrap();
        assert!(now_ns() - t < 500_000_000);
        w.drain();
        let t = now_ns();
        wait_readable(&[w.fd()], Some(20_000_000)).unwrap();
        assert!(now_ns() - t >= 15_000_000, "drained pipe is not readable");
    }

    #[test]
    fn percentiles_of_samples() {
        let mut xs = vec![5.0, 1.0, 3.0, 2.0, 4.0];
        let p = pct(&mut xs);
        assert_eq!(
            (p["p50"].as_f64(), p["max"].as_f64(), p["n"].as_u64()),
            (Some(3.0), Some(5.0), Some(5))
        );
        assert!(pct(&mut []).is_null());
    }

    #[test]
    fn ctrl_c_wakes_the_session_loop_and_marks_it_interrupted() {
        let w = Waker::new().unwrap();
        INTERRUPT_FD.store(w.0.write, Ordering::SeqCst);
        assert!(!interrupted());
        on_interrupt(libc::SIGINT);
        assert!(interrupted());
        wait_readable(&[w.fd()], Some(1_000_000_000)).unwrap();
        let mut buf = [0u8; 4];
        // SAFETY: a read into our buffer from our own non-blocking pipe.
        assert_eq!(unsafe { libc::read(w.fd(), buf.as_mut_ptr().cast(), 4) }, 1);
        INTERRUPT_FD.store(-1, Ordering::SeqCst);
    }
}
