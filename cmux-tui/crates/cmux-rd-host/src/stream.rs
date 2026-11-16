//! One viewer's media session: the I/O loop around this OS's desktop (desktop.rs: damage and
//! injection here, capture and encode on the session's encode thread, encode_thread.rs, so
//! input never waits behind an encode). The media logic (frame gate, congestion control,
//! packetize with FEC, NACK history, recovery, exactly-once input) is the shared engine,
//! cmux-rd-engine (rd change C7 step 2).

use crate::carrier::{Carrier, Incoming};
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
use cmux_rd_core::pacer::Pacer;
use cmux_rd_core::policy::Principal;
use cmux_rd_core::session::{SessionId, SessionTable};
use cmux_rd_engine::{Encoded, EngineConfig, MediaEngine, Output};
use std::collections::VecDeque;

#[derive(Clone)]
pub struct SessionCfg {
    pub display: String,
    pub max_fps: u32,
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
    /// macOS: stream at most this many pixels wide (`--max-width`; the display's aspect is
    /// kept). Encode time grows with the pixel count (remote-desktop-mac-host.md section 6).
    #[cfg_attr(target_os = "linux", allow(dead_code))]
    pub max_width: Option<u32>,
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
    /// Spreads each frame's datagrams over part of its frame interval (`None` with
    /// `CMUX_RD_PACE=0`, for comparison): a keyframe written as one burst of hundreds of
    /// datagrams is queued or dropped by a Wi-Fi radio or the kernel.
    pacer: Option<Pacer>,
    frame_interval_us: u64,
    /// Timing lines of frames still in the pacer: datagrams left, the line without `sent_us`.
    paced_logs: VecDeque<(usize, serde_json::Value)>,
}

/// Whether frames are paced (`CMUX_RD_PACE=0` turns it off, for A/B measurement).
fn pacing_enabled() -> bool {
    std::env::var_os("CMUX_RD_PACE").is_none_or(|v| v != "0")
}

