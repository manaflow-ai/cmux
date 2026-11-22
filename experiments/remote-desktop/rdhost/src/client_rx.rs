//! Client receive side: decodes VIDEO with openh264, reads the marker, collects PONG and HOST_STATS.

use crate::clock::{ms, now_ns};
use crate::marker;
use crate::proto::{self, HelloAck, HostStats, VideoHeader};
use openh264::decoder::Decoder;
use openh264::formats::YUVSource;
use std::net::TcpStream;
use std::sync::{Condvar, Mutex};

/// The most recent marker change seen in a decoded frame.
#[derive(Clone, Copy)]
pub struct MarkerSeen {
    pub value: u16,
    pub t_decoded_ns: u64,
    pub header: VideoHeader,
}

#[derive(Default)]
pub struct RxState {
    pub ack: Option<HelloAck>,
    pub marker: Option<MarkerSeen>,
    pub frames: u64,
    pub bytes: u64,
    pub keyframes: u64,
    pub idr_without_sps: u64,
    pub decode_errors: u64,
    pub decode_ms: Vec<f64>,
    /// (rtt_ms, host_minus_client_offset_ns) per PONG.
    pub pongs: Vec<(f64, i64)>,
    pub host_stats: Vec<HostStats>,
    pub ended: Option<String>,
}

pub struct Rx {
    pub st: Mutex<RxState>,
    pub cv: Condvar,
}

impl Rx {
    pub fn new() -> Self {
        Self { st: Mutex::new(RxState::default()), cv: Condvar::new() }
    }

    fn update(&self, f: impl FnOnce(&mut RxState)) {
        if let Ok(mut s) = self.st.lock() {
            f(&mut s);
        }
        self.cv.notify_all();
    }
}

/// True when an Annex-B access unit carries an SPS NAL unit (type 7).
fn has_sps(au: &[u8]) -> bool {
    au.windows(4).any(|w| w[..3] == [0, 0, 1] && w[3] & 0x1f == 7)
}

pub fn read_loop(mut rd: TcpStream, rx: &Rx) {
    let mut decoder = match Decoder::new() {
        Ok(d) => d,
        Err(e) => {
            rx.update(|s| s.ended = Some(format!("decoder init failed: {e}")));
            return;
        }
    };
    let reason = loop {
        let (ty, payload) = match proto::read_msg(&mut rd) {
            Ok(m) => m,
            Err(e) => break format!("connection closed: {e}"),
        };
        match ty {
            proto::HELLO_ACK => {
                let ack = serde_json::from_slice::<HelloAck>(&payload).ok();
                rx.update(|s| s.ack = ack);
            }
            proto::VIDEO => {
                let Some(header) = VideoHeader::decode(&payload) else { continue };
                let au = &payload[proto::VIDEO_HEADER_LEN..];
                let key = header.flags & proto::FLAG_KEYFRAME != 0;
                let t0 = now_ns();
                let decoded = decoder.decode(au);
                let t1 = now_ns();
                let value = match &decoded {
                    Ok(Some(yuv)) => marker::decode_luma(yuv.y(), yuv.strides().0, true),
                    _ => None,
                };
                let failed = decoded.is_err();
                let bytes = payload.len() as u64;
                rx.update(|s| {
                    s.frames += 1;
                    s.bytes += bytes;
                    s.keyframes += u64::from(key);
                    s.idr_without_sps += u64::from(key && !has_sps(au));
                    s.decode_errors += u64::from(failed);
                    s.decode_ms.push(ms(t1 - t0));
                    if let Some(v) = value {
                        if s.marker.map(|m| m.value) != Some(v) {
                            s.marker = Some(MarkerSeen { value: v, t_decoded_ns: t1, header });
                        }
                    }
                });
            }
            proto::PONG => {
                let t_rx = now_ns();
                let Some((t_tx, t_host)) = proto::decode_pong(&payload) else { continue };
                let rtt = t_rx.saturating_sub(t_tx);
                let offset = t_host as i64 - (t_tx + rtt / 2) as i64;
                rx.update(|s| s.pongs.push((ms(rtt), offset)));
            }
            proto::HOST_STATS => {
                if let Ok(h) = serde_json::from_slice::<HostStats>(&payload) {
                    rx.update(|s| s.host_stats.push(h));
                }
            }
            proto::BYE => break format!("BYE: {}", String::from_utf8_lossy(&payload)),
            _ => {}
        }
    };
    rx.update(|s| s.ended = Some(reason));
}
