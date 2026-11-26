//! `cmux mcp-servers`: the remote MCP servers a person connects once in cmux (cmux platform
//! `/v1/mcp-servers`), which every agent chat then reaches through cmux's hosted MCP server
//! (acpmux `hosted_mcp.rs`) with no config and no secret on the machine.
//!
//! Settings > Connections is drawn from `catalog --json`: the catalog in rank order, each entry
//! shaped here into the card's view model (`state`, `statusLabel`, `buttonLabel`, `toolsLabel`), so
//! the page only renders. Connect answers the provider's `authorizeUrl` for the browser, or connects
//! at once (a key-auth server, its key read from stdin and never from argv; a server with no auth).
//!
//! Every verb prints one JSON object with `--json`: `{"ok": true, ...}`, or `{"ok": false, "error":
//! {"code", "message"}}` with the platform's own code (`mcp_servers.unavailable`, ...) or this
//! CLI's (`cli.invalid_args`, `api.unreachable`, `api.bad_answer`, `auth.no_token`). A deployment
//! with no catalog yet answers `"available": false`, which the page shows calmly.

use std::io::{IsTerminal, Read};
use std::time::Duration;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::hub::{error_json, platform_for};
use super::inference_gateway::{TokenSource, backend_credential};

pub(super) const HELP: &str = "\
cmux mcp-servers: connect remote MCP servers once; every agent chat gets their tools.

