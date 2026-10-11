//! One host streaming session: capture -> convert -> encode -> send, plus input, ping, and stats.

use crate::capture::{Capturer, DamageEvent, Rect};
use crate::clock::{ms, now_ns};
use crate::convert::{bgrx_rect_to_i420, I420};
use crate::encoder::{self, EncCfg, VideoEncoder};
use crate::fdwait::{wait_readable, Waker};
use crate::inject::Injector;
use crate::proto::{self, Hello, HelloAck, HostStats, Input, VideoHeader};
use crate::stats::{p50, summarize, StageSamples};
use crate::sysinfo::{self, CpuMeter};
use crate::Res;
use std::io::Write;
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const MARKER_AREA: Rect = Rect { x: 0, y: 0, w: crate::marker::WIDTH, h: crate::marker::CELL };

#[derive(Clone)]
pub struct ServeCfg {
    pub display: String,
    pub capture: String,
    pub max_fps: u32,
    pub qp: Option<u8>,
    pub threads: u16,
    pub convert_threads: usize,
    pub screen: bool,
    pub codec: String,
    pub x264_preset: String,
    pub x264_profile: String,
}

#[derive(Default)]
struct InjectMark {
    t_ns: u64,
    pending: bool,
}

struct Shared {
    stop: AtomicBool,
    keyframe: AtomicBool,
    waker: Waker,
    inject: Mutex<InjectMark>,
    injected_seq: AtomicU32,
    window: Mutex<StageSamples>,
    total: Mutex<StageSamples>,
    cpu: Mutex<(Vec<f64>, Vec<f64>)>,
    writer: Mutex<TcpStream>,
}

impl Shared {
    fn send(&self, ty: u8, parts: &[&[u8]]) -> std::io::Result<()> {
        let msg = proto::frame(ty, parts);
        let mut w = self.writer.lock().map_err(|_| std::io::Error::other("writer poisoned"))?;
        w.write_all(&msg)
    }

    fn record(&self, f: impl Fn(&mut StageSamples)) {
        if let Ok(mut w) = self.window.lock() {
            f(&mut w);
        }
        if let Ok(mut t) = self.total.lock() {
            f(&mut t);
        }
    }
}

struct Pipeline {
    cap: Capturer,
    enc: Box<dyn VideoEncoder>,
    pic: I420,
    au: Vec<u8>,
    seq: u64,
    convert_threads: usize,
}

impl Pipeline {
    /// Captures `rect`, encodes, sends. Returns false when the client is gone.
    fn frame(&mut self, sh: &Shared, rect: Rect, t_damage: u64, force_idr: bool) -> Res<bool> {
        let r = rect.align_even(self.cap.width, self.cap.height);
        if r.w == 0 || r.h == 0 {
            return Ok(true);
        }
        let t0 = now_ns();
        let src = self.cap.grab(r)?;
        let t_capture = now_ns();
        let last_input_seq = sh.injected_seq.load(Ordering::Acquire);
        bgrx_rect_to_i420(src, &mut self.pic, r.x as usize, r.y as usize, r.w as usize, r.h as usize, self.convert_threads);
        let t_converted = now_ns();
        let key = self.enc.encode(&self.pic, force_idr, (t_capture / 1_000_000) as i64, &mut self.au)?;
        let t_encoded = now_ns();
        if self.au.is_empty() {
            return Ok(true);
        }
        self.seq += 1;
        let hdr = VideoHeader {
            frame_seq: self.seq,
            t_damage_ns: t_damage,
            t_capture_ns: t_capture,
            t_encoded_ns: t_encoded,
            last_input_seq,
            flags: if key { proto::FLAG_KEYFRAME } else { 0 },
            width: self.cap.width,
            height: self.cap.height,
        };
        if sh.send(proto::VIDEO, &[&hdr.encode(), &self.au]).is_err() {
            return Ok(false);
        }
        let t_sent = now_ns();
        let bytes = (proto::VIDEO_HEADER_LEN + self.au.len()) as u64;
        sh.record(|s| {
            s.frames += 1;
            s.keyframes += u64::from(key);
            s.bytes += bytes;
            s.capture.push(ms(t_capture - t0));
            s.capture_px.push(f64::from(r.w * r.h) / 1e6);
            s.convert.push(ms(t_converted - t_capture));
            s.encode.push(ms(t_encoded - t_converted));
            s.encode_to_sent.push(ms(t_sent - t_encoded));
            if t_damage > 0 {
                s.damage_to_capture.push(ms(t_capture - t_damage));
                s.damage_to_send.push(ms(t_sent - t_damage));
            }
        });
        Ok(true)
    }
}

