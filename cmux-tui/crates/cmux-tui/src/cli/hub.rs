//! `cmux hub`: the integrations hub (cmux platform `/v1/hub`) as CLI verbs a person, an agent or the app drives.
//!
//! A person links an account once (`cmux hub link stripe`, the restricted key read from stdin or a hidden prompt,
//! never from argv), and their agents call typed actions on it (`cmux hub call stripe.refund.create --args '{...}'`)
//! under rules, with approvals and an audit log. The hub decides; this CLI only asks and shapes the answers.
//!
//! Approvals are read only here: a person answers one with a click in cmux Settings > Integrations. A lane running
//! this CLI holds the person's session token, so an answer verb would let it approve its own agent's refund.
//!
//! Every verb prints one JSON object with `--json`: `{"ok": true, ...}`, or `{"ok": false, "error": {"code",
//! "message"}}` with the hub's own code (`stripe.key_refused`, `approval.gone`, ...) or this CLI's (`cli.invalid_args`,
//! `api.unreachable`, `api.bad_answer`, `auth.no_token`). A deployment with no hub answers `hub.not_found` with
//! `"available": false`, which the app shows as "not available here yet", not as a failure.
//!
//! The view-model fields (`line`, `text`, `amountText`, the labels) are shaped here, not in the app: the Settings card
//! renders only what this returns.

use std::io::{BufRead, IsTerminal, Read, Write};
use std::time::Duration;

use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::inference_gateway::{TokenSource, backend_credential};

pub(super) const HELP: &str = "\
cmux hub: link accounts (Stripe, GitHub) and let your agents call them under your rules.

Usage:
  cmux hub overview [--audit-limit N] [--json]
  cmux hub connections [--json]
  cmux hub link stripe [--sharing private|team] [--policy ask|block] [--json]
      (the restricted key is read from stdin, or a hidden prompt; never pass it as an argument)
  cmux hub link github [--sharing private|team] [--json]
      (no key: it uses the GitHub connection you made in cmux)
  cmux hub remove <connection-id> [--json]
  cmux hub actions [--json]
  cmux hub call <action> [--FIELD VALUE ... | --args JSON] [--connection ID] [--invocation-id ID] [--json]
      e.g. cmux hub call stripe.refund.create --charge ch_123 --amount 4200
      (field values use JSON when valid, or plain text; use --args for reserved flag names)
  cmux hub status <call-id> [--json]
  cmux hub approvals [--json]
      (read only: a person answers an approval in cmux Settings > Integrations, never from this CLI)
  cmux hub policy [--json]
  cmux hub rule add --action NAME --effect allow|ask|block [--owner team|user] [--connection ID]
                    [--agent NAME] [--amount-lte MINOR] [--amount-gt MINOR] [--currency CUR] [--repo OWNER/NAME]
                    [--limit-window day|month [--limit-amount MINOR] [--limit-calls N] [--limit-over ask|block]]
                    [--expires-at UNIX_MS] [--json]
  cmux hub rule remove <rule-id> [--json]
  cmux hub pause | resume [--json]
  cmux hub audit [--limit N] [--before SEQ] [--json]

Every verb also takes --platform URL (else CMUX_PLATFORM_URL, else the platform of the app's sign-in),
--team TEAM, and --token-file PATH | --token-command CMD (else CMUX_CLOUD_ACCESS_TOKEN, else the app's sign-in).
";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Common {
    /// The platform origin named (`--platform`, `CMUX_PLATFORM_URL`); `None`: the one of the token's deployment.
    pub platform: Option<String>,
    pub team: Option<String>,
    pub token: TokenSource,
}

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Verb {
    Overview {
        audit_limit: u32,
    },
    Connections,
    Link {
        /// `stripe` (a restricted key on stdin) or `github` (no key).
        provider: String,
        sharing: Option<String>,
        policy: Option<String>,
    },
    Remove {
        id: String,
    },
    Actions,
    Call {
        action: String,
        args: Option<Value>,
        connection: Option<String>,
        invocation_id: Option<String>,
    },
    Status {
        id: String,
    },
    Approvals,
    Policy,
    RuleAdd {
        rule: Value,
    },
    RuleRemove {
        id: String,
    },
    Pause {
        paused: bool,
    },
    Audit {
        limit: Option<u32>,
        before: Option<u64>,
    },
}

/// One HTTP request to the hub, before the credential and origin are added.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct HubRequest {
    pub method: &'static str,
    /// Under `/v1/hub`, with path segments already validated.
    pub path: String,
    pub query: Vec<(&'static str, String)>,
    pub body: Option<Value>,
}

/// The error object every verb prints on failure.
pub(super) fn error_json(code: &str, message: &str) -> Value {
    json!({"ok": false, "error": {"code": code, "message": message}})
}

/// An id the hub minted: `prefix` and 1 to 64 of `[A-Za-z0-9_-]`, so it is safe as a path segment.
pub(super) fn valid_id(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix).is_some_and(|rest| {
        (1..=64).contains(&rest.len())
            && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    })
}

fn one_of(value: &str, allowed: &[&str], flag: &str) -> Result<String, String> {
    if allowed.contains(&value) {
        Ok(value.to_owned())
    } else {
        Err(format!("{flag} is {}", allowed.join(" or ")))
    }
}

fn number<T: std::str::FromStr>(value: &str, flag: &str) -> Result<T, String> {
    value.parse().map_err(|_| format!("{flag} takes a whole number"))
}

/// An action name as the hub takes it in a rule: `stripe.refund.create`, `stripe.*` or `*`.
pub(super) fn valid_action_pattern(name: &str) -> bool {
    if name == "*" {
        return true;
    }
    let body = name.strip_suffix(".*").unwrap_or(name);
    !body.is_empty()
        && body.len() <= 128
        && body.split('.').all(|part| {
            !part.is_empty()
                && part.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        })
}

