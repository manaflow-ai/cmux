//! One viewer's media session on the Linux desktop: X damage and capture,
//! I420 conversion and H.264 (x264 by default, openh264 as the alternative),
//! XTest injection and the I/O loop. The media logic (frame gate, congestion
//! control, packetize with FEC, NACK history, recovery, exactly-once input)
//! is the shared engine, cmux-rd-engine (rd change C7 step 2).

use crate::capture::{Capturer, Rect as CapRect};
use crate::clock::now_ns;
use crate::encoder::{self, EncCfg, H264Encoder};
use crate::fdwait::wait_readable;
use crate::inject::Injector;
use crate::wire::{
    write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM,
};
use crate::Res;
use cmux_encode::{bgrx_rect_to_i420, I420};
use cmux_rd_core::cc::PathKind;
use cmux_rd_core::flow::Rect;
use cmux_rd_core::policy::Principal;
use cmux_rd_core::session::{SessionId, SessionTable};
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine, Output};
use std::collections::VecDeque;
use std::io;
use std::net::{IpAddr, TcpStream, UdpSocket};
use std::os::fd::AsRawFd;

#[derive(Clone)]
pub struct SessionCfg {
    pub display: String,
    pub max_fps: u32,
    pub start_kbps: u32,
    pub max_kbps: u32,
    pub preset: String,
    pub profile: String,
    /// `openh264` (default) or `x264` (feature).
    pub codec: String,
    /// Cisco's OpenH264 library for `--codec openh264` (pinned SHA-256; downloaded from
    /// Cisco on this machine, never shipped with cmux).
    pub openh264_lib: Option<String>,
    /// `screen` (default) or `camera` (openh264 usage).
    pub content: String,
    pub threads: u16,
    pub stats_every_ms: u64,
    /// Quiet time after damage before a capture (0 disables).
    pub settle_us: u64,
}

