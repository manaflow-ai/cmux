//! `cmux env`'s way to the session daemon's `cloud-environment` op, with an install token the app
//! mints for this run (`auth.token`).

use std::io::{BufRead as _, BufReader, Write as _};
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};
use zeroize::{Zeroize as _, Zeroizing};

use super::super::GlobalArgs;
use super::ops::Failure;

/// The app bounds a mint at 25 s (auth_token.rs); the daemon's platform call at 30 s.
const MINT_TIMEOUT: Duration = Duration::from_secs(30);
const REPLY_TIMEOUT: Duration = Duration::from_secs(45);
const REQUEST_ID: &str = "cmux-env";

/// One `cloud-environment` action: the daemon's `data`, or its refusal.
pub(super) trait Daemon {
    fn call(&mut self, action: &str, params: &Value) -> Result<Value, Failure>;
}

/// Zeroes every string in `value` (a request that carried a token or a secret's value).
pub(super) fn wipe(value: &mut Value) {
    match value {
        Value::String(text) => text.zeroize(),
        Value::Array(items) => items.iter_mut().for_each(wipe),
        Value::Object(fields) => fields.values_mut().for_each(wipe),
        _ => {}
    }
}

/// The session daemon, with this run's install token and the platform that accepts it.
pub(super) struct Live {
    socket: PathBuf,
    derived: bool,
    platform: String,
    token: Zeroizing<String>,
}

impl Live {
    /// Finds the session daemon and asks the app for an install token.
    pub(super) fn connect(global: &GlobalArgs) -> Result<Self, Failure> {
        if global.machine.is_some() {
            return Err(Failure::new(
                "usage.invalid",
                "cmux env runs on this machine; drop --machine",
                2,
            ));
        }
        let (socket, derived) =
            super::super::wire::resolve_socket_with_origin(global).map_err(|error| {
                Failure::new(
                    "socket.no_daemon",
                    super::super::wire::resolve_failure_message(&error),
                    3,
                )
            })?;
        let (platform, token) = mint(global)?;
        Ok(Self { socket, derived, platform, token })
    }
}

/// `auth.token` from the app: the token and the platform of the API that issued it.
fn mint(global: &GlobalArgs) -> Result<(String, Zeroizing<String>), Failure> {
    let mut stream = super::super::app::connect_command(global).map_err(|error| {
        let message =
            error.get("message").and_then(Value::as_str).unwrap_or("the cmux app is not running");
        Failure::new(
            "app.unreachable",
            format!("{message}: cmux env needs the signed-in cmux app"),
            3,
        )
    })?;
    let mut answer =
        match super::super::app::request(&mut stream, "auth.token", json!({}), MINT_TIMEOUT) {
            Ok(Ok(answer)) => answer,
            Ok(Err(error)) => {
                let code = error.get("code").and_then(Value::as_str).unwrap_or("app.failed");
                let message = match code {
                    "not_signed_in" => "sign in to cmux first (`cmux login`)".to_owned(),
                    "no_team" => "choose a team in the cmux app first".to_owned(),
                    _ => error
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("the app refused")
                        .to_owned(),
                };
                return Err(Failure::new(code, message, 3));
            }
            Err(message) => return Err(Failure::new("app.transport", message, 3)),
        };
    let token = answer
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .map(|t| Zeroizing::new(t.to_owned()));
    let platform = answer.get("api_origin").and_then(Value::as_str).and_then(platform_for);
    wipe(&mut answer);
    match (token, platform) {
        (Some(token), Some(platform)) => Ok((platform, token)),
        (None, _) => Err(Failure::new("app.invalid_response", "the app answered no token", 1)),
        (_, None) => Err(Failure::new(
            "env.unknown_backend",
            "the app is signed in to a Cloud backend cmux env does not know (a preview?)",
            1,
        )),
    }
}

/// The platform that accepts a token the API at `api_origin` issued: one of the three
/// deployments, or the local development stack's.
pub(super) fn platform_for(api_origin: &str) -> Option<String> {
    use cmux_cloud_environment::LOCAL_DEPLOYMENT;
    let origin = api_origin.trim().trim_end_matches('/');
    acpmux::hosted_mcp::platform_for_issuer(origin).map(str::to_owned).or_else(|| {
        (origin == LOCAL_DEPLOYMENT.api_origin).then(|| LOCAL_DEPLOYMENT.platform_origin.to_owned())
    })
}

impl Daemon for Live {
    fn call(&mut self, action: &str, params: &Value) -> Result<Value, Failure> {
        let unreachable = |error: std::io::Error| {
            Failure::new("socket.unreachable", format!("cannot reach the cmux session: {error}"), 3)
        };
        let stream = cmux_tui_core::server::connect_session_socket(&self.socket, self.derived)
            .map_err(unreachable)?;
        let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
        let _ = stream.set_read_timeout(Some(REPLY_TIMEOUT));
        let mut reader = BufReader::new(stream);
        let mut request = json!({
            "id": REQUEST_ID,
            "cmd": "cloud-environment",
            "action": action,
            "params": params,
            "platform_origin": self.platform,
            "access_token": self.token.as_str(),
        });
        // No launch credential: the op's params take no unknown field, and a local user is enough.
        let mut bytes = Zeroizing::new(Vec::with_capacity(4096));
        let encoded = serde_json::to_writer(&mut *bytes, &request);
        wipe(&mut request);
        encoded.map_err(|error| Failure::new("env.encode", error.to_string(), 1))?;
        bytes.push(b'\n');
        reader.get_mut().write_all(&bytes).map_err(unreachable)?;
        drop(bytes);
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).map_err(unreachable)? == 0 {
                return Err(Failure::new(
                    "socket.closed",
                    "the cmux session closed the connection",
                    3,
                ));
            }
            let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
            if reply.get("id").and_then(Value::as_str) == Some(REQUEST_ID) {
                return answer(reply);
            }
        }
    }
}

/// The daemon's reply as the answer or a failure. Its messages are the daemon's own: it never
/// forwards an upstream message (environments.rs `refused`).
pub(super) fn answer(reply: Value) -> Result<Value, Failure> {
    if reply.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(reply.get("data").cloned().unwrap_or(Value::Null));
    }
    let code = reply.get("error_code").and_then(Value::as_str).unwrap_or("env.failed");
    let message = reply.get("error").and_then(Value::as_str).unwrap_or("the cmux session refused");
    let message = match reply.get("reason").and_then(Value::as_str) {
        Some("forbidden") => {
            format!("{message} (update the cmux app: its session is older than cmux env)")
        }
        _ => message.to_owned(),
    };
    Err(Failure::new(code, message, 1))
}
