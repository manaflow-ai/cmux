//! The inference gateway's state and route, as CLI verbs a person or a test runner can drive (`--json`):
//!
//! - `cmux inference gateway status [--personal]`: the team's (or the person's own) gateway: mode, named machine,
//!   whether a gateway is online, its kind and since when (`GET /v1/cloud/inference-gateway[/personal]`).
//! - `cmux inference gateway mode gateway|off|joined [--personal] [--gateway-machine vm_…|machine_<uuid> |
//!   --no-gateway-machine]`: sets it (`PUT`). The person's own gateway serves every machine they created, in any team;
//!   the team's serves the team. `joined` serves only the team's hub-joined machines (`acpmux machine join`, their
//!   `cmm_` credential): its Cloud machines get no edge rule, as in `off`. A joined machine named as the gateway
//!   machine (`machine_<uuid>`) holds the socket with its own credential (`cmux inference gateway --token-command`).
//! - `cmux inference route --machine vm_… [--agent claude|codex]`: which route that machine's next model call takes,
//!   asked FROM the machine through its edge (`GET https://coderouter.cmux.internal/v1/cmux/route`), so it proves the
//!   edge rule too. No model call is made and nothing secret is printed.
//!
//! Every answer is one JSON object: `{"ok": true, ...}` or `{"ok": false, "error": {"code", "message"}}`. The codes
//! are stable: the API's own (`auth.forbidden`, `owner.unreachable`, `inference.keys_unreachable`, ...) or this
//! CLI's (`cli.invalid_args`, `api.unreachable`, `api.bad_answer`, `machine.exec_failed`).

use std::time::Duration;

use serde_json::{Value, json};

use super::cloud_client_session::secure_origin;
use super::inference_gateway::{TokenSource, backend_credential};
use cmux_cloud_api::machine_io::{Op, Request, RouteChoice, perform};
use cmux_cloud_api::session::valid_machine;

const PLACEHOLDER: &str = "cmux-vm-edge-placeholder";
const ROUTE_HELP: &str = "\
cmux inference route: which route a Cloud machine's next model call takes, asked from the machine itself.

Usage:
  cmux inference route --machine vm_... [--agent claude|codex] [--api URL] [--team TEAM]
                       [--token-file PATH | --token-command CMD] [--json]

Routes: team_key (the team's shared key), owner_key (the machine owner's own key), owner_gateway (the owner's
own `cmux inference gateway --personal`), team_gateway (the team's gateway), shared_coderouter (the machine's
edge does not reach the gateway service: the team and the owner have no gateway or key on).
";
pub(super) const ADMIN_HELP: &str = "\
  cmux inference gateway status [--personal] [--json]
  cmux inference gateway mode gateway|off|joined [--personal]
                         [--gateway-machine vm_...|machine_<uuid> | --no-gateway-machine] [--json]
";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Common {
    /// The cmux API origin; `None` when nothing names one and the token is the app's: the API that issued the app's
    /// token (`cmux auth token --json`'s `api_origin`), as the app runs `inference gateway status` with no `--api`.
    pub api: Option<String>,
    pub team: Option<String>,
    pub token: TokenSource,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verb {
    Status { personal: bool },
    Mode { personal: bool, mode: String, machine: Option<Option<String>> },
    Route { machine: String, agent: String },
}

/// The error object every verb prints on failure.
pub(super) fn error_json(code: &str, message: &str) -> Value {
    json!({"ok": false, "error": {"code": code, "message": message}})
}

