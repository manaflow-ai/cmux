//! The local owner's Unix socket server (JSON lines, protocol.rs).
//!
//! One writer thread owns the `Engine`: it blocks on its channel, drains
//! whatever else is queued (group commit), flushes once, then answers and
//! fans out events. Connection threads only parse and write lines. Nothing
//! polls: every thread blocks on a channel or a socket read.

#![cfg(unix)]

use std::collections::BTreeMap;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::thread;

use cmux_tasks_core::ids::Principal;
use serde_json::{Value, json};

use crate::engine::Engine;
use crate::owner::LocalOwner;
use crate::protocol::{ClientLine, ErrorBody, ErrorCode, Request, ServerLine, Settled};

const MAX_BATCH: usize = 256;
/// Requests queued for the writer; a full queue blocks that client's reader
/// (backpressure on the client that floods, not on others).
const REQUEST_QUEUE: usize = 1_024;
/// Lines queued for one connection; a client that falls this far behind is
/// disconnected and resumes with `after_seq` (no unbounded buffers).
const OUT_QUEUE: usize = 4_096;

enum Msg {
    Request {
        conn: u64,
        actor: Principal,
        request: Request,
    },
    Hangup {
        conn: u64,
    },
    Connected {
        conn: u64,
        out: SyncSender<String>,
    },
    /// A line for one connection that did not come from a request.
    Raw {
        conn: u64,
        text: String,
    },
}

fn line(value: &ServerLine) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".to_owned())
}

/// Bind the socket and serve until the process exits. `on_ready` runs once
/// the socket accepts connections.
pub fn serve(owner: &LocalOwner, engine: Engine, on_ready: impl FnOnce()) -> io::Result<()> {
    // We hold the store lock, so any socket file left here is stale.
    let _ = std::fs::remove_file(&owner.socket);
    let listener = UnixListener::bind(&owner.socket)?;
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&owner.socket, std::fs::Permissions::from_mode(0o600))?;
    }
    let (tx, rx) = mpsc::sync_channel::<Msg>(REQUEST_QUEUE);
    let writer = thread::Builder::new()
        .name("tasks-writer".to_owned())
        .spawn(move || writer_loop(engine, rx))?;
    on_ready();
    let mut next_conn = 0u64;
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(stream) => stream,
            Err(_) => continue,
        };
        next_conn += 1;
        let conn = next_conn;
        let tx = tx.clone();
        thread::Builder::new()
            .name(format!("tasks-conn-{conn}"))
            .spawn(move || connection(conn, stream, tx))?;
        if writer.is_finished() {
            return Err(io::Error::other("tasks writer stopped"));
        }
    }
    Ok(())
}

fn connection(conn: u64, stream: UnixStream, tx: SyncSender<Msg>) {
    let Ok(write_half) = stream.try_clone() else { return };
    let (out_tx, out_rx) = mpsc::sync_channel::<String>(OUT_QUEUE);
    // Only the writer holds the sender, so dropping it there closes the
    // socket of a slow client.
    if tx.send(Msg::Connected { conn, out: out_tx }).is_err() {
        return;
    }
    let pump = thread::spawn(move || {
        let mut write_half = write_half;
        for text in out_rx {
            if write_half
                .write_all(text.as_bytes())
                .and_then(|()| write_half.write_all(b"\n"))
                .is_err()
            {
                break;
            }
        }
        // The writer dropped this connection (too slow) or it hung up: close
        // the socket so the client sees EOF and reconnects.
        let _ = write_half.shutdown(std::net::Shutdown::Both);
    });
    // Without a hello the connection acts as the machine's person, never
    // as whatever agent environment the server itself was started in.
    let mut actor = crate::owner::local_person();
    for raw in BufReader::new(stream).lines() {
        let Ok(raw) = raw else { break };
        if raw.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<ClientLine>(&raw) {
            Ok(ClientLine::Hello { hello }) => actor = hello.actor,
            Ok(ClientLine::Request(request)) => {
                if tx.send(Msg::Request { conn, actor: actor.clone(), request }).is_err() {
                    break;
                }
            }
            Err(e) => {
                let err = ServerLine::Err {
                    id: 0,
                    err: ErrorBody::new(ErrorCode::Usage, format!("bad line: {e}")),
                };
                if tx.send(Msg::Raw { conn, text: line(&err) }).is_err() {
                    break;
                }
            }
        }
    }
    let _ = tx.send(Msg::Hangup { conn });
    let _ = pump.join();
}

