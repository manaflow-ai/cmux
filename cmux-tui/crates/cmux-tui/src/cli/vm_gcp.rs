//! `cmux vm new --provider freestyle|gcp`: which provider makes the VM (cmuxterm-hq RFD 0016,
//! row ec576b0815). `freestyle` (or no `--provider`) is today's `cmux vm new`: the app's Cloud
//! create, or the VM API, as [`super::vm::new_route`] picks. `gcp` is our own Compute Engine
//! capacity (the CI builder pool, lanes until they move), never a customer's machine: it sends
//! `cloud.machine.create` with `kind: "fleet"` and `provider: "gcp"` straight to the cmux API,
//! headless, and CloudDO makes it only for a team its deployment's `CLOUD_GCE_TEAMS` names
//! (cmux-platform `src/server/cloud/domain/Cloud.ts` create; otherwise
//! `cloud.provider.unavailable`).
//!
//! The cmux API, the credential and the team come from `--cloud-api` (or `CMUX_CLOUD_API_URL`),
//! `--cloud-token-file` (or `CMUX_CLOUD_ACCESS_TOKEN`) and `--team` (or `CMUX_CLOUD_TEAM`), as
//! `cmux cloud team-keys` takes them. The flags only the app's create or the VM API's takes are
//! refused with `--provider gcp`: neither of those makes a GCE machine.

use std::path::PathBuf;
use std::time::Duration;

use cmux_cloud_client::ApiError;
use cmux_cloud_client::ops::call;
use cmux_cloud_wire::{CloudMachineCreateError, Op, WireClass, WireIdempotency, WirePrincipal};
use serde_json::{Value, json};

use super::{GlobalArgs, UsageError};

const USAGE: &str = "usage: cmux vm new --provider gcp [--name NAME] [--size small|medium|large|xlarge]\n                   [--team TEAM_ID] [--cloud-api URL] [--cloud-token-file PATH]\n                   [--idempotency-key KEY] [--json]";
const TIMEOUT: Duration = Duration::from_secs(60);
/// The app's default machine (CloudMachineCreateFlow.named): 4 vCPUs, 16 GiB, a 64 GiB disk.
const DEFAULT_SIZE: (i64, i64) = (4, 16_384);
const DISK_MB: i64 = 65_536;

/// The provider `cmux vm new --provider` names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Provider {
    Freestyle,
    Gcp,
}

/// `--provider P` (or `=P`) before any `--` in `tail`: `Ok(None)` when absent, the words
/// without it, or a usage error for a value that is not a provider.
pub(super) fn take_provider(
    tail: &[String],
) -> Result<(Option<Provider>, Vec<String>), UsageError> {
    let mut provider = None;
    let mut kept = Vec::with_capacity(tail.len());
    let mut words = tail.iter();
    while let Some(word) = words.next() {
        if word == "--" {
            kept.push(word.clone());
            kept.extend(words.cloned());
            break;
        }
        let value = if let Some(value) = word.strip_prefix("--provider=") {
            value.to_owned()
        } else if word == "--provider" {
            words
                .next()
                .cloned()
                .ok_or_else(|| UsageError::new("--provider is freestyle or gcp"))?
        } else {
            kept.push(word.clone());
            continue;
        };
        let named = match value.as_str() {
            "freestyle" => Provider::Freestyle,
            "gcp" => Provider::Gcp,
            other => {
                return Err(UsageError::new(format!(
                    "--provider is freestyle or gcp, not {other}"
                )));
            }
        };
        if provider.is_some_and(|p| p != named) {
            return Err(UsageError::new("--provider is given twice with different values"));
        }
        provider = Some(named);
    }
    Ok((provider, kept))
}

/// A checked `cmux vm new --provider gcp`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct GcpNew {
    pub name: Option<String>,
    pub size: Option<String>,
    pub team: Option<String>,
    pub api: Option<String>,
    pub credential_file: Option<PathBuf>,
}

