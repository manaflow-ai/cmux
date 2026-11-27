//! The Chief's engine settings: the pickers and their "Default" titles (`HomeChiefEngineTitles.swift`),
//! the errors the card says (`HomeChiefEngineError.swift`), a hosted cloud Chief's brain route
//! (`HomeChiefHostedEngine.swift`), each Chief's harness (`HomeChiefHarnesses.swift`), recent picks
//! (`HomeChiefModelRecents.swift`) and the snapshot read from the Chief's files (`HomeChiefFiles.swift`).
//! The file reads and network calls stay in Swift; these take what they read.

use super::model_menu::{self, Model, display_name_of, readable, release_of};
use super::names::{Pick, backend_title, harness_items};
use super::{Strings, format, strings};
use crate::ops::{self, OpError};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// The engine fields (`ChiefEngineReport.Engine`); nil is the brain's default. The classifier fields
/// keep the brain's snake_case names, and `reactions_can_wake` reads a bool or the string a set sent.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Engine {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub classifier_harness: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub classifier_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub classifier_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", deserialize_with = "bool_or_text")]
    pub reactions_can_wake: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub computer: Option<String>,
}

fn bool_or_text<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<bool>, D::Error> {
    Ok(match Value::deserialize(deserializer)? {
        Value::Bool(on) => Some(on),
        Value::String(text) => match text.as_str() {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        },
        _ => None,
    })
}

/// What the brain offers (`ChiefEngineReport.Offered`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Offered {
    pub models: Vec<Model>,
    pub efforts: Vec<String>,
    pub speeds: Vec<String>,
}

/// The brain's `chief.engine.get` report (the fields the snapshot reads).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Report {
    pub engine: Engine,
    pub choice: Engine,
    pub offered: Offered,
}

/// What the Chief settings show (`HomeChiefSnapshot`, without the trace's turns, which stay in Swift).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Snapshot {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar: Option<String>,
    pub route_configured: bool,
    pub models: Vec<Model>,
    pub efforts: Vec<String>,
    pub speeds: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effective: Option<Engine>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub classifier_harness: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub classifier_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub classifier_prompt: Option<String>,
    /// "true" or "false".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reactions_can_wake: Option<String>,
    pub brain_off: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub computer: Option<String>,
}

// MARK: Titles

/// The pickers' items and their "Default" titles for one snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Titles {
    pub harnesses: Vec<Pick>,
    /// Every model row's value and title, in the menu's order, once each.
    pub models: Vec<Pick>,
    pub menu: model_menu::Menu,
    pub efforts: Vec<Pick>,
    pub default_harness: String,
    pub default_model: String,
    pub default_effort: String,
    pub offers_fast: bool,
}

/// "Default (value)", or "Default" when the brain did not say (or says "default").
pub fn default_titled(value: Option<&str>, strings: &Strings) -> String {
    match value {
        Some(value) if !value.is_empty() && value != "default" => {
            format(&strings.default_named_format, &[value])
        }
        _ => strings.default_value.clone(),
    }
}

