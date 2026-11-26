//! `cmux autocloud`: Cloud automations (cmux platform `/v1/automations`), the conditions a person sets for when
//! AutoCloud goes off: a trigger (a GitHub event on a repository, a signed webhook, a schedule), conditions over the
//! event JSON, and the agent it starts (repository, ref and prompt templates, harness) under guardrails.
//!
//! Leo, 2026-11-24: "likewise, setting up automation and webhooks will be ultra big for us; having people be able to
//! set up their own conditions for when autocloud will go off, and examining and perfecting our github integrations
//! all the way through and through"
//!
//! The platform decides and runs; this CLI checks a spec, asks, and shapes the answers. Every label the Settings >
//! Automations card shows (trigger summaries, run statuses, times, the template gallery) is written here: the card
//! renders only what `overview`, `runs` and `preview` return. `preview` runs here with no network: it renders the ref
//! and prompt templates and checks the conditions against a sample event, the same rules the platform applies.
//!
//! A spec (create, update, preview) is read from stdin as JSON, never from argv. A webhook automation's secret comes
//! back once, in `create`'s answer, and is never read again.
//!
//! Every verb prints one JSON object with `--json`: `{"ok": true, ...}`, or `{"ok": false, "error": {"code",
//! "message"}}` with the platform's code (`automation.invalid`, `automation.conflict`, ...) or this CLI's
//! (`cli.invalid_args`, `api.unreachable`, `api.bad_answer`, `auth.no_token`). A deployment with no automations
//! answers `"available": false`, which the app shows as "not available here yet", not as a failure.

use std::io::Read;
use std::time::Duration;

use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::hub::{error_json, platform_for};
use super::inference_gateway::{TokenSource, backend_credential};

pub(super) const HELP: &str = "\
cmux autocloud: Cloud automations, when AutoCloud starts an agent for you.

Usage:
  cmux autocloud overview [--json]          your automations, their last runs, and the templates
  cmux autocloud runs <id> [--limit N] [--json]
  cmux autocloud create [--json]            (the spec is read from stdin as JSON)
  cmux autocloud update <id> [--json]       (the spec, with its revision, from stdin)
  cmux autocloud enable | disable <id> --revision N [--json]
  cmux autocloud remove <id> [--json]
  cmux autocloud preview [--json]           ({spec, sample | event} from stdin; no network)
  cmux autocloud templates [--json]

