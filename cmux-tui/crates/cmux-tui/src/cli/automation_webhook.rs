//! `cmux automation create NAME --webhook --on cloud --from MACHINE --repo OWNER/REPO --prompt TEXT`
//! (cmuxterm-hq docs/rfd/0001-webhooks.md, section 5): a GitHub repository webhook that starts an
//! agent on a fork of one of the person's machines.
//!
//! As the signed-in person (`CMUX_CLOUD_ACCESS_TOKEN`, else a token the app mints), against the
//! cmux platform, in order:
//!
//! 1. `POST /v1/machines/{from}/fork` with a `clientKey` derived from the automation, so a
//!    retried create reaches the same fork;
//! 2. `POST /v1/workspaces/auto-<slug>/machine/import` binds a workspace to that fork (a
//!    trigger's target must be a workspace bound to its machine, cmux-platform
//!    src/server/triggers/Access.ts); a retry with generation 0 replays the finished import;
//! 3. `POST /v1/triggers` registers a repository webhook (no `installation`) that starts a
//!    session on the fork for each delivery.
//!
//! No `x-cmux-team` header: the fork, the binding and the trigger all live in the person's
//! personal team, where the trigger's access check reads the binding.
//!
//! It prints the trigger id, the fork, the URL to paste into GitHub and the secret, which the
//! platform shows only once. `--target cloud --webhook` (a Chief job) is unchanged.

use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::{Args, Failure, Out, Outcome, OutputMode, messages, parse_duration, usage};
use crate::cli::{GlobalArgs, Platform, PlatformCallError as CallError};

pub(super) const TRIGGERS_PATH: &str = "/v1/triggers";
/// A fork is a snapshot and its restore, which can take a minute or more.
const TIMEOUT: Duration = Duration::from_secs(180);
const DEFAULT_COOLDOWN_SECONDS: u64 = 600;
const MAX_COOLDOWN_SECONDS: u64 = 86_400;
const DEFAULT_MAX_RUNS: u64 = 24;
const MAX_RUNS: u64 = 1_000;
const SLUG_MAX: usize = 48;
const CLIENT_KEY_PREFIX: &str = "auto-webhook-";

const VALUED: &[&str] = &[
    "on", "from", "repo", "prompt", "cwd", "harness", "events", "cooldown", "max-runs", "platform",
    // Refused below with a reason: a Cloud webhook runs its prompt, on its own schedule.
    "if", "watch", "every", "command", "daily", "weekdays", "weekly", "at", "in", "cron", "when",
    "debounce",
];
const FLAGS: &[&str] = &["webhook", "yes", "hourly", "manual"];
const PROMPT_ONLY_VALUED: &[&str] = &[
    "if", "watch", "every", "command", "daily", "weekdays", "weekly", "at", "in", "cron", "when",
    "debounce",
];
const PROMPT_ONLY_FLAGS: &[&str] = &["hourly", "manual"];

/// The stored trigger kinds, and RFD 5.2's class names for them.
const EVENTS: &[(&str, &str)] = &[
    ("ci_failure", "github.workflow_run.failed"),
    ("pr_opened", "github.pull_request.opened"),
    ("pr_review_comment", "github.pull_request.review_comment"),
    ("pr_comment", "github.pull_request.comment"),
];

/// `create|new|add … --on …`: this module's create, before `--target` is read.
pub(super) fn wants(args: &[String]) -> bool {
    let Some((verb, rest)) = args.split_first() else { return false };
    matches!(verb.as_str(), "create" | "new" | "add")
        && rest.iter().any(|arg| arg == "--on" || arg.starts_with("--on="))
}

/// A checked create: everything the three requests need.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Plan {
    pub name: String,
    pub slug: String,
    pub from: String,
    pub repository: String,
    pub prompt: String,
    pub cwd: String,
    pub harness: String,
    pub events: Vec<&'static str>,
    pub cooldown_seconds: u64,
    pub max_runs: u64,
    pub platform: Option<String>,
}

