//! The JSON ops the app calls through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops `workspace_naming_*`). Holds and namer ledgers live here by
//! the id the app gives each (`hold`, `namer`); every other op is pure.
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `workspace_naming_clean` | `{text}` | `{name}`: one line, trimmed, at most 80 characters (null: empty) |
//! | `workspace_naming_for_tab` | `{tab}` | `{name}`: a new workspace's name from its tab |
//! | `workspace_naming_for_last_tab` | `{name, title, source, revision, allows_legacy_defaults, tab_name}` or `{…, tab}` | `{name}`: the name a workspace keeps when its last tab moves out |
//! | `workspace_naming_for_group` | `{name, first_tab}` | `{name}` |
//! | `workspace_naming_is_user_named` | `{named}` | `{user_named}` |
//! | `workspace_naming_derived` | `{front}` | `{name}` |
//! | `workspace_naming_label` | `{enabled, named, front, anchor}` | `{label}`: the live sidebar label (null: the name stands) |
//! | `workspace_naming_persisted_name` | `{enabled, variant, named, front, persist}` | `{name}`: what variant B writes (null: nothing) |
//! | `workspace_naming_page_title` | `{page}` | `{title}`: a browser tab's title for its label |
//! | `workspace_naming_activity` | `{tabs}` | `{tabs, empty, prompt, params, fallback_params}`: Name from Activity's request |
//! | `workspace_naming_activity_tab` | `{tab}` | `{tab}`: one tab's facts as snippets (null: nothing to name from) |
//! | `workspace_naming_activity_name` | `{reply}` | `{name}`: the name in the model's reply (null: none) |
//! | `workspace_naming_activity_refusal` | `{has_workspace, guards_revision, has_activity, has_agents}` | `{refusal}`: `no_workspace`, `old_daemon`, `nothing_to_name_from`, `no_agents` or null |
//! | `workspace_naming_snippet` | `{text}` | `{snippet}` |
//! | `workspace_naming_defaults` | `{}` | `{variant}`: the setting's default |
//! | `workspace_naming_hold_settle` | `{hold, workspace, namer, label}` | `{name}` |
//! | `workspace_naming_hold_launcher_named` | `{hold, workspace, name, session, matches}` | `{launcher_named}` |
//! | `workspace_naming_hold_forget` | `{hold, workspace}` | `{}` |
//! | `workspace_naming_hold_drop` | `{hold}` | `{}`: the hold is gone |
//! | `workspace_naming_namer_list` | `{namer, slots}` | `{}` |
//! | `workspace_naming_namer_plan` | `{namer, slot, target, candidate}` | `{rename}`: the candidate is new |
//! | `workspace_naming_namer_begin` | `{namer, slot, submission}` | `{attempt}` (null: already live) |
//! | `workspace_naming_namer_may_send` | `{namer, slot, attempt, current}` | `{send, retry}` |
//! | `workspace_naming_namer_release` | `{namer, slot, attempt}` | `{}` |
//! | `workspace_naming_namer_drop` | `{namer}` | `{}`: the namer is gone |

use crate::activity::{self, Gate};
use crate::auto_name::{self, Front, Named, Page, Persist, Variant};
use crate::hold::Hold;
use crate::namer::{Ledger, Slot, Submission, Target};
use crate::new_name::{self, NameSource, Tab};
use crate::text::{clean, snippet};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::HashMap;

/// The ops' prefix.
pub const PREFIX: &str = "workspace_naming_";

/// Why an op failed.
#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of the table's.
    UnknownOp(String),
    /// The request is not the JSON the op takes.
    Invalid(String),
}

/// The app's holds and namer ledgers, by the id it gave each.
#[derive(Debug, Default)]
pub struct WorkspaceNaming {
    holds: HashMap<u64, Hold>,
    namers: HashMap<u64, Ledger>,
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    let request = if request.is_null() { json!({}) } else { request };
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
struct TextRequest {
    #[serde(default)]
    text: Option<String>,
}

#[derive(Deserialize)]
struct TabRequest {
    tab: Tab,
}

#[derive(Deserialize)]
struct LastTabRequest {
    #[serde(default)]
    name: String,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    source: NameSource,
    #[serde(default)]
    revision: u64,
    #[serde(default = "yes")]
    allows_legacy_defaults: bool,
    #[serde(default)]
    tab_name: Option<String>,
    #[serde(default)]
    tab: Option<Tab>,
}

#[derive(Deserialize)]
struct GroupRequest {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    first_tab: Option<Tab>,
}

#[derive(Deserialize)]
struct NamedRequest {
    #[serde(default)]
    named: Named,
}

#[derive(Deserialize)]
struct FrontRequest {
    front: Front,
}

#[derive(Deserialize)]
struct LabelRequest {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    named: Named,
    #[serde(default)]
    front: Option<Front>,
    #[serde(default)]
    anchor: Option<Front>,
}

#[derive(Deserialize)]
struct PersistRequest {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    variant: Variant,
    #[serde(default)]
    named: Named,
    #[serde(default)]
    front: Option<Front>,
    #[serde(default)]
    persist: Persist,
}

#[derive(Deserialize)]
struct PageRequest {
    #[serde(default)]
    page: Page,
}

#[derive(Deserialize)]
struct ActivityRequest {
    #[serde(default)]
    tabs: Vec<activity::Tab>,
}

#[derive(Deserialize)]
struct ReplyRequest {
    #[serde(default)]
    reply: String,
}

#[derive(Deserialize)]
struct HoldRequest {
    hold: u64,
    #[serde(default)]
    workspace: String,
    #[serde(default)]
    namer: String,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    name: String,
    #[serde(default)]
    session: String,
    #[serde(default)]
    matches: bool,
}

#[derive(Deserialize)]
struct NamerRequest {
    namer: u64,
    #[serde(default)]
    slot: Slot,
    #[serde(default)]
    slots: Vec<Slot>,
    #[serde(default)]
    target: Target,
    #[serde(default)]
    candidate: Option<Submission>,
    #[serde(default)]
    submission: Submission,
    #[serde(default)]
    attempt: u64,
    #[serde(default)]
    current: bool,
}

impl WorkspaceNaming {
    /// A namer with no holds or ledgers.
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether `op` is one of the table's.
    pub fn serves(op: &str) -> bool {
        op.starts_with(PREFIX)
    }

