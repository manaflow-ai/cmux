//! The serve loop of `cmux-cloud`: the only thread that changes server
//! state. It blocks on one inbox that carries the host's lines (from a
//! reader thread) and wakes from link processes. Each op gets one result
//! line, then the events it caused; a wake sends the link and forward
//! events at once, with no op after the change. A connect never blocks the
//! loop: its result goes out when its link is up or ended. No polling; the
//! only timer is the link's ready deadline (`READY_DEADLINE`, crate::clock).

use super::relay::{HostRelay, Next, Waker};
use super::wire::Request;
use crate::app_env::AppEnv;
use crate::link::Attach;
use crate::ops::Server;
use crate::ports::{Edge, EdgeDown};
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};
use std::sync::Arc;

/// Serves ops until the host closes the channel.
pub fn serve<R: BufRead + Send + 'static, W: Write>(relay: HostRelay<R, W>) -> io::Result<()> {
    // Link details come from the host (`cmux.host.link.get`); the only
    // environment read is the allowlist (crate::app_env).
    serve_with(relay, Attach::real().with_env(AppEnv::from_process()), Edge::real())
}

/// [`serve`] with the attach state and the files and ports edge given
/// (tests pass the fake link spawner and the fake tunnel). The wake applies
/// to links spawned from here on: pass an `attach` with no live link.
pub fn serve_with<R: BufRead + Send + 'static, W: Write>(
    relay: HostRelay<R, W>,
    attach: Attach,
    edge: Edge,
) -> io::Result<()> {
    let (relay, waker) = relay.into_inbox()?;
    let mut server = Server::with_parts(relay, attach, edge);
    let link_waker = waker.clone();
    server.set_wake(Arc::new(move || link_waker.wake()));
    // Ask the host for the link details before the first op; connect
    // answers `link_unavailable` until they come.
    server.request_link_details();
    send_events(&mut server, &waker)?;
    while let Some(next) = server.control_plane_mut().next_step()? {
        if let Next::Message(message) = next
            && let Some(answer) = answer(&mut server, message)
        {
            server.control_plane_mut().send(&answer)?;
        }
        send_events(&mut server, &waker)?;
    }
    Ok(())
}

/// The result line for one host message; `None` for a line that gets none.
fn answer<R: BufRead, W: Write>(
    server: &mut Server<HostRelay<R, W>>,
    message: Value,
) -> Option<Value> {
    if super::host::is_host_frame(&message) {
        // A host answer or event: it changes state, it gets no line.
        server.host_frame(&message);
        return None;
    }
    let id = message.get("id").cloned().unwrap_or(Value::Null);
    Some(match message.get("type").and_then(Value::as_str) {
        // A connect never waits here for its link: its result goes out
        // later, from `send_events`, when the link is up or ended.
        Some("op") => match serde_json::from_value::<Request>(message) {
            Ok(request) => result_line(id.clone(), server.handle_from_loop(&request, &id)?),
            Err(e) => invalid(id, &e.to_string()),
        },
        // A team wire event (api::events): it changes the projection, its
        // watch events follow at once; it gets no line.
        Some("team.event") => {
            let event = message.get("event").and_then(Value::as_str).unwrap_or_default();
            let data = message.get("data").cloned().unwrap_or(Value::Null);
            if let Err(error) = server.team_event(event, &data) {
                eprintln!("cmux-cloud: ignored a team event: {error}");
            }
            return None;
        }
        // A relay answer that no call waits for (late or unknown): never
        // answer it, so the host cannot take it for one of its own ops.
        Some(t) if t.starts_with("relay.") => {
            eprintln!("cmux-cloud: ignored a {t} line that no call waits for");
            return None;
        }
        _ => invalid(id, "expected a message of type op"),
    })
}

/// Sends every event that is ready, in cause order: machine watch events,
/// then link changes, then the forwards and routes those changes closed.
fn send_events<R: BufRead, W: Write>(
    server: &mut Server<HostRelay<R, W>>,
    waker: &Waker,
) -> io::Result<()> {
    // Before the events are taken: a link event queued after this wakes
    // the loop again, so none waits for the next op.
    waker.taken();
    // Host-only requests (a link.get, or its one retry) first.
    for frame in server.take_host_frames() {
        server.control_plane_mut().send(&frame)?;
    }
    // `data` is the stream item (`{type: upsert|removed, revision, ...}`);
    // it is nested because `type` names the line kind here.
    for event in server.take_events() {
        let line = json!({ "type": "event", "event": "cloud.machine.watch", "data": event });
        server.control_plane_mut().send(&line)?;
    }
    // Connects whose link is now up or ended: each result before the link
    // line of the same change (the order a waiting connect had).
    for (id, outcome) in server.take_settled() {
        server.control_plane_mut().send(&result_line(id, outcome))?;
    }
    // Carrier changes (up, down, revoked) that arrived by now. This pumps
    // the supervisor; the reconcile below reads that same state.
    for line in crate::link::ops::take_event_lines(server) {
        server.control_plane_mut().send(&line)?;
    }
    // A link that went down (or was replaced) closes its forwards now.
    server.reconcile_edge();
    for down in server.take_edge_events() {
        server.control_plane_mut().send(&edge_line(&down))?;
    }
    // File transfers that ended (their workers woke the loop).
    for event in server.take_transfer_events() {
        server.control_plane_mut().send(&transfer_line(&event))?;
    }
    Ok(())
}

/// `cloud.port.changed`: a forward (`kind: forward`, with `port`) or a
/// browser route (`kind: browser`) closed with its link.
fn edge_line(down: &EdgeDown) -> Value {
    let mut line = json!({ "type": "event", "event": "cloud.port.changed",
        "machine": down.machine, "kind": if down.port.is_some() { "forward" } else { "browser" },
        "host": "127.0.0.1", "localPort": down.local_port, "generation": down.generation,
        "state": "down", "reason": down.reason });
    if let Some(port) = down.port {
        line["port"] = json!(port);
    }
    line
}

/// `cloud.file.transfer.changed`: one transfer ended (`done` with
/// `bytes`, `failed` with the typed `error`, or `cancelled`).
fn transfer_line(event: &crate::fs::TransferEvent) -> Value {
    let direction = match event.direction {
        crate::fs::Direction::Push => "push",
        crate::fs::Direction::Pull => "pull",
    };
    let mut line = json!({ "type": "event", "event": "cloud.file.transfer.changed",
        "transfer": event.transfer, "machine": event.machine, "direction": direction,
        "path": event.path, "localPath": event.local_path.to_string_lossy() });
    match &event.outcome {
        Ok(bytes) => {
            line["state"] = json!("done");
            line["bytes"] = json!(bytes);
        }
        Err(error) if error.code == crate::fs::transfer::TRANSFER_CANCELLED => {
            line["state"] = json!("cancelled");
        }
        Err(error) => {
            line["state"] = json!("failed");
            line["error"] = json!(error);
        }
    }
    line
}

fn result_line(id: Value, outcome: Result<Value, crate::api::CloudError>) -> Value {
    match outcome {
        Ok(result) => json!({ "type": "result", "id": id, "ok": true, "result": result }),
        Err(error) => json!({ "type": "result", "id": id, "ok": false, "error": error }),
    }
}

fn invalid(id: Value, why: &str) -> Value {
    json!({ "type": "result", "id": id, "ok": false,
        "error": { "code": "cmux.cloud.invalid_request", "message": why, "retryable": false } })
}