/// Parses the words after `hub`.
pub(super) fn parse(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<(Common, Verb), String> {
    let (kind, rest): (String, &[String]) = match words {
        [r, sub, rest @ ..] if r == "rule" && (sub == "add" || sub == "remove") => {
            (format!("rule {sub}"), rest)
        }
        [w, rest @ ..] => (w.clone(), rest),
        [] => return Err("expected a verb (cmux hub --help)".into()),
    };
    // Refused before any flag is read, so `approve ID --remember` gets this answer and not "unexpected argument".
    if matches!(kind.as_str(), "approve" | "deny" | "answer") {
        return Err(
            "approvals are answered by a person in cmux Settings > Integrations, not from the CLI"
                .into(),
        );
    }
    let mut platform = None;
    let mut team = None;
    let mut token = None;
    let mut positionals: Vec<String> = Vec::new();
    let mut values: Map<String, Value> = Map::new();
    let mut action_fields = Map::new();
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
        let verb_flags: &[&str] = match kind.as_str() {
            "overview" => &["--audit-limit"],
            "link" => &["--sharing", "--policy"],
            "call" => &["--args", "--connection", "--invocation-id"],
            "audit" => &["--limit", "--before"],
            "rule add" => &[
                "--owner",
                "--action",
                "--effect",
                "--connection",
                "--agent",
                "--amount-lte",
                "--amount-gt",
                "--currency",
                "--repo",
                "--limit-window",
                "--limit-amount",
                "--limit-calls",
                "--limit-over",
                "--expires-at",
            ],
            _ => &[],
        };
        match flag {
            "--platform" => platform = Some(value()?),
            "--team" => team = Some(value()?),
            "--token-file" => token = Some(TokenSource::File(value()?.into())),
            "--token-command" => token = Some(TokenSource::Command(value()?)),
            "--key" | "--secret" | "--api-key" => {
                return Err("the key is read from stdin or a prompt, never from an argument".into());
            }
            f if verb_flags.contains(&f) => {
                values.insert(f.trim_start_matches("--").to_owned(), Value::String(value()?));
            }
            f if kind == "call" && f.starts_with("--") && f.len() > 2 => {
                let raw = match inline {
                    Some(raw) => raw,
                    None => args
                        .next()
                        .filter(|v| !v.starts_with("--"))
                        .cloned()
                        .ok_or_else(|| format!("{f} needs a value"))?,
                };
                let field = f.strip_prefix("--").unwrap_or(f);
                let parsed = serde_json::from_str(&raw).unwrap_or(Value::String(raw));
                if action_fields.insert(field.to_owned(), parsed).is_some() {
                    return Err(format!("duplicate action field {f}"));
                }
            }
            f if f.starts_with("--") => return Err(format!("unexpected argument {f}")),
            _ => positionals.push(arg.clone()),
        }
    }
    let text = |k: &str| values.get(k).and_then(Value::as_str).map(str::to_owned);
    let positional = |what: &str, prefix: &str| -> Result<String, String> {
        match positionals.as_slice() {
            [id] if valid_id(id, prefix) => Ok(id.clone()),
            [id] => Err(format!("{id:?} is not a {what} id ({prefix}...)")),
            [] => Err(format!("name the {what} ({prefix}...)")),
            [_, extra, ..] => Err(format!("unexpected argument {extra}")),
        }
    };
    let none = |verb: Verb| -> Result<Verb, String> {
        match positionals.first() {
            Some(extra) => Err(format!("unexpected argument {extra}")),
            None => Ok(verb),
        }
    };
    let verb = match kind.as_str() {
        "overview" => {
            let audit_limit = match text("audit-limit") {
                Some(v) => number::<u32>(&v, "--audit-limit")?,
                None => 20,
            };
            if !(1..=200).contains(&audit_limit) {
                return Err("--audit-limit is 1 to 200".into());
            }
            none(Verb::Overview { audit_limit })?
        }
        "connections" => none(Verb::Connections)?,
        "link" => {
            let provider = match positionals.as_slice() {
                [p] if p == "stripe" || p == "github" => p.clone(),
                [p] => return Err(format!("{p} cannot be linked here yet; link stripe or github")),
                [] => return Err("name the provider: cmux hub link stripe | github".into()),
                [_, extra, ..] => return Err(format!("unexpected argument {extra}")),
            };
            let sharing = text("sharing")
                .map(|s| one_of(&s, &["private", "team"], "--sharing"))
                .transpose()?;
            let policy =
                text("policy").map(|s| one_of(&s, &["ask", "block"], "--policy")).transpose()?;
            if provider == "github" && policy.is_some() {
                return Err("--policy is for Stripe; GitHub reads follow your rules".into());
            }
            Verb::Link { provider, sharing, policy }
        }
        "remove" => Verb::Remove { id: positional("connection", "hubc_")? },
        "actions" => none(Verb::Actions)?,
        "call" => {
            let action = match positionals.as_slice() {
                [a] if valid_action_pattern(a) && !a.ends_with('*') => a.clone(),
                [a] => return Err(format!("{a:?} is not an action name")),
                [] => return Err("name the action (cmux hub actions lists them)".into()),
                [_, extra, ..] => return Err(format!("unexpected argument {extra}")),
            };
            let args = match text("args") {
                Some(_) if !action_fields.is_empty() => {
                    return Err("pass action fields individually or in --args".into());
                }
                Some(raw) => match serde_json::from_str::<Value>(&raw) {
                    Ok(v @ Value::Object(_)) => Some(v),
                    _ => return Err("--args takes a JSON object".into()),
                },
                None if !action_fields.is_empty() => Some(Value::Object(action_fields)),
                None => None,
            };
            let connection = text("connection");
            if let Some(c) = &connection
                && !valid_id(c, "hubc_")
            {
                return Err("--connection takes a connection id (hubc_...)".into());
            }
            let invocation_id = text("invocation-id");
            if let Some(i) = &invocation_id
                && !(8..=128).contains(&i.len())
            {
                return Err("--invocation-id is 8 to 128 characters".into());
            }
            Verb::Call { action, args, connection, invocation_id }
        }
        "status" => Verb::Status { id: positional("call", "hcall_")? },
        "approvals" => none(Verb::Approvals)?,
        "policy" => none(Verb::Policy)?,
        "rule add" => none(Verb::RuleAdd { rule: rule_body(&values)? })?,
        "rule remove" => Verb::RuleRemove { id: positional("rule", "hubr_")? },
        "pause" => none(Verb::Pause { paused: true })?,
        "resume" => none(Verb::Pause { paused: false })?,
        "audit" => {
            let limit = text("limit").map(|v| number::<u32>(&v, "--limit")).transpose()?;
            if limit.is_some_and(|l| !(1..=200).contains(&l)) {
                return Err("--limit is 1 to 200".into());
            }
            let before = text("before").map(|v| number::<u64>(&v, "--before")).transpose()?;
            if before == Some(0) {
                return Err("--before takes a row's seq (1 or more)".into());
            }
            none(Verb::Audit { limit, before })?
        }
        "rule" => return Err("rule add or rule remove".into()),
        other => return Err(format!("unknown verb {other} (cmux hub --help)")),
    };
    let token = token.unwrap_or_else(|| {
        if env("CMUX_CLOUD_ACCESS_TOKEN").is_some() { TokenSource::Env } else { TokenSource::App }
    });
    let platform = match platform.or_else(|| env("CMUX_PLATFORM_URL")) {
        Some(p) => Some(
            super::cloud_client_session::secure_origin(p.trim())
                .map_err(|m| m.replace("the cmux API", "the cmux platform"))?,
        )
        // The person named this platform (--platform or the env); a redirect off it is still checked.
        .inspect(|p| cmux_egress::allow_named(p)),
        None => None,
    };
    Ok((Common { platform, team, token }, verb))
}

