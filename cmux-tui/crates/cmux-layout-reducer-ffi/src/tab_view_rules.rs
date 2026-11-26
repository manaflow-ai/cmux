//! `cmux-window-rules`' tab strip view rules over the JSON channel (ops
//! `tab_view_rules_*`): a tab's hover card rows, what an inline rename
//! commits, where each tab sits in a layout, and the strip's sync hold (its
//! state goes out and comes back whole with each call).

use crate::ERR_INVALID;
use cmux_window_rules::tabs::hover_card::{self, Item, Sample};
use cmux_window_rules::tabs::strip_state::{self, Slot, StripFacts, SyncHold};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"tab_view_rules_")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HoverCard {
    item: Item,
    #[serde(default)]
    report: Option<Vec<Sample>>,
    now: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Rename {
    #[serde(default)]
    title: Option<String>,
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Slots {
    #[serde(default)]
    slots: Vec<Slot>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Holds {
    #[serde(default)]
    hold: SyncHold,
    strip: StripFacts,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TakeOwed {
    #[serde(default)]
    hold: SyncHold,
}

fn parse<T: DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer: Value = match operation {
        b"tab_view_rules_hover_card" => {
            let ask: HoverCard = parse(request)?;
            json!(hover_card::make(&ask.item, ask.report.as_deref(), ask.now))
        }
        b"tab_view_rules_rename_commit" => {
            let ask: Rename = parse(request)?;
            json!(strip_state::rename_commit(ask.title.as_deref(), &ask.text))
        }
        b"tab_view_rules_slot_index" => {
            json!(strip_state::slot_index(&parse::<Slots>(request)?.slots))
        }
        b"tab_view_rules_sync_holds" => {
            let mut ask: Holds = parse(request)?;
            let holds = ask.hold.holds(&ask.strip);
            json!({"hold": ask.hold, "holds": holds})
        }
        b"tab_view_rules_sync_take_owed" => {
            let mut ask: TakeOwed = parse(request)?;
            let owed = ask.hold.take_owed_sync();
            json!({"hold": ask.hold, "owed": owed})
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
