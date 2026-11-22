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

use cmux_rd_core::service::caps::INPUT_SERVICE;
use cmux_rd_ffi::{Carrier, InputChannel, Session};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::{
    DatagramHeader, DatagramKind, InputEvent, InputPacket, SERVICE_REMOTE_BROWSER, STREAM_CONTROL,
    STREAM_DATAGRAM, encode_stream_frame, flags,
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
    /// Then each picker of [`PICKER_PAGE`] (date, color, datalist): a click
    /// opens it, which must show an rb surface with frames on its own
    /// stream; a click inside the surface answers it, which must hide it.
    pub pickers: bool,
    /// Last: hold key `S`, then skip one input sequence number so the host
    /// skips a gap and must release `S` ([`PICKER_PAGE`] turns green on the
    /// release; the host logs `release_all`).
    pub stuck_key: bool,
}

/// A page for `--ui`: key `d` opens an alert; a right-click opens the
/// page's context menu.
pub const UI_PAGE: &str = "data:text/html,<html><body style='margin:0;background:%23203040'>\
<script>addEventListener('keydown',e=>{if(e.key=='d')alert('hello from the host');});\
document.title='ready';</script></body></html>";

/// A page for `--pickers` and `--stuck-key`: a date input, a color input
/// with suggestions and a text input with a datalist (each opens its
/// picker on click), and a body that is red while `S` is held.
pub const PICKER_PAGE: &str = "data:text/html,<html><body style='margin:0;background:%23203040'>\
<input id=d type=date style='position:absolute;left:20px;top:20px;width:200px;height:30px'>\
<input id=c type=color list=cl style='position:absolute;left:20px;top:80px;width:60px;height:30px'>\
<datalist id=cl><option value=%23ff0000><option value=%2300ff00><option value=%230000ff></datalist>\
<input id=t list=tl style='position:absolute;left:20px;top:140px;width:200px;height:30px'>\
<datalist id=tl><option value=alpha><option value=beta><option value=gamma></datalist>\
<script>for(const e of document.querySelectorAll('input')){\
e.addEventListener('click',()=>{if(e.type!='color'){try{e.showPicker()}catch(x){document.title='err '+x}}});\
e.addEventListener('input',()=>document.title=e.id+'='+e.value);}\
addEventListener('keydown',e=>{if(e.code=='KeyS'){document.body.style.background='red';document.title='held KeyS'}});\
addEventListener('keyup',e=>{if(e.code=='KeyS'){document.body.style.background='green';document.title='released KeyS'}});\
document.title='ready';</script></body></html>";

