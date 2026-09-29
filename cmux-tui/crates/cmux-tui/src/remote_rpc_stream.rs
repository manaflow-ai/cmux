//! `cmux remote rpc --stream`: a long-lived, multiplexed WorkspaceRequest
//! channel for native hosts.
//!
//! Plain line mode answers requests in order and exits on the first RPC error,
//! which suits scripts. A native file browser instead keeps one connection per
//! machine and issues independent requests (list, stat, read) that may fail on
//! their own. Stream mode tags every request with a caller-chosen id, runs the
//! requests concurrently, reports each result or error on its own line, and
//! keeps the channel open. `{"id":ID,"cancel":true}` drops an in-flight request,
//! which cancels it on the daemon.

use std::collections::HashMap;
use std::io::{self, Write};
use std::sync::Arc;

use cmux_remote::client::WorkspaceClient;
use cmux_remote_protocol::{RpcError, WorkspaceRequest, WorkspaceResponse};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

/// Upper bound on concurrently running stream requests. Excess requests are
/// rejected with `busy` instead of queueing without limit.
const MAX_STREAM_IN_FLIGHT: usize = 64;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct StreamInput {
    id: Value,
    #[serde(default)]
    request: Option<WorkspaceRequest>,
    #[serde(default)]
    cancel: bool,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
enum StreamOutput {
    Ready { ready: bool },
    Result { id: Value, result: WorkspaceResponse },
    Error { id: Value, error: RpcError },
}

/// Parsed stream line: either a request to start or a cancellation.
#[derive(Debug)]
enum StreamCommand {
    Start { key: String, id: Value, request: Box<WorkspaceRequest> },
    Cancel { key: String },
}

fn parse_stream_line(line: &str) -> Result<StreamCommand, Box<(Value, RpcError)>> {
    let input: StreamInput = serde_json::from_str(line).map_err(|error| {
        Box::new((
            Value::Null,
            RpcError::new("invalid-request", format!("invalid stream line: {error}")),
        ))
    })?;
    let key = input.id.to_string();
    match (input.request, input.cancel) {
        (Some(request), false) => {
            Ok(StreamCommand::Start { key, id: input.id, request: Box::new(request) })
        }
        (None, true) => Ok(StreamCommand::Cancel { key }),
        _ => Err(Box::new((
            input.id,
            RpcError::new("invalid-request", "stream line needs exactly one of request or cancel"),
        ))),
    }
}

fn write_output(output: &StreamOutput) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, output).map_err(io::Error::other)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}

/// Serves stream mode until stdin closes or the remote runtime finishes.
pub(super) async fn serve_rpc_stream(
    client: Arc<WorkspaceClient>,
    input: &mut mpsc::Receiver<io::Result<String>>,
    finished: &mut watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let (done_tx, mut done_rx) = mpsc::unbounded_channel::<String>();
    let mut in_flight: HashMap<String, JoinHandle<()>> = HashMap::new();
    write_output(&StreamOutput::Ready { ready: true })?;
    loop {
        let line = tokio::select! {
            biased;
            Some(key) = done_rx.recv() => {
                in_flight.remove(&key);
                continue;
            }
            event = super::next_rpc_input(input, finished) => event?,
        };
        let super::RpcInputEvent::Line(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        match parse_stream_line(&line) {
            Err(failure) => {
                let (id, error) = *failure;
                write_output(&StreamOutput::Error { id, error })?;
            }
            Ok(StreamCommand::Cancel { key }) => {
                if let Some(task) = in_flight.remove(&key) {
                    task.abort();
                }
            }
            Ok(StreamCommand::Start { key, id, request }) => {
                if in_flight.contains_key(&key) {
                    let error = RpcError::new("invalid-request", "request id is already in flight");
                    write_output(&StreamOutput::Error { id, error })?;
                    continue;
                }
                if in_flight.len() >= MAX_STREAM_IN_FLIGHT {
                    let error = RpcError::new("busy", "too many in-flight stream requests");
                    write_output(&StreamOutput::Error { id, error })?;
                    continue;
                }
                let client = Arc::clone(&client);
                let done = done_tx.clone();
                let task_key = key.clone();
                let task = tokio::spawn(async move {
                    let output = match client.request(*request).await {
                        Ok(result) => StreamOutput::Result { id, result },
                        Err(error) => StreamOutput::Error { id, error },
                    };
                    // A closed stdout ends the process through the input loop.
                    let _ = write_output(&output);
                    let _ = done.send(task_key);
                });
                in_flight.insert(key, task);
            }
        }
    }
    for (_, task) in in_flight {
        task.abort();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_line_parses_request_with_numeric_id() {
        let command =
            parse_stream_line(r#"{"id":7,"request":{"type":"open-workspace","root":"/"}}"#)
                .unwrap();
        let StreamCommand::Start { key, id, request } = command else { panic!() };
        assert_eq!(key, "7");
        assert_eq!(id, Value::from(7));
        assert!(matches!(*request, WorkspaceRequest::OpenWorkspace { root } if root == "/"));
    }

    #[test]
    fn stream_line_parses_cancel() {
        let command = parse_stream_line(r#"{"id":"a","cancel":true}"#).unwrap();
        assert!(matches!(command, StreamCommand::Cancel { key } if key == "\"a\""));
    }

    #[test]
    fn stream_line_errors_keep_the_caller_id() {
        let (id, error) = *parse_stream_line(r#"{"id":3}"#).unwrap_err();
        assert_eq!(id, Value::from(3));
        assert_eq!(error.code, "invalid-request");
        let (id, _) = *parse_stream_line("not json").unwrap_err();
        assert_eq!(id, Value::Null);
    }

    #[test]
    fn stream_output_shapes_are_flat_json() {
        let ready = serde_json::to_string(&StreamOutput::Ready { ready: true }).unwrap();
        assert_eq!(ready, r#"{"ready":true}"#);
        let error = serde_json::to_string(&StreamOutput::Error {
            id: Value::from(1),
            error: RpcError::new("not-found", "missing"),
        })
        .unwrap();
        assert_eq!(
            error,
            r#"{"id":1,"error":{"code":"not-found","message":"missing","retryable":false}}"#
        );
    }
}
