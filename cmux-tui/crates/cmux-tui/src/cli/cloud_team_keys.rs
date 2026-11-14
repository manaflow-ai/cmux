//! `cmux cloud team-keys status|set|remove`: a team's shared agent keys
//! (Cloud multiplayer, contract C4). An owner or admin sets one key per agent
//! (`claude`, `codex`) for the whole team; it overrides each member's own key
//! on the team's Cloud machines. The cmux API keeps it sealed in the team's
//! record (`backend/apps/api/src/team-agent-keys.ts`); nothing answers it back
//! to a client: `status` says whether one is set, its kind, generation, who
//! set it and when, and (to owners and admins) its last four characters.
//!
//! The ops are `team.agent_key.status` (read), `team.agent_key.set` and
//! `team.agent_key.remove` (mutations, session credentials only), the same
//! ones the app's Settings > Team > Agents page calls. `set` reads the key
//! from a hidden prompt, stdin or `--secret-file PATH`, never from argv; the
//! key goes only in the request body and is never printed or logged.
//!
//! The cmux API and the caller's credential come from `--cloud-api` (or
//! `CMUX_CLOUD_API_URL`) and `--cloud-token-file` (or
//! `CMUX_CLOUD_ACCESS_TOKEN`); the team from `--team` (or `CMUX_CLOUD_TEAM`).
//!
//! Errors (stderr JSON with `--json`, stable `code`): `usage.invalid` (exit
//! 2); the API's own codes, verbatim (`auth.required`, `team.not_member`
//! (not in the team), `auth.forbidden` (not an owner or admin),
//! `validation.invalid` (a malformed
//! key), `team_agent_key.not_configured` (the deployment has no sealing key),
//! `revision.conflict` (another admin changed it at the same moment: run it
//! again), `owner.unreachable`); `cloud.unreachable` (no answer; retry with
//! the same `--idempotency-key`) and `cloud.client.unreadable` (exit 1).

use std::path::PathBuf;
use std::time::Duration;

use cmux_cloud_client::ApiError;
use cmux_cloud_client::ops::{Answer, call};
use cmux_cloud_wire::{Op, TeamAgentKeyRemoveOp, TeamAgentKeySetOp, TeamAgentKeyStatusOp};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::UsageError;

const USAGE: &str = "usage: cmux cloud team-keys status [--json]\n       cmux cloud team-keys set claude|codex [--kind api_key|oauth] [--secret-file PATH] [--idempotency-key KEY] [--json]\n       cmux cloud team-keys remove claude|codex [--idempotency-key KEY] [--json]\n  each takes --team TEAM_ID (or CMUX_CLOUD_TEAM), --cloud-api URL (or CMUX_CLOUD_API_URL)\n  and --cloud-token-file PATH (or CMUX_CLOUD_ACCESS_TOKEN); set reads the key from a hidden\n  prompt or stdin unless --secret-file names a file, never from an argument";
const TEAM_ENV: &str = "CMUX_CLOUD_TEAM";
const TIMEOUT: Duration = Duration::from_secs(30);
/// The API's own bound (`TEAM_AGENT_KEY_MAX_BYTES`).
const MAX_KEY_BYTES: usize = 16 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verb {
    Help,
    Status,
    Set { agent: String, kind: String, secret_file: Option<PathBuf> },
    Remove { agent: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Command {
    pub verb: Verb,
    pub team: Option<String>,
    pub api: Option<String>,
    pub credential_file: Option<PathBuf>,
    pub idempotency_key: Option<String>,
}

/// `Some(exit code)` when `args` is `cloud team-keys …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || !matches!(noun.as_str(), "team-keys" | "team-key") {
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
        let help = crate::localization::catalog().app_control.cloud_team_keys_help;
        println!("{USAGE}\n\n{help}");
        return Some(0);
    }
    let target = match resolve(&command, |key| std::env::var(key).ok()) {
        Ok(target) => target,
        Err(message) => return Some(fail("usage.invalid", &message, 2)),
    };
    Some(match run(&command, &target) {
        Ok(answer) => super::wire::print_local_success(&answer, global.output),
        Err(error) => {
            let code = error.code.clone().unwrap_or_else(|| "cloud.unreachable".to_owned());
            let body = json!({ "code": code, "message": format!("cmux: {}", error.message), "details": {}, "retryable": error.retryable });
            super::wire::print_local_error(&body, global.output, 1)
        }
    })
}