Usage:
  cmux mcp-servers catalog [--json]
  cmux mcp-servers connect <name> [--owner me|team] [--return-to URL] [--key-stdin] [--json]
      (a key-auth server's key is read from stdin; never pass it as an argument)
  cmux mcp-servers remove <connection-id> [--json]
  cmux mcp-servers reconnect <connection-id> [--return-to URL] [--json]
  cmux mcp-servers enable <connection-id> [--json]

A server whose vendor takes only loopback redirects (Vercel) signs in through this Mac: connect and
reconnect listen on http://127.0.0.1:47215/callback (CMUX_MCP_LOOPBACK_PORT) for up to 10 minutes.

Every verb also takes --platform URL (else CMUX_PLATFORM_URL, else the platform of the app's sign-in),
--team TEAM, and --token-file PATH | --token-command CMD (else CMUX_CLOUD_ACCESS_TOKEN, else the app's sign-in).
";

/// The schemes and hosts the platform sends a person back to after a sign-in (its allowlist).
const RETURN_SCHEMES: [&str; 3] = ["cmux://", "cmux-nightly://", "cmux-dev://"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Common {
    pub platform: Option<String>,
    pub team: Option<String>,
    pub token: TokenSource,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verb {
    Catalog,
    Connect { name: String, owner: Option<String>, return_to: Option<String>, key: bool },
    Remove { id: String },
    Reconnect { id: String, return_to: Option<String> },
    Enable { id: String },
}

/// A catalog name or connection id: 1 to 80 of `[A-Za-z0-9_.-]`, safe as a path segment.
pub(super) fn valid_name(value: &str) -> bool {
    (1..=80).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
        && !value.starts_with('.')
}

/// A `return_to` the platform accepts: a cmux link, or an https page on cmux.com.
pub(super) fn valid_return_to(url: &str) -> bool {
    if url.len() > 512 || url.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return false;
    }
    if RETURN_SCHEMES.iter().any(|s| url.starts_with(s)) {
        return true;
    }
    let Some(rest) = url.strip_prefix("https://") else { return false };
    let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
    host == "cmux.com" || host.strip_suffix(".cmux.com").is_some_and(|sub| !sub.is_empty())
}

pub(super) fn parse(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<(Common, Verb), String> {
    let Some((kind, rest)) = words.split_first() else {
        return Err("expected a verb (cmux mcp-servers --help)".into());
    };
    let (mut platform, mut team, mut token) = (None, None, None);
    let (mut owner, mut return_to, mut key) = (None, None, false);
    let mut positionals: Vec<String> = Vec::new();
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
            "--platform" => platform = Some(value()?),
            "--team" => team = Some(value()?),
            "--token-file" => token = Some(TokenSource::File(value()?.into())),
            "--token-command" => token = Some(TokenSource::Command(value()?)),
            "--key" | "--secret" | "--api-key" => {
                return Err("the key is read from stdin, never from an argument".into());
            }
            "--owner" if kind == "connect" => {
                let v = value()?;
                if v != "me" && v != "team" {
                    return Err("--owner is me or team".into());
                }
                owner = Some(v);
            }
            "--return-to" if kind == "connect" || kind == "reconnect" => {
                let v = value()?;
                if !valid_return_to(&v) {
                    return Err("--return-to must be a cmux link or an https cmux.com page".into());
                }
                return_to = Some(v);
            }
            "--key-stdin" if kind == "connect" => key = true,
            f if f.starts_with("--") => return Err(format!("unexpected argument {f}")),
            _ => positionals.push(arg.clone()),
        }
    }
    let one = |what: &str| -> Result<String, String> {
        match positionals.as_slice() {
            [v] if valid_name(v) => Ok(v.clone()),
            [v] => Err(format!("{v:?} is not a {what}")),
            [] => Err(format!("name the {what}")),
            [_, extra, ..] => Err(format!("unexpected argument {extra}")),
        }
    };
    let verb = match kind.as_str() {
        "catalog" | "list" => match positionals.first() {
            Some(extra) => return Err(format!("unexpected argument {extra}")),
            None => Verb::Catalog,
        },
        "connect" => Verb::Connect { name: one("catalog server")?, owner, return_to, key },
        "remove" | "disconnect" => Verb::Remove { id: one("connection id")? },
        "reconnect" => Verb::Reconnect { id: one("connection id")?, return_to },
        "enable" => Verb::Enable { id: one("connection id")? },
        other => return Err(format!("unknown verb {other} (cmux mcp-servers --help)")),
    };
    let token = token.unwrap_or_else(|| {
        if env("CMUX_CLOUD_ACCESS_TOKEN").is_some() { TokenSource::Env } else { TokenSource::App }
    });
    let platform = match platform.or_else(|| env("CMUX_PLATFORM_URL")) {
        Some(p) => Some(
            super::cloud_client_session::secure_origin(p.trim())
                .map_err(|m| m.replace("the cmux API", "the cmux platform"))?,
        ),
        None => None,
    };
    Ok((Common { platform, team, token }, verb))
}

/// Set `key` on a JSON object; a non-object is left alone (no panicking index).
fn put(target: &mut Value, key: &str, value: Value) {
    if let Some(map) = target.as_object_mut() {
        map.insert(key.to_owned(), value);
    }
}

/// One request under `/v1/mcp-servers`: method, path and body (the key added at send time).
pub(super) fn request_of(verb: &Verb) -> (&'static str, String, Option<Value>) {
    match verb {
        Verb::Catalog => ("GET", "/catalog".into(), None),
        Verb::Connect { name, owner, return_to, .. } => {
            let mut body = json!({"catalog": name, "owner": owner.as_deref().unwrap_or("me")});
            if let Some(r) = return_to {
                put(&mut body, "return_to", json!(r));
            }
            ("POST", "/connect".into(), Some(body))
        }
        Verb::Remove { id } => ("POST", format!("/{id}/remove"), None),
        Verb::Reconnect { id, return_to } => {
            let body = return_to.as_ref().map(|r| json!({"return_to": r})).unwrap_or(json!({}));
            ("POST", format!("/{id}/reconnect"), Some(body))
        }
        Verb::Enable { id } => ("POST", format!("/{id}/enable"), None),
    }
}

fn clean(text: &str, max: usize) -> String {
    let flat: String =
        text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect::<String>();
    let flat = flat.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= max {
        return flat;
    }
    let mut cut: String = flat.chars().take(max.saturating_sub(1)).collect();
    cut.push('…');
    cut
}

fn text<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
}

/// The plain words for why a catalog entry cannot be connected here.
pub(super) fn unavailable_text(reason: Option<&str>) -> String {
    match reason.unwrap_or_default() {
        "" => "Not available on this deployment yet.".into(),
        "not_configured" | "not_set_up" => "Not set up on this deployment yet.".into(),
        "team_policy" | "policy" => "Your team's policy turns this off.".into(),
        "plan" => "Not included in your plan.".into(),
        other if other.contains(' ') => clean(other, 120),
        other => format!("Not available here ({}).", clean(other, 60)),
    }
}

/// An RFC 3339 instant as the platform writes it (`2026-12-01T09:00:00Z`): a date, a `T`, at most 40
/// characters of digits and separators. Anything else is dropped rather than shown.
fn looks_like_time(at: &str) -> bool {
    let b = at.as_bytes();
    at.len() >= 20
        && at.len() <= 40
        && b[..4].iter().all(u8::is_ascii_digit)
        && b[4] == b'-'
        && b[10] == b'T'
        && at.bytes().all(|c| c.is_ascii_digit() || b"-:.TZ+".contains(&c))
}

fn tools_label(count: u64) -> String {
    if count == 1 { "1 tool".into() } else { format!("{count} tools") }
}

/// One catalog entry as the card draws it. `state` is the one button the row shows:
/// `connect`, `connected`, `reconnect` (its sign-in lapsed or the server stopped answering),
/// `enable` (its tools changed and wait for the person's OK) or `unavailable`.
pub(super) fn entry_view(entry: &Value) -> Value {
    let name = text(entry, "name").unwrap_or_default();
    let title = text(entry, "title").map_or_else(|| name.to_owned(), |t| clean(t, 60));
    let auth = text(entry, "auth").unwrap_or("none");
    let available = entry.get("available").and_then(Value::as_bool).unwrap_or(true);
    let connection = entry.get("connection").filter(|c| c.is_object());
    let mut view = json!({
        "name": name,
        "title": title,
        "line": clean(text(entry, "description").unwrap_or_default(), 140),
        "auth": auth,
        "rank": entry.get("rank").and_then(Value::as_f64).unwrap_or(f64::MAX),
        "category": text(entry, "category"),
        "docsUrl": text(entry, "docsUrl").filter(|u| u.starts_with("https://")),
        "available": available,
        "loopback": text(entry, "redirect") == Some("loopback"),
        "upcoming": upcoming(entry),
        "keyField": false,
        "connectionId": null,
        "owner": null,
        "ownerLabel": null,
        "toolCount": null,
        "toolsLabel": null,
        "expiresAt": null,
    });
    let Some(connection) = connection else {
        if !available {
            put(&mut view, "state", json!("unavailable"));
            put(
                &mut view,
                "statusLabel",
                json!(unavailable_text(text(entry, "unavailableReason"))),
            );
            put(&mut view, "buttonLabel", Value::Null);
        } else {
            put(&mut view, "state", json!("connect"));
            put(&mut view, "statusLabel", Value::Null);
            put(&mut view, "buttonLabel", json!("Connect"));
            put(&mut view, "keyField", json!(auth == "key"));
        }
        return view;
    };
    let count = connection.get("toolCount").and_then(Value::as_u64).unwrap_or(0);
    let owner = text(connection, "owner").unwrap_or("me");
    put(&mut view, "connectionId", json!(text(connection, "id")));
    put(&mut view, "owner", json!(owner));
    put(&mut view, "ownerLabel", json!(if owner == "team" { "Team" } else { "Personal" }));
    put(&mut view, "toolCount", json!(count));
    put(&mut view, "toolsLabel", json!(tools_label(count)));
    // When the provider's sign-in lapses (RFC 3339), so the card can offer Reconnect before it does.
    put(
        &mut view,
        "expiresAt",
        json!(text(connection, "expiresAt").filter(|at| looks_like_time(at))),
    );
    let (state, status, button) = match text(connection, "status").unwrap_or("ready") {
        "ready" => ("connected", format!("Connected · {}", tools_label(count)), None),
        "changed" => {
            ("enable", "Its tools changed: review and turn them on".into(), Some("Enable"))
        }
        "unreachable" => ("reconnect", "Not answering".to_owned(), Some("Reconnect")),
        "needs_auth" => ("reconnect", "Sign in again".to_owned(), Some("Reconnect")),
        other => ("reconnect", clean(other, 40), Some("Reconnect")),
    };
    put(&mut view, "state", json!(state));
    put(&mut view, "statusLabel", json!(status));
    put(&mut view, "buttonLabel", json!(button));
    view
}

/// Catalog servers the page shows only with Settings > Labs > Upcoming Connections on
/// (`labs.connectionsUpcoming`, off by default): Slack and Google, which come to agents through the
/// integrations hub's providers today and go live in the catalog once cmux's client for each is
/// registered (until then the platform answers them `not_set_up`). One already connected always
/// shows, so it can be disconnected.
pub(super) fn upcoming(entry: &Value) -> bool {
    let name = text(entry, "name").unwrap_or_default();
    let vendor = name == "slack" || name == "gmail" || name.starts_with("google");
    vendor && entry.get("connection").is_none_or(Value::is_null)
}

/// The catalog answer as the card's view model: entries in rank order, then by title.
pub(super) fn catalog_view(body: &Value) -> Value {
    let mut entries: Vec<Value> = body
        .get("entries")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter(|e| text(e, "name").is_some_and(valid_name))
                .map(entry_view)
                .collect()
        })
        .unwrap_or_default();
    entries.sort_by(|a, b| {
        let rank = |v: &Value| v["rank"].as_f64().unwrap_or(f64::MAX);
        rank(a).total_cmp(&rank(b)).then_with(|| a["title"].as_str().cmp(&b["title"].as_str()))
    });
    let connected = entries.iter().filter(|e| e["connectionId"].is_string()).count();
    json!({"ok": true, "available": true, "entries": entries, "connected": connected})
}