/// The body of `rule add`, from its flags.
pub(super) fn rule_body(values: &Map<String, Value>) -> Result<Value, String> {
    let text = |k: &str| values.get(k).and_then(Value::as_str);
    let action = text("action").ok_or("--action names the action (a name, prefix.* or *)")?;
    if !valid_action_pattern(action) {
        return Err(format!("{action:?} is not an action name, prefix.* or *"));
    }
    let effect = one_of(
        text("effect").ok_or("--effect is allow, ask or block")?,
        &["allow", "ask", "block"],
        "--effect",
    )?;
    let owner = one_of(text("owner").unwrap_or("user"), &["team", "user"], "--owner")?;
    let mut rule = Map::new();
    rule.insert("owner".into(), json!(owner));
    rule.insert("action".into(), json!(action));
    rule.insert("effect".into(), json!(effect));
    if let Some(c) = text("connection") {
        if !valid_id(c, "hubc_") {
            return Err("--connection takes a connection id (hubc_...)".into());
        }
        rule.insert("connection".into(), json!(c));
    }
    if let Some(a) = text("agent") {
        rule.insert("agent".into(), json!(a));
    }
    let mut when = Map::new();
    if let Some(v) = text("amount-lte") {
        when.insert("amountLte".into(), json!(number::<u64>(v, "--amount-lte")?));
    }
    if let Some(v) = text("amount-gt") {
        when.insert("amountGt".into(), json!(number::<u64>(v, "--amount-gt")?));
    }
    if let Some(v) = text("currency") {
        if v.len() != 3 || !v.bytes().all(|b| b.is_ascii_alphabetic()) {
            return Err("--currency is a three-letter code (usd)".into());
        }
        when.insert("currency".into(), json!(v.to_ascii_lowercase()));
    }
    if let Some(v) = text("repo") {
        when.insert("repo".into(), json!(v));
    }
    if !when.is_empty() {
        rule.insert("when".into(), Value::Object(when));
    }
    let limit_flags = ["limit-amount", "limit-calls", "limit-over"];
    match text("limit-window") {
        Some(window) => {
            let window = one_of(window, &["day", "month"], "--limit-window")?;
            let mut limit = Map::new();
            limit.insert("window".into(), json!(window));
            if let Some(v) = text("limit-amount") {
                limit.insert("amount".into(), json!(number::<u64>(v, "--limit-amount")?));
            }
            if let Some(v) = text("limit-calls") {
                limit.insert("calls".into(), json!(number::<u64>(v, "--limit-calls")?));
            }
            if !limit.contains_key("amount") && !limit.contains_key("calls") {
                return Err("--limit-window needs --limit-amount or --limit-calls".into());
            }
            let over =
                one_of(text("limit-over").unwrap_or("ask"), &["ask", "block"], "--limit-over")?;
            limit.insert("over".into(), json!(over));
            rule.insert("limit".into(), Value::Object(limit));
        }
        None if limit_flags.iter().any(|f| values.contains_key(*f)) => {
            return Err("--limit-amount, --limit-calls and --limit-over need --limit-window".into());
        }
        None => {}
    }
    if let Some(v) = text("expires-at") {
        rule.insert("expiresAt".into(), json!(number::<u64>(v, "--expires-at")?));
    }
    Ok(Value::Object(rule))
}

/// The request a verb makes (the overview makes several: [`overview_requests`]). `Link`'s body is made at send time
/// ([`link_body`]) so the key never sits in a printable value.
pub(super) fn request_of(verb: &Verb) -> HubRequest {
    let get =
        |path: &str| HubRequest { method: "GET", path: path.to_owned(), query: vec![], body: None };
    let post = |path: String, body: Value| HubRequest {
        method: "POST",
        path,
        query: vec![],
        body: Some(body),
    };
    match verb {
        Verb::Overview { .. } | Verb::Connections => get("/connections"),
        Verb::Link { .. } => {
            HubRequest { method: "POST", path: "/connections".into(), query: vec![], body: None }
        }
        Verb::Remove { id } => post(format!("/connections/{id}/remove"), json!({})),
        Verb::Actions => get("/actions"),
        Verb::Call { action, args, connection, invocation_id } => {
            let mut body = Map::new();
            body.insert("action".into(), json!(action));
            if let Some(a) = args {
                body.insert("args".into(), a.clone());
            }
            if let Some(c) = connection {
                body.insert("connection".into(), json!(c));
            }
            if let Some(i) = invocation_id {
                body.insert("invocationId".into(), json!(i));
            }
            post("/calls".into(), Value::Object(body))
        }
        Verb::Status { id } => get(&format!("/calls/{id}")),
        Verb::Approvals => get("/approvals"),
        Verb::Policy => get("/policy"),
        Verb::RuleAdd { rule } => post("/policy/rules".into(), rule.clone()),
        Verb::RuleRemove { id } => post(format!("/policy/rules/{id}/remove"), json!({})),
        Verb::Pause { paused } => post("/policy/pause".into(), json!({"paused": paused})),
        Verb::Audit { limit, before } => {
            let mut query = vec![];
            if let Some(b) = before {
                query.push(("before", b.to_string()));
            }
            if let Some(l) = limit {
                query.push(("limit", l.to_string()));
            }
            HubRequest { method: "GET", path: "/audit".into(), query, body: None }
        }
    }
}

/// The overview's reads: connections, approvals, policy and the newest audit rows.
pub(super) fn overview_requests(audit_limit: u32) -> [HubRequest; 4] {
    [
        request_of(&Verb::Connections),
        request_of(&Verb::Approvals),
        request_of(&Verb::Policy),
        request_of(&Verb::Audit { limit: Some(audit_limit), before: None }),
    ]
}

/// The link body: a Stripe key goes here and nowhere else; GitHub has none.
pub(super) fn link_body(
    provider: &str,
    key: Option<&str>,
    sharing: Option<&str>,
    policy: Option<&str>,
) -> Zeroizing<String> {
    let mut body = Map::new();
    body.insert("provider".into(), json!(provider));
    if let Some(key) = key {
        body.insert("key".into(), json!(key));
    }
    if let Some(s) = sharing {
        body.insert("sharing".into(), json!(s));
    }
    if let Some(p) = policy {
        body.insert("policy".into(), json!(p));
    }
    let text = Zeroizing::new(Value::Object(body).to_string());
    // The map's copy of the key is dropped here; the string is the only one left, wiped on drop.
    text
}

/// A pasted key, trimmed, if it is a Stripe restricted key. A secret key (`sk_`) is refused here, before any request:
/// it would give agents the whole account.
pub(super) fn restricted_key(raw: &str) -> Result<Zeroizing<String>, Value> {
    let key = raw.trim();
    if key.is_empty() {
        return Err(error_json(
            "cli.invalid_args",
            "no key: paste a Stripe restricted key (rk_...)",
        ));
    }
    if key.starts_with("sk_") {
        return Err(error_json(
            "stripe.key_refused",
            "that is a secret key; make a restricted key (rk_...) with Charges: read and Refunds: write",
        ));
    }
    let ok = (key.starts_with("rk_test_") || key.starts_with("rk_live_"))
        && key.len() <= 256
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
    if !ok {
        return Err(error_json(
            "stripe.key_refused",
            "not a Stripe restricted key; paste a key that starts with rk_test_ or rk_live_",
        ));
    }
    Ok(Zeroizing::new(key.to_owned()))
}