pub fn run(stream: TcpStream, hello: &Hello, cfg: &ServeCfg) -> Res<serde_json::Value> {
    let capture = match hello.capture.as_str() {
        "damage" | "poll" => hello.capture.clone(),
        _ => cfg.capture.clone(),
    };
    let max_fps = if hello.max_fps > 0 { hello.max_fps.min(240) } else { cfg.max_fps };
    let cap = Capturer::new(&cfg.display, capture == "damage")?;
    let enc_cfg = EncCfg {
        width: cap.width,
        height: cap.height,
        max_fps,
        qp: cfg.qp,
        bitrate_kbps: hello.bitrate_kbps,
        threads: cfg.threads,
        screen: cfg.screen,
        codec: cfg.codec.clone(),
        x264_preset: cfg.x264_preset.clone(),
        x264_profile: cfg.x264_profile.clone(),
    };
    let enc = encoder::open(&enc_cfg)?;
    let injector = Injector::new(&cfg.display)?;
    let ack = HelloAck {
        width: cap.width,
        height: cap.height,
        encoder: enc.name().to_string(),
        capture: capture.clone(),
        host: sysinfo::hostname(),
        cpu: sysinfo::cpu_model(),
        cores: sysinfo::cores(),
    };
    let shared = Arc::new(Shared {
        stop: AtomicBool::new(false),
        keyframe: AtomicBool::new(false),
        waker: Waker::new()?,
        inject: Mutex::new(InjectMark::default()),
        injected_seq: AtomicU32::new(0),
        window: Mutex::new(StageSamples::default()),
        total: Mutex::new(StageSamples::default()),
        cpu: Mutex::new((Vec::new(), Vec::new())),
        writer: Mutex::new(stream.try_clone()?),
    });
    shared.send(proto::HELLO_ACK, &[serde_json::to_string(&ack)?.as_bytes()])?;

    let t_start = now_ns();
    let reader = {
        let sh = Arc::clone(&shared);
        let rd = stream.try_clone()?;
        std::thread::spawn(move || read_loop(rd, &sh, &injector))
    };
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let stats = {
        let sh = Arc::clone(&shared);
        std::thread::spawn(move || stats_loop(&sh, &stop_rx))
    };
    let mut pipe = Pipeline { pic: I420::new(cap.width as usize, cap.height as usize), cap, enc, au: Vec::new(), seq: 0, convert_threads: cfg.convert_threads };
    let interval = 1_000_000_000 / u64::from(max_fps.max(1));
    let result = if capture == "damage" { damage_loop(&mut pipe, &shared, interval) } else { poll_loop(&mut pipe, &shared, interval) };

    shared.stop.store(true, Ordering::Release);
    let _ = stream.shutdown(Shutdown::Both);
    drop(stop_tx);
    let _ = reader.join();
    let _ = stats.join();
    result?;

    let total = shared.total.lock().map(|t| t.summary_json()).unwrap_or_default();
    let (proc_cpu, sys_cpu) = shared.cpu.lock().map(|c| c.clone()).unwrap_or_default();
    Ok(serde_json::json!({
        "hello": hello,
        "ack": ack,
        "duration_s": (now_ns() - t_start) as f64 / 1e9,
        "max_fps": max_fps,
        "convert_threads": cfg.convert_threads,
        "stages": total,
        "cpu_pct_process": summarize(&proc_cpu),
        "cpu_pct_system": summarize(&sys_cpu),
    }))
}