/// The platform's error, kept with its own code and a short message a person reads.
pub(super) fn api_error(status: u16, body: &Value) -> Value {
    let field = |p: &str| body.pointer(p).and_then(Value::as_str).map(|s| clean(s, 300));
    let code = field("/error/code").unwrap_or_else(|| "api.bad_answer".into());
    let message = field("/error/message").unwrap_or_else(|| match code.as_str() {
        "mcp_servers.already_connected" => "That server is already connected.".into(),
        "mcp_servers.discovery_failed" => "The server did not answer its sign-in discovery.".into(),
        "mcp_servers.registration_failed" => {
            "The server refused cmux's sign-in registration.".into()
        }
        "mcp_servers.unavailable" => "That server is not available here.".into(),
        "mcp_servers.catalog_unknown" => "That server is not in the catalog.".into(),
        "mcp_servers.loopback_required" => {
            "That server signs in through this Mac; run `cmux mcp-servers connect NAME` to sign in."
                .into()
        }
        _ => format!("the cmux platform answered HTTP {status}"),
    });
    let mut error = error_json(&code, &message);
    put(&mut error, "status", json!(status));
    error
}

/// A verb's answer from the platform's status and body.
pub(super) fn answer(verb: &Verb, status: u16, body: &Value) -> Value {
    if matches!(verb, Verb::Catalog) && status == 404 {
        return json!({"ok": true, "available": false, "entries": [], "connected": 0,
            "message": "Connections are not available on this deployment yet."});
    }
    if !(200..300).contains(&status) || !body.is_object() {
        return api_error(status, body);
    }
    match verb {
        Verb::Catalog => catalog_view(body),
        Verb::Connect { .. } | Verb::Reconnect { .. } => {
            match text(body, "authorize_url").or_else(|| text(body, "authorizeUrl")) {
                Some(url) if url.starts_with("https://") => {
                    json!({"ok": true, "authorizeUrl": url})
                }
                Some(_) => error_json("api.bad_answer", "the sign-in page is not an https URL"),
                None => json!({"ok": true, "connected": true,
                    "held": body.get("held").cloned().unwrap_or(Value::Null)}),
            }
        }
        Verb::Remove { id } => json!({"ok": true, "removed": id}),
        Verb::Enable { id } => json!({"ok": true, "enabled": id}),
    }
}