A spec: {name, trigger, conditions, action, guardrails}
  trigger     {type: github, events: [ci_failure], repository: owner/name} | {type: webhook}
              | {type: schedule, cron: \"0 9 * * 1-5\", timeZone: America/Los_Angeles}
  conditions  [{path: workflow_run.head_branch, op: equals|not_equals|in|not_in|contains|prefix|exists|missing|gt|gte|lt|lte, value}]
  action      {type: start_agent, repo, ref, harness: claude|codex, model?, prompt, postBack?: comment|none, openPr?}
              (ref and prompt read {{event.*}}, {{trigger.*}} and {{run.url}})
  guardrails  {cooldownSeconds, maxRunsPerDay, maxConcurrent, maxMinutesPerRun}

Every verb also takes --platform URL (else CMUX_PLATFORM_URL, else the platform of the app's sign-in),
--team TEAM, and --token-file PATH | --token-command CMD (else CMUX_CLOUD_ACCESS_TOKEN, else the app's sign-in).
";

/// The GitHub events a trigger can name, with what the card calls each.
pub(super) const GITHUB_EVENTS: &[(&str, &str)] = &[
    ("ci_failure", "CI fails"),
    ("pr_opened", "A pull request opens"),
    ("review_requested", "A review is requested"),
    ("issue_labeled", "An issue is labeled"),
    ("pr_comment", "A pull request comment"),
    ("pr_review_comment", "A review comment"),
    ("push", "A push"),
];

/// The condition operators, with their labels.
pub(super) const OPS: &[(&str, &str)] = &[
    ("equals", "equals"),
    ("not_equals", "does not equal"),
    ("in", "is one of"),
    ("not_in", "is none of"),
    ("contains", "contains"),
    ("prefix", "starts with"),
    ("exists", "exists"),
    ("missing", "is missing"),
    ("gt", "is more than"),
    ("gte", "is at least"),
    ("lt", "is less than"),
    ("lte", "is at most"),
];

/// The operators that take no value.
pub(super) const VALUELESS_OPS: &[&str] = &["exists", "missing"];
/// The operators whose value is a list.
pub(super) const LIST_OPS: &[&str] = &["in", "not_in"];
/// The operators whose value is a number.
pub(super) const NUMBER_OPS: &[&str] = &["gt", "gte", "lt", "lte"];

pub(super) const HARNESSES: &[(&str, &str)] = &[("claude", "Claude Code"), ("codex", "Codex")];

#[cfg(test)]
pub(super) const STATUSES: &[&str] =
    &["skipped", "queued", "running", "succeeded", "failed", "capped"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Common {
    pub platform: Option<String>,
    pub team: Option<String>,
    pub token: TokenSource,
}

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Verb {
    Overview,
    Runs { id: String, limit: u32 },
    Create,
    Update { id: String },
    Enable { id: String, enabled: bool, revision: i64 },
    Remove { id: String },
    Preview,
    Templates,
}

impl Verb {
    /// The verbs that read a JSON object from stdin.
    pub(super) fn reads_stdin(&self) -> bool {
        matches!(self, Verb::Create | Verb::Update { .. } | Verb::Preview)
    }
    /// The verbs answered here, with no platform call.
    fn local(&self) -> bool {
        matches!(self, Verb::Preview | Verb::Templates)
    }
}

/// One HTTP request, before the credential and origin are added.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Request {
    pub method: &'static str,
    /// Under `/v1/automations`.
    pub path: String,
    pub query: Vec<(&'static str, String)>,
    pub body: Option<Value>,
}

/// An id the platform minted: 1 to 128 of `[A-Za-z0-9_-]`, safe as a path segment.
pub(super) fn valid_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

pub(super) fn parse(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<(Common, Verb), String> {
    let (kind, rest) = match words {
        [w, rest @ ..] => (w.as_str(), rest),
        [] => return Err("expected a verb (cmux autocloud --help)".into()),
    };
    let mut platform = None;
    let mut team = None;
    let mut token = None;
    let mut limit = None;
    let mut revision = None;
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
            "--limit" if kind == "runs" => {
                let v = value()?;
                let n: u32 = v.parse().map_err(|_| "--limit takes a whole number".to_owned())?;
                if !(1..=200).contains(&n) {
                    return Err("--limit is 1 to 200".into());
                }
                limit = Some(n);
            }
            "--revision" if kind == "enable" || kind == "disable" => {
                let v = value()?;
                revision = Some(
                    v.parse::<i64>().map_err(|_| "--revision takes a whole number".to_owned())?,
                );
            }
            "--secret" | "--spec" => {
                return Err(format!(
                    "{flag}: a spec is read from stdin as JSON, never from an argument"
                ));
            }
            f if f.starts_with("--") => return Err(format!("unexpected argument {f}")),
            _ => positionals.push(arg.clone()),
        }
    }
    let id = || -> Result<String, String> {
        match positionals.as_slice() {
            [id] if valid_id(id) => Ok(id.clone()),
            [id] => Err(format!("{id:?} is not an automation id")),
            [] => Err("name the automation (cmux autocloud overview lists them)".into()),
            [_, extra, ..] => Err(format!("unexpected argument {extra}")),
        }
    };
    let none = |verb: Verb| -> Result<Verb, String> {
        match positionals.first() {
            Some(extra) => Err(format!("unexpected argument {extra}")),
            None => Ok(verb),
        }
    };
    let verb = match kind {
        "overview" | "list" => none(Verb::Overview)?,
        "runs" => Verb::Runs { id: id()?, limit: limit.unwrap_or(50) },
        "create" => none(Verb::Create)?,
        "update" => Verb::Update { id: id()? },
        "enable" | "disable" => Verb::Enable {
            id: id()?,
            enabled: kind == "enable",
            revision: revision.ok_or("--revision N: the revision the overview listed")?,
        },
        "remove" | "delete" => Verb::Remove { id: id()? },
        "preview" => none(Verb::Preview)?,
        "templates" => none(Verb::Templates)?,
        other => return Err(format!("unknown verb {other} (cmux autocloud --help)")),
    };
    let token = token.unwrap_or_else(|| {
        if super::api_tokens::env_credential(env).is_some() {
            TokenSource::Env
        } else {
            TokenSource::App
        }
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

// ---- spec checks ----

fn is_repo(s: &str) -> bool {
    let mut parts = s.split('/');
    let ok = |p: Option<&str>| {
        p.is_some_and(|p| {
            !p.is_empty()
                && p.len() <= 100
                && p.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        })
    };
    ok(parts.next()) && ok(parts.next()) && parts.next().is_none()
}

/// A condition path over the event JSON: dot-separated keys (a number indexes an array).
pub(super) fn valid_path(path: &str) -> bool {
    (1..=200).contains(&path.len())
        && path.split('.').all(|seg| {
            !seg.is_empty()
                && seg.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        })
}

fn text_field<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
}

fn bounded_int(
    v: &Value,
    key: &str,
    (min, max): (i64, i64),
    what: &str,
) -> Result<Option<i64>, String> {
    match v.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(n) => match n.as_i64() {
            Some(n) if (min..=max).contains(&n) => Ok(Some(n)),
            _ => Err(format!("{what} is {min} to {max}")),
        },
    }
}

/// A five-field cron expression, loosely: five fields of digits and `*,-/`.
pub(super) fn valid_cron(cron: &str) -> bool {
    let fields: Vec<&str> = cron.split_whitespace().collect();
    fields.len() == 5
        && fields.iter().all(|f| {
            f.bytes().all(|b| b.is_ascii_digit() || matches!(b, b'*' | b',' | b'-' | b'/'))
        })
}

/// A trigger type name: 1 to 40 of `[a-z0-9_]`.
fn is_type_name(name: &str) -> bool {
    (1..=40).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

fn check_trigger(trigger: &Value) -> Result<Value, String> {
    match text_field(trigger, "type") {
        Some("github") => {
            let events: Vec<String> = trigger
                .get("events")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default();
            if events.is_empty() {
                return Err("a GitHub trigger names at least one event".into());
            }
            if let Some(bad) = events.iter().find(|e| !GITHUB_EVENTS.iter().any(|(v, _)| v == e)) {
                return Err(format!("{bad} is not a GitHub event a trigger can name"));
            }
            let repository = text_field(trigger, "repository").unwrap_or_default();
            if !is_repo(repository) {
                return Err("the trigger's repository is owner/name".into());
            }
            Ok(json!({"type": "github", "events": events, "repository": repository}))
        }
        Some("webhook") => Ok(json!({"type": "webhook"})),
        Some("schedule") => {
            let cron = text_field(trigger, "cron").unwrap_or_default();
            if !valid_cron(cron) {
                return Err("a schedule is a five-field cron expression (0 9 * * 1-5)".into());
            }
            let zone = text_field(trigger, "timeZone").unwrap_or("UTC");
            if zone.len() > 64 || zone.contains(char::is_whitespace) {
                return Err("the time zone is an IANA name (America/Los_Angeles)".into());
            }
            Ok(json!({"type": "schedule", "cron": cron, "timeZone": zone}))
        }
        // The union stays open (Slack, Linear, Jira, Sentry and email triggers come later): a type
        // this CLI does not know goes to the platform as written, and the platform checks it.
        Some(other) if is_type_name(other) && trigger.is_object() => Ok(trigger.clone()),
        _ => {
            Err("the trigger is github, webhook, schedule or another type the platform names"
                .into())
        }
    }
}

fn check_condition(c: &Value) -> Result<Value, String> {
    let path = text_field(c, "path").unwrap_or_default();
    if !valid_path(path) {
        return Err(format!("{path:?} is not an event path (pull_request.base.ref)"));
    }
    let op = text_field(c, "op").unwrap_or_default();
    if !OPS.iter().any(|(v, _)| *v == op) {
        return Err(format!("{op:?} is not a condition operator"));
    }
    let value = match (op, c.get("value")) {
        (op, _) if VALUELESS_OPS.contains(&op) => Value::Null,
        (op, Some(Value::Array(items))) if LIST_OPS.contains(&op) => {
            let items: Vec<String> =
                items.iter().filter_map(Value::as_str).map(str::to_owned).collect();
            if items.is_empty() {
                return Err(format!("{path} {}: name at least one value", op_label(op)));
            }
            json!(items)
        }
        (op, Some(Value::String(s))) if LIST_OPS.contains(&op) => {
            let items: Vec<String> =
                s.split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned).collect();
            if items.is_empty() {
                return Err(format!("{path} {}: name at least one value", op_label(op)));
            }
            json!(items)
        }
        (op, Some(v)) if NUMBER_OPS.contains(&op) => {
            match scalar_text(v).and_then(|t| t.trim().parse::<f64>().ok().map(|_| t)) {
                Some(t) => json!(t.trim()),
                None => return Err(format!("{path} {}: name a number", op_label(op))),
            }
        }
        (_, Some(Value::String(s))) => {
            if s.len() > 1000 {
                return Err(format!("the value for {path} is at most 1000 characters"));
            }
            json!(s)
        }
        (_, Some(Value::Number(n))) => json!(n.to_string()),
        (_, Some(Value::Bool(b))) => json!(b.to_string()),
        _ => return Err(format!("{path} {op}: name a value")),
    };
    let mut out = json!({"path": path, "op": op});
    if !value.is_null() {
        put(&mut out, "value", value);
    }
    Ok(out)
}

fn check_action(a: &Value) -> Result<Value, String> {
    let repo = text_field(a, "repo").unwrap_or_default();
    if !is_repo(repo) {
        return Err("the agent's repository is owner/name".into());
    }
    let reference = text_field(a, "ref").unwrap_or_default();
    if reference.is_empty() || reference.len() > 300 {
        return Err(
            "the agent's ref is a branch, a tag or a template, at most 300 characters".into()
        );
    }
    let harness = text_field(a, "harness").unwrap_or("claude");
    if !HARNESSES.iter().any(|(v, _)| *v == harness) {
        return Err("the harness is claude or codex".into());
    }
    let prompt = a.get("prompt").and_then(Value::as_str).unwrap_or_default();
    if prompt.trim().is_empty() || prompt.len() > 16_384 {
        return Err("the prompt is 1 to 16384 characters".into());
    }
    let mut out = json!({"type": "start_agent", "repo": repo, "ref": reference, "harness": harness, "prompt": prompt});
    if let Some(model) = text_field(a, "model") {
        if model.len() > 128 {
            return Err("the model is at most 128 characters".into());
        }
        put(&mut out, "model", json!(model));
    }
    match text_field(a, "postBack") {
        None => {}
        Some(p @ ("comment" | "none")) => put(&mut out, "postBack", json!(p)),
        Some(_) => return Err("postBack is comment or none".into()),
    }
    if let Some(open) = a.get("openPr").and_then(Value::as_bool) {
        put(&mut out, "openPr", json!(open));
    }
    Ok(out)
}

fn check_guardrails(g: Option<&Value>) -> Result<Value, String> {
    let g = g.cloned().unwrap_or_else(|| json!({}));
    let mut out = Map::new();
    // The platform's bounds (cmux-platform src/api/Automations.ts AutomationGuardrails).
    for (key, bounds, what) in [
        ("cooldownSeconds", (0, 86_400), "the cooldown, in seconds,"),
        ("maxRunsPerDay", (0, 1000), "the daily cap"),
        ("maxConcurrent", (1, 10), "the most runs at once"),
        ("maxMinutesPerRun", (1, 240), "the minutes a run may take"),
    ] {
        if let Some(n) = bounded_int(&g, key, bounds, what)? {
            out.insert(key.into(), json!(n));
        }
    }
    Ok(Value::Object(out))
}

/// The spec a create or update sends, checked and with only the fields the platform takes.
pub(super) fn check_spec(spec: &Value) -> Result<Value, String> {
    if !spec.is_object() {
        return Err("the spec is a JSON object".into());
    }
    let name = text_field(spec, "name").unwrap_or_default();
    if name.is_empty() || name.chars().count() > 100 {
        return Err("the name is 1 to 100 characters".into());
    }
    let trigger = check_trigger(spec.get("trigger").unwrap_or(&Value::Null))?;
    let conditions: Vec<Value> = match spec.get("conditions") {
        None | Some(Value::Null) => vec![],
        Some(Value::Array(list)) if list.len() <= 20 => {
            list.iter().map(check_condition).collect::<Result<_, _>>()?
        }
        Some(Value::Array(_)) => return Err("at most 20 conditions".into()),
        Some(_) => return Err("conditions is a list".into()),
    };
    let action = check_action(spec.get("action").unwrap_or(&Value::Null))?;
    let guardrails = check_guardrails(spec.get("guardrails"))?;
    let mut out = json!({
        "name": name,
        "trigger": trigger,
        "conditions": conditions,
        "action": action,
        "guardrails": guardrails,
    });
    if let Some(enabled) = spec.get("enabled").and_then(Value::as_bool) {
        put(&mut out, "enabled", json!(enabled));
    }
    Ok(out)
}

// ---- templates and preview ----

/// A value at a dot path in `root` (a number segment indexes an array).
pub(super) fn lookup<'a>(root: &'a Value, path: &str) -> Option<&'a Value> {
    path.split('.').try_fold(root, |v, seg| match v {
        Value::Object(map) => map.get(seg),
        Value::Array(items) => seg.parse::<usize>().ok().and_then(|i| items.get(i)),
        _ => None,
    })
}

fn scalar_text(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

/// Renders `{{event.*}}`, `{{trigger.*}}` and `{{run.*}}` in `template` against `scope` (`{event, trigger, run}`):
/// the text, and the placeholders that named nothing (left as they were).
pub(super) fn render(template: &str, scope: &Value) -> (String, Vec<String>) {
    let mut out = String::with_capacity(template.len());
    let mut missing = vec![];
    let mut rest = template;
    while let Some((before, after_open)) = rest.split_once("{{") {
        out.push_str(before);
        let Some((inner, after)) = after_open.split_once("}}") else {
            out.push_str("{{");
            out.push_str(after_open);
            rest = "";
            break;
        };
        let name = inner.trim();
        let known = ["event.", "trigger.", "run."].iter().any(|p| name.starts_with(p));
        match lookup(scope, name).and_then(scalar_text) {
            Some(text) if known => out.push_str(&text),
            _ => {
                out.push_str("{{");
                out.push_str(inner);
                out.push_str("}}");
                if !missing.iter().any(|m| m == name) {
                    missing.push(name.to_owned());
                }
            }
        }
        rest = after;
    }
    out.push_str(rest);
    (out, missing)
}

/// Whether one condition holds for `event`, and what the event has at its path (for the preview).
pub(super) fn holds(condition: &Value, event: &Value) -> (bool, Option<String>) {
    let path = condition.get("path").and_then(Value::as_str).unwrap_or_default();
    let op = condition.get("op").and_then(Value::as_str).unwrap_or_default();
    let found = lookup(event, path);
    let actual =
        found.and_then(|v| scalar_text(v).or_else(|| (!v.is_null()).then(|| v.to_string())));
    let want = condition.get("value");
    let want_text = want.and_then(scalar_text).unwrap_or_default();
    let list: Vec<String> = match want {
        Some(Value::Array(a)) => a.iter().filter_map(scalar_text).collect(),
        _ => want_text.split(',').map(str::trim).map(str::to_owned).collect(),
    };
    let number = |t: &str| t.trim().parse::<f64>().ok();
    let compare = |f: fn(f64, f64) -> bool| {
        actual.as_deref().and_then(number).zip(number(&want_text)).is_some_and(|(a, w)| f(a, w))
    };
    let ok = match op {
        "exists" => found.is_some_and(|v| !v.is_null()),
        "missing" => found.is_none_or(|v| v.is_null()),
        "equals" => actual.as_deref() == Some(want_text.as_str()),
        "not_equals" => actual.as_deref() != Some(want_text.as_str()),
        "contains" => match found {
            Some(Value::Array(items)) => {
                items.iter().filter_map(scalar_text).any(|s| s == want_text)
            }
            _ => actual.as_deref().is_some_and(|a| a.contains(&want_text)),
        },
        "prefix" => actual.as_deref().is_some_and(|a| a.starts_with(&want_text)),
        "in" => actual.as_deref().is_some_and(|a| list.iter().any(|w| w == a)),
        "not_in" => !actual.as_deref().is_some_and(|a| list.iter().any(|w| w == a)),
        "gt" => compare(|a, w| a > w),
        "gte" => compare(|a, w| a >= w),
        "lt" => compare(|a, w| a < w),
        "lte" => compare(|a, w| a <= w),
        _ => false,
    };
    (ok, actual.map(|a| clip(&a, 120)))
}

fn clip(text: &str, max: usize) -> String {
    let clean: String = text.chars().filter(|c| !c.is_control()).collect();
    if clean.chars().count() <= max {
        clean
    } else {
        format!("{}…", clean.chars().take(max - 1).collect::<String>())
    }
}

/// The sample events the preview offers, by kind: trimmed GitHub payloads with the fields templates use.
pub(super) fn sample_event(kind: &str) -> Option<Value> {
    let repository = json!({"full_name": "acme/web", "name": "web", "owner": {"login": "acme"}, "default_branch": "main"});
    Some(match kind {
        "ci_failure" => json!({
            "action": "completed",
            "repository": repository,
            "sender": {"login": "octocat"},
            "workflow_run": {
                "name": "CI",
                "conclusion": "failure",
                "head_branch": "fix-login-redirect",
                "head_sha": "4f2c9e1",
                "html_url": "https://github.com/acme/web/actions/runs/1234",
                "event": "pull_request",
                "pull_requests": [{"number": 42, "head": {"ref": "fix-login-redirect"}, "base": {"ref": "main"}}],
            },
        }),
        "pr_opened" | "review_requested" => json!({
            "action": if kind == "pr_opened" { "opened" } else { "review_requested" },
            "repository": repository,
            "sender": {"login": "octocat"},
            "requested_reviewer": {"login": "cmux-bot"},
            "pull_request": {
                "number": 42,
                "title": "Fix the login redirect",
                "html_url": "https://github.com/acme/web/pull/42",
                "draft": false,
                "user": {"login": "octocat"},
                "head": {"ref": "fix-login-redirect"},
                "base": {"ref": "main"},
            },
        }),
        "issue_labeled" => json!({
            "action": "labeled",
            "repository": repository,
            "sender": {"login": "octocat"},
            "label": {"name": "autofix"},
            "issue": {"number": 7, "title": "Search returns stale results", "html_url": "https://github.com/acme/web/issues/7"},
        }),
        "pr_comment" | "pr_review_comment" => json!({
            "action": "created",
            "repository": repository,
            "sender": {"login": "octocat"},
            "comment": {"body": "@cmux please fix the flaky test", "html_url": "https://github.com/acme/web/pull/42#issuecomment-1"},
            "issue": {"number": 42, "title": "Fix the login redirect"},
            "pull_request": {"number": 42, "head": {"ref": "fix-login-redirect"}, "base": {"ref": "main"}},
        }),
        "push" => json!({
            "ref": "refs/heads/main",
            "repository": repository,
            "sender": {"login": "octocat"},
            "head_commit": {"id": "4f2c9e1", "message": "Bump dependencies"},
        }),
        "webhook" => {
            json!({"type": "deploy.failed", "service": "api", "environment": "staging", "url": "https://deploys.example.com/991"})
        }
        "schedule" => json!({"scheduledAt": "2026-11-24T17:00:00Z"}),
        _ => return None,
    })
}

/// The sample kinds, in the order the preview lists them, with their labels.
pub(super) fn sample_kinds() -> Vec<Value> {
    let mut out: Vec<Value> = GITHUB_EVENTS
        .iter()
        .map(|(value, label)| json!({"value": value, "label": format!("GitHub: {}", label.to_lowercase())}))
        .collect();
    out.push(json!({"value": "webhook", "label": "Webhook: a JSON body"}));
    out.push(json!({"value": "schedule", "label": "Schedule: the time it fired"}));
    out
}

/// The sample a spec's trigger previews against by default.
fn default_sample(spec: &Value) -> &'static str {
    let trigger = spec.get("trigger").unwrap_or(&Value::Null);
    match trigger.get("type").and_then(Value::as_str) {
        Some("webhook") => "webhook",
        Some("schedule") => "schedule",
        _ => {
            let first =
                trigger.pointer("/events/0").and_then(Value::as_str).unwrap_or("ci_failure");
            GITHUB_EVENTS.iter().find(|(v, _)| *v == first).map_or("ci_failure", |(v, _)| v)
        }
    }
}

/// `preview`: `{spec, sample?, event?}` → the rendered ref and prompt, the placeholders that named nothing, and
/// each condition against the event.
pub(super) fn preview(input: &Value) -> Value {
    let spec = input.get("spec").cloned().unwrap_or_else(|| json!({}));
    let sample = input
        .get("sample")
        .and_then(Value::as_str)
        .unwrap_or_else(|| default_sample(&spec))
        .to_owned();
    let event = match input.get("event") {
        Some(e @ Value::Object(_)) => e.clone(),
        _ => match sample_event(&sample) {
            Some(e) => e,
            None => return error_json("cli.invalid_args", &format!("no sample event {sample}")),
        },
    };
    let trigger = spec.get("trigger").cloned().unwrap_or_else(|| json!({}));
    let scope = json!({
        "event": event,
        "trigger": trigger,
        "run": {"url": "https://cmux.com/runs/sample", "id": "run_sample"},
    });
    let action = spec.get("action").unwrap_or(&Value::Null);
    let (reference, mut missing) =
        render(action.get("ref").and_then(Value::as_str).unwrap_or_default(), &scope);
    let (prompt, more) =
        render(action.get("prompt").and_then(Value::as_str).unwrap_or_default(), &scope);
    for m in more {
        if !missing.contains(&m) {
            missing.push(m);
        }
    }
    let conditions: Vec<Value> = spec
        .get("conditions")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .map(|c| {
                    let (ok, actual) = holds(c, &event);
                    json!({
                        "text": condition_text(c),
                        "holds": ok,
                        "actualText": match actual {
                            Some(a) => format!("The event has {a}"),
                            None => "The event has nothing there".to_owned(),
                        },
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let matches = conditions.iter().all(|c| c["holds"] == json!(true));
    json!({
        "ok": true,
        "sample": sample,
        "ref": reference,
        "prompt": prompt,
        "missing": missing,
        "missingText": if missing.is_empty() { Value::Null } else {
            json!(format!("Nothing in the event for {}", missing.iter().map(|m| format!("{{{{{m}}}}}")).collect::<Vec<_>>().join(", ")))
        },
        "conditions": conditions,
        "matches": matches,
        "matchText": if matches { "This event would start the agent" } else { "This event would be skipped" },
    })
}

/// The template gallery: whole specs a person starts from (a first-run template among them).
pub(super) fn templates() -> Vec<Value> {
    vec![
        json!({
            "id": "ci-fix",
            "title": "When CI fails on a PR, start an agent to fix it and push to the PR",
            "summary": "GitHub CI fails on a pull request's branch: an agent reads the failure, fixes it and pushes to the same branch.",
            "spec": {
                "name": "Fix CI on pull requests",
                "trigger": {"type": "github", "events": ["ci_failure"], "repository": ""},
                "conditions": [
                    {"path": "workflow_run.event", "op": "equals", "value": "pull_request"},
                    {"path": "workflow_run.pull_requests.0.number", "op": "exists"},
                ],
                "action": {
                    "type": "start_agent",
                    "repo": "",
                    "ref": "{{event.workflow_run.head_branch}}",
                    "harness": "claude",
                    "prompt": "CI ({{event.workflow_run.name}}) failed on pull request #{{event.workflow_run.pull_requests.0.number}} in {{event.repository.full_name}}: {{event.workflow_run.html_url}}\n\nRead the failing job's log, find the cause, fix it, run the failing check locally if you can, and push the fix to the branch {{event.workflow_run.head_branch}}. Do not open a new pull request.",
                    "postBack": "comment",
                    "openPr": false,
                },
                "guardrails": {"cooldownSeconds": 1800, "maxRunsPerDay": 10, "maxConcurrent": 1, "maxMinutesPerRun": 30},
            },
        }),
        json!({
            "id": "review-requested",
            "title": "When a review is requested, have an agent review the PR",
            "summary": "A person asks for a review: an agent reads the diff and comments on the pull request.",
            "spec": {
                "name": "Review requested pull requests",
                "trigger": {"type": "github", "events": ["review_requested"], "repository": ""},
                "conditions": [{"path": "pull_request.draft", "op": "equals", "value": "false"}],
                "action": {
                    "type": "start_agent",
                    "repo": "",
                    "ref": "{{event.pull_request.head.ref}}",
                    "harness": "codex",
                    "prompt": "Review pull request #{{event.pull_request.number}} ({{event.pull_request.title}}) in {{event.repository.full_name}}: {{event.pull_request.html_url}}\n\nRead the diff against {{event.pull_request.base.ref}}, and reply with what would break, what is missing and what to change. Do not push.",
                    "postBack": "comment",
                    "openPr": false,
                },
                "guardrails": {"cooldownSeconds": 600, "maxRunsPerDay": 20, "maxConcurrent": 2, "maxMinutesPerRun": 20},
            },
        }),
        json!({
            "id": "labeled-issue",
            "title": "When an issue is labeled autofix, start an agent and open a PR",
            "summary": "Label an issue autofix: an agent works on it and opens a pull request with the fix.",
            "spec": {
                "name": "Fix issues labeled autofix",
                "trigger": {"type": "github", "events": ["issue_labeled"], "repository": ""},
                "conditions": [{"path": "label.name", "op": "in", "value": ["autofix", "agent"]}],
                "action": {
                    "type": "start_agent",
                    "repo": "",
                    "ref": "{{event.repository.default_branch}}",
                    "harness": "claude",
                    "prompt": "Fix issue #{{event.issue.number}} ({{event.issue.title}}) in {{event.repository.full_name}}: {{event.issue.html_url}}\n\nWork on a new branch and end with a summary of the change for the pull request.",
                    "postBack": "comment",
                    "openPr": true,
                },
                "guardrails": {"cooldownSeconds": 0, "maxRunsPerDay": 10, "maxConcurrent": 2, "maxMinutesPerRun": 45},
            },
        }),
    ]
}

/// What the card's pickers offer, with their labels.
pub(super) fn catalog() -> Value {
    let list = |items: &[(&str, &str)]| -> Value {
        items.iter().map(|(value, label)| json!({"value": value, "label": label})).collect()
    };
    json!({
        "triggerTypes": list(&[("github", "GitHub event"), ("webhook", "Webhook"), ("schedule", "Schedule")]),
        "githubEvents": list(GITHUB_EVENTS),
        "ops": list(OPS),
        "harnesses": list(HARNESSES),
        "samples": sample_kinds(),
    })
}

// ---- views ----

fn event_label(event: &str) -> String {
    GITHUB_EVENTS
        .iter()
        .find(|(v, _)| *v == event)
        .map_or_else(|| clip(event, 40), |(_, l)| (*l).to_owned())
}

fn harness_label(harness: &str) -> String {
    HARNESSES
        .iter()
        .find(|(v, _)| *v == harness)
        .map_or_else(|| clip(harness, 40), |(_, l)| (*l).to_owned())
}

/// The trigger in one line: "GitHub · CI fails · acme/web".
pub(super) fn trigger_text(trigger: &Value) -> String {
    match trigger.get("type").and_then(Value::as_str) {
        Some("github") => {
            let events: Vec<String> = trigger
                .get("events")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(event_label).collect())
                .unwrap_or_default();
            let repo =
                trigger.get("repository").and_then(Value::as_str).unwrap_or("any repository");
            format!("GitHub · {} · {}", events.join(", "), clip(repo, 100))
        }
        Some("webhook") => "Webhook · a signed POST".to_owned(),
        Some("schedule") => {
            let cron = trigger.get("cron").and_then(Value::as_str).unwrap_or_default();
            let zone = trigger.get("timeZone").and_then(Value::as_str).unwrap_or("UTC");
            format!("Schedule · {} · {}", clip(cron, 60), clip(zone, 64))
        }
        Some(other) => {
            let name = clip(other, 40).replace('_', " ");
            let mut chars = name.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().chain(chars).collect(),
                None => name,
            }
        }
        None => "No trigger".to_owned(),
    }
}

fn op_label(op: &str) -> &str {
    OPS.iter().find(|(v, _)| *v == op).map_or(op, |(_, l)| l)
}

/// One condition in words: "workflow_run.head_branch starts with fix-".
pub(super) fn condition_text(c: &Value) -> String {
    let path = c.get("path").and_then(Value::as_str).unwrap_or_default();
    let op = c.get("op").and_then(Value::as_str).unwrap_or_default();
    let label = op_label(op);
    let value = match c.get("value") {
        Some(Value::Array(items)) => {
            items.iter().filter_map(scalar_text).collect::<Vec<_>>().join(", ")
        }
        Some(v) => scalar_text(v).unwrap_or_default(),
        None => String::new(),
    };
    clip(
        if value.is_empty() {
            format!("{path} {label}")
        } else {
            format!("{path} {label} {value}")
        }
        .trim(),
        200,
    )
}

/// "3 minutes ago", from unix milliseconds against `now_ms`.
pub(super) fn ago(ms: i64, now_ms: i64) -> String {
    let s = (now_ms - ms).max(0) / 1000;
    let plural = |n: i64, unit: &str| {
        if n == 1 { format!("1 {unit} ago") } else { format!("{n} {unit}s ago") }
    };
    match s {
        0..60 => "just now".to_owned(),
        60..3600 => plural(s / 60, "minute"),
        3600..86_400 => plural(s / 3600, "hour"),
        _ => plural(s / 86_400, "day"),
    }
}

pub(super) fn status_label(status: &str) -> &'static str {
    match status {
        "skipped" => "Skipped",
        "queued" => "Queued",
        "running" => "Running",
        "succeeded" => "Succeeded",
        "failed" => "Failed",
        "capped" => "Over the cap",
        _ => "Unknown",
    }
}

/// The status dot's tone: good, warn, bad or plain.
fn status_tone(status: &str) -> &'static str {
    match status {
        "succeeded" => "good",
        "running" | "queued" => "plain",
        "failed" => "bad",
        "capped" => "warn",
        _ => "plain",
    }
}

fn link_label(key: &str) -> Option<&'static str> {
    match key {
        "pr" => Some("Pull request"),
        "comment" => Some("Comment"),
        "session" => Some("Session"),
        _ => None,
    }
}

/// One run with its view fields.
pub(super) fn run_view(run: &Value, now_ms: i64) -> Value {
    let status = run.get("status").and_then(Value::as_str).unwrap_or_default();
    let started = run.get("startedAt").and_then(Value::as_i64);
    let minutes = run.get("minutes").and_then(Value::as_f64);
    let links: Vec<Value> = ["pr", "comment", "session"]
        .iter()
        .filter_map(|k| {
            let url = run.pointer(&format!("/links/{k}")).and_then(Value::as_str)?;
            url.starts_with("https://").then(|| json!({"label": link_label(k), "url": url}))
        })
        .collect();
    let matched: Vec<String> = run
        .get("matched")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(|s| clip(s, 120)).collect())
        .unwrap_or_default();
    json!({
        "id": run.get("id").cloned().unwrap_or(Value::Null),
        "status": status,
        "statusLabel": status_label(status),
        "tone": status_tone(status),
        "eventText": run.pointer("/event/summary").and_then(Value::as_str).map(|s| clip(s, 200))
            .unwrap_or_else(|| "An event".to_owned()),
        "whenText": started.map(|s| ago(s, now_ms)),
        "minutesText": minutes.map(|m| if m < 1.0 { "under a minute".to_owned() }
            else if (m - 1.0).abs() < f64::EPSILON { "1 minute".to_owned() }
            else { format!("{} minutes", m.round() as i64) }),
        "machine": run.get("machine").and_then(Value::as_str),
        "links": links,
        "matchedText": (!matched.is_empty()).then(|| matched.join(" · ")),
        "errorText": run.get("error").and_then(Value::as_str).map(|s| clip(s, 300)),
    })
}

