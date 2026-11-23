//! One viewer's media session: the I/O loop around this OS's desktop (desktop.rs: damage and
//! injection here, capture and encode on the session's encode thread, encode_thread.rs, so
//! input never waits behind an encode). The media logic (frame gate, congestion control,
//! packetize with FEC, NACK history, recovery, exactly-once input) is the shared engine,
//! cmux-rd-engine (rd change C7 step 2).

use crate::carrier::{Carrier, DatagramDeparture, Incoming};
use crate::clock::now_ns;
use crate::cursor::CursorChannel;
use crate::desktop::{Desktop, FrameSource};
use crate::encode_thread::{Done, EncodeThread};
use crate::fdwait::wait_readable;
use crate::upstream::{UpstreamSink, Upstreams};
use crate::wire::Control;
use crate::Res;
use cmux_rd_core::cc::PathKind;
use cmux_rd_core::flow::Rect;
use cmux_rd_core::pacer::{Pacer, StrictWireBudget};
use cmux_rd_core::policy::Principal;
use cmux_rd_core::profile::EncodeProfile;
use cmux_rd_core::resolution::{LadderConfig, Picture};
use cmux_rd_core::session::{SessionId, SessionTable};
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine, Output};
use cmux_rd_proto::{flags, DatagramHeader, DatagramKind, FrameTimes};
use paced::{PacedFrame, PacedFrames};
use std::collections::VecDeque;

#[path = "stream_paced.rs"]
mod paced;

#[derive(Clone)]
pub struct SessionCfg {
    pub display: String,
    /// Linux X11: the viewer's display pick, an index into the host's display list (`main`
    /// or none is the whole X screen). macOS picks through `display` itself.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub display_pick: Option<String>,
    /// Linux X11: share this one window (an X window id) instead of a display; it wins over
    /// `display_pick`. The session ends when the window is closed or resized. macOS and the
    /// Wayland portal refuse a session that names one.
    #[cfg_attr(not(any(target_os = "linux", target_os = "macos")), allow(dead_code))]
    pub window: Option<u32>,
    pub max_fps: u32,
    /// `--encode-profile`: standard (default) or ultra (the engine marks every frame with it).
    pub encode_profile: cmux_rd_core::profile::EncodeProfile,
    pub start_kbps: u32,
    pub max_kbps: u32,
    #[cfg_attr(target_os = "macos", allow(dead_code))] // software encoders only
    pub preset: String,
    pub profile: String,
    /// `openh264` (default) or `x264` (feature).
    pub codec: String,
    /// Cisco's OpenH264 library for `--codec openh264` (pinned SHA-256; downloaded from
    /// Cisco on this machine, never shipped with cmux).
    #[cfg_attr(target_os = "macos", allow(dead_code))] // software encoders only
    pub openh264_lib: Option<String>,
    /// `screen` (default) or `camera` (openh264 usage).
    #[cfg_attr(target_os = "macos", allow(dead_code))] // software encoders only
    pub content: String,
    #[cfg_attr(target_os = "macos", allow(dead_code))] // software encoders only
    pub threads: u16,
    pub stats_every_ms: u64,
    /// Quiet time after damage before a capture (0 disables).
    pub settle_us: u64,
    /// Development only (`--upstream-record DIR`): write the viewer's
    /// upstream streams to files in this directory. `None` offers no
    /// upstream media.
    pub upstream_record: Option<std::path::PathBuf>,
    /// Most bytes one session records (`--upstream-record-max-mb`, default 1024).
    pub upstream_record_max_bytes: u64,
    /// Frames the engine may have unacknowledged before a hybrid path reports its RTT.
    pub frames_in_flight: u32,
    /// After injected input, frames skip the frame-rate cap for a short window
    /// (`--input-frame-now 1`; the engine's `input_frame_now`).
    pub input_frame_now: bool,
    /// The resolution ladder (design D5, `--resolution-ladder 1`; off by default): below the
    /// bits-per-pixel floor the encoded picture gets smaller, not blurrier.
    pub resolution_ladder: bool,
    /// The ladder's QP ceiling (`--max-qp N`, default
    /// `cmux_rd_core::resolution::DEFAULT_MAX_QP`); unused without the ladder.
    pub max_qp: u8,
    /// macOS: stream at most this many pixels wide (`--max-width`; the display's aspect is
    /// kept). Encode time grows with the pixel count (remote-desktop-mac-host.md section 6).
    #[cfg_attr(target_os = "linux", allow(dead_code))]
    pub max_width: Option<u32>,
    /// macOS: false leaves the cursor out of the stream altogether (the viewer's
    /// `a=cmux-rd-cursor:0`): out of the pictures and no cursor metadata.
    #[cfg_attr(target_os = "linux", allow(dead_code))]
    pub show_cursor: bool,
    /// Linux: how the screen is captured (X11, or the portal on a Wayland session).
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub capture: crate::capture_backend::CaptureBackend,
}