async fn run(common: &Common, verb: &Verb, key: Option<Zeroizing<String>>) -> Value {
    let (token, issued_by) = match backend_credential(&common.token, common.team.as_deref()).await {
        Ok(t) => t,
        Err(e) => return error_json("auth.no_token", &e),
    };
    let token = Zeroizing::new(token);
    let platform = match platform_for(common.platform.as_deref(), issued_by.as_deref()) {
        Ok(p) => p,
        Err(e) => return error_json("cli.invalid_args", &e),
    };
    let http = match cmux_egress::client_builder("cmux_tui::cli::mcp_servers")
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(45))
        .build()
    {
        Ok(h) => h,
        Err(e) => return error_json("cli.http_client", &e.to_string()),
    };
    let (method, path, body) = request_of(verb);
    let mut url = format!("{platform}/v1/mcp-servers{path}");
    if let Some(team) = &common.team {
        url.push_str("?team=");
        url.push_str(
            &team
                .bytes()
                .filter(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
                .map(char::from)
                .collect::<String>(),
        );
    }
    let send = |body: Option<Value>| {
        let mut builder = match method {
            "POST" => http.post(&url),
            _ => http.get(&url),
        }
        .bearer_auth(token.as_str())
        .header("accept", "application/json");
        if let Some(team) = &common.team {
            builder = builder.header("x-cmux-team", team.as_str());
        }
        if method == "POST" {
            let mut body = body.unwrap_or_else(|| json!({}));
            if let Some(key) = &key {
                put(&mut body, "key", json!(key.as_str()));
            }
            let sent = Zeroizing::new(body.to_string());
            if let Some(map) = body.as_object_mut()
                && let Some(Value::String(mut k)) = map.remove("key")
            {
                zeroize::Zeroize::zeroize(&mut k);
            }
            builder =
                builder.header("content-type", "application/json").body(sent.as_str().to_owned());
        }
        async move {
            let response = match builder.send().await {
                Ok(r) => r,
                Err(_) => return error_json("api.unreachable", "the cmux platform did not answer"),
            };
            let status = response.status().as_u16();
            let bytes = match response.bytes().await {
                Ok(b) => b,
                Err(_) => {
                    return error_json("api.unreachable", "the cmux platform's answer was cut off");
                }
            };
            match serde_json::from_slice::<Value>(&bytes) {
                Ok(v) => answer(verb, status, &v),
                Err(_) if status == 404 => answer(verb, status, &json!({})),
                Err(_) => error_json(
                    "api.bad_answer",
                    &format!("the platform answered HTTP {status}, not JSON"),
                ),
            }
        }
    };
    let first = send(body.clone()).await;
    if !loopback_required(verb, &first) {
        return first;
    }
    // A vendor that takes only loopback redirects (Vercel): listen on this Mac's fixed port, then
    // ask again naming it (mcp_loopback.rs).
    let port = super::mcp_loopback::port();
    let forward = format!("{platform}{}", super::mcp_loopback::CALLBACK_PATH);
    if let Err(message) = super::mcp_loopback::ensure(port, &forward) {
        return error_json("cli.loopback_unavailable", &message);
    }
    send(Some(with_loopback_port(body, port))).await
}

