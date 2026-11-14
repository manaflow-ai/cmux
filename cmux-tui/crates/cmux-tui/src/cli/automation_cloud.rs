//! `cmux automation … --target cloud`: Cloud Chief jobs on cmux Cloud
//! (docs/automations-platonic-ideal.md, Cloud slice).
//!
//! The CLI holds no account token. Each verb is one `cloud.automation` call
//! to the cmux app, which forwards the op to the API Worker as the signed-in
//! user (`cmux cloud automation-relay`, rules in `cmux_cloud_wire::automation`). A Cloud automation's body
//! is `{type: "chief", chief, conversation, prompt}`: each run puts the prompt
//! in the person's default Cloud Chief's main conversation and starts a turn
//! there, with every computer of the person asleep too. The free plan has one
//! Cloud job; the next create answers `automation.plan.required` with a
//! checkout link, which the CLI prints.

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

/// The app bounds its Cloud call at 20 s; the CLI waits a little longer.
const CLOUD_TIMEOUT: Duration = Duration::from_secs(35);

/// A schedule as Cloud triggers (`cron` with an IANA zone, `webhook`, or
/// `manual` only). Every Cloud automation also gets a `manual` trigger, so
/// `run` works on it.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum CloudSchedule {
    Cron { expr: String, tz: String },
    Webhook,
    Manual,
}

impl CloudSchedule {
    pub(super) fn triggers(&self) -> Value {
        match self {
            CloudSchedule::Cron { expr, tz } => {
                json!([{"type": "cron", "expr": expr, "tz": tz}, {"type": "manual"}])
            }
            CloudSchedule::Webhook => json!([{"type": "webhook"}, {"type": "manual"}]),
            CloudSchedule::Manual => json!([{"type": "manual"}]),
        }
    }
}

/// The IANA zone of this machine (`/etc/localtime` points into a zoneinfo
/// folder), else `UTC`.
pub(super) fn local_zone_name() -> String {
    if let Ok(tz) = std::env::var("TZ")
        && tz.contains('/')
        && !tz.starts_with('/')
    {
        return tz;
    }
    std::fs::read_link("/etc/localtime")
        .ok()
        .and_then(|target| zone_from_path(&target.to_string_lossy()))
        .unwrap_or_else(|| "UTC".into())
}

/// `…/zoneinfo/America/Los_Angeles` → `America/Los_Angeles`.
pub(super) fn zone_from_path(path: &str) -> Option<String> {
    let (_, zone) = path.split_once("zoneinfo/")?;
    (!zone.is_empty()).then(|| zone.to_string())
}

/// The default Cloud Chief and its main conversation from a `chief.list`
/// value: the active default one, else the oldest active one.
pub(super) fn default_chief(list: &Value) -> Option<(String, String)> {
    let chiefs = list.get("chiefs")?.as_array()?;
    let active = |c: &&Value| c.get("archived_at").is_none_or(Value::is_null);
    let pick = chiefs
        .iter()
        .filter(active)
        .find(|c| c.get("is_default").and_then(Value::as_bool) == Some(true))
        .or_else(|| chiefs.iter().find(active))?;
    Some((
        pick.get("id")?.as_str()?.to_string(),
        pick.get("main_conversation")?.as_str()?.to_string(),
    ))
}

/// The `automation.create` params of a Cloud job.
pub(super) fn create_params(
    name: &str,
    prompt: &str,
    schedule: &CloudSchedule,
    chief: &(String, String),
    paused: bool,
) -> Value {
    json!({
        "name": name,
        "description": format!("Cloud job made with cmux automation: {}", prompt.chars().take(200).collect::<String>()),
        "enabled": !paused,
        "triggers": schedule.triggers(),
        "body": {"type": "chief", "chief": chief.0, "conversation": chief.1, "prompt": prompt},
    })
}

/// A fresh idempotency key for one mutation of this command (the global
/// `--idempotency-key` wins, so a retried command applies once).
pub(super) fn key(global: &GlobalArgs, verb: &str) -> String {
    if let Some(k) = &global.idempotency_key {
        return k.clone();
    }
    let mut bytes = [0u8; 12];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read as _;
        let _ = f.read_exact(&mut bytes);
    }
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("cli-automation-{verb}-{hex}")
}

/// What one `cloud.automation` call answered.
pub(super) enum Answer {
    /// The op's value.
    Value(Value),
    /// The owner (or the app) refused: the error object, details included.
    Refused(Value),
}

/// One `cloud.automation` call to the cmux app.
pub(super) fn call(
    global: &GlobalArgs,
    op: &str,
    params: Value,
    key: Option<String>,
) -> Result<Answer, Value> {
    let mut stream = super::app::connect_command(global)?;
    let mut request = Map::new();
    request.insert("op".into(), json!(op));
    request.insert("params".into(), params);
    if let Some(k) = key {
        request.insert("idempotency_key".into(), json!(k));
    }
    match super::app::request(
        &mut stream,
        "cloud.automation",
        Value::Object(request),
        CLOUD_TIMEOUT,
    ) {
        Ok(Ok(reply)) => Ok(match reply.get("ok").and_then(Value::as_bool) {
            Some(true) => Answer::Value(reply.get("value").cloned().unwrap_or(Value::Null)),
            _ => Answer::Refused(
                reply.get("error").cloned().unwrap_or_else(|| json!({"code": "owner.bad_reply"})),
            ),
        }),
        Ok(Err(error)) => Err(error),
        Err(message) => Err(json!({"code": "app.transport", "message": message})),
    }
}

/// The exit code of a refusal: 4 for a plan refusal (a person can act on
/// it), 3 signed out, 5 an app without the method, 1 else.
pub(super) fn refusal_exit(error: &Value) -> i32 {
    match error.get("code").and_then(Value::as_str).unwrap_or("error") {
        "automation.plan.required" => 4,
        "automation.signed_out" | "not_signed_in" => 3,
        "method_not_found" => 5,
        _ => 1,
    }
}

/// Prints a refusal: the checkout link of a plan refusal on its own line.
/// Exit as [`refusal_exit`].
pub(super) fn print_refusal(error: &Value, output: OutputMode) -> i32 {
    let code = error.get("code").and_then(Value::as_str).unwrap_or("error");
    let exit = refusal_exit(error);
    if output == OutputMode::Json {
        println!("{}", json!({"ok": false, "error": error}));
        return exit;
    }
    let message = error.get("message").and_then(Value::as_str).unwrap_or("");
    eprintln!("cmux: {code}: {message}");
    if let Some(link) = error.get("details").and_then(|d| d.get("checkout")).and_then(Value::as_str)
    {
        eprintln!("{link}");
    }
    exit
}

#[cfg(test)]
mod tests;
