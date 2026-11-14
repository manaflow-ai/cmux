//! One bench row: a scene captured at a fixed rate, encoded by one codec, sent
//! by the real host media engine (`cmux-rd-engine`: frame gate, congestion
//! control, FEC, NACK resends, recovery keyframes), carried by a simulated link
//! (one-way delay, random loss both ways, a bottleneck with a queue), rebuilt
//! by the viewer's real reassembler (`cmux-rd-core`) and decoded, with the
//! viewer sending the same feedback `cmux-rd bench` does.
//!
//! Time is simulated in 1 ms steps, except that encode and decode take their
//! real wall time: a slow encoder holds the host back and a slow decoder delays
//! what the viewer shows, so a codec's speed shows up in its on-time rate.
//!
//! Per row: on-time fps (frames shown within `on_time_ms` of capture, per
//! second), shown fps, capture-to-shown latency, luma PSNR of each shown frame
//! against its source picture, encode and decode ms per frame, keyframes and
//! the bitrate on the wire.

pub mod scene;

use std::collections::{BTreeMap, VecDeque};
use std::time::Instant;

use cmux_encode::{Codec, EncCfg, I420, Res};
use cmux_rd_core::cc::PathKind;
use cmux_rd_core::flow::Rect;
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine, frames_in_flight_for};
use cmux_rd_proto::{
    Arrival, DatagramHeader, DatagramKind, Feedback, HEADER_LEN, MAX_ARRIVALS, MAX_DATAGRAM_VPC,
    Nack,
};
use serde_json::{Value, json};

use scene::{Rng, Scene, SceneKind};

/// One row's settings.
#[derive(Debug, Clone)]
pub struct RowCfg {
    pub codec: Codec,
    pub scene: SceneKind,
    pub loss_pct: f64,
    pub rtt_ms: u64,
    pub link_mbps: f64,
    pub seconds: u64,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub threads: u16,
    pub on_time_ms: u64,
    /// The viewer's reassembly deadline (`cmux-rd bench --deadline-ms`, default 200).
    pub deadline_ms: u64,
    pub seed: u64,
}

/// A one-direction link: a bottleneck of `mbps` with a FIFO queue, then a fixed
/// delay; each datagram is lost with probability `loss`.
struct Link {
    one_way_us: u64,
    loss: f64,
    us_per_byte: f64,
    free_at_us: u64,
    max_queue_us: u64,
    rng: Rng,
    in_flight: BTreeMap<(u64, u64), Vec<u8>>,
    seq: u64,
    sent: u64,
    dropped: u64,
}

impl Link {
    fn new(one_way_us: u64, loss: f64, mbps: f64, seed: u64) -> Self {
        Self {
            one_way_us,
            loss,
            us_per_byte: if mbps > 0.0 { 8.0 / mbps } else { 0.0 },
            free_at_us: 0,
            max_queue_us: 500_000,
            rng: Rng::new(seed),
            in_flight: BTreeMap::new(),
            seq: 0,
            sent: 0,
            dropped: 0,
        }
    }

    fn send(&mut self, now_us: u64, d: Vec<u8>) {
        self.sent += d.len() as u64;
        let start = self.free_at_us.max(now_us);
        if start - now_us > self.max_queue_us {
            self.dropped += 1;
            return;
        }
        let depart = start + (d.len() as f64 * self.us_per_byte) as u64;
        self.free_at_us = depart;
        if self.rng.unit() * 100.0 < self.loss {
            self.dropped += 1;
            return;
        }
        self.seq += 1;
        self.in_flight.insert((depart + self.one_way_us, self.seq), d);
    }

    fn arrived(&mut self, now_us: u64) -> Vec<Vec<u8>> {
        let later = self.in_flight.split_off(&(now_us + 1, 0));
        std::mem::replace(&mut self.in_flight, later).into_values().collect()
    }
}

fn pct(xs: &mut [f64], p: f64) -> f64 {
    if xs.is_empty() {
        return f64::NAN;
    }
    xs.sort_by(f64::total_cmp);
    xs[((p / 100.0) * (xs.len() - 1) as f64).round() as usize]
}