/// A Connect or Reconnect the platform answered `mcp_servers.loopback_required`.
pub(super) fn loopback_required(verb: &Verb, answer: &Value) -> bool {
    matches!(verb, Verb::Connect { .. } | Verb::Reconnect { .. })
        && answer.pointer("/error/code").and_then(Value::as_str)
            == Some("mcp_servers.loopback_required")
}

/// The request body again, naming the port the sign-in comes back to.
pub(super) fn with_loopback_port(body: Option<Value>, port: u16) -> Value {
    let mut body = body.unwrap_or_else(|| json!({}));
    put(&mut body, "loopback_port", json!(port));
    body
}

/// The key from stdin (the app pipes it): trimmed, at most 4 KiB, never echoed.
fn read_key() -> Result<Zeroizing<String>, Value> {
    let stdin = std::io::stdin();
    if stdin.is_terminal() {
        return Err(error_json("cli.invalid_args", "pipe the key on stdin"));
    }
    let mut raw = Zeroizing::new(String::new());
    if stdin.lock().take(4096).read_to_string(&mut raw).is_err() {
        return Err(error_json("cli.invalid_args", "could not read the key from stdin"));
    }
    let key = raw.trim();
    if key.is_empty() || key.contains(char::is_whitespace) {
        return Err(error_json("cli.invalid_args", "paste the server's key"));
    }
    Ok(Zeroizing::new(key.to_owned()))
}