/// A picker of [`PICKER_PAGE`]: name, where to click on the page (DIP), and
/// where to click inside the open surface as a fraction of its size.
type Picker = (&'static str, (f64, f64), (f64, f64));

const PICKERS: [Picker; 3] = [
    // A day in the middle of the calendar grid.
    ("date", (120.0, 35.0), (0.5, 0.6)),
    // The first suggested swatch.
    ("color", (50.0, 95.0), (0.115, 0.26)),
    // The first option.
    ("datalist", (120.0, 155.0), (0.5, 0.15)),
];

impl Default for Plan {
    fn default() -> Self {
        Self {
            settle_ms: 2000,
            idle_ms: 5000,
            keys: 40,
            key_spacing_ms: 200,
            first_frame_timeout_ms: 30_000,
            ui: false,
            pickers: false,
            stuck_key: false,
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
    /// `--pickers`: one entry per picker.
    pub pickers: Vec<PickerResult>,
    /// Complete frames per popup stream.
    pub popup_frames: std::collections::BTreeMap<u16, u64>,
    /// `--stuck-key`: frames after the sequence gap (the release repaints).
    pub frames_after_gap: Option<u64>,
}

/// What one picker did.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct PickerResult {
    pub name: String,
    pub surface: Option<u64>,
    pub stream: Option<u16>,
    pub width: Option<u64>,
    pub height: Option<u64>,
    /// Complete frames on its stream before the answer.
    pub frames: u64,
    /// `rb.surface.hide` came after the click inside it.
    pub answered: bool,
}

#[derive(PartialEq)]
enum Phase {
    WaitFirst,
    Settle {
        until: Instant,
    },
    Idle {
        until: Instant,
        start_frames: u64,
    },
    Keys {
        next: Instant,
    },
    Menu {
        until: Instant,
    },
    Dialog {
        until: Instant,
    },
    /// Click picker `index` open (past the last one: the next check).
    PickerStart {
        index: usize,
    },
    /// Picker `index` was clicked when `shows` surfaces had been shown:
    /// waiting for its surface and a frame on its stream.
    PickerOpen {
        index: usize,
        shows: usize,
        until: Instant,
    },
    /// Picker `index`: answered, waiting for `rb.surface.hide`.
    PickerAnswer {
        index: usize,
        surface: u64,
        until: Instant,
    },
    /// A picker stayed open: Escape went out; picker `index` starts at `until`.
    PickerPause {
        index: usize,
        until: Instant,
    },
    /// Press `S` (its release is the one the gap loses).
    StuckStart,
    /// `S` is down (sequence `seq`); the gap packet goes out at `at`.
    StuckHold {
        seq: u32,
        at: Instant,
    },
    /// The gap packet went out; frames from `frames` on are after it.
    StuckWait {
        until: Instant,
        frames: u64,
    },
    Done,
}

fn click(surface: u64, x: f64, y: f64, down: bool) -> Vec<u8> {
    serde_json::json!({"e": "pointer", "surface": surface, "kind": if down { "down" } else { "up" },
        "x": x, "y": y, "button": 0, "buttons": u8::from(down),
        "click_count": 1, "modifiers": 0, "pointer_type": "mouse"})
    .to_string()
    .into_bytes()
}

fn pointer_move(x: f64, y: f64) -> Vec<u8> {
    serde_json::json!({"e": "pointer", "surface": 0, "kind": "move", "x": x, "y": y,
        "button": 0, "buttons": 0, "click_count": 0, "modifiers": 0, "pointer_type": "mouse"})
    .to_string()
    .into_bytes()
}

/// The phase after the keys and the menu and dialog checks.
fn after_ui(plan: &Plan) -> Phase {
    if plan.pickers { Phase::PickerStart { index: 0 } } else { after_pickers(plan) }
}

fn after_pickers(plan: &Plan) -> Phase {
    if plan.stuck_key { Phase::StuckStart } else { Phase::Done }
}

/// Every rb message `t` in `controls`.
fn rb_messages<'a>(
    controls: &'a [serde_json::Value],
    t: &'a str,
) -> impl Iterator<Item = &'a serde_json::Value> + 'a {
    controls.iter().map(|c| &c["body"]).filter(move |b| b["t"] == t)
}

/// One stream-framed input datagram with `events` from sequence `first_seq`
/// (the probe's own gap: the input channel never skips a number).
fn raw_input(first_seq: u32, events: Vec<InputEvent>) -> Vec<u8> {
    let mut datagram = Vec::new();
    DatagramHeader {
        flags: 0,
        kind: DatagramKind::Input,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode_into(&mut datagram);
    datagram.extend_from_slice(&InputPacket { first_seq, events }.encode());
    let mut out = Vec::new();
    let _ = encode_stream_frame(STREAM_DATAGRAM, &datagram, &mut out);
    out
}

fn key_event(down: bool) -> Vec<u8> {
    key(down, "KeyA", "a")
}

fn key(down: bool, code: &str, key: &str) -> Vec<u8> {
    // Named keys (Escape) carry no text.
    let text = if down && key.chars().count() == 1 { key } else { "" };
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

/// The probe's hello: service `rb/1`, as the Mac client sends it.
pub fn hello_control() -> Control {
    hello_control_with(None)
}

/// [`hello_control`] carrying the host's per-launch secret as its token.
pub fn hello_control_with(token: Option<&str>) -> Control {
    Control::Hello {
        user: "probe".into(),
        install: "probe".into(),
        class: "viewer".into(),
        interactive: true,
        udp_port: None,
        max_datagram: 1332,
        token: token.map(|token| cmux_rd_proto::control::SecretHex(token.to_owned())),
        service: SERVICE_REMOTE_BROWSER.into(),
        caps: vec![INPUT_SERVICE.into()],
    }
}

/// True when the host's welcome in `controls` grants service input (the
/// Mac client sends no input otherwise).
pub fn input_granted(controls: &[serde_json::Value]) -> bool {
    controls.iter().any(|c| {
        c["t"] == "welcome"
            && c["caps"].as_array().is_some_and(|caps| caps.iter().any(|cap| cap == INPUT_SERVICE))
    })
}

fn hello(token: Option<&str>) -> Vec<u8> {
    let control = hello_control_with(token);
    let mut out = Vec::new();
    let json = serde_json::to_vec(&control).unwrap_or_default();
    let _ = encode_stream_frame(STREAM_CONTROL, &json, &mut out);
    out
}

/// Runs the probe against `addr` and writes its files into `out`. `token` is
/// the host's per-launch secret, sent as the hello's session token.
pub fn run(addr: SocketAddr, out: &Path, plan: Plan, token: Option<&str>) -> Report {
    let mut report = Report::default();
    if let Err(e) = probe(addr, out, plan, token, &mut report) {
        report.error = Some(e);
    }
    let _ = std::fs::write(out.join("result.json"), result_json(&report));
    report
}

fn probe(
    addr: SocketAddr,
    out: &Path,
    plan: Plan,
    token: Option<&str>,
    r: &mut Report,
) -> Result<(), String> {
    std::fs::create_dir_all(out).map_err(|e| e.to_string())?;
    let mut h264 = std::fs::File::create(out.join("stream.h264")).map_err(|e| e.to_string())?;
    let mut sock =
        TcpStream::connect_timeout(&addr, Duration::from_secs(10)).map_err(|e| e.to_string())?;
    sock.set_nodelay(true).map_err(|e| e.to_string())?;
    sock.write_all(&hello(token)).map_err(|e| e.to_string())?;
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
                    // A surface's frames follow its show on the same carrier.
                    let body = &v["body"];
                    let stream = body["stream"].as_u64().and_then(|s| u16::try_from(s).ok());
                    if let (true, Some(stream)) = (body["t"] == "rb.surface.show", stream) {
                        let _ = core.open_stream(stream);
                    }
                    r.controls.push(v);
                }
            } else {
                let _ = input.on_ack(&m.bytes);
            }
        }
        while let Some((stream, frame)) = core.pop_frame() {
            if stream != 0 {
                *r.popup_frames.entry(stream).or_default() += 1;
                // Each popup stream to its own file, for an offline decode.
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(out.join(format!("popup-{stream}.h264")))
                {
                    let _ = f.write_all(&frame.body.access_unit);
                }
                continue;
            }
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
                // The Mac client sends no input unless the welcome grants it.
                if !input_granted(&r.controls) {
                    return Err(format!("the welcome does not grant {INPUT_SERVICE}"));
                }
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
                    after_ui(&plan)
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
                    after_ui(&plan)
                }
                None if at >= until => return Err("no rb.dialog.show after key d".into()),
                None => Phase::Dialog { until },
            },
            Phase::PickerStart { index } => match PICKERS.get(index) {
                None => after_pickers(&plan),
                Some(&(name, (x, y), _)) => {
                    r.pickers.push(PickerResult { name: name.into(), ..PickerResult::default() });
                    for down in [true, false] {
                        let bytes = click(0, x, y, down);
                        input.push(InputEvent::Service { must_deliver: true, bytes });
                    }
                    let shows = rb_messages(&r.controls, "rb.surface.show").count();
                    Phase::PickerOpen { index, shows, until: at + Duration::from_secs(8) }
                }
            },
            Phase::PickerOpen { index, shows, until } => {
                let name = PICKERS[index].0;
                match rb_messages(&r.controls, "rb.surface.show").nth(shows).cloned() {
                    None if at >= until => {
                        return Err(format!("picker {name}: no rb.surface.show"));
                    }
                    None => Phase::PickerOpen { index, shows, until },
                    Some(show) => {
                        let stream = show["stream"].as_u64().and_then(|s| u16::try_from(s).ok());
                        let frames =
                            stream.and_then(|s| r.popup_frames.get(&s)).copied().unwrap_or(0);
                        let surface = show["surface"].as_u64().unwrap_or(0);
                        if let Some(p) = r.pickers.get_mut(index) {
                            p.surface = Some(surface);
                            p.stream = stream;
                            p.width = show["width"].as_u64();
                            p.height = show["height"].as_u64();
                            p.frames = frames;
                        }
                        if frames > 0 {
                            // Answer it: a click inside the surface (its DIP).
                            let (fx, fy) = PICKERS[index].2;
                            let w = show["anchor"]["width"].as_f64().unwrap_or(100.0);
                            let h = show["anchor"]["height"].as_f64().unwrap_or(100.0);
                            for down in [true, false] {
                                let bytes = click(surface, w * fx, h * fy, down);
                                input.push(InputEvent::Service { must_deliver: true, bytes });
                            }
                            let until = at + Duration::from_secs(5);
                            Phase::PickerAnswer { index, surface, until }
                        } else if at >= until {
                            return Err(format!("picker {name}: no frame on its stream"));
                        } else {
                            Phase::PickerOpen { index, shows, until }
                        }
                    }
                }
            }
            Phase::PickerAnswer { index, surface, until } => {
                let hidden = rb_messages(&r.controls, "rb.surface.hide")
                    .any(|b| b["surface"].as_u64() == Some(surface));
                if hidden || at >= until {
                    if let Some(p) = r.pickers.get_mut(index) {
                        p.answered = hidden;
                    }
                    if hidden {
                        Phase::PickerStart { index: index + 1 }
                    } else {
                        // Close it, so the next click opens the next picker.
                        for down in [true, false] {
                            let bytes = key(down, "Escape", "Escape");
                            input.push(InputEvent::Service { must_deliver: true, bytes });
                        }
                        let until = at + Duration::from_millis(700);
                        Phase::PickerPause { index: index + 1, until }
                    }
                } else {
                    Phase::PickerAnswer { index, surface, until }
                }
            }
            Phase::PickerPause { index, until } if at >= until => Phase::PickerStart { index },
            Phase::StuckStart => {
                let bytes = key(true, "KeyS", "s");
                let seq = input.push(InputEvent::Service { must_deliver: true, bytes });
                Phase::StuckHold { seq, at: at + Duration::from_millis(500) }
            }
            Phase::StuckHold { seq, at: due } if at >= due => {
                // The key-up (seq + 1) is "lost": the next packet starts after it.
                let bytes = pointer_move(5.0, 5.0);
                let events = vec![InputEvent::Service { must_deliver: true, bytes }];
                sock.write_all(&raw_input(seq.wrapping_add(2), events))
                    .map_err(|e| e.to_string())?;
                Phase::StuckWait { until: at + Duration::from_secs(2), frames: r.frames }
            }
            Phase::StuckWait { until, frames } if at >= until => {
                r.frames_after_gap = Some(r.frames - frames);
                Phase::Done
            }
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
        "pickers": r.pickers,
        "popup_frames": r.popup_frames,
        "frames_after_gap": r.frames_after_gap,
        "error": r.error,
    })
    .to_string()
        + "\n"
}
