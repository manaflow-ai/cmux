//! `cmux-cloud`: the native server of the `cmux/cloud` app. The host
//! supervisor starts it on demand and speaks JSON lines on stdin and stdout
//! (shape in `api/relay.rs`). Nothing else is written to stdout.

use cmux_cloud::Server;
use cmux_cloud::api::{HostRelay, Request};
use serde_json::{Value, json};
use std::io::{self, BufReader};

fn main() -> io::Result<()> {
    let relay = HostRelay::new(BufReader::new(io::stdin().lock()), io::stdout().lock());
    let mut server = Server::new(relay);
    while let Some(message) = server.control_plane_mut().next_message()? {
        let id = message.get("id").cloned().unwrap_or(Value::Null);
        let answer = match message.get("type").and_then(Value::as_str) {
            Some("op") => match serde_json::from_value::<Request>(message) {
                Ok(request) => match server.handle(&request) {
                    Ok(result) => {
                        json!({ "type": "result", "id": id, "ok": true, "result": result })
                    }
                    Err(error) => {
                        json!({ "type": "result", "id": id, "ok": false, "error": error })
                    }
                },
                Err(e) => invalid(id, &e.to_string()),
            },
            _ => invalid(id, "expected a message of type op"),
        };
        server.control_plane_mut().send(&answer)?;
        for event in server.take_events() {
            let mut line = json!({ "type": "event", "event": "cloud.machine.changed" });
            if let (Some(target), Ok(Value::Object(fields))) =
                (line.as_object_mut(), serde_json::to_value(&event))
            {
                target.extend(fields);
            }
            server.control_plane_mut().send(&line)?;
        }
    }
    Ok(())
}

fn invalid(id: Value, why: &str) -> Value {
    json!({ "type": "result", "id": id, "ok": false,
        "error": { "code": "cmux.cloud.invalid_request", "message": why, "retryable": false } })
}
