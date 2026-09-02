//! Forward agent journal events from this machine to the Mac that owns it.
//!
//! On a cmux Cloud machine the owner's Mac listens on its private-network
//! address for notifications (`VMHostListenerCoordinator` in the Mac app). It
//! writes `/etc/cmux/host.env` here (`CMUX_HOST_ENDPOINT`, `CMUX_HOST_TOKEN`,
//! `CMUX_HOST_WORKSPACE_ID`) and registers a journal hook on this daemon whose
//! argv is `cmux-tui host-forward`. The dispatcher runs that command once per
//! matching `agent.*` event, with the hook envelope on stdin and an empty
//! environment, so everything this command needs comes from the env file and
//! stdin.
//!
//! Each event becomes the Mac's own control-socket verbs: `workspace.status.set`
//! moves the bound workspace's status lane, and `notification.create` raises a
//! notification when the agent finished or needs the human. Requests carry the
//! per-machine token the Mac minted; the Mac admits only these verbs from a
//! machine and only for workspaces bound to it.
//!
//! Exit status is the retry contract with the dispatcher: 0 means delivered or
//! nothing to do (the Mac turned forwarding off, or the Mac answered with a
//! definitive error that a retry cannot fix); 1 means the Mac was unreachable,
//! so the dispatcher retries with its backoff.

use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, anyhow, bail};
use serde_json::{Map, Value, json};

/// Where the Mac installs the endpoint file on a machine.
pub(crate) const DEFAULT_ENV_PATH: &str = "/etc/cmux/host.env";
/// The journal hook id the Mac registers for this command.
pub(crate) const HOOK_ID: &str = "cmux_host_forward";
/// The Mac-side parameter that carries the machine token.
const TOKEN_PARAM: &str = "_cmux_vm_host_token";
/// Longest hook envelope this command reads before refusing it.
const MAX_ENVELOPE_BYTES: u64 = 1024 * 1024;
/// Longest notification body sent to the Mac.
const MAX_BODY_CHARS: usize = 500;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(4);
const IO_TIMEOUT: Duration = Duration::from_secs(6);
const MAX_RESPONSE_BYTES: usize = 64 * 1024;

/// Journal event kinds the hook subscribes to. Mirrors the agent status
/// reducer's vocabulary (`agent_state_for_hook_kind` in cmux-tui-core).
pub(crate) const FORWARDED_KINDS: [&str; 7] = [
    "agent.turn.started",
    "agent.turn.completed",
    "agent.approval.requested",
    "agent.question.requested",
    "agent.plan_review.requested",
    "agent.error.reported",
    "agent.session.ended",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Plan {
    pub env_file: Option<PathBuf>,
    pub print_manifest: Option<String>,
}

/// The endpoint file the Mac wrote. An empty or missing endpoint means the
/// Mac has forwarding off; that is not an error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HostEnv {
    pub endpoint: Option<String>,
    pub token: String,
    pub workspace_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Request {
    pub method: &'static str,
    pub params: Map<String, Value>,
}

/// The manifest the Mac puts on a machine's daemon. `binary` is the guest path
/// of cmux-tui (argv[0] must be absolute).
pub(crate) fn hook_manifest(binary: &str) -> Value {
    json!({
        "hook_id": HOOK_ID,
        "manifest_version": 1,
        "filter": { "kinds": FORWARDED_KINDS },
        "exec": { "argv": [binary, "host-forward"], "timeout_ms": 15_000, "max_parallel": 2 },
        "delivery": { "start": "tail", "retry": { "max_attempts": 3, "backoff_ms": 2_000 } },
        "permissions": ["journal.read"],
    })
}

pub(crate) fn parse_host_env(text: &str) -> anyhow::Result<HostEnv> {
    let mut endpoint = None;
    let mut token = None;
    let mut workspace_id = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            bail!("host env line has no '=': {line:?}");
        };
        let value = value.trim().trim_matches('"').trim_matches('\'').to_string();
        let value = (!value.is_empty()).then_some(value);
        match key.trim() {
            "CMUX_HOST_ENDPOINT" => endpoint = value,
            "CMUX_HOST_TOKEN" => token = value,
            "CMUX_HOST_WORKSPACE_ID" => workspace_id = value,
            _ => {}
        }
    }
    Ok(HostEnv { endpoint, token: token.unwrap_or_default(), workspace_id })
}

/// Human name for a hook adapter id (`payload.adapter`).
fn agent_display_name(adapter: &str) -> String {
    match adapter {
        "claude-code" | "claude" => "Claude Code".into(),
        "codex" => "Codex".into(),
        "cursor" => "Cursor".into(),
        "gemini" => "Gemini".into(),
        "grok" => "Grok".into(),
        "opencode" => "OpenCode".into(),
        "pi" => "Pi".into(),
        "hermes" => "Hermes".into(),
        "" => "Agent".into(),
        other => other.to_string(),
    }
}

