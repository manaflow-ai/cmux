//! The chat pane's Cloud start wire (the app's `AgentPaneCloudStart`, `AgentPaneHandOff` and
//! `CloudMachineSession`): the `cloud.repickChat` params check, the codes the pane refuses a start
//! with before the App's start runs, the start card's `cloudStartProgress` push, and which agents a
//! Cloud machine's daemon confirms it holds credentials for. The app reads the facts and sends the
//! answer on; the rules and their tests are here.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// `cloud.repickChat {machine?, name?}`, checked: at least one, each a non-empty printable ASCII
/// name of at most 128 bytes, and no other key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Repick {
    pub machine: Option<String>,
    pub name: Option<String>,
}

/// The page's `cloud.repickChat` params, checked; nil for anything else (a missing params is `{}`).
pub fn repick(params: &Value) -> Option<Repick> {
    let empty = Map::new();
    let params = match params {
        Value::Object(map) => map,
        Value::Null => &empty,
        _ => return None,
    };
    if params.keys().any(|key| key != "machine" && key != "name") {
        return None;
    }
    let text = |key: &str| -> Option<Option<String>> {
        let Some(value) = params.get(key) else {
            return Some(None);
        };
        let text = value.as_str()?;
        let printable = text.chars().all(|c| c.is_ascii() && !c.is_ascii_control());
        (!text.is_empty() && text.len() <= 128 && printable).then(|| Some(text.to_owned()))
    };
    let (machine, name) = (text("machine")?, text("name")?);
    (machine.is_some() || name.is_some()).then_some(Repick { machine, name })
}

/// The codes the pane refuses a start with before the App's start runs, besides `transport.*`: an
/// attachment Cloud can't take, a pane that can't start one, the send line or another hand-off still
/// out, the tab's one Sandboxed send, and a folder that may not leave this Mac. The page keeps the
/// same list (webviews cloudStartProgress.ts `REFUSED_HERE`).
pub const REFUSED_HERE: [&str; 8] = [
    "cloud_attachments",
    "unsupported",
    "unavailable_now",
    "sandbox_busy",
    "sandbox_spent",
    "cloud_folder_missing",
    "cloud_folder_home",
    "cloud_folder_secret",
];

/// A reply's error code when the pane refused the start itself (`ok` false, the code one of
/// [`REFUSED_HERE`] or `transport.*`); nil for a success or the App's own failure.
pub fn refused_here(ok: Option<bool>, code: Option<&str>) -> Option<String> {
    let code = code.filter(|_| ok == Some(false))?;
    (code.starts_with("transport.") || REFUSED_HERE.contains(&code)).then(|| code.to_owned())
}

/// A seed's or copy's progress line, as the app reads it (`SeedProgress`, camelCase).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SeedProgress {
    pub phase: String,
    pub bytes_done: Option<i64>,
    pub bytes_total: Option<i64>,
    pub objects: Option<i64>,
    pub objects_total: Option<i64>,
    pub files_done: Option<i64>,
    pub files_total: Option<i64>,
    pub fallback_code: Option<String>,
    #[serde(rename = "installURL")]
    pub install_url: Option<String>,
}

/// The clone row's fields for a seed's or copy's progress (webviews `cloudStartProgress.ts`):
/// `progress` with the counts it has (none: no `progress`), and `fallback` and `install_url` when a
/// seed copied instead.
pub fn seed_fields(progress: &SeedProgress) -> Map<String, Value> {
    let counts: Map<String, Value> = [
        ("received_bytes", progress.bytes_done),
        ("bytes_total", progress.bytes_total),
        ("objects", progress.objects),
        ("total_objects", progress.objects_total),
        ("files_done", progress.files_done),
        ("files_total", progress.files_total),
    ]
    .into_iter()
    .filter_map(|(key, value)| value.map(|value| (key.to_owned(), Value::from(value))))
    .collect();
    let mut fields = Map::new();
    if !counts.is_empty() {
        fields.insert("progress".into(), Value::Object(counts));
    }
    if let Some(code) = &progress.fallback_code {
        fields.insert("fallback".into(), Value::from(code.as_str()));
    }
    if let Some(url) = &progress.install_url {
        fields.insert("install_url".into(), Value::from(url.as_str()));
    }
    fields
}

