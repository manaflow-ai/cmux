//! One viewer's media session: the I/O loop around this OS's desktop (desktop.rs:
//! capture, encode, injection). The media logic (frame gate, congestion control,
//! packetize with FEC, NACK history, recovery, exactly-once input) is the shared
//! engine, cmux-rd-engine (rd change C7 step 2).

use crate::carrier::{Carrier, Incoming};
use crate::clock::now_ns;
use crate::desktop::Desktop;
use crate::fdwait::wait_readable;
use crate::upstream::{UpstreamSink, Upstreams};
use crate::wire::Control;
use crate::Res;
use cmux_rd_core::cc::PathKind;
use cmux_rd_core::flow::Rect;
use cmux_rd_core::policy::Principal;
use cmux_rd_core::session::{SessionId, SessionTable};
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine, Output};
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
    /// macOS: stream at most this many pixels wide (`--max-width`; the display's aspect is
    /// kept). Encode time grows with the pixel count (remote-desktop-mac-host.md section 6).
    #[cfg_attr(target_os = "linux", allow(dead_code))]
    pub max_width: Option<u32>,
}

pub struct MediaSession {
    desktop: Box<dyn Desktop>,
    au: Vec<u8>,
    engine: MediaEngine,
    /// Upstream media the viewer opened (rd change C4).
    upstreams: Upstreams<Box<dyn UpstreamSink>>,
    deferred_error: Option<String>,
    stats_frames_sent: u64,
    encode_ms: VecDeque<f64>,
    next_stats_ns: u64,
    stats_every_ns: u64,
    cpu_last: (f64, u64),
    settle_ns: u64,
}

/// No feedback for this long ends the session.
const LIVENESS_NS: u64 = 3_000_000_000;

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
        let desktop = crate::desktop::open(cfg)?;
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
                ..EngineConfig::default()
            },
            now_us(),
        );
        Ok(Self {
            desktop,
            au: Vec::new(),
            engine,
            upstreams: Upstreams::new(sink, negotiated_caps),
            deferred_error: None,
            stats_frames_sent: 0,
            encode_ms: VecDeque::new(),
            next_stats_ns: now_ns(),
            stats_every_ns: cfg.stats_every_ms * 1_000_000,
            cpu_last: (process_cpu_s(), now_ns()),
            settle_ns: cfg.settle_us * 1000,
        })
    }

    /// The streamed size (even; an odd last column or row of the display is not sent).
    pub fn size(&self) -> (u32, u32) {
        self.desktop.size()
    }

    pub fn encoder_name(&self) -> String {
        self.desktop.encoder_name()
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
        // The first frame covers the whole screen (an IDR).
        if let Some(req) = self.engine.start(now_us()) {
            if let Err(e) = self.encode(carrier, &req) {
                return format!("encode/send failed: {e}");
            }
        }
        loop {
            if !table.may_send_media(session, viewer) {
                return "session not active".into();
            }
            if let Some(e) = self.deferred_error.take() {
                return format!("encode/send failed: {e}");
            }
            // The viewer sends feedback at least every second; silence means it is gone.
            if self.engine.silent_for_us(now_us()) > LIVENESS_NS / 1000 {
                return "viewer silent for 3 s".into();
            }
            let now = now_us();
            if let Some(req) = self.engine.poll(now) {
                if let Err(e) = self.encode(carrier, &req) {
                    return format!("encode/send failed: {e}");
                }
            }
            let timeout = self.engine.next_deadline_us().map(|t| t.saturating_sub(now_us()) * 1000);
            let stats_in = self.next_stats_ns.saturating_sub(now_ns());
            // The engine's deadline covers held frames and input held behind a gap.
            let timeout = timeout.map_or(stats_in, |t| t.min(stats_in)).min(LIVENESS_NS);
            let timeout = Some(timeout.max(1_000_000));
            let mut fds = carrier.fds();
            fds.push(self.desktop.fd());
            if let Err(e) = wait_readable(&fds, timeout) {
                return format!("wait failed: {e}");
            }
            incoming.clear();
            if let Err(reason) = carrier.receive(&mut incoming) {
                return reason;
            }
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
            // Damage from the desktop.
            damage.clear();
            if let Err(e) = self.drain_settled(&mut damage) {
                return format!("capture failed: {e}");
            }
            // One gate decision for everything that settled together.
            let merged = damage.iter().copied().reduce(Rect::union);
            if let Some(r) = merged {
                let req = self.engine.damage(0, r, now_us());
                trace(&format!("damage {r:?} -> {req:?}"));
                if let Some(req) = req {
                    if let Err(e) = self.encode(carrier, &req) {
                        return format!("encode/send failed: {e}");
                    }
                }
            }
            let may_inject = table.may_inject_input(session, viewer);
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
            if now_ns() >= self.next_stats_ns {
                self.send_stats(carrier);
            }
        }
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

    fn encode(&mut self, carrier: &mut dyn Carrier, req: &EncodeRequest) -> Res<()> {
        self.desktop.capture(req.damage)?;
        let t_capture_us = now_us();
        self.desktop.set_bitrate(req.target_kbps);
        let t0 = now_ns();
        let idr = self.desktop.encode(req.force_idr, t_capture_us as i64, &mut self.au)?;
        self.encode_ms.push_back((now_ns() - t0) as f64 / 1e6);
        if self.encode_ms.len() > 120 {
            self.encode_ms.pop_front();
        }
        let encoded = Encoded { access_unit: std::mem::take(&mut self.au), idr, t_capture_us };
        let out =
            self.engine.encoded(req, Some(encoded), now_us()).map_err(|e| format!("{e:?}"))?;
        if out.halve_bitrate {
            // Too large to send (about 4.6 MB): the engine dropped it and asks for a keyframe.
            self.desktop.set_bitrate(self.desktop.kbps() / 2);
        }
        for datagram in &out.datagrams {
            carrier.send_datagram(datagram)?;
        }
        Ok(())
    }

    /// Sends an engine output's datagrams, injects its input and encodes its
    /// requested frame.
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
            if let Err(e) = self.encode(carrier, &req) {
                self.deferred_error = Some(e.to_string());
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
        let out = self.engine.on_datagram(datagram, may_inject, now_us());
        self.apply(carrier, out, table, session, viewer);
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
            kbps: self.desktop.kbps(),
            frames: stats.frames,
            keyframes: stats.keyframes,
            cpu_pct,
            encode_ms_p50,
            loss_pct: stats.loss * 100.0,
        };
        let _ = carrier.send_control(&stats);
    }
}