/// The platform a verb asks: the one named, else the platform of the deployment that issued the token, else
/// production. An API origin from an unknown deployment (a local stack) is refused rather than guessed.
pub(super) fn platform_for(named: Option<&str>, issued_by: Option<&str>) -> Result<String, String> {
    use cmux_cloud_environment as env;
    if let Some(p) = named {
        return Ok(p.trim_end_matches('/').to_owned());
    }
    let Some(api) = issued_by else {
        return Ok(env::PRODUCTION_PLATFORM.trim_end_matches('/').to_owned());
    };
    let api = api.trim_end_matches('/');
    [env::PRODUCTION_DEPLOYMENT, env::STAGING_DEPLOYMENT, env::DEVELOPMENT_DEPLOYMENT]
        .iter()
        .find(|d| d.api_origin.trim_end_matches('/') == api)
        .map(|d| d.platform_origin.trim_end_matches('/').to_owned())
        .ok_or_else(|| {
            "the app's sign-in names an API with no known platform; pass --platform (or CMUX_PLATFORM_URL)".into()
        })
}

/// The full URL of a request.
pub(super) fn url_of(platform: &str, request: &HubRequest, team: Option<&str>) -> String {
    let mut url = format!("{platform}/v1/hub{}", request.path);
    let mut query: Vec<(&str, String)> = request.query.clone();
    if let Some(t) = team {
        query.push(("team", t.to_owned()));
    }
    for (i, (k, v)) in query.iter().enumerate() {
        url.push(if i == 0 { '?' } else { '&' });
        url.push_str(k);
        url.push('=');
        url.push_str(&percent(v));
    }
    url
}

