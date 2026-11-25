//! The data channel's messages: the viewer's input and control (`ScreenInput`, viewer to host)
//! and the host's messages (`ScreenHostMessage`), as JSON objects with short keys. An older peer
//! ignores a key or a message type it does not know, so every field but `t` is optional.

use serde::de::{self, Deserializer, Visitor};
use serde::{Deserialize, Serialize};
use std::fmt;

/// `u` for a scroll in pixels (absent: lines, which every host takes).
pub const PIXEL_UNIT: &str = "px";

/// `t` of the message a host sends once its input channel opens, and of a viewer's own.
pub const CAPABILITIES_TYPE: &str = "caps";
/// The host posts `scroll` with `u: "px"` as pixel (continuous) scrolling.
pub const PIXEL_SCROLL_CAPABILITY: &str = "scroll-px";
/// Pointer events carry the modifier keys held down.
pub const MODIFIED_POINTER_CAPABILITY: &str = "mods";
/// `t` of the host's pointer positions (`person`, `agent`).
pub const TELEPOINTERS_TYPE: &str = "telepointers";
/// A viewer that draws pointers itself says it in its `caps`: the host leaves the cursor out.
pub const TELEPOINTERS_CAPABILITY: &str = "telepointers";
/// `t` of the host's cursor image, once per shape.
pub const CURSOR_SHAPE_TYPE: &str = "cursor";
/// A viewer that draws the Mac's own cursor image says it, with `telepointers`.
pub const CURSOR_SHAPE_CAPABILITY: &str = "cursor-shape";
/// `t` of the host's source state (in `s`), sent when it changes.
pub const SOURCE_TYPE: &str = "source";
/// In the host's `caps`: it takes `paste-image` messages.
pub const PASTE_IMAGE_CAPABILITY: &str = "paste-image";
/// `t` of the viewer's image chunks and of the host's answer.
pub const PASTE_IMAGE_TYPE: &str = "paste-image";
/// `t` of the host's displays message.
pub const DISPLAYS_TYPE: &str = "displays";
/// `t` of the viewer's report of how large it shows the stream (`i` long edge, `d` pinch).
pub const VIEW_DEMAND_MESSAGE: &str = "view";
/// `t` of the viewer's display rate report (`i` frames per second).
pub const FRAME_RATE_MESSAGE: &str = "fps";
/// `t` of the viewer's goodbye: the session ends.
pub const BYE_MESSAGE: &str = "bye";
/// What a view-only viewer may still send: a request for a fresh frame.
pub const VIEW_ONLY_MESSAGES: &[&str] = &["refresh"];

/// Viewer to host input and control on the `input` data channel. Pointer coordinates are
/// normalized (0...1) within the display being streamed.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ScreenInput {
    /// move, scroll, key, chord, text, display, refresh, quality, fps, view, caps, paste-image, bye
    pub t: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    /// RFB button mask (1 left, 2 middle, 4 right).
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "exact_u8")]
    pub b: Option<u8>,
    /// A fractional delta (a pixel scroll) rounds to the nearest whole value.
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "delta")]
    pub dx: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "delta")]
    pub dy: Option<i64>,
    /// X11 keysym.
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "exact_u32")]
    pub k: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub d: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub s: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "exact_i64")]
    pub i: Option<i64>,
    /// Modifier keysyms for `chord`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub m: Option<Vec<u32>>,
    /// The unit of a `scroll`'s `dx`/`dy`: absent for lines, `px` for pixels.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub u: Option<String>,
    /// For `paste-image`: the chunk count (`i` is the chunk's index).
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "exact_i64")]
    pub n: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// For `paste-image`: the image's uniform type identifier.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub f: Option<String>,
}

impl ScreenInput {
    pub fn new(t: impl Into<String>) -> Self {
        Self { t: t.into(), ..Self::default() }
    }