/// The titles for `snapshot`, this harness's recent picks and this Mac's other harnesses.
pub fn titles(
    snapshot: &Snapshot,
    recents: &[String],
    listed: &[String],
    strings: &Strings,
) -> Titles {
    let harnesses = harness_items(snapshot.route_configured, listed, strings);
    let menu = model_menu::menu(&snapshot.models, snapshot.model.as_deref(), recents, strings);
    let mut seen: Vec<&str> = Vec::new();
    let mut models = Vec::new();
    for item in &menu.items {
        if !seen.contains(&item.value.as_str()) {
            seen.push(&item.value);
            models.push(Pick { value: item.value.clone(), title: item.title.clone() });
        }
    }
    let engine = snapshot.effective.as_ref();
    let default_runs: Option<String> =
        engine.and_then(|engine| engine.model.clone()).or_else(|| {
            snapshot
                .models
                .iter()
                .find(|model| model.id == "default")
                .and_then(|model| model.resolved_model.clone())
        });
    let running = snapshot
        .model
        .clone()
        .or_else(|| default_runs.clone())
        .and_then(|id| release_of(&id, &snapshot.models));
    let takes: Option<Vec<String>> =
        running.and_then(|running| running.efforts.clone()).map(|levels| {
            if snapshot.efforts.is_empty() {
                levels
            } else {
                levels.into_iter().filter(|level| snapshot.efforts.contains(level)).collect()
            }
        });
    let levels =
        takes.filter(|levels| !levels.is_empty()).unwrap_or_else(|| snapshot.efforts.clone());
    let efforts = levels
        .into_iter()
        .map(|level| Pick { title: strings.effort_title(&level), value: level })
        .collect();
    let offers_fast = snapshot.speeds.iter().any(|speed| speed == "fast")
        && (running.and_then(|running| running.fast) != Some(false)
            || snapshot.speed.as_deref() == Some("fast"));
    let harness_default = if snapshot.harness.is_none() {
        engine.and_then(|engine| engine.harness.clone())
    } else {
        None
    }
    .map(|harness| if harness == "default" { harness } else { backend_title(&harness, strings) });
    let model_default = if snapshot.model.is_none() {
        default_runs
            .as_deref()
            .and_then(|id| release_of(id, &snapshot.models))
            .map(|row| row.short_name.clone().unwrap_or_else(|| readable(row)))
            .or_else(|| {
                default_runs.as_ref().map(|id| {
                    if id == "default" {
                        id.clone()
                    } else {
                        display_name_of(id, &snapshot.models, strings)
                    }
                })
            })
    } else {
        None
    };
    let level_default = engine
        .and_then(|engine| engine.effort.clone())
        .or_else(|| running.and_then(|running| running.default_effort.clone()));
    let effort_default = if snapshot.effort.is_none() { level_default } else { None }
        .map(|level| strings.effort_title(&level));
    Titles {
        harnesses,
        models,
        menu,
        efforts,
        default_harness: default_titled(harness_default.as_deref(), strings),
        default_model: default_titled(model_default.as_deref(), strings),
        default_effort: default_titled(effort_default.as_deref(), strings),
        offers_fast,
    }
}

// MARK: Errors

/// Why the panel could not read or set the engine (`HomeChiefEngineError`), and its text.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EngineError {
    /// `unreachable`, `localUnreachable`, `localStarting`, `forbidden`, `notConfigured`, `unsupported`,
    /// `agentsDisabled`, `refused`, `cloudUnreachable`, `signedOut`, `cloudUnavailable`,
    /// `cloudStopUnsupported` or `other`.
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

fn error_default(kind: &str) -> &'static str {
    match kind {
        "unreachable" => "The server with this Chief is not connected.",
        "localUnreachable" => "This Mac's Chief is not running.",
        "localStarting" => {
            "This Mac's Chief was not running. It is starting now; try again in a moment."
        }
        "forbidden" => "This server does not let this connection change its Chief.",
        "notConfigured" => {
            "This daemon does not reach its Chief's brain. Restart the Chief's daemon."
        }
        "unsupported" => "This server's cmux is too old to change its Chief from here.",
        "agentsDisabled" => "Agents are disabled in this build session. The Chief does not answer.",
        "cloudUnreachable" => {
            "cmux could not reach the cloud for this Chief. Check your connection and try again."
        }
        "signedOut" => "Sign in to cmux to change this Chief's settings.",
        "cloudUnavailable" => "This cloud does not run Chiefs, so this Chief does not answer.",
        "cloudStopUnsupported" => "A cloud Chief's reply cannot be stopped from here yet.",
        _ => "The change failed: %@",
    }
}

/// `error` (a `ChiefControlError` or a panel error) as the panel's error, with the text it says: a refusal
/// for `agent_launch_disabled` is Agents Disabled; a refusal or other error says its message.
pub fn engine_error(error: &EngineError, strings: &Strings) -> EngineError {
    let mut out = EngineError { kind: error.kind.clone(), ..Default::default() };
    match error.kind.as_str() {
        "refused" if error.reason.as_deref() == Some("agent_launch_disabled") => {
            out.kind = "agentsDisabled".into();
        }
        "refused" => {
            out.reason = Some(error.reason.clone().unwrap_or_default());
            out.message = Some(error.message.clone().unwrap_or_default());
        }
        "other" => {
            out.message =
                Some(error.message.clone().or_else(|| error.text.clone()).unwrap_or_default());
        }
        "unreachable"
        | "localUnreachable"
        | "localStarting"
        | "forbidden"
        | "notConfigured"
        | "unsupported"
        | "agentsDisabled"
        | "cloudUnreachable"
        | "signedOut"
        | "cloudUnavailable"
        | "cloudStopUnsupported" => {}
        _ => {
            out.kind = "other".into();
            out.message =
                Some(error.message.clone().or_else(|| error.text.clone()).unwrap_or_default());
        }
    }
    let template = strings.errors.get(&out.kind).cloned().unwrap_or_else(|| {
        if out.kind == "refused" || out.kind == "other" {
            strings
                .errors
                .get("refused")
                .cloned()
                .unwrap_or_else(|| error_default("refused").to_owned())
        } else {
            error_default(&out.kind).to_owned()
        }
    });
    out.text = Some(match out.kind.as_str() {
        "refused" | "other" => format(&template, &[out.message.as_deref().unwrap_or("")]),
        _ => template,
    });
    out
}

