//! `cmux-rd-screen`'s screen stream rules over the JSON channel (`screen_*`):
//! the hub ticket and its signaling frames, follow mode's focus producer,
//! viewer demand and the cursor shape delivery. State the Swift caller keeps
//! between calls (the producer, the demand, the delivery) goes in and comes
//! back as JSON; the Swift side keeps the platform work (libwebrtc, capture,
//! the cursor reader, the Secure Enclave signer).

use cmux_rd_screen::cursor_shape::{self, CursorShape, CursorShapeDelivery};
use cmux_rd_screen::demand::{self, Quality, ViewerDemand};
use cmux_rd_screen::focus::{FocusGeometry, FocusProducer, FocusSample};
use cmux_rd_screen::geometry::{Rect, Size};
use cmux_rd_screen::ticket::{self, Signal, TicketSignaling};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"screen_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
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

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The ticket, the socket URL with it, and whether the first hello says the peer is there.
        b"screen_ticket_open" => {
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
        b"screen_ticket_receive" => {
            let r: TicketRequest = read(request)?;
            match TicketSignaling::new(&r.jws, &r.signal_url, None).and_then(|s| s.receive(&r.text))
            {
                Ok(inbound) => json!({ "inbound": inbound }),
                Err(e) => ticket_error(e),
            }
        }
        // The bytes this side signs for an offer or answer's fingerprint.
        b"screen_ticket_signing_message" => {
            let r: TicketRequest = read(request)?;
            match TicketSignaling::new(&r.jws, &r.signal_url, None)
                .and_then(|s| s.signing_message(&r.sdp))
            {
                Ok(message) => json!({ "message": message }),
                Err(e) => ticket_error(e),
            }
        }
        // The text to send for one signal (null: nothing goes).
        b"screen_ticket_outbound" => {
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
        b"screen_focus_tick" => {
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
        b"screen_focus_damage" => {
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
        b"screen_demand_report" => {
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
        b"screen_demand_fit" => {
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
        b"screen_cursor_caps" => {
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
        b"screen_cursor_shape" => {
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
                .map_err(|_| ERR_INVALID)?;
            json!({ "id": cursor_shape::shape_id(&png, r.hotspot_x, r.hotspot_y) })
        }
        b"screen_cursor_drawable" => {
            let shape: CursorShape = read(request)?;
            json!({ "drawable": shape.is_drawable() })
        }
        // One cursor sample: the message to try sending (null: none) and the delivery to finish with.
        b"screen_cursor_prepare" => {
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
        b"screen_cursor_finish" => {
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
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

#[cfg(test)]
#[path = "screen_tests.rs"]
mod tests;