pub struct MediaSession {
    desktop: Box<dyn Desktop>,
    /// Capture and encode, off this thread, so input never waits behind an encode.
    encoder: EncodeThread,
    /// Damage seen while the encode thread was busy, for the frame after its current one.
    held_damage: Option<Rect>,
    engine: MediaEngine,
    /// Upstream media the viewer opened (rd change C4).
    upstreams: Upstreams<Box<dyn UpstreamSink>>,
    stats_frames_sent: u64,
    /// The profile the last encoded frame ran with, as the encoder applied it (None until one
    /// is encoded, and always from an encoder without an ultra mode): the stats line's
    /// `encode_profile`.
    encoded_profile: Option<cmux_rd_core::profile::EncodeProfile>,
    /// Departure receipts drained from the carrier each pump (a reused buffer) and their
    /// running totals for the stats line: what left the socket, not what was queued.
    departures: Vec<DatagramDeparture>,
    departed_datagrams: u64,
    departed_bytes: u64,
    encode_ms: VecDeque<f64>,
    next_stats_ns: u64,
    stats_every_ns: u64,
    cpu_last: (f64, u64),
    settle_ns: u64,
    /// Per-frame times for the screen stream eval, when `CMUX_RD_TIMING_LOG` names a file.
    timing: Option<Timing>,
    /// The cursor as metadata, when the viewer draws it (cap `cursor`) and the desktop
    /// reports it: the pictures leave it out.
    cursor: Option<CursorChannel>,
    /// Clipboard text both ways (cap `clipboard.text`), only while the viewer holds control.
    clipboard: Option<crate::clipboard::ClipboardChannel>,
    /// Spreads each frame's datagrams over part of its frame interval (`None` with
    /// `CMUX_RD_PACE=0`, for comparison): a keyframe written as one burst of hundreds of
    /// datagrams is queued or dropped by a Wi-Fi radio or the kernel.
    pacer: Option<Pacer>,
    frame_interval_us: u64,
    /// Frames still in the pacer that a timing line or the ledger waits on.
    paced: PacedFrames,
    /// The viewer offered cap `ledger`: each frame's host times follow its last shard
    /// (a `FrameTimes` datagram).
    ledger: bool,
}

/// Whether frames are paced (`CMUX_RD_PACE=0` turns it off, for A/B measurement).
fn pacing_enabled() -> bool {
    std::env::var_os("CMUX_RD_PACE").is_none_or(|v| v != "0")
}

/// Original video and FEC shards are one replaceable frame. Key, recovery,
/// tile, repair, and unknown datagrams must stay protected.
fn frame_is_droppable(datagrams: &[Vec<u8>]) -> bool {
    !datagrams.is_empty()
        && datagrams.iter().all(|datagram| {
            let Ok((header, _)) = DatagramHeader::decode(datagram) else { return false };
            matches!(header.kind, DatagramKind::Video | DatagramKind::Fec)
                && header.flags & (flags::KEYFRAME | flags::RECOVERY | flags::TILE) == 0
        })
}

/// A frame shard or parity datagram: what the engine resends on a NACK or a tail-loss
/// probe. These go through the pacer; input acks and clock pongs (small, latency-bound)
/// do not.
fn is_media_datagram(datagram: &[u8]) -> bool {
    DatagramHeader::decode(datagram)
        .is_ok_and(|(header, _)| matches!(header.kind, DatagramKind::Video | DatagramKind::Fec))
}

/// An ultra capacity probe: it leaves at once (the train's dispersion is the measurement),
/// the engine is told when, and its bytes are charged to the pacer's budget.
fn is_probe(datagram: &[u8]) -> bool {
    DatagramHeader::decode(datagram).is_ok_and(|(header, _)| header.kind == DatagramKind::Probe)
}

/// Ultra charges every budgeted byte it sends (media, FEC, repairs, probes) to one strict
/// wire budget (D10), released at the engine's pacing rate (the probed capacity, over the
/// held rate the encoder targets); standard keeps the balanced pacer, which paces at a
/// multiple of the target.
fn new_pacer(profile: EncodeProfile, wire_bps: u64) -> Pacer {
    if profile.is_ultra() {
        Pacer::strict(StrictWireBudget::new(wire_bps))
    } else {
        Pacer::new()
    }
}

/// Where each encoded frame's time went, one JSON line a frame (measurement only; the eval's
/// `scripts/measure/screen-stream-eval` reads it): `input_us`, the last viewer input injected before
/// this frame, once; `shown_us`, the vsync the window server composited the frame for
/// (ScreenCaptureKit's display time, usually a few ms after `arrived_us`);
/// `arrived_us`, when the capture handed it over; `damage_us`, when the session first saw damage
/// since the last frame; `release_us`, when the engine's gate released the frame's request;
/// `capture_start_us`, when the encode thread began the capture (Linux: the XShm readback and
/// I420 conversion run from here to `capture_us`; macOS: taking the newest ScreenCaptureKit
/// frame); `capture_us`, the frame's `t_capture_us` (the capture ended; also on the viewer's
/// frame);
/// `encode_start_us`, when the encoder was handed the picture; `encoded_us`, when the encode
/// ended; `first_sent_us` and `sent_us`, when the pacer handed its first and last datagram to the
/// carrier (the times a `ledger` viewer gets in the frame's `FrameTimes`). Every injected
/// input also gets a line of its own, `{"inject_us", "recv_us"}` (`recv_us`: when the datagram
/// that carried it was read), so a remote viewer's key press can be matched to its injection
/// (`scripts/screen-share-vs.py`). All on the protocol clock in µs.
struct Timing {
    out: std::fs::File,
    input_us: Option<u64>,
    damage_us: Option<u64>,
    /// When the datagram being handled now was read.
    recv_us: Option<u64>,
}

/// What [`Timing::frame`] logs besides the frame's [`FrameTimes`].
struct FrameLog {
    shown: Option<(u64, u64)>,
    capture_start_us: u64,
    capture_us: u64,
    release_us: u64,
    encoded_bytes: usize,
    /// Why the frame is an IDR, or `None` for a delta frame.
    idr_reason: Option<&'static str>,
    /// With a resolution ladder: the picture this frame was encoded at.
    picture: Option<Picture>,
}

