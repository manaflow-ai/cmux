//! The stream transport's rules (was the pure parts of
//! `RemoteRdStreamTransport*.swift`, `RemoteRdStreamSplitter.swift` and
//! `RemoteRdSurfaceStreams.swift`): what goes out when the carrier opens or
//! the viewer stops, what one host control message asks the transport to do,
//! which close reason a session keeps, the status the pane sees, and the
//! frame boundaries and popup surface streams of the received bytes. The
//! Swift shell keeps the carrier, the queue, the Rust core and the async
//! streams; it asks these rules what to do.

use std::collections::BTreeMap;

use cmux_rd_proto::control::Control;
use cmux_rd_proto::{STREAM_CONTROL, STREAM_PREFIX_LEN};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::control::{
    self, CLIPBOARD_TEXT_CAP, CLOCK_CAP, DEFAULT_MAX_DATAGRAM, Hello, INPUT_SERVICE_CAP, Incoming,
};
use super::cursor::{self, CursorImage};
use super::handshake::Handshake;
use super::pane::{Path, UpstreamStatus, ViewStatus};

/// One session's queue-confined bookkeeping (`RemoteRdStreamTransport.Engine`
/// less the Rust core and the carrier).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transport {
    /// The hello this transport sends (already [`Hello::for_stream`]).
    pub hello: Hello,
    pub start_key: String,
    /// Start mode `control` (else `view`).
    #[serde(default)]
    pub control: bool,
    /// Whether this viewer offered `clipboard.text` (the caller's decision).
    #[serde(default)]
    pub offers_clipboard: bool,
    pub handshake: Handshake,
    /// The carrier started (`connect`).
    #[serde(default)]
    pub started: bool,
    /// The upstream consent exists (created at the welcome).
    #[serde(default)]
    pub upstream: bool,
    /// Clipboard sync exists (created at the welcome when both sides list the cap).
    #[serde(default)]
    pub clipboard: bool,
    /// Why the path closed; none until it did.
    #[serde(default)]
    pub end_reason: Option<String>,
    /// The carrier's latest progress text while the path opens.
    #[serde(default)]
    pub connecting_reason: Option<String>,
}

/// What the host's answer to an upstream `stream_open` asks of the consent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum UpstreamAnswer {
    /// `consent.opened`: its sender uses the welcome's `max_datagram`.
    #[serde(rename_all = "camelCase")]
    Opened {
        stream: u16,
        max_datagram: u32,
    },
    Refused {
        stream: u16,
    },
    ClosedByHost {
        stream: u16,
    },
}

/// What one received control message asks of the transport, in the order the
/// Swift transport does it: the service body, stats and cursor shape go to
/// their streams, the clock starts, the handshake moves (already applied to
/// the returned state), then the consent and clipboard are created and the
/// upstream answer applied.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlActions {
    /// False when the message did not parse: nothing else happens.
    pub parsed: bool,
    /// The session service's body, for the service stream.
    pub service: Option<Value>,
    /// The popup surface change the body asks for (applied before the body is yielded).
    pub surface: Option<SurfaceChange>,
    /// The host's stats, for the stats stream and the log.
    pub host_stats: Option<Value>,
    /// A cursor shape whose pixels match its size.
    pub cursor_shape: Option<CursorImage>,
    /// `core.enableClock()`: the welcome lists `clock`.
    pub enable_clock: bool,
    /// Create the upstream consent with these welcome caps.
    pub create_upstream: Option<Vec<String>>,
    /// Create clipboard sync.
    pub create_clipboard: bool,
    pub upstream: Option<UpstreamAnswer>,
    /// The session ended with this message: finish every stream.
    pub ended: bool,
}

impl Transport {
    /// `RemoteRdStreamTransport.init`: the hello goes out with no UDP port and
    /// with `clipboard.text` when `clipboard`; the handshake waits for the
    /// hello's service (the caller's, before the clipboard cap).
    pub fn new(hello: Hello, start_key: &str, control: bool, clipboard: bool) -> Self {
        let handshake = Handshake::new(&hello.service);
        Self {
            hello: hello.for_stream(clipboard),
            start_key: start_key.to_owned(),
            control,
            offers_clipboard: clipboard,
            handshake,
            started: false,
            upstream: false,
            clipboard: false,
            end_reason: None,
            connecting_reason: None,
        }
    }

