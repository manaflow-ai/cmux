//! `cmux-window-rules`' tab-side rules over the JSON channel (ops
//! `tab_rules_*`): an agent tab's relaunch key, the new tab screen's
//! type-ahead edit, where a dragged tab or group lands among groups, and the
//! bookkeeping of closes that wait for pages deciding their own close (its
//! state goes out and comes back whole with each call).

use crate::ERR_INVALID;
use cmux_window_rules::tabs::agent_key::{self, AgentTabKey};
use cmux_window_rules::tabs::group_drop::{self, Entry};
use cmux_window_rules::tabs::page_closes::{Closes, Part};
use cmux_window_rules::tabs::type_ahead;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"tab_rules_")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyStore {
    #[serde(default)]
    keys: Vec<AgentTabKey>,
    key: AgentTabKey,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyRead {
    stored: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Delta {
    sent: String,
    typed: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Drop {
    #[serde(default)]
    entries: Vec<Entry>,
    start: f64,
    dragged_min_x: f64,
    #[serde(default)]
    current_group: Option<String>,
    #[serde(default)]
    hysteresis: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Begin {
    #[serde(default)]
    closes: Closes,
    #[serde(default)]
    closing: Vec<Part>,
    #[serde(default)]
    deciding: Vec<Part>,
    user_close: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Absorb {
    #[serde(default)]
    closes: Closes,
    #[serde(default)]
    parts: Vec<Part>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Finish {
    #[serde(default)]
    closes: Closes,
    id: u64,
}

fn parse<T: DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer: Value = match operation {
        b"tab_rules_agent_key_store" => {
            let ask: KeyStore = parse(request)?;
            let duplicates = agent_key::duplicate_ids(&ask.keys);
            json!({
                "storageKey": ask.key.relaunch_storage_key(&duplicates),
                "candidates": ask.key.relaunch_key_candidates(),
                "duplicateIds": duplicates,
            })
        }
        b"tab_rules_agent_key_read" => {
            json!(AgentTabKey::from_relaunch_storage_key(&parse::<KeyRead>(request)?.stored))
        }
        b"tab_rules_type_ahead_delta" => {
            let ask: Delta = parse(request)?;
            json!(type_ahead::delta(&ask.sent, &ask.typed))
        }
        b"tab_rules_group_drop_tab" => {
            let ask: Drop = parse(request)?;
            json!(group_drop::resolve_tab(
                &ask.entries,
                ask.start,
                ask.dragged_min_x,
                ask.current_group.as_deref(),
                ask.hysteresis,
            ))
        }
        b"tab_rules_group_drop_group" => {
            let ask: Drop = parse(request)?;
            let (unit_index, tab_index) =
                group_drop::resolve_group(&ask.entries, ask.start, ask.dragged_min_x);
            json!({
                "unitIndex": unit_index,
                "tabIndex": tab_index,
                "units": group_drop::units(&ask.entries),
            })
        }
        b"tab_rules_page_closes_begin" => {
            let mut ask: Begin = parse(request)?;
            let id = ask.closes.begin(&ask.closing, &ask.deciding, ask.user_close);
            json!({"closes": ask.closes, "id": id})
        }
        b"tab_rules_page_closes_absorb" => {
            let mut ask: Absorb = parse(request)?;
            let absorbed = ask.closes.absorb(&ask.parts);
            json!({"closes": ask.closes, "rest": absorbed.rest, "finished": absorbed.finished})
        }
        b"tab_rules_page_closes_finish" => {
            let mut ask: Finish = parse(request)?;
            let finished = ask.closes.finish(ask.id);
            json!({"closes": ask.closes, "finished": finished})
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