/// Where each encoded frame's time went, one JSON line a frame (measurement only; the eval's
/// `scripts/measure/screen-stream-eval` reads it): `input_us`, the last viewer input injected before
/// this frame, once; `shown_us`, when the display showed the frame (ScreenCaptureKit's display time);
/// `arrived_us`, when the capture handed it over; `damage_us`, when the session first saw damage
/// since the last frame; `release_us`, when the gate let the encode start; `encoded_us`, when the
/// encode ended; `sent_us`, when its last datagram was handed to the carrier. Every injected
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

    /// One frame's line, without `sent_us` (added when its last datagram leaves).
    fn frame(
        &mut self,
        shown: Option<(u64, u64)>,
        release_us: u64,
        encoded_us: u64,
        encoded_bytes: usize,
        idr_reason: Option<&'static str>,
    ) -> serde_json::Value {
        serde_json::json!({
            "input_us": self.input_us.take(),
            "shown_us": shown.map(|t| t.0),
            "arrived_us": shown.map(|t| t.1),
            "damage_us": self.damage_us.take(),
            "release_us": release_us,
            "encoded_us": encoded_us,
            "encoded_bytes": encoded_bytes,
            "idr": idr_reason.is_some(),
            "idr_reason": idr_reason,
        })
    }

    /// Writes a frame's line once its last datagram was handed to the carrier at `sent_us`.
    fn frame_sent(&mut self, mut line: serde_json::Value, sent_us: u64) {
        use std::io::Write;
        line["sent_us"] = serde_json::json!(sent_us);
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
fn wants_cursor(negotiated_caps: &[String]) -> bool {
    crate::desktop::reports_cursor()
        && negotiated_caps.iter().any(|c| c == cmux_rd_core::service::caps::CURSOR)
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

impl MediaSession {
    pub fn open(
        cfg: &SessionCfg,
        max_datagram: usize,
        negotiated_caps: &[String],
        sink: Box<dyn UpstreamSink>,
    ) -> Res<Self> {
        let open_us = now_us();
        let (desktop, frames) = crate::desktop::open(cfg, wants_cursor(negotiated_caps))?;
        let ready_us = now_us();
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
        let engine = MediaEngine::new(
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
                ..EngineConfig::default()
            },
            now_us(),
        );
        Ok(Self {
            desktop,
            encoder: EncodeThread::spawn(frames)?,
            held_damage: None,
            engine,
            upstreams: Upstreams::new(sink, negotiated_caps),
            stats_frames_sent: 0,
            encode_ms: VecDeque::new(),
            next_stats_ns: now_ns(),
            stats_every_ns: cfg.stats_every_ms * 1_000_000,
            cpu_last: (process_cpu_s(), now_ns()),
            settle_ns: cfg.settle_us * 1000,
            timing: Timing::from_env(),
            cursor: wants_cursor(negotiated_caps).then(CursorChannel::new),
            pacer: pacing_enabled().then(Pacer::new),
            frame_interval_us: 1_000_000 / u64::from(cfg.max_fps.max(1)),
            paced_logs: VecDeque::new(),
        })
    }

    /// The streamed size (even; an odd last column or row of the display is not sent).
    pub fn size(&self) -> (u32, u32) {
        self.desktop.size()
    }

    pub fn encoder_name(&self) -> String {
        self.encoder.encoder_name()
    }

    /// Runs until the viewer stops, the host stops the session, or the carrier fails.
    pub fn run(
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
                    Incoming::Control(Control::Stop) => return "stopped by viewer".into(),
                    Incoming::Control(control) => {
                        let may_control = table.may_inject_input(session, viewer);
                        if let Some(answer) =
                            self.upstreams.on_control(&mut self.engine, &control, may_control)
                        {
                            if let Err(e) = carrier.send_control(&answer) {
                                return format!("control write failed: {e}");
                            }
                        }
                    }
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
    fn send_encoded(&mut self, carrier: &mut dyn Carrier) -> Res<()> {
        let Some(Done { req, result }) = self.encoder.take_done()? else { return Ok(()) };
        let frame = result?;
        // Logged after the send, with the send time (`sent_us`).
        let logged = self.timing.is_some().then(|| {
            let len = frame.access_unit.len();
            // An IDR the engine did not ask for is the encoder's own choice.
            let idr = frame.idr.then(|| req.idr_reason.map_or("encoder", |r| r.as_str()));
            (frame.picked_times, frame.t_capture_us, frame.encoded_us, len, idr)
        });
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
            (Some(timing), Some((shown, t_capture_us, encoded_us, len, idr))) => {
                Some(timing.frame(shown, t_capture_us, encoded_us, len, idr))
            }
            _ => None,
        };
        let Some(pacer) = self.pacer.as_mut() else {
            carrier.send_datagram_frame(out.datagrams)?;
            if let (Some(timing), Some(line)) = (self.timing.as_mut(), line) {
                timing.frame_sent(line, now_us());
            }
            return Ok(());
        };
        if out.datagrams.is_empty() {
            return Ok(());
        }
        if let Some(line) = line {
            self.paced_logs.push_back((out.datagrams.len(), line));
        }
        pacer.push_frame(out.datagrams, self.engine.target_bps(), self.frame_interval_us, now_us());
        Ok(self.send_paced(carrier)?)
    }

    /// Sends the paced datagrams that are due, telling the engine when each left.
    fn send_paced(&mut self, carrier: &mut dyn Carrier) -> std::io::Result<()> {
        let Some(pacer) = self.pacer.as_mut() else { return Ok(()) };
        let now = now_us();
        let due = pacer.due(now);
        for datagram in &due {
            carrier.send_datagram(datagram)?;
            self.engine.datagram_sent(datagram, now);
        }
        let mut left = due.len();
        while left > 0 {
            let Some((remaining, _)) = self.paced_logs.front_mut() else { break };
            let take = left.min(*remaining);
            *remaining -= take;
            left -= take;
            if *remaining == 0 {
                if let (Some((_, line)), Some(timing)) =
                    (self.paced_logs.pop_front(), self.timing.as_mut())
                {
                    timing.frame_sent(line, now_us());
                }
            }
        }
        Ok(())
    }

    /// Sends an engine output's datagrams, injects its input and hands its
    /// requested frame to the encode thread.
    fn apply(
        &mut self,
        carrier: &mut dyn Carrier,
        out: Output,
        table: &SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) {
        for datagram in &out.datagrams {
            let _ = carrier.send_datagram(datagram);
        }
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
        let stats = Control::Stats {
            kbps: self.encoder.kbps(),
            frames: stats.frames,
            keyframes: stats.keyframes,
            cpu_pct,
            encode_ms_p50,
            loss_pct: stats.loss * 100.0,
        };
        let _ = carrier.send_control(&stats);
    }
}

#[cfg(test)]
mod tests {
    use super::viewer_silent_too_long;

    #[test]
    fn viewer_silence_allows_the_ninety_second_reattach_window() {
        assert!(!viewer_silent_too_long(90_000_000));
        assert!(viewer_silent_too_long(90_000_001));
    }
}

#[cfg(test)]
mod encode_off_loop_tests {
    use super::*;
    use crate::carrier::{Carrier, Incoming};
    use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, PrincipalClass};
    use cmux_rd_core::session::StartRequest;
    use cmux_rd_proto::{DatagramHeader, DatagramKind, InputEvent, InputPacket};
    use std::os::fd::{AsRawFd, RawFd};
    use std::os::unix::net::UnixStream;
    use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
    use std::sync::mpsc;
    use std::sync::Arc;
    use std::time::Duration;

    #[derive(Default)]
    struct Seen {
        encode_started: AtomicBool,
        injected: AtomicBool,
        encode_returned: AtomicBool,
        injected_before_encode_returned: AtomicBool,
    }

    struct FakeDesktop {
        seen: Arc<Seen>,
        /// Never readable: this desktop reports no damage.
        quiet: (UnixStream, UnixStream),
    }

    impl Desktop for FakeDesktop {
        fn size(&self) -> (u32, u32) {
            (64, 64)
        }
        fn fd(&self) -> RawFd {
            self.quiet.1.as_raw_fd()
        }
        fn drain(&mut self, _out: &mut Vec<Rect>) -> Res<()> {
            Ok(())
        }
        fn inject(&mut self, _event: &InputEvent) -> Res<()> {
            self.seen.injected.store(true, SeqCst);
            Ok(())
        }
        fn release_all(&mut self) -> Res<()> {
            Ok(())
        }
    }

    /// Its first encode blocks until the test releases it (at most 5 s), like a slow 4K encode.
    struct BlockingEncoder {
        seen: Arc<Seen>,
        release: mpsc::Receiver<()>,
        first: bool,
    }

    impl FrameSource for BlockingEncoder {
        fn capture(&mut self, _damage: Rect) -> Res<()> {
            Ok(())
        }
        fn encode(&mut self, _force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
            if std::mem::take(&mut self.first) {
                self.seen.encode_started.store(true, SeqCst);
                let _ = self.release.recv_timeout(Duration::from_secs(5));
                let injected = self.seen.injected.load(SeqCst);
                self.seen.injected_before_encode_returned.store(injected, SeqCst);
                self.seen.encode_returned.store(true, SeqCst);
            }
            out.extend_from_slice(&[0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00]);
            Ok(true)
        }
        fn set_bitrate(&mut self, _kbps: u32) {}
        fn kbps(&self) -> u32 {
            1000
        }
        fn encoder_name(&self) -> String {
            "blocking test encoder".into()
        }
    }

    /// Sends one key press once the encode started, releases the encode once the press was
    /// injected, and stops the session once the encode returned.
    struct FakeCarrier {
        seen: Arc<Seen>,
        release: Option<mpsc::Sender<()>>,
        sent_input: bool,
        /// Always readable, so the loop keeps reading.
        ready: (UnixStream, UnixStream),
    }

    impl Carrier for FakeCarrier {
        fn fds(&self) -> Vec<RawFd> {
            vec![self.ready.1.as_raw_fd()]
        }
        fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
            if self.seen.encode_started.load(SeqCst) && !self.sent_input {
                self.sent_input = true;
                let mut d = DatagramHeader {
                    flags: 0,
                    kind: DatagramKind::Input,
                    stream: 0,
                    frame: 0,
                    index: 0,
                    count: 0,
                    fec_count: 0,
                    transport_seq: 0,
                }
                .encode()
                .to_vec();
                let packet = InputPacket {
                    first_seq: 1,
                    events: vec![InputEvent::Key { usage: 4, down: true }],
                };
                d.extend_from_slice(&packet.encode());
                out.push(Incoming::Datagram(d));
            }
            if self.seen.injected.load(SeqCst) {
                if let Some(release) = self.release.take() {
                    let _ = release.send(());
                }
            }
            if self.seen.encode_returned.load(SeqCst) {
                out.push(Incoming::Control(Control::Stop));
            }
            Ok(())
        }
        fn send_datagram(&mut self, _datagram: &[u8]) -> std::io::Result<()> {
            Ok(())
        }
        fn send_control(&mut self, _control: &Control) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn cfg() -> SessionCfg {
        SessionCfg {
            display: String::new(),
            max_fps: 60,
            start_kbps: 1000,
            max_kbps: 2000,
            preset: String::new(),
            profile: String::new(),
            codec: String::new(),
            openh264_lib: None,
            content: "screen".into(),
            threads: 1,
            stats_every_ms: 1000,
            settle_us: 0,
            upstream_record: None,
            upstream_record_max_bytes: 0,
            frames_in_flight: 2,
            input_frame_now: false,
            max_width: None,
            capture: crate::capture_backend::CaptureBackend::default(),
        }
    }

    #[test]
    fn viewer_input_is_injected_while_a_frame_encodes() {
        let seen = Arc::new(Seen::default());
        let (release_tx, release_rx) = mpsc::channel();
        let desktop =
            FakeDesktop { seen: seen.clone(), quiet: UnixStream::pair().expect("socket pair") };
        let encoder = BlockingEncoder { seen: seen.clone(), release: release_rx, first: true };
        let mut session = MediaSession::with_desktop(
            Box::new(desktop),
            Box::new(encoder),
            &cfg(),
            1200,
            &[],
            Box::new(crate::upstream::NoSink),
        )
        .expect("session");
        let ready = UnixStream::pair().expect("socket pair");
        use std::io::Write;
        (&ready.0).write_all(&[1]).expect("make the carrier readable");
        let mut carrier =
            FakeCarrier { seen: seen.clone(), release: Some(release_tx), sent_input: false, ready };
        let viewer = Principal {
            user: "owner".into(),
            install: "test".into(),
            class: PrincipalClass::User,
            interactive: true,
        };
        let mut table = SessionTable::new(HostPolicy {
            enabled: true,
            owner_user: viewer.user.clone(),
            grants: Vec::new(),
            consent: ConsentRule::AskOthers,
            unattended_allowed: true,
        });
        let id = table
            .start(StartRequest {
                key: "k",
                caller: Some(&viewer),
                for_client: None,
                mode: Mode::Control,
                console_user: None,
                now_ms: 0,
            })
            .expect("session starts");
        assert!(table.may_inject_input(id, &viewer));
        let reason = session.run(&mut carrier, &mut table, id, &viewer);
        assert_eq!(reason, "stopped by viewer");
        assert!(seen.injected.load(SeqCst), "the key press was never injected");
        assert!(
            seen.injected_before_encode_returned.load(SeqCst),
            "the key press waited for the encode to finish"
        );
    }
}
