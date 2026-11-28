//! One Windows viewing session: GDI capture paced by a timer (the frame gate drops unchanged
//! frames), OpenH264, the shared media engine (cmux-rd-engine) and SendInput, over any
//! [`Wire`]: the framed TCP stream of `cmux-rd host` ([`TcpWire`]) or the secure link of a
//! device hub session (`cmux-rd serve`, src/windows_serve.rs).

use super::{
    apply_input, hid_to_scancode, mouse_button_event, read_frame, sample, send_input_scancode,
    send_mouse, write_control, write_frame, GdiCapture, HostMetrics, FRAME_CONTROL, FRAME_DATAGRAM,
};
use crate::clock::now_ns;
use crate::encoder::H264Encoder;
use crate::Res;
use cmux_encode::{bgrx_rect_to_i420, I420};
use cmux_rd_core::cc::PathKind;
use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{EngineConfig, MediaEngine, Output};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::InputEvent;
use std::collections::{hash_map::DefaultHasher, BTreeSet};
use std::hash::Hasher;
use std::net::TcpStream;
use std::time::{Duration, Instant};

/// One thing that arrived from the viewer.
pub(crate) enum Incoming {
    Control(Control),
    Datagram(Vec<u8>),
}

/// What carries a session's control messages and datagrams.
pub(crate) trait Wire {
    /// Takes everything waiting, without blocking. `Ok(false)`: the viewer is gone (end of
    /// stream); `Err` ends the session with its reason.
    fn receive(&mut self, out: &mut Vec<Incoming>) -> Res<bool>;
    fn send_datagram(&mut self, datagram: &[u8]) -> Res<()>;
    fn send_control(&mut self, control: &Control) -> Res<()>;
    /// Waits at most `limit` for something to arrive (the loop's pacing).
    fn wait(&mut self, limit: Duration);
}

/// The framed TCP stream of `cmux-rd host` (control and datagrams on one stream).
pub(crate) struct TcpWire<'a> {
    pub(crate) stream: &'a mut TcpStream,
    pub(crate) input: Vec<u8>,
}

impl Wire for TcpWire<'_> {
    fn receive(&mut self, out: &mut Vec<Incoming>) -> Res<bool> {
        loop {
            let Some((ty, payload)) = read_frame(self.stream, &mut self.input)? else {
                return Ok(false);
            };
            if payload.is_empty() && ty == 0 {
                return Ok(true);
            }
            match ty {
                FRAME_CONTROL => {
                    if let Ok(control) = serde_json::from_slice::<Control>(&payload) {
                        out.push(Incoming::Control(control));
                    }
                }
                FRAME_DATAGRAM => out.push(Incoming::Datagram(payload)),
                _ => {}
            }
        }
    }

    fn send_datagram(&mut self, datagram: &[u8]) -> Res<()> {
        Ok(write_frame(self.stream, FRAME_DATAGRAM, datagram)?)
    }

    fn send_control(&mut self, control: &Control) -> Res<()> {
        Ok(write_control(self.stream, control)?)
    }

    fn wait(&mut self, limit: Duration) {
        // A non-blocking stream: poll it every millisecond, as before.
        std::thread::sleep(limit.min(Duration::from_millis(1)));
    }
}

pub(crate) struct WindowsSession {
    capture: GdiCapture,
    encoder: Box<dyn H264Encoder>,
    picture: I420,
    engine: MediaEngine,
    held_keys: BTreeSet<u16>,
    held_buttons: BTreeSet<u8>,
    last_frame_fingerprint: Option<u64>,
    width: u32,
    height: u32,
    interval: Duration,
    pub(crate) metrics: Option<HostMetrics>,
    pub(crate) deadline: Option<Instant>,
    /// Whether the viewer's input reaches this desktop (a control session). False: the engine
    /// takes the input datagrams (acknowledged, never applied) and nothing is injected.
    pub(crate) may_inject: bool,
}

impl WindowsSession {
    pub(crate) fn new(
        capture: GdiCapture,
        encoder: Box<dyn H264Encoder>,
        max_datagram: usize,
        fps: u32,
        start_kbps: u32,
        max_kbps: u32,
    ) -> Self {
        let fps = fps.max(1);
        let (width, height) = capture.size();
        Self {
            capture,
            encoder,
            picture: I420::new(width as usize, height as usize),
            engine: MediaEngine::new(
                EngineConfig {
                    width,
                    height,
                    max_fps: fps,
                    start_bps: u64::from(start_kbps) * 1000,
                    max_bps: u64::from(max_kbps.max(start_kbps)) * 1000,
                    max_datagram,
                    path: PathKind::ViaCloudRegion,
                    ..EngineConfig::default()
                },
                now_ns() / 1000,
            ),
            held_keys: BTreeSet::new(),
            held_buttons: BTreeSet::new(),
            last_frame_fingerprint: None,
            width,
            height,
            interval: Duration::from_secs_f64(1.0 / f64::from(fps)),
            metrics: None,
            deadline: None,
            may_inject: true,
        }
    }

    /// Streams until the viewer stops or leaves; every key and button it holds is released.
    pub(crate) fn run(&mut self, wire: &mut dyn Wire) -> Res<()> {
        let result = self.run_loop(wire);
        let cleanup = self.release_all();
        match (result, cleanup) {
            (Err(error), _) => Err(error),
            (Ok(()), Err(error)) => Err(error),
            (Ok(()), Ok(())) => Ok(()),
        }
    }

