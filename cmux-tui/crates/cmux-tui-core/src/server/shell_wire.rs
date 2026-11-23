//! `shell-run`, `shell-read` and `shell-stop` (`shell-runs-v1`): shell mode's commands of a chat
//! that lives on this machine (`crate::shell_runs`). The app forwards its page's `shell.run`,
//! `shell.read` and `shell.stop` here, so a Cloud or SSH chat's `!` line runs on its machine.
//!
//! Owner only, as a terminal of this machine is: a local Unix connection of this daemon's own
//! user that is bound to no agent, or the owner's signed Native link (the proof that already
//! lets the app open terminals here, `native_owner.rs`). A relayed peer, a guest, a WebSocket
//! page or an agent-bound connection is refused before anything runs; the remote relay gate
//! never admits these commands.
//!
//! - `shell-run {command, cwd?, scope?, run?}` answers `{run}` (the run's id: `run` when the caller
//!   chose one, so a lost answer still leaves it a run it can stop), or `{refused}`: `too_many`,
//!   `folder_missing`, `spawn_failed`, `invalid` (also a malformed or taken `run`).
//! - `shell-read {run, after, wait_ms?}` answers `{output, next, truncated?, exit?: {code?,
//!   signal?}}` once there is output after `after` or the command ended, else after `wait_ms`
//!   (at most 10 s, the default), or `{refused}`: `unknown_run`, `busy`. A read that waits does
//!   so on a thread of its own, so the connection's other requests are not held behind it.
//! - `shell-stop {run}` answers `{}` (Ctrl-C, escalating), or `{refused: "unknown_run"}`.
//!
//! Refusals are answers, not errors: a remote connection's errors reach the app as one opaque
//! code, and the app shows each refusal as its own message.