/// One automation with its view fields; `spec` is what the edit form starts from.
pub(super) fn automation_view(a: &Value, now_ms: i64) -> Value {
    let trigger = a.get("trigger").cloned().unwrap_or(Value::Null);
    let conditions = a.get("conditions").cloned().unwrap_or_else(|| json!([]));
    let action = a.get("action").cloned().unwrap_or(Value::Null);
    let condition_list: Vec<String> =
        conditions.as_array().map(|l| l.iter().map(condition_text).collect()).unwrap_or_default();
    let last = a.get("lastRun").filter(|r| r.is_object()).map(|r| run_view(r, now_ms));
    let last_text = match &last {
        Some(r) => match r["whenText"].as_str() {
            Some(when) => format!("{} {when}", r["statusLabel"].as_str().unwrap_or_default()),
            None => r["statusLabel"].as_str().unwrap_or_default().to_owned(),
        },
        None => "Never ran".to_owned(),
    };
    let repo = action.get("repo").and_then(Value::as_str).unwrap_or_default();
    let harness = harness_label(action.get("harness").and_then(Value::as_str).unwrap_or("claude"));
    json!({
        "id": a.get("id").cloned().unwrap_or(Value::Null),
        "name": a.get("name").and_then(Value::as_str).map(|s| clip(s, 100)).unwrap_or_default(),
        "enabled": a.get("enabled").and_then(Value::as_bool).unwrap_or(false),
        "revision": a.get("revision").and_then(Value::as_i64).unwrap_or(0),
        "triggerType": trigger.get("type").cloned().unwrap_or(Value::Null),
        "triggerText": trigger_text(&trigger),
        "conditionsText": (!condition_list.is_empty()).then(|| format!("Only when {}", condition_list.join(" and "))),
        "actionText": format!("Starts {harness} on {}", clip(repo, 100)),
        "lastRun": last,
        "lastRunText": last_text,
        "webhookUrl": a.get("webhookUrl").and_then(Value::as_str).filter(|u| u.starts_with("https://")),
        "spec": {
            "name": a.get("name").cloned().unwrap_or(Value::Null),
            "trigger": trigger,
            "conditions": conditions,
            "action": action,
            "guardrails": a.get("guardrails").cloned().unwrap_or_else(|| json!({})),
        },
    })
}

