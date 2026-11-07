//! Moving an automation between stores (docs/automations-teleport-teams.md,
//! section 2): the destination grammar and the spec a destination imports.
//!
//! The store side (fence, release, import) is in [`crate::Store`]; this file
//! is the pure part, so both the CLI and the tests use one parser.

use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::automation::{Automation, AutomationSpec, Body, Handoff};
use crate::catch_up::CatchUp;
use crate::clock::Zone;
use crate::trigger::Trigger;

/// Where an automation can move.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Destination {
    /// cmux Cloud.
    Cloud,
    /// This Mac (the Mac the person runs the command on).
    Home,
    /// Another machine over ssh; `dir` is where its runs start.
    Ssh { host: String, dir: Option<String> },
    /// A folder on this machine (the Chief teleport's form; automations refuse it).
    Local { dir: String },
}

impl fmt::Display for Destination {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Destination::Cloud => f.write_str("cloud"),
            Destination::Home => f.write_str("home"),
            Destination::Ssh { host, dir: None } => write!(f, "ssh:{host}"),
            Destination::Ssh { host, dir: Some(dir) } => write!(f, "ssh:{host}:{dir}"),
            Destination::Local { dir } => write!(f, "local:{dir}"),
        }
    }
}

const DESTINATION_RULE: &str = "--to takes \"cloud\", \"home\", \"ssh:<host>[:<dir>]\" or \"local:<absolute dir>\": at most 256 characters, no control characters";

/// Parses a destination the way the Chief teleport checks one
/// (`destinationError` in `brain-teleport.ts`), plus `cloud`.
pub fn parse_destination(text: &str) -> Result<Destination, String> {
    let bad = || Err(DESTINATION_RULE.to_string());
    if text.chars().count() > 256 || text.chars().any(|c| (c as u32) < 0x20 || c as u32 == 0x7f) {
        return bad();
    }
    match text {
        "cloud" => return Ok(Destination::Cloud),
        "home" => return Ok(Destination::Home),
        _ => {}
    }
    if let Some(dir) = text.strip_prefix("local:") {
        return if dir.starts_with('/') {
            Ok(Destination::Local { dir: dir.to_string() })
        } else {
            bad()
        };
    }
    let Some(rest) = text.strip_prefix("ssh:") else { return bad() };
    let (host, dir) = match rest.split_once(':') {
        Some((host, dir)) => (host, Some(dir)),
        None => (rest, None),
    };
    let host_ok = host.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
        && host.bytes().all(|b| b.is_ascii_alphanumeric() || b"._@-".contains(&b));
    if !host_ok || dir.is_some_and(str::is_empty) {
        return bad();
    }
    Ok(Destination::Ssh { host: host.to_string(), dir: dir.map(str::to_string) })
}

/// The handoff an import carries (`automation.import`'s `handoff`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportHandoff {
    /// The handoff id; the import's idempotency key.
    pub id: String,
    /// The source's home (`cloud`, `mac:<machine id>`).
    pub from: String,
    /// The automation's id at the source.
    pub source_id: String,
    /// The epoch the imported copy gets.
    pub epoch: u64,
    /// The newest scheduled time the source fired, in milliseconds.
    pub last_slot: Option<i64>,
}

fn yes() -> bool {
    true
}

/// An automation as another store sends it: the `automation.import` params,
/// also what `cmux automation import --json -` reads.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ImportSpec {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default = "yes")]
    pub enabled: bool,
    /// Cloud triggers (`{type: cron, expr, tz}`, `{type: manual}`, also
    /// wrapped as `{spec: …}`) or this machine's (`every`, `at`).
    pub triggers: Vec<Value>,
    /// `{type: prompt|command|chief, …}`.
    pub body: Value,
    /// `latest`, `all` or `none`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catch_up: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sharing: Option<String>,
    pub handoff: ImportHandoff,
}