impl Timing {
    fn from_env() -> Option<Self> {
        let path = std::env::var_os("CMUX_RD_TIMING_LOG")?;
        match std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            Ok(out) => Some(Self { out, input_us: None, damage_us: None, recv_us: None }),
            Err(e) => {
                eprintln!("cmux-rd host: CMUX_RD_TIMING_LOG {}: {e}", path.to_string_lossy());
                None
            }
        }
    }

    /// One frame's line, without the send times (added when its last datagram leaves).
    fn frame(&mut self, log: FrameLog, times: &FrameTimes) -> serde_json::Value {
        let mut line = serde_json::json!({
            "input_us": self.input_us.take(),
            "shown_us": log.shown.map(|t| t.0),
            "arrived_us": log.shown.map(|t| t.1),
            "damage_us": self.damage_us.take(),
            "release_us": log.release_us,
            "capture_start_us": log.capture_start_us,
            "capture_us": log.capture_us,
            "encode_start_us": times.encode_start_us,
            "encoded_us": times.encoded_us,
            "encoded_bytes": log.encoded_bytes,
            "idr": log.idr_reason.is_some(),
            "idr_reason": log.idr_reason,
        });
        // With a resolution ladder: the picture this frame was encoded at.
        if let (Some(p), Some(fields)) = (log.picture, line.as_object_mut()) {
            fields.insert("width".into(), p.width.into());
            fields.insert("height".into(), p.height.into());
            fields.insert("eighths".into(), p.eighths.into());
            fields.insert("max_qp".into(), p.max_qp.into());
        }
        line
    }

    /// Writes a frame's line once its last datagram was handed to the carrier.
    fn frame_sent(&mut self, mut line: serde_json::Value, times: &FrameTimes) {
        use std::io::Write;
        line["first_sent_us"] = serde_json::json!(times.first_sent_us);
        line["sent_us"] = serde_json::json!(times.last_sent_us);
        let _ = writeln!(self.out, "{line}");
    }

    /// The session opened its capture and encoder: asked at `open_us`, ready at `ready_us`.
    fn opened(&mut self, open_us: u64, ready_us: u64) {
        use std::io::Write;
        let line = serde_json::json!({ "open_us": open_us, "desktop_ready_us": ready_us });
        let _ = writeln!(self.out, "{line}");
    }

    /// An input was injected at `inject_us`.
    fn injected(&mut self, inject_us: u64) {
        use std::io::Write;
        self.input_us = Some(inject_us);
        let line = serde_json::json!({ "inject_us": inject_us, "recv_us": self.recv_us });
        let _ = writeln!(self.out, "{line}");
    }
}

/// Keep the ticket and session alive while a viewer reattaches after a network
/// drop. The viewer's reconnect path can take longer than a short transport
/// blip, including a phone waking from sleep; the session is still bounded.
const REATTACH_GRACE_NS: u64 = 90_000_000_000;

fn viewer_silent_too_long(silent_us: u64) -> bool {
    silent_us > REATTACH_GRACE_NS / 1000
}

/// Whether the session sends the cursor as metadata: the viewer draws it (cap `cursor`) and
/// this OS's desktop can report it.
/// Whether this host offers cap `h264.baseline`: an H.264 encoder that can switch to
/// Constrained Baseline for one session (every H.264 encoder here; VP9 and AV1 have no
/// H.264 profile).
pub fn offers_h264_baseline(codec: &str) -> bool {
    !matches!(codec, "vp9" | "av1")
}

/// The session's settings with the viewer's caps applied: a viewer that negotiated
/// `h264.baseline` (OpenH264, which shows a High-profile stream as wrong pictures with no
/// error, cmux#50591) gets Constrained Baseline whatever `--profile` says.
fn session_cfg<'a>(
    cfg: &'a SessionCfg,
    negotiated_caps: &[String],
) -> std::borrow::Cow<'a, SessionCfg> {
    let baseline = negotiated_caps.iter().any(|c| c == cmux_rd_core::service::caps::H264_BASELINE);
    if baseline && cfg.profile != "baseline" {
        std::borrow::Cow::Owned(SessionCfg { profile: "baseline".into(), ..cfg.clone() })
    } else {
        std::borrow::Cow::Borrowed(cfg)
    }
}

pub(crate) fn wants_cursor(negotiated_caps: &[String]) -> bool {
    crate::desktop::reports_cursor()
        && negotiated_caps.iter().any(|c| c == cmux_rd_core::service::caps::CURSOR)
}

/// Whether the session runs the resolution ladder: the host asked for it and the viewer scales
/// a smaller picture to the stream's size (cap `video.scaled`). A viewer without the cap maps
/// input from the decoded picture's size, so a smaller picture would move its clicks.
fn wants_ladder(asked: bool, negotiated_caps: &[String]) -> bool {
    asked && negotiated_caps.iter().any(|c| c == cmux_rd_core::service::caps::VIDEO_SCALED)
}

fn now_us() -> u64 {
    now_ns() / 1000
}

/// Per-event trace on stderr when `CMUX_RD_TRACE=1` (debugging only).
fn trace(what: &str) {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    if *ON.get_or_init(|| std::env::var_os("CMUX_RD_TRACE").is_some_and(|v| v == "1")) {
        eprintln!("{} {what}", now_us());
    }
}

fn process_cpu_s() -> f64 {
    // SAFETY: rusage is plain old data; all-zero is a valid value.
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: getrusage fills the struct we own.
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let tv = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    tv(ru.ru_utime) + tv(ru.ru_stime)
}

/// A desktop and its frame source (capture and encoder) opened ahead of the session: `cmux-rd
/// serve` opens them while its answer crosses the hub and the link shakes hands, so the first
/// frame is captured by the time the viewer starts. `cursor` is the cursor choice it opened for,
/// asked at `open_us` and ready at `ready_us`.
pub struct OpenedDesktop {
    desktop: Box<dyn Desktop>,
    frames: Box<dyn FrameSource>,
    cursor: bool,
    /// The H.264 profile it was opened for (a `h264.baseline` viewer needs Constrained Baseline).
    profile: String,
    open_us: u64,
    ready_us: u64,
}

impl OpenedDesktop {
    /// Opens this OS's desktop; `cursor`: the viewer draws the cursor (cap `cursor`).
    pub fn open(cfg: &SessionCfg, cursor: bool) -> Res<Self> {
        let open_us = now_us();
        let (desktop, frames) = crate::desktop::open(cfg, cursor)?;
        Ok(Self {
            desktop,
            frames,
            cursor,
            profile: cfg.profile.clone(),
            open_us,
            ready_us: now_us(),
        })
    }
}

