//! `cmux cloud preflight [--agent claude|codex] [--team TEAM]... [--no-personal] [--json]`: would a Cloud chat start
//! now, as the app's start gate decides it (CmuxNextApp `CloudStartChat`, `setup.gateway`), and if not, why.
//!
//! The gate counts the inference gateway of two backend teams: the install token's team, and the person's own
//! (personal) team, where production makes the person's Cloud machines (cmux#51322). A team serves the chat when its
//! gateway is in mode `gateway` and online (`inference gateway status`'s `serves`). This command asks the same teams the
//! same question, through the same `inference gateway status` read, and prints the teams, each gateway, the agents
//! served and the verdict, with a reason whenever the verdict is no. The production probe
//! (cmuxterm-hq `cloud_chat_app_probe.py`) and a person whose chat will not start run this one command, so neither
//! keeps its own copy of the gate's decision.
//!
//! With no `--team`, the teams come from the app's token (`cmux auth token --json`): its `team` claim and the personal
//! team of its `sub` (`personal_team_of`). `--no-personal` drops the personal team, as the gate does for a managed team.
//! Exit 0 when the agent is served, 1 when it is not (the JSON says why), 2 on bad arguments.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::inference_gateway::{TokenSource, backend_credential};
use super::inference_gateway_admin::{Common, Verb, error_json};
use super::{GlobalArgs, OutputMode};

pub(super) const USAGE: &str = "\
usage: cmux cloud preflight [--agent claude|codex] [--team TEAM]... [--no-personal]
                            [--api URL] [--token-file PATH | --token-command CMD] [--json]

Would a Cloud chat start now, as the app's start gate decides it: the teams it counts (the install
token's team and your personal team), each team's inference gateway, the agents they serve, and the
verdict with its reason. Exit 0 when the agent is served, 1 when it is not.
";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Options {
    pub agent: String,
    pub teams: Vec<String>,
    pub personal: bool,
    pub api: Option<String>,
    pub token: TokenSource,
}

/// `Some(exit code)` when `args` is `cloud preflight …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, verb, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || verb != "preflight" {
        return None;
    }
    let mut words = Vec::new();
    for word in rest {
        match word.as_str() {
            "--json" => global.output = OutputMode::Json,
            "-h" | "--help" => {
                print!("{USAGE}");
                return Some(0);
            }
            _ => words.push(word.clone()),
        }
    }
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let options = match parse(&words, &env) {
        Ok(o) => o,
        Err(e) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {e}\n{USAGE}"),
                global.output,
                2,
            ));
        }
    };
    Some(run(&global, &options))
}

pub(super) fn parse(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Options, String> {
    let mut agent = None;
    let mut teams = Vec::new();
    let mut personal = true;
    let mut api = None;
    let mut token = None;
    let mut args = words.iter();
    while let Some(arg) = args.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f, Some(v.to_owned())),
            _ => (arg.as_str(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| args.next().cloned())
                .filter(|v| !v.is_empty())
                .ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag {
            "--agent" => agent = Some(value()?),
            "--team" => teams.push(value()?),
            "--no-personal" => personal = false,
            "--api" => api = Some(value()?),
            "--token-file" => token = Some(TokenSource::File(value()?.into())),
            "--token-command" => token = Some(TokenSource::Command(value()?)),
            _ => return Err(format!("unexpected argument {arg}")),
        }
    }
    let agent = agent.unwrap_or_else(|| "claude".into());
    if agent != "claude" && agent != "codex" {
        return Err("--agent is claude or codex".into());
    }
    let token = token.unwrap_or_else(|| {
        if env("CMUX_CLOUD_ACCESS_TOKEN").is_some() { TokenSource::Env } else { TokenSource::App }
    });
    let api = api.or_else(|| env("CMUX_CLOUD_API_URL"));
    if api.is_none() && token != TokenSource::App {
        return Err("--api (or CMUX_CLOUD_API_URL) names the cmux API".into());
    }
    Ok(Options { agent, teams, personal, api, token })
}

/// The backend's id for `user`'s personal team (cmux-platform `personalTeamIdFor`; Swift
/// `GitHubConnections.personalTeam(user:)`): `team_` and the first 20 hex digits of SHA-256 of `personal:<user>`.
pub(super) fn personal_team_of(user: &str) -> String {
    use sha2::{Digest, Sha256};
    let hex: String = Sha256::digest(format!("personal:{user}"))
        .iter()
        .take(10)
        .map(|b| format!("{b:02x}"))
        .collect();
    format!("team_{hex}")
}

