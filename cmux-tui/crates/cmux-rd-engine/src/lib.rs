//! Placeholder (red commit): the engine lands in the next commit.

use cmux_rd_core::flow::Rect;
use cmux_rd_core::packetize::PacketizeError;
use cmux_rd_proto::InputEvent;

#[derive(Debug, Clone, Copy, Default)]
pub struct EngineConfig {
    pub width: u32,
    pub height: u32,
    pub max_fps: u32,
    pub start_bps: u64,
    pub max_bps: u64,
    pub max_datagram: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodeRequest {
    pub frame: u32,
    pub damage: Rect,
    pub force_idr: bool,
    pub target_kbps: u32,
}

pub struct Encoded {
    pub access_unit: Vec<u8>,
    pub idr: bool,
    pub t_capture_us: u64,
}

#[derive(Debug, Default)]
pub struct Output {
    pub datagrams: Vec<Vec<u8>>,
    pub inject: Vec<InputEvent>,
    pub release_all: bool,
    pub encode: Option<EncodeRequest>,
    pub halve_bitrate: bool,
}

pub struct MediaEngine;

impl MediaEngine {
    pub fn new(_cfg: EngineConfig, _now_us: u64) -> Self {
        Self
    }
    pub fn start(&mut self, _now_us: u64) -> Option<EncodeRequest> {
        None
    }
    pub fn damage(&mut self, _r: Rect, _now_us: u64) -> Option<EncodeRequest> {
        None
    }
    pub fn encoded(&mut self, _r: &EncodeRequest, _e: Option<Encoded>, _now_us: u64) -> Result<Output, PacketizeError> {
        Ok(Output::default())
    }
    pub fn on_datagram(&mut self, _d: &[u8], _may_inject: bool, _now_us: u64) -> Output {
        Output::default()
    }
    pub fn silent_for_us(&self, _now_us: u64) -> u64 {
        0
    }
}
