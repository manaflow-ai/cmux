//! `cmux cloud vm-agent-key-mint`: the app's `vm.agent_key.create` (what `cmux vm token create`
//! asks the app for) as one Rust call. The app holds the Stack session and the team, so it runs
//! this with them the way it runs `cmux cloud auth-handoff-relay`: one JSON request on stdin (the
//! credential never goes in argv), one JSON line out, `{ok: true, value}` or `{ok: false, error}`
//! where `error` is an [`agent_key::Refusal`] (`code`, `message`, `status`, `appText`).
//!
//! ```json
//! {"backend": {"kind": "production"}, "vmOrigin": "https://vm.cmux.dev"|null,
//!  "credential": "…", "teamId": "team_1", "params": {"ttlSeconds": 3600, "maxVms": 2}}
//! ```
//!
//! The body, its limits, the VM API for the backend and how the answer reads are
//! [`agent_key`]'s (the same rules `cmux vm token create` links); this file sends the one
//! `POST /v1/agent-keys` to the runtime selection's VM API (`vmOrigin`) or the backend's, and
//! never to another origin.

use std::io::{Read as _, Write as _};
use std::time::Duration;

use cmux_cloud_config::agent_key::{self, Refusal};
use cmux_cloud_config::config::Backend;
use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::cloud_client_session::secure_origin;

/// Largest stdin request read; a mint request is well under 1 KiB.
const MAX_INPUT: u64 = 65_536;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Envelope {
    backend: Backend,
    #[serde(default)]
    vm_origin: Option<String>,
    #[serde(default)]
    credential: Option<String>,
    #[serde(default)]
    team_id: Option<String>,
    #[serde(default)]
    params: Map<String, Value>,
}

/// `Some(exit code)` when `args` is `cloud vm-agent-key-mint`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "vm-agent-key-mint" {
        return None;
    }
    let answer = if rest.is_empty() {
        let mut input = zeroize::Zeroizing::new(Vec::new());
        match std::io::stdin().take(MAX_INPUT).read_to_end(&mut input) {
            Ok(_) => mint_blocking(&input),
            Err(_) => refused(invalid("the request could not be read")),
        }
    } else {
        refused(invalid("cmux cloud vm-agent-key-mint takes its request as JSON on stdin"))
    };
    let mut stdout = std::io::stdout().lock();
    let written = writeln!(stdout, "{answer}").and_then(|()| stdout.flush());
    Some(if written.is_ok() && answer.get("ok") == Some(&Value::Bool(true)) { 0 } else { 1 })
}

fn mint_blocking(input: &[u8]) -> Value {
    let _ = rustls::crypto::ring::default_provider().install_default();
    match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime.block_on(mint(input)),
        Err(error) => refused(internal(&error.to_string())),
    }
}

fn invalid(message: &str) -> Refusal {
    Refusal { code: "invalid_params".into(), message: message.into(), status: None, app_text: None }
}

fn internal(message: &str) -> Refusal {
    Refusal { code: "internal".into(), message: message.into(), status: None, app_text: None }
}

fn refused(refusal: Refusal) -> Value {
    json!({ "ok": false, "error": refusal })
}

/// Mints one key for the stdin request.
pub(super) async fn mint(input: &[u8]) -> Value {
    let Ok(envelope) = serde_json::from_slice::<Envelope>(input) else {
        return refused(invalid("the request is not a mint request"));
    };
    let nonblank =
        |text: Option<String>| text.map(|t| t.trim().to_owned()).filter(|t| !t.is_empty());
    let Some(credential) = nonblank(envelope.credential).map(zeroize::Zeroizing::new) else {
        return refused(Refusal {
            code: "not_signed_in".into(),
            message: "Sign in to cmux in the cmux app first.".into(),
            status: None,
            app_text: Some("notSignedIn".into()),
        });
    };
    let Some(team) = nonblank(envelope.team_id) else {
        return refused(Refusal {
            code: "no_team".into(),
            message: "Choose a cmux team in the cmux app first.".into(),
            status: None,
            app_text: None,
        });
    };
    let mut planned = match agent_key::request(&envelope.backend, &envelope.params) {
        Ok(planned) => planned,
        Err(refusal) => return refused(refusal),
    };
    // A runtime selection names its own VM API; else the one the backend names.
    if let Some(origin) = nonblank(envelope.vm_origin) {
        match secure_origin(&origin) {
            Ok(origin) => {
                planned.url = format!("{origin}/{}", agent_key::PATH);
                planned.base_url = origin;
            }
            Err(message) => return refused(internal(&message)),
        }
    }
    let (status, body) = post(&planned, &credential, &team).await;
    match agent_key::answer(status, &body, &planned.base_url, &team) {
        Ok(value) => json!({ "ok": true, "value": value }),
        Err(refusal) => refused(refusal),
    }
}

/// The POST's status and body; status 0 when nothing answered (`agent_key::answer` reads it as
/// unreachable).
async fn post(planned: &agent_key::Request, credential: &str, team: &str) -> (u16, Vec<u8>) {
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    // timeout: a VM API that never answers; the app's control method allows 25 s for the whole call.
    let timeout = Duration::from_secs(u64::from(planned.timeout_seconds));
    let Ok((_, http)) = cmux_cloud_client::http(
        &planned.base_url,
        Some(credential),
        Some(team),
        user_agent,
        timeout,
    ) else {
        return (0, Vec::new());
    };
    let Ok(response) = http.post(&planned.url).json(&planned.body).send().await else {
        return (0, Vec::new());
    };
    let status = response.status().as_u16();
    let body = response.bytes().await.map(|bytes| bytes.to_vec()).unwrap_or_default();
    (status, body)
}

#[cfg(test)]
#[path = "cloud_vm_agent_key_tests.rs"]
mod tests;
