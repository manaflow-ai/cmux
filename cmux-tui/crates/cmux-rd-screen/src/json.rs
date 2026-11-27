//! The screen stream's rules over JSON (`screen_*`): one dispatcher that both
//! app libraries call, so the Mac (cmux-layout-reducer-ffi's C ABI) and iOS
//! (cmux-mobile-ffi's `screen_json`) answer every op the same way. State the
//! Swift caller keeps between calls (the producer, the demand, the delivery)
//! goes in and comes back as JSON; the Swift side keeps the platform work
//! (libwebrtc, capture, the cursor reader, the Secure Enclave signer).
//!
//! - `screen_ticket_open|receive|signing_message|outbound`: the hub ticket
//!   and its signaling frames ([`crate::ticket`]).
//! - `screen_focus_tick|damage`: follow mode's focus producer ([`crate::focus`]).
//! - `screen_demand_report|fit`: viewer demand ([`crate::demand`]).
//! - `screen_cursor_caps|shape|drawable|prepare|finish`: the cursor shape
//!   delivery ([`crate::cursor_shape`]).
//! - `screen_quality_encoding`: a preset's frame rate and sender encoding
//!   ([`crate::quality`]).

use std::fmt;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::cursor_shape::{self, CursorShape, CursorShapeDelivery};
use crate::demand::{self, Quality, ViewerDemand};
use crate::focus::{FocusGeometry, FocusProducer, FocusSample};
use crate::geometry::{Rect, Size};
use crate::quality;
use crate::ticket::{self, Signal, TicketSignaling};

/// The prefix every op of [`respond`] carries.
pub const OPERATION_PREFIX: &str = "screen_";

/// Whether `operation` is one of [`respond`]'s.
pub fn handles(operation: &str) -> bool {
    operation.starts_with(OPERATION_PREFIX)
}

/// Why [`respond`] gave no answer. A refusal the rules make (a bad ticket)
/// is an answer (`{"error": ...}`), not this.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JsonError {
    /// No op of that name.
    UnknownOperation(String),
    /// The request is not the op's JSON.
    Invalid(String),
}

impl fmt::Display for JsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownOperation(op) => write!(f, "unknown screen op {op:?}"),
            Self::Invalid(detail) => write!(f, "invalid screen request: {detail}"),
        }
    }
}