/// Parses the verb's arguments (after `inference gateway` for status/mode, after `inference route` for route).
pub(super) fn parse(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<(Common, Verb), String> {
    let (kind, rest) = match words {
        [w, rest @ ..] if w == "status" || w == "mode" || w == "route" => (w.as_str(), rest),
        _ => return Err("expected status, mode or route".into()),
    };
    let mut api = None;
    let mut team = None;
    let mut token = None;
    let mut personal = false;
    let mut machine = None;
    let mut gateway_machine: Option<Option<String>> = None;
    let mut agent = None;
    let mut mode = None;
    let mut args = rest.iter();
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
            "--api" => api = Some(value()?),
            "--team" => team = Some(value()?),
            "--token-file" => token = Some(TokenSource::File(value()?.into())),
            "--token-command" => token = Some(TokenSource::Command(value()?)),
            "--personal" if kind != "route" => personal = true,
            "--machine" if kind == "route" => machine = Some(value()?),
            "--agent" if kind == "route" => agent = Some(value()?),
            "--gateway-machine" if kind == "mode" => gateway_machine = Some(Some(value()?)),
            "--no-gateway-machine" if kind == "mode" => gateway_machine = Some(None),
            "gateway" | "off" | "joined" if kind == "mode" && mode.is_none() => {
                mode = Some(arg.clone());
            }
            _ => return Err(format!("unexpected argument {arg}")),
        }
    }
    let token = token.unwrap_or_else(|| {
        if super::api_tokens::env_credential(env).is_some() {
            TokenSource::Env
        } else {
            TokenSource::App
        }
    });
    // The app runs these with its own environment, which names no API (hq#15762): the app's token says which.
    let api = match api.or_else(|| env("CMUX_CLOUD_API_URL")) {
        Some(api) => Some(secure_origin(&api)?),
        None if token == TokenSource::App => None,
        None => return Err("--api (or CMUX_CLOUD_API_URL) names the cmux API".into()),
    };
    let verb = match kind {
        "status" => Verb::Status { personal },
        "mode" => {
            if let Some(Some(m)) = &gateway_machine
                && !valid_machine(m)
                && !joined_machine(m)
            {
                return Err(
                    "--gateway-machine takes a machine id (vm_..., or a joined machine's machine_<uuid>)"
                        .into(),
                );
            }
            Verb::Mode {
                personal,
                mode: mode.ok_or("mode takes gateway, off or joined")?,
                machine: gateway_machine,
            }
        }
        _ => {
            let machine = machine.ok_or("--machine vm_... names the machine")?;
            if !valid_machine(&machine) {
                return Err("--machine takes a machine id (vm_...)".into());
            }
            let agent = agent.unwrap_or_else(|| "codex".into());
            if agent != "claude" && agent != "codex" {
                return Err("--agent is claude or codex".into());
            }
            Verb::Route { machine, agent }
        }
    };
    Ok((Common { api, team, token }, verb))
}

/// A hub-joined machine's id, as the join registry names it: `machine_` and a lowercase UUID.
pub(super) fn joined_machine(id: &str) -> bool {
    let Some(uuid) = id.strip_prefix("machine_") else { return false };
    let groups: Vec<&str> = uuid.split('-').collect();
    groups.iter().map(|g| g.len()).eq([8, 4, 4, 4, 12])
        && groups
            .iter()
            .all(|g| g.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
}

/// The admin path for `personal`.
pub(super) fn route_path(personal: bool) -> &'static str {
    if personal { "/v1/cloud/inference-gateway/personal" } else { "/v1/cloud/inference-gateway" }
}

/// The API a verb asks: the one named (`--api`, `CMUX_CLOUD_API_URL`), else the one that issued the app's token.
pub(super) fn api_origin(named: Option<&str>, issued_by: Option<&str>) -> Result<String, String> {
    match (named, issued_by) {
        (Some(api), _) => Ok(api.to_owned()),
        (None, Some(issued)) => secure_origin(issued),
        (None, None) => {
            Err("--api (or CMUX_CLOUD_API_URL) names the cmux API; the app's token named none"
                .into())
        }
    }
}

/// The verb's JSON answer and exit code (0 ok, 1 refused or failed).
pub(super) async fn run(common: &Common, verb: &Verb) -> (Value, i32) {
    let (token, issued_by) = match backend_credential(&common.token, common.team.as_deref()).await {
        Ok(t) => t,
        Err(e) => return (error_json("auth.no_token", &e), 1),
    };
    let api = match api_origin(common.api.as_deref(), issued_by.as_deref()) {
        Ok(api) => api,
        Err(e) => return (error_json("cli.invalid_args", &e), 2),
    };
    let http = match cmux_egress::client_builder("cmux_tui::cli::inference_gateway_admin")
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(30))
        .build()
    {
        Ok(h) => h,
        Err(e) => return (error_json("cli.http_client", &e.to_string()), 1),
    };
    let answer = match verb {
        Verb::Status { personal } | Verb::Mode { personal, .. } => {
            let url = format!("{}{}", api, route_path(*personal));
            let mut request = match verb {
                Verb::Mode { mode, machine, .. } => {
                    let mut body = serde_json::Map::new();
                    body.insert("mode".to_owned(), json!(mode));
                    if let Some(m) = machine {
                        body.insert("machine".to_owned(), json!(m));
                    }
                    http.put(url).json(&body)
                }
                _ => http.get(url),
            }
            .bearer_auth(&token);
            if let Some(team) = &common.team {
                request = request.header("x-cmux-team", team);
            }
            match request.send().await {
                Err(_) => return (error_json("api.unreachable", "the cmux API did not answer"), 1),
                Ok(r) => match r.json::<Value>().await {
                    Err(_) => {
                        return (
                            error_json("api.bad_answer", "the cmux API's answer was not JSON"),
                            1,
                        );
                    }
                    Ok(body) => status_answer(*personal, &body),
                },
            }
        }
        Verb::Route { machine, agent } => route(&http, &api, common, &token, machine, agent).await,
    };
    let ok = answer.get("ok").and_then(Value::as_bool) == Some(true);
    (answer, if ok { 0 } else { 1 })
}