impl Plan {
    /// The workspace bound to the fork.
    fn workspace(&self) -> String {
        format!("auto-{}", self.slug)
    }

    /// The name prefix of the chat each delivery starts.
    fn session(&self) -> String {
        format!("auto-{}", self.slug)
    }

    /// The same for the same automation (its name, repository and source machine), so a retried
    /// create reaches the same fork and the same import.
    fn client_key(&self) -> String {
        let digest = Sha256::digest(
            format!("{}\n{}\n{}", self.name, self.repository.to_ascii_lowercase(), self.from)
                .as_bytes(),
        );
        let hex: String = digest.iter().take(16).map(|byte| format!("{byte:02x}")).collect();
        format!("{CLIENT_KEY_PREFIX}{hex}")
    }
}

/// The words after `create`, checked before any request.
fn plan(args: &[String]) -> Result<Plan, Failure> {
    let a = Args::parse(args, VALUED, FLAGS)?;
    let m = messages();
    if let Some(flag) = PROMPT_ONLY_VALUED
        .iter()
        .find(|f| a.value(f).is_some())
        .or_else(|| PROMPT_ONLY_FLAGS.iter().find(|f| a.flag(f)))
    {
        return usage(m.webhook_prompt_only.replace("{flag}", flag));
    }
    match a.value("on") {
        Some("cloud") => {}
        Some(other) => return usage(m.webhook_bad_on.replace("{value}", other)),
        None => return usage(m.webhook_missing.replace("{flag}", "on")),
    }
    if !a.flag("webhook") {
        return usage(m.webhook_needs_webhook);
    }
    let name = a.one_word("NAME")?.to_string();
    let required = |flag: &str| -> Result<String, Failure> {
        match a.value(flag) {
            Some(v) if flag != "prompt" || !v.trim().is_empty() => Ok(v.to_string()),
            _ => usage(m.webhook_missing.replace("{flag}", flag)),
        }
    };
    let repository = required("repo")?;
    let from = required("from")?;
    let prompt = required("prompt")?;
    if !valid_repo(&repository) {
        return usage(m.webhook_bad_repo.replace("{value}", &repository));
    }
    if !valid_machine(&from) {
        return usage(m.webhook_bad_machine.replace("{value}", &from));
    }
    let slug = slug(&name);
    if slug.is_empty() {
        return usage(m.webhook_bad_name.replace("{value}", &name));
    }
    let harness = a.value("harness").unwrap_or("claude");
    if !matches!(harness, "claude" | "codex") {
        return usage(m.webhook_bad_harness.replace("{value}", harness));
    }
    let events = match a.value("events") {
        Some(list) => parse_events(list)?,
        None => vec!["ci_failure"],
    };
    let cwd = match a.value("cwd") {
        Some(cwd) if cwd.starts_with('/') && cwd.len() <= 4096 => cwd.to_string(),
        Some(cwd) => return usage(m.webhook_bad_cwd.replace("{value}", cwd)),
        None => format!("/root/{}", repository.split('/').nth(1).unwrap_or_default()),
    };
    let cooldown_seconds = match a.value("cooldown") {
        Some(text) => {
            let seconds = parse_duration(text)?;
            if seconds > MAX_COOLDOWN_SECONDS {
                return usage(m.webhook_bad_cooldown.replace("{value}", text));
            }
            seconds
        }
        None => DEFAULT_COOLDOWN_SECONDS,
    };
    let max_runs = match a.value("max-runs") {
        Some(text) => match text.trim().parse::<u64>() {
            Ok(n) if n <= MAX_RUNS => n,
            _ => return usage(m.bad_max_runs.replace("{value}", text)),
        },
        None => DEFAULT_MAX_RUNS,
    };
    // RFD 5.5: the fork carries everything on the source machine; the person says so first.
    if !a.flag("yes") {
        return usage(m.webhook_consent_needed.replace("{consent}", &consent_line(&from)));
    }
    Ok(Plan {
        name,
        slug,
        from,
        repository,
        prompt,
        cwd,
        harness: harness.to_string(),
        events,
        cooldown_seconds,
        max_runs,
        platform: a.value("platform").map(str::to_string),
    })
}