// MARK: Hosted brain

/// The models the hosted brain route takes (chief-brain/routes.ts).
pub const HOSTED_MODELS: &[(&str, &str)] = &[
    ("claude-opus-5-5", "Opus 5.5"),
    ("claude-sonnet-5-5", "Sonnet 5.5"),
    ("claude-haiku-5-5", "Haiku 5.5"),
];
/// The efforts the hosted brain route takes (contract.ts `Effort`).
pub const HOSTED_EFFORTS: &[&str] = &["off", "minimal", "low", "medium", "high", "xhigh", "max"];
/// The hosted brain's own defaults (contract.ts `DEFAULT_MODEL`, `DEFAULT_EFFORT`).
pub const HOSTED_DEFAULT_MODEL: &str = "claude-opus-5-5";
pub const HOSTED_DEFAULT_EFFORT: &str = "low";

fn hosted_models() -> Vec<Model> {
    HOSTED_MODELS
        .iter()
        .map(|(id, name)| Model {
            id: (*id).to_owned(),
            name: (*name).to_owned(),
            ..Default::default()
        })
        .collect()
}

/// The hosted route's offer and path for one Chief.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostedOffer {
    pub models: Vec<Model>,
    pub efforts: Vec<String>,
    pub default_model: String,
    pub default_effort: String,
    pub chooses_harness: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

pub fn hosted_offer(agent: Option<&str>) -> HostedOffer {
    HostedOffer {
        models: hosted_models(),
        efforts: HOSTED_EFFORTS.iter().map(|effort| (*effort).to_owned()).collect(),
        default_model: HOSTED_DEFAULT_MODEL.into(),
        default_effort: HOSTED_DEFAULT_EFFORT.into(),
        chooses_harness: false,
        path: agent.map(|agent| format!("v1/chiefs/{agent}/brain")),
    }
}

/// The PUT body for a set: model and effort only (a key present), null as the brain's default.
pub fn hosted_patch(fields: &Map<String, Value>) -> BTreeMap<String, String> {
    let mut patch = BTreeMap::new();
    for (key, default) in [("model", HOSTED_DEFAULT_MODEL), ("effort", HOSTED_DEFAULT_EFFORT)] {
        if let Some(value) = fields.get(key) {
            patch.insert(key.to_owned(), value.as_str().unwrap_or(default).to_owned());
        }
    }
    patch
}

