//! The inference gateway's state and route, as CLI verbs a person or a test runner can drive (`--json`):
//!
//! - `cmux inference gateway status [--personal]`: the team's (or the person's own) gateway: mode, named machine,
//!   whether a gateway is online, its kind and since when (`GET /v1/cloud/inference-gateway[/personal]`).
//! - `cmux inference gateway mode gateway|off [--personal] [--gateway-machine vm_… | --no-gateway-machine]`: sets it
//!   (`PUT`). The person's own gateway serves every machine they created, in any team; the team's serves the team.
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
use super::inference_gateway::{TokenSource, backend_token};
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
  cmux inference gateway mode gateway|off [--personal]
                         [--gateway-machine vm_... | --no-gateway-machine] [--json]
";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Common {
    pub api: String,
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
            "gateway" | "off" if kind == "mode" && mode.is_none() => mode = Some(arg.clone()),
            _ => return Err(format!("unexpected argument {arg}")),
        }
    }
    let api = api
        .or_else(|| env("CMUX_CLOUD_API_URL"))
        .ok_or("--api (or CMUX_CLOUD_API_URL) names the cmux API")?;
    let api = secure_origin(&api)?;
    let token = token.unwrap_or_else(|| {
        if env("CMUX_CLOUD_ACCESS_TOKEN").is_some() { TokenSource::Env } else { TokenSource::App }
    });
    let verb = match kind {
        "status" => Verb::Status { personal },
        "mode" => {
            if let Some(Some(m)) = &gateway_machine
                && !valid_machine(m)
            {
                return Err("--gateway-machine takes a machine id (vm_...)".into());
            }
            Verb::Mode {
                personal,
                mode: mode.ok_or("mode takes gateway or off")?,
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

/// The admin path for `personal`.
pub(super) fn route_path(personal: bool) -> &'static str {
    if personal { "/v1/cloud/inference-gateway/personal" } else { "/v1/cloud/inference-gateway" }
}

/// The verb's JSON answer and exit code (0 ok, 1 refused or failed).
pub(super) async fn run(common: &Common, verb: &Verb) -> (Value, i32) {
    let token = match backend_token(&common.token, common.team.as_deref()).await {
        Ok(t) => t,
        Err(e) => return (error_json("auth.no_token", &e), 1),
    };
    let http = match reqwest::Client::builder()
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
            let url = format!("{}{}", common.api, route_path(*personal));
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
        Verb::Route { machine, agent } => route(&http, common, &token, machine, agent).await,
    };
    let ok = answer.get("ok").and_then(Value::as_bool) == Some(true);
    (answer, if ok { 0 } else { 1 })
}

/// The status or mode answer, scoped: `{ok, scope, gateway}` or the API's error object.
pub(super) fn status_answer(personal: bool, body: &Value) -> Value {
    match body.get("gateway") {
        Some(gateway) if body.get("ok").and_then(Value::as_bool) == Some(true) => {
            json!({"ok": true, "scope": if personal { "personal" } else { "team" }, "gateway": gateway})
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
    common: &Common,
    token: &str,
    machine: &str,
    agent: &str,
) -> Value {
    let request = Request {
        api: common.api.clone(),
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
    Some(run_words(&words, global.output == super::OutputMode::Json))
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
mod tests {
    use super::*;

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }
    fn env(k: &str) -> Option<String> {
        (k == "CMUX_CLOUD_API_URL").then(|| "https://api.cmux.test".to_owned())
    }

    #[test]
    fn parses_status_mode_and_route() {
        let (c, v) = parse(&words(&["status", "--personal"]), &env).unwrap();
        assert_eq!(c.api, "https://api.cmux.test");
        assert_eq!(v, Verb::Status { personal: true });
        let (_, v) = parse(
            &words(&["mode", "gateway", "--gateway-machine", "vm_abcdefghij0123456789"]),
            &env,
        )
        .unwrap();
        assert_eq!(
            v,
            Verb::Mode {
                personal: false,
                mode: "gateway".into(),
                machine: Some(Some("vm_abcdefghij0123456789".into()))
            }
        );
        let (_, v) =
            parse(&words(&["mode", "off", "--no-gateway-machine", "--personal"]), &env).unwrap();
        assert_eq!(v, Verb::Mode { personal: true, mode: "off".into(), machine: Some(None) });
        let (_, v) = parse(
            &words(&["route", "--machine", "vm_abcdefghij0123456789", "--agent", "claude"]),
            &env,
        )
        .unwrap();
        assert_eq!(
            v,
            Verb::Route { machine: "vm_abcdefghij0123456789".into(), agent: "claude".into() }
        );
        assert!(parse(&words(&["mode"]), &env).is_err());
        assert!(parse(&words(&["mode", "on"]), &env).is_err());
        assert!(parse(&words(&["route", "--machine", "nope"]), &env).is_err());
        assert!(
            parse(
                &words(&["route", "--machine", "vm_abcdefghij0123456789", "--agent", "gemini"]),
                &env
            )
            .is_err()
        );
        assert!(parse(&words(&["status", "--machine", "vm_abcdefghij0123456789"]), &env).is_err());
    }

    #[test]
    fn scopes_the_status_and_keeps_api_error_codes() {
        let ok = json!({"ok": true, "gateway": {"mode": "gateway", "online": true}});
        assert_eq!(
            status_answer(true, &ok),
            json!({"ok": true, "scope": "personal", "gateway": {"mode": "gateway", "online": true}})
        );
        let refused = json!({"ok": false, "error": {"code": "auth.forbidden", "message": "no"}});
        assert_eq!(status_answer(false, &refused), error_json("auth.forbidden", "no"));
        assert_eq!(route_path(true), "/v1/cloud/inference-gateway/personal");
    }

    #[test]
    fn reads_the_machine_probe() {
        let body = r#"{"ok":true,"route":"owner_gateway","agent":"claude"}"#;
        assert_eq!(
            probe_answer("vm_x", "claude", &format!("{body}\n200"))["route"],
            "owner_gateway"
        );
        assert_eq!(probe_answer("vm_x", "codex", "not found\n404")["route"], "shared_coderouter");
        assert_eq!(
            probe_answer("vm_x", "codex", "\n000")["error"]["code"],
            "machine.edge_unreachable"
        );
        let err = r#"{"error":{"code":"inference.keys_unreachable","message":"retry"}}"#;
        assert_eq!(
            probe_answer("vm_x", "codex", &format!("{err}\n503"))["error"]["code"],
            "inference.keys_unreachable"
        );
        assert!(probe_command("claude").ends_with("/v1/cmux/route?agent=claude'"));
        assert!(!probe_command("claude").contains("x-cmux-inference-authorization"));
    }
}
