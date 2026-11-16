//! `carrier supervise`'s lines, both ways, and the serve child's stderr
//! lines it reads ([`super::supervise`] has the contract).

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde_json::{Value, json};

use super::serve_machine::{Caller, ChildId, Env, Event, LinkError, ReadId, TokenRead, WaiterId};

/// One line from the app, read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AppLine {
    Connect {
        waiter: WaiterId,
        keep_refusal: bool,
    },
    Park,
    Stop,
    AccountEnded,
    /// The answer to a `read_token` line.
    Token {
        read: ReadId,
        result: TokenRead,
    },
}

/// The app's line, or None for anything else (it is skipped).
pub(crate) fn app_line(text: &str) -> Option<AppLine> {
    let value: Value = serde_json::from_str(text).ok()?;
    if let Some(waiter) = value.get("connect").and_then(Value::as_u64) {
        let keep_refusal = value.get("keep_refusal").and_then(Value::as_bool).unwrap_or(false);
        return Some(AppLine::Connect { waiter, keep_refusal });
    }
    if value.get("park").is_some() {
        return Some(AppLine::Park);
    }
    if value.get("stop").is_some() {
        return Some(AppLine::Stop);
    }
    if value.get("account_ended").is_some() {
        return Some(AppLine::AccountEnded);
    }
    let read = value.get("token").and_then(Value::as_u64)?;
    let result = if value.get("fenced").and_then(Value::as_bool) == Some(true) {
        TokenRead::Fenced
    } else if let Some(env) = value.get("env").and_then(Value::as_object) {
        TokenRead::Ok(
            env.iter()
                .filter_map(|(key, value)| Some((key.clone(), value.as_str()?.to_owned())))
                .collect::<Env>(),
        )
    } else {
        TokenRead::Failed(value.get("error").and_then(error_of).unwrap_or_else(|| {
            LinkError::helper_not_running("cmux carrier serve has no access token")
        }))
    };
    Some(AppLine::Token { read, result })
}

/// An error on the wire: `{"kind":…, …}`, the app's `CloudLinkError` case and
/// its fields.
pub(crate) fn error_json(error: &LinkError) -> Value {
    match error {
        LinkError::Disconnected { reason } => json!({"kind": "disconnected", "reason": reason}),
        LinkError::Revoked { reason } => json!({"kind": "revoked", "reason": reason}),
        LinkError::HelperNotRunning { reason } => {
            json!({"kind": "helper_not_running", "reason": reason})
        }
        LinkError::UnsafeSocket(detail) => json!({"kind": "unsafe_socket", "detail": detail}),
        LinkError::OpenDirectory { path, parent } => {
            json!({"kind": "open_directory", "path": path, "parent": parent})
        }
        LinkError::InvalidAnswer(detail) => json!({"kind": "invalid_answer", "detail": detail}),
        LinkError::NotUp { state } => json!({"kind": "not_up", "state": state}),
        LinkError::Failed { code, message } => {
            json!({"kind": "failed", "code": code, "message": message})
        }
        LinkError::Unsupported => json!({"kind": "unsupported"}),
    }
}

/// [`error_json`] read back; None for a kind it does not name.
pub(crate) fn error_of(value: &Value) -> Option<LinkError> {
    let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    Some(match value.get("kind")?.as_str()? {
        "disconnected" => LinkError::Disconnected { reason: text("reason") },
        "revoked" => LinkError::Revoked { reason: text("reason") },
        "helper_not_running" => LinkError::HelperNotRunning { reason: text("reason") },
        "unsafe_socket" => LinkError::UnsafeSocket(text("detail")),
        "open_directory" => LinkError::OpenDirectory {
            path: text("path"),
            parent: value.get("parent").and_then(Value::as_bool).unwrap_or(false),
        },
        "invalid_answer" => LinkError::InvalidAnswer(text("detail")),
        "not_up" => LinkError::NotUp { state: text("state") },
        "failed" => LinkError::Failed { code: text("code"), message: text("message") },
        "unsupported" => LinkError::Unsupported,
        _ => return None,
    })
}

/// The longest `log` line text, in characters.
pub(crate) const LOG_MAX: usize = 400;

/// A run of token characters this long is taken for a credential and left
/// out of a `log` line (a JWT or key is far longer; paths, ids and words are
/// shorter).
const SECRET_RUN: usize = 40;