fn damage_loop(pipe: &mut Pipeline, sh: &Shared, interval: u64) -> Res<()> {
    let full = pipe.cap.full();
    // The first frame is a full-screen IDR.
    let mut pending: Option<(u64, Rect)> = Some((now_ns(), full));
    let mut force_idr = true;
    let mut last_frame = 0u64;
    let mut events: Vec<DamageEvent> = Vec::new();
    let fds = [pipe.cap.fd(), sh.waker.fd()];
    while !sh.stop.load(Ordering::Acquire) {
        sh.waker.drain();
        events.clear();
        pipe.cap.drain(&mut events)?;
        for ev in &events {
            pending = Some(match pending {
                Some((t, r)) => (t, r.union(ev.rect)),
                None => (ev.t_ns, ev.rect),
            });
            if ev.rect.intersects(MARKER_AREA) {
                if let Ok(mut m) = sh.inject.lock() {
                    if m.pending && ev.t_ns >= m.t_ns {
                        m.pending = false;
                        let d = ms(ev.t_ns - m.t_ns);
                        sh.record(|s| s.inject_to_damage.push(d));
                    }
                }
            }
        }
        if sh.keyframe.swap(false, Ordering::AcqRel) {
            force_idr = true;
            pending = Some((pending.map_or_else(now_ns, |p| p.0), full));
        }
        let mut timeout = None;
        if let Some((t_damage, rect)) = pending {
            let now = now_ns();
            let slot = last_frame + interval;
            if now >= slot {
                last_frame = now;
                pending = None;
                if !pipe.frame(sh, rect, t_damage, force_idr)? {
                    return Ok(());
                }
                force_idr = false;
                continue;
            }
            timeout = Some(slot - now);
        }
        wait_readable(&fds, timeout)?;
    }
    Ok(())
}

fn poll_loop(pipe: &mut Pipeline, sh: &Shared, interval: u64) -> Res<()> {
    let full = pipe.cap.full();
    let mut next = now_ns();
    let mut force_idr = true;
    while !sh.stop.load(Ordering::Acquire) {
        sh.waker.drain();
        force_idr |= sh.keyframe.swap(false, Ordering::AcqRel);
        let now = now_ns();
        if now >= next {
            if !pipe.frame(sh, full, 0, force_idr)? {
                return Ok(());
            }
            force_idr = false;
            next += interval;
            if now > next {
                next = now + interval;
            }
            continue;
        }
        wait_readable(&[sh.waker.fd()], Some(next - now))?;
    }
    Ok(())
}

fn read_loop(mut rd: TcpStream, sh: &Shared, injector: &Injector) {
    while let Ok((ty, payload)) = proto::read_msg(&mut rd) {
        match ty {
            proto::INPUT => {
                let Some(input) = Input::decode(&payload) else { continue };
                let t = now_ns();
                if let Err(e) = injector.apply(&input) {
                    eprintln!("rdhost serve: inject failed: {e}");
                    continue;
                }
                if let Ok(mut m) = sh.inject.lock() {
                    *m = InjectMark { t_ns: t, pending: true };
                }
                sh.injected_seq.store(input.seq, Ordering::Release);
            }
            proto::KEYFRAME_REQ => {
                sh.keyframe.store(true, Ordering::Release);
                sh.waker.wake();
            }
            proto::PING => {
                let Some(t_client) = proto::decode_ping(&payload) else { continue };
                let t_host = now_ns();
                let mut b = [0u8; 16];
                b[..8].copy_from_slice(&t_client.to_le_bytes());
                b[8..].copy_from_slice(&t_host.to_le_bytes());
                if sh.send(proto::PONG, &[&b]).is_err() {
                    break;
                }
            }
            proto::BYE => break,
            _ => {}
        }
    }
    sh.stop.store(true, Ordering::Release);
    sh.waker.wake();
}

fn stats_loop(sh: &Shared, stop: &mpsc::Receiver<()>) {
    let mut cpu = CpuMeter::new();
    while let Err(RecvTimeoutError::Timeout) = stop.recv_timeout(Duration::from_secs(1)) {
        let w = sh.window.lock().map(|mut w| w.take()).unwrap_or_default();
        let (proc_pct, sys_pct) = cpu.sample();
        if let (Ok(mut c), Some(p), Some(s)) = (sh.cpu.lock(), proc_pct, sys_pct) {
            c.0.push(p);
            c.1.push(s);
        }
        let stats = HostStats {
            cpu_pct_process: proc_pct,
            cpu_pct_system: sys_pct,
            frames: w.frames,
            bytes: w.bytes,
            capture_ms_p50: p50(&w.capture),
            convert_ms_p50: p50(&w.convert),
            encode_ms_p50: p50(&w.encode),
            damage_to_send_ms_p50: p50(&w.damage_to_send),
            input_inject_to_damage_ms_p50: p50(&w.inject_to_damage),
        };
        let Ok(json) = serde_json::to_string(&stats) else { continue };
        if sh.send(proto::HOST_STATS, &[json.as_bytes()]).is_err() {
            break;
        }
    }
}