fn writer_loop(mut engine: Engine, rx: Receiver<Msg>) {
    let mut outs: BTreeMap<u64, SyncSender<String>> = BTreeMap::new();
    let mut subscribers: BTreeMap<u64, SyncSender<String>> = BTreeMap::new();
    while let Ok(first) = rx.recv() {
        let mut batch = vec![first];
        while batch.len() < MAX_BATCH {
            match rx.try_recv() {
                Ok(msg) => batch.push(msg),
                Err(_) => break,
            }
        }
        let mut requests = Vec::new();
        let mut subscribes = Vec::new();
        for msg in batch {
            match msg {
                Msg::Connected { conn, out } => {
                    outs.insert(conn, out);
                }
                Msg::Raw { conn, text } => {
                    if let Some(out) = outs.get(&conn)
                        && !deliver(out, text)
                    {
                        outs.remove(&conn);
                    }
                }
                Msg::Hangup { conn } => {
                    outs.remove(&conn);
                    subscribers.remove(&conn);
                }
                Msg::Request { conn, actor, request } if request.op == "task.subscribe" => {
                    subscribes.push((conn, actor, request));
                }
                Msg::Request { conn, actor, request } => requests.push((conn, actor, request)),
            }
        }
        let conns: Vec<u64> = requests.iter().map(|(c, _, _)| *c).collect();
        let outcomes =
            match engine.handle_batch(requests.into_iter().map(|(_, a, r)| (a, r)).collect()) {
                Ok(outcomes) => outcomes,
                Err(e) => {
                    // The log write failed: memory is ahead of disk. Exit and
                    // let the supervisor restart from disk (crash-only).
                    eprintln!("cmux-tasks: log write failed, exiting: {e}");
                    std::process::exit(70);
                }
            };
        for (conn, outcome) in conns.into_iter().zip(outcomes) {
            for event in &outcome.events {
                let text = line(&ServerLine::Event { event: event.clone() });
                let slow: Vec<u64> = subscribers
                    .iter()
                    .filter(|(_, out)| !deliver(out, text.clone()))
                    .map(|(c, _)| *c)
                    .collect();
                for c in slow {
                    subscribers.remove(&c);
                    outs.remove(&c);
                }
            }
            if let Some(out) = outs.get(&conn) {
                let reply = match outcome.reply {
                    Ok(ok) => ServerLine::Ok { id: outcome.settled.id, ok },
                    Err(err) => ServerLine::Err { id: outcome.settled.id, err },
                };
                let delivered = deliver(out, line(&reply))
                    && deliver(out, line(&ServerLine::Settled { settled: outcome.settled }));
                if !delivered {
                    outs.remove(&conn);
                    subscribers.remove(&conn);
                }
            }
        }
        for (conn, actor, request) in subscribes {
            subscribe(&engine, &outs, &mut subscribers, conn, &actor, &request);
        }
    }
}

/// Queue a line without blocking the writer; false when the client is gone
/// or too far behind (the caller then drops the connection).
fn deliver(out: &SyncSender<String>, text: String) -> bool {
    match out.try_send(text) {
        Ok(()) => true,
        Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => false,
    }
}

fn subscribe(
    engine: &Engine,
    outs: &BTreeMap<u64, SyncSender<String>>,
    subscribers: &mut BTreeMap<u64, SyncSender<String>>,
    conn: u64,
    actor: &Principal,
    request: &Request,
) {
    let Some(out) = outs.get(&conn) else { return };
    let seq = engine.state().seq;
    let settled = ServerLine::Settled { settled: Settled { id: request.id, tx: None, seq } };
    match request.params.get("after_seq").and_then(Value::as_u64) {
        None => {
            let _ = out.try_send(line(&ServerLine::Ok { id: request.id, ok: json!({"seq": seq}) }));
            let _ = out.try_send(line(&settled));
            let _ = out
                .try_send(line(&ServerLine::Snapshot { snapshot: engine.snapshot_value(actor) }));
        }
        Some(after) => match engine.events_after(after) {
            // More catch-up than one connection may queue: start over.
            Ok(events) if events.len() + 8 >= OUT_QUEUE => {
                let err = ErrorBody::new(
                    ErrorCode::Resync,
                    "too many events to catch up; subscribe without after_seq",
                );
                let _ = out.try_send(line(&ServerLine::Err { id: request.id, err }));
                let _ = out.try_send(line(&settled));
                return;
            }
            Ok(events) => {
                let _ =
                    out.try_send(line(&ServerLine::Ok { id: request.id, ok: json!({"seq": seq}) }));
                let _ = out.try_send(line(&settled));
                for event in events {
                    let _ = out.try_send(line(&ServerLine::Event { event }));
                }
            }
            Err(err) => {
                let _ = out.try_send(line(&ServerLine::Err { id: request.id, err }));
                let _ = out.try_send(line(&settled));
                return;
            }
        },
    }
    subscribers.insert(conn, out.clone());
}