fn header(kind: DatagramKind) -> Vec<u8> {
    let mut d = Vec::with_capacity(HEADER_LEN + 64);
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
    .encode_into(&mut d);
    d
}

/// The viewer: reassembly, decode, feedback (the logic of `cmux-rd bench`'s viewer).
struct Viewer {
    reassembler: Reassembler,
    decoder: Box<dyn cmux_encode::VideoDecoder>,
    arrivals: Vec<Arrival>,
    last_feedback_us: u64,
    released_since_feedback: bool,
    decode_ms: Vec<f64>,
    decode_errors: u64,
    busy_until_us: u64,
    out: I420,
}

impl Viewer {
    fn feedback(&mut self, now_us: u64, up: &mut Link) {
        let since = now_us.saturating_sub(self.last_feedback_us);
        let due = since >= 50_000;
        let keepalive = since >= 1_000_000;
        if !(self.released_since_feedback
            || keepalive
            || (due && (!self.arrivals.is_empty() || self.reassembler.need_recovery())))
        {
            return;
        }
        let nacks = self
            .reassembler
            .missing(now_us, 5_000)
            .into_iter()
            .take(4)
            .map(|(frame, indexes)| Nack { frame, indexes: indexes.into_iter().take(32).collect() })
            .collect();
        let mut recent: Vec<f64> = self.decode_ms.iter().rev().take(30).copied().collect();
        recent.sort_by(f64::total_cmp);
        while self.arrivals.len() > MAX_ARRIVALS {
            let rest = self.arrivals.split_off(MAX_ARRIVALS);
            let head = std::mem::replace(&mut self.arrivals, rest);
            let fb = Feedback {
                acked_frame: self.reassembler.last_released(),
                arrivals: head,
                ..Feedback::default()
            };
            let mut d = header(DatagramKind::Feedback);
            d.extend_from_slice(&fb.encode());
            up.send(now_us, d);
        }
        let fb = Feedback {
            acked_frame: self.reassembler.last_released(),
            decode_us: recent.get(recent.len() / 2).map_or(0, |m| (m * 1000.0) as u32),
            need_recovery: self.reassembler.need_recovery(),
            arrivals: std::mem::take(&mut self.arrivals),
            nacks,
        };
        let mut d = header(DatagramKind::Feedback);
        d.extend_from_slice(&fb.encode());
        up.send(now_us, d);
        self.last_feedback_us = now_us;
        self.released_since_feedback = false;
    }
}

