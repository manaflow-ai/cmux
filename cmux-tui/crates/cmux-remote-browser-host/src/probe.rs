//! `--probe ADDR OUT_DIR`: a loopback viewer for the host's own proof
//! (remote-tab-r2.md section 2, step 4). It speaks the rd stream carrier with
//! the viewer core the Mac client links (cmux-rd-ffi), and writes to OUT_DIR:
//! - `stream.h264`: every access unit it received (Annex-B), for an offline
//!   decode to PNG;
//! - `result.json`: frames and keyframes, frames while idle (must be 0), and
//!   key-to-frame latencies: an rb key sent as an rd service input event to
//!   the first complete frame after it (encode, packetize, loopback network
//!   and reassembly included; decode not included).
//!
//! The page is the host's `--url`; the default test page toggles a box on
//! every keydown, so each key makes exactly one frame.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::Path;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, Instant};

use cmux_rd_ffi::{Carrier, InputChannel, Session};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::{
    InputEvent, SERVICE_REMOTE_BROWSER, STREAM_CONTROL, encode_stream_frame, flags,
};

/// Probe settings.
#[derive(Debug, Clone, Copy)]
pub struct Plan {
    pub settle_ms: u64,
    pub idle_ms: u64,
    pub keys: usize,
    pub key_spacing_ms: u64,
    pub first_frame_timeout_ms: u64,
    /// After the keys: a right-click must show an rb menu (answered with
    /// cancel), then key `d` must show an rb dialog (answered with OK). Needs
    /// a page that opens an alert on `d` ([`UI_PAGE`]).
    pub ui: bool,
}

/// A page for `--ui`: key `d` opens an alert; a right-click opens the
/// page's context menu.
pub const UI_PAGE: &str = "data:text/html,<html><body style='margin:0;background:%23203040'>\
<script>addEventListener('keydown',e=>{if(e.key=='d')alert('hello from the host');});\
document.title='ready';</script></body></html>";

impl Default for Plan {
    fn default() -> Self {
        Self {
            settle_ms: 2000,
            idle_ms: 5000,
            keys: 40,
            key_spacing_ms: 200,
            first_frame_timeout_ms: 30_000,
            ui: false,
        }
    }
}

/// What the probe measured.
#[derive(Debug, Default, Clone)]
pub struct Report {
    pub controls: Vec<serde_json::Value>,
    pub frames: u64,
    pub keyframes: u64,
    pub bytes: u64,
    pub first_frame_ms: Option<f64>,
    pub idle_frames: Option<u64>,
    pub keys_sent: usize,
    pub latencies_ms: Vec<f64>,
    pub error: Option<String>,
    /// `--ui`: the item count of the context menu the viewer was shown.
    pub menu_items: Option<usize>,
    /// `--ui`: the kind of the dialog the viewer was shown.
    pub dialog_kind: Option<String>,
}

#[derive(PartialEq)]
enum Phase {
    WaitFirst,
    Settle { until: Instant },
    Idle { until: Instant, start_frames: u64 },
    Keys { next: Instant },
    Menu { until: Instant },
    Dialog { until: Instant },
    Done,
}

fn key_event(down: bool) -> Vec<u8> {
    key(down, "KeyA", "a")
}

fn key(down: bool, code: &str, key: &str) -> Vec<u8> {
    let text = if down { key } else { "" };
    serde_json::json!({"e": "key", "surface": 0, "down": down, "code": code, "key": key,
        "text": text, "unmodified_text": text, "modifiers": 0, "repeat": false,
        "location": 0, "edit_commands": []})
    .to_string()
    .into_bytes()
}

fn right_click(down: bool) -> Vec<u8> {
    serde_json::json!({"e": "pointer", "surface": 0, "kind": if down { "down" } else { "up" },
        "x": 300.0, "y": 300.0, "button": 2, "buttons": if down { 2 } else { 0 },
        "click_count": 1, "modifiers": 0, "pointer_type": "mouse"})
    .to_string()
    .into_bytes()
}