/// The platform's error, kept with its own code and a short, printable message. A 404 with no
/// automations code is a deployment without them: `available: false`.
pub(super) fn api_error(status: u16, body: &Value) -> Value {
    let field = |p: &str| body.pointer(p).and_then(Value::as_str).map(|s| clip(s, 300));
    let code =
        field("/error/code").or_else(|| field("/code")).unwrap_or_else(|| "api.bad_answer".into());
    let message = field("/error/message")
        .or_else(|| field("/message"))
        .unwrap_or_else(|| format!("the cmux platform answered HTTP {status}"));
    let mut error = error_json(&code, &message);
    if let Some(inner) = error.get_mut("error") {
        put(inner, "status", json!(status));
    }
    if status == 404 && !code.starts_with("automation.") {
        put(&mut error, "available", json!(false));
    }
    error
}

pub(super) fn not_here() -> Value {
    json!({
        "ok": true,
        "available": false,
        "message": "Cloud automations are not available on this cmux Cloud deployment yet.",
        "automations": [],
        "templates": templates(),
        "catalog": catalog(),
    })
}

/// The overview from the list answer.
pub(super) fn overview(status: u16, body: &Value, now_ms: i64) -> Value {
    if !(200..300).contains(&status) {
        let error = api_error(status, body);
        return if error.get("available") == Some(&json!(false)) { not_here() } else { error };
    }
    let list = body.get("automations").and_then(Value::as_array).cloned().unwrap_or_default();
    json!({
        "ok": true,
        "available": true,
        "automations": list.iter().map(|a| automation_view(a, now_ms)).collect::<Vec<_>>(),
        "templates": templates(),
        "catalog": catalog(),
    })
}