/// Runs one row and returns its JSON record.
pub fn run_row(cfg: &RowCfg) -> Res<Value> {
    let (w, h) = (cfg.width as usize, cfg.height as usize);
    let enc_cfg = EncCfg {
        width: cfg.width,
        height: cfg.height,
        fps: cfg.fps,
        kbps: 8_000,
        threads: cfg.threads,
        screen_content: true,
    };
    let Some(mut enc) = crate::open_encoder(cfg.codec, &enc_cfg)? else {
        return Err(format!("{} is not in this build", cfg.codec.wire_name()).into());
    };
    let Some(decoder) = crate::open_decoder(cfg.codec, u32::from(cfg.threads))? else {
        return Err(format!("{} decoder is not in this build", cfg.codec.wire_name()).into());
    };
    let mut scene = Scene::new(cfg.scene, w, h, cfg.seed);
    let rtt_us = cfg.rtt_ms * 1000;
    let one_way = rtt_us / 2;
    let mut down = Link::new(one_way, cfg.loss_pct, cfg.link_mbps, cfg.seed ^ 0xd0);
    let mut up = Link::new(one_way, cfg.loss_pct, 0.0, cfg.seed ^ 0x0b);
    let mut engine = MediaEngine::new(
        EngineConfig {
            width: cfg.width,
            height: cfg.height,
            max_fps: cfg.fps,
            max_datagram: MAX_DATAGRAM_VPC,
            path: PathKind::ViaCloudRegion,
            frames_in_flight: frames_in_flight_for(rtt_us, cfg.fps),
            ..EngineConfig::default()
        },
        0,
    );
    let mut viewer = Viewer {
        reassembler: Reassembler::new(cfg.deadline_ms * 1000),
        decoder,
        arrivals: Vec::new(),
        last_feedback_us: 0,
        released_since_feedback: false,
        decode_ms: Vec::new(),
        decode_errors: 0,
        busy_until_us: 0,
        out: I420::new(w, h),
    };

    let interval_us = 1_000_000 / u64::from(cfg.fps.max(1));
    let end_us = cfg.seconds * 1_000_000;
    // Source pictures by capture time, for PSNR, while a frame of them may still show.
    let mut sources: VecDeque<(u64, I420)> = VecDeque::new();
    let mut next_capture_us = 0u64;
    let mut captured_at_us = 0u64;
    let mut captures = 0u64;
    let mut damage = false;
    let mut host_busy_until = 0u64;
    // An encode in progress: its request and result, handed to the engine when it ends.
    let mut in_encode: Option<(EncodeRequest, Vec<u8>, bool, u64)> = None;
    let mut queued_req: Option<EncodeRequest> = engine.start(0);
    let mut au = Vec::new();
    let mut encode_ms = Vec::new();
    let mut au_bytes = 0u64;
    let mut encoded = 0u64;
    let mut skipped = 0u64;
    let mut idrs = 0u64;
    let mut shown = 0u64;
    let mut on_time = 0u64;
    let mut latency_ms = Vec::new();
    let mut psnr = Vec::new();
    let mut max_gap_ms = 0f64;
    let mut last_shown_us = 0u64;

    let mut now = 0u64;
    while now < end_us {
        // Capture: the screen changes every frame interval (every scene moves every frame).
        if now >= next_capture_us {
            if captures > 0 {
                scene.advance();
            }
            captured_at_us = now;
            captures += 1;
            next_capture_us += interval_us;
            damage = true;
            sources.push_back((now, scene.picture().clone()));
            while sources.len() > 64 {
                sources.pop_front();
            }
        }

        // Host.
        if now >= host_busy_until {
            if let Some((req, bytes, idr, t_capture)) = in_encode.take() {
                let result = (!bytes.is_empty()).then(|| Encoded {
                    access_unit: bytes,
                    idr,
                    t_capture_us: t_capture,
                });
                match engine.encoded(&req, result, now) {
                    Ok(out) => {
                        for d in out.datagrams {
                            down.send(now, d);
                        }
                        if out.halve_bitrate {
                            let half = enc.kbps() / 2;
                            enc.set_bitrate(half);
                        }
                    }
                    Err(e) => return Err(format!("packetize: {e:?}").into()),
                }
            }
            for d in up.arrived(now) {
                let out = engine.on_datagram(&d, false, now);
                for d in out.datagrams {
                    down.send(now, d);
                }
                if out.encode.is_some() {
                    queued_req = out.encode.or(queued_req);
                }
            }
            let out = engine.tick(false, now);
            for d in out.datagrams {
                down.send(now, d);
            }
            if out.encode.is_some() {
                queued_req = out.encode.or(queued_req);
            }
            if queued_req.is_none() && damage {
                queued_req = engine.damage(
                    0,
                    Rect { x: 0, y: 0, width: cfg.width, height: cfg.height },
                    now,
                );
                damage = false;
            }
            if queued_req.is_none() {
                queued_req = engine.poll(now);
            }
            if let Some(req) = queued_req.take() {
                enc.set_bitrate(req.target_kbps);
                let t0 = Instant::now();
                let idr =
                    enc.encode(scene.picture(), req.force_idr, captured_at_us as i64, &mut au)?;
                let ms = t0.elapsed().as_secs_f64() * 1000.0;
                encode_ms.push(ms);
                let t_capture = enc.output_pts().map_or(captured_at_us, |p| p.max(0) as u64);
                if au.is_empty() {
                    skipped += 1;
                } else {
                    encoded += 1;
                    au_bytes += au.len() as u64;
                    idrs += u64::from(idr);
                }
                host_busy_until = now + (ms * 1000.0).ceil() as u64;
                in_encode = Some((req, std::mem::take(&mut au), idr, t_capture));
            }
        }

        // Viewer.
        for d in down.arrived(now) {
            let Ok((hd, payload)) = DatagramHeader::decode(&d) else { continue };
            if !matches!(hd.kind, DatagramKind::Video | DatagramKind::Fec) {
                continue;
            }
            viewer
                .arrivals
                .push(Arrival { transport_seq: hd.transport_seq, arrival_us: now as u32 });
            for frame in viewer.reassembler.push(&hd, payload, now) {
                viewer.released_since_feedback = true;
                let t0 = Instant::now();
                let decoded = viewer.decoder.decode(&frame.body.access_unit, &mut viewer.out);
                let ms = t0.elapsed().as_secs_f64() * 1000.0;
                viewer.decode_ms.push(ms);
                let start = now.max(viewer.busy_until_us);
                let shown_at = start + (ms * 1000.0).ceil() as u64;
                viewer.busy_until_us = shown_at;
                match decoded {
                    Ok(true) => {
                        shown += 1;
                        let lat = shown_at.saturating_sub(frame.body.t_capture_us) as f64 / 1000.0;
                        latency_ms.push(lat);
                        if lat <= cfg.on_time_ms as f64 {
                            on_time += 1;
                        }
                        if last_shown_us > 0 {
                            max_gap_ms = max_gap_ms.max((shown_at - last_shown_us) as f64 / 1000.0);
                        }
                        last_shown_us = shown_at;
                        if let Some((_, src)) =
                            sources.iter().find(|(t, _)| *t == frame.body.t_capture_us)
                        {
                            psnr.push(crate::psnr_y(src, &viewer.out));
                        }
                    }
                    Ok(false) => {}
                    Err(_) => viewer.decode_errors += 1,
                }
            }
        }
        viewer.reassembler.tick(now);
        viewer.feedback(now, &mut up);
        now += 1000;
    }

    let secs = cfg.seconds as f64;
    let stats = engine.stats();
    let mean = |xs: &[f64]| {
        if xs.is_empty() { f64::NAN } else { xs.iter().sum::<f64>() / xs.len() as f64 }
    };
    let psnr_mean = mean(&psnr);
    let psnr_min = psnr.iter().copied().fold(f64::INFINITY, f64::min);
    Ok(json!({
        "codec": cfg.codec.wire_name(),
        "encoder": enc.name(),
        "decoder": viewer.decoder.name(),
        "scene": cfg.scene.name(),
        "text_scene": cfg.scene.is_text(),
        "loss_pct": cfg.loss_pct,
        "rtt_ms": cfg.rtt_ms,
        "link_mbps": cfg.link_mbps,
        "size": format!("{}x{}", cfg.width, cfg.height),
        "capture_fps": cfg.fps,
        "seconds": cfg.seconds,
        "on_time_ms": cfg.on_time_ms,
        "on_time_fps": on_time as f64 / secs,
        "shown_fps": shown as f64 / secs,
        "captures": captures,
        "encoded": encoded,
        "encoder_skipped": skipped,
        "keyframes": idrs,
        "engine_keyframes": stats.keyframes,
        "wire_mbps": down.sent as f64 * 8.0 / secs / 1e6,
        "media_mbps": au_bytes as f64 * 8.0 / secs / 1e6,
        "datagrams_dropped": down.dropped,
        "latency_ms": {"p50": pct(&mut latency_ms.clone(), 50.0), "p95": pct(&mut latency_ms, 95.0)},
        "max_gap_ms": max_gap_ms,
        "psnr_y_db": {"mean": psnr_mean, "min": if psnr.is_empty() { f64::NAN } else { psnr_min }, "frames": psnr.len()},
        "encode_ms": {"p50": pct(&mut encode_ms.clone(), 50.0), "p95": pct(&mut encode_ms, 95.0)},
        "decode_ms": {"p50": pct(&mut viewer.decode_ms.clone(), 50.0), "p95": pct(&mut viewer.decode_ms, 95.0)},
        "decode_errors": viewer.decode_errors,
        "final_target_kbps": stats.target_bps / 1000,
    }))
}