pub(super) fn parse(args: &[String]) -> Result<Command, UsageError> {
    let usage = || UsageError::new(USAGE);
    let mut command = Command {
        verb: Verb::Help,
        team: None,
        api: None,
        credential_file: None,
        idempotency_key: None,
    };
    let Some((verb, rest)) = args.split_first() else { return Ok(command) };
    if matches!(verb.as_str(), "--help" | "-h" | "help") {
        return if rest.is_empty() { Ok(command) } else { Err(usage()) };
    }
    // `team-keys status --help` is the help too (a flag never takes `--help` as its value).
    let verbs = ["status", "set", "remove", "rm"];
    if verbs.contains(&verb.as_str()) && rest.iter().any(|w| w == "--help" || w == "-h") {
        return Ok(command);
    }
    let (agent, options) = match verb.as_str() {
        "status" => (None, rest),
        "set" | "remove" | "rm" => {
            let (agent, options) = rest.split_first().ok_or_else(usage)?;
            if !matches!(agent.as_str(), "claude" | "codex") {
                return Err(UsageError::new(format!(
                    "the agent is claude or codex, not {agent}\n{USAGE}"
                )));
            }
            (Some(agent.clone()), options)
        }
        _ => return Err(usage()),
    };
    let (mut kind, mut secret_file) = (None, None);
    let mut words = options.iter();
    while let Some(word) = words.next() {
        let (name, value) = match word.split_once('=') {
            Some((name, value)) => (name, value.to_owned()),
            None => (word.as_str(), words.next().cloned().ok_or_else(usage)?),
        };
        match name {
            "--team" => command.team = Some(value),
            "--cloud-api" => command.api = Some(value),
            "--cloud-token-file" => command.credential_file = Some(value.into()),
            "--idempotency-key" if verb != "status" => {
                let plain = (8..=128).contains(&value.len())
                    && value
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'));
                if !plain {
                    return Err(UsageError::new(
                        "--idempotency-key is 8 to 128 letters, digits and _-.:",
                    ));
                }
                command.idempotency_key = Some(value);
            }
            "--kind" if verb == "set" => {
                if !matches!(value.as_str(), "api_key" | "oauth") {
                    return Err(UsageError::new("--kind is api_key or oauth"));
                }
                kind = Some(value);
            }
            "--secret-file" if verb == "set" => secret_file = Some(PathBuf::from(value)),
            _ => return Err(usage()),
        }
    }
    command.verb = match (verb.as_str(), agent) {
        ("status", _) => Verb::Status,
        ("set", Some(agent)) => {
            Verb::Set { agent, kind: kind.unwrap_or_else(|| "api_key".to_owned()), secret_file }
        }
        (_, Some(agent)) => Verb::Remove { agent },
        _ => return Err(usage()),
    };
    Ok(command)
}

/// Where the call goes: the API origin, the credential and the team.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Target {
    pub api: String,
    pub credential: String,
    pub team: String,
}

pub(super) fn resolve(
    command: &Command,
    env: impl Fn(&str) -> Option<String>,
) -> Result<Target, String> {
    let resolved = super::cloud_client_session::resolve(
        &super::cloud_client_session::Command {
            verb: super::cloud_client_session::Verb::Create { token_file: None },
            machine: String::new(),
            ttl: None,
            api: command.api.clone(),
            credential_file: command.credential_file.clone(),
            team: None,
        },
        &env,
    )?;
    let team = command
        .team
        .clone()
        .or_else(|| env(TEAM_ENV))
        .map(|t| t.trim().to_owned())
        .filter(|t| !t.is_empty())
        .ok_or_else(|| format!("name the team with --team TEAM_ID or {TEAM_ENV}"))?;
    if team.len() > 128
        || !team.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
    {
        return Err("--team takes a team id (team_…)".into());
    }
    Ok(Target { api: resolved.0, credential: resolved.1, team })
}