impl MediaSession {
    pub fn open(
        cfg: &SessionCfg,
        max_datagram: usize,
        negotiated_caps: &[String],
        sink: Box<dyn UpstreamSink>,
    ) -> Res<Self> {
        let session = &*session_cfg(cfg, negotiated_caps);
        Self::on_desktop(
            OpenedDesktop::open(session, wants_cursor(negotiated_caps))?,
            cfg,
            max_datagram,
            negotiated_caps,
            sink,
        )
    }

    /// A session on a desktop opened earlier (`cmux-rd serve` opens it during the handshake).
    /// One opened for the other cursor choice or H.264 profile than the viewer negotiated is
    /// closed and opened again. `cfg.start_kbps` still sets the first frame's bitrate: the
    /// encoder takes the engine's target before every frame.
    pub fn on_desktop(
        opened: OpenedDesktop,
        cfg: &SessionCfg,
        max_datagram: usize,
        negotiated_caps: &[String],
        sink: Box<dyn UpstreamSink>,
    ) -> Res<Self> {
        let cfg = &*session_cfg(cfg, negotiated_caps);
        let cursor = wants_cursor(negotiated_caps);
        let opened = if opened.cursor == cursor && opened.profile == cfg.profile {
            opened
        } else {
            // The capture closes before it opens again.
            drop(opened);
            OpenedDesktop::open(cfg, cursor)?
        };
        let OpenedDesktop { desktop, frames, open_us, ready_us, .. } = opened;
        let mut session =
            Self::with_desktop(desktop, frames, cfg, max_datagram, negotiated_caps, sink)?;
        if let Some(timing) = session.timing.as_mut() {
            timing.opened(open_us, ready_us);
        }
        Ok(session)
    }

    /// A session on an opened desktop (tests use a fake one).
    fn with_desktop(
        desktop: Box<dyn Desktop>,
        frames: Box<dyn FrameSource>,
        cfg: &SessionCfg,
        max_datagram: usize,
        negotiated_caps: &[String],
        sink: Box<dyn UpstreamSink>,
    ) -> Res<Self> {
        let (w, h) = desktop.size();
        // Phase 1 has no path events from the link yet; the VPC path is the deployed case.
        let mut engine = MediaEngine::new(
            EngineConfig {
                width: w,
                height: h,
                max_fps: cfg.max_fps,
                start_bps: u64::from(cfg.start_kbps) * 1000,
                max_bps: u64::from(cfg.max_kbps) * 1000,
                max_datagram,
                path: PathKind::ViaCloudRegion,
                frames_in_flight: cfg.frames_in_flight,
                input_frame_now: cfg.input_frame_now,
                resolution_ladder: wants_ladder(cfg.resolution_ladder, negotiated_caps)
                    .then(|| LadderConfig { max_qp: Some(cfg.max_qp), ..LadderConfig::default() }),
                ..EngineConfig::default()
            },
            now_us(),
        );
        engine.set_fec_blocks(
            negotiated_caps.iter().any(|c| c == cmux_rd_core::service::caps::FEC_BLOCKS),
        );
        engine.set_profile(cfg.encode_profile);
        let pacer = pacing_enabled().then(|| new_pacer(cfg.encode_profile, engine.pacing_bps()));
        Ok(Self {
            desktop,
            encoder: EncodeThread::spawn(frames)?,
            held_damage: None,
            engine,
            upstreams: Upstreams::new(sink, negotiated_caps),
            stats_frames_sent: 0,
            encoded_profile: None,
            departures: Vec::new(),
            departed_datagrams: 0,
            departed_bytes: 0,
            encode_ms: VecDeque::new(),
            next_stats_ns: now_ns(),
            stats_every_ns: cfg.stats_every_ms * 1_000_000,
            cpu_last: (process_cpu_s(), now_ns()),
            settle_ns: cfg.settle_us * 1000,
            timing: Timing::from_env(),
            cursor: wants_cursor(negotiated_caps).then(CursorChannel::new),
            clipboard: crate::clipboard::open(negotiated_caps, now_us()),
            pacer,
            frame_interval_us: 1_000_000 / u64::from(cfg.max_fps.max(1)),
            paced: PacedFrames::default(),
            ledger: negotiated_caps.iter().any(|c| c == cmux_rd_core::service::caps::LEDGER),
        })
    }

    /// The streamed size (even; an odd last column or row of the display is not sent).
    pub fn size(&self) -> (u32, u32) {
        self.desktop.size()
    }

    pub fn encoder_name(&self) -> String {
        self.encoder.encoder_name()
    }

    /// Runs until the viewer stops, the host stops the session, or the carrier fails, then logs
    /// what the clipboard channel refused. Returns why the session ended.
    pub fn run(
        &mut self,
        carrier: &mut dyn Carrier,
        table: &mut SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) -> String {
        // Measurement only: CMUX_RD_TEST_LOSS_PCT loses media datagrams (off unless set).
        let mut lossy;
        let carrier: &mut dyn Carrier = match crate::test_loss::TestLoss::from_env() {
            Some(loss) => {
                lossy = crate::test_loss::LossyCarrier { inner: carrier, loss };
                &mut lossy
            }
            None => carrier,
        };
        let reason = self.run_until_end(carrier, table, session, viewer);
        if let Some(line) = self.clipboard.as_ref().and_then(|c| c.counters().log_line()) {
            eprintln!("{line}");
        }
        reason
    }

