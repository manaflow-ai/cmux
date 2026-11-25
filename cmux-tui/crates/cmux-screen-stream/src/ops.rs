//! The stateless rules as JSON ops (the app's one entry for them, `cmux_screen_stream_call`).
//! Each op takes a JSON object and answers one; keys are camelCase.

use crate::demand;
use crate::paste;
use crate::quality::{self, Quality, Rect};
use crate::session;
use crate::wire::{self, ScreenHostMessage, ScreenInput, SourceState};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    Unknown,
    Invalid,
}

fn parse<T: DeserializeOwned>(request: &Value) -> Result<T, OpError> {
    serde_json::from_value(request.clone()).map_err(|_| OpError::Invalid)
}

fn quality_of(name: &str) -> Result<Quality, OpError> {
    Quality::parse(name).ok_or(OpError::Invalid)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TextRequest {
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputRequest {
    text: String,
    #[serde(default)]
    view_only: bool,
    #[serde(default)]
    backend_capabilities: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SettingsRequest {
    quality: String,
    #[serde(default)]
    source_width: i64,
    #[serde(default)]
    source_height: i64,
    #[serde(default = "baseline")]
    frame_rate: i64,
}

fn baseline() -> i64 {
    quality::BASELINE_FRAME_RATE
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FrameRateRequest {
    quality: String,
    host_maximum: Option<i64>,
    viewer_maximum: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CaptureCapRequest {
    quality: String,
    demand: Option<i64>,
    scales: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CapabilitiesRequest {
    capabilities: Vec<String>,
    #[serde(default)]
    view_only: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PasteRequest {
    data: String,
    #[serde(rename = "type")]
    image_type: String,
    id: String,
}

#[derive(Deserialize)]
struct FractionRequest {
    x: Option<f64>,
    y: Option<f64>,
    display: Option<Rect>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FitRequest {
    width: f64,
    height: f64,
    cap: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScrollRequest {
    x: f64,
    y: f64,
    dx: i64,
    dy: i64,
    #[serde(default)]
    pixels: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SourceRequest {
    #[serde(default)]
    locked: bool,
    #[serde(default)]
    asleep: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ViewRequest {
    long_edge: i64,
    #[serde(default)]
    pinch: bool,
}

fn source_name(state: Option<SourceState>) -> Value {
    state.map_or(Value::Null, |s| Value::from(s.as_str()))
}

/// Runs one op.
///
/// - `input_read` `{text, viewOnly, backendCapabilities}`: the host's reading of one viewer
///   message: `{input}` (null when it is not one), `delivery` (`drop`, `selectDisplay`,
///   `handle`), `endsSession`, `reportedFrameRate`, `drawsPointers`, `drawsCursorShapes`.
/// - `host_read` `{text}`: the viewer's reading of one host message: `{message}` (null when
///   not one), `isDisplays`, `sourceState`, `pasteImageOutcome`, `capabilities`.
/// - `settings` `{quality, sourceWidth, sourceHeight, frameRate}`: the encoder settings.
/// - `frame_rate` `{quality, hostMaximum, viewerMaximum}`: `{frameRate}`.
/// - `capture_cap` `{quality, demand, scales}`: `{cap}`.
/// - `capabilities_message` `{capabilities, viewOnly}`: `{text}` (null: send none).
/// - `paste_chunks` `{data (base64), type, id}`: `{texts}`.
/// - `fraction` `{x, y, display}`: `{pointer}` (null off the display).
/// - `fit` `{width, height, cap}`: `{width, height}`.
/// - `rung` `{longEdge, displayLongEdge}`: `{rung}`.
/// - `scroll_input` `{x, y, dx, dy, pixels}`, `view_input` `{longEdge, pinch}`,
///   `frame_rate_input` `{fps}`: `{text}`.
/// - `source_message` `{locked, asleep}`: `{state, text}`.
/// - `qualities` `{}`: `{qualities: [{id, title}]}`.
/// - `encoding_name` `{raw}`: `{name}`.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    Ok(match op {
        "input_read" => {
            let r: InputRequest = parse(request)?;
            match ScreenInput::decode(r.text.as_bytes()) {
                None => json!({ "input": null }),
                Some(input) => {
                    let delivery =
                        match wire::delivery(&input, r.view_only, &r.backend_capabilities) {
                            wire::Delivery::Drop => "drop",
                            wire::Delivery::SelectDisplay => "selectDisplay",
                            wire::Delivery::Handle => "handle",
                        };
                    json!({
                        "delivery": delivery,
                        "endsSession": input.ends_session(),
                        "reportedFrameRate": input.reported_frame_rate(),
                        "drawsPointers": input.viewer_draws_pointers(),
                        "drawsCursorShapes": input.viewer_draws_cursor_shapes(),
                        "input": input,
                    })
                }
            }
        }
        "host_read" => {
            let r: TextRequest = parse(request)?;
            match ScreenHostMessage::decode(r.text.as_bytes()) {
                None => json!({ "message": null }),
                Some(message) => json!({
                    "isDisplays": message.is_displays(),
                    "sourceState": source_name(message.source_state()),
                    "pasteImageOutcome": message.paste_image_outcome().map(|o| o.as_str()),
                    "capabilities": message.host_capabilities(),
                    "message": message,
                }),
            }
        }
        "settings" => {
            let r: SettingsRequest = parse(request)?;
            let settings =
                quality_of(&r.quality)?.settings(r.source_width, r.source_height, r.frame_rate);
            serde_json::to_value(settings).map_err(|_| OpError::Invalid)?
        }
        "frame_rate" => {
            let r: FrameRateRequest = parse(request)?;
            json!({ "frameRate": quality_of(&r.quality)?.frame_rate(r.host_maximum, r.viewer_maximum) })
        }
        "capture_cap" => {
            let r: CaptureCapRequest = parse(request)?;
            json!({ "cap": quality_of(&r.quality)?.capture_cap(r.demand, r.scales) })
        }
        "capabilities_message" => {
            let r: CapabilitiesRequest = parse(request)?;
            json!({ "text": ScreenHostMessage::capabilities(&r.capabilities, r.view_only).map(|m| m.encode()) })
        }
        "paste_chunks" => {
            let r: PasteRequest = parse(request)?;
            let data = STANDARD.decode(r.data).map_err(|_| OpError::Invalid)?;
            let texts: Vec<String> = paste::chunks(&data, &r.image_type, &r.id)
                .iter()
                .map(ScreenInput::encode)
                .collect();
            json!({ "texts": texts })
        }
        "fraction" => {
            let r: FractionRequest = parse(request)?;
            let point = r.x.zip(r.y);
            json!({ "pointer": quality::fraction(point, r.display).map(|(x, y)| json!({ "x": x, "y": y })) })
        }
        "fit" => {
            let r: FitRequest = parse(request)?;
            let (width, height) = demand::fit(r.width, r.height, r.cap);
            json!({ "width": width, "height": height })
        }
        "rung" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct RungRequest {
                long_edge: i64,
                display_long_edge: i64,
            }
            let r: RungRequest = parse(request)?;
            json!({ "rung": demand::rung(r.long_edge, r.display_long_edge) })
        }
        "scroll_input" => {
            let r: ScrollRequest = parse(request)?;
            json!({ "text": ScreenInput::scroll(r.x, r.y, r.dx, r.dy, r.pixels).encode() })
        }
        "view_input" => {
            let r: ViewRequest = parse(request)?;
            json!({ "text": ScreenInput::view_demand(r.long_edge, r.pinch).encode() })
        }
        "frame_rate_input" => {
            #[derive(Deserialize)]
            struct FpsRequest {
                fps: i64,
            }
            let r: FpsRequest = parse(request)?;
            json!({ "text": ScreenInput::frame_rate(r.fps).encode() })
        }
        "source_message" => {
            let r: SourceRequest = parse(request)?;
            let state = SourceState::from_flags(r.locked, r.asleep);
            json!({ "state": state.as_str(), "text": ScreenHostMessage::source(state).encode() })
        }
        "qualities" => {
            let list: Vec<Value> = quality::ALL
                .iter()
                .map(|q| json!({ "id": q.as_str(), "title": q.title() }))
                .collect();
            json!({ "qualities": list })
        }
        "encoding_name" => {
            #[derive(Deserialize)]
            struct RawRequest {
                raw: i32,
            }
            let r: RawRequest = parse(request)?;
            json!({ "name": session::encoding_name(r.raw) })
        }
        _ => return Err(OpError::Unknown),
    })
}