/// The key for `set`: `--secret-file` (one trailing line break dropped), else
/// a hidden prompt on a terminal or all of stdin.
fn read_key(agent: &str, file: Option<&PathBuf>) -> Result<Zeroizing<String>, ApiError> {
    let local = |message: String| ApiError {
        status: None,
        tag: None,
        code: Some("usage.invalid".to_owned()),
        message,
        retryable: false,
    };
    let value = match file {
        Some(path) => {
            let mut file = std::fs::File::open(path)
                // Neither the path nor the contents go into the error (a pasted key could be in either).
                .map_err(|e| {
                    local(format!("the --secret-file could not be read ({:?})", e.kind()))
                })?;
            acpmux::cli::harness_secret::read_secret_from(&mut file)
                .map_err(|e| local(e.to_string()))?
        }
        None => acpmux::cli::harness_secret::read_value(&format!("the team's {agent} key"))
            .map_err(|e| local(e.to_string()))?,
    };
    if value.is_empty() {
        return Err(local("the key is empty".into()));
    }
    if value.len() > MAX_KEY_BYTES {
        return Err(local(format!("the key is longer than {} KiB", MAX_KEY_BYTES / 1024)));
    }
    Ok(value)
}

pub(super) fn run(command: &Command, target: &Target) -> Result<Value, ApiError> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    let (base, http) = cmux_cloud_client::http(
        &target.api,
        Some(&target.credential),
        Some(&target.team),
        user_agent,
        TIMEOUT,
    )
    .map_err(|e| ApiError {
        status: None,
        tag: None,
        code: Some("usage.invalid".into()),
        message: e.to_string(),
        retryable: false,
    })?;
    // The key is read before anything is sent, so a prompt never waits on a connection.
    let secret = match &command.verb {
        Verb::Set { agent, secret_file, .. } => Some(read_key(agent, secret_file.as_ref())?),
        _ => None,
    };
    let runtime =
        tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| {
            ApiError {
                status: None,
                tag: None,
                code: Some("cloud.unreachable".into()),
                message: e.to_string(),
                retryable: true,
            }
        })?;
    let key = command.idempotency_key.clone().unwrap_or_else(cmux_cloud_client::client_key);
    runtime.block_on(async {
        match &command.verb {
            Verb::Help => Ok(json!({})),
            Verb::Status => {
                let params = params::<TeamAgentKeyStatusOp>(json!({ "team": target.team }))?;
                answer(call::<TeamAgentKeyStatusOp>(&http, &base, params, None, None).await?)
            }
            Verb::Set { agent, kind, .. } => {
                let secret = secret.as_ref().map(|s| s.as_str()).unwrap_or_default();
                let params = params::<TeamAgentKeySetOp>(
                    json!({ "agent": agent, "kind": kind, "secret": secret }),
                )?;
                answer(call::<TeamAgentKeySetOp>(&http, &base, params, Some(&key), None).await?)
            }
            Verb::Remove { agent } => {
                let params = params::<TeamAgentKeyRemoveOp>(json!({ "agent": agent }))?;
                answer(call::<TeamAgentKeyRemoveOp>(&http, &base, params, Some(&key), None).await?)
            }
        }
    })
}

fn params<O: Op>(value: Value) -> Result<O::Params, ApiError> {
    serde_json::from_value(value).map_err(|e| ApiError {
        status: None,
        tag: None,
        code: Some("usage.invalid".into()),
        // The error names the field, never a value (the set's params hold the key).
        message: format!(
            "{}: {}",
            O::NAME,
            e.to_string().split(" at line").next().unwrap_or("invalid")
        ),
        retryable: false,
    })
}

