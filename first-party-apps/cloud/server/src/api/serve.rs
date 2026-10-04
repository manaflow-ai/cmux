//! The op loop of `cmux-cloud`: one host message at a time; each op gets one
//! result line, then the projection events it caused.

use super::relay::HostRelay;
use super::wire::Request;
use crate::ops::Server;
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};

/// Serves ops until the host closes the channel.
pub fn serve<R: BufRead, W: Write>(relay: HostRelay<R, W>) -> io::Result<()> {
    // Attach settings come from the host's environment (crate::link::Attach::from_env).
    let mut server = Server::with_attach(relay, crate::link::Attach::from_env());
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
            // A relay answer that no call waits for (late or unknown): never
            // answer it, so the host cannot take it for one of its own ops.
            Some(t) if t.starts_with("relay.") => {
                eprintln!("cmux-cloud: ignored a {t} line that no call waits for");
                continue;
            }
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
