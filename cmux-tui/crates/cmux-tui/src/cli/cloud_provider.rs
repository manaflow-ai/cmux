//! `cmux cloud provider gcp status|set|off`: bring your own cloud. A team admin connects the
//! team's own GCP project as a Cloud machine pool (cmux-platform `ProviderPoolOps.ts`,
//! `cloud.provider.gcp.get` and `cloud.provider.gcp.set`); after that `cmux vm new --provider gcp`
//! makes the team's machines there, through the same create, lifecycle, link and meter as every
//! Cloud machine, at most `--pool-size` holding compute at once.
//!
//! `status` prints the pool (or none), whether this deployment offers team pools, the principal to
//! grant Service Account Token Creator on the team's service account (`grant_to`), the image pool
//! machines boot and how many hold compute now. `set` connects or changes it; `off` disconnects it
//! (machines already made there stay where they are).
//!
//! The cmux API, the credential and the team come from `--cloud-api` (or `CMUX_CLOUD_API_URL`),
//! `--cloud-token-file` (or `CMUX_CLOUD_ACCESS_TOKEN`) and `--team` (or `CMUX_CLOUD_TEAM`), as
//! `cmux cloud team-keys` takes them. The ops are sent as JSON (`cmux_cloud_client::ops::call`), as
//! vm_gcp.rs sends its create, until this build's generated wire carries them.

use std::path::PathBuf;
use std::time::Duration;

use cmux_cloud_client::ApiError;
use cmux_cloud_client::ops::call;
use cmux_cloud_wire::{
    CloudMachineCreateError, CloudPlanGetError, Op, WireClass, WireIdempotency, WirePrincipal,
};
use serde_json::{Map, Value, json};

use super::UsageError;

pub(super) const USAGE: &str = "\
usage: cmux cloud provider gcp status [--json]
       cmux cloud provider gcp set [--project ID] [--zone ZONE] [--service-account EMAIL]
                                   [--pool-size N] [--idempotency-key KEY] [--json]
       cmux cloud provider gcp off [--idempotency-key KEY] [--json]
  each takes --team TEAM_ID (or CMUX_CLOUD_TEAM), --cloud-api URL (or CMUX_CLOUD_API_URL)
  and --cloud-token-file PATH (or CMUX_CLOUD_ACCESS_TOKEN)

Connects the team's own GCP project as a Cloud machine pool (a team admin). Grant the
principal `status` prints as grant_to Service Account Token Creator on --service-account,
and that account Compute Instance Admin in --project and Compute Image User on the image.
Then `cmux vm new --provider gcp` makes the team's machines there, at most --pool-size
holding compute at once; they are metered and billed like every Cloud machine. The first
set needs --project, --zone, --service-account and --pool-size; a later one changes only
what it names. off disconnects it; machines already made there stay where they are.
";
const TIMEOUT: Duration = Duration::from_secs(30);
/// cmux-platform `GCP_POOL_MAX`.
const POOL_MAX: u64 = 1000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verb {
    Help,
    Status,
    Set(Map<String, Value>),
    Off,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Command {
    pub verb: Verb,
    pub team: Option<String>,
    pub api: Option<String>,
    pub credential_file: Option<PathBuf>,
}

/// `Some(exit code)` when `args` is `cloud provider …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || !matches!(noun.as_str(), "provider" | "providers") {
        return None;
    }
    let fail = |code: &str, message: &str, exit: i32| {
        super::app::failure(code, &format!("cmux: {message}"), global.output, exit)
    };
    let command = match parse(rest) {
        Ok(command) => command,
        Err(error) => return Some(fail("usage.invalid", &error.0, 2)),
    };
    if command.verb == Verb::Help {
        print!("{USAGE}");
        return Some(0);
    }
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
        Err(message) => return Some(fail("usage.invalid", &message, 2)),
    };
    let key = global.idempotency_key.clone().unwrap_or_else(cmux_cloud_client::client_key);
    Some(match run(&command.verb, &target, &key) {
        Ok(answer) => super::wire::print_local_success(&answer, global.output),
        Err(error) => {
            let code = error.code.clone().unwrap_or_else(|| "cloud.unreachable".to_owned());
            // The key goes back so a retry of an unanswered set is the same set.
            let details = if command.verb == Verb::Status {
                json!({})
            } else {
                json!({ "idempotency_key": key })
            };
            let body = json!({
                "code": code,
                "message": format!("cmux: {}", error.message),
                "details": details,
                "retryable": error.retryable,
            });
            super::wire::print_local_error(&body, global.output, 1)
        }
    })
}