fn percent(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn clean(text: &str, max: usize) -> String {
    text.chars().filter(|c| !c.is_control()).take(max).collect()
}

/// One field of an answer, or null: reading never panics on a shape the hub did not send.
fn pick(v: &Value, key: &str) -> Value {
    v.get(key).cloned().unwrap_or(Value::Null)
}

/// Sets one view field on an object; anything that is not an object stays as it is.
fn put(v: &mut Value, key: &str, value: Value) {
    if let Some(map) = v.as_object_mut() {
        map.insert(key.to_owned(), value);
    }
}

/// The hub's error, kept with its own code and a short, printable message.
pub(super) fn hub_error(status: u16, body: &Value) -> Value {
    let field = |p: &str| body.pointer(p).and_then(Value::as_str).map(|s| clean(s, 300));
    let code = field("/error/code").unwrap_or_else(|| "api.bad_answer".into());
    let message =
        field("/error/message").unwrap_or_else(|| format!("the hub answered HTTP {status}"));
    let mut error = error_json(&code, &message);
    put(&mut error, "status", json!(status));
    if code == "hub.not_found" && status == 404 {
        put(&mut error, "available", json!(false));
        if let Some(inner) = error.get_mut("error") {
            put(
                inner,
                "message",
                json!("the integrations hub is not available on this deployment yet"),
            );
        }
    }
    if let Some(call) = body.get("call").filter(|c| c.is_object()) {
        put(&mut error, "call", call_view(call));
    }
    error
}

/// A verb's answer from the hub's status and body: the body's fields with view fields added, or the error.
pub(super) fn answer(verb: &Verb, status: u16, body: &Value) -> Value {
    if !(200..300).contains(&status) || !body.is_object() {
        return hub_error(status, body);
    }
    let mut out = Map::new();
    out.insert("ok".into(), json!(true));
    let list = |key: &str, shape: fn(&Value) -> Value| -> Value {
        Value::Array(
            body.get(key)
                .and_then(Value::as_array)
                .map(|a| a.iter().map(shape).collect())
                .unwrap_or_default(),
        )
    };
    match verb {
        Verb::Overview { .. } | Verb::Connections => {
            out.insert("connections".into(), list("connections", connection_view));
        }
        Verb::Link { .. } => {
            out.insert(
                "connection".into(),
                body.get("connection").map(connection_view).unwrap_or(Value::Null),
            );
        }
        Verb::Remove { .. } | Verb::RuleRemove { .. } => {
            out.insert("removed".into(), body.get("removed").cloned().unwrap_or(json!(true)));
            out.insert("id".into(), body.get("id").cloned().unwrap_or(Value::Null));
        }
        Verb::Actions => {
            out.insert("actions".into(), list("actions", action_view));
        }
        Verb::Call { .. } | Verb::Status { .. } => {
            out.insert("call".into(), body.get("call").map(call_view).unwrap_or(Value::Null));
        }
        Verb::Approvals => {
            out.insert("approvals".into(), list("approvals", call_view));
        }
        Verb::Policy => {
            out.insert(
                "paused".into(),
                json!(body.get("paused").and_then(Value::as_bool).unwrap_or(false)),
            );
            out.insert("rules".into(), list("rules", rule_view));
        }
        Verb::RuleAdd { .. } => {
            out.insert("rule".into(), body.get("rule").map(rule_view).unwrap_or(Value::Null));
        }
        Verb::Pause { .. } => {
            out.insert(
                "paused".into(),
                json!(body.get("paused").and_then(Value::as_bool).unwrap_or(false)),
            );
        }
        Verb::Audit { .. } => {
            out.insert("audit".into(), list("audit", audit_view));
            if let Some(next) = body.get("next").filter(|n| !n.is_null()) {
                out.insert("next".into(), next.clone());
            }
        }
    }
    Value::Object(out)
}

/// The overview with where its approvals are answered: `platform` (the origin it read) and `team` (the one it named,
/// else null for the token's own). The Settings card answers an approval there itself, on the person's click: this CLI
/// has no verb that answers one, since a lane running it holds the person's token and could approve its own agent.
pub(super) fn with_answer_target(mut overview: Value, platform: &str, team: Option<&str>) -> Value {
    if overview.get("available") == Some(&json!(true))
        && let Some(map) = overview.as_object_mut()
    {
        map.insert("platform".into(), json!(platform));
        map.insert("team".into(), team.map_or(Value::Null, |t| json!(t)));
    }
    overview
}

/// The overview from its four answers (in [`overview_requests`] order): one view model for the Settings card. A hub
/// that is not on this deployment is `ok: true, available: false`, so the card shows a calm "not available here yet".
pub(super) fn overview(parts: [(u16, Value); 4]) -> Value {
    let [connections, approvals, policy, audit] = parts;
    let answers = [
        answer(&Verb::Connections, connections.0, &connections.1),
        answer(&Verb::Approvals, approvals.0, &approvals.1),
        answer(&Verb::Policy, policy.0, &policy.1),
        answer(&Verb::Audit { limit: None, before: None }, audit.0, &audit.1),
    ];
    if answers.iter().any(|a| a.get("available") == Some(&json!(false))) {
        return json!({
            "ok": true,
            "available": false,
            "message": "The integrations hub is not available on this deployment yet.",
            "connections": [], "approvals": [], "approvalCards": [], "rules": [], "audit": [], "paused": false,
            "hasStripe": false,
            "hasGithub": false,
        });
    }
    if let Some(failed) = answers.iter().find(|a| a.get("ok") != Some(&json!(true))) {
        return failed.clone();
    }
    let [c, a, p, l] = answers;
    let connections = pick(&c, "connections");
    let has = |provider: &str| {
        connections
            .as_array()
            .is_some_and(|list| list.iter().any(|c| str_of(c, "provider") == Some(provider)))
    };
    let (has_stripe, has_github) = (has("stripe"), has("github"));
    let (approvals, rules) = (pick(&a, "approvals"), pick(&p, "rules"));
    let paused = p.get("paused").and_then(Value::as_bool).unwrap_or(false);
    json!({
        "ok": true,
        "available": true,
        "paused": paused,
        "pausedText": if paused { "Paused: every call is refused until you resume." } else { "On: calls follow your rules." },
        "connections": connections,
        "hasStripe": has_stripe,
        "hasGithub": has_github,
        "approvals": approvals,
        "approvalCards": approval_cards(&approvals, &rules, &connections),
        "rules": rules,
        "audit": pick(&l, "audit"),
        "next": l.get("next").cloned().unwrap_or(Value::Null),
    })
}

// --- View shaping -------------------------------------------------------------------------------------------------

/// The minor-unit exponent of an ISO 4217 currency, as Stripe counts it.
pub(super) fn currency_exponent(currency: &str) -> u32 {
    const ZERO: [&str; 16] = [
        "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv",
        "xaf", "xof", "xpf",
    ];
    const THREE: [&str; 5] = ["bhd", "jod", "kwd", "omr", "tnd"];
    let c = currency.to_ascii_lowercase();
    if ZERO.contains(&c.as_str()) {
        0
    } else if THREE.contains(&c.as_str()) {
        3
    } else {
        2
    }
}

/// An amount in minor units, for people: `1234567` usd is `12,345.67 USD`, `500` jpy is `500 JPY`.
pub(super) fn format_money(minor: i64, currency: &str) -> String {
    let exponent = currency_exponent(currency);
    let sign = if minor < 0 { "-" } else { "" };
    let abs = minor.unsigned_abs();
    let scale = 10u64.checked_pow(exponent).unwrap_or(1);
    let whole = abs.checked_div(scale).unwrap_or(abs);
    let digits = whole.to_string();
    let mut grouped = String::new();
    for (i, ch) in digits.chars().enumerate() {
        let left = digits.len().saturating_sub(i);
        if i > 0 && left.is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(ch);
    }
    let code = currency.to_ascii_uppercase();
    if exponent == 0 {
        format!("{sign}{grouped} {code}")
    } else {
        let frac = abs.checked_rem(scale).unwrap_or(0);
        format!(
            "{sign}{grouped}.{frac:0width$} {code}",
            width = usize::try_from(exponent).unwrap_or(2)
        )
    }
}

fn provider_label(provider: &str) -> String {
    match provider {
        "stripe" => "Stripe".into(),
        "github" => "GitHub".into(),
        other => clean(other, 40),
    }
}

/// An action name for people: `stripe.refund.create` is "Stripe refunds", `stripe.*` "any Stripe action".
pub(super) fn action_label(name: &str) -> String {
    match name {
        "*" => "any action".into(),
        "stripe.refund.create" => "Stripe refunds".into(),
        "stripe.charges.list" => "listing Stripe charges".into(),
        "stripe.charge.get" => "reading a Stripe charge".into(),
        "github.pulls.list" => "listing GitHub pull requests".into(),
        "github.issues.list" => "listing GitHub issues".into(),
        other => match other.strip_suffix(".*") {
            Some(prefix) if !prefix.contains('.') => {
                format!("any {} action", provider_label(prefix))
            }
            Some(prefix) => format!("any {prefix} action"),
            None => clean(other, 128),
        },
    }
}

fn str_of<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// An ISO time as the card shows it: `2026-11-23 14:05 UTC` (the hub's times are UTC).
pub(super) fn short_time(iso: &str) -> String {
    match (iso.get(0..10), iso.get(11..16)) {
        (Some(date), Some(time)) if iso.as_bytes().get(10) == Some(&b'T') => {
            format!("{date} {time} UTC")
        }
        _ => clean(iso, 40),
    }
}

/// A linked account with its view fields.
pub(super) fn connection_view(c: &Value) -> Value {
    let mut out = c.clone();
    let provider = str_of(c, "provider").unwrap_or("");
    let mode = str_of(c, "mode");
    let sharing = str_of(c, "sharing").unwrap_or("private");
    let status = str_of(c, "status").unwrap_or("active");
    put(&mut out, "providerLabel", json!(provider_label(provider)));
    put(
        &mut out,
        "title",
        json!(format!(
            "{} · {}",
            provider_label(provider),
            clean(str_of(c, "account").unwrap_or("account"), 120)
        )),
    );
    put(
        &mut out,
        "modeLabel",
        match mode {
            Some("test") => json!("Test mode"),
            Some("live") => json!("Live mode"),
            _ => Value::Null,
        },
    );
    put(
        &mut out,
        "sharingLabel",
        json!(if sharing == "team" { "Shared with the team" } else { "Private to you" }),
    );
    put(
        &mut out,
        "statusLabel",
        json!(match (status, provider) {
            ("active", _) => "Connected",
            ("needs_reauth", "stripe") => "Needs a new key",
            ("needs_reauth", _) => "Needs to be linked again",
            (other, _) => other,
        }),
    );
    put(&mut out, "healthy", json!(status == "active"));
    // A connection the provider stopped honouring (RFD 0055 "Revoke": `needs_reauth`) offers Reconnect: a key
    // provider takes a new pasted key, an OAuth provider goes through its link again. Null while it works.
    put(
        &mut out,
        "reconnect",
        match (status, provider) {
            ("needs_reauth", "stripe") => json!("key"),
            ("needs_reauth", _) => json!("link"),
            _ => Value::Null,
        },
    );
    put(&mut out, "canRemove", json!(c.get("canRemove").and_then(Value::as_bool).unwrap_or(false)));
    out
}

fn action_view(a: &Value) -> Value {
    let mut out = a.clone();
    let risk = str_of(a, "risk").unwrap_or("");
    put(
        &mut out,
        "riskLabel",
        json!(match risk {
            "read" => "Reads",
            "mutate-own" => "Changes your data",
            "mutate-shared" => "Changes shared data",
            "execute" => "Runs code",
            "send-external" => "Sends outside",
            "money" => "Moves money",
            "destructive" => "Deletes",
            other => other,
        }),
    );
    out
}

/// The status of a call, for people.
pub(super) fn call_status_label(status: &str) -> &'static str {
    match status {
        "approval_required" => "Waiting for you",
        "running" => "Running",
        "succeeded" => "Done",
        "failed" => "Failed",
        "denied" => "Denied",
        "expired" => "Expired",
        "blocked" => "Blocked by a rule",
        "outcome_unknown" => "Outcome unknown",
        _ => "Unknown",
    }
}

fn requester(r: Option<&Value>) -> String {
    let Some(r) = r else { return "someone".into() };
    match (str_of(r, "kind"), str_of(r, "agent"), str_of(r, "user")) {
        (Some("agent"), Some(agent), _) => format!("agent {}", clean(agent, 60)),
        (Some("agent"), None, _) => "an agent".into(),
        (_, _, Some(user)) => clean(user, 60),
        _ => "someone".into(),
    }
}