    fn run_until_end(
        &mut self,
        carrier: &mut dyn Carrier,
        table: &mut SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) -> String {
        let mut damage = Vec::new();
        let mut incoming = Vec::new();
        let mut had_control = table.may_inject_input(session, viewer);
        // The first frame covers the whole screen (an IDR).
        if let Some(req) = self.engine.start(now_us()) {
            self.encoder.submit(req);
        }
        loop {
            if !table.may_send_media(session, viewer) {
                return "session not active".into();
            }
            // The viewer sends feedback at least every second. Keep the ticket
            // alive through a full network drop so the viewer can reattach.
            if viewer_silent_too_long(self.engine.silent_for_us(now_us())) {
                return "viewer silent for 90 s".into();
            }
            let now = now_us();
            if let Some(req) = self.engine.poll(now) {
                self.encoder.submit(req);
            }
            if let Err(e) = self.send_paced(carrier) {
                return format!("send failed: {e}");
            }
            // The engine's deadlines and the pacer's next datagram.
            let deadline = [
                self.engine.next_deadline_us(),
                self.pacer.as_ref().and_then(Pacer::next_deadline_us),
            ]
            .into_iter()
            .flatten()
            .min();
            let timeout = deadline.map(|t| t.saturating_sub(now_us()) * 1000);
            let stats_in = self.next_stats_ns.saturating_sub(now_ns());
            // The engine's deadline covers held frames and input held behind a gap.
            let timeout = timeout.map_or(stats_in, |t| t.min(stats_in)).min(REATTACH_GRACE_NS);
            // The next cursor reading (fast while it moves, slow when still).
            let timeout = self.cursor.as_ref().map_or(timeout, |c| {
                timeout.min(c.next_deadline_us().saturating_sub(now_us()).saturating_mul(1000))
            });
            // The next clipboard check or part (only while the viewer holds control).
            let may_control = table.may_inject_input(session, viewer);
            let timeout =
                match self.clipboard.as_ref().and_then(|c| c.next_deadline_us(may_control)) {
                    Some(due) => timeout.min(due.saturating_sub(now_us()).saturating_mul(1000)),
                    None => timeout,
                };
            // Timed input work: a press waiting behind the agent's held button, the person
            // master going idle.
            let wake = if table.may_inject_input(session, viewer) {
                self.desktop.pump().unwrap_or_else(|e| {
                    eprintln!("inject failed: {e}");
                    None
                })
            } else {
                None
            };
            let timeout = wake
                .map_or(timeout, |d| timeout.min(u64::try_from(d.as_nanos()).unwrap_or(u64::MAX)));
            let timeout = Some(timeout.max(1_000_000));
            let mut fds = carrier.fds();
            fds.push(self.desktop.fd());
            fds.push(self.encoder.fd());
            if let Err(e) = wait_readable(&fds, timeout) {
                return format!("wait failed: {e}");
            }
            incoming.clear();
            if let Err(reason) = carrier.receive(&mut incoming) {
                return reason;
            }
            self.engine.update_frames_in_flight_from_rtt(carrier.path_rtt_us());
            for item in incoming.drain(..) {
                match item {
                    Incoming::Control(control) => match *control {
                        Control::Stop => return "stopped by viewer".into(),
                        Control::Clipboard { seq, text, offset, total } => {
                            // Applied only in a control session; without the cap, ignored.
                            let may_control = table.may_inject_input(session, viewer);
                            if let Some(clipboard) = self.clipboard.as_mut() {
                                let part = cmux_rd_proto::clipboard::ClipboardPart {
                                    seq,
                                    text,
                                    offset,
                                    total,
                                };
                                clipboard.on_part(part, may_control);
                            }
                        }
                        control => {
                            let may_control = table.may_inject_input(session, viewer);
                            if let Some(answer) =
                                self.upstreams.on_control(&mut self.engine, &control, may_control)
                            {
                                if let Err(e) = carrier.send_control(&answer) {
                                    return format!("control write failed: {e}");
                                }
                            }
                        }
                    },
                    Incoming::Datagram(datagram) => {
                        self.on_datagram(carrier, &datagram, table, session, viewer)
                    }
                }
            }
            // Socket/proxy carriers do not expose a link path event. Once a
            // cumulative frame acknowledgement arrives, use its measured RTT
            // to size the BDP-equivalent send window just like the secure link.
            self.engine.update_frames_in_flight_from_rtt(carrier.path_rtt_us());
            // A frame the encode thread finished: packetize and send it.
            if let Err(e) = self.send_encoded(carrier) {
                return format!("encode/send failed: {e}");
            }
            // Damage from the desktop.
            damage.clear();
            if let Err(e) = self.drain_settled(&mut damage) {
                return format!("capture failed: {e}");
            }
            // One gate decision for everything that settled together.
            let merged = damage.iter().copied().reduce(Rect::union);
            if let (Some(_), Some(timing)) = (merged, self.timing.as_mut()) {
                timing.damage_us.get_or_insert(now_us());
            }
            if let Some(r) = merged {
                self.held_damage = Some(self.held_damage.map_or(r, |held| held.union(r)));
            }
            // While a frame encodes, damage waits here: the next frame captures the newest
            // picture once the encode thread is free, instead of queueing frames behind it.
            if self.encoder.is_idle() {
                if let Some(r) = self.held_damage.take() {
                    let req = self.engine.damage(0, r, now_us());
                    trace(&format!("damage {r:?} -> {req:?}"));
                    if let Some(req) = req {
                        self.encoder.submit(req);
                    }
                }
            }
            let may_inject = table.may_inject_input(session, viewer);
            if had_control && !may_inject {
                // Control just ended: release what the viewer holds and drop queued input.
                self.release_input();
            }
            had_control = may_inject;
            if !may_inject {
                // Control ended: the viewer's microphone and camera stop with it.
                for closed in self.upstreams.close_all(&mut self.engine) {
                    let _ = carrier.send_control(&Control::StreamClose { stream: closed });
                }
            }
            let out = self.engine.tick(may_inject, now_us());
            self.apply(carrier, out, table, session, viewer);
            // Acks, NACKs and arrivals for the viewer's upstream senders.
            while let Some(datagram) = self.engine.upstream_feedback(now_us()) {
                let _ = carrier.send_datagram(&datagram);
            }
            if let Err(e) = self.send_cursor(carrier) {
                return format!("control write failed: {e}");
            }
            if let Some(clipboard) = self.clipboard.as_mut() {
                if let Some(part) = clipboard.poll(now_us(), may_inject) {
                    if let Err(e) = carrier.send_control(&part) {
                        return format!("control write failed: {e}");
                    }
                }
            }
            if now_ns() >= self.next_stats_ns {
                self.send_stats(carrier);
            }
        }
    }

