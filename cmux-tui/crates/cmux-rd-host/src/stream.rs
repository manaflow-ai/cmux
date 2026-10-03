//! One viewer's media session: damage -> frame gate -> capture -> convert -> x264 at the
//! congestion controller's bitrate -> packetize with adaptive FEC -> send; feedback drives
//! acknowledgements, recovery, NACK resends and the bitrate; input goes through the
//! exactly-once applier and the session table's input gate.

use crate::capture::{Capturer, Rect as CapRect};
use crate::clock::now_ns;
use crate::convert::{bgrx_rect_to_i420, I420};
use crate::fdwait::wait_readable;
use crate::inject::Injector;
use crate::wire::{
    write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM,
};
use crate::x264::X264;
use crate::Res;
use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind};
use cmux_rd_core::flow::{FlowAction, FrameGate, Rect};
use cmux_rd_core::input::InputApplier;
use cmux_rd_core::packetize::{parity_for, Packetizer};
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
    pub threads: u16,
    pub stats_every_ms: u64,
}

pub struct MediaSession {
    cap: Capturer,
    injector: Injector,
    enc: X264,
    pic: I420,
    au: Vec<u8>,
    gate: FrameGate,
    cc: CongestionController,
    packetizer: Packetizer,
    applier: InputApplier,
    out: DatagramOut,
    peer_ip: IpAddr,
    last_frame: u32,
    force_idr: bool,
    history: BTreeMap<u32, Vec<Vec<u8>>>,
    sent_since_feedback: u32,
    loss: f64,
    encode_ms: VecDeque<f64>,
    frames: u64,
    keyframes: u64,
    next_stats_ns: u64,
    stats_every_ns: u64,
    cpu_last: (f64, u64),
}

fn now_us() -> u64 {
    now_ns() / 1000
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
        peer_ip: IpAddr,
    ) -> Res<Self> {
        let cap = Capturer::new(&cfg.display, true)?;
        let (w, h) = (cap.width, cap.height);
        let enc = X264::new(w, h, cfg.max_fps, cfg.start_kbps, cfg.threads, &cfg.preset)?;
        // Phase 1 has no path events from the link yet; the VPC path is the deployed case.
        let path = PathKind::ViaCloudRegion;
        let cc_cfg = CcConfig {
            start_bps: u64::from(cfg.start_kbps) * 1000,
            max_bps: u64::from(cfg.max_kbps) * 1000,
            ..CcConfig::default()
        };
        let mut gate = FrameGate::new(1, cfg.max_fps);
        // The first frame covers the whole screen (an IDR).
        let _ = gate.damage(Rect { x: 0, y: 0, width: w, height: h }, now_us());
        Ok(Self {
            injector: Injector::new(&cfg.display)?,
            pic: I420::new(w as usize, h as usize),
            au: Vec::new(),
            gate,
            cc: CongestionController::new(cc_cfg, path),
            packetizer: Packetizer::new(0, max_datagram),
            applier: InputApplier::new(200_000),
            out,
            peer_ip,
            last_frame: 0,
            force_idr: true,
            history: BTreeMap::new(),
            sent_since_feedback: 0,
            loss: 0.0,
            encode_ms: VecDeque::new(),
            frames: 0,
            keyframes: 0,
            next_stats_ns: now_ns(),
            stats_every_ns: cfg.stats_every_ms * 1_000_000,
            cpu_last: (process_cpu_s(), now_ns()),
            cap,
            enc,
        })
    }

    pub fn size(&self) -> (u32, u32) {
        (self.cap.width, self.cap.height)
    }

    pub fn encoder_name(&self) -> String {
        self.enc.name.clone()
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
        loop {
            if !table.may_send_media(session, viewer) {
                return "session not active".into();
            }
            let now = now_us();
            if let FlowAction::Encode { damage: d, frame } = self.gate.poll(now) {
                if let Err(e) = self.encode(stream, d, frame) {
                    return format!("encode/send failed: {e}");
                }
            }
            let timeout = self.gate.next_deadline_us().map(|t| t.saturating_sub(now_us()) * 1000);
            let stats_in = self.next_stats_ns.saturating_sub(now_ns());
            let timeout = Some(timeout.map_or(stats_in, |t| t.min(stats_in)).max(1_000_000));
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
            // UDP datagrams, only from the viewer's address.
            loop {
                match udp.recv_from(&mut buf) {
                    Ok((n, from)) if from.ip() == self.peer_ip => {
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
            if let Err(e) = self.cap.drain(&mut damage) {
                return format!("capture failed: {e}");
            }
            for ev in &damage {
                let r = Rect { x: ev.rect.x, y: ev.rect.y, width: ev.rect.w, height: ev.rect.h };
                if let FlowAction::Encode { damage: d, frame } = self.gate.damage(r, now_us()) {
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

    fn encode(&mut self, stream: &mut TcpStream, d: Rect, frame: u32) -> Res<()> {
        let (w, h) = (self.cap.width, self.cap.height);
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
        let idr = self.enc.encode(&self.pic, self.force_idr, i64::from(frame), &mut self.au)?;
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
        let packets = self
            .packetizer
            .packetize(frame, if idr { flags::KEYFRAME } else { 0 }, &body, parity)
            .map_err(|e| format!("{e:?}"))?;
        for (i, datagram) in packets.datagrams.iter().enumerate() {
            self.out.send(stream, datagram)?;
            self.cc.on_sent(packets.first_transport_seq.wrapping_add(i as u16), now_us());
        }
        self.sent_since_feedback += packets.datagrams.len() as u32;
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
                for event in self.applier.accept(&packet, now_us()) {
                    self.inject(&event, table, session, viewer);
                }
                self.send_input_ack(stream);
            }
            DatagramKind::Feedback => {
                let Ok(fb) = Feedback::decode(payload) else { return };
                let sent = self.sent_since_feedback.max(1) as f64;
                let lost = (sent - fb.arrivals.len() as f64).max(0.0) / sent;
                self.loss = 0.8 * self.loss + 0.2 * lost;
                self.sent_since_feedback = 0;
                self.cc.on_feedback(&fb.arrivals, lost, now_us());
                for nack in &fb.nacks {
                    if let Some(datagrams) = self.history.get(&nack.frame) {
                        for &i in &nack.indexes {
                            if let Some(d) = datagrams.get(usize::from(i)) {
                                let _ = self.out.send(stream, d);
                            }
                        }
                    }
                }
                if fb.need_recovery {
                    self.force_idr = true;
                    self.gate.clear_in_flight();
                    let full = Rect { x: 0, y: 0, width: self.cap.width, height: self.cap.height };
                    let _ = self.gate.damage(full, now_us());
                }
                if let FlowAction::Encode { damage, frame } =
                    self.gate.ack(fb.acked_frame, now_us())
                {
                    let _ = self.encode(stream, damage, frame);
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
        let _ = self.out.send(stream, &d);
    }

    fn send_stats(&mut self, stream: &mut TcpStream) {
        let now = now_ns();
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
        self.next_stats_ns = now + self.stats_every_ns.max(100_000_000);
    }
}