/// A call with its view fields: `line` is the pinned summary the hub wrote (what the person approves), never
/// re-worded here; `amountText`, `statusLabel`, `requestedByText` and `approvalId` sit beside it.
pub(super) fn call_view(c: &Value) -> Value {
    let mut out = c.clone();
    let status = str_of(c, "status").unwrap_or("");
    put(&mut out, "line", json!(clean(str_of(c, "summary").unwrap_or("(no summary)"), 500)));
    put(&mut out, "statusLabel", json!(call_status_label(status)));
    put(
        &mut out,
        "amountText",
        match (c.get("amount").and_then(Value::as_i64), str_of(c, "currency")) {
            (Some(minor), Some(cur)) => json!(format_money(minor, cur)),
            _ => Value::Null,
        },
    );
    put(&mut out, "actionLabel", json!(action_label(str_of(c, "action").unwrap_or(""))));
    put(&mut out, "requestedByText", json!(requester(c.get("requestedBy"))));
    put(&mut out, "approvalId", c.pointer("/approval/id").cloned().unwrap_or(Value::Null));
    put(
        &mut out,
        "expiresText",
        c.pointer("/approval/expiresAt")
            .and_then(Value::as_str)
            .map(|e| json!(format!("Expires {}", short_time(e))))
            .unwrap_or(Value::Null),
    );
    put(
        &mut out,
        "policyText",
        c.pointer("/policy/reason")
            .and_then(Value::as_str)
            .map(|r| json!(clean(r, 300)))
            .unwrap_or(Value::Null),
    );
    if let Some(e) = c.get("error").filter(|e| e.is_object()) {
        put(&mut out, "errorText", json!(clean(str_of(e, "message").unwrap_or("failed"), 300)));
    }
    let (outcome, tone) = call_outcome(c);
    put(&mut out, "outcomeText", outcome.map_or(Value::Null, |o| json!(o)));
    put(&mut out, "outcomeTone", tone.map_or(Value::Null, |t| json!(t)));
    out
}

/// What became of a call once a person answered it, in one sentence for the Chief card that answered it, with its
/// tone (`done`, `denied`, `failed`): "Approved. It ran (re_123)." Null while it still waits or runs.
pub(super) fn call_outcome(c: &Value) -> (Option<String>, Option<&'static str>) {
    let error = c.pointer("/error/message").and_then(Value::as_str).map(|m| clean(m, 300));
    match str_of(c, "status").unwrap_or("") {
        "succeeded" => {
            let text = match str_of(c, "providerRef") {
                Some(r) => format!("Approved. It ran ({}).", clean(r, 80)),
                None => "Approved. It ran.".into(),
            };
            (Some(text), Some("done"))
        }
        "denied" => (Some("Denied. Nothing ran.".into()), Some("denied")),
        "failed" => (
            Some(match error {
                Some(e) => format!("Approved, but it failed: {e}"),
                None => "Approved, but it failed.".into(),
            }),
            Some("failed"),
        ),
        "outcome_unknown" => (
            Some("Approved, but the hub could not tell whether it ran. Check the provider before trying again.".into()),
            Some("failed"),
        ),
        "expired" => (Some("This approval expired before the answer. Nothing ran.".into()), Some("denied")),
        "blocked" => (Some("A rule blocked it. Nothing ran.".into()), Some("denied")),
        _ => (None, None),
    }
}

/// What the integration did: the action's verb for one call ("Refund"), where [`action_label`] names the kind.
pub(super) fn action_title(name: &str) -> String {
    match name {
        "stripe.refund.create" => "Refund".into(),
        "stripe.charges.list" => "List charges".into(),
        "stripe.charge.get" => "Read a charge".into(),
        "github.pulls.list" => "List pull requests".into(),
        "github.issues.list" => "List issues".into(),
        other => clean(other.rsplit_once('.').map_or(other, |(_, verb)| verb), 60),
    }
}