    /// Reads the cursor when its channel is due and sends what changed: a new shape on the
    /// control stream, then the position as a datagram.
    fn send_cursor(&mut self, carrier: &mut dyn Carrier) -> std::io::Result<()> {
        let Some(channel) = self.cursor.as_mut() else { return Ok(()) };
        let now = now_us();
        if !channel.due(now) {
            return Ok(());
        }
        let Some(sample) = self.desktop.cursor() else {
            channel.missed(now);
            return Ok(());
        };
        let out = channel.on_sample(&sample, now);
        if let Some(shape) = out.shape {
            carrier.send_control(&shape)?;
        }
        if let Some(datagram) = out.datagram {
            // Latest wins: a lost position is replaced by the next one.
            let _ = carrier.send_datagram(&datagram);
        }
        Ok(())
    }

    /// Drains damage, then keeps draining while more arrives within `settle_ns` (at most
    /// four times), so an app that draws one change with several requests is captured
    /// whole instead of torn (measured: a torn first frame cost one frame interval).
    fn drain_settled(&mut self, out: &mut Vec<Rect>) -> Res<()> {
        self.desktop.drain(out)?;
        if out.is_empty() || self.settle_ns == 0 {
            return Ok(());
        }
        for _ in 0..4 {
            let before = out.len();
            wait_readable(&[self.desktop.fd()], Some(self.settle_ns))?;
            self.desktop.drain(out)?;
            if out.len() == before {
                break;
            }
        }
        Ok(())
    }

    /// Hands the engine the frame the encode thread finished, if there is one, and sends its
    /// datagrams.
    /// Drains the carrier's bounded departure receipts so they never overflow while a session
    /// runs; the totals go out with the stats line.
    fn take_departures(&mut self, carrier: &mut dyn Carrier) {
        carrier.drain_departures(&mut self.departures);
        self.departed_datagrams += self.departures.len() as u64;
        self.departed_bytes += self.departures.iter().map(|d| d.wire_bytes as u64).sum::<u64>();
        self.departures.clear();
    }

    fn send_encoded(&mut self, carrier: &mut dyn Carrier) -> Res<()> {
        self.take_departures(carrier);
        let Some(Done { req, result }) = self.encoder.take_done()? else { return Ok(()) };
        let frame = result?;
        let idr = frame.idr.then(|| idr_reason(&req, frame.idr_cause));
        if let Some(reason) = idr {
            // Every keyframe says why, timing log or not: one costs many delta frames' bytes.
            eprintln!(
                "cmux-rd host: idr stream={} frame={} reason={reason} bytes={}",
                req.stream,
                req.frame,
                frame.access_unit.len()
            );
        }
        let times = FrameTimes {
            display_us: frame.picked_times.map_or(0, |(shown, _)| shown),
            encode_start_us: frame.encode_start_us,
            encoded_us: frame.encoded_us,
            ..FrameTimes::default()
        };
        let logged = self.timing.is_some().then_some(FrameLog {
            shown: frame.picked_times,
            capture_start_us: frame.capture_start_us,
            capture_us: frame.t_capture_us,
            release_us: frame.released_us,
            encoded_bytes: frame.access_unit.len(),
            idr_reason: idr,
            picture: req.picture,
        });
        self.encoded_profile = frame.profile;
        self.encode_ms.push_back(frame.encode_ms);
        if self.encode_ms.len() > 120 {
            self.encode_ms.pop_front();
        }
        let encoded = Encoded {
            access_unit: frame.access_unit,
            idr: frame.idr,
            t_capture_us: frame.t_capture_us,
        };
        let out =
            self.engine.encoded(&req, Some(encoded), now_us()).map_err(|e| format!("{e:?}"))?;
        if out.halve_bitrate {
            // Too large to send (about 4.6 MB): the engine dropped it and asks for a keyframe.
            self.encoder.halve_bitrate();
        }
        let line = match (self.timing.as_mut(), logged) {
            (Some(timing), Some(log)) => Some(timing.frame(log, &times)),
            _ => None,
        };

        // LinkCarrier owns the bounded whole-frame queue. Do not put a second
        // pacer queue in front of it: hand over the complete frame and let the
        // link drain/replacement policy decide what can wait.
        if carrier.media_queue_stats().is_some() || self.pacer.is_none() {
            return Ok(self.send_whole_frame(carrier, out.datagrams, times, &req, line)?);
        }
        let Some(pacer) = self.pacer.as_mut() else { return Ok(()) };
        if out.datagrams.is_empty() {
            return Ok(());
        }
        if line.is_some() || self.ledger {
            self.paced.push(PacedFrame {
                remaining: out.datagrams.len(),
                stream: req.stream,
                frame: req.frame,
                times,
                line,
            });
        }
        pacer.push_frame(out.datagrams, self.engine.target_bps(), self.frame_interval_us, now_us());
        // Ultra's strict queue keeps its bound by dropping whole older unstarted frames
        // (D2, newest wins): retire them, so a datagram never sent is not read as loss.
        let dropped = pacer.take_dropped();
        if !dropped.is_empty() {
            let frames: std::collections::BTreeSet<(u16, u32)> = dropped
                .iter()
                .filter_map(|d| DatagramHeader::decode(d).ok().map(|(h, _)| (h.stream, h.frame)))
                .collect();
            trace(&format!(
                "strict queue full: dropped {} unstarted frames ({} in all)",
                frames.len(),
                pacer.frames_dropped()
            ));
            self.paced.forget(|stream, frame| frames.contains(&(stream, frame)));
            self.engine.forget_unsent(&dropped);
        }
        Ok(self.send_paced(carrier)?)
    }