use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RunParams {
    command: String,
    #[serde(default)]
    cwd: Option<String>,
    /// The chat pane whose commands these are; each has its own running cap.
    #[serde(default)]
    scope: Option<String>,
    /// The run's id, chosen by the caller (`run_` and 32 lowercase hex digits), so it can stop
    /// the command even when this answer is lost; a new random one when absent.
    #[serde(default)]
    run: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ReadParams {
    run: String,
    #[serde(default)]
    after: u64,
    #[serde(default)]
    wait_ms: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StopParams {
    run: String,
}

#[cfg(unix)]
mod serve {
    use super::*;
    use crate::Mux;
    use crate::conversation_store::LOCAL_USER;
    use crate::panic_free::JsonFields;
    use crate::server::{ClientTransport, MessageWriter, Response, send_response};
    use crate::shell_runs::{Chunk, READ_WAIT, ReadStart, Refusal};
    use std::sync::Arc;
    use std::time::Duration;

    /// Not the owner: nothing runs, and the caller learns nothing about runs.
    #[derive(Debug)]
    pub(in crate::server) struct NotOwner;

    impl std::fmt::Display for NotOwner {
        fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            formatter.write_str(crate::request_origin::ORIGIN_FORBIDDEN)
        }
    }

    impl std::error::Error for NotOwner {}

    fn owner(mux: &Mux, client: u64) -> bool {
        let unix = matches!(mux.control_clients.transport_of(client), Some(ClientTransport::Unix));
        (unix && !mux.is_remote_client(client) && mux.conversation_principal(client) == LOCAL_USER)
            || mux.is_native_agent_owner(client)
    }

    fn refused(refusal: Refusal) -> Value {
        json!({"refused": refusal.as_str()})
    }

    pub(in crate::server) fn run(
        mux: &Mux,
        client: u64,
        params: RunParams,
    ) -> anyhow::Result<Value> {
        anyhow::ensure!(owner(mux, client), NotOwner);
        let scope = params.scope.unwrap_or_default();
        Ok(
            match mux.shell_runs.run_as(
                &scope,
                client,
                &params.command,
                params.cwd.as_deref(),
                params.run.as_deref(),
            ) {
                Ok(run) => json!({"run": run}),
                Err(refusal) => refused(refusal),
            },
        )
    }

    pub(in crate::server) fn stop(
        mux: &Mux,
        client: u64,
        params: StopParams,
    ) -> anyhow::Result<Value> {
        anyhow::ensure!(owner(mux, client), NotOwner);
        Ok(match mux.shell_runs.stop(&params.run) {
            Ok(()) => json!({}),
            Err(refusal) => refused(refusal),
        })
    }

    /// Answers at once when there is something to read, else from a thread that waits.
    pub(in crate::server) fn read(
        mux: &Arc<Mux>,
        client: u64,
        id: Option<Value>,
        params: ReadParams,
        writer: &MessageWriter,
    ) -> bool {
        if !owner(mux, client) {
            return respond(writer, id, Err(NotOwner.into()));
        }
        let wait = params.wait_ms.map_or(READ_WAIT, Duration::from_millis).min(READ_WAIT);
        let permit = match mux.shell_runs.start_read(&params.run, params.after) {
            Ok(ReadStart::Ready(chunk)) => return respond(writer, id, Ok(chunk_json(&chunk))),
            Ok(ReadStart::Wait(permit)) => permit,
            Err(refusal) => return respond(writer, id, Ok(refused(refusal))),
        };
        let thread_mux = mux.clone();
        let thread_writer = writer.clone();
        let reply_id = id.clone();
        let spawned = std::thread::Builder::new().name("shell-run-read".into()).spawn(move || {
            let answer =
                match thread_mux.shell_runs.wait_read(&permit, &params.run, params.after, wait) {
                    Ok(chunk) => chunk_json(&chunk),
                    Err(refusal) => refused(refusal),
                };
            drop(permit);
            respond(&thread_writer, reply_id, Ok(answer));
        });
        spawned.is_ok() || respond(writer, id, Ok(refused(Refusal::Busy)))
    }

    fn chunk_json(chunk: &Chunk) -> Value {
        let mut value = json!({"output": chunk.output, "next": chunk.next});
        if chunk.truncated {
            value.insert("truncated", json!(true));
        }
        if let Some(exit) = chunk.exit {
            let mut ended = json!({});
            if let Some(code) = exit.code {
                ended.insert("code", json!(code));
            }
            if let Some(signal) = exit.signal {
                ended.insert("signal", json!(signal));
            }
            value.insert("exit", ended);
        }
        value
    }

    fn respond(writer: &MessageWriter, id: Option<Value>, answer: anyhow::Result<Value>) -> bool {
        let response = match answer {
            Ok(data) => Response {
                id,
                ok: true,
                data: Some(data),
                error: None,
                error_code: None,
                error_delivery: None,
            },
            Err(error) => Response {
                id,
                ok: false,
                data: None,
                error: Some(error.to_string()),
                error_code: Some(crate::request_origin::ORIGIN_FORBIDDEN.to_owned()),
                error_delivery: None,
            },
        };
        send_response(writer, response)
    }
}

#[cfg(unix)]
pub(super) use serve::{read, run, stop};

#[cfg(not(unix))]
pub(super) fn run(_: &super::Mux, _: u64, _: RunParams) -> anyhow::Result<Value> {
    Ok(json!({"refused": "spawn_failed"}))
}

#[cfg(not(unix))]
pub(super) fn stop(_: &super::Mux, _: u64, _: StopParams) -> anyhow::Result<Value> {
    Ok(json!({"refused": "unknown_run"}))
}

#[cfg(not(unix))]
pub(super) fn read(
    _: &std::sync::Arc<super::Mux>,
    _: u64,
    id: Option<Value>,
    _: ReadParams,
    writer: &super::MessageWriter,
) -> bool {
    super::send_response(
        writer,
        super::Response {
            id,
            ok: true,
            data: Some(json!({"refused": "unknown_run"})),
            error: None,
            error_code: None,
            error_delivery: None,
        },
    )
}

#[cfg(all(test, unix))]
#[path = "shell_wire_tests.rs"]
mod tests;
