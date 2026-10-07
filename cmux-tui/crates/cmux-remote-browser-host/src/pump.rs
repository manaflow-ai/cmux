//! The media pump of one viewer (remote-tab-r2.md section 1, step 3):
//! captured frames in, encoded and packetized datagrams out, viewer
//! datagrams (feedback, input) in, rb input events out. Pure: the encoder
//! and the frame type are the caller's (VideoToolbox over a capture lease on
//! macOS, a fake in tests), and every time is the caller's monotonic clock.
//!
//! The pump keeps the latest captured frame (one capture lease of Viz's
//! ten), so a frame that the engine's gate held back (fps cap, one frame in
//! flight) or a recovery keyframe is encoded from it at once, without a
//! capture round trip. It asks the capture for a refresh only when the
//! engine wants a frame and none was captured yet.

use std::collections::BTreeMap;

use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{
    EncodeRequest, Encoded, EngineConfig, EngineStats, MediaEngine, Output, StreamError,
};
use cmux_rd_proto::InputEvent as RdInput;
use cmux_remote_browser::proto::InputEvent;

/// The source's encoder behind a trait (VideoToolbox on macOS).
pub trait FrameEncoder {
    /// One captured frame (it releases its capture lease on drop).
    type Frame;
    /// Encodes `frame` into `out` (Annex-B). Returns true for an IDR.
    fn encode(
        &mut self,
        frame: &Self::Frame,
        damage: Rect,
        force_idr: bool,
        pts_us: i64,
        out: &mut Vec<u8>,
    ) -> Result<bool, String>;
    fn set_kbps(&mut self, kbps: u32);
    fn kbps(&self) -> u32;
}

/// What the source does after one pump call.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct PumpOut {
    /// Datagrams to send now, in order.
    pub datagrams: Vec<Vec<u8>>,
    /// rb input events from the viewer, applied exactly once, in order.
    pub input: Vec<InputEvent>,
    /// Release every key and button the viewer holds (input skipped a gap).
    pub release_all: bool,
    /// Ask the capture for a full frame (the engine wants a frame and the
    /// pump holds none).
    pub refresh: bool,
}

/// Counters of one pump.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct PumpStats {
    pub captured: u64,
    pub encoded: u64,
    pub idr: u64,
    pub encode_errors: u64,
    pub refreshes: u64,
    /// Viewer service events that are not rb input JSON (dropped).
    pub bad_input: u64,
    /// Viewer input events of another kind than service (dropped).
    pub foreign_input: u64,
}

/// One display stream: its encoder and its latest frame.
struct Slot<E: FrameEncoder> {
    encoder: E,
    /// The latest captured frame and its capture time.
    held: Option<(E::Frame, u64)>,
    /// A request that waits for the first captured frame.
    pending: Option<EncodeRequest>,
}

impl<E: FrameEncoder> Slot<E> {
    fn new(encoder: E) -> Self {
        Self { encoder, held: None, pending: None }
    }
}

/// One viewer's media state: the engine and, per display stream (the page
/// and each popup surface, RP7), an encoder and the latest frame.
pub struct Pump<E: FrameEncoder> {
    engine: MediaEngine,
    /// The page's stream.
    stream: u16,
    main: Slot<E>,
    popups: BTreeMap<u16, Slot<E>>,
    stats: PumpStats,
}

impl<E: FrameEncoder> Pump<E> {
    pub fn new(cfg: EngineConfig, encoder: E, now_us: u64) -> Self {
        Self {
            engine: MediaEngine::new(cfg, now_us),
            stream: cfg.stream,
            main: Slot::new(encoder),
            popups: BTreeMap::new(),
            stats: PumpStats::default(),
        }
    }

    /// The viewer joined: the first frame (the whole surface, an IDR).
    pub fn start(&mut self, now_us: u64) -> PumpOut {
        let mut out = PumpOut::default();
        let req = self.engine.start(now_us);
        self.serve(req, now_us, &mut out);
        out
    }

    /// A captured frame with the region that changed since the previous one
    /// (frame pixels) and its capture time.
    pub fn frame(
        &mut self,
        frame: E::Frame,
        damage: Rect,
        t_capture_us: u64,
        now_us: u64,
    ) -> PumpOut {
        self.frame_on(self.stream, frame, damage, t_capture_us, now_us)
    }

    /// Adds popup stream `stream` (`width` x `height` pixels) with its own
    /// encoder; its first frame is a keyframe of the whole stream.
    pub fn add_stream(
        &mut self,
        stream: u16,
        width: u32,
        height: u32,
        encoder: E,
    ) -> Result<(), StreamError> {
        if stream == self.stream {
            return Err(StreamError::Exists(stream));
        }
        self.engine.add_stream(stream, width, height)?;
        self.popups.insert(stream, Slot::new(encoder));
        Ok(())
    }

    /// Removes popup stream `stream` and gives its held frame back.
    pub fn remove_stream(&mut self, stream: u16) {
        if self.popups.remove(&stream).is_some() {
            self.engine.remove_stream(stream);
        }
    }