/// An rb message to the host (rd service control).
fn service(body: serde_json::Value) -> Vec<u8> {
    let control = Control::Service { service: SERVICE_REMOTE_BROWSER.into(), body };
    let mut out = Vec::new();
    let json = serde_json::to_vec(&control).unwrap_or_default();
    let _ = encode_stream_frame(STREAM_CONTROL, &json, &mut out);
    out
}

/// The body of the first rb message `t` in `controls`.
fn rb_message<'a>(controls: &'a [serde_json::Value], t: &str) -> Option<&'a serde_json::Value> {
    controls.iter().map(|c| &c["body"]).find(|b| b["t"] == t)
}

fn hello() -> Vec<u8> {
    let control = Control::Hello {
        user: "probe".into(),
        install: "probe".into(),
        class: "viewer".into(),
        interactive: true,
        udp_port: None,
        max_datagram: 1332,
        token: None,
        service: SERVICE_REMOTE_BROWSER.into(),
        caps: vec![],
    };
    let mut out = Vec::new();
    let json = serde_json::to_vec(&control).unwrap_or_default();
    let _ = encode_stream_frame(STREAM_CONTROL, &json, &mut out);
    out
}

/// Runs the probe against `addr` and writes its files into `out`.
pub fn run(addr: SocketAddr, out: &Path, plan: Plan) -> Report {
    let mut report = Report::default();
    if let Err(e) = probe(addr, out, plan, &mut report) {
        report.error = Some(e);
    }
    let _ = std::fs::write(out.join("result.json"), result_json(&report));
    report
}