    /// `connect()`: true when the carrier should start now (once, and never after the end).
    pub fn connect(&mut self) -> bool {
        if self.started || self.handshake.is_ended() {
            return false;
        }
        self.started = true;
        true
    }

    /// The carrier is ready: hello and start go out.
    pub fn ready(&mut self) -> Vec<Value> {
        self.connecting_reason = None;
        vec![
            control::encode(&self.hello.control()),
            control::encode(&control::start(&self.start_key, self.control)),
        ]
    }

    /// The carrier's progress text while the path opens (ignored after the end).
    pub fn progress(&mut self, text: &str) {
        if self.handshake.is_ended() {
            return;
        }
        self.connecting_reason = Some(text.to_owned());
    }

    /// Received bytes are pushed only while the session lives.
    pub fn accepts_data(&self) -> bool {
        !self.handshake.is_ended()
    }

    /// The carrier closed or the core rejected bytes. Only the close that ends
    /// a live session records its reason: a later one, or one after the host
    /// ended the session, says nothing new.
    pub fn closed(&mut self, reason: &str) {
        if !self.handshake.is_ended() {
            self.end_reason = Some(reason.to_owned());
        }
        self.handshake.connection_closed();
    }

    /// The reason the core's refusal of received bytes ends the session with.
    pub fn rejected_reason(error: &str) -> String {
        format!("rd stream bytes rejected: {error}")
    }

    /// `stop()`: nothing after the end; else every upstream is revoked first
    /// (nothing goes out after the user's stop), then stop goes out.
    pub fn stop(&mut self) -> Option<Value> {
        if self.handshake.is_ended() {
            return None;
        }
        self.handshake.viewer_stopped();
        Some(control::encode(&Control::Stop))
    }

    /// One `service` message of the session's service, or none after the end.
    pub fn service_message(&self, body: Value) -> Option<Value> {
        if self.handshake.is_ended() {
            return None;
        }
        Some(control::encode(&Control::Service { service: self.hello.service.clone(), body }))
    }

    /// `sendServiceInput` is allowed: live, and the welcome lists `input.service`.
    pub fn allows_service_input(&self) -> bool {
        !self.handshake.is_ended()
            && self.handshake.welcome.as_ref().is_some_and(|w| w.has_cap(INPUT_SERVICE_CAP))
    }

    /// `requestUpstream` is allowed: streaming with a consent.
    pub fn allows_upstream_request(&self) -> bool {
        self.handshake.is_streaming() && self.upstream
    }

    /// One control message the core handed out.
    pub fn receive_control(&mut self, json: &[u8]) -> ControlActions {
        let Ok(incoming) = control::parse(json) else {
            return ControlActions::default();
        };
        self.receive(incoming)
    }

    pub fn receive(&mut self, incoming: Incoming) -> ControlActions {
        let mut out = ControlActions { parsed: true, ..ControlActions::default() };
        match &incoming {
            Incoming::Control { control: Control::Service { service, body } }
                if *service == self.hello.service && !self.handshake.is_ended() =>
            {
                out.surface = SurfaceChange::parse(body);
                out.service = Some(body.clone());
            }
            Incoming::Control { control: stats @ Control::Stats { .. } } => {
                out.host_stats = Some(control::encode(stats));
            }
            Incoming::Control {
                control: Control::CursorShape { shape, width, height, hot_x, hot_y, rgba },
            } => {
                out.cursor_shape = cursor::image(*shape, *width, *height, *hot_x, *hot_y, rgba);
            }
            // Clock probes only when the host lists `clock` (an older host refuses them).
            Incoming::Welcome { welcome } if welcome.has_cap(CLOCK_CAP) => out.enable_clock = true,
            _ => {}
        }
        let was_ended = self.handshake.is_ended();
        self.handshake.receive(&incoming);
        out.ended = !was_ended && self.handshake.is_ended();
        let welcome = self.handshake.welcome.clone();
        if !self.upstream
            && let Some(welcome) = &welcome
        {
            self.upstream = true;
            out.create_upstream = Some(welcome.caps.clone().unwrap_or_default());
        }
        if !self.clipboard
            && self.offers_clipboard
            && welcome.as_ref().is_some_and(|w| w.has_cap(CLIPBOARD_TEXT_CAP))
        {
            self.clipboard = true;
            out.create_clipboard = true;
        }
        if self.upstream
            && let Incoming::Control { control } = &incoming
        {
            out.upstream = match control {
                Control::StreamOpened { stream } => {
                    let max = welcome.as_ref().map_or(DEFAULT_MAX_DATAGRAM, |w| w.max_datagram);
                    Some(UpstreamAnswer::Opened {
                        stream: *stream,
                        max_datagram: u32::try_from(max).unwrap_or(u32::MAX),
                    })
                }
                Control::StreamRefused { stream, .. } => {
                    Some(UpstreamAnswer::Refused { stream: *stream })
                }
                Control::StreamClose { stream } => {
                    Some(UpstreamAnswer::ClosedByHost { stream: *stream })
                }
                _ => None,
            };
        }
        out
    }