/// The brain's config from one reply (GET's `value.config`, PUT's `value`), or why not.
pub fn hosted_config(status: i64, body: &Value) -> Result<Map<String, Value>, EngineError> {
    let empty = Map::new();
    let json = body.as_object().unwrap_or(&empty);
    if status == 200
        && let Some(value) = json.get("value").and_then(Value::as_object)
    {
        return Ok(value.get("config").and_then(Value::as_object).unwrap_or(value).clone());
    }
    let error = json.get("error").and_then(Value::as_object);
    let code = error.and_then(|error| error.get("code")).and_then(Value::as_str).map(str::to_owned);
    let kind = |kind: &str| EngineError { kind: kind.into(), ..Default::default() };
    Err(match status {
        401 => kind("signedOut"),
        404 => kind("cloudUnavailable"),
        0 | 200 => kind("cloudUnreachable"),
        status if status >= 500 => kind("cloudUnreachable"),
        status => EngineError {
            kind: "refused".into(),
            reason: Some(code.clone().unwrap_or_else(|| format!("http_{status}"))),
            message: Some(
                error
                    .and_then(|error| error.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or(code)
                    .unwrap_or_else(|| format!("HTTP {status}")),
            ),
            text: None,
        },
    })
}

/// What the card shows for one hosted config.
pub fn hosted_snapshot(config: &Map<String, Value>, avatar: Option<String>) -> Snapshot {
    let text = |key: &str| config.get(key).and_then(Value::as_str).map(str::to_owned);
    let (model, effort) = (text("model"), text("effort"));
    Snapshot {
        model: model.clone(),
        effort: effort.clone(),
        avatar,
        models: hosted_models(),
        efforts: HOSTED_EFFORTS.iter().map(|effort| (*effort).to_owned()).collect(),
        effective: Some(Engine { model, effort, ..Default::default() }),
        brain_off: config.get("enabled") == Some(&Value::Bool(false)),
        ..Default::default()
    }
}

// MARK: Harnesses

fn unwrap_value(listed: &Value) -> Option<&Map<String, Value>> {
    let reply = listed.as_object()?;
    Some(reply.get("value").and_then(Value::as_object).unwrap_or(reply))
}

/// Each record's `engine.harness` by Chief id, from a `chief.profile.list` result.
pub fn record_harnesses(listed: &Value) -> BTreeMap<String, String> {
    let mut harnesses = BTreeMap::new();
    let Some(chiefs) =
        unwrap_value(listed).and_then(|object| object.get("chiefs")).and_then(Value::as_array)
    else {
        return harnesses;
    };
    for record in chiefs {
        let id = record.get("id").and_then(Value::as_str);
        let harness =
            record.get("engine").and_then(|engine| engine.get("harness")).and_then(Value::as_str);
        if let (Some(id), Some(harness)) = (id, harness)
            && !harness.is_empty()
        {
            harnesses.insert(id.to_owned(), harness.to_owned());
        }
    }
    harnesses
}

/// The deleted Chiefs' ids of a `chief.profile.list` result; nil with no result or no `deleted` list.
pub fn deleted_ids(listed: &Value) -> Option<Vec<String>> {
    let ids = unwrap_value(listed)?.get("deleted")?.as_array()?;
    let mut out: Vec<String> = ids.iter().filter_map(Value::as_str).map(str::to_owned).collect();
    out.sort();
    out.dedup();
    Some(out)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Harnesses {
    pub harnesses: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deleted: Option<Vec<String>>,
}

/// Each Chief's harness: the one its brain saved in engine.json, else its record's.
pub fn harnesses(chiefs: &[String], saved: &BTreeMap<String, String>, listed: &Value) -> Harnesses {
    let records = record_harnesses(listed);
    let mut out = BTreeMap::new();
    for chief in chiefs {
        let harness =
            saved.get(chief).filter(|harness| !harness.is_empty()).or_else(|| records.get(chief));
        if let Some(harness) = harness {
            out.insert(chief.clone(), harness.clone());
        }
    }
    Harnesses { harnesses: out, deleted: deleted_ids(listed) }
}

// MARK: Recents and files

pub const RECENTS_LIMIT: usize = 5;

/// `list` with `model` first, once, kept short.
pub fn recents_remember(model: &str, list: &[String]) -> Vec<String> {
    std::iter::once(model.to_owned())
        .chain(list.iter().filter(|other| *other != model).cloned())
        .take(RECENTS_LIMIT)
        .collect()
}

/// The snapshot from engine.json and profile.json's objects (`HomeChiefFiles.snapshot`).
pub fn engine_choice(choice: &Value, profile: &Value, route_configured: bool) -> Snapshot {
    let text =
        |object: &Value, key: &str| object.get(key).and_then(Value::as_str).map(str::to_owned);
    let filled = |value: Option<String>| value.filter(|value| !value.is_empty());
    let reactions = match choice.get("reactions_can_wake") {
        Some(Value::Bool(on)) => Some(on.to_string()),
        Some(Value::String(text)) => Some(text.clone()),
        _ => None,
    };
    Snapshot {
        harness: text(choice, "harness"),
        model: text(choice, "model"),
        effort: text(choice, "effort"),
        speed: text(choice, "speed"),
        avatar: filled(text(profile, "avatar")),
        route_configured,
        classifier_harness: text(choice, "classifier_harness"),
        classifier_model: text(choice, "classifier_model"),
        classifier_prompt: text(choice, "classifier_prompt"),
        reactions_can_wake: reactions,
        computer: filled(text(choice, "computer")),
        ..Default::default()
    }
}

/// `snapshot` with `report`'s offer and effective engine (`HomeChiefSnapshot.offering`).
pub fn snapshot_offering(snapshot: &Snapshot, report: &Report) -> Snapshot {
    let mut out = snapshot.clone();
    out.models = report.offered.models.clone();
    out.efforts = report.offered.efforts.clone();
    out.speeds = report.offered.speeds.clone();
    out.effective = Some(report.engine.clone());
    let choice = &report.choice;
    if choice.classifier_harness.is_some()
        || choice.classifier_model.is_some()
        || choice.classifier_prompt.is_some()
        || choice.reactions_can_wake.is_some()
    {
        out.classifier_harness = choice.classifier_harness.clone();
        out.classifier_model = choice.classifier_model.clone();
        out.classifier_prompt = choice.classifier_prompt.clone();
        out.reactions_can_wake = choice.reactions_can_wake.map(|on| on.to_string());
    }
    out.computer = choice.computer.clone();
    out
}

/// Whether the Chief's acpmux has a CodeRouter Claude route: `ACPMUX_CODEROUTER_CLAUDE_ROUTE` when the
/// environment has it, else the config's `coderouterClaudeRoute`. Blank values do not count.
pub fn route_configured(environment: Option<&str>, config: &Value) -> bool {
    let configured =
        |value: Option<&str>| !value.unwrap_or("").trim_matches([' ', '\t']).is_empty();
    match environment {
        Some(value) => configured(Some(value)),
        None => configured(config.get("coderouterClaudeRoute").and_then(Value::as_str)),
    }
}

// MARK: Ops

#[derive(Deserialize, Default)]
#[serde(default)]
struct TitlesRequest {
    snapshot: Snapshot,
    recents: Vec<String>,
    listed: Vec<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct ValueRequest {
    value: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct ErrorRequest {
    error: EngineError,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct AgentRequest {
    agent: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct PatchRequest {
    fields: Map<String, Value>,
}

#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct ConfigRequest {
    status: i64,
    body: Option<Value>,
    body_text: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct HostedSnapshotRequest {
    config: Map<String, Value>,
    avatar: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct HarnessesRequest {
    chiefs: Vec<String>,
    saved: BTreeMap<String, String>,
    listed: Value,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct RecentsRequest {
    model: String,
    list: Vec<String>,
}

#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct ChoiceRequest {
    choice: Value,
    profile: Value,
    route_configured: bool,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct OfferingRequest {
    snapshot: Snapshot,
    report: Report,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct RouteRequest {
    environment: Option<String>,
    config: Value,
}

fn object(request: &Value) -> Value {
    if request.is_null() { Value::Object(Map::new()) } else { request.clone() }
}

pub(super) fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    let words = strings(request);
    let request = &object(request);
    match name {
        "engineTitles" => {
            let request: TitlesRequest = ops::parse(request)?;
            ops::reply(&titles(&request.snapshot, &request.recents, &request.listed, &words))
        }
        "defaultTitled" => ops::reply(&default_titled(
            ops::parse::<ValueRequest>(request)?.value.as_deref(),
            &words,
        )),
        "engineError" => {
            ops::reply(&engine_error(&ops::parse::<ErrorRequest>(request)?.error, &words))
        }
        "hostedOffer" => {
            ops::reply(&hosted_offer(ops::parse::<AgentRequest>(request)?.agent.as_deref()))
        }
        "hostedPatch" => ops::reply(&hosted_patch(&ops::parse::<PatchRequest>(request)?.fields)),
        "hostedConfig" => {
            let request: ConfigRequest = ops::parse(request)?;
            let body = request
                .body
                .or_else(|| request.body_text.and_then(|text| serde_json::from_str(&text).ok()))
                .unwrap_or(Value::Null);
            match hosted_config(request.status, &body) {
                Ok(config) => ops::reply(&serde_json::json!({ "config": config })),
                Err(error) => {
                    ops::reply(&serde_json::json!({ "error": engine_error(&error, &words) }))
                }
            }
        }
        "hostedSnapshot" => {
            let request: HostedSnapshotRequest = ops::parse(request)?;
            ops::reply(&hosted_snapshot(&request.config, request.avatar))
        }
        "harnesses" => {
            let request: HarnessesRequest = ops::parse(request)?;
            ops::reply(&harnesses(&request.chiefs, &request.saved, &request.listed))
        }
        "recentsRemember" => {
            let request: RecentsRequest = ops::parse(request)?;
            ops::reply(&recents_remember(&request.model, &request.list))
        }
        "engineChoice" => {
            let request: ChoiceRequest = ops::parse(request)?;
            ops::reply(&engine_choice(&request.choice, &request.profile, request.route_configured))
        }
        "snapshotOffering" => {
            let request: OfferingRequest = ops::parse(request)?;
            ops::reply(&snapshot_offering(&request.snapshot, &request.report))
        }
        "routeConfigured" => {
            let request: RouteRequest = ops::parse(request)?;
            ops::reply(&route_configured(request.environment.as_deref(), &request.config))
        }
        _ => Err(OpError::Unknown),
    }
}