fn print(answer: &Value, json_out: bool) {
    if json_out {
        println!("{answer}");
        return;
    }
    if answer.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = answer.pointer("/error/code").and_then(Value::as_str).unwrap_or("error");
        let message = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or_default();
        eprintln!("cmux mcp-servers: {code}: {message}");
        return;
    }
    if let Some(message) = text(answer, "message") {
        println!("{message}");
    }
    for e in answer.get("entries").and_then(Value::as_array).into_iter().flatten() {
        let status = text(e, "statusLabel").or(text(e, "buttonLabel")).unwrap_or_default();
        println!(
            "{}  {}  {status}",
            text(e, "name").unwrap_or_default(),
            text(e, "title").unwrap_or_default()
        );
    }
    if let Some(url) = text(answer, "authorizeUrl") {
        println!("Open this page to sign in: {url}");
    }
    if answer.get("connected") == Some(&json!(true)) {
        println!("connected");
    }
    if let Some(id) = text(answer, "removed") {
        println!("removed {id}");
    }
    if let Some(id) = text(answer, "enabled") {
        println!("enabled {id}");
    }
}

/// `Some(exit code)` for `cmux mcp-servers …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_action_globals(args).ok()?;
    let rest = match command_args.as_slice() {
        [h, rest @ ..] if h == "mcp-servers" => rest,
        _ => return None,
    };
    if let [verb, serve_args @ ..] = rest {
        if verb == "loopback-serve" {
            return Some(super::mcp_loopback::serve_main(serve_args));
        }
    }
    if rest.is_empty()
        || rest.iter().any(|a| a == "--help" || a == "-h")
        || rest.first().is_some_and(|a| a == "help")
    {
        print!("{HELP}");
        return Some(0);
    }
    let json_out = global.output == super::OutputMode::Json;
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let (common, verb) = match parse(rest, &env) {
        Ok(p) => p,
        Err(e) => {
            print(&error_json("cli.invalid_args", &e), json_out);
            return Some(2);
        }
    };
    let key = match &verb {
        Verb::Connect { key: true, .. } => match read_key() {
            Ok(k) => Some(k),
            Err(e) => {
                print(&e, json_out);
                return Some(2);
            }
        },
        _ => None,
    };
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(r) => r,
        Err(e) => {
            print(&error_json("cli.runtime", &e.to_string()), json_out);
            return Some(1);
        }
    };
    let answer = runtime.block_on(run(&common, &verb, key));
    print(&answer, json_out);
    Some(if answer.get("ok").and_then(Value::as_bool) == Some(true) { 0 } else { 1 })
}

#[cfg(test)]
#[path = "mcp_servers_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "mcp_servers_seeded_tests.rs"]
mod seeded_tests;
