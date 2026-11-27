//! The names a person reads for the ids a Chief's engine reports (Leo 2026-10-21, #89: the Chief
//! settings showed `claude-sr2-pipe` and `claude-opus-5-5`), and the official engines
//! (`ChiefNames.swift`, `ChiefBackend.swift`, `HomeChiefSettingsView.harnesses`).

use super::{Strings, strings, trim};
use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One official engine a Chief runs on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Backend {
    /// The acpmux harness id.
    pub id: String,
    /// The name the app shows for it.
    pub title: String,
    /// One line under a picker that has it chosen.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
    /// New Chief makes a Chief of this Mac's owner (true) or the account's cloud Chief (false).
    pub creates_on_this_mac: bool,
    /// The engine a Chief runs on when nothing else is chosen (Claude).
    pub is_default: bool,
}

/// The official engines' ids, in the order the pickers offer them, and whether New Chief makes them
/// on this Mac.
pub const OFFICIAL: &[(&str, bool)] =
    &[("claude", false), ("codex", true), ("muse", true), ("unii", true)];

/// The official engine `id`'s title, or nil for an id that is no official engine.
pub fn official_title(id: &str, strings: &Strings) -> Option<String> {
    if !OFFICIAL.iter().any(|(own, _)| *own == id) {
        return None;
    }
    if let Some(title) = strings.backends.get(id) {
        return Some(title.clone());
    }
    Some(
        match id {
            "codex" => "Codex",
            "muse" => "Muse Code",
            "unii" => "UniiChat",
            _ => "Claude",
        }
        .to_owned(),
    )
}

fn official_hint(id: &str, strings: &Strings) -> Option<String> {
    if let Some(hint) = strings.hints.get(id) {
        return Some(hint.clone());
    }
    match id {
        "unii" => {
            Some("Runs on your UniiChat account. Sign in first with `cmux harness login unii`.")
        }
        "muse" => Some(
            "Runs on this Mac with your Muse sign-in (`muse login`) through the muse-acp adapter.",
        ),
        "codex" => Some("Runs on this Mac with your Codex sign-in."),
        _ => None,
    }
    .map(str::to_owned)
}

/// Every official engine, in the pickers' order.
pub fn backends(strings: &Strings) -> Vec<Backend> {
    OFFICIAL
        .iter()
        .map(|(id, creates)| Backend {
            id: (*id).to_owned(),
            title: official_title(id, strings).unwrap_or_default(),
            hint: official_hint(id, strings),
            creates_on_this_mac: *creates,
            is_default: *id == "claude",
        })
        .collect()
}

/// The name to show for harness `id`: an official engine's title, else the id made readable.
pub fn backend_title(id: &str, strings: &Strings) -> String {
    official_title(id, strings).unwrap_or_else(|| harness_name(id, strings))
}

/// The badge a Home row shows for a Chief on `harness`: nil for the default engine (no choice,
/// `default`, or a Claude route such as `claude-cr`), else the engine's name.
pub fn backend_badge(harness: Option<&str>, strings: &Strings) -> Option<String> {
    let harness = trim(harness?);
    if harness.is_empty() || harness == "default" || harness.starts_with("claude") {
        return None;
    }
    Some(backend_title(harness, strings))
}

/// The harness picker's ids: the official engines (with the CodeRouter Claude route after Claude
/// when it is configured), then this Mac's other acpmux harnesses.
pub fn harnesses(route_configured: bool, listed: &[String]) -> Vec<String> {
    let mut offered: Vec<String> = if route_configured {
        let mut ids = vec!["claude".to_owned(), "claude-cr".to_owned()];
        ids.extend(
            OFFICIAL.iter().filter(|(id, _)| *id != "claude").map(|(id, _)| (*id).to_owned()),
        );
        ids
    } else {
        OFFICIAL.iter().map(|(id, _)| (*id).to_owned()).collect()
    };
    for id in listed {
        if !id.is_empty() && !offered.contains(id) {
            offered.push(id.clone());
        }
    }
    offered
}

/// A picker item: the value a pick writes and the title it shows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pick {
    pub value: String,
    pub title: String,
}

/// The harness picker's items: each harness with the name the app shows for it.
pub fn harness_items(route_configured: bool, listed: &[String], strings: &Strings) -> Vec<Pick> {
    harnesses(route_configured, listed)
        .into_iter()
        .map(|id| Pick { title: backend_title(&id, strings), value: id })
        .collect()
}

const ROUTES: &[(&str, &str)] = &[("cr", "CodeRouter"), ("sr", "Subrouter")];
const BUILTINS: &[(&str, &str)] = &[
    ("aider", "Aider"),
    ("gemini", "Gemini CLI"),
    ("muse", "Muse Code"),
    ("opencode", "OpenCode"),
    ("pi", "Pi"),
];
const ACRONYMS: &[&str] = &["gpt", "glm", "oss", "ai", "api", "acp", "llm", "xai"];

fn lookup(table: &[(&str, &str)], key: &str) -> Option<String> {
    table.iter().find(|(own, _)| *own == key).map(|(_, name)| (*name).to_owned())
}

/// The id's words: split on dashes, underscores, slashes, colons and spaces.
fn tokens(id: &str) -> Vec<&str> {
    id.split(|c| "-_/: ".contains(c)).filter(|part| !part.is_empty()).collect()
}