    /// A captured frame of `stream` ([`Self::frame`] for another stream).
    /// A frame of an unknown stream is dropped (its lease goes back).
    pub fn frame_on(
        &mut self,
        stream: u16,
        frame: E::Frame,
        damage: Rect,
        t_capture_us: u64,
        now_us: u64,
    ) -> PumpOut {
        let mut out = PumpOut::default();
        let Some(slot) = self.slot(stream) else { return out };
        // The previous frame's lease goes back to Viz here.
        slot.held = Some((frame, t_capture_us));
        let pending = slot.pending.take();
        self.stats.captured += 1;
        let req = match pending {
            Some(req) => Some(req),
            None => self.engine.damage(stream, damage, now_us),
        };
        self.serve(req, now_us, &mut out);
        out
    }

    fn slot(&mut self, stream: u16) -> Option<&mut Slot<E>> {
        if stream == self.stream { Some(&mut self.main) } else { self.popups.get_mut(&stream) }
    }

    /// One datagram from the viewer. `may_inject` is the input gate.
    pub fn datagram(&mut self, datagram: &[u8], may_inject: bool, now_us: u64) -> PumpOut {
        let engine_out = self.engine.on_datagram(datagram, may_inject, now_us);
        self.absorb(engine_out, now_us)
    }

    /// Advances time: a frame held by the fps cap, input held behind a gap.
    pub fn tick(&mut self, may_inject: bool, now_us: u64) -> PumpOut {
        let ticked = self.engine.tick(may_inject, now_us);
        let mut out = self.absorb(ticked, now_us);
        let req = self.engine.poll(now_us);
        self.serve(req, now_us, &mut out);
        out
    }

    /// When [`Self::tick`] must run next; `None` while nothing is pending
    /// (an idle page needs no wakeup).
    pub fn next_deadline_us(&self) -> Option<u64> {
        self.engine.next_deadline_us()
    }

    /// Gives the page's held frame back (capture stopped or the tab closed).
    pub fn release_frame(&mut self) {
        self.main.held = None;
    }

    pub fn holds_frame(&self) -> bool {
        self.main.held.is_some()
    }

    pub fn stats(&self) -> PumpStats {
        self.stats
    }

    pub fn engine_stats(&self) -> EngineStats {
        self.engine.stats()
    }

    /// The page stream's encoder.
    pub fn encoder(&self) -> &E {
        &self.main.encoder
    }

    pub fn encoder_mut(&mut self) -> &mut E {
        &mut self.main.encoder
    }

    fn absorb(&mut self, engine_out: Output, now_us: u64) -> PumpOut {
        let mut out = PumpOut {
            datagrams: engine_out.datagrams,
            release_all: engine_out.release_all,
            ..PumpOut::default()
        };
        for event in engine_out.inject {
            match event {
                RdInput::Service { bytes, .. } => match serde_json::from_slice(&bytes) {
                    Ok(event) => out.input.push(event),
                    Err(_) => self.stats.bad_input += 1,
                },
                _ => self.stats.foreign_input += 1,
            }
        }
        if engine_out.halve_bitrate {
            halve(&mut self.main.encoder);
        }
        self.serve(engine_out.encode, now_us, &mut out);
        out
    }

    /// Encodes `req` from its stream's held frame, or waits for a captured
    /// one (only the page asks the capture for a refresh; a popup's first
    /// frame comes with its capture).
    fn serve(&mut self, req: Option<EncodeRequest>, now_us: u64, out: &mut PumpOut) {
        let Some(req) = req else { return };
        let is_main = req.stream == self.stream;
        let Some(slot) = self.slot(req.stream) else { return };
        let Some((frame, t_capture_us)) = slot.held.as_ref() else {
            // A recovery request replaces an older pending one: it asks for more.
            slot.pending = Some(match slot.pending.take() {
                Some(old) => EncodeRequest { force_idr: old.force_idr || req.force_idr, ..req },
                None => req,
            });
            if is_main {
                if !out.refresh {
                    self.stats.refreshes += 1;
                }
                out.refresh = true;
            }
            return;
        };
        let t_capture_us = *t_capture_us;
        if req.target_kbps > 0 && req.target_kbps != slot.encoder.kbps() {
            slot.encoder.set_kbps(req.target_kbps);
        }
        let mut access_unit = Vec::new();
        let pts = i64::try_from(t_capture_us).unwrap_or(i64::MAX);
        let result = slot.encoder.encode(frame, req.damage, req.force_idr, pts, &mut access_unit);
        let encoded = match result {
            Ok(idr) => {
                self.stats.encoded += 1;
                self.stats.idr += u64::from(idr);
                Some(Encoded { access_unit, idr, t_capture_us })
            }
            Err(_) => {
                // The gate opens again; the next damage tries anew.
                self.stats.encode_errors += 1;
                None
            }
        };
        match self.engine.encoded(&req, encoded, now_us) {
            Ok(engine_out) => {
                if engine_out.halve_bitrate
                    && let Some(slot) = self.slot(req.stream)
                {
                    halve(&mut slot.encoder);
                }
                out.datagrams.extend(engine_out.datagrams);
            }
            Err(_) => self.stats.encode_errors += 1,
        }
    }
}

/// The last frame was too large to send: half the bitrate.
fn halve<E: FrameEncoder>(encoder: &mut E) {
    let kbps = encoder.kbps() / 2;
    encoder.set_kbps(kbps.max(1));
}