    /// Decodes one message; `None` for anything that is not one (the host drops it).
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        serde_json::from_slice(bytes).ok()
    }

    pub fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    /// A scroll message: wheel lines, or pixels (`u: "px"`).
    pub fn scroll(x: f64, y: f64, dx: i64, dy: i64, pixels: bool) -> Self {
        Self {
            x: Some(x),
            y: Some(y),
            dx: Some(dx),
            dy: Some(dy),
            u: pixels.then(|| PIXEL_UNIT.to_owned()),
            ..Self::new("scroll")
        }
    }

    /// The viewer's display rate report.
    pub fn frame_rate(fps: i64) -> Self {
        Self { i: Some(fps), ..Self::new(FRAME_RATE_MESSAGE) }
    }

    /// The viewer's report of how large it shows the stream.
    pub fn view_demand(long_edge: i64, pinch: bool) -> Self {
        Self { d: Some(pinch), i: Some(long_edge), ..Self::new(VIEW_DEMAND_MESSAGE) }
    }

    /// The viewer's display rate from its `fps` report; `None` for any other message or a rate
    /// no display has.
    pub fn reported_frame_rate(&self) -> Option<i64> {
        if self.t != FRAME_RATE_MESSAGE {
            return None;
        }
        self.i.filter(|fps| (1..=1000).contains(fps))
    }

    /// The capabilities a viewer's `caps` message lists (empty for any other message).
    pub fn viewer_capabilities(&self) -> Vec<String> {
        if self.t != CAPABILITIES_TYPE {
            return Vec::new();
        }
        split_list(self.s.as_deref().unwrap_or(""), false)
    }

    /// Whether a viewer's `caps` message says it draws pointers itself.
    pub fn viewer_draws_pointers(&self) -> bool {
        self.viewer_capabilities().iter().any(|c| c == TELEPOINTERS_CAPABILITY)
    }

    /// Whether a viewer's `caps` message says it draws the Mac's cursor image.
    pub fn viewer_draws_cursor_shapes(&self) -> bool {
        let caps = self.viewer_capabilities();
        caps.iter().any(|c| c == TELEPOINTERS_CAPABILITY)
            && caps.iter().any(|c| c == CURSOR_SHAPE_CAPABILITY)
    }

    /// Whether this message ends its session (the viewer left).
    pub fn ends_session(&self) -> bool {
        self.t == BYE_MESSAGE
    }
}

/// What the host does with one viewer message it does not handle itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Delivery {
    /// Dropped (view-only, or a scroll in a unit the backend did not advertise).
    Drop = 0,
    /// Select the display `i`.
    SelectDisplay = 1,
    /// Hand to the backend.
    Handle = 2,
}

/// The display choice always reaches the backend; input only when the session is not view-only,
/// and a scroll only in a unit the backend advertised (40 px is not 40 lines).
pub fn delivery(input: &ScreenInput, view_only: bool, backend_capabilities: &[String]) -> Delivery {
    if input.t == "display" {
        return if input.i.is_some() { Delivery::SelectDisplay } else { Delivery::Drop };
    }
    if view_only && !VIEW_ONLY_MESSAGES.contains(&input.t.as_str()) {
        return Delivery::Drop;
    }
    if input.t == "scroll"
        && let Some(unit) = &input.u
        && (unit != PIXEL_UNIT
            || !backend_capabilities.iter().any(|c| c == PIXEL_SCROLL_CAPABILITY))
    {
        return Delivery::Drop;
    }
    Delivery::Handle
}

/// A display the host can stream, in pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Display {
    pub w: i64,
    pub h: i64,
}

/// A pointer position as a fraction of the streamed display (0-1, top left origin).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Pointer {
    pub x: f64,
    pub y: f64,
}

/// Host to viewer: the displays and which one streams, its capabilities, telepointers, cursor
/// shapes, its source state and image paste answers.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ScreenHostMessage {
    pub t: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub displays: Option<Vec<Display>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// The frames per second the stream is set to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps: Option<i64>,
    /// `caps`: a comma list; `source`: the state; `paste-image`: the outcome.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub s: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub person: Option<Pointer>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<Pointer>,
    /// For `telepointers`: the id of the person's cursor shape.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<String>,
    /// For `cursor`: the Mac's cursor image (id, png, w, h, hx, hy, pw, ph), kept as it came.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<serde_json::Value>,
    /// For `paste-image`: the image the answer is about.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

