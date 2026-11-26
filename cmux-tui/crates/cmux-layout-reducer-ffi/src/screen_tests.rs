use super::*;

fn call(operation: &str, request: Value) -> Value {
    let bytes = respond(operation.as_bytes(), request.to_string().as_bytes()).expect("answers");
    serde_json::from_slice(&bytes).unwrap()
}

#[test]
fn only_screen_ops_are_its_own() {
    assert!(handles(b"screen_demand_report"));
    assert!(!handles(b"window_close"));
    assert_eq!(respond(b"screen_nope", b"{}"), Err(ERR_INVALID));
    assert_eq!(respond(b"screen_demand_report", b"not json"), Err(ERR_INVALID));
}

#[test]
fn the_demand_round_trips_its_state() {
    let first = call(
        "screen_demand_report",
        json!({"longEdge": 1179, "displayLongEdge": 3456, "now": 0.0}),
    );
    assert_eq!(first["changed"], false);
    let second = call(
        "screen_demand_report",
        json!({"demand": first["demand"], "longEdge": 1179, "displayLongEdge": 3456, "now": 6.0}),
    );
    assert_eq!(second["changed"], true);
    assert_eq!(second["demand"]["cap"], 1280);
    let fit = call(
        "screen_demand_fit",
        json!({"size": {"w": 3456.0, "h": 2234.0}, "cap": 1280, "demand": 1280, "quality": "auto", "scales": false}),
    );
    assert_eq!(fit["size"], json!({"w": 1280.0, "h": 828.0}));
    assert_eq!(fit["captureCap"], Value::Null);
}

#[test]
fn a_bad_ticket_answers_swifts_error() {
    let answer =
        call("screen_ticket_open", json!({"jws": "nope", "signalUrl": "wss://hub.example/s"}));
    assert_eq!(
        answer["error"],
        ticket::TicketError::BadTicket("not a compact JWS".into()).to_string()
    );
    let bye = call("screen_ticket_outbound", json!({"signal": {"type": "bye"}}));
    assert_eq!(bye["text"], "{\"type\":\"bye\"}");
}

#[test]
fn the_focus_tick_answers_both_outcomes() {
    let sample = json!({"geometry": {"display": {"x": 0.0, "y": 0.0, "w": 100.0, "h": 50.0}, "pixels": {"w": 200.0, "h": 100.0}},
                        "pointer": {"x": 10.0, "y": 10.0}});
    let tick = call("screen_focus_tick", json!({"sample": sample, "nowUs": 1}));
    let messages = tick["messages"].as_array().unwrap();
    assert!(messages.iter().any(|m| m.as_str().unwrap().contains("\"kind\":\"pointer\"")));
    // After a refusal everything goes again; after a send, an unchanged pointer does not.
    let again = call(
        "screen_focus_tick",
        json!({"producer": tick["failed"], "sample": sample, "nowUs": 2}),
    );
    assert_eq!(again["messages"].as_array().unwrap().len(), messages.len());
    let quiet =
        call("screen_focus_tick", json!({"producer": tick["sent"], "sample": sample, "nowUs": 2}));
    assert!(
        quiet["messages"]
            .as_array()
            .unwrap()
            .iter()
            .all(|m| !m.as_str().unwrap().contains("pointer"))
    );
    let damage = call(
        "screen_focus_damage",
        json!({"producer": tick["sent"], "geometry": sample["geometry"], "rects": [{"x": 0.0, "y": 0.0, "w": 10.0, "h": 10.0}],
               "captured": {"w": 200.0, "h": 100.0}}),
    );
    assert!(damage["producer"].is_object());
}

#[test]
fn the_cursor_delivery_retries_a_refused_shape() {
    let caps = call("screen_cursor_caps", json!({"t": "caps", "s": "telepointers,cursor-shape"}));
    assert_eq!(caps, json!({"pointers": true, "shapes": true}));
    let id = call(
        "screen_cursor_shape",
        json!({"png": "iVBORw==", "hotspotX": 5.0, "hotspotY": 5.0}),
    )["id"]
        .clone();
    let shape = json!({"id": id, "png": "iVBORw==", "w": 0.02, "h": 0.04, "hx": 0.2, "hy": 0.125, "pw": 28.0, "ph": 40.0});
    assert_eq!(call("screen_cursor_drawable", shape.clone())["drawable"], true);
    let display = json!({"x": 0.0, "y": 0.0, "w": 1512.0, "h": 982.0});
    let prepared = call("screen_cursor_prepare", json!({"read": shape, "display": display}));
    assert!(prepared["text"].as_str().unwrap().contains("\"t\":\"cursor\""));
    let refused =
        call("screen_cursor_finish", json!({"delivery": prepared["delivery"], "delivered": false}));
    assert_eq!(refused["shape"], Value::Null);
    let retry =
        call("screen_cursor_prepare", json!({"delivery": refused["delivery"], "display": display}));
    assert_eq!(retry["text"], prepared["text"]);
    let taken =
        call("screen_cursor_finish", json!({"delivery": retry["delivery"], "delivered": true}));
    assert_eq!(taken["shape"], id);
}