/// One Chief card per approval that waits for a person: which agent asked, which integration and action (with its
/// amount and the pinned line naming its target), and which rule sent it to the person. A rule is named by its
/// sentence when the overview listed it; a limit's reason ("over the limit of ...") follows it. With no rule the
/// hub's default decided, and its reason says so.
pub(super) fn approval_cards(approvals: &Value, rules: &Value, connections: &Value) -> Value {
    let by_id = |list: &Value, id: Option<&str>| -> Option<Value> {
        let id = id?;
        list.as_array()?.iter().find(|r| str_of(r, "id") == Some(id)).cloned()
    };
    let cards = approvals
        .as_array()
        .map(|list| {
            list.iter()
                .filter(|c| str_of(c, "status") == Some("approval_required"))
                .filter(|c| c.pointer("/approval/id").and_then(Value::as_str).is_some())
                .map(|c| {
                    let action = str_of(c, "action").unwrap_or("");
                    let provider = action.split('.').next().unwrap_or("");
                    let connection = by_id(connections, str_of(c, "connection"));
                    let integration = connection
                        .as_ref()
                        .and_then(|conn| str_of(conn, "title").map(str::to_owned))
                        .unwrap_or_else(|| provider_label(provider));
                    let reason = c.pointer("/policy/reason").and_then(Value::as_str);
                    let rule = by_id(rules, c.pointer("/policy/rule").and_then(Value::as_str));
                    let rule_line = match (&rule, reason) {
                        (Some(r), Some(why)) if why.starts_with("over the limit") => {
                            format!("{}: {}; {}", rule_owner(r), rule_text(r), clean(why, 200))
                        }
                        (Some(r), _) => format!("{}: {}", rule_owner(r), rule_text(r)),
                        (None, Some(why)) => format!("Rule: {}", clean(why, 300)),
                        (None, None) => "Rule: the hub's default for this action".into(),
                    };
                    json!({
                        "approvalId": c.pointer("/approval/id").cloned().unwrap_or(Value::Null),
                        "callId": c.get("id").cloned().unwrap_or(Value::Null),
                        "agentText": requester(c.get("requestedBy")),
                        "integrationText": integration,
                        "actionText": action_title(action),
                        "amountText": c.get("amountText").cloned().unwrap_or(Value::Null),
                        "line": c.get("line").cloned().unwrap_or(Value::Null),
                        "ruleText": rule_line,
                        "expiresText": c.get("expiresText").cloned().unwrap_or(Value::Null),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Value::Array(cards)
}

fn rule_owner(rule: &Value) -> &'static str {
    if str_of(rule, "owner") == Some("team") { "Team rule" } else { "Your rule" }
}

/// A rule in one sentence: "Ask before Stripe refunds over 50.00 USD, for agent ci (team rule)".
pub(super) fn rule_text(rule: &Value) -> String {
    let action = action_label(str_of(rule, "action").unwrap_or("*"));
    let mut text = match str_of(rule, "effect").unwrap_or("ask") {
        "allow" => format!("Allow {action}"),
        "block" => format!("Block {action}"),
        _ => format!("Ask before {action}"),
    };
    let currency = rule.pointer("/when/currency").and_then(Value::as_str);
    let money = |minor: i64| match currency {
        Some(c) => format_money(minor, c),
        None => format!("{minor} (minor units)"),
    };
    if let Some(gt) = rule.pointer("/when/amountGt").and_then(Value::as_i64) {
        text.push_str(&format!(" over {}", money(gt)));
    }
    if let Some(lte) = rule.pointer("/when/amountLte").and_then(Value::as_i64) {
        let joiner = if rule.pointer("/when/amountGt").is_some() { " and" } else { "" };
        text.push_str(&format!("{joiner} up to {}", money(lte)));
    }
    if currency.is_some()
        && rule.pointer("/when/amountGt").is_none()
        && rule.pointer("/when/amountLte").is_none()
    {
        text.push_str(&format!(" in {}", currency.unwrap_or_default().to_ascii_uppercase()));
    }
    if let Some(repo) = rule.pointer("/when/repo").and_then(Value::as_str) {
        text.push_str(&format!(" in {}", clean(repo, 120)));
    }
    if let Some(agent) = str_of(rule, "agent") {
        text.push_str(&format!(", for agent {}", clean(agent, 60)));
    }
    if let Some(c) = str_of(rule, "connection") {
        text.push_str(&format!(", on {}", clean(c, 40)));
    }
    if let Some(limit) = rule.get("limit").filter(|l| l.is_object()) {
        let window = if str_of(limit, "window") == Some("month") { "a month" } else { "a day" };
        let mut caps = vec![];
        if let Some(a) = limit.get("amount").and_then(Value::as_i64) {
            caps.push(money(a));
        }
        if let Some(n) = limit.get("calls").and_then(Value::as_i64) {
            caps.push(if n == 1 { "1 call".into() } else { format!("{n} calls") });
        }
        let over = if str_of(limit, "over") == Some("block") { "block" } else { "ask" };
        text.push_str(&format!("; at most {} {window}, then {over}", caps.join(" and ")));
    }
    if let Some(e) = str_of(rule, "expiresAt") {
        text.push_str(&format!("; until {}", short_time(e)));
    }
    text
}

/// A rule with its view fields.
pub(super) fn rule_view(r: &Value) -> Value {
    let mut out = r.clone();
    put(&mut out, "text", json!(rule_text(r)));
    put(&mut out, "ownerLabel", json!(rule_owner(r)));
    put(&mut out, "canRemove", json!(r.get("canRemove").and_then(Value::as_bool).unwrap_or(false)));
    put(
        &mut out,
        "remembered",
        json!(r.get("remembered").and_then(Value::as_bool).unwrap_or(false)),
    );
    out
}

/// An audit event for people.
pub(super) fn event_label(event: &str) -> String {
    match event {
        "connection.added" => "Linked".into(),
        "connection.removed" => "Removed".into(),
        "connection.needs_reauth" => "Needs a new key".into(),
        "rule.added" => "Rule added".into(),
        "rule.removed" => "Rule removed".into(),
        "hub.paused" => "Paused".into(),
        "hub.resumed" => "Resumed".into(),
        "call.allowed" => "Allowed by a rule".into(),
        "call.asked" => "Asked for approval".into(),
        "call.blocked" => "Blocked".into(),
        "approval.allowed" => "Approved".into(),
        "approval.denied" => "Denied".into(),
        "approval.expired" => "Approval expired".into(),
        "call.succeeded" => "Succeeded".into(),
        "call.failed" => "Failed".into(),
        "call.outcome_unknown" => "Outcome unknown".into(),
        other => clean(other, 60),
    }
}

/// An audit row with its view fields: `line` "Approved · Refund 12.00 USD on ch_123 · by leo".
pub(super) fn audit_view(row: &Value) -> Value {
    let mut out = row.clone();
    let event = str_of(row, "event").unwrap_or("");
    let label = event_label(event);
    let summary = clean(str_of(row, "summary").unwrap_or(""), 300);
    let who = requester(row.get("actor"));
    let line = if summary.is_empty() {
        format!("{label} · by {who}")
    } else {
        format!("{label} · {summary} · by {who}")
    };
    put(&mut out, "eventLabel", json!(label));
    put(&mut out, "line", json!(line));
    put(&mut out, "whenText", json!(short_time(str_of(row, "at").unwrap_or(""))));
    put(
        &mut out,
        "tone",
        json!(match event {
            "call.failed"
            | "call.blocked"
            | "approval.denied"
            | "connection.needs_reauth"
            | "call.outcome_unknown" => "warn",
            "call.succeeded" | "approval.allowed" | "connection.added" => "good",
            _ => "plain",
        }),
    );
    out
}

// --- Running ------------------------------------------------------------------------------------------------------

struct Hub {
    http: reqwest::Client,
    platform: String,
    token: Zeroizing<String>,
    team: Option<String>,
}

impl Hub {
    async fn send(&self, request: &HubRequest, body: Option<&str>) -> Result<(u16, Value), Value> {
        let url = url_of(&self.platform, request, self.team.as_deref());
        let mut builder = match request.method {
            "POST" => self.http.post(url),
            _ => self.http.get(url),
        }
        .bearer_auth(self.token.as_str())
        .header("accept", "application/json");
        let owned;
        let body = match (body, &request.body) {
            (Some(b), _) => Some(b),
            (None, Some(v)) => {
                owned = v.to_string();
                Some(owned.as_str())
            }
            (None, None) => None,
        };
        if let Some(b) = body {
            builder = builder.header("content-type", "application/json").body(b.to_owned());
        }
        let response = builder
            .send()
            .await
            .map_err(|_| error_json("api.unreachable", "the cmux platform did not answer"))?;
        let status = response.status().as_u16();
        let bytes = response
            .bytes()
            .await
            .map_err(|_| error_json("api.unreachable", "the cmux platform's answer was cut off"))?;
        match serde_json::from_slice::<Value>(&bytes) {
            Ok(v) => Ok((status, v)),
            Err(_) if status == 404 => Ok((status, json!({"error": {"code": "hub.not_found"}}))),
            Err(_) => Err(error_json(
                "api.bad_answer",
                &format!("the hub answered HTTP {status}, not JSON"),
            )),
        }
    }
}

/// Reads the key: all of stdin when it is not a terminal (the app pipes it), else a hidden prompt.
fn read_key() -> Result<Zeroizing<String>, Value> {
    let stdin = std::io::stdin();
    let mut raw = Zeroizing::new(String::new());
    let read = if stdin.is_terminal() {
        read_hidden_line(
            "Stripe restricted key (rk_..., Charges: read, Refunds: write): ",
            &mut raw,
        )
    } else {
        stdin.lock().take(4096).read_to_string(&mut raw).map(|_| ())
    };
    read.map_err(|_| error_json("cli.invalid_args", "could not read the key from stdin"))?;
    restricted_key(&raw)
}

fn read_hidden_line(prompt: &str, into: &mut String) -> std::io::Result<()> {
    let mut stderr = std::io::stderr().lock();
    stderr.write_all(prompt.as_bytes())?;
    stderr.flush()?;
    // SAFETY: termios is plain data; tcgetattr fills it for fd 0.
    let mut original: libc::termios = unsafe { std::mem::zeroed() };
    let has_terminal = unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } == 0;
    if has_terminal {
        let mut hidden = original;
        hidden.c_lflag &= !libc::ECHO;
        // SAFETY: a termios copy of the current settings with ECHO cleared.
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &hidden) };
    }
    let read = std::io::stdin().lock().read_line(into);
    if has_terminal {
        // SAFETY: restores the settings read above.
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &original) };
    }
    let _ = stderr.write_all(b"\n");
    read.map(|_| ())
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
    let http = match cmux_egress::client_builder("cmux_tui::cli::hub")
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(45))
        .build()
    {
        Ok(h) => h,
        Err(e) => return error_json("cli.http_client", &e.to_string()),
    };
    let hub = Hub { http, platform, token, team: common.team.clone() };
    match verb {
        Verb::Overview { audit_limit } => {
            let [a, b, c, d] = overview_requests(*audit_limit);
            let (a, b, c, d) = tokio::join!(
                hub.send(&a, None),
                hub.send(&b, None),
                hub.send(&c, None),
                hub.send(&d, None)
            );
            match (a, b, c, d) {
                (Ok(a), Ok(b), Ok(c), Ok(d)) => {
                    with_answer_target(overview([a, b, c, d]), &hub.platform, hub.team.as_deref())
                }
                (Err(e), ..) | (_, Err(e), ..) | (_, _, Err(e), _) | (.., Err(e)) => e,
            }
        }
        Verb::Link { provider, sharing, policy } => {
            if provider == "stripe" && key.is_none() {
                return error_json("cli.invalid_args", "no key");
            }
            let body = link_body(
                provider,
                key.as_deref().map(|k| k.as_str()),
                sharing.as_deref(),
                policy.as_deref(),
            );
            match hub.send(&request_of(verb), Some(&body)).await {
                Ok((status, value)) => answer(verb, status, &value),
                Err(e) => e,
            }
        }
        _ => match hub.send(&request_of(verb), None).await {
            Ok((status, value)) => answer(verb, status, &value),
            Err(e) => e,
        },
    }
}