    /// The session ended: the consent and clipboard are freed with it.
    pub fn finish(&mut self) {
        self.upstream = false;
        self.clipboard = false;
    }

    /// The status the pane sees (`publishStatus`). `upstream` is the consent's
    /// state when one exists; it shows only while streaming.
    pub fn status(&self, upstream: Option<UpstreamStatus>) -> ViewStatus {
        let upstream = match upstream {
            Some(status) if self.upstream && self.handshake.is_streaming() => status,
            _ => UpstreamStatus::default(),
        };
        let welcome = self.handshake.welcome.as_ref();
        ViewStatus {
            path: Path::Direct,
            rtt_ms: None,
            loss_percent: 0.0,
            state: self.handshake.session_state(),
            upstream,
            end_reason: if self.handshake.is_ended() { self.end_reason.clone() } else { None },
            connecting_reason: self.connecting_reason.clone(),
            stream_width: welcome.map(|w| i64::from(w.width)),
            stream_height: welcome.map(|w| i64::from(w.height)),
        }
    }
}

/// One piece of received bytes (`RemoteRdStreamSplitter.Segment`): bytes up
/// to `end` (exclusive, an offset into the chunk given to [`StreamSplitter::split`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Segment {
    pub end: usize,
    /// The piece ends with the last byte of a control frame.
    pub ends_control_frame: bool,
}

/// Cuts received stream-carrier bytes (`u8 type, u32 len` little-endian,
/// payload) right after every control frame, so the transport acts on a
/// control message before it pushes the bytes behind it: rb/1
/// `rb.surface.show {stream}` opens its stream in the core before that
/// stream's first datagrams arrive. Only tracks frame boundaries; the core
/// validates the frames.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StreamSplitter {
    pub header: Vec<u8>,
    pub remaining: u32,
    pub kind: u8,
    pub in_payload: bool,
}

impl StreamSplitter {
    pub fn split(&mut self, data: &[u8]) -> Vec<Segment> {
        let mut segments = Vec::new();
        let mut index = 0;
        while index < data.len() {
            if self.in_payload {
                let take = (self.remaining as usize).min(data.len() - index);
                index += take;
                self.remaining -= take as u32;
            } else {
                self.header.push(data[index]);
                index += 1;
                if self.header.len() < STREAM_PREFIX_LEN {
                    continue;
                }
                self.kind = self.header[0];
                self.remaining = u32::from_le_bytes([
                    self.header[1],
                    self.header[2],
                    self.header[3],
                    self.header[4],
                ]);
                self.header.clear();
                self.in_payload = true;
            }
            if self.in_payload && self.remaining == 0 {
                self.in_payload = false;
                if self.kind == STREAM_CONTROL {
                    segments.push(Segment { end: index, ends_control_frame: true });
                }
            }
        }
        let start = segments.last().map_or(0, |s| s.end);
        if start < data.len() {
            segments.push(Segment { end: data.len(), ends_control_frame: false });
        }
        segments
    }
}