/// One word as a name: a known acronym or a short code (`cr`, `sr2`) in capitals, a version (`5.1`,
/// `4o`) as it is, any other word with a capital first letter.
pub fn word(part: &str) -> String {
    let lower = part.to_lowercase();
    if ACRONYMS.contains(&lower.as_str()) {
        return lower.to_uppercase();
    }
    let Some(first) = part.chars().next() else { return lower };
    if !first.is_alphabetic() {
        return lower;
    }
    let count = part.chars().count();
    let has_digit = part.chars().any(char::is_numeric);
    if count <= 2 || (has_digit && count <= 4) {
        return lower.to_uppercase();
    }
    let mut chars = lower.chars();
    let head: String = chars.next().map(|c| c.to_uppercase().collect()).unwrap_or_default();
    head + chars.as_str()
}

/// A harness id as a name: the official engine or acpmux built-in it starts with, then the rest in
/// brackets (`claude-sr2-pipe` → "Claude (SR2 Pipe)", `gemini` → "Gemini CLI"). A blank id comes back
/// as it is.
pub fn harness_name(id: &str, strings: &Strings) -> String {
    let parts = tokens(id);
    let Some(first) = parts.first() else { return id.to_owned() };
    let lower = first.to_lowercase();
    let lead = official_title(&lower, strings)
        .or_else(|| lookup(BUILTINS, &lower))
        .unwrap_or_else(|| word(first));
    let rest: Vec<String> = parts
        .iter()
        .skip(1)
        .map(|part| lookup(ROUTES, &part.to_lowercase()).unwrap_or_else(|| word(part)))
        .collect();
    if rest.is_empty() { lead } else { format!("{lead} ({})", rest.join(" ")) }
}

/// Whether three tokens are a `YYYY-MM-DD` date: a month of 1 to 12 and a day of 1 to 31.
fn is_date(parts: [&str; 3]) -> bool {
    let mut numbers = Vec::new();
    for (part, width) in parts.iter().zip([4, 2, 2]) {
        if part.chars().count() == width && part.chars().all(|c| c.is_ascii_digit()) {
            numbers.push(part.parse::<u32>().unwrap_or(0));
        }
    }
    matches!(numbers.as_slice(), [_, month, day] if (1..=12).contains(month) && (1..=31).contains(day))
}

/// A model id as a name: words capitalized, a version's numbers joined by a dot, a trailing release
/// date (`20250929` or `2024-08-06`) dropped, a context suffix kept (`opus[1m]` → "Opus (1M)"). A blank
/// id comes back as it is.
pub fn model_name(id: &str) -> String {
    let mut base = trim(id).to_owned();
    let mut context = None;
    if base.ends_with(']')
        && let Some(open) = base.rfind('[')
    {
        context = base.get(open + 1..base.len() - 1).map(str::to_uppercase);
        base.truncate(open);
    }
    let mut parts = tokens(&base);
    let last_is_date = parts.last().is_some_and(|last| {
        let chars: Vec<char> = last.chars().collect();
        chars.len() == 8 && chars.iter().all(|c| c.is_numeric()) && {
            let cut =
                |a: usize, b: usize| chars.get(a..b).unwrap_or_default().iter().collect::<String>();
            let (year, month, day) = (cut(0, 4), cut(4, 6), cut(6, 8));
            is_date([&year, &month, &day])
        }
    });
    if last_is_date {
        parts.pop();
    } else if parts.len() > 3
        && let [.., year, month, day] = parts.as_slice()
        && is_date([*year, *month, *day])
    {
        parts.truncate(parts.len() - 3);
    }
    if parts.is_empty() {
        return id.to_owned();
    }
    let mut words: Vec<String> = Vec::new();
    let mut version: Vec<&str> = Vec::new();
    for part in parts {
        if part.chars().count() <= 2 && part.chars().all(char::is_numeric) {
            version.push(part);
        } else {
            if !version.is_empty() {
                words.push(version.join("."));
                version.clear();
            }
            words.push(word(part));
        }
    }
    if !version.is_empty() {
        words.push(version.join("."));
    }
    let name = words.join(" ");
    match context {
        Some(context) if !context.is_empty() => format!("{name} ({context})"),
        _ => name,
    }
}

#[derive(Deserialize)]
struct IdRequest {
    #[serde(default)]
    id: String,
}

#[derive(Deserialize)]
struct BadgeRequest {
    #[serde(default)]
    harness: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItemsRequest {
    #[serde(default)]
    route_configured: bool,
    #[serde(default)]
    listed: Vec<String>,
}

fn request_or_empty(request: &Value) -> Value {
    if request.is_null() { Value::Object(Default::default()) } else { request.clone() }
}

pub(super) fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    let words = strings(request);
    let request = &request_or_empty(request);
    match name {
        "harnessName" => ops::reply(&harness_name(&ops::parse::<IdRequest>(request)?.id, &words)),
        "modelName" => ops::reply(&model_name(&ops::parse::<IdRequest>(request)?.id)),
        "backends" => ops::reply(&backends(&words)),
        "backendTitle" => ops::reply(&backend_title(&ops::parse::<IdRequest>(request)?.id, &words)),
        "backendBadge" => {
            let request: BadgeRequest = ops::parse(request)?;
            ops::reply(&backend_badge(request.harness.as_deref(), &words))
        }
        "harnessItems" => {
            let request: ItemsRequest = ops::parse(request)?;
            ops::reply(&harness_items(request.route_configured, &request.listed, &words))
        }
        _ => Err(OpError::Unknown),
    }
}