/// One `cloudStartProgress` push's facts: the start's step and what is known so far.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Progress {
    pub key: String,
    pub step: String,
    pub folder: Option<String>,
    pub machine: Option<String>,
    pub size: Option<String>,
    pub clone_state: Option<String>,
    pub clone_phase: Option<String>,
    pub clone_started_at: Option<f64>,
    pub clone_finished_at: Option<f64>,
    pub environment_id: Option<String>,
    pub setup_state: Option<String>,
    pub setup_status: Option<String>,
    pub setup_started_at: Option<f64>,
    pub setup_finished_at: Option<f64>,
    pub setup_error: Option<String>,
    pub setup_has_script: Option<bool>,
    pub clone_progress: Option<SeedProgress>,
    pub left_on_mac: Option<i64>,
}

fn put<T: Into<Value>>(map: &mut Map<String, Value>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        map.insert(key.into(), value.into());
    }
}

/// The start card's `cloudStartProgress` push (webviews `cloudStartProgress.ts`): the step it is on
/// (`machine`, `folder`, `opening`), the folder it copies, the machine and its size once known, the
/// clone and set-up rows when they have a field, keyed by the page's send so a card for another start
/// ignores it.
pub fn progress(facts: &Progress) -> Value {
    let mut value = Map::new();
    value.insert("key".into(), Value::from(facts.key.as_str()));
    value.insert("step".into(), Value::from(facts.step.as_str()));
    put(&mut value, "folder", facts.folder.clone());
    put(&mut value, "machine", facts.machine.clone());
    put(&mut value, "size", facts.size.clone());
    let mut clone = Map::new();
    put(&mut clone, "state", facts.clone_state.clone());
    put(&mut clone, "phase", facts.clone_phase.clone());
    put(&mut clone, "startedAt", facts.clone_started_at);
    put(&mut clone, "finishedAt", facts.clone_finished_at);
    if let Some(seed) = &facts.clone_progress {
        clone.extend(seed_fields(seed));
    }
    // A first pass: the files left on this Mac, so the card says the copy is partial.
    put(&mut clone, "left_on_mac", facts.left_on_mac.filter(|left| *left > 0));
    if !clone.is_empty() {
        value.insert("clone".into(), Value::Object(clone));
    }
    put(&mut value, "environmentId", facts.environment_id.clone());
    let mut setup = Map::new();
    put(&mut setup, "state", facts.setup_state.clone());
    put(&mut setup, "status", facts.setup_status.clone());
    put(&mut setup, "startedAt", facts.setup_started_at);
    put(&mut setup, "finishedAt", facts.setup_finished_at);
    put(&mut setup, "error", facts.setup_error.clone());
    put(&mut setup, "hasScript", facts.setup_has_script);
    if !setup.is_empty() {
        value.insert("setup".into(), Value::Object(setup));
    }
    Value::Object(value)
}

/// The capability a Cloud daemon lists per agent it starts with its own endpoint credentials.
pub const ENDPOINT_HARNESS_PREFIX: &str = "agent-session-start-endpoint-harness:";

/// The agents whose credentials a Cloud machine's daemon confirms (`CloudMachineSession`): nil when
/// it does not support the credentials capability (`supported`); else each harness it lists with
/// [`ENDPOINT_HARNESS_PREFIX`], all of them for a subscription and only `gemini` and `grok` for a key.
pub fn credential_harnesses(
    supported: bool,
    capabilities: &[String],
    subscription: bool,
) -> Option<BTreeSet<String>> {
    supported.then(|| {
        capabilities
            .iter()
            .filter_map(|value| value.strip_prefix(ENDPOINT_HARNESS_PREFIX))
            .filter(|harness| subscription || matches!(*harness, "gemini" | "grok"))
            .map(str::to_owned)
            .collect()
    })
}

#[cfg(test)]
mod tests;