impl std::error::Error for JsonError {}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, JsonError> {
    serde_json::from_slice(request).map_err(|e| JsonError::Invalid(e.to_string()))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TicketRequest {
    jws: String,
    signal_url: String,
    #[serde(default)]
    expected_peer_key: Option<String>,
    #[serde(default)]
    text: String,
    #[serde(default)]
    sdp: String,
}

/// `{"error": description}` for a ticket refusal, as Swift's error reads.
fn ticket_error(error: ticket::TicketError) -> Value {
    json!({ "error": error.to_string() })
}

pub fn respond(operation: &str, request: &[u8]) -> Result<Value, JsonError> {
    let answer = match operation {
        // The ticket, the socket URL with it, and whether the first hello says the peer is there.
        "screen_ticket_open" => {
            let r: TicketRequest = read(request)?;
            match TicketSignaling::new(&r.jws, &r.signal_url, r.expected_peer_key.as_deref()) {
                Ok(s) => json!({
                    "ticket": s.ticket,
                    "socketUrl": s.socket_url,
                    "helloPeerPresent": s.hello_peer_present(),
                    "transport": ticket::RD_TRANSPORT,
                }),
                Err(e) => ticket_error(e),
            }
        }
        // One socket frame: the signal it carries (null: none), or the refusal that ends the session.
        "screen_ticket_receive" => {
            let r: TicketRequest = read(request)?;
            match TicketSignaling::new(&r.jws, &r.signal_url, None).and_then(|s| s.receive(&r.text))
            {
                Ok(inbound) => json!({ "inbound": inbound }),
                Err(e) => ticket_error(e),
            }
        }
        // The bytes this side signs for an offer or answer's fingerprint.
        "screen_ticket_signing_message" => {
            let r: TicketRequest = read(request)?;
            match TicketSignaling::new(&r.jws, &r.signal_url, None)
                .and_then(|s| s.signing_message(&r.sdp))
            {
                Ok(message) => json!({ "message": message }),
                Err(e) => ticket_error(e),
            }
        }
        // The text to send for one signal (null: nothing goes).
        "screen_ticket_outbound" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                signal: Signal,
                #[serde(default)]
                fp_sig: Option<String>,
            }
            let r: Request = read(request)?;
            json!({ "text": TicketSignaling::outbound(&r.signal, r.fp_sig.as_deref()) })
        }
        // One focus tick: the messages in order, and the producer after they all went or after a refusal.
        "screen_focus_tick" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                producer: Option<FocusProducer>,
                sample: FocusSample,
                now_us: u64,
            }
            let r: Request = read(request)?;
            let mut producer = r.producer.unwrap_or_default();
            match producer.tick(&r.sample, r.now_us) {
                Some(tick) => {
                    let messages = tick.messages.clone();
                    let mut failed = producer.clone();
                    failed.failed();
                    producer.commit(tick);
                    json!({ "messages": messages, "sent": producer, "failed": failed })
                }
                None => json!({ "messages": [], "sent": producer, "failed": producer }),
            }
        }
        // Screen damage from the capture, in its own pixels.
        "screen_focus_damage" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                producer: Option<FocusProducer>,
                #[serde(default)]
                geometry: Option<FocusGeometry>,
                rects: Vec<Rect>,
                captured: Size,
            }
            let r: Request = read(request)?;
            let mut producer = r.producer.unwrap_or_default();
            producer.damage(r.geometry.as_ref(), &r.rects, r.captured);
            json!({ "producer": producer })
        }
        // One viewer report: the demand after it and whether the cap changed.
        "screen_demand_report" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                demand: ViewerDemand,
                long_edge: i64,
                display_long_edge: i64,
                #[serde(default)]
                pinch: bool,
                now: f64,
            }
            let r: Request = read(request)?;
            let mut demand = r.demand;
            let changed = demand.report(r.long_edge, r.display_long_edge, r.pinch, r.now);
            json!({ "demand": demand, "changed": changed })
        }
        // The capture size for a cap, and the cap a source takes under a quality.
        "screen_demand_fit" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                size: Size,
                #[serde(default)]
                cap: Option<i64>,
                #[serde(default)]
                demand: Option<i64>,
                quality: Quality,
                scales: bool,
            }
            let r: Request = read(request)?;
            let capture = demand::capture_cap(r.demand, r.quality, r.scales);
            json!({ "size": demand::fit(r.size, r.cap), "captureCap": capture })
        }
        // A viewer's `caps`: whether it draws pointers, and the Mac's cursor image.
        "screen_cursor_caps" => {
            #[derive(Deserialize)]
            struct Request {
                t: String,
                #[serde(default)]
                s: Option<String>,
            }
            let r: Request = read(request)?;
            json!({
                "pointers": cursor_shape::viewer_draws_pointers(&r.t, r.s.as_deref()),
                "shapes": cursor_shape::viewer_draws_cursor_shapes(&r.t, r.s.as_deref()),
            })
        }
        // A read cursor's id and whether a viewer can draw it.
        "screen_cursor_shape" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                png: String,
                hotspot_x: f64,
                hotspot_y: f64,
            }
            use base64::Engine;
            let r: Request = read(request)?;
            let png = base64::engine::general_purpose::STANDARD
                .decode(&r.png)
                .map_err(|e| JsonError::Invalid(format!("png: {e}")))?;
            json!({ "id": cursor_shape::shape_id(&png, r.hotspot_x, r.hotspot_y) })
        }
        "screen_cursor_drawable" => {
            let shape: CursorShape = read(request)?;
            json!({ "drawable": shape.is_drawable() })
        }
        // One cursor sample: the message to try sending (null: none) and the delivery to finish with.
        "screen_cursor_prepare" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                delivery: CursorShapeDelivery,
                #[serde(default)]
                read: Option<CursorShape>,
                display: Rect,
            }
            let r: Request = read(request)?;
            let mut delivery = r.delivery;
            let text = delivery.prepare(r.read.as_ref(), r.display);
            json!({ "delivery": delivery, "text": text })
        }
        // Whether the link took it: the shape the telepointers name now.
        "screen_cursor_finish" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                delivery: CursorShapeDelivery,
                delivered: bool,
            }
            let r: Request = read(request)?;
            let mut delivery = r.delivery;
            let shape = delivery.finish(r.delivered);
            json!({ "delivery": delivery, "shape": shape })
        }
        // The frame rate both displays agree on and the screen sender's encoding at it.
        "screen_quality_encoding" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                quality: Quality,
                #[serde(default)]
                source_width: i64,
                #[serde(default)]
                source_height: i64,
                #[serde(default)]
                host_maximum: Option<i64>,
                #[serde(default)]
                viewer_maximum: Option<i64>,
            }
            let r: Request = read(request)?;
            let fps = quality::frame_rate(r.quality, r.host_maximum, r.viewer_maximum);
            let encoding = quality::encoding(r.quality, r.source_width, r.source_height, fps);
            json!({ "frameRate": fps, "encoding": encoding })
        }
        _ => return Err(JsonError::UnknownOperation(operation.to_owned())),
    };
    Ok(answer)
}

#[cfg(test)]
#[path = "json_tests.rs"]
mod tests;