pub struct MediaSession {
    cap: Capturer,
    injector: Injector,
    enc: Box<dyn H264Encoder>,
    pic: I420,
    au: Vec<u8>,
    engine: MediaEngine,
    out: DatagramOut,
    /// Where the viewer's datagrams come from (UDP carrier); `None` on the stream carrier.
    peer_udp: Option<std::net::SocketAddr>,
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
/// UDP datagrams read per wake.
const MAX_UDP_PER_WAKE: usize = 64;

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
        out: DatagramOut,
        _peer_ip: IpAddr,
    ) -> Res<Self> {
        let cap = Capturer::new(&cfg.display, true)?;
        // x264 and 4:2:0 need even sizes; an odd last column or row is not sent.
        let (w, h) = (cap.width & !1, cap.height & !1);
        let enc = encoder::open(&EncCfg {
            width: w,
            height: h,
            fps: cfg.max_fps,
            kbps: cfg.start_kbps,
            threads: cfg.threads,
            codec: &cfg.codec,
            screen_content: cfg.content != "camera",
            preset: &cfg.preset,
            profile: &cfg.profile,
            openh264_lib: cfg.openh264_lib.as_deref(),
        })?;
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
        let peer_udp = match &out {
            DatagramOut::Udp { peer, .. } => Some(*peer),
            DatagramOut::Stream => None,
        };
        Ok(Self {
            injector: Injector::new(&cfg.display)?,
            pic: I420::new(w as usize, h as usize),
            au: Vec::new(),
            engine,
            out,
            peer_udp,
            deferred_error: None,
            stats_frames_sent: 0,
            encode_ms: VecDeque::new(),
            next_stats_ns: now_ns(),
            stats_every_ns: cfg.stats_every_ms * 1_000_000,
            cpu_last: (process_cpu_s(), now_ns()),
            settle_ns: cfg.settle_us * 1000,
            cap,
            enc,
        })
    }

    /// The streamed size (even; an odd last column or row of the display is not sent).
    pub fn size(&self) -> (u32, u32) {
        (self.cap.width & !1, self.cap.height & !1)
    }

    pub fn encoder_name(&self) -> String {
        self.enc.name()
    }

    /// Runs until the viewer stops, the host stops the session, or the connection fails.
    pub fn run(
        &mut self,
        stream: &mut TcpStream,
        reader: &mut FrameReader,
        udp: &UdpSocket,
        table: &mut SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) -> String {
        let mut damage = Vec::new();
        let mut buf = vec![0u8; 65536];
        // The first frame covers the whole screen (an IDR).
        if let Some(req) = self.engine.start(now_us()) {
            if let Err(e) = self.encode(stream, &req) {
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
                if let Err(e) = self.encode(stream, &req) {
                    return format!("encode/send failed: {e}");
                }
            }
            let timeout = self.engine.next_deadline_us().map(|t| t.saturating_sub(now_us()) * 1000);
            let stats_in = self.next_stats_ns.saturating_sub(now_ns());
            // The engine's deadline covers held frames and input held behind a gap.
            let timeout = timeout.map_or(stats_in, |t| t.min(stats_in)).min(LIVENESS_NS);
            let timeout = Some(timeout.max(1_000_000));
            if let Err(e) =
                wait_readable(&[self.cap.fd(), stream.as_raw_fd(), udp.as_raw_fd()], timeout)
            {
                return format!("wait failed: {e}");
            }
            // Control and stream-carried datagrams.
            if let Err(e) = reader.fill(stream) {
                return format!("viewer closed: {e}");
            }
            loop {
                match reader.next() {
                    Ok(Some((FRAME_CONTROL, payload))) => {
                        if matches!(serde_json::from_slice::<Control>(&payload), Ok(Control::Stop))
                        {
                            return "stopped by viewer".into();
                        }
                    }
                    Ok(Some((FRAME_DATAGRAM, payload))) => {
                        self.on_datagram(stream, &payload, table, session, viewer)
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => break,
                    Err(e) => return format!("bad frame: {e}"),
                }
            }
            // UDP datagrams, only from the viewer's own socket, at most 64 per wake.
            for _ in 0..MAX_UDP_PER_WAKE {
                if self.peer_udp.is_none() {
                    break;
                }
                match udp.recv_from(&mut buf) {
                    Ok((n, from)) if Some(from) == self.peer_udp => {
                        let datagram = buf[..n].to_vec();
                        self.on_datagram(stream, &datagram, table, session, viewer);
                    }
                    Ok(_) => {}
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) => return format!("udp failed: {e}"),
                }
            }
            // Damage from the X server.
            damage.clear();
            if let Err(e) = self.drain_settled(&mut damage) {
                return format!("capture failed: {e}");
            }
            // One gate decision for everything that settled together.
            let merged = damage
                .iter()
                .map(|ev| Rect { x: ev.rect.x, y: ev.rect.y, width: ev.rect.w, height: ev.rect.h })
                .reduce(Rect::union);
            if let Some(r) = merged {
                let req = self.engine.damage(0, r, now_us());
                trace(&format!("damage {r:?} -> {req:?}"));
                if let Some(req) = req {
                    if let Err(e) = self.encode(stream, &req) {
                        return format!("encode/send failed: {e}");
                    }
                }
            }
            let may_inject = table.may_inject_input(session, viewer);
            let out = self.engine.tick(may_inject, now_us());
            self.apply(stream, out, table, session, viewer);
            if now_ns() >= self.next_stats_ns {
                self.send_stats(stream);
            }
        }
    }

    /// Drains damage, then keeps draining while more arrives within `settle_ns` (at most
    /// four times), so an app that draws one change with several requests is captured
    /// whole instead of torn (measured: a torn first frame cost one frame interval).
    fn drain_settled(&mut self, out: &mut Vec<crate::capture::DamageEvent>) -> Res<()> {
        self.cap.drain(out)?;
        if out.is_empty() || self.settle_ns == 0 {
            return Ok(());
        }
        for _ in 0..4 {
            let before = out.len();
            wait_readable(&[self.cap.fd()], Some(self.settle_ns))?;
            self.cap.drain(out)?;
            if out.len() == before {
                break;
            }
        }
        Ok(())
    }

    fn encode(&mut self, stream: &mut TcpStream, req: &EncodeRequest) -> Res<()> {
        let (w, h) = self.size();
        let d = req.damage;
        let r = CapRect { x: d.x, y: d.y, w: d.width, h: d.height }.align_even(w, h);
        if r.w > 0 && r.h > 0 {
            let px = self.cap.grab(r)?;
            bgrx_rect_to_i420(
                px,
                &mut self.pic,
                r.x as usize,
                r.y as usize,
                r.w as usize,
                r.h as usize,
                2,
            );
        }
        let t_capture_us = now_us();
        self.enc.set_bitrate(req.target_kbps);
        let t0 = now_ns();
        let idr = self.enc.encode(&self.pic, req.force_idr, t_capture_us as i64, &mut self.au)?;
        self.encode_ms.push_back((now_ns() - t0) as f64 / 1e6);
        if self.encode_ms.len() > 120 {
            self.encode_ms.pop_front();
        }
        let encoded = Encoded { access_unit: std::mem::take(&mut self.au), idr, t_capture_us };
        let out =
            self.engine.encoded(req, Some(encoded), now_us()).map_err(|e| format!("{e:?}"))?;
        if out.halve_bitrate {
            // Too large to send (about 4.6 MB): the engine dropped it and asks for a keyframe.
            self.enc.set_bitrate(self.enc.kbps() / 2);
        }
        for datagram in &out.datagrams {
            self.out.send(stream, datagram)?;
        }
        Ok(())
    }

    /// Sends an engine output's datagrams, injects its input and encodes its
    /// requested frame.
    fn apply(
        &mut self,
        stream: &mut TcpStream,
        out: Output,
        table: &SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) {
        for datagram in &out.datagrams {
            let _ = self.out.send(stream, datagram);
        }
        if out.release_all {
            let _ = self.injector.release_all();
        }
        for event in &out.inject {
            self.inject(event, table, session, viewer);
        }
        if let Some(req) = out.encode {
            if let Err(e) = self.encode(stream, &req) {
                self.deferred_error = Some(e.to_string());
            }
        }
    }

    fn on_datagram(
        &mut self,
        stream: &mut TcpStream,
        datagram: &[u8],
        table: &SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) {
        let may_inject = table.may_inject_input(session, viewer);
        let out = self.engine.on_datagram(datagram, may_inject, now_us());
        self.apply(stream, out, table, session, viewer);
    }

    fn inject(
        &mut self,
        event: &cmux_rd_proto::InputEvent,
        table: &SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) {
        if !table.may_inject_input(session, viewer) {
            let _ = self.injector.release_all();
            self.engine.reset_input();
            return;
        }
        trace(&format!("inject {event:?}"));
        if let Err(e) = self.injector.apply(event) {
            eprintln!("inject failed: {e}");
        }
    }

    /// Releases every key and button the viewer holds on the host and forgets held input
    /// (called on every end of a session).
    pub fn release_input(&mut self) {
        let _ = self.injector.release_all();
        self.engine.reset_input();
    }

    fn send_stats(&mut self, stream: &mut TcpStream) {
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
            kbps: self.enc.kbps(),
            frames: stats.frames,
            keyframes: stats.keyframes,
            cpu_pct,
            encode_ms_p50,
            loss_pct: stats.loss * 100.0,
        };
        let _ = write_control(stream, &stats);
    }
}
