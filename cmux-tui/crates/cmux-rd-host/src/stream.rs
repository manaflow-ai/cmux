//! One viewer's media session: damage -> frame gate -> capture -> convert -> H.264 (openh264, or x264 with the feature) at the
//! congestion controller's bitrate -> packetize with adaptive FEC -> send; feedback drives
//! acknowledgements, recovery, NACK resends and the bitrate; input goes through the
//! exactly-once applier and the session table's input gate.

use crate::capture::{Capturer, Rect as CapRect};
use crate::clock::now_ns;
use crate::convert::{bgrx_rect_to_i420, I420};
use crate::encoder::{self, EncCfg, H264Encoder};
use crate::fdwait::wait_readable;
use crate::inject::Injector;
use crate::wire::{
    write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM,
};
use crate::Res;
use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind};
use cmux_rd_core::flow::{FlowAction, FrameGate, Rect};
use cmux_rd_core::input::InputApplier;
use cmux_rd_core::packetize::{parity_for, PacketizeError, Packetizer};
use cmux_rd_core::policy::Principal;
use cmux_rd_core::session::{SessionId, SessionTable};
use cmux_rd_proto::{
    flags, DatagramHeader, DatagramKind, Feedback, FrameBody, InputPacket, HEADER_LEN, REF_NONE,
};
use std::collections::{BTreeMap, VecDeque};
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
    gate: FrameGate,
    cc: CongestionController,
    packetizer: Packetizer,
    applier: InputApplier,
    out: DatagramOut,
    /// Where the viewer's datagrams come from (UDP carrier); `None` on the stream carrier.
    peer_udp: Option<std::net::SocketAddr>,
    last_feedback_ns: u64,
    last_input_ns: u64,
    last_forced_idr_ns: u64,
    deferred_error: Option<String>,
    stats_frames_sent: u64,
    last_frame: u32,
    force_idr: bool,
    history: BTreeMap<u32, Vec<Vec<u8>>>,
    loss_meter: crate::loss::LossMeter,
    loss: f64,
    encode_ms: VecDeque<f64>,
    frames: u64,
    keyframes: u64,
    next_stats_ns: u64,
    stats_every_ns: u64,
    cpu_last: (f64, u64),
    settle_ns: u64,
}

