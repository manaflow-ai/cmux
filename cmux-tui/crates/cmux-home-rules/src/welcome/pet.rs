//! The Chief pet: each non-default Chief's own character (`ChiefMascotPicks`) and the notice the pet
//! shows for a daemon notification (`ChiefPetNotice+Daemon`).
//!
//! The character list, default and settings path are generated into Swift at build time
//! (`HomeChiefPetSetting`), so Swift passes them in.

use super::text::format;
use crate::ops::{OpError, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

pub const PICKS_KEY: &str = "home.chief.mascots";
pub const FINISHED_FORMAT: &str = "%@ finished";
pub const NEEDS_YOU_FORMAT: &str = "%@ needs your input";
pub const FAILED_FORMAT: &str = "%@ failed";

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Mascots {
    pub values: Vec<String>,
    pub default: String,
    /// Dotted keys into the settings file (`HomeChiefPetSetting.mascotPath`).
    pub path: Vec<String>,
}

fn is_default(chief: Option<&str>, default_chief: &str) -> bool {
    chief.is_none_or(|c| c == default_chief)
}

/// `ChiefMascotPicks.init`: string values that name a character; anything else is dropped alone.
pub fn load(stored: Option<&Value>, mascots: &Mascots) -> BTreeMap<String, String> {
    let Some(Value::Object(map)) = stored else { return BTreeMap::new() };
    map.iter()
        .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
        .filter(|(_, v)| mascots.values.contains(v))
        .collect()
}

fn value_at<'a>(file: &'a Value, path: &[String]) -> Option<&'a Value> {
    path.iter().try_fold(file, |node, key| node.as_object()?.get(key))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PicksRequest {
    #[serde(default)]
    chief: Option<String>,
    default_chief: String,
    #[serde(default)]
    picks: BTreeMap<String, String>,
    #[serde(default)]
    mascots: Mascots,
    /// The settings snapshot's `homeChiefPetMascot` (for `mascot`).
    #[serde(default)]
    snapshot_mascot: Option<String>,
    /// The settings file as JSON (for `mascotPicked`).
    #[serde(default)]
    file: Option<Value>,
    /// The character to remember (for `mascotRemember`).
    #[serde(default)]
    mascot: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoadRequest {
    #[serde(default)]
    stored: Option<Value>,
    #[serde(default)]
    mascots: Mascots,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Level {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    NeedsYou,
    Failed,
    Done,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReplyKind {
    Type,
    OpenTab,
    OpenChat,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NoticeRequest {
    pub level: Option<Level>,
    pub title: String,
    pub subtitle: Option<String>,
    pub source: Option<String>,
    pub reply: bool,
    /// The tab's display title.
    pub tab_title: String,
    /// The tab is a terminal (`.pty`).
    pub tab_is_pty: bool,
    pub tab_has_agent_session: bool,
    pub name: Option<String>,
    pub workspace: Option<String>,
    pub program_title: Option<String>,
    pub body: String,
    /// Localized title templates; English by default.
    pub finished_format: Option<String>,
    pub needs_you_format: Option<String>,
    pub failed_format: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Notice {
    pub title: String,
    pub detail: String,
    pub kind: Kind,
    pub reply: ReplyKind,
}

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `ChiefPetNotice.init(_:tab:name:workspace:programTitle:body:)`.
pub fn notice(req: &NoticeRequest) -> Notice {
    // `split(whereSeparator: \.isNewline)` skips empty pieces: the first line with text.
    let line = req.body.split(is_newline).find(|s| !s.is_empty()).unwrap_or("");
    let kind = match req.level.unwrap_or(Level::Info) {
        Level::Warning => Kind::NeedsYou,
        Level::Error => Kind::Failed,
        Level::Info => Kind::Done,
    };
    let subtitle = req.subtitle.as_deref().filter(|s| !s.is_empty()).unwrap_or("");
    let text = if line.is_empty() { subtitle } else { line };
    let shown = req.name.as_deref().unwrap_or(&req.tab_title);
    let name = if shown.is_empty() { req.workspace.as_deref().unwrap_or("") } else { shown };
    let from_agent = req.source.as_deref() == Some("agent");
    let happened = if name.is_empty() || (kind == Kind::Done && !from_agent) {
        name.to_string()
    } else {
        let template = match kind {
            Kind::Done => req.finished_format.as_deref().unwrap_or(FINISHED_FORMAT),
            Kind::NeedsYou => req.needs_you_format.as_deref().unwrap_or(NEEDS_YOU_FORMAT),
            Kind::Failed => req.failed_format.as_deref().unwrap_or(FAILED_FORMAT),
        };
        format(template, &[name])
    };
    let title = match &req.program_title {
        Some(t) => t.clone(),
        None if req.title.is_empty() => happened,
        None => req.title.clone(),
    };
    let detail = [req.workspace.as_deref().unwrap_or(""), text]
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" · ");
    let reply = if req.tab_is_pty {
        if req.reply || from_agent { ReplyKind::Type } else { ReplyKind::OpenTab }
    } else if req.tab_has_agent_session {
        ReplyKind::OpenChat
    } else {
        ReplyKind::OpenTab
    };
    Notice { title, detail, kind, reply }
}

pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "mascotPicksLoad" => {
            let req: LoadRequest = parse(request)?;
            reply(&json!({"key": PICKS_KEY, "picks": load(req.stored.as_ref(), &req.mascots)}))
        }
        "mascot" => {
            let req: PicksRequest = parse(request)?;
            let chief = req.chief.as_deref();
            let mascot = if is_default(chief, &req.default_chief) {
                req.snapshot_mascot.unwrap_or(req.mascots.default)
            } else {
                chief.and_then(|c| req.picks.get(c).cloned()).unwrap_or(req.mascots.default)
            };
            reply(&json!({"mascot": mascot}))
        }
        "mascotPicked" => {
            let req: PicksRequest = parse(request)?;
            let chief = req.chief.as_deref();
            let picked = if is_default(chief, &req.default_chief) {
                req.file
                    .as_ref()
                    .and_then(|f| value_at(f, &req.mascots.path))
                    .and_then(Value::as_str)
                    .filter(|s| req.mascots.values.iter().any(|v| v == s))
                    .map(str::to_string)
            } else {
                chief.and_then(|c| req.picks.get(c).cloned())
            };
            reply(&json!({"picked": picked}))
        }
        "mascotRemember" => {
            let req: PicksRequest = parse(request)?;
            let chief = req.chief.as_deref();
            let mascot = req.mascot.unwrap_or_default();
            let mut picks = req.picks;
            let changed = match chief {
                Some(c)
                    if !is_default(chief, &req.default_chief)
                        && req.mascots.values.contains(&mascot)
                        && picks.get(c) != Some(&mascot) =>
                {
                    picks.insert(c.to_string(), mascot);
                    true
                }
                _ => false,
            };
            let stored: Map<String, Value> =
                picks.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect();
            reply(&json!({
                "picks": picks,
                "write": changed.then(|| json!({"key": PICKS_KEY, "value": stored})),
            }))
        }
        "petNotice" => {
            let req: NoticeRequest = parse(request)?;
            reply(&notice(&req))
        }
        _ => Err(OpError::Unknown),
    }
}