/// `OWNER/REPO`, as the platform's trigger schema takes it.
fn valid_repo(repo: &str) -> bool {
    let part = |s: &str| {
        !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
    };
    matches!(repo.split_once('/'), Some((owner, name)) if part(owner) && part(name))
}

/// A machine id that is safe in a path: letters, digits, `_` and `-`.
fn valid_machine(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 256
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// `--events a,b`: each a stored kind or its RFD class name, repeats dropped, in order.
fn parse_events(list: &str) -> Result<Vec<&'static str>, Failure> {
    let mut out: Vec<&'static str> = Vec::new();
    for word in list.split(',').map(str::trim).filter(|w| !w.is_empty()) {
        let Some(&(kind, _)) = EVENTS.iter().find(|&&(kind, class)| kind == word || class == word)
        else {
            return usage(messages().webhook_bad_event.replace("{value}", word));
        };
        if !out.contains(&kind) {
            out.push(kind);
        }
    }
    if out.is_empty() {
        return usage(messages().webhook_bad_event.replace("{value}", list));
    }
    Ok(out)
}

/// Lowercase letters and digits, other runs turned into one `-`, at most [`SLUG_MAX`].
fn slug(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    out.truncate(SLUG_MAX);
    while out.ends_with('-') {
        out.pop();
    }
    out
}

/// What a run on a fork of `from` can see (RFD 5.5).
fn consent_line(from: &str) -> String {
    messages().webhook_consent.replace("{machine}", from)
}

/// The GitHub webhook settings that send `events`.
fn github_events(events: &[&str]) -> Vec<&'static str> {
    let mut out = Vec::new();
    for kind in events {
        let names: &[&'static str] = match *kind {
            "ci_failure" => &["Workflow runs"],
            "pr_opened" => &["Pull requests"],
            "pr_review_comment" => &["Pull request reviews", "Pull request review comments"],
            "pr_comment" => &["Issue comments"],
            _ => &[],
        };
        for name in names {
            if !out.contains(name) {
                out.push(*name);
            }
        }
    }
    out
}

fn fork_path(plan: &Plan) -> String {
    format!("/v1/machines/{}/fork", plan.from)
}

fn fork_body(plan: &Plan) -> Value {
    json!({"clientKey": plan.client_key()})
}

fn bind_path(plan: &Plan) -> String {
    format!("/v1/workspaces/{}/machine/import", plan.workspace())
}

/// Adopts the fork for the workspace: generation 0 for a workspace with no machine yet (a retry
/// replays the finished import).
fn bind_body(plan: &Plan, fork: &str) -> Value {
    json!({"carrierMachine": fork, "expectedGeneration": 0, "clientKey": plan.client_key()})
}

fn trigger_body(plan: &Plan, fork: &str) -> Value {
    json!({
        "repository": plan.repository,
        "prompt": plan.prompt,
        "events": plan.events,
        "target": {
            "machine": fork,
            "workspace": plan.workspace(),
            "session": plan.session(),
            "cwd": plan.cwd,
            "harness": plan.harness,
            "policy": "start_session",
        },
        "guardrails": {"cooldownSeconds": plan.cooldown_seconds, "maxRunsPerDay": plan.max_runs},
    })
}

struct Registered {
    machine: String,
    trigger: String,
    secret: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Fork,
    Bind,
    Trigger,
    Remove,
}

impl Step {
    fn code(self) -> &'static str {
        match self {
            Step::Fork => "fork",
            Step::Bind => "bind",
            Step::Trigger => "trigger",
            Step::Remove => "remove",
        }
    }

    fn words(self) -> &'static str {
        let m = messages();
        match self {
            Step::Fork => m.webhook_step_fork,
            Step::Bind => m.webhook_step_bind,
            Step::Trigger => m.webhook_step_trigger,
            Step::Remove => m.webhook_step_remove,
        }
    }
}