/// A trigger with `tz: local` named by its zone, so another machine reads it.
fn named_zone(trigger: &Trigger, local_zone: &str) -> Value {
    match trigger {
        Trigger::Cron { expr, tz } if Zone::parse(tz) == Ok(Zone::Local) => {
            json!({"type": "cron", "expr": expr, "tz": local_zone})
        }
        other => serde_json::to_value(other).unwrap_or(Value::Null),
    }
}

/// The spec another machine imports for `a`, fenced by `handoff`.
/// `local_zone` is this machine's IANA zone, which a `local` cron names.
pub fn export_spec(a: &Automation, handoff: &Handoff, local_zone: &str) -> ImportSpec {
    ImportSpec {
        name: a.name.clone(),
        description: None,
        enabled: a.enabled,
        triggers: vec![named_zone(&a.trigger, local_zone)],
        body: serde_json::to_value(&a.body).unwrap_or(Value::Null),
        catch_up: Some(a.catch_up.name().to_string()),
        timeout_seconds: Some(a.timeout_seconds),
        sharing: None,
        handoff: ImportHandoff {
            id: handoff.id.clone(),
            from: a.home.clone(),
            source_id: a.id.clone(),
            epoch: handoff.epoch,
            last_slot: a.last_slot,
        },
    }
}

fn text(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

impl ImportSpec {
    /// This machine's spec for it. A cron in `local_zone` (this machine's IANA
    /// zone) becomes `local`; another named zone, a webhook, or two schedules
    /// are refused. `folder` (from `ssh:HOST:DIR`) replaces the body's folder.
    pub fn to_spec(
        &self,
        local_zone: &str,
        folder: Option<&str>,
    ) -> Result<AutomationSpec, String> {
        let mut schedules = Vec::new();
        for raw in &self.triggers {
            let t = raw.get("spec").unwrap_or(raw);
            match t.get("type").and_then(Value::as_str) {
                Some("manual") => {}
                Some("webhook") => {
                    return Err("a webhook trigger runs on cmux Cloud only".into());
                }
                Some("cron") => {
                    let expr = text(t, "expr").ok_or("a cron trigger needs expr")?;
                    let tz = text(t, "tz").unwrap_or_else(|| "UTC".into());
                    let tz = match Zone::parse(&tz) {
                        Ok(zone) => zone.name().to_string(),
                        Err(_) if tz == local_zone => "local".to_string(),
                        Err(why) => return Err(why),
                    };
                    schedules.push(Trigger::Cron { expr, tz });
                }
                _ => schedules.push(
                    serde_json::from_value::<Trigger>(t.clone())
                        .map_err(|e| format!("trigger {t}: {e}"))?,
                ),
            }
        }
        let trigger = match schedules.len() {
            0 => Trigger::Manual,
            1 => schedules.remove(0),
            _ => return Err("an automation on this machine has one schedule".into()),
        };
        trigger.validate().map_err(|e| e.0)?;
        let body = &self.body;
        let folder = folder.map(str::to_string).or_else(|| text(body, "folder"));
        let body = match body.get("type").and_then(Value::as_str) {
            Some("prompt" | "chief") => Body::Prompt {
                prompt: text(body, "prompt").ok_or("the body has no prompt")?,
                folder,
                model: text(body, "model"),
            },
            Some("command") => Body::Command {
                command: text(body, "command").ok_or("the body has no command")?,
                folder,
            },
            other => {
                return Err(format!(
                    "a {} body does not run on this machine",
                    other.unwrap_or("missing")
                ));
            }
        };
        let catch_up = match self.catch_up.as_deref() {
            None => CatchUp::default(),
            Some(name) => CatchUp::from_name(name)
                .ok_or_else(|| format!("catch_up takes latest, all or none, not \"{name}\""))?,
        };
        Ok(AutomationSpec {
            name: self.name.clone(),
            trigger,
            body,
            catch_up,
            timeout_seconds: self.timeout_seconds.unwrap_or(30 * 60),
            enabled: self.enabled,
        })
    }
}

/// What an import made, or found already made by the same handoff.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Imported {
    pub automation: Automation,
    /// The handoff was imported before; nothing new was written.
    pub replayed: bool,
}