    fn run_loop(&mut self, wire: &mut dyn Wire) -> Res<()> {
        let mut incoming = Vec::new();
        let mut next = Instant::now();
        loop {
            if self.deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                return Err("Windows loopback host exceeded its deadline".into());
            }
            if !wire.receive(&mut incoming)? {
                return Ok(());
            }
            for item in incoming.drain(..) {
                match item {
                    Incoming::Control(Control::Stop) => {
                        wire.send_control(&Control::Ended { reason: "stopped by viewer".into() })?;
                        return Ok(());
                    }
                    Incoming::Datagram(datagram) => {
                        let output =
                            self.engine.on_datagram(&datagram, self.may_inject, now_ns() / 1000);
                        self.send_output(wire, output)?;
                    }
                    Incoming::Control(_) => {}
                }
            }
            let now = Instant::now();
            if now >= next {
                let capture_started = self.metrics.as_ref().map(|_| Instant::now());
                let now_us = now_ns() / 1000;
                let pixels = self.capture.capture()?.to_vec();
                let mut fingerprint = DefaultHasher::new();
                fingerprint.write(&pixels);
                let fingerprint = fingerprint.finish();
                let changed =
                    self.last_frame_fingerprint.map_or(true, |previous| previous != fingerprint);
                self.last_frame_fingerprint = Some(fingerprint);
                if let (Some(metrics), Some(start)) = (&mut self.metrics, capture_started) {
                    sample(&mut metrics.capture_ms, start);
                }
                let request = if changed {
                    self.engine.damage(
                        0,
                        Rect { x: 0, y: 0, width: self.width, height: self.height },
                        now_us,
                    )
                } else {
                    // Damage held by the fps cap still needs its due frame when the
                    // desktop stops changing; no new damage event will wake it.
                    self.engine.poll(now_us)
                };
                if let Some(req) = request {
                    self.encode(wire, &req, &pixels)?;
                }
                let output = self.engine.tick(self.may_inject, now_us);
                self.send_output(wire, output)?;
                next = now + self.interval;
            }
            wire.wait(next.saturating_duration_since(Instant::now()));
        }
    }

    fn encode(
        &mut self,
        wire: &mut dyn Wire,
        req: &cmux_rd_engine::EncodeRequest,
        pixels: &[u8],
    ) -> Res<()> {
        let conversion_started = self.metrics.as_ref().map(|_| Instant::now());
        bgrx_rect_to_i420(
            pixels,
            &mut self.picture,
            0,
            0,
            self.width as usize,
            self.height as usize,
            2,
        );
        if let (Some(metrics), Some(start)) = (&mut self.metrics, conversion_started) {
            sample(&mut metrics.convert_ms, start);
        }
        let mut au = Vec::new();
        let encode_started = self.metrics.as_ref().map(|_| Instant::now());
        let idr =
            self.encoder.encode(&self.picture, req.force_idr, now_ns() as i64 / 1000, &mut au)?;
        if let (Some(metrics), Some(start)) = (&mut self.metrics, encode_started) {
            sample(&mut metrics.encode_ms, start);
        }
        let out = self
            .engine
            .encoded(
                req,
                Some(cmux_rd_engine::Encoded {
                    access_unit: au,
                    idr,
                    t_capture_us: now_ns() / 1000,
                    ltr_token: None,
                }),
                now_ns() / 1000,
            )
            .map_err(|e| format!("packetize: {e:?}"))?;
        self.send_output(wire, out)
    }

    fn send_output(&mut self, wire: &mut dyn Wire, out: Output) -> Res<()> {
        for datagram in out.datagrams {
            wire.send_datagram(&datagram)?;
        }
        if out.release_all {
            self.release_all()?;
        }
        // The engine injects nothing it was not allowed to; this keeps a view session's
        // desktop untouched whatever the engine decides.
        for event in out.inject.into_iter().filter(|_| self.may_inject) {
            apply_input(&event, self.width, self.height)?;
            match event {
                InputEvent::Key { usage, down } => {
                    if let Some(scancode) = hid_to_scancode(usage) {
                        if down {
                            self.held_keys.insert(scancode);
                        } else {
                            self.held_keys.remove(&scancode);
                        }
                    }
                }
                InputEvent::Button { button, down } => {
                    if mouse_button_event(button, down).is_some() {
                        if down {
                            self.held_buttons.insert(button);
                        } else {
                            self.held_buttons.remove(&button);
                        }
                    }
                }
                _ => {}
            }
        }
        if let Some(req) = out.encode {
            // Feedback and recovery can open the frame gate. Ignoring this request
            // leaves a frame marked in flight that was never encoded or sent.
            let capture_started = self.metrics.as_ref().map(|_| Instant::now());
            let pixels = self.capture.capture()?.to_vec();
            if let (Some(metrics), Some(start)) = (&mut self.metrics, capture_started) {
                sample(&mut metrics.capture_ms, start);
            }
            self.encode(wire, &req, &pixels)?;
        }
        Ok(())
    }

    fn release_all(&mut self) -> Res<()> {
        let keys = std::mem::take(&mut self.held_keys);
        for scancode in keys {
            send_input_scancode(scancode, false)?;
        }
        let buttons = std::mem::take(&mut self.held_buttons);
        for button in buttons {
            let Some((flags, data)) = mouse_button_event(button, false) else {
                continue;
            };
            send_mouse(0, 0, flags, data)?;
        }
        Ok(())
    }
}