/// `{"log":TEXT}`: one link step (a connect, a child's start or exit, the
/// socket ready, a refusal), which the app writes to its unified log as one
/// persisted line (subsystem `com.cmuxterm.app.next`, category
/// `cloud.carrier`), so a release build's link failure can be read with
/// `log show`. Once per step, never per frame or byte; the text is one line,
/// at most [`LOG_MAX`] characters, with any credential-shaped run replaced
/// by `[redacted]`.
pub(crate) fn log_line(text: &str) -> String {
    json!({ "log": log_text(text) }).to_string()
}

/// `text` as a `log` line holds it: one line, bounded, no credential.
pub(crate) fn log_text(text: &str) -> String {
    // A run takes `/` too (standard base64), except at its start, so an
    // absolute path stays readable.
    fn flush(run: &mut String, out: &mut String) {
        if run.chars().count() >= SECRET_RUN && !run.starts_with('/') {
            out.push_str("[redacted]");
        } else {
            out.push_str(run);
        }
        run.clear();
    }
    let mut out = String::new();
    let mut run = String::new();
    for c in text.chars() {
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '+' | '=' | '/') {
            run.push(c);
            continue;
        }
        flush(&mut run, &mut out);
        out.push(if c.is_control() { ' ' } else { c });
    }
    flush(&mut run, &mut out);
    if out.chars().count() > LOG_MAX {
        out = out.chars().take(LOG_MAX - 1).collect();
        out.push('…');
    }
    out
}

/// `{"read_token":R}`: the app answers with a `token` line.
pub(crate) fn read_token_line(read: ReadId) -> String {
    json!({ "read_token": read }).to_string()
}

/// `{"resume":[W…],"socket":S}` or `{"resume":[W…],"error":E}`.
pub(crate) fn resume_line(waiters: &[WaiterId], result: &Result<String, LinkError>) -> String {
    match result {
        Ok(socket) => json!({"resume": waiters, "socket": socket}),
        Err(error) => json!({"resume": waiters, "error": error_json(error)}),
    }
    .to_string()
}

/// `{"publish":"owner"|"team"|"unknown"}`: a connection's answer.
pub(crate) fn publish_line(caller: Caller) -> String {
    json!({ "publish": caller.word() }).to_string()
}

/// `{"state":{"refusal":E|null,"answer":…|null}}`: what the app reads
/// between lines.
pub(crate) fn state_line(refusal: Option<&LinkError>, answer: Option<Caller>) -> String {
    json!({"state": {"refusal": refusal.map(error_json), "answer": answer.map(Caller::word)}})
        .to_string()
}

/// The token line `carrier serve` reads on stdin.
pub(crate) fn token_line(token: &str) -> String {
    let mut line = json!({ "access_token": token }).to_string();
    line.push('\n');
    line
}

/// One stderr line of `child` as its event: the ready line (checked with
/// `check`), a connection's `ok` line, or a refusal. None for anything else.
pub(crate) fn serve_event(
    child: ChildId,
    text: &str,
    check: fn(&str) -> Result<(), LinkError>,
) -> Option<Event> {
    let value: Value = serde_json::from_str(text).ok()?;
    let str_of = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    if value.get("ok")?.as_bool()? {
        return Some(match str_of("socket").filter(|socket| !socket.is_empty()) {
            Some(socket) => {
                let policy = check(&socket).err();
                Event::ReadyLine { child, socket, policy }
            }
            None => Event::OkLine { child, vmk: str_of("vmk") },
        });
    }
    let code = str_of("error_code")?;
    Some(Event::RefusalLine { child, code, detail: str_of("error_detail") })
}

/// When the next token line goes out after `token`: a minute before its
/// `exp`, at least 15 s on; five minutes on for a token that names no `exp`.
pub(crate) fn refresh_delay(token: &str) -> Duration {
    refresh_delay_at(token, SystemTime::now())
}

pub(crate) fn refresh_delay_at(token: &str, now: SystemTime) -> Duration {
    const NO_EXP: Duration = Duration::from_secs(300);
    let Some(exp) = jwt_exp(token) else {
        return NO_EXP;
    };
    let now = now.duration_since(UNIX_EPOCH).map_or(0.0, |since| since.as_secs_f64());
    Duration::try_from_secs_f64((exp - now - 60.0).max(15.0)).unwrap_or(NO_EXP)
}

/// A JWT's `exp` claim (seconds since the epoch).
fn jwt_exp(token: &str) -> Option<f64> {
    let payload = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    let claims: Value = serde_json::from_slice(&bytes).ok()?;
    claims.get("exp")?.as_f64()
}
