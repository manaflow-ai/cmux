//! Maps client failures to a message and an exit code (see [`crate::exit`]).

use std::io::Write;

use cmux_vm_client::{ByteStream, Error};
use futures::StreamExt;
use serde_json::{Value, json};

use crate::exit;

/// Error bodies larger than this are cut; the CLI only shows a message.
const MAX_ERROR_BODY: usize = 64 * 1024;

#[derive(Debug)]
pub struct CliError {
    code: i32,
    status: Option<u16>,
    tag: Option<String>,
    /// For HTTP 429, which budget ran out (`snapshots`, `vms`, `rate` or
    /// `capacity`), when the server names it.
    budget: Option<String>,
    message: String,
}

impl CliError {
    pub fn usage(message: impl Into<String>) -> Self {
        Self::local(exit::USAGE, message)
    }

    pub fn unexpected(message: impl Into<String>) -> Self {
        Self::local(exit::UNEXPECTED, message)
    }

    pub fn unauthenticated(message: impl Into<String>) -> Self {
        Self::local(exit::UNAUTHENTICATED, message)
    }

    pub fn network(message: impl Into<String>) -> Self {
        Self::local(exit::NETWORK, message)
    }

    pub fn cancelled(message: impl Into<String>) -> Self {
        Self::local(exit::CANCELLED, message)
    }

    /// An error raised by the CLI itself, before or without an HTTP status.
    /// Its tag names the kind, so `--json` callers can branch on `tag` for
    /// every failure, not only API errors.
    fn local(code: i32, message: impl Into<String>) -> Self {
        let tag = match code {
            exit::USAGE => "UsageError",
            exit::NETWORK => "NetworkError",
            exit::UNAUTHENTICATED => "MissingCredentials",
            exit::CANCELLED => "Cancelled",
            _ => "UnexpectedError",
        };
        Self {
            code,
            status: None,
            tag: Some(tag.to_owned()),
            budget: None,
            message: message.into(),
        }
    }

    pub fn exit_code(&self) -> i32 {
        self.code
    }

    /// Keep the original intent key visible after a resize error, including a partial provider failure.
    pub fn with_retry_key(mut self, key: &str) -> Self {
        self.message = format!(
            "{}; retry the same intent with --idempotency-key {key}",
            self.message
        );
        self
    }

    /// For a create or fork whose outcome is unknown (the request may have
    /// reached the server before the connection failed), says how to retry
    /// without creating a second VM.
    pub fn with_idempotency_hint(mut self, key: &str) -> Self {
        if self.code == exit::NETWORK {
            self.message = format!(
                "{}; the operation may have succeeded: rerun with --idempotency-key {key} to retry it safely",
                self.message
            );
        }
        self
    }

    /// Add the resource and command needed to recover a VM operation. The
    /// HTTP error body does not contain the CLI's original path, so callers
    /// add this at the VM operation boundary.
    pub fn for_vm(mut self, vm_id: &str, verb: &str) -> Self {
        let next = match verb {
            "exec" => format!("cmux-vm exec {vm_id} -- <command>"),
            "pause" => format!("cmux-vm pause {vm_id}"),
            "resume" => format!("cmux-vm resume {vm_id}"),
            "start" => format!("cmux-vm start {vm_id}"),
            "stop" => format!("cmux-vm stop {vm_id}"),
            "delete" => format!("cmux-vm delete {vm_id} --yes"),
            "fork" => format!("cmux-vm fork {vm_id}"),
            "snapshot" => format!("cmux-vm snapshot create {vm_id}"),
            _ => format!("cmux-vm get {vm_id}"),
        };
        if self.status == Some(404) && self.message == "not found" {
            self.message = format!("VM {vm_id} was not found; run `cmux-vm ls` to list VMs");
        } else if !self.message.contains(vm_id) {
            self.message = format!("VM {vm_id}: {}", self.message);
        }
        if !self.message.contains(&next) {
            self.message.push_str(&format!("; next: `{next}`"));
        }
        self
    }

    pub async fn from_api(error: Error<ByteStream>) -> Self {
        match error {
            Error::ErrorResponse(response) => {
                let status = response.status().as_u16();
                let body = read_stream(response.into_inner()).await;
                Self::from_status(status, &body)
            }
            Error::UnexpectedResponse(mut response) => {
                let status = response.status().as_u16();
                let mut body = Vec::new();
                while body.len() < MAX_ERROR_BODY {
                    match response.chunk().await {
                        Ok(Some(chunk)) => append_capped(&mut body, &chunk),
                        _ => break,
                    }
                }
                Self::from_status(status, &body)
            }
            Error::CommunicationError(e) | Error::ResponseBodyError(e) => Self::network(format!(
                "could not reach the cmux VM API: {e}; check your network and retry with `cmux-vm --help`"
            )),
            Error::InvalidRequest(message) => Self::usage(message),
            Error::InvalidResponsePayload(_, e) => Self::local(
                exit::UNEXPECTED,
                format!(
                    "the cmux VM API sent a response this CLI cannot read: {e}; update cmux-vm and retry"
                ),
            ),
            other => Self::local(exit::UNEXPECTED, other.to_string()),
        }
    }