fn probe(addr: SocketAddr, out: &Path, plan: Plan, r: &mut Report) -> Result<(), String> {
    std::fs::create_dir_all(out).map_err(|e| e.to_string())?;
    let mut h264 = std::fs::File::create(out.join("stream.h264")).map_err(|e| e.to_string())?;
    let mut sock =
        TcpStream::connect_timeout(&addr, Duration::from_secs(10)).map_err(|e| e.to_string())?;
    sock.set_nodelay(true).map_err(|e| e.to_string())?;
    sock.write_all(&hello()).map_err(|e| e.to_string())?;
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let mut reader = sock.try_clone().map_err(|e| e.to_string())?;
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 64 * 1024];
        while let Ok(n) = reader.read(&mut buf) {
            if n == 0 || tx.send(buf[..n].to_vec()).is_err() {
                return;
            }
        }
    });
    let t0 = Instant::now();
    let now = || u64::try_from(t0.elapsed().as_micros()).unwrap_or(u64::MAX);
    let mut core = Session::new(Carrier::Stream, 500_000, 50_000);
    let mut input = InputChannel::new(Carrier::Stream, 50_000);
    let mut phase = Phase::WaitFirst;
    let mut key_sent_at: Option<Instant> = None;
    let deadline = t0 + Duration::from_millis(plan.first_frame_timeout_ms);
    while phase != Phase::Done {
        let wait_us = core.next_deadline_us().saturating_sub(now()).clamp(1_000, 10_000);
        match rx.recv_timeout(Duration::from_micros(wait_us)) {
            Ok(bytes) => core.push_stream(&bytes, now()).map_err(|e| format!("push: {e:?}"))?,
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Err("the host closed".into()),
        }
        core.tick(now());
        while let Some(m) = core.pop_message() {
            if m.kind == STREAM_CONTROL {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&m.bytes) {
                    r.controls.push(v);
                }
            } else {
                let _ = input.on_ack(&m.bytes);
            }
        }
        while let Some((_, frame)) = core.pop_frame() {
            r.frames += 1;
            r.bytes += frame.body.access_unit.len() as u64;
            r.keyframes += u64::from(frame.flags & flags::KEYFRAME != 0);
            let _ = h264.write_all(&frame.body.access_unit);
            if r.first_frame_ms.is_none() {
                r.first_frame_ms = Some(t0.elapsed().as_secs_f64() * 1000.0);
            }
            if let Some(sent) = key_sent_at.take() {
                r.latencies_ms.push(sent.elapsed().as_secs_f64() * 1000.0);
            }
        }
        while let Some(fb) = core.feedback(now()) {
            sock.write_all(&fb).map_err(|e| e.to_string())?;
        }
        let at = Instant::now();
        phase = match phase {
            Phase::WaitFirst if r.frames > 0 => {
                Phase::Settle { until: at + Duration::from_millis(plan.settle_ms) }
            }
            Phase::WaitFirst if at > deadline => return Err("no frame within the timeout".into()),
            Phase::Settle { until } if at >= until => Phase::Idle {
                until: at + Duration::from_millis(plan.idle_ms),
                start_frames: r.frames,
            },
            Phase::Idle { until, start_frames } if at >= until => {
                r.idle_frames = Some(r.frames - start_frames);
                Phase::Keys { next: at }
            }
            Phase::Keys { next } if at >= next => {
                if r.keys_sent >= plan.keys && plan.ui {
                    input
                        .push(InputEvent::Service { must_deliver: true, bytes: right_click(true) });
                    input.push(InputEvent::Service {
                        must_deliver: true,
                        bytes: right_click(false),
                    });
                    Phase::Menu { until: at + Duration::from_secs(5) }
                } else if r.keys_sent >= plan.keys {
                    Phase::Done
                } else {
                    // A missed frame for the previous key counts as no sample.
                    key_sent_at = Some(at);
                    r.keys_sent += 1;
                    input.push(InputEvent::Service { must_deliver: true, bytes: key_event(true) });
                    input.push(InputEvent::Service { must_deliver: true, bytes: key_event(false) });
                    Phase::Keys { next: at + Duration::from_millis(plan.key_spacing_ms) }
                }
            }
            Phase::Menu { until } => match rb_message(&r.controls, "rb.menu.show") {
                Some(show) => {
                    r.menu_items = show["menu"]["items"].as_array().map(Vec::len);
                    let answer = serde_json::json!({"t": "rb.menu.result",
                        "token": show["token"], "choice": {"choice": "cancel"}});
                    sock.write_all(&service(answer)).map_err(|e| e.to_string())?;
                    input.push(InputEvent::Service {
                        must_deliver: true,
                        bytes: key(true, "KeyD", "d"),
                    });
                    input.push(InputEvent::Service {
                        must_deliver: true,
                        bytes: key(false, "KeyD", "d"),
                    });
                    Phase::Dialog { until: at + Duration::from_secs(5) }
                }
                None if at >= until => return Err("no rb.menu.show after a right-click".into()),
                None => Phase::Menu { until },
            },
            Phase::Dialog { until } => match rb_message(&r.controls, "rb.dialog.show") {
                Some(show) => {
                    r.dialog_kind = show["dialog"]["kind"].as_str().map(str::to_string);
                    let answer = serde_json::json!({"t": "rb.dialog.result",
                        "token": show["token"], "accept": true, "text": null});
                    sock.write_all(&service(answer)).map_err(|e| e.to_string())?;
                    Phase::Done
                }
                None if at >= until => return Err("no rb.dialog.show after key d".into()),
                None => Phase::Dialog { until },
            },
            other => other,
        };
        while let Some(packet) = input.packet(now()) {
            sock.write_all(&packet).map_err(|e| e.to_string())?;
        }
    }
    let _ = sock.shutdown(std::net::Shutdown::Both);
    Ok(())
}

fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    let i = ((sorted.len().checked_sub(1)?) as f64 * p).round() as usize;
    sorted.get(i).copied()
}

fn result_json(r: &Report) -> String {
    let mut l = r.latencies_ms.clone();
    l.sort_by(f64::total_cmp);
    let round = |v: Option<f64>| v.map(|v| (v * 10.0).round() / 10.0);
    serde_json::json!({
        "frames": r.frames,
        "keyframes": r.keyframes,
        "bytes": r.bytes,
        "first_frame_ms": round(r.first_frame_ms),
        "idle_frames": r.idle_frames,
        "keys": r.keys_sent,
        "key_to_frame_ms": {"count": l.len(), "p50": round(percentile(&l, 0.5)),
            "p95": round(percentile(&l, 0.95)), "max": round(l.last().copied())},
        "controls": r.controls.iter().map(|c| c["t"].clone()).collect::<Vec<_>>(),
        "menu_items": r.menu_items,
        "dialog_kind": r.dialog_kind,
        "error": r.error,
    })
    .to_string()
        + "\n"
}