/// The teams the gate counts, each with where it came from (`asked`, `install`, `personal`), first-seen order, once
/// each. `claims` is the app token's (team, user).
pub(super) fn teams(
    asked: &[String],
    claims: (Option<&str>, Option<&str>),
    personal: bool,
) -> Vec<(String, &'static str)> {
    let mut out: Vec<(String, &'static str)> = Vec::new();
    let mut push = |team: String, source| {
        if !out.iter().any(|(t, _)| *t == team) {
            out.push((team, source));
        }
    };
    if !asked.is_empty() {
        asked.iter().for_each(|t| push(t.clone(), "asked"));
        return out;
    }
    if let Some(team) = claims.0 {
        push(team.to_owned(), "install");
    }
    if personal && let Some(user) = claims.1 {
        push(personal_team_of(user), "personal");
    }
    out
}

/// One team's row from its `inference gateway status` answer.
pub(super) fn team_row(team: &str, source: &str, status: &Value) -> Value {
    if status.get("ok").and_then(Value::as_bool) != Some(true) {
        return json!({"team": team, "source": source, "ok": false, "serves": [],
            "error": status.get("error").cloned().unwrap_or(Value::Null)});
    }
    let g = status.get("gateway").cloned().unwrap_or(Value::Null);
    json!({"team": team, "source": source, "ok": true,
        "serves": status.get("serves").cloned().unwrap_or_else(|| json!([])),
        "gateway": {"mode": g.get("mode").cloned().unwrap_or(Value::Null),
                    "online": g.get("online").cloned().unwrap_or(Value::Null),
                    "machine": g.get("machine").cloned().unwrap_or(Value::Null)}})
}

/// The verdict over the team rows: served when any team serves `agent` (the gate's union of `serves`), else the reason.
pub(super) fn verdict(agent: &str, rows: &[Value]) -> Value {
    let serves: BTreeSet<&str> = rows
        .iter()
        .filter_map(|r| r.get("serves").and_then(Value::as_array))
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let ready = serves.contains(agent);
    let reason = if ready {
        Value::Null
    } else if rows.is_empty() {
        json!({"code": "no_team", "message": "the app's token names no team and no user: sign in to cmux"})
    } else {
        let why: Vec<String> = rows
            .iter()
            .map(|r| {
                let team = r.get("team").and_then(Value::as_str).unwrap_or("?");
                if r.get("ok").and_then(Value::as_bool) != Some(true) {
                    let code = r.pointer("/error/code").and_then(Value::as_str).unwrap_or("error");
                    format!("{team}: gateway status unread ({code})")
                } else {
                    let mode = r.pointer("/gateway/mode").and_then(Value::as_str).unwrap_or("off");
                    let online =
                        r.pointer("/gateway/online").and_then(Value::as_bool) == Some(true);
                    match (mode, online) {
                        ("gateway", false) => format!("{team}: gateway mode on, gateway offline"),
                        ("gateway", true) => format!("{team}: gateway online, serves no {agent}"),
                        (mode, _) => format!("{team}: mode {mode}"),
                    }
                }
            })
            .collect();
        let all_unread = rows.iter().all(|r| r.get("ok").and_then(Value::as_bool) != Some(true));
        let any_offline = rows.iter().any(|r| {
            r.pointer("/gateway/mode").and_then(Value::as_str) == Some("gateway")
                && r.pointer("/gateway/online").and_then(Value::as_bool) != Some(true)
        });
        let code = if all_unread {
            "gateway_unread"
        } else if any_offline {
            "gateway_offline"
        } else {
            "gateway_off"
        };
        json!({"code": code, "message": format!("No Cloud connection serves {agent}: {}", why.join("; "))})
    };
    json!({"ok": true, "agent": agent, "ready": ready, "serves": serves, "teams": rows, "reason": reason})
}

async fn preflight(options: &Options) -> Value {
    let (team, user) = if options.teams.is_empty() {
        match backend_credential(&options.token, None).await {
            Ok((token, _)) => {
                let claims = cmux_cloud_config::identity::claims(token.trim());
                (claims.team, claims.user)
            }
            Err(e) => {
                let mut answer = verdict(&options.agent, &[]);
                if let Some(object) = answer.as_object_mut() {
                    object.insert("reason".into(), json!({"code": "no_token", "message": e}));
                }
                return answer;
            }
        }
    } else {
        (None, None)
    };
    let mut rows = Vec::new();
    for (team, source) in
        teams(&options.teams, (team.as_deref(), user.as_deref()), options.personal)
    {
        let common = Common {
            api: options.api.clone(),
            team: Some(team.clone()),
            token: options.token.clone(),
        };
        let (status, _) =
            super::inference_gateway_admin::run(&common, &Verb::Status { personal: false }).await;
        rows.push(team_row(&team, source, &status));
    }
    verdict(&options.agent, &rows)
}

fn run(global: &GlobalArgs, options: &Options) -> i32 {
    let json_out = global.output == OutputMode::Json;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let answer = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime.block_on(preflight(options)),
        Err(e) => error_json("cli.runtime", &e.to_string()),
    };
    print(&answer, json_out);
    if answer.get("ready").and_then(Value::as_bool) == Some(true) { 0 } else { 1 }
}

fn print(answer: &Value, json_out: bool) {
    if json_out {
        println!("{answer}");
        return;
    }
    for row in answer.get("teams").and_then(Value::as_array).into_iter().flatten() {
        let team = row.get("team").and_then(Value::as_str).unwrap_or("?");
        let source = row.get("source").and_then(Value::as_str).unwrap_or("?");
        let serves: Vec<&str> = row
            .get("serves")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        println!(
            "{team} ({source}): serves {}",
            if serves.is_empty() { "nothing".into() } else { serves.join(", ") }
        );
    }
    if answer.get("ready").and_then(Value::as_bool) == Some(true) {
        println!("ready: a Cloud chat with {} starts", answer["agent"].as_str().unwrap_or("?"));
    } else if let Some(message) = answer.pointer("/reason/message").and_then(Value::as_str) {
        println!("not ready: {message}");
    } else if let Some(message) = answer.pointer("/error/message").and_then(Value::as_str) {
        eprintln!("cmux cloud preflight: {message}");
    }
}

#[cfg(test)]
#[path = "cloud_preflight_tests.rs"]
mod tests;