    /// Hands a whole frame to the carrier at once (no pacer in front of it), then
    /// sends its ledger times and finishes its timing line.
    fn send_whole_frame(
        &mut self,
        carrier: &mut dyn Carrier,
        datagrams: Vec<Vec<u8>>,
        mut times: FrameTimes,
        req: &EncodeRequest,
        line: Option<serde_json::Value>,
    ) -> std::io::Result<()> {
        let sent_any = !datagrams.is_empty();
        let droppable = frame_is_droppable(&datagrams);
        times.first_sent_us = now_us();
        carrier.send_datagram_frame(datagrams, droppable)?;
        times.last_sent_us = now_us();
        if self.ledger && sent_any {
            // Measurement only: a lost one leaves the viewer's row without host times.
            let _ = carrier.send_datagram(&times.datagram(req.stream, req.frame));
        }
        if let (Some(timing), Some(line)) = (self.timing.as_mut(), line) {
            timing.frame_sent(line, &times);
        }
        Ok(())
    }

    /// Sends the paced datagrams that are due, telling the engine when each left.
    fn send_paced(&mut self, carrier: &mut dyn Carrier) -> std::io::Result<()> {
        let Some(pacer) = self.pacer.as_mut() else { return Ok(()) };
        // Ultra: the strict budget follows the engine's pacing rate (a probe result, a
        // standing-queue cut). Balanced pacing ignores it.
        pacer.set_rate_bps(self.engine.pacing_bps());
        let now = now_us();
        let due = pacer.due(now);
        // Repairs left first; only the frame datagrams count toward a frame's send time.
        let left = pacer.take_frame_datagrams_sent();
        for datagram in &due {
            carrier.send_datagram(datagram)?;
            self.engine.datagram_sent(datagram, now);
        }
        for done in self.paced.sent(left, now, now_us()) {
            if self.ledger {
                // Measurement only: a lost one leaves the viewer's row without host times.
                let _ = carrier.send_datagram(&done.times.datagram(done.stream, done.frame));
            }
            if let (Some(timing), Some(line)) = (self.timing.as_mut(), done.line) {
                timing.frame_sent(line, &done.times);
            }
        }
        Ok(())
    }

    /// D12: the path came back from an outage. What queued in the pacer while the
    /// radio was away delays the newest picture, but dropping a frame the encoder
    /// predicts from costs a keyframe; the engine picks the whole unstarted frames
    /// worth dropping (`outage_drop_plan`). They leave the queue and its timing
    /// lines, then the engine retires them (else their missing receipts read as
    /// loss) and makes the next frame a keyframe where one is needed.
    fn drop_stale_queue(&mut self, out: &mut Output) {
        let Some(pacer) = self.pacer.as_mut() else { return };
        let drop = self.engine.outage_drop_plan(pacer.queued(), out);
        if drop.is_empty() {
            return;
        }
        let is_dropped = |d: &[u8]| {
            DatagramHeader::decode(d).is_ok_and(|(h, _)| {
                matches!(h.kind, DatagramKind::Video | DatagramKind::Fec)
                    && drop.contains(&(h.stream, h.frame))
            })
        };
        let stale = pacer.take_where(is_dropped);
        self.paced.forget(|stream, frame| drop.contains(&(stream, frame)));
        trace(&format!(
            "outage ended: dropped {} queued datagrams of {} unstarted frames",
            stale.len(),
            drop.len()
        ));
        self.engine.retire_unsent(&stale, out, now_us());
    }

    /// Sends an engine output's datagrams, injects its input and hands its
    /// requested frame to the encode thread.
    fn apply(
        &mut self,
        carrier: &mut dyn Carrier,
        mut out: Output,
        table: &SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) {
        if out.outage_ended.is_some() {
            self.drop_stale_queue(&mut out);
        }
        self.send_output(carrier, std::mem::take(&mut out.datagrams));
        self.upstreams.deliver(&out.upstream);
        if out.release_all {
            let _ = self.desktop.release_all();
        }
        for event in &out.inject {
            self.inject(event, table, session, viewer);
        }
        if let Some(req) = out.encode {
            self.encoder.submit(req);
        }
    }

    /// Sends an engine output's datagrams: resent frame shards (NACK answers, tail-loss
    /// probes) through the pacer, ahead of queued frames, so a recovery never leaves as an
    /// unpaced burst; everything else at once. An ultra probe train leaves at once too (its
    /// dispersion is the measurement): the engine's probe planner is told when each probe
    /// left, and the strict pacer is charged its bytes.
    fn send_output(&mut self, carrier: &mut dyn Carrier, datagrams: Vec<Vec<u8>>) {
        let Some(pacer) = self.pacer.as_mut() else {
            for datagram in &datagrams {
                let _ = carrier.send_datagram(datagram);
                if is_probe(datagram) {
                    self.engine.datagram_sent(datagram, now_us());
                }
            }
            return;
        };
        let (repairs, direct): (Vec<_>, Vec<_>) =
            datagrams.into_iter().partition(|d| is_media_datagram(d));
        for datagram in &direct {
            let _ = carrier.send_datagram(datagram);
            if is_probe(datagram) {
                let now = now_us();
                self.engine.datagram_sent(datagram, now);
                pacer.set_rate_bps(self.engine.pacing_bps());
                pacer.charge(datagram.len(), now);
            }
        }
        if !repairs.is_empty() {
            pacer.push_repair(repairs, self.engine.target_bps(), now_us());
            if let Err(e) = self.send_paced(carrier) {
                eprintln!("cmux-rd host: paced repair send failed: {e}");
            }
        }
    }

    fn on_datagram(
        &mut self,
        carrier: &mut dyn Carrier,
        datagram: &[u8],
        table: &SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) {
        let may_inject = table.may_inject_input(session, viewer);
        let now = now_us();
        if let Some(timing) = self.timing.as_mut() {
            timing.recv_us = Some(now);
        }
        let out = self.engine.on_datagram(datagram, may_inject, now);
        self.apply(carrier, out, table, session, viewer);
        if let Some(timing) = self.timing.as_mut() {
            timing.recv_us = None;
        }
    }