/// No feedback for this long ends the session.
const LIVENESS_NS: u64 = 3_000_000_000;
/// UDP datagrams read per wake.
const MAX_UDP_PER_WAKE: usize = 64;
/// Datagrams resent for NACKs per feedback.
const MAX_RESENDS_PER_FEEDBACK: usize = 64;

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
        })?;
        // Phase 1 has no path events from the link yet; the VPC path is the deployed case.
        let path = PathKind::ViaCloudRegion;
        let cc_cfg = CcConfig {
            start_bps: u64::from(cfg.start_kbps) * 1000,
            max_bps: u64::from(cfg.max_kbps) * 1000,
            ..CcConfig::default()
        };
        let gate = FrameGate::new(1, cfg.max_fps);
        let peer_udp = match &out {
            DatagramOut::Udp { peer, .. } => Some(*peer),
            DatagramOut::Stream => None,
        };
        Ok(Self {
            injector: Injector::new(&cfg.display)?,
            pic: I420::new(w as usize, h as usize),
            au: Vec::new(),
            gate,
            cc: CongestionController::new(cc_cfg, path),
            packetizer: Packetizer::new(0, max_datagram),
            applier: InputApplier::new(200_000),
            out,
            peer_udp,
            last_feedback_ns: now_ns(),
            last_input_ns: 0,
            last_forced_idr_ns: 0,
            deferred_error: None,
            stats_frames_sent: 0,
            last_frame: 0,
            force_idr: true,
            history: BTreeMap::new(),
            loss_meter: crate::loss::LossMeter::default(),
            loss: 0.0,
            encode_ms: VecDeque::new(),
            frames: 0,
            keyframes: 0,
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
        let (w, h) = self.size();
        let full = Rect { x: 0, y: 0, width: w, height: h };
        if let FlowAction::Encode { damage: d, frame } = self.gate.damage(full, now_us()) {
            if let Err(e) = self.encode(stream, d, frame) {
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
            if now_ns().saturating_sub(self.last_feedback_ns) > LIVENESS_NS {
                return "viewer silent for 3 s".into();
            }
            let now = now_us();
            if let FlowAction::Encode { damage: d, frame } = self.gate.poll(now) {
                if let Err(e) = self.encode(stream, d, frame) {
                    return format!("encode/send failed: {e}");
                }
            }
            let timeout = self.gate.next_deadline_us().map(|t| t.saturating_sub(now_us()) * 1000);
            let stats_in = self.next_stats_ns.saturating_sub(now_ns());
            let mut timeout = timeout.map_or(stats_in, |t| t.min(stats_in)).min(LIVENESS_NS);
            // While the viewer types, wake often enough to release input held behind a gap.
            if now_ns().saturating_sub(self.last_input_ns) < 1_000_000_000 {
                timeout = timeout.min(50_000_000);
            }
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
                let action = self.gate.damage(r, now_us());
                trace(&format!("damage {r:?} -> {action:?} in_flight {}", self.gate.in_flight()));
                if let FlowAction::Encode { damage: d, frame } = action {
                    if let Err(e) = self.encode(stream, d, frame) {
                        return format!("encode/send failed: {e}");
                    }
                }
            }
            for event in self.applier.tick(now_us()) {
                self.inject(&event, table, session, viewer);
            }
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

    fn encode(&mut self, stream: &mut TcpStream, d: Rect, frame: u32) -> Res<()> {
        let (w, h) = self.size();
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
        self.enc.set_bitrate((self.cc.target_bps() / 1000) as u32);
        let t0 = now_ns();
        let idr = self.enc.encode(&self.pic, self.force_idr, t_capture_us as i64, &mut self.au)?;
        self.encode_ms.push_back((now_ns() - t0) as f64 / 1e6);
        if self.encode_ms.len() > 120 {
            self.encode_ms.pop_front();
        }
        if self.au.is_empty() {
            // Nothing to send; let the next damage through.
            self.gate.clear_in_flight();
            return Ok(());
        }
        self.force_idr = false;
        let body = FrameBody {
            t_capture_us,
            ref_frame: if idr { REF_NONE } else { self.last_frame },
            access_unit: std::mem::take(&mut self.au),
        };
        let shard_len = self.packetizer.shard_len();
        let data_shards = (body.access_unit.len() + 16).div_ceil(shard_len);
        let parity = parity_for(data_shards, self.loss, idr);
        let packets =
            self.packetizer.packetize(frame, if idr { flags::KEYFRAME } else { 0 }, &body, parity);
        let packets = match packets {
            Ok(p) => p,
            Err(PacketizeError::FrameTooLarge) => {
                // Too large to send (about 4.6 MB): drop it, halve the bitrate, start over
                // with a new keyframe instead of ending the session.
                self.enc.set_bitrate(self.enc.kbps() / 2);
                self.force_idr = true;
                self.gate.clear_in_flight();
                self.au = body.access_unit;
                return Ok(());
            }
            Err(e) => return Err(format!("{e:?}").into()),
        };
        for (i, datagram) in packets.datagrams.iter().enumerate() {
            self.out.send(stream, datagram)?;
            let seq = packets.first_transport_seq.wrapping_add(i as u16);
            self.cc.on_sent(seq, now_us());
            self.loss_meter.on_sent(seq);
        }
        self.au = body.access_unit;
        self.history.insert(frame, packets.datagrams);
        while self.history.len() > 16 {
            self.history.pop_first();
        }
        self.last_frame = frame;
        self.frames += 1;
        self.keyframes += u64::from(idr);
        Ok(())
    }

    fn on_datagram(
        &mut self,
        stream: &mut TcpStream,
        datagram: &[u8],
        table: &SessionTable,
        session: SessionId,
        viewer: &Principal,
    ) {
        let Ok((header, payload)) = DatagramHeader::decode(datagram) else { return };
        match header.kind {
            DatagramKind::Input => {
                let Ok(packet) = InputPacket::decode(payload) else { return };
                if !table.may_inject_input(session, viewer) {
                    self.applier.reset();
                    return;
                }
                self.last_input_ns = now_ns();
                for event in self.applier.accept(&packet, now_us()) {
                    self.inject(&event, table, session, viewer);
                }
                self.send_input_ack(stream);
            }
            DatagramKind::Feedback => {
                let Ok(fb) = Feedback::decode(payload) else { return };
                let settled =
                    self.loss_meter.on_arrivals(fb.arrivals.iter().map(|a| a.transport_seq));
                if let Some(lost) = settled {
                    self.loss = 0.8 * self.loss + 0.2 * lost;
                }
                self.cc.on_feedback(&fb.arrivals, settled.unwrap_or(0.0), now_us());
                self.last_feedback_ns = now_ns();
                // Resends are bounded per feedback so a hostile feedback cannot amplify.
                let mut budget = MAX_RESENDS_PER_FEEDBACK;
                for nack in &fb.nacks {
                    if let Some(datagrams) = self.history.get(&nack.frame) {
                        for &i in &nack.indexes {
                            if budget == 0 {
                                break;
                            }
                            if let Some(d) = datagrams.get(usize::from(i)) {
                                let _ = self.out.send(stream, d);
                                budget -= 1;
                            }
                        }
                    }
                }
                let mut action = self.gate.ack(fb.acked_frame, now_us());
                // At most one forced IDR per 250 ms.
                if fb.need_recovery
                    && now_ns().saturating_sub(self.last_forced_idr_ns) > 250_000_000
                {
                    self.last_forced_idr_ns = now_ns();
                    self.force_idr = true;
                    self.gate.clear_in_flight();
                    let (w, h) = self.size();
                    action = self.gate.damage(Rect { x: 0, y: 0, width: w, height: h }, now_us());
                }
                if let FlowAction::Encode { damage, frame } = action {
                    if let Err(e) = self.encode(stream, damage, frame) {
                        self.deferred_error = Some(e.to_string());
                    }
                }
            }
            _ => {}
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
            let _ = self.injector.release_all();
            self.applier.reset();
            return;
        }
        if self.applier.take_skipped_gap() {
            let _ = self.injector.release_all();
        }
        trace(&format!("inject {event:?}"));
        if let Err(e) = self.injector.apply(event) {
            eprintln!("inject failed: {e}");
        }
    }

    fn send_input_ack(&mut self, stream: &mut TcpStream) {
        let header = DatagramHeader {
            flags: 0,
            kind: DatagramKind::InputAck,
            stream: 0,
            frame: 0,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: self.packetizer.reserve_transport_seq(1),
        };
        let mut d = Vec::with_capacity(HEADER_LEN + 4);
        header.encode_into(&mut d);
        d.extend_from_slice(&self.applier.applied().to_le_bytes());
        // Input acks are not reported back as arrivals, so they stay out of loss and CC.
        let _ = self.out.send(stream, &d);
    }

    /// Releases every key and button the viewer holds on the host and forgets held input
    /// (called on every end of a session).
    pub fn release_input(&mut self) {
        let _ = self.injector.release_all();
        self.applier.reset();
    }

    fn send_stats(&mut self, stream: &mut TcpStream) {
        let now = now_ns();
        self.next_stats_ns = now + self.stats_every_ns.max(100_000_000);
        // Stats only while frames flow: an idle session sends nothing.
        if self.frames == self.stats_frames_sent {
            return;
        }
        self.stats_frames_sent = self.frames;
        let cpu = process_cpu_s();
        let cpu_pct =
            (cpu - self.cpu_last.0) / ((now - self.cpu_last.1) as f64 / 1e9).max(1e-3) * 100.0;
        self.cpu_last = (cpu, now);
        let mut sorted: Vec<f64> = self.encode_ms.iter().copied().collect();
        sorted.sort_by(f64::total_cmp);
        let encode_ms_p50 = sorted.get(sorted.len() / 2).copied().unwrap_or(0.0);
        let stats = Control::Stats {
            kbps: self.enc.kbps(),
            frames: self.frames,
            keyframes: self.keyframes,
            cpu_pct,
            encode_ms_p50,
            loss_pct: self.loss * 100.0,
        };
        let _ = write_control(stream, &stats);
    }
}
