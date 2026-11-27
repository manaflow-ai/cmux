//! Maps client failures to a message and an exit code (see [`crate::exit`]).

use std::io::Write;

use cmux_vm_client::{ByteStream, Error};
use futures::StreamExt;
use serde_json::{Value, json};

use crate::exit;

static IN_CMUX: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The program name errors and hints use: `cmux vm` when cmux runs this in
/// process (an agent types that; `cmux-vm` is usually not on PATH), else
/// `cmux-vm`.
pub fn program() -> &'static str {
    if IN_CMUX.load(std::sync::atomic::Ordering::Relaxed) {
        "cmux vm"
    } else {
        "cmux-vm"
    }
}

/// Sets [`program`] from argv[0] (`cmux vm` from cmux's in-process call).
pub(crate) fn set_program(argv0: Option<&std::ffi::OsStr>) {
    let in_cmux = program_for(argv0) == "cmux vm";
    IN_CMUX.store(in_cmux, std::sync::atomic::Ordering::Relaxed);
}

fn program_for(argv0: Option<&std::ffi::OsStr>) -> &'static str {
    if argv0.is_some_and(|name| name == "cmux vm") {
        "cmux vm"
    } else {
        "cmux-vm"
    }
}

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

    pub fn conflict(message: impl Into<String>) -> Self {
        Self::local(exit::CONFLICT, message)
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
            exit::CONFLICT => "Conflict",
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

    /// What went wrong, for a message that wraps it.
    pub fn message(&self) -> &str {
        &self.message
    }

    /// For HTTP 429, the budget the server named, if any.
    pub fn budget(&self) -> Option<&str> {
        self.budget.as_deref()
    }

    /// The HTTP status, for an API error.
    pub fn status(&self) -> Option<u16> {
        self.status
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

    /// A 404 says what was not found and how to list them, unless the
    /// message already names a next step.
    pub fn with_not_found(mut self, what: &str, list: &str) -> Self {
        if self.status == Some(404) && !self.message.contains("next: `") {
            self.message = format!(
                "{what} not found ({}); next: `{} {list}`",
                self.message,
                program()
            );
        }
        self
    }

    pub fn with_recovery(mut self, recovery: &str) -> Self {
        self.message.push_str("; ");
        self.message.push_str(recovery);
        self
    }

    /// Add the VM and operation to an error from a VM-scoped command.
    pub fn for_vm(mut self, vm_id: &str, operation: &str) -> Self {
        let next = match operation {
            "client-session create" => format!(
                "{p} client-session list {vm_id}",
                p = crate::error::program()
            ),
            "client-session list" | "client-session revoke" => {
                format!(
                    "{p} client-session list {vm_id}",
                    p = crate::error::program()
                )
            }
            // A 404 means the VM itself is gone, so `get` would fail too.
            _ if self.status == Some(404) => format!("{p} list", p = crate::error::program()),
            _ => format!("{p} get {vm_id}", p = crate::error::program()),
        };
        self.message = format!(
            "VM {vm_id} {operation} failed: {}; next: `{next}`",
            self.message
        );
        // A 4xx means the server refused before minting; any other failure
        // (network, 5xx, a cut-off body) may have minted a session.
        let refused = matches!(self.status, Some(400..=499));
        if operation == "client-session create" && !refused {
            self.message
                .push_str("; revoke any newly created session before retrying");
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
                "could not reach the cmux VM API: {e}; check your network; run `{p} list` to check connectivity",
                p = program()
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

    pub(crate) fn from_status(status: u16, body: &[u8]) -> Self {
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
            message.push_str(&format!(
                "; check the command's flags and run `{} --help`",
                program()
            ));
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
                    writeln!(
                        stderr,
                        "{p}: {} (HTTP {status} {tag})",
                        self.message,
                        p = crate::error::program()
                    )
                }
                (Some(status), None) => {
                    writeln!(
                        stderr,
                        "{p}: {} (HTTP {status})",
                        self.message,
                        p = crate::error::program()
                    )
                }
                _ => writeln!(stderr, "{p}: {}", self.message, p = crate::error::program()),
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
        writeln!(
            stderr,
            "{p}: warning: {message}",
            p = crate::error::program()
        )
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_program_name_follows_argv0() {
        assert_eq!(
            program_for(Some(std::ffi::OsStr::new("cmux vm"))),
            "cmux vm"
        );
        assert_eq!(
            program_for(Some(std::ffi::OsStr::new("cmux-vm"))),
            "cmux-vm"
        );
        assert_eq!(
            program_for(Some(std::ffi::OsStr::new("/usr/local/bin/cmux-vm"))),
            "cmux-vm"
        );
        assert_eq!(program_for(None), "cmux-vm");
        // Tests never call set_program, so errors read cmux-vm here.
        let mut out = Vec::new();
        CliError::usage("bad").report(false, &mut out);
        assert_eq!(String::from_utf8(out).unwrap(), "cmux-vm: bad\n");
    }

    #[test]
    fn a_404_names_what_was_not_found_and_how_to_list_them() {
        let error = CliError::from_status(404, b"").with_not_found("VM vm_x", "list");
        assert!(
            error.message().starts_with("VM vm_x not found ("),
            "{}",
            error.message()
        );
        assert!(error.message().ends_with("list`"), "{}", error.message());
        // Other statuses, and a message that already names a next step, are kept.
        let kept = CliError::from_status(409, b"").with_not_found("VM vm_x", "list");
        assert!(!kept.message().contains("not found"));
        let scoped = CliError::from_status(404, b"").for_vm("vm_x", "get");
        let before = scoped.message().to_owned();
        assert_eq!(scoped.with_not_found("VM vm_x", "list").message(), before);
    }

    #[test]
    fn vm_errors_preserve_server_details_and_status() {
        for (status, body, fragments) in [
            (403, json!({"scope":"vm:exec"}), vec!["vm:exec"]),
            (
                400,
                json!({"field":"linuxUser", "message":"invalid user", "action":"choose root"}),
                vec!["linuxUser", "invalid user", "choose root"],
            ),
            (409, json!({"state":"paused"}), vec!["paused"]),
            (404, json!({}), vec!["cmux-vm list"]),
        ] {
            let error = CliError::from_status(status, &serde_json::to_vec(&body).unwrap())
                .for_vm("vm_example", "exec");
            assert_eq!(error.exit_code(), exit::for_status(status));
            assert!(error.message.contains("VM vm_example exec failed"));
            for fragment in fragments {
                assert!(error.message.contains(fragment), "{}", error.message);
            }
            assert!(!error.message.contains("cmux-vm ls"));
        }
    }

    #[test]
    fn fork_recovery_preserves_the_original_idempotency_key() {
        let error = CliError::network("connection closed")
            .with_idempotency_hint("original-key")
            .for_vm("vm_example", "fork");
        assert!(error.message.contains("--idempotency-key original-key"));
        assert!(error.message.contains("cmux-vm get vm_example"));
        assert!(!error.message.contains("cmux-vm fork"));
    }
}