impl ScreenHostMessage {
    pub fn new(t: impl Into<String>) -> Self {
        Self { t: t.into(), ..Self::default() }
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        serde_json::from_slice(bytes).ok()
    }

    pub fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    /// The host's source state message.
    pub fn source(state: SourceState) -> Self {
        Self { s: Some(state.as_str().to_owned()), ..Self::new(SOURCE_TYPE) }
    }

    /// The source state this message carries; `None` for any other message.
    pub fn source_state(&self) -> Option<SourceState> {
        if self.t != SOURCE_TYPE {
            return None;
        }
        self.s.as_deref().and_then(SourceState::parse)
    }

    /// The host's answer for `outcome` about the image `id`.
    pub fn paste_image(outcome: PasteImageOutcome, id: Option<String>) -> Self {
        Self { s: Some(outcome.as_str().to_owned()), id, ..Self::new(PASTE_IMAGE_TYPE) }
    }

    /// The paste outcome this message carries; `None` for any other message.
    pub fn paste_image_outcome(&self) -> Option<PasteImageOutcome> {
        if self.t != PASTE_IMAGE_TYPE {
            return None;
        }
        self.s.as_deref().and_then(PasteImageOutcome::parse)
    }

    /// The `caps` message for a backend's input capabilities: none for a view-only session or a
    /// backend with none.
    pub fn capabilities(capabilities: &[String], view_only: bool) -> Option<Self> {
        if view_only || capabilities.is_empty() {
            return None;
        }
        Some(Self { s: Some(capabilities.join(",")), ..Self::new(CAPABILITIES_TYPE) })
    }

    /// The host's input capabilities from its `caps` message; `None` for any other message.
    pub fn host_capabilities(&self) -> Option<Vec<String>> {
        if self.t != CAPABILITIES_TYPE {
            return None;
        }
        Some(split_list(self.s.as_deref().unwrap_or(""), true))
    }

    /// Whether this is the displays message.
    pub fn is_displays(&self) -> bool {
        self.t == DISPLAYS_TYPE
    }

    /// The cursor shape message for one image (its JSON object).
    pub fn cursor_shape(cursor: serde_json::Value) -> Self {
        Self { cursor: Some(cursor), ..Self::new(CURSOR_SHAPE_TYPE) }
    }

    /// The telepointers message.
    pub fn telepointers(
        person: Option<Pointer>,
        agent: Option<Pointer>,
        shape: Option<String>,
    ) -> Self {
        Self { person, agent, shape, ..Self::new(TELEPOINTERS_TYPE) }
    }
}

/// What the Mac's screen shows the capture: the picture, or nothing because the session is
/// locked or the display asleep.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum SourceState {
    Live = 0,
    Locked = 1,
    /// The display sleeps (the session may be unlocked).
    Asleep = 2,
}

impl SourceState {
    /// Locked wins over asleep: a locked Mac whose display slept needs unlocking either way.
    pub fn from_flags(locked: bool, asleep: bool) -> Self {
        if locked {
            Self::Locked
        } else if asleep {
            Self::Asleep
        } else {
            Self::Live
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Live => "live",
            Self::Locked => "locked",
            Self::Asleep => "asleep",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "live" => Some(Self::Live),
            "locked" => Some(Self::Locked),
            "asleep" => Some(Self::Asleep),
            _ => None,
        }
    }

    pub fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Live),
            1 => Some(Self::Locked),
            2 => Some(Self::Asleep),
            _ => None,
        }
    }
}

/// The host's answer to a pasted image.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum PasteImageOutcome {
    /// On the Mac's pasteboard, and Command-V pressed.
    Pasted = 0,
    /// Too large, or an unknown type.
    Refused = 1,
    /// A chunk went missing (out of order, or another image started).
    Incomplete = 2,
}