enum Why {
    Call(CallError),
    /// The workspace is bound to this other machine.
    Bound(String),
}

/// Where a create stopped, and the fork when it was made.
struct Stopped {
    step: Step,
    machine: Option<String>,
    why: Why,
}

fn stopped(step: Step, machine: Option<&str>, why: Why) -> Stopped {
    Stopped { step, machine: machine.map(str::to_owned), why }
}

fn text_at<'a>(v: &'a Value, path: &[&str]) -> Option<&'a str> {
    path.iter().try_fold(v, |v, key| v.get(key)).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// The three calls, in order; each is safe to repeat (the fork and the import by their key).
fn register(platform: &Platform, plan: &Plan) -> Result<Registered, Stopped> {
    let unreadable =
        |step, machine: Option<&str>| stopped(step, machine, Why::Call(CallError::Unreadable(200)));
    let fork = platform
        .post(&fork_path(plan), fork_body(plan))
        .map_err(|e| stopped(Step::Fork, None, Why::Call(e)))?;
    let machine = text_at(&fork, &["id"])
        .or_else(|| text_at(&fork, &["machine", "id"]))
        .ok_or_else(|| unreadable(Step::Fork, None))?
        .to_owned();
    let bound = platform
        .post(&bind_path(plan), bind_body(plan, &machine))
        .map_err(|e| stopped(Step::Bind, Some(&machine), Why::Call(e)))?;
    if let Some(other) = text_at(&bound, &["machineId"]) {
        if other != machine {
            return Err(stopped(Step::Bind, Some(&machine), Why::Bound(other.to_owned())));
        }
    }
    let answer = platform
        .post(TRIGGERS_PATH, trigger_body(plan, &machine))
        .map_err(|e| stopped(Step::Trigger, Some(&machine), Why::Call(e)))?;
    let trigger = text_at(&answer, &["trigger", "id"]).or_else(|| text_at(&answer, &["id"]));
    let secret = text_at(&answer, &["secret"]);
    match (trigger, secret) {
        (Some(trigger), Some(secret)) => {
            Ok(Registered { machine, trigger: trigger.to_owned(), secret: secret.to_owned() })
        }
        _ => Err(unreadable(Step::Trigger, Some(&machine))),
    }
}

/// The answer: one object, printed whole by `--json`.
fn created(plan: &Plan, origin: &str, done: &Registered) -> Value {
    json!({
        "id": done.trigger,
        "name": plan.name,
        "machine": done.machine,
        "from": plan.from,
        "workspace": plan.workspace(),
        "session": plan.session(),
        "repository": plan.repository,
        "events": plan.events,
        "url": format!("{origin}{TRIGGERS_PATH}/{}/github", done.trigger),
        "content_type": "application/json",
        "github_events": github_events(&plan.events),
        "secret": done.secret,
        "secret_shown_once": true,
    })
}

fn field<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

fn human_lines(plan: &Plan, created: &Value) -> Vec<String> {
    let m = messages();
    let github = created
        .get("github_events")
        .and_then(Value::as_array)
        .map(|names| names.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", "))
        .unwrap_or_default();
    vec![
        m.webhook_created.replace("{name}", &plan.name).replace("{id}", field(created, "id")),
        m.webhook_machine
            .replace("{machine}", field(created, "machine"))
            .replace("{from}", &plan.from)
            .replace("{workspace}", field(created, "workspace")),
        consent_line(&plan.from),
        m.webhook_url.replace("{url}", field(created, "url")),
        m.webhook_content_type.to_string(),
        m.webhook_github_events.replace("{events}", &github),
        m.webhook_secret.replace("{secret}", field(created, "secret")),
        m.webhook_secret_once.to_string(),
    ]
}

/// `--quiet` still prints what cannot be read again.
fn quiet_lines(created: &Value) -> Vec<String> {
    let m = messages();
    vec![
        m.webhook_url.replace("{url}", field(created, "url")),
        m.webhook_secret.replace("{secret}", field(created, "secret")),
    ]
}

