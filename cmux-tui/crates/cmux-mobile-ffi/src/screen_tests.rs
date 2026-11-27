use serde_json::{Value, json};

use super::*;

fn call(operation: &str, request: Value) -> Value {
    let answer = screen_json(operation.into(), request.to_string()).expect("answers");
    serde_json::from_str(&answer).unwrap()
}

/// What the Mac's C ABI answers for the same op (cmux-layout-reducer-ffi
/// passes `cmux_rd_screen::json::respond` through unchanged).
fn mac(operation: &str, request: &Value) -> Value {
    cmux_rd_screen::json::respond(operation, request.to_string().as_bytes()).expect("answers")
}

#[test]
fn errors_name_the_op_or_the_request() {
    assert_eq!(
        screen_json("screen_nope".into(), "{}".into()),
        Err(ScreenJsonError::UnknownOperation { operation: "screen_nope".into() })
    );
    assert!(matches!(
        screen_json("screen_demand_report".into(), "not json".into()),
        Err(ScreenJsonError::Invalid { .. })
    ));
    assert!(matches!(
        screen_json("window_close".into(), "{}".into()),
        Err(ScreenJsonError::UnknownOperation { .. })
    ));
}

/// One request per op: the phone answers each exactly as the Mac does.
#[test]
fn every_op_answers_as_on_the_mac() {
    let display = json!({"x": 0.0, "y": 0.0, "w": 1512.0, "h": 982.0});
    let shape = json!({"id": "s", "png": "iVBORw==", "w": 0.02, "h": 0.04, "hx": 0.2, "hy": 0.125, "pw": 28.0, "ph": 40.0});
    let geometry = json!({"display": {"x": 0.0, "y": 0.0, "w": 100.0, "h": 50.0}, "pixels": {"w": 200.0, "h": 100.0}});
    let cases = [
        ("screen_ticket_open", json!({"jws": "nope", "signalUrl": "wss://hub.example/s"})),
        (
            "screen_ticket_receive",
            json!({"jws": "nope", "signalUrl": "wss://hub.example/s", "text": "{}"}),
        ),
        (
            "screen_ticket_signing_message",
            json!({"jws": "nope", "signalUrl": "wss://hub.example/s", "sdp": "v=0"}),
        ),
        ("screen_ticket_outbound", json!({"signal": {"type": "bye"}})),
        (
            "screen_focus_tick",
            json!({"sample": {"geometry": geometry, "pointer": {"x": 10.0, "y": 10.0}}, "nowUs": 1}),
        ),
        (
            "screen_focus_damage",
            json!({"geometry": geometry, "rects": [{"x": 0.0, "y": 0.0, "w": 10.0, "h": 10.0}], "captured": {"w": 200.0, "h": 100.0}}),
        ),
        ("screen_demand_report", json!({"longEdge": 1179, "displayLongEdge": 3456, "now": 0.0})),
        (
            "screen_demand_fit",
            json!({"size": {"w": 3456.0, "h": 2234.0}, "cap": 1280, "quality": "auto", "scales": false}),
        ),
        ("screen_cursor_caps", json!({"t": "caps", "s": "telepointers,cursor-shape"})),
        ("screen_cursor_shape", json!({"png": "iVBORw==", "hotspotX": 5.0, "hotspotY": 5.0})),
        ("screen_cursor_drawable", shape.clone()),
        ("screen_cursor_prepare", json!({"read": shape, "display": display})),
        ("screen_cursor_finish", json!({"delivered": true})),
    ];
    for (operation, request) in cases {
        assert_eq!(call(operation, request.clone()), mac(operation, &request), "{operation}");
    }
}

#[test]
fn state_round_trips_through_the_string() {
    let first = call(
        "screen_demand_report",
        json!({"longEdge": 1179, "displayLongEdge": 3456, "now": 0.0}),
    );
    let second = call(
        "screen_demand_report",
        json!({"demand": first["demand"], "longEdge": 1179, "displayLongEdge": 3456, "now": 6.0}),
    );
    assert_eq!(second["changed"], true);
    assert_eq!(second["demand"]["cap"], 1280);
}