/// The words after `--provider gcp` was taken out of them.
pub(super) fn parse(words: &[String]) -> Result<GcpNew, UsageError> {
    let mut command = GcpNew::default();
    let mut iter = words.iter();
    while let Some(word) = iter.next() {
        let (name, inline) = match word.split_once('=') {
            Some((name, value)) => (name, Some(value.to_owned())),
            None => (word.as_str(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| iter.next().cloned())
                .ok_or_else(|| UsageError::new(format!("{name} needs a value\n{USAGE}")))
        };
        match name {
            "--name" => command.name = Some(value()?),
            "--size" => {
                let size = value()?;
                if cmux_cloud_handlers::args::create_size(&size).is_none() {
                    return Err(UsageError::new("--size is small, medium, large or xlarge"));
                }
                command.size = Some(size);
            }
            "--team" => command.team = Some(value()?),
            "--cloud-api" => command.api = Some(value()?),
            "--cloud-token-file" => command.credential_file = Some(value()?.into()),
            other => {
                return Err(UsageError::new(format!(
                    "{other} is not taken with --provider gcp: a GCP VM is our own fleet capacity, made through the cmux API; the app's and the VM API's options are Freestyle's\n{USAGE}"
                )));
            }
        }
    }
    Ok(command)
}

/// `cloud.machine.create`'s params for this create: a fleet machine on GCP.
pub(super) fn params(command: &GcpNew) -> Value {
    let (cpu, memory_mb) = command
        .size
        .as_deref()
        .and_then(cmux_cloud_handlers::args::create_size)
        .unwrap_or(DEFAULT_SIZE);
    let mut params = json!({
        "size": { "cpu": cpu, "memory_mb": memory_mb, "disk_mb": DISK_MB },
        "kind": "fleet",
        "provider": "gcp",
    });
    if let Some(name) = command.name.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
        params["name"] = json!(name);
    }
    params
}

/// `cloud.machine.create` with the params this build's generated wire does not carry yet
/// (`kind`, `provider`): the same op, its declared errors, its params as JSON.
struct FleetCreateOp;

impl Op for FleetCreateOp {
    const NAME: &'static str = "cloud.machine.create";
    const CLASS: WireClass = WireClass::Mutation;
    const IDEMPOTENCY: WireIdempotency = WireIdempotency::Required;
    const OWNER: &'static str = "cloud:CloudDO";
    const RISK: &'static str = "money";
    const PRINCIPALS: &'static [WirePrincipal] = &[WirePrincipal::Session, WirePrincipal::Install];
    type Params = Value;
    type Result = Value;
    type Error = CloudMachineCreateError;
}

/// Sends the create; the value is the op's answer (`machine`, …), with `replayed` when the
/// same key's first try answered it.
pub(super) fn run(
    command: &GcpNew,
    target: &super::cloud_team_keys::Target,
    key: &str,
) -> Result<Value, ApiError> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let local = |code: &str, message: String| ApiError {
        status: None,
        tag: None,
        code: Some(code.to_owned()),
        message,
        retryable: code == "cloud.unreachable",
        retry_after: None,
    };
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    let (base, http) = cmux_cloud_client::http(
        &target.api,
        Some(&target.credential),
        Some(&target.team),
        user_agent,
        TIMEOUT,
    )
    .map_err(|e| local("usage.invalid", e.to_string()))?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| local("cloud.unreachable", e.to_string()))?;
    let answer =
        runtime.block_on(call::<FleetCreateOp>(&http, &base, params(command), Some(key), None))?;
    let replayed = matches!(answer, cmux_cloud_client::ops::Answer::Value { replayed: true, .. });
    let mut value = answer.into_result()?;
    if replayed && let Some(object) = value.as_object_mut() {
        object.insert("replayed".into(), json!(true));
    }
    Ok(value)
}

/// `cmux vm new --provider gcp …` (the words with `--provider` taken out): its exit code.
pub(super) fn run_new(global: &GlobalArgs, words: &[String]) -> i32 {
    let fail = |code: &str, message: &str, exit: i32| {
        super::app::failure(code, &format!("cmux: {message}"), global.output, exit)
    };
    let command = match parse(words) {
        Ok(command) => command,
        Err(error) => return fail("usage.invalid", &error.0, 2),
    };
    let target = match super::cloud_team_keys::resolve(
        &super::cloud_team_keys::Command {
            verb: super::cloud_team_keys::Verb::Help,
            team: command.team.clone(),
            api: command.api.clone(),
            credential_file: command.credential_file.clone(),
            idempotency_key: None,
        },
        |key| std::env::var(key).ok(),
    ) {
        Ok(target) => target,
        Err(message) => return fail("usage.invalid", &message, 2),
    };
    let key = global.idempotency_key.clone().unwrap_or_else(cmux_cloud_client::client_key);
    match run(&command, &target, &key) {
        Ok(answer) => super::wire::print_local_success(&answer, global.output),
        Err(error) => {
            let code = error.code.clone().unwrap_or_else(|| "cloud.unreachable".to_owned());
            // The key goes back so a retry of an unanswered create is the same create.
            let body = json!({
                "code": code,
                "message": format!("cmux: {}", error.message),
                "details": { "idempotency_key": key },
                "retryable": error.retryable,
            });
            super::wire::print_local_error(&body, global.output, 1)
        }
    }
}

#[cfg(test)]
#[path = "vm_gcp_tests.rs"]
mod tests;