    /// Runs `op` on `request`.
    pub fn call(&mut self, op: &str, request: Value) -> Result<Value, OpError> {
        let name = op.strip_prefix(PREFIX).ok_or_else(|| OpError::UnknownOp(op.to_owned()))?;
        Ok(match name {
            "clean" => {
                let request: TextRequest = parse(request)?;
                json!({"name": clean(request.text.as_deref())})
            }
            "snippet" => {
                let request: TextRequest = parse(request)?;
                json!({"snippet": snippet(request.text.as_deref())})
            }
            "for_tab" => {
                let request: TabRequest = parse(request)?;
                json!({"name": new_name::for_tab(&request.tab)})
            }
            "for_last_tab" => {
                let request: LastTabRequest = parse(request)?;
                let tab_name =
                    request.tab_name.or_else(|| request.tab.as_ref().and_then(new_name::for_tab));
                json!({"name": new_name::for_last_tab(
                    &request.name,
                    request.title.as_deref(),
                    tab_name,
                    request.source,
                    request.revision,
                    request.allows_legacy_defaults,
                )})
            }
            "for_group" => {
                let request: GroupRequest = parse(request)?;
                json!({"name": new_name::for_group(request.name.as_deref(), request.first_tab.as_ref())})
            }
            "is_user_named" => {
                let request: NamedRequest = parse(request)?;
                json!({"user_named": auto_name::is_user_named(&request.named)})
            }
            "derived" => {
                let request: FrontRequest = parse(request)?;
                json!({"name": auto_name::derived(&request.front)})
            }
            "label" => {
                let request: LabelRequest = parse(request)?;
                json!({"label": auto_name::label(
                    request.enabled,
                    &request.named,
                    request.front.as_ref(),
                    request.anchor.as_ref(),
                )})
            }
            "persisted_name" => {
                let request: PersistRequest = parse(request)?;
                json!({"name": auto_name::persisted_name(
                    request.enabled,
                    request.variant,
                    &request.named,
                    request.front.as_ref(),
                    &request.persist,
                )})
            }
            "page_title" => {
                let request: PageRequest = parse(request)?;
                json!({"title": auto_name::page_title(&request.page)})
            }
            "activity" => {
                let request: ActivityRequest = parse(request)?;
                let snipped: Vec<activity::Tab> =
                    request.tabs.iter().map(activity::Tab::snipped).collect();
                let tabs = activity::tabs(&snipped);
                let prompt = activity::prompt(&tabs);
                json!({
                    "empty": tabs.is_empty(),
                    "params": activity::params(&prompt),
                    "fallback_params": activity::fallback_params(&prompt),
                    "prompt": prompt,
                    "tabs": tabs,
                })
            }
            "activity_tab" => {
                #[derive(Deserialize)]
                struct OneTab {
                    tab: activity::Tab,
                }
                let request: OneTab = parse(request)?;
                let tab = request.tab.snipped();
                json!({"tab": (!tab.is_empty()).then_some(tab)})
            }
            "activity_name" => {
                let request: ReplyRequest = parse(request)?;
                json!({"name": activity::name_from_reply(&request.reply)})
            }
            "activity_refusal" => {
                let gate: Gate = parse(request)?;
                json!({"refusal": activity::refusal(&gate)})
            }
            "defaults" => json!({"variant": Variant::default()}),
            "hold_settle" | "hold_launcher_named" | "hold_forget" | "hold_drop" => {
                let request: HoldRequest = parse(request)?;
                if name == "hold_drop" {
                    self.holds.remove(&request.hold);
                    return Ok(json!({}));
                }
                let hold = self.holds.entry(request.hold).or_default();
                match name {
                    "hold_settle" => {
                        json!({"name": hold.settle(&request.workspace, &request.namer, request.label)})
                    }
                    "hold_launcher_named" => json!({"launcher_named": hold.launcher_named(
                        &request.workspace,
                        &request.name,
                        &request.session,
                        request.matches,
                    )}),
                    _ => {
                        hold.forget(&request.workspace);
                        json!({})
                    }
                }
            }
            "namer_list" | "namer_plan" | "namer_begin" | "namer_may_send" | "namer_release"
            | "namer_drop" => {
                let request: NamerRequest = parse(request)?;
                if name == "namer_drop" {
                    self.namers.remove(&request.namer);
                    return Ok(json!({}));
                }
                let ledger = self.namers.entry(request.namer).or_default();
                match name {
                    "namer_list" => {
                        ledger.list(&request.slots);
                        json!({})
                    }
                    "namer_plan" => json!({"rename": ledger.plan(
                        &request.slot,
                        &request.target,
                        request.candidate.as_ref(),
                    )}),
                    "namer_begin" => {
                        json!({"attempt": ledger.begin(&request.slot, request.submission)})
                    }
                    "namer_may_send" => serde_json::to_value(ledger.may_send(
                        &request.slot,
                        request.attempt,
                        request.current,
                    ))
                    .map_err(|error| OpError::Invalid(error.to_string()))?,
                    _ => {
                        ledger.release(&request.slot, request.attempt);
                        json!({})
                    }
                }
            }
            _ => return Err(OpError::UnknownOp(op.to_owned())),
        })
    }
}
