//! rdproto/0 framing and message payloads (little-endian, `u8 type, u32 len, payload`).

use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};

pub const HELLO: u8 = 0x01;
pub const HELLO_ACK: u8 = 0x02;
pub const VIDEO: u8 = 0x10;
pub const INPUT: u8 = 0x20;
pub const KEYFRAME_REQ: u8 = 0x21;
pub const PING: u8 = 0x30;
pub const PONG: u8 = 0x31;
pub const HOST_STATS: u8 = 0x40;
pub const BYE: u8 = 0x7f;

/// Upper bound on a payload we accept (one 4K IDR fits easily).
const MAX_PAYLOAD: u32 = 64 << 20;

pub const VIDEO_HEADER_LEN: usize = 48;
pub const INPUT_LEN: usize = 28;
pub const FLAG_KEYFRAME: u32 = 1;

pub const INPUT_KEY_TAP: u32 = 1;
pub const INPUT_POINTER_MOVE: u32 = 2;
pub const INPUT_BUTTON_TAP: u32 = 3;

pub fn read_msg(r: &mut impl Read) -> io::Result<(u8, Vec<u8>)> {
    let mut head = [0u8; 5];
    r.read_exact(&mut head)?;
    let len = u32::from_le_bytes([head[1], head[2], head[3], head[4]]);
    if len > MAX_PAYLOAD {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("payload too large: {len}")));
    }
    let mut payload = vec![0u8; len as usize];
    r.read_exact(&mut payload)?;
    Ok((head[0], payload))
}

/// Encodes one message (header + payload) into a single buffer so one write sends it whole.
pub fn frame(ty: u8, parts: &[&[u8]]) -> Vec<u8> {
    let len: usize = parts.iter().map(|p| p.len()).sum();
    let mut out = Vec::with_capacity(5 + len);
    out.push(ty);
    out.extend_from_slice(&(len as u32).to_le_bytes());
    for p in parts {
        out.extend_from_slice(p);
    }
    out
}

pub fn write_msg(w: &mut impl Write, ty: u8, payload: &[u8]) -> io::Result<()> {
    w.write_all(&frame(ty, &[payload]))
}

fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

fn u64_at(b: &[u8], o: usize) -> u64 {
    let mut a = [0u8; 8];
    a.copy_from_slice(&b[o..o + 8]);
    u64::from_le_bytes(a)
}

#[derive(Debug, Clone, Copy, Default)]
pub struct VideoHeader {
    pub frame_seq: u64,
    pub t_damage_ns: u64,
    pub t_capture_ns: u64,
    pub t_encoded_ns: u64,
    pub last_input_seq: u32,
    pub flags: u32,
    pub width: u32,
    pub height: u32,
}

impl VideoHeader {
    pub fn encode(&self) -> [u8; VIDEO_HEADER_LEN] {
        let mut b = [0u8; VIDEO_HEADER_LEN];
        b[0..8].copy_from_slice(&self.frame_seq.to_le_bytes());
        b[8..16].copy_from_slice(&self.t_damage_ns.to_le_bytes());
        b[16..24].copy_from_slice(&self.t_capture_ns.to_le_bytes());
        b[24..32].copy_from_slice(&self.t_encoded_ns.to_le_bytes());
        b[32..36].copy_from_slice(&self.last_input_seq.to_le_bytes());
        b[36..40].copy_from_slice(&self.flags.to_le_bytes());
        b[40..44].copy_from_slice(&self.width.to_le_bytes());
        b[44..48].copy_from_slice(&self.height.to_le_bytes());
        b
    }

    pub fn decode(b: &[u8]) -> Option<Self> {
        if b.len() < VIDEO_HEADER_LEN {
            return None;
        }
        Some(Self {
            frame_seq: u64_at(b, 0),
            t_damage_ns: u64_at(b, 8),
            t_capture_ns: u64_at(b, 16),
            t_encoded_ns: u64_at(b, 24),
            last_input_seq: u32_at(b, 32),
            flags: u32_at(b, 36),
            width: u32_at(b, 40),
            height: u32_at(b, 44),
        })
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Input {
    pub seq: u32,
    pub kind: u32,
    pub x: i32,
    pub y: i32,
    pub code: u32,
    pub t_client_send_ns: u64,
}

impl Input {
    pub fn encode(&self) -> [u8; INPUT_LEN] {
        let mut b = [0u8; INPUT_LEN];
        b[0..4].copy_from_slice(&self.seq.to_le_bytes());
        b[4..8].copy_from_slice(&self.kind.to_le_bytes());
        b[8..12].copy_from_slice(&self.x.to_le_bytes());
        b[12..16].copy_from_slice(&self.y.to_le_bytes());
        b[16..20].copy_from_slice(&self.code.to_le_bytes());
        b[20..28].copy_from_slice(&self.t_client_send_ns.to_le_bytes());
        b
    }

    pub fn decode(b: &[u8]) -> Option<Self> {
        if b.len() < INPUT_LEN {
            return None;
        }
        Some(Self {
            seq: u32_at(b, 0),
            kind: u32_at(b, 4),
            x: u32_at(b, 8) as i32,
            y: u32_at(b, 12) as i32,
            code: u32_at(b, 16),
            t_client_send_ns: u64_at(b, 20),
        })
    }
}

pub fn decode_pong(b: &[u8]) -> Option<(u64, u64)> {
    (b.len() >= 16).then(|| (u64_at(b, 0), u64_at(b, 8)))
}

pub fn decode_ping(b: &[u8]) -> Option<u64> {
    (b.len() >= 8).then(|| u64_at(b, 0))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Hello {
    pub proto: String,
    pub width: u32,
    pub height: u32,
    pub max_fps: u32,
    pub bitrate_kbps: u32,
    pub workload: String,
    pub capture: String,
    pub client: String,
}

impl Default for Hello {
    fn default() -> Self {
        Self {
            proto: "rdproto/0".into(),
            width: 1920,
            height: 1080,
            max_fps: 60,
            bitrate_kbps: 8000,
            workload: "marker".into(),
            capture: "damage".into(),
            client: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct HelloAck {
    pub width: u32,
    pub height: u32,
    pub encoder: String,
    pub capture: String,
    pub host: String,
    pub cpu: String,
    pub cores: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct HostStats {
    pub cpu_pct_process: Option<f64>,
    pub cpu_pct_system: Option<f64>,
    pub frames: u64,
    pub bytes: u64,
    pub capture_ms_p50: Option<f64>,
    pub convert_ms_p50: Option<f64>,
    pub encode_ms_p50: Option<f64>,
    pub damage_to_send_ms_p50: Option<f64>,
    pub input_inject_to_damage_ms_p50: Option<f64>,
}