fn truncate_chars(text: &str, limit: usize) -> String {
    let mut out: String = text.chars().take(limit).collect();
    if out.len() < text.len() {
        out.push('…');
    }
    out
}

/// Turn one hook envelope into Mac requests. Pure, so the mapping is testable
/// without a socket. Unknown kinds produce no requests.
pub(crate) fn plan_requests(envelope: &Value, env: &HostEnv) -> anyhow::Result<Vec<Request>> {
    let event = envelope.get("event").ok_or_else(|| anyhow!("hook envelope has no event"))?;
    let kind = event.get("kind").and_then(Value::as_str).unwrap_or_default();
    let payload = event.get("payload").cloned().unwrap_or(Value::Null);
    let adapter = payload.get("adapter").and_then(Value::as_str).unwrap_or_default();
    let normalized = payload.get("normalized").cloned().unwrap_or(Value::Null);
    let message = normalized
        .get("message")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(|text| truncate_chars(text, MAX_BODY_CHARS));
    let agent = agent_display_name(adapter);

    let (status, notification): (Option<&str>, Option<(String, String)>) = match kind {
        "agent.turn.started" => (Some("working"), None),
        "agent.turn.completed" => (
            Some("review"),
            Some((format!("{agent} finished"), message.clone().unwrap_or_else(|| "Turn completed".into()))),
        ),
        "agent.approval.requested" => (
            Some("needs-attention"),
            Some((format!("{agent} needs approval"), message.clone().unwrap_or_else(|| "Waiting for your approval".into()))),
        ),
        "agent.question.requested" => (
            Some("needs-attention"),
            Some((format!("{agent} asked a question"), message.clone().unwrap_or_else(|| "Waiting for your answer".into()))),
        ),
        "agent.plan_review.requested" => (
            Some("needs-attention"),
            Some((format!("{agent} wants a plan review"), message.clone().unwrap_or_else(|| "Waiting for your review".into()))),
        ),
        "agent.error.reported" => (
            Some("needs-attention"),
            Some((format!("{agent} reported an error"), message.clone().unwrap_or_else(|| "The agent hit an error".into()))),
        ),
        // The session is gone: hand the lane back to the Mac's own inference.
        "agent.session.ended" => (Some("auto"), None),
        _ => (None, None),
    };

    let mut requests = Vec::new();
    let base = |env: &HostEnv| -> Map<String, Value> {
        let mut params = Map::new();
        params.insert(TOKEN_PARAM.into(), Value::String(env.token.clone()));
        if let Some(workspace) = &env.workspace_id {
            params.insert("workspace_id".into(), Value::String(workspace.clone()));
        }
        params
    };
    if let Some(status) = status {
        let mut params = base(env);
        params.insert("status".into(), Value::String(status.into()));
        requests.push(Request { method: "workspace.status.set", params });
    }
    if let Some((title, body)) = notification {
        let mut params = base(env);
        params.insert("title".into(), Value::String(title));
        params.insert("body".into(), Value::String(body));
        requests.push(Request { method: "notification.create", params });
    }
    Ok(requests)
}

/// One response line from the Mac, already parsed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Delivered {
    Ok,
    /// The Mac answered with an error. Retrying the same request cannot help.
    Rejected { code: String, message: String },
}

fn parse_endpoint(endpoint: &str) -> anyhow::Result<SocketAddr> {
    endpoint
        .parse::<SocketAddr>()
        .with_context(|| format!("CMUX_HOST_ENDPOINT {endpoint:?} is not host:port"))
}

/// Send every request on one connection, one JSON line each, and read one
/// response line per request. A transport error is returned as `Err` so the
/// caller can exit non-zero and let the dispatcher retry.
pub(crate) fn deliver(endpoint: &str, requests: &[Request]) -> anyhow::Result<Vec<Delivered>> {
    let address = parse_endpoint(endpoint)?;
    let stream = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT)
        .with_context(|| format!("connect to Mac at {endpoint}"))?;
    stream.set_read_timeout(Some(IO_TIMEOUT))?;
    stream.set_write_timeout(Some(IO_TIMEOUT))?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    let mut outcomes = Vec::with_capacity(requests.len());
    for (index, request) in requests.iter().enumerate() {
        let line = json!({
            "id": format!("host-forward-{}", index + 1),
            "method": request.method,
            "params": request.params,
        });
        let mut bytes = serde_json::to_vec(&line)?;
        bytes.push(b'\n');
        writer.write_all(&bytes).context("write request to Mac")?;
        writer.flush()?;
        let mut response = Vec::new();
        let read = (&mut reader)
            .take(MAX_RESPONSE_BYTES as u64)
            .read_until(b'\n', &mut response)
            .context("read response from Mac")?;
        if read == 0 {
            bail!("Mac closed the connection before answering");
        }
        let value: Value = serde_json::from_slice(&response).context("parse Mac response")?;
        let ok = value.get("ok").and_then(Value::as_bool).unwrap_or(false);
        if ok {
            outcomes.push(Delivered::Ok);
        } else {
            let error = value.get("error").cloned().unwrap_or(Value::Null);
            outcomes.push(Delivered::Rejected {
                code: error.get("code").and_then(Value::as_str).unwrap_or("unknown").to_string(),
                message: error.get("message").and_then(Value::as_str).unwrap_or_default().to_string(),
            });
        }
    }
    Ok(outcomes)
}