/// A failed call's error: its value, exit code (1 refused, 3 signed out or unreachable) and
/// whether it may have applied.
fn call_error(step: Step, error: &CallError) -> (Value, i32, bool) {
    let m = messages();
    let (code, message, exit, unknown) = match error {
        CallError::Status { status: 401, code, .. } => (
            "automation.signed_out",
            m.webhook_signed_out.replace("{reason}", format!("401 {code}").trim_end()),
            3,
            false,
        ),
        CallError::Status { status, code, facts } => (
            "automation.webhook.refused",
            m.webhook_refused.replace("{step}", step.words()).replace(
                "{status}",
                &format!(
                    "{}{}",
                    format!("{status} {code}").trim_end(),
                    crate::cli::platform_refusal_reason(code, facts.as_ref())
                ),
            ),
            1,
            false,
        ),
        CallError::Unreachable(reason) => (
            "automation.webhook.unreachable",
            m.webhook_unreachable.replace("{step}", step.words()).replace("{reason}", reason),
            3,
            true,
        ),
        CallError::Unreadable(status) => (
            "automation.webhook.unreadable",
            m.webhook_unreadable
                .replace("{step}", step.words())
                .replace("{status}", &status.to_string()),
            1,
            true,
        ),
    };
    let retryable = matches!(error, CallError::Unreachable(_));
    (
        json!({"code": code, "message": message, "details": {"step": step.code()}, "retryable": retryable}),
        exit,
        unknown,
    )
}

fn stopped_error(plan: &Plan, stop: &Stopped) -> (Value, i32, bool) {
    let (mut error, exit, unknown) = match &stop.why {
        Why::Call(e) => call_error(stop.step, e),
        Why::Bound(other) => (
            json!({
                "code": "automation.webhook.workspace_taken",
                "message": messages()
                    .webhook_workspace_taken
                    .replace("{workspace}", &plan.workspace())
                    .replace("{bound}", other)
                    .replace("{machine}", stop.machine.as_deref().unwrap_or("")),
                "details": {"step": stop.step.code(), "workspace": plan.workspace(), "bound": other},
                "retryable": false,
            }),
            1,
            false,
        ),
    };
    if let Some(machine) = &stop.machine {
        error["details"]["machine"] = json!(machine);
        let message = format!(
            "{}; {}",
            error["message"].as_str().unwrap_or(""),
            messages().webhook_rerun.replace("{machine}", machine)
        );
        error["message"] = json!(message);
    }
    (error, exit, unknown)
}

fn signed_out(reason: &str) -> Value {
    json!({
        "code": "automation.signed_out",
        "message": messages().webhook_signed_out.replace("{reason}", reason),
        "details": {},
        "retryable": false,
    })
}

/// Why there is no signed-in platform.
enum Unconnected {
    /// `--platform` (or `CMUX_PLATFORM_URL`) is not an origin a credential may go to.
    Origin(String),
    SignedOut(String),
    Client,
}

/// The platform at `flag` (or `CMUX_PLATFORM_URL`), signed in as the person: with
/// `CMUX_CLOUD_ACCESS_TOKEN`, else a token the app mints (`auth.token`), as
/// `chat_start::joined::account_rows` does.
fn signed_in(global: &GlobalArgs, flag: Option<&str>) -> Result<(Platform, String), Unconnected> {
    let origin = crate::cli::platform_origin(flag, &|key: &str| std::env::var(key).ok())
        .map_err(Unconnected::Origin)?;
    let credential = match crate::cli::joined_machine_credential(None, false) {
        Ok(Some(credential)) => credential,
        Ok(None) => {
            crate::cli::chat_start::joined::app_token(global).map_err(Unconnected::SignedOut)?
        }
        Err(reason) => return Err(Unconnected::SignedOut(reason)),
    };
    let platform =
        Platform::new(origin.clone(), credential, TIMEOUT).map_err(|_| Unconnected::Client)?;
    Ok((platform, origin))
}