    fn inject(
        &mut self,
        event: &cmux_rd_proto::InputEvent,
        table: &SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) {
        if !table.may_inject_input(session, viewer) {
            let _ = self.desktop.release_all();
            self.engine.reset_input();
            return;
        }
        trace(&format!("inject {event:?}"));
        if let Err(e) = self.desktop.inject(event) {
            eprintln!("inject failed: {e}");
        }
        if let Some(timing) = self.timing.as_mut() {
            timing.injected(now_us());
        }
    }

    /// Ends every upstream stream (called on every end of a session).
    pub fn close_upstreams(&mut self) {
        let _ = self.upstreams.close_all(&mut self.engine);
    }

    /// Releases every key and button the viewer holds on the host and forgets held input
    /// (called on every end of a session).
    pub fn release_input(&mut self) {
        let _ = self.desktop.release_all();
        self.engine.reset_input();
    }

    fn send_stats(&mut self, carrier: &mut dyn Carrier) {
        self.take_departures(carrier);
        let now = now_ns();
        self.next_stats_ns = now + self.stats_every_ns.max(100_000_000);
        // Stats only while frames flow: an idle session sends nothing.
        let stats = self.engine.stats();
        if stats.frames == self.stats_frames_sent {
            return;
        }
        self.stats_frames_sent = stats.frames;
        let cpu = process_cpu_s();
        let cpu_pct =
            (cpu - self.cpu_last.0) / ((now - self.cpu_last.1) as f64 / 1e9).max(1e-3) * 100.0;
        self.cpu_last = (cpu, now);
        let mut sorted: Vec<f64> = self.encode_ms.iter().copied().collect();
        sorted.sort_by(f64::total_cmp);
        let encode_ms_p50 = sorted.get(sorted.len() / 2).copied().unwrap_or(0.0);
        let queue = carrier.media_queue_stats();
        let stats = Control::Stats {
            kbps: self.encoder.kbps(),
            frames: stats.frames,
            keyframes: stats.keyframes,
            cpu_pct,
            encode_ms_p50,
            loss_pct: stats.loss * 100.0,
            queue_frames: queue.map(|stats| stats.queue_frames),
            queue_datagrams: queue.map(|stats| stats.queue_datagrams),
            queue_dropped_frames: queue.map(|stats| stats.dropped_frames),
            queue_dropped_datagrams: queue.map(|stats| stats.dropped_datagrams),
            queue_dropped_replaced_frames: queue.map(|stats| stats.dropped_replaced_frames),
            queue_dropped_replaced_datagrams: queue.map(|stats| stats.dropped_replaced_datagrams),
            queue_dropped_evicted_for_protected_frames: queue
                .map(|stats| stats.dropped_evicted_for_protected_frames),
            queue_dropped_evicted_for_protected_datagrams: queue
                .map(|stats| stats.dropped_evicted_for_protected_datagrams),
            queue_dropped_rejected_protected_frames: queue
                .map(|stats| stats.dropped_rejected_protected_frames),
            queue_dropped_rejected_protected_datagrams: queue
                .map(|stats| stats.dropped_rejected_protected_datagrams),
            departed_datagrams: Some(self.departed_datagrams),
            departed_bytes: Some(self.departed_bytes),
            departure_overflows: Some(carrier.departure_overflows()),
            encode_profile: self.encoded_profile.map(|profile| profile.as_str().to_owned()),
        };
        let _ = carrier.send_control(&stats);
    }
}

/// Why an encoded IDR is one: the engine's ask, else the encoder's own cause, else
/// `encoder` for an encoder that cannot say.
fn idr_reason(req: &EncodeRequest, cause: Option<&'static str>) -> &'static str {
    req.idr_reason.map(|r| r.as_str()).or(cause).unwrap_or("encoder")
}

#[cfg(test)]
mod tests {
    use super::{idr_reason, viewer_silent_too_long, wants_ladder};
    use cmux_rd_core::flow::Rect;
    use cmux_rd_engine::{EncodeRequest, IdrReason};

    #[test]
    fn viewer_silence_allows_the_ninety_second_reattach_window() {
        assert!(!viewer_silent_too_long(90_000_000));
        assert!(viewer_silent_too_long(90_000_001));
    }

    #[test]
    fn the_ladder_runs_only_for_a_viewer_that_scales_a_smaller_picture() {
        let scaled = vec!["cursor".to_string(), "video.scaled".to_string()];
        let old = vec!["cursor".to_string()];
        assert!(wants_ladder(true, &scaled));
        assert!(!wants_ladder(true, &old), "an old viewer's clicks would move");
        assert!(!wants_ladder(false, &scaled), "off unless the host asks for it");
    }

    #[test]
    fn an_idr_names_the_engines_ask_then_the_encoders_cause() {
        let req = |reason: Option<IdrReason>| EncodeRequest {
            stream: 0,
            frame: 9,
            damage: Rect { x: 0, y: 0, width: 16, height: 16 },
            force_idr: reason.is_some(),
            idr_reason: reason,
            target_kbps: 8_000,
            picture: None,
            profile: Default::default(),
            refine: false,
        };
        assert_eq!(idr_reason(&req(Some(IdrReason::Recovery)), None), "recovery");
        assert_eq!(idr_reason(&req(Some(IdrReason::Start)), Some("resize")), "start");
        assert_eq!(idr_reason(&req(None), Some("scene_change")), "scene_change");
        assert_eq!(idr_reason(&req(None), None), "encoder");
    }
}

#[cfg(test)]
#[path = "stream_encode_tests.rs"]
mod encode_off_loop_tests;

/// D12 detector, host half: when an outage ends, what queued in the pacer during it never
/// goes out, its missing receipts are not loss, and the newest frame goes out next as a
/// keyframe.
#[cfg(test)]
#[path = "stream_outage_tests.rs"]
mod outage_drop_tests;

/// D10 ultra on the host: the strict one-budget pacer at the engine's held rate, and a
/// probe train that leaves at once, is timed for the planner and raises the held rate.
#[cfg(test)]
#[path = "stream_ultra_tests.rs"]
mod ultra_tests;