fn read_envelope(mut input: impl Read) -> anyhow::Result<Value> {
    let mut bytes = Vec::new();
    input.by_ref().take(MAX_ENVELOPE_BYTES + 1).read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() as u64 <= MAX_ENVELOPE_BYTES, "hook envelope exceeds {MAX_ENVELOPE_BYTES} bytes");
    serde_json::from_slice(&bytes).context("hook envelope is not JSON")
}

/// Outcome of one run, printed as the command's JSON result.
pub(crate) fn run_with(env_path: &Path, input: impl Read) -> anyhow::Result<Value> {
    let env = match fs::read_to_string(env_path) {
        Ok(text) => parse_host_env(&text)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(json!({ "forwarded": false, "reason": "no_host_env" }));
        }
        Err(error) => return Err(error).with_context(|| format!("read {}", env_path.display())),
    };
    let Some(endpoint) = env.endpoint.clone() else {
        return Ok(json!({ "forwarded": false, "reason": "forwarding_off" }));
    };
    if env.token.is_empty() {
        return Ok(json!({ "forwarded": false, "reason": "no_token" }));
    }
    let envelope = read_envelope(input)?;
    let requests = plan_requests(&envelope, &env)?;
    if requests.is_empty() {
        return Ok(json!({ "forwarded": false, "reason": "kind_not_forwarded" }));
    }
    let outcomes = deliver(&endpoint, &requests)?;
    let rejected: Vec<Value> = outcomes
        .iter()
        .zip(requests.iter())
        .filter_map(|(outcome, request)| match outcome {
            Delivered::Ok => None,
            Delivered::Rejected { code, message } => {
                Some(json!({ "method": request.method, "code": code, "message": message }))
            }
        })
        .collect();
    Ok(json!({
        "forwarded": true,
        "endpoint": endpoint,
        "requests": requests.iter().map(|request| request.method).collect::<Vec<_>>(),
        "rejected": rejected,
    }))
}