/// The words after `cloud provider`.
pub(super) fn parse(args: &[String]) -> Result<Command, UsageError> {
    let usage = || UsageError::new(USAGE);
    let mut command = Command { verb: Verb::Help, team: None, api: None, credential_file: None };
    let Some((provider, rest)) = args.split_first() else { return Ok(command) };
    if matches!(provider.as_str(), "--help" | "-h" | "help") {
        return Ok(command);
    }
    if provider != "gcp" {
        return Err(UsageError::new(format!(
            "the provider is gcp (a team's own GCP project), not {provider}\n{USAGE}"
        )));
    }
    let Some((verb, options)) = rest.split_first() else { return Ok(command) };
    if matches!(verb.as_str(), "--help" | "-h" | "help")
        || options.iter().any(|w| w == "--help" || w == "-h")
    {
        return Ok(command);
    }
    let mut set = Map::new();
    let mut words = options.iter();
    while let Some(word) = words.next() {
        let (name, value) = match word.split_once('=') {
            Some((name, value)) => (name, value.to_owned()),
            None => (
                word.as_str(),
                words
                    .next()
                    .cloned()
                    .ok_or_else(|| UsageError::new(format!("{word} needs a value\n{USAGE}")))?,
            ),
        };
        let value = value.trim().to_owned();
        match name {
            "--team" => command.team = Some(value),
            "--cloud-api" => command.api = Some(value),
            "--cloud-token-file" => command.credential_file = Some(value.into()),
            "--project" | "--zone" | "--service-account" if verb == "set" => {
                if value.is_empty() {
                    return Err(UsageError::new(format!("{name} needs a value")));
                }
                set.insert(name.trim_start_matches("--").replace('-', "_"), json!(value));
            }
            "--pool-size" if verb == "set" => {
                let size = value
                    .parse::<u64>()
                    .ok()
                    .filter(|n| (1..=POOL_MAX).contains(n))
                    .ok_or_else(|| {
                        UsageError::new(format!("--pool-size is a whole number, 1 to {POOL_MAX}"))
                    })?;
                set.insert("pool_size".into(), json!(size));
            }
            _ => return Err(UsageError::new(format!("unexpected argument {word:?}\n{USAGE}"))),
        }
    }
    command.verb = match verb.as_str() {
        "status" | "get" => Verb::Status,
        "off" | "disconnect" => Verb::Off,
        "set" if set.is_empty() => {
            return Err(UsageError::new(format!(
                "set needs at least one of --project, --zone, --service-account, --pool-size\n{USAGE}"
            )));
        }
        "set" => Verb::Set(set),
        _ => return Err(usage()),
    };
    Ok(command)
}

/// The op and params of a verb (never `Help`).
pub(super) fn request(verb: &Verb) -> Option<(&'static str, Value)> {
    match verb {
        Verb::Help => None,
        Verb::Status => Some(("cloud.provider.gcp.get", json!({}))),
        Verb::Set(fields) => Some(("cloud.provider.gcp.set", Value::Object(fields.clone()))),
        Verb::Off => Some(("cloud.provider.gcp.set", json!({ "off": true }))),
    }
}

/// `cloud.provider.gcp.get` as JSON.
struct GcpGetOp;

impl Op for GcpGetOp {
    const NAME: &'static str = "cloud.provider.gcp.get";
    const CLASS: WireClass = WireClass::Read;
    const IDEMPOTENCY: WireIdempotency = WireIdempotency::Forbidden;
    const OWNER: &'static str = "cloud:CloudDO";
    const RISK: &'static str = "read";
    const PRINCIPALS: &'static [WirePrincipal] = &[WirePrincipal::Session, WirePrincipal::Install];
    type Params = Value;
    type Result = Value;
    // Its codes are the common ones a team read answers (auth, team); an undeclared one is `Unknown`.
    type Error = CloudPlanGetError;
}

/// `cloud.provider.gcp.set` as JSON: a team admin's signed-in session only.
struct GcpSetOp;

impl Op for GcpSetOp {
    const NAME: &'static str = "cloud.provider.gcp.set";
    const CLASS: WireClass = WireClass::Mutation;
    const IDEMPOTENCY: WireIdempotency = WireIdempotency::Required;
    const OWNER: &'static str = "cloud:CloudDO";
    const RISK: &'static str = "money";
    const PRINCIPALS: &'static [WirePrincipal] = &[WirePrincipal::Session];
    type Params = Value;
    type Result = Value;
    // `cloud.provider.unavailable` and the common codes; an undeclared one is `Unknown`.
    type Error = CloudMachineCreateError;
}

pub(super) fn run(
    verb: &Verb,
    target: &super::cloud_team_keys::Target,
    key: &str,
) -> Result<Value, ApiError> {
    let local = |code: &str, message: String| ApiError {
        status: None,
        tag: None,
        code: Some(code.to_owned()),
        message,
        retryable: code == "cloud.unreachable",
        retry_after: None,
    };
    let Some((name, params)) = request(verb) else {
        return Err(local("usage.invalid", USAGE.to_owned()));
    };
    let _ = rustls::crypto::ring::default_provider().install_default();
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
    if name == GcpGetOp::NAME {
        runtime.block_on(call::<GcpGetOp>(&http, &base, params, None, None))?.into_result()
    } else {
        runtime.block_on(call::<GcpSetOp>(&http, &base, params, Some(key), None))?.into_result()
    }
}

#[cfg(test)]
#[path = "cloud_provider_tests.rs"]
mod tests;