/// The agents a gateway in mode `gateway` that is online serves now: Claude and Codex (the agents the edge routes
/// through it, `cmux inference route`'s `team_gateway` / `owner_gateway`); none for any other state. `joined` serves
/// none here: it takes only hub-joined machines' calls, never a Cloud chat's.
pub(super) const GATEWAY_SERVES: [&str; 2] = ["claude", "codex"];

/// The status or mode answer, scoped: `{ok, scope, gateway, serves}` or the API's error object. `serves` is what the
/// app's Cloud start gate counts (CmuxNextCloud `CloudSetup`, hq#15762): a team in gateway mode whose gateway is
/// online serves its members' Cloud chats with no connection of their own.
pub(super) fn status_answer(personal: bool, body: &Value) -> Value {
    match body.get("gateway") {
        Some(gateway) if body.get("ok").and_then(Value::as_bool) == Some(true) => {
            let up = gateway.get("mode").and_then(Value::as_str) == Some("gateway")
                && gateway.get("online").and_then(Value::as_bool) == Some(true);
            let serves: &[&str] = if up { &GATEWAY_SERVES } else { &[] };
            json!({"ok": true, "scope": if personal { "personal" } else { "team" }, "gateway": gateway, "serves": serves})
        }
        _ => api_error(body),
    }
}

/// An API error object with only its code and message (both short, printable).
fn api_error(body: &Value) -> Value {
    let field = |p: &str| {
        body.pointer(p)
            .and_then(Value::as_str)
            .map(|s| s.chars().filter(|c| !c.is_control()).take(300).collect::<String>())
    };
    error_json(
        &field("/error/code").unwrap_or_else(|| "api.bad_answer".into()),
        &field("/error/message").unwrap_or_else(|| "the cmux API refused the request".into()),
    )
}

/// The machine's own probe: one curl through its edge. Its output is the body, then a last line with the status.
pub(super) fn probe_command(agent: &str) -> String {
    format!(
        "curl -sS --max-time 30 -w '\\n%{{http_code}}' -H 'authorization: Bearer {PLACEHOLDER}' \
         'https://coderouter.cmux.internal/v1/cmux/route?agent={agent}'"
    )
}

/// Reads the probe's output: the route answer, or `shared_coderouter` when the edge reached the shared coderouter
/// (it serves no such path), or the error.
pub(super) fn probe_answer(machine: &str, agent: &str, stdout: &str) -> Value {
    let (body, status) = stdout.trim_end().rsplit_once('\n').unwrap_or(("", stdout.trim()));
    let parsed = serde_json::from_str::<Value>(body).ok();
    match (status.trim(), parsed) {
        ("200", Some(v)) if v.get("route").is_some() => v,
        ("404", _) => {
            json!({"ok": true, "route": "shared_coderouter", "agent": agent, "machine": machine})
        }
        ("000", _) | ("", _) => {
            error_json("machine.edge_unreachable", "the machine could not reach its model edge")
        }
        (_, Some(v)) if v.pointer("/error/code").is_some() => api_error(&v),
        (s, _) => error_json("api.bad_answer", &format!("the route probe answered HTTP {s}")),
    }
}

async fn route(
    http: &reqwest::Client,
    api: &str,
    common: &Common,
    token: &str,
    machine: &str,
    agent: &str,
) -> Value {
    let request = Request {
        api: api.to_owned(),
        credential: token.to_owned(),
        team: common.team.clone(),
        machine: machine.to_owned(),
        op: Op::Exec,
        path: None,
        data_base64: None,
        mode: None,
        command: Some(probe_command(agent)),
        timeout_ms: Some(45_000),
        cache_dir: None,
        route: RouteChoice::Auto,
        app_version: None,
        local_only: false,
        max_bytes: None,
    };
    let now = || {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
    };
    let (_, answer) = perform(http, &request, now).await;
    if !(200..300).contains(&answer.status) {
        let mut e = api_error(&answer.body);
        if e.pointer("/error/code").and_then(Value::as_str) == Some("api.bad_answer") {
            e = error_json(
                "machine.exec_failed",
                &format!("the machine did not run the probe (HTTP {})", answer.status),
            );
        }
        return e;
    }
    probe_answer(
        machine,
        agent,
        answer.body.get("stdout").and_then(Value::as_str).unwrap_or_default(),
    )
}