/// Prints the answer: JSON as is, or short lines for people.
pub(super) fn print(answer: &Value, json_out: bool) {
    if json_out {
        println!("{answer}");
        return;
    }
    if answer.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = answer.pointer("/error/code").and_then(Value::as_str).unwrap_or("error");
        let message = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or_default();
        eprintln!("cmux hub: {code}: {message}");
        return;
    }
    for line in human_lines(answer) {
        println!("{line}");
    }
}

/// The lines a person reads for an answer.
pub(super) fn human_lines(answer: &Value) -> Vec<String> {
    let mut lines = vec![];
    if answer.get("available") == Some(&json!(false)) {
        lines.push(str_of(answer, "message").unwrap_or("not available").to_owned());
        return lines;
    }
    if let Some(p) = answer.get("paused").and_then(Value::as_bool) {
        lines.push(if p { "hub: paused".into() } else { "hub: on".into() });
    }
    let each = |key: &str| answer.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
    for c in each("connections") {
        let mode = str_of(&c, "modeLabel").map(|m| format!(", {m}")).unwrap_or_default();
        lines.push(format!(
            "{}  {}{mode}, {}, {}",
            str_of(&c, "id").unwrap_or(""),
            str_of(&c, "title").unwrap_or(""),
            str_of(&c, "sharingLabel").unwrap_or(""),
            str_of(&c, "statusLabel").unwrap_or("")
        ));
    }
    if let Some(c) = answer.get("connection").filter(|c| c.is_object()) {
        lines.push(format!(
            "linked {}  {}",
            str_of(c, "id").unwrap_or(""),
            str_of(c, "title").unwrap_or("")
        ));
    }
    for a in each("actions") {
        lines.push(format!(
            "{}  {} ({}{})",
            str_of(&a, "name").unwrap_or(""),
            str_of(&a, "title").unwrap_or(""),
            str_of(&a, "riskLabel").unwrap_or(""),
            if a.get("linked") == Some(&json!(true)) { "" } else { ", not linked" }
        ));
    }
    let call_line = |c: &Value| {
        format!(
            "{}  {}: {}",
            str_of(c, "id").unwrap_or(""),
            str_of(c, "statusLabel").unwrap_or(""),
            str_of(c, "line").unwrap_or("")
        )
    };
    for c in each("approvals") {
        lines.push(format!("{}  {}", str_of(&c, "approvalId").unwrap_or(""), call_line(&c)));
    }
    if let Some(c) = answer.get("call").filter(|c| c.is_object()) {
        lines.push(call_line(c));
        if let Some(e) = str_of(c, "errorText") {
            lines.push(format!("  {e}"));
        }
    }
    for r in each("rules") {
        lines.push(format!(
            "{}  {}",
            str_of(&r, "id").unwrap_or(""),
            str_of(&r, "text").unwrap_or("")
        ));
    }
    if let Some(r) = answer.get("rule").filter(|r| r.is_object()) {
        lines.push(format!(
            "rule {}  {}",
            str_of(r, "id").unwrap_or(""),
            str_of(r, "text").unwrap_or("")
        ));
    }
    for row in each("audit") {
        lines.push(format!(
            "{}  {}",
            str_of(&row, "whenText").unwrap_or(""),
            str_of(&row, "line").unwrap_or("")
        ));
    }
    if let Some(id) = str_of(answer, "id")
        && answer.get("removed").is_some()
    {
        lines.push(format!("removed {id}"));
    }
    lines
}

/// `Some(exit code)` for `cmux hub …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_action_globals(args).ok()?;
    let rest = match command_args.as_slice() {
        [h, rest @ ..] if h == "hub" => rest,
        _ => return None,
    };
    if rest.is_empty()
        || rest.iter().any(|a| a == "--help" || a == "-h")
        || rest.first().is_some_and(|a| a == "help")
    {
        print!("{HELP}");
        return Some(0);
    }
    let json_out = global.output == super::OutputMode::Json;
    Some(run_words(rest, json_out))
}

/// Parses and runs a verb; prints its answer. Exit 0 ok, 1 refused or failed, 2 bad arguments.
pub(super) fn run_words(words: &[String], json_out: bool) -> i32 {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let (common, verb) = match parse(words, &env) {
        Ok(p) => p,
        Err(e) => {
            print(&error_json("cli.invalid_args", &e), json_out);
            return 2;
        }
    };
    let key = if matches!(&verb, Verb::Link { provider, .. } if provider == "stripe") {
        match read_key() {
            Ok(k) => Some(k),
            Err(e) => {
                print(&e, json_out);
                return 2;
            }
        }
    } else {
        None
    };
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(r) => r,
        Err(e) => {
            print(&error_json("cli.runtime", &e.to_string()), json_out);
            return 1;
        }
    };
    let answer = runtime.block_on(run(&common, &verb, key));
    print(&answer, json_out);
    if answer.get("ok").and_then(Value::as_bool) == Some(true) { 0 } else { 1 }
}

#[cfg(test)]
#[path = "hub_tests.rs"]
mod tests;