impl PasteImageOutcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pasted => "pasted",
            Self::Refused => "refused",
            Self::Incomplete => "incomplete",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "pasted" => Some(Self::Pasted),
            "refused" => Some(Self::Refused),
            "incomplete" => Some(Self::Incomplete),
            _ => None,
        }
    }
}

/// Foundation's `.whitespaces`: Unicode spaces and tabs, not line breaks.
fn is_horizontal_space(c: char) -> bool {
    c.is_whitespace()
        && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// A comma list, each item trimmed of spaces and tabs (and empty items dropped when asked).
fn split_list(s: &str, drop_empty: bool) -> Vec<String> {
    if s.is_empty() {
        // Swift's `split` drops empty subsequences: "" splits into nothing.
        return Vec::new();
    }
    s.split(',')
        .filter(|part| !part.is_empty())
        .map(|part| part.trim_matches(is_horizontal_space).to_owned())
        .filter(|part| !drop_empty || !part.is_empty())
        .collect()
}

/// A JSON number that is a whole value (an integer, or a float with no fraction) in range.
fn whole(value: f64, min: f64, max: f64) -> Option<f64> {
    (value.is_finite() && value.fract() == 0.0 && value >= min && value <= max).then_some(value)
}

struct NumberVisitor<F: Fn(Number) -> Result<i64, String>>(F);

enum Number {
    Int(i128),
    Float(f64),
}

impl<F: Fn(Number) -> Result<i64, String>> Visitor<'_> for NumberVisitor<F> {
    type Value = Option<i64>;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a number")
    }
    fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_none<E: de::Error>(self) -> Result<Self::Value, E> {
        Ok(None)
    }
    fn visit_i64<E: de::Error>(self, v: i64) -> Result<Self::Value, E> {
        (self.0)(Number::Int(i128::from(v))).map(Some).map_err(E::custom)
    }
    fn visit_u64<E: de::Error>(self, v: u64) -> Result<Self::Value, E> {
        (self.0)(Number::Int(i128::from(v))).map(Some).map_err(E::custom)
    }
    fn visit_f64<E: de::Error>(self, v: f64) -> Result<Self::Value, E> {
        (self.0)(Number::Float(v)).map(Some).map_err(E::custom)
    }
}

fn number<'de, D: Deserializer<'de>>(
    d: D,
    convert: impl Fn(Number) -> Result<i64, String>,
) -> Result<Option<i64>, D::Error> {
    d.deserialize_any(NumberVisitor(convert))
}

fn ranged(n: Number, min: i64, max: i64) -> Result<i64, String> {
    let value = match n {
        Number::Int(v) => v,
        Number::Float(v) => {
            whole(v, min as f64, max as f64).ok_or("not a whole number in range")? as i128
        }
    };
    if value < i128::from(min) || value > i128::from(max) {
        return Err("out of range".into());
    }
    Ok(value as i64)
}

fn exact_i64<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    number(d, |n| ranged(n, i64::MIN, i64::MAX))
}

fn exact_u32<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u32>, D::Error> {
    number(d, |n| ranged(n, 0, i64::from(u32::MAX))).map(|v| v.map(|v| v as u32))
}

fn exact_u8<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u8>, D::Error> {
    number(d, |n| ranged(n, 0, i64::from(u8::MAX))).map(|v| v.map(|v| v as u8))
}

const MAX_DELTA: i128 = 1_000_000_000_000_000;

/// A scroll delta: a whole value that fits as is; a fraction (or a whole value too large) rounds to the nearest whole value (half away
/// from zero), clamped to +-1e15.
fn delta<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    number(d, |n| match n {
        Number::Int(v) => Ok(i64::try_from(v).unwrap_or(v.clamp(-MAX_DELTA, MAX_DELTA) as i64)),
        Number::Float(v) if v.is_finite() => Ok(v.round().clamp(-1e15, 1e15) as i64),
        Number::Float(_) => Err("not a finite delta".into()),
    })
}