/// `create NAME --webhook --on cloud …` (the words after the verb).
pub(super) fn create(args: &[String], global: &GlobalArgs, out: &Out) -> Outcome {
    let plan = plan(args)?;
    let (platform, origin) = match connect(global, plan.platform.as_deref(), out) {
        Ok(found) => found,
        Err(done) => return done,
    };
    match register(&platform, &plan) {
        Ok(done) => {
            let v = created(&plan, &origin, &done);
            match out.mode {
                OutputMode::Json | OutputMode::JsonLines => out.value(&v),
                OutputMode::Quiet => quiet_lines(&v).iter().for_each(|l| println!("{l}")),
                OutputMode::Human => human_lines(&plan, &v).iter().for_each(|l| println!("{l}")),
            }
            Ok(0)
        }
        Err(stop) => {
            let (error, exit, unknown) = stopped_error(&plan, &stop);
            Ok(out.error(&error, exit, unknown))
        }
    }
}

/// [`signed_in`], a missing sign-in answered as exit 3 and a bad `--platform` as a usage error.
fn connect(
    global: &GlobalArgs,
    flag: Option<&str>,
    out: &Out,
) -> Result<(Platform, String), Outcome> {
    match signed_in(global, flag) {
        Ok(found) => Ok(found),
        Err(Unconnected::Origin(message)) => Err(usage(message)),
        Err(Unconnected::SignedOut(reason)) => Err(Ok(out.error(&signed_out(&reason), 3, false))),
        Err(Unconnected::Client) => Err(Ok(out.error(
            &json!({"code": "internal", "message": "the HTTP client could not start", "details": {}, "retryable": false}),
            1,
            false,
        ))),
    }
}

/// A trigger id: the platform's UUID shape, so it is safe in a path.
fn trigger_id(word: &str) -> Result<&str, Failure> {
    let groups: Vec<&str> = word.split('-').collect();
    let shaped = groups.len() == 5
        && groups
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(group, len)| group.len() == len && group.bytes().all(|b| b.is_ascii_hexdigit()));
    if shaped { Ok(word) } else { usage(messages().webhook_bad_trigger.replace("{value}", word)) }
}

/// `automation webhook rm TRIGGER`: `DELETE /v1/triggers/{id}` (the fork stays; delete it with
/// `cmux cloud`).
pub(super) fn webhook(args: &[String], global: &GlobalArgs, out: &Out) -> Outcome {
    let Some((verb, rest)) = args.split_first() else {
        print!("{}", messages().webhook_usage);
        return Ok(0);
    };
    match verb.as_str() {
        "help" | "-h" | "--help" => {
            print!("{}", messages().webhook_usage);
            Ok(0)
        }
        "rm" | "delete" | "remove" => {
            let a = Args::parse(rest, &["platform"], &[])?;
            let id = trigger_id(a.one_word("TRIGGER")?)?.to_owned();
            let (platform, _) = match connect(global, a.value("platform"), out) {
                Ok(found) => found,
                Err(done) => return done,
            };
            match platform.delete(&format!("{TRIGGERS_PATH}/{id}")) {
                Ok(answer) => {
                    let removed = answer.get("removed").and_then(Value::as_bool).unwrap_or(true);
                    match out.mode {
                        OutputMode::Json | OutputMode::JsonLines => {
                            out.value(&json!({"id": id, "removed": removed}));
                        }
                        OutputMode::Quiet => {}
                        OutputMode::Human => {
                            println!("{}", messages().webhook_removed.replace("{id}", &id));
                        }
                    }
                    Ok(0)
                }
                Err(e) => {
                    let (error, exit, unknown) = call_error(Step::Remove, &e);
                    Ok(out.error(&error, exit, unknown))
                }
            }
        }
        other => usage(messages().unknown_verb.replace("{verb}", other)),
    }
}

#[cfg(test)]
#[path = "automation_webhook_tests.rs"]
mod tests;