/// What an rb/1 service body does to the session's display streams
/// (`RemoteRdSurfaceStreamChange`; remote-tab-protocol.md section 2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SurfaceChange {
    /// `rb.surface.show {surface, stream}`.
    Show { surface: u32, stream: u16 },
    /// `rb.surface.hide {surface}`.
    Hide { surface: u32 },
}

/// A non-negative integer (`RemoteRdJSON.unsigned`): numbers may arrive as doubles.
fn unsigned(value: &Value) -> Option<u64> {
    let Value::Number(n) = value else { return None };
    if let Some(v) = n.as_u64() {
        return Some(v);
    }
    if n.is_i64() {
        return None;
    }
    let v = n.as_f64()?;
    // `UInt64(exactly:)`: whole, in range (2^64 itself is out).
    (v >= 0.0 && v.fract() == 0.0 && v < 18_446_744_073_709_551_616.0).then_some(v as u64)
}

impl SurfaceChange {
    pub fn parse(body: &Value) -> Option<Self> {
        let fields = body.as_object()?;
        let t = fields.get("t")?.as_str()?;
        let surface = u32::try_from(unsigned(fields.get("surface")?)?).ok()?;
        match t {
            "rb.surface.show" => {
                // Stream 0 is the page; a surface never streams there.
                let stream = u16::try_from(unsigned(fields.get("stream")?)?).ok()?;
                (stream != 0).then_some(Self::Show { surface, stream })
            }
            "rb.surface.hide" => Some(Self::Hide { surface }),
            _ => None,
        }
    }
}

/// The popup streams the transport has open, stream to surface
/// (`RemoteRdSurfaceStreams`; the Swift shell keeps each stream's units).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SurfaceStreams {
    /// As `[{stream, surface}]` in JSON (a request's buffered fields lose integer map keys).
    #[serde(with = "open_streams")]
    pub open: BTreeMap<u16, u32>,
}

mod open_streams {
    use std::collections::BTreeMap;

    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    #[derive(Serialize, Deserialize)]
    struct Open {
        stream: u16,
        surface: u32,
    }

    pub fn serialize<S: Serializer>(open: &BTreeMap<u16, u32>, s: S) -> Result<S::Ok, S::Error> {
        let list: Vec<Open> =
            open.iter().map(|(&stream, &surface)| Open { stream, surface }).collect();
        list.serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<BTreeMap<u16, u32>, D::Error> {
        Ok(Vec::<Open>::deserialize(d)?.into_iter().map(|o| (o.stream, o.surface)).collect())
    }
}

/// What a surface change asks of the core (`applySurfaceStreams`): close
/// `close` (already ended here), then open `open` and, when the core opened
/// it, [`SurfaceStreams::start`] it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SurfacePlan {
    pub close: Vec<u16>,
    pub open: Option<u16>,
}

impl SurfaceStreams {
    /// The stream that carries `surface`, if open.
    pub fn stream_of(&self, surface: u32) -> Option<u16> {
        self.open.iter().find(|(_, s)| **s == surface).map(|(stream, _)| *stream)
    }

    /// Starts `stream` for `surface` (an earlier surface on it ends).
    pub fn start(&mut self, stream: u16, surface: u32) {
        self.open.insert(stream, surface);
    }

    pub fn end(&mut self, stream: u16) {
        self.open.remove(&stream);
    }

    pub fn end_all(&mut self) -> Vec<u16> {
        std::mem::take(&mut self.open).into_keys().collect()
    }

    pub fn apply(&mut self, change: SurfaceChange) -> SurfacePlan {
        let mut plan = SurfacePlan::default();
        match change {
            SurfaceChange::Show { surface, stream } => {
                // A resized surface comes back on a new stream; the old one ends.
                if let Some(old) = self.stream_of(surface)
                    && old != stream
                {
                    self.end(old);
                    plan.close.push(old);
                }
                plan.open = Some(stream);
            }
            SurfaceChange::Hide { surface } => {
                if let Some(stream) = self.stream_of(surface) {
                    self.end(stream);
                    plan.close.push(stream);
                }
            }
        }
        plan
    }
}