pub(crate) fn run(plan: &Plan) -> anyhow::Result<Value> {
    if let Some(binary) = &plan.print_manifest {
        return Ok(hook_manifest(binary));
    }
    let path = plan.env_file.clone().unwrap_or_else(|| PathBuf::from(DEFAULT_ENV_PATH));
    run_with(&path, io::stdin().lock())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::net::TcpListener;
    use std::thread;

    fn env() -> HostEnv {
        HostEnv {
            endpoint: Some("127.0.0.1:1".into()),
            token: "tok".into(),
            workspace_id: Some("11111111-2222-3333-4444-555555555555".into()),
        }
    }

    fn envelope(kind: &str, adapter: &str, message: Option<&str>) -> Value {
        let mut normalized = Map::new();
        if let Some(message) = message {
            normalized.insert("message".into(), Value::String(message.into()));
        }
        json!({
            "protocol_version": 1,
            "delivery": { "hook_id": HOOK_ID, "manifest_version": 1, "attempt": 1 },
            "event": {
                "kind": kind,
                "subjects": [{ "kind": "terminal", "id": "term_1" }],
                "payload": { "adapter": adapter, "normalized": normalized },
            }
        })
    }

    #[test]
    fn parses_env_file_and_treats_empty_endpoint_as_off() {
        let parsed = parse_host_env(
            "# written by the Mac\nCMUX_HOST_ENDPOINT=[fd00::1]:4321\nCMUX_HOST_TOKEN=\"abc\"\nCMUX_HOST_WORKSPACE_ID=ws\n",
        )
        .unwrap();
        assert_eq!(
            parsed,
            HostEnv { endpoint: Some("[fd00::1]:4321".into()), token: "abc".into(), workspace_id: Some("ws".into()) }
        );
        let off = parse_host_env("CMUX_HOST_ENDPOINT=\nCMUX_HOST_TOKEN=abc\n").unwrap();
        assert_eq!(off.endpoint, None);
        assert!(parse_host_env("garbage").is_err());
    }

    #[test]
    fn turn_completed_sets_review_and_notifies_with_message() {
        let requests = plan_requests(&envelope("agent.turn.completed", "claude-code", Some("Done: 3 files")), &env()).unwrap();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0].method, "workspace.status.set");
        assert_eq!(requests[0].params["status"], "review");
        assert_eq!(requests[0].params[TOKEN_PARAM], "tok");
        assert_eq!(requests[0].params["workspace_id"], "11111111-2222-3333-4444-555555555555");
        assert_eq!(requests[1].method, "notification.create");
        assert_eq!(requests[1].params["title"], "Claude Code finished");
        assert_eq!(requests[1].params["body"], "Done: 3 files");
        assert_eq!(requests[1].params[TOKEN_PARAM], "tok");
    }

    #[test]
    fn attention_kinds_set_needs_attention_and_notify() {
        for kind in ["agent.approval.requested", "agent.question.requested", "agent.plan_review.requested", "agent.error.reported"] {
            let requests = plan_requests(&envelope(kind, "codex", None), &env()).unwrap();
            assert_eq!(requests[0].params["status"], "needs-attention", "{kind}");
            assert_eq!(requests[1].method, "notification.create", "{kind}");
            assert!(requests[1].params["title"].as_str().unwrap().starts_with("Codex "), "{kind}");
        }
    }

    #[test]
    fn turn_started_only_moves_the_lane_and_session_end_releases_it() {
        let started = plan_requests(&envelope("agent.turn.started", "codex", None), &env()).unwrap();
        assert_eq!(started.len(), 1);
        assert_eq!(started[0].params["status"], "working");
        let ended = plan_requests(&envelope("agent.session.ended", "codex", None), &env()).unwrap();
        assert_eq!(ended.len(), 1);
        assert_eq!(ended[0].params["status"], "auto");
        assert!(plan_requests(&envelope("agent.tool.started", "codex", None), &env()).unwrap().is_empty());
    }

    #[test]
    fn manifest_is_a_valid_journal_hook_manifest() {
        let manifest: cmux_tui_core::JournalHookManifest =
            serde_json::from_value(hook_manifest("/usr/local/bin/cmux-tui")).unwrap();
        assert_eq!(manifest.hook_id, HOOK_ID);
        assert_eq!(manifest.exec.argv, vec!["/usr/local/bin/cmux-tui", "host-forward"]);
        assert_eq!(manifest.filter.kinds, FORWARDED_KINDS.iter().map(|kind| kind.to_string()).collect::<Vec<_>>());
        assert_eq!(manifest.delivery.start, "tail");
        assert!(manifest.permissions.iter().any(|permission| permission == "journal.read"));
    }

    #[test]
    fn deliver_sends_one_line_per_request_and_reads_each_reply() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut writer = stream;
            let mut lines = Vec::new();
            for index in 0..2 {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                lines.push(request.clone());
                let reply = if index == 0 {
                    json!({ "id": request["id"], "ok": true, "result": {} })
                } else {
                    json!({ "id": request["id"], "ok": false, "error": { "code": "vm_host_workspace_denied", "message": "nope" } })
                };
                writer.write_all(format!("{reply}\n").as_bytes()).unwrap();
            }
            lines
        });
        let env = HostEnv { endpoint: Some(address.to_string()), ..env() };
        let requests = plan_requests(&envelope("agent.turn.completed", "codex", None), &env).unwrap();
        let outcomes = deliver(&address.to_string(), &requests).unwrap();
        assert_eq!(outcomes[0], Delivered::Ok);
        assert_eq!(
            outcomes[1],
            Delivered::Rejected { code: "vm_host_workspace_denied".into(), message: "nope".into() }
        );
        let received = server.join().unwrap();
        assert_eq!(received[0]["method"], "workspace.status.set");
        assert_eq!(received[0]["params"][TOKEN_PARAM], "tok");
        assert_eq!(received[1]["method"], "notification.create");
    }

    #[test]
    fn run_with_reports_off_without_dialing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("host.env");
        fs::write(&path, "CMUX_HOST_ENDPOINT=\nCMUX_HOST_TOKEN=tok\n").unwrap();
        let result = run_with(&path, Cursor::new(b"{}".to_vec())).unwrap();
        assert_eq!(result["reason"], "forwarding_off");
        let missing = run_with(&dir.path().join("absent"), Cursor::new(b"{}".to_vec())).unwrap();
        assert_eq!(missing["reason"], "no_host_env");
    }

    #[test]
    fn unreachable_mac_is_a_transport_error() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("host.env");
        fs::write(&path, format!("CMUX_HOST_ENDPOINT={address}\nCMUX_HOST_TOKEN=tok\nCMUX_HOST_WORKSPACE_ID=ws\n")).unwrap();
        let body = serde_json::to_vec(&envelope("agent.turn.completed", "codex", None)).unwrap();
        assert!(run_with(&path, Cursor::new(body)).is_err());
    }
}