pub(super) fn request_of(verb: &Verb, body: Option<Value>) -> Option<Request> {
    let r = |method, path: String, query: Vec<(&'static str, String)>, body| Request {
        method,
        path,
        query,
        body,
    };
    Some(match verb {
        Verb::Overview => r("GET", String::new(), vec![], None),
        Verb::Runs { id, limit } => {
            r("GET", format!("/{id}/runs"), vec![("limit", limit.to_string())], None)
        }
        Verb::Create => r("POST", String::new(), vec![], body),
        Verb::Update { id } => r("PATCH", format!("/{id}"), vec![], body),
        Verb::Enable { id, enabled, revision } => r(
            "PATCH",
            format!("/{id}"),
            vec![],
            Some(json!({"enabled": enabled, "revision": revision})),
        ),
        Verb::Remove { id } => r("DELETE", format!("/{id}"), vec![], None),
        Verb::Preview | Verb::Templates => return None,
    })
}

/// The full URL of a request.
pub(super) fn url_of(platform: &str, request: &Request, team: Option<&str>) -> String {
    let mut url = format!("{platform}/v1/automations{}", request.path);
    let mut query = request.query.clone();
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

pub(super) fn percent(value: &str) -> String {
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

/// A verb's answer from the platform's status and body.
pub(super) fn answer(verb: &Verb, status: u16, body: &Value, now_ms: i64) -> Value {
    if !matches!(verb, Verb::Overview) && !(200..300).contains(&status) {
        return api_error(status, body);
    }
    match verb {
        Verb::Overview => overview(status, body, now_ms),
        Verb::Runs { id, .. } => {
            let runs = body.get("runs").and_then(Value::as_array).cloned().unwrap_or_default();
            json!({"ok": true, "automation": id, "runs": runs.iter().map(|r| run_view(r, now_ms)).collect::<Vec<_>>()})
        }
        Verb::Create | Verb::Update { .. } | Verb::Enable { .. } => {
            let Some(automation) = body.get("automation").filter(|a| a.is_object()) else {
                return error_json(
                    "api.bad_answer",
                    "the cmux platform's answer named no automation",
                );
            };
            let mut out = json!({"ok": true, "automation": automation_view(automation, now_ms)});
            // A new webhook automation's secret, once: the app shows it and keeps no copy.
            if let Some(secret) =
                body.get("secret").and_then(Value::as_str).filter(|s| !s.is_empty())
            {
                put(&mut out, "secret", json!(secret));
                put(
                    &mut out,
                    "secretText",
                    json!(
                        "Copy this secret now; it is not shown again. Sign each POST: x-cmux-webhook-signature is sha256= and the HMAC-SHA256 of the timestamp, delivery id and body, with x-cmux-webhook-timestamp and x-cmux-webhook-delivery (or Standard Webhooks headers)."
                    ),
                );
            }
            out
        }
        Verb::Remove { id } => json!({"ok": true, "removed": id}),
        Verb::Preview | Verb::Templates => json!({"ok": true}),
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// A verb answered with no platform call.
pub(super) fn run_local(verb: &Verb, input: Option<&Value>) -> Value {
    match verb {
        Verb::Preview => preview(input.unwrap_or(&Value::Null)),
        Verb::Templates => json!({"ok": true, "templates": templates(), "catalog": catalog()}),
        _ => error_json("cli.invalid_args", "not a local verb"),
    }
}

async fn run(common: &Common, verb: &Verb, input: Option<Value>) -> Value {
    if verb.local() {
        return run_local(verb, input.as_ref());
    }
    let body = match (verb, &input) {
        (Verb::Create | Verb::Update { .. }, Some(spec)) => match check_spec(spec) {
            Ok(mut checked) => {
                if let Verb::Update { .. } = verb {
                    match spec.get("revision").and_then(Value::as_i64) {
                        Some(rev) => put(&mut checked, "revision", json!(rev)),
                        None => {
                            return error_json(
                                "cli.invalid_args",
                                "an update names the revision it edits",
                            );
                        }
                    }
                }
                Some(checked)
            }
            Err(e) => return error_json("automation.invalid", &e),
        },
        (Verb::Create | Verb::Update { .. }, None) => {
            return error_json("cli.invalid_args", "the spec is read from stdin as JSON");
        }
        _ => None,
    };
    let Some(request) = request_of(verb, body) else {
        return error_json("cli.invalid_args", "no request");
    };
    let (token, issued_by) = match backend_credential(&common.token, common.team.as_deref()).await {
        Ok(t) => t,
        Err(e) => return error_json("auth.no_token", &e),
    };
    let token = Zeroizing::new(token);
    let platform = match platform_for(common.platform.as_deref(), issued_by.as_deref()) {
        Ok(p) => p,
        Err(e) => return error_json("cli.invalid_args", &e),
    };
    let http = match cmux_egress::client_builder("cmux_tui::cli::autocloud")
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(30))
        .build()
    {
        Ok(h) => h,
        Err(e) => return error_json("cli.http_client", &e.to_string()),
    };
    let url = url_of(&platform, &request, common.team.as_deref());
    let mut builder = match request.method {
        "POST" => http.post(url),
        "PATCH" => http.patch(url),
        "DELETE" => http.delete(url),
        _ => http.get(url),
    }
    .bearer_auth(token.as_str())
    .header("accept", "application/json");
    if let Some(b) = &request.body {
        builder = builder.header("content-type", "application/json").body(b.to_string());
    }
    let response = match builder.send().await {
        Ok(r) => r,
        Err(_) => return error_json("api.unreachable", "the cmux platform did not answer"),
    };
    let status = response.status().as_u16();
    let bytes = match response.bytes().await {
        Ok(b) => b,
        Err(_) => return error_json("api.unreachable", "the cmux platform's answer was cut off"),
    };
    let value = match serde_json::from_slice::<Value>(&bytes) {
        Ok(v) => v,
        Err(_) if status == 404 => json!({}),
        Err(_) => {
            return error_json(
                "api.bad_answer",
                &format!("the cmux platform answered HTTP {status}, not JSON"),
            );
        }
    };
    let mut out = answer(verb, status, &value, now_ms());
    if let Verb::Overview = verb
        && let Some(map) = out.as_object_mut()
    {
        map.insert("platform".into(), json!(platform));
        if let Some(team) = &common.team {
            map.insert("team".into(), json!(team));
        }
    }
    out
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
        eprintln!("cmux autocloud: {code}: {message}");
        return;
    }
    for line in human_lines(answer) {
        println!("{line}");
    }
}

pub(super) fn human_lines(answer: &Value) -> Vec<String> {
    let mut lines = vec![];
    if let Some(message) = answer.get("message").and_then(Value::as_str) {
        lines.push(message.to_owned());
    }
    for a in answer.get("automations").and_then(Value::as_array).into_iter().flatten() {
        let on = if a["enabled"] == json!(true) { "on " } else { "off" };
        lines.push(format!(
            "{on}  {}  {}  {}  ({})",
            a["id"].as_str().unwrap_or_default(),
            a["name"].as_str().unwrap_or_default(),
            a["triggerText"].as_str().unwrap_or_default(),
            a["lastRunText"].as_str().unwrap_or_default()
        ));
    }
    for r in answer.get("runs").and_then(Value::as_array).into_iter().flatten() {
        lines.push(format!(
            "{}  {}  {}",
            r["statusLabel"].as_str().unwrap_or_default(),
            r["whenText"].as_str().unwrap_or_default(),
            r["eventText"].as_str().unwrap_or_default()
        ));
    }
    if let Some(a) = answer.get("automation").filter(|a| a.is_object()) {
        lines.push(format!(
            "{}  {}",
            a["id"].as_str().unwrap_or_default(),
            a["name"].as_str().unwrap_or_default()
        ));
        if let Some(url) = a["webhookUrl"].as_str() {
            lines.push(format!("webhook URL: {url}"));
        }
    }
    if let Some(secret) = answer.get("secret").and_then(Value::as_str) {
        lines.push(format!("secret (shown once): {secret}"));
    }
    if let Some(id) = answer.get("removed").and_then(Value::as_str) {
        lines.push(format!("removed {id}"));
    }
    if answer.get("prompt").is_some() {
        lines.push(format!("ref: {}", answer["ref"].as_str().unwrap_or_default()));
        lines.push(answer["prompt"].as_str().unwrap_or_default().to_owned());
        lines.push(answer["matchText"].as_str().unwrap_or_default().to_owned());
    }
    for t in answer.get("templates").and_then(Value::as_array).into_iter().flatten() {
        if answer.get("automations").is_none() {
            lines.push(format!(
                "{}  {}",
                t["id"].as_str().unwrap_or_default(),
                t["title"].as_str().unwrap_or_default()
            ));
        }
    }
    lines
}

/// `Some(exit code)` for `cmux autocloud …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_action_globals(args).ok()?;
    let rest = match command_args.as_slice() {
        [h, rest @ ..] if h == "autocloud" => rest,
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
    let input = if verb.reads_stdin() {
        let mut raw = String::new();
        if std::io::stdin().lock().take(256 * 1024).read_to_string(&mut raw).is_err() {
            print(&error_json("cli.invalid_args", "could not read the spec from stdin"), json_out);
            return 2;
        }
        match serde_json::from_str::<Value>(&raw) {
            Ok(v @ Value::Object(_)) => Some(v),
            _ => {
                print(&error_json("cli.invalid_args", "stdin is not a JSON object"), json_out);
                return 2;
            }
        }
    } else {
        None
    };
    let answer = if verb.local() {
        run_local(&verb, input.as_ref())
    } else {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(r) => r,
            Err(e) => {
                print(&error_json("cli.runtime", &e.to_string()), json_out);
                return 1;
            }
        };
        runtime.block_on(run(&common, &verb, input))
    };
    print(&answer, json_out);
    if answer.get("ok").and_then(Value::as_bool) == Some(true) { 0 } else { 1 }
}

/// Sets `key` on a JSON object (a no-op on anything else): the non-panicking form of `v[key] = value`.
fn put(v: &mut Value, key: &str, value: Value) {
    if let Some(map) = v.as_object_mut() {
        map.insert(key.to_owned(), value);
    }
}

#[cfg(test)]
#[path = "autocloud_tests.rs"]
mod tests;