/// The value as JSON, with `replayed` for a mutation answered from its first try.
fn answer<T: serde::Serialize, E: cmux_cloud_wire::WireError>(
    answer: Answer<T, E>,
) -> Result<Value, ApiError> {
    let replayed = matches!(answer, Answer::Value { replayed: true, .. });
    let mut value = serde_json::to_value(answer.into_result()?).map_err(ApiError::unreadable)?;
    if replayed && let Some(object) = value.as_object_mut() {
        object.insert("replayed".into(), json!(true));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(line: &str) -> Vec<String> {
        line.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn parses_status_set_and_remove_and_keeps_the_key_off_argv() {
        assert_eq!(parse(&words("status --team team_a")).unwrap().verb, Verb::Status);
        let set = parse(&words(
            "set codex --kind oauth --secret-file /tmp/auth.json --idempotency-key ck_12345678",
        ))
        .unwrap();
        assert_eq!(
            set.verb,
            Verb::Set {
                agent: "codex".into(),
                kind: "oauth".into(),
                secret_file: Some("/tmp/auth.json".into())
            }
        );
        assert_eq!(set.idempotency_key.as_deref(), Some("ck_12345678"));
        assert_eq!(
            parse(&words("set claude")).unwrap().verb,
            Verb::Set { agent: "claude".into(), kind: "api_key".into(), secret_file: None }
        );
        assert_eq!(
            parse(&words("rm claude")).unwrap().verb,
            Verb::Remove { agent: "claude".into() }
        );
        assert_eq!(parse(&[]).unwrap().verb, Verb::Help);
        assert_eq!(parse(&words("status --help")).unwrap().verb, Verb::Help);
        assert_eq!(parse(&words("set claude --help")).unwrap().verb, Verb::Help);
        // No way to put the key itself on the command line.
        assert!(parse(&words("set claude sk-live-123456789")).is_err());
        assert!(parse(&words("set claude --secret sk-live-123456789")).is_err());
        assert!(parse(&words("set gemini")).is_err());
        assert!(parse(&words("set claude --kind password")).is_err());
        assert!(parse(&words("status --kind oauth")).is_err());
        assert!(parse(&words("remove codex --idempotency-key x")).is_err());
    }

    #[test]
    fn resolves_the_team_from_the_flag_or_the_environment() {
        let env = |key: &str| match key {
            "CMUX_CLOUD_API_URL" => Some("https://api.example.test".to_owned()),
            "CMUX_CLOUD_ACCESS_TOKEN" => Some("tok".to_owned()),
            "CMUX_CLOUD_TEAM" => Some("team_env".to_owned()),
            _ => None,
        };
        let status = parse(&words("status")).unwrap();
        assert_eq!(resolve(&status, env).unwrap().team, "team_env");
        let flagged = parse(&words("status --team team_flag")).unwrap();
        assert_eq!(resolve(&flagged, env).unwrap().team, "team_flag");
        let none = |key: &str| if key == "CMUX_CLOUD_TEAM" { None } else { env(key) };
        assert!(resolve(&status, none).unwrap_err().contains("--team"));
        let bad = parse(&words("status --team a/b")).unwrap();
        assert!(resolve(&bad, env).is_err());
    }

    #[test]
    fn a_replayed_set_says_so_and_a_refusal_keeps_its_code() {
        let body = br#"{"ok":true,"op":"team.agent_key.set","value":{"agent":"claude","set":true,"kind":"api_key","generation":1,"updated_at":1,"updated_by":"user_a","hint":"abcd"},"transaction":"t","idempotency_key":"ck_1","replayed":true,"stream":"s","sequence":3}"#;
        let read = cmux_cloud_client::ops::read_answer::<TeamAgentKeySetOp>(200, body).unwrap();
        assert_eq!(answer(read).unwrap()["replayed"], json!(true));
        let refused = br#"{"ok":false,"op":"team.agent_key.set","error":{"code":"team_agent_key.not_configured","message":"no sealing key","retryable":false},"transaction":"t","idempotency_key":"ck_1","replayed":false,"stream":"s","sequence":3}"#;
        let read = cmux_cloud_client::ops::read_answer::<TeamAgentKeySetOp>(200, refused).unwrap();
        assert_eq!(
            answer(read).unwrap_err().code.as_deref(),
            Some("team_agent_key.not_configured")
        );
    }

    #[test]
    fn a_secret_file_is_read_without_its_trailing_line_break() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("key");
        std::fs::write(&path, "sk-team-0123456789\n").unwrap();
        assert_eq!(read_key("claude", Some(&path)).unwrap().as_str(), "sk-team-0123456789");
        std::fs::write(&path, "").unwrap();
        assert_eq!(
            read_key("claude", Some(&path)).unwrap_err().code.as_deref(),
            Some("usage.invalid")
        );
        let missing = dir.path().join("missing");
        let error = read_key("claude", Some(&missing)).unwrap_err();
        assert!(!error.message.contains("missing"), "the path stays out of the error");
    }
}