/// Prints the answer: JSON as is, or one plain line per field for people.
pub(super) fn print(answer: &Value, json_out: bool) {
    if json_out {
        println!("{answer}");
        return;
    }
    if answer.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = answer.pointer("/error/code").and_then(Value::as_str).unwrap_or("error");
        let message = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or_default();
        eprintln!("cmux inference: {code}: {message}");
        return;
    }
    if let Some(route) = answer.get("route").and_then(Value::as_str) {
        println!("route: {route}");
    }
    if let Some(scope) = answer.get("scope").and_then(Value::as_str) {
        println!("scope: {scope}");
    }
    let gateways: Vec<(&str, &Value)> = match (answer.get("gateway"), answer.get("gateways")) {
        (Some(g), _) => vec![("gateway", g)],
        (_, Some(g)) => ["owner", "team"].iter().filter_map(|k| Some((*k, g.get(*k)?))).collect(),
        _ => vec![],
    };
    for (name, g) in gateways {
        if g.is_null() {
            continue;
        }
        let mode = g.get("mode").and_then(Value::as_str).unwrap_or("off");
        let online = g.get("online").and_then(Value::as_bool).unwrap_or(false);
        let machine = g
            .get("machine")
            .and_then(Value::as_str)
            .map(|m| format!(", machine {m}"))
            .unwrap_or_default();
        println!("{name}: mode {mode}, {}{machine}", if online { "online" } else { "offline" });
    }
}

/// `Some(exit code)` for `inference route …`.
pub(super) fn run_route_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_action_globals(args).ok()?;
    let rest = match command_args.as_slice() {
        [a, b, rest @ ..] if a == "inference" && b == "route" => rest,
        _ => return None,
    };
    if rest.iter().any(|a| a == "--help" || a == "-h") {
        print!("{ROUTE_HELP}");
        return Some(0);
    }
    let mut words = vec!["route".to_owned()];
    words.extend(rest.iter().cloned());
    let json_out = global.output == super::OutputMode::Json;
    if let Some((machine, agent)) =
        app_route(&words, &|k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty()))
        && super::app::connect_command(&global).is_ok()
    {
        let probe = vec![
            "cloud".to_owned(),
            "exec".to_owned(),
            "--target".to_owned(),
            format!("machine:{machine}"),
            "--command".to_owned(),
            probe_command(&agent),
        ];
        let step = super::cloud_start_chat::app_step(&global, &probe);
        let answer = app_route_answer(&machine, &agent, step);
        print(&answer, json_out);
        return Some(if answer.get("ok").and_then(Value::as_bool) == Some(true) { 0 } else { 1 });
    }
    Some(run_words(&words, json_out))
}

/// The machine and agent of a `route` that goes through the cmux app, as `cmux vm exec` does: the app runs the probe
/// on the machine (`cloud exec`) with its own sign-in, so no `--api` or token is needed. `None` when the words name a
/// direct API path (`--api`, `--team`, `--token-file`, `--token-command`, or `CMUX_CLOUD_ACCESS_TOKEN`) or do not parse.
pub(super) fn app_route(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Option<(String, String)> {
    let direct = ["--api", "--team", "--token-file", "--token-command"];
    if super::api_tokens::env_credential(env).is_some()
        || words.iter().any(|w| direct.iter().any(|d| w == d || w.starts_with(&format!("{d}="))))
    {
        return None;
    }
    // The API origin is not used on this path: any valid one lets the rest parse.
    let placeholder =
        |k: &str| (k == "CMUX_CLOUD_API_URL").then(|| "https://api.cmux.invalid".to_owned());
    match parse(words, &placeholder).ok()? {
        (_, Verb::Route { machine, agent }) => Some((machine, agent)),
        _ => None,
    }
}

/// The route answer from the app's `cloud exec` of the probe: its stdout read as [`probe_answer`] reads the API's.
pub(super) fn app_route_answer(machine: &str, agent: &str, step: Result<Value, Value>) -> Value {
    match step {
        Ok(answer) => probe_answer(
            machine,
            agent,
            answer.get("stdout").and_then(Value::as_str).unwrap_or_default(),
        ),
        Err(error) => {
            let reason = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the cmux app did not run it");
            error_json(
                "machine.exec_failed",
                &format!("the machine did not run the probe: {reason}"),
            )
        }
    }
}

/// Parses and runs a verb; prints its answer.
pub(super) fn run_words(words: &[String], json_out: bool) -> i32 {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let (common, verb) = match parse(words, &env) {
        Ok(p) => p,
        Err(e) => {
            print(&error_json("cli.invalid_args", &e), json_out);
            return 2;
        }
    };
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(r) => r,
        Err(e) => {
            print(&error_json("cli.runtime", &e.to_string()), json_out);
            return 1;
        }
    };
    let (answer, code) = runtime.block_on(run(&common, &verb));
    print(&answer, json_out);
    code
}

#[cfg(test)]
#[path = "inference_gateway_admin_tests.rs"]
mod tests;