    fn from_status(status: u16, body: &[u8]) -> Self {
        let parsed: Option<Value> = serde_json::from_slice(body).ok();
        let field = |name: &str| {
            parsed
                .as_ref()
                .and_then(|v| v.get(name))
                .and_then(Value::as_str)
                .map(str::to_owned)
        };
        let tag = field("_tag");
        let budget = field("budget");
        let server_message = field("message");
        let missing_scope = field("missingScope").or_else(|| field("scope"));
        let field_name = field("field");
        let state = field("state");
        let action = field("action");
        let code = exit::for_status(status);
        let fallback = match status {
            400 => "the request was rejected as invalid",
            401 => "not authenticated: check the API key",
            402 => "the team's plan does not include this",
            403 => "this credential lacks the required scope",
            404 => "not found",
            409 => "the resource's current state does not allow this",
            413 => "the request is larger than the cmux VM API accepts",
            426 => "this endpoint needs a WebSocket upgrade",
            429 => "a quota or rate limit was reached",
            501 => "this operation is not available yet",
            503 => "the cmux VM service is temporarily unavailable",
            _ => "the cmux VM API returned an error",
        };
        let mut message = server_message.unwrap_or_else(|| fallback.to_owned());
        if let Some(scope) = missing_scope {
            message = format!("{message}; this credential lacks the required `{scope}` scope");
        }
        if let Some(field_name) = field_name {
            message = format!("{message} (field `{field_name}`)");
        }
        if let Some(state) = state {
            message = format!("{message}; VM state is `{state}`");
        }
        if let Some(action) = action {
            message = format!("{message}; action: {action}");
        }
        if status == 501 && !message.contains("not available yet") {
            message = format!("not available yet: {message}; update cmux-vm and retry");
        }
        if status == 400 {
            message.push_str("; check the command's flags and run `cmux-vm --help`");
        }
        if status == 402 {
            message.push_str("; check the team's plan at https://cmux.com/pricing");
        }
        Self {
            code,
            status: Some(status),
            tag,
            budget,
            message,
        }
    }

    pub fn report(&self, json: bool, stderr: &mut dyn Write) {
        let _ = if json {
            let mut error = json!({
                "status": self.status,
                "tag": self.tag,
                "message": self.message,
                "exitCode": self.code,
            });
            if let Some(budget) = &self.budget {
                error["budget"] = json!(budget);
            }
            writeln!(stderr, "{}", json!({ "error": error }))
        } else {
            let tag = match (&self.tag, &self.budget) {
                (Some(tag), Some(budget)) => Some(format!("{tag}, budget {budget}")),
                (tag, _) => tag.clone(),
            };
            match (self.status, &tag) {
                (Some(status), Some(tag)) => {
                    writeln!(stderr, "cmux-vm: {} (HTTP {status} {tag})", self.message)
                }
                (Some(status), None) => {
                    writeln!(stderr, "cmux-vm: {} (HTTP {status})", self.message)
                }
                _ => writeln!(stderr, "cmux-vm: {}", self.message),
            }
        };
    }
}

/// Prints a non-fatal warning: a JSON line `{"warning": ...}` with `--json`,
/// otherwise a `cmux-vm: warning:` line.
pub fn report_warning(message: &str, json: bool, stderr: &mut dyn Write) {
    let _ = if json {
        writeln!(stderr, "{}", json!({ "warning": message }))
    } else {
        writeln!(stderr, "cmux-vm: warning: {message}")
    };
}

async fn read_stream(stream: ByteStream) -> Vec<u8> {
    let mut stream = stream.into_inner();
    let mut body = Vec::new();
    while body.len() < MAX_ERROR_BODY {
        match stream.next().await {
            Some(Ok(chunk)) => append_capped(&mut body, &chunk),
            _ => break,
        }
    }
    body
}

fn append_capped(body: &mut Vec<u8>, chunk: &[u8]) {
    let room = MAX_ERROR_BODY.saturating_sub(body.len());
    body.extend_from_slice(&chunk[..chunk.len().min(room)]);
}
