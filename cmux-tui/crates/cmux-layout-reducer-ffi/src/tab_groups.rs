//! `cmux-window-rules`' tab group rules over the JSON channel (ops `tab_groups_*`): a strip's
//! display order (`normalized`), its chips (`layout`), the selection leaving a collapsing group
//! (`selection_after_collapsing`, `selection_before_collapsing`) and the strip's local reducer
//! (`apply`).

use crate::ERR_INVALID;
use cmux_window_rules::tabs::groups::{self, Group, Intent, Strip, Tab};
use serde::Deserialize;
use std::collections::{BTreeSet, HashSet};

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"tab_groups_")
}

#[derive(Deserialize)]
struct Normalized {
    tabs: Vec<Tab>,
    #[serde(default)]
    groups: HashSet<String>,
}

#[derive(Deserialize)]
struct Layout {
    tabs: Vec<Tab>,
    #[serde(default)]
    groups: Vec<Group>,
    #[serde(default)]
    selected: Option<String>,
}

#[derive(Deserialize)]
struct Collapsing {
    group: String,
    tabs: Vec<Tab>,
    #[serde(default)]
    collapsed: BTreeSet<String>,
    #[serde(default)]
    selected: Option<String>,
}

#[derive(Deserialize)]
struct Apply {
    strip: Strip,
    intent: Intent,
}

fn parse<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let reply = match operation {
        b"tab_groups_normalized" => {
            let request: Normalized = parse(request)?;
            serde_json::to_value(groups::normalized(&request.tabs, &request.groups))
        }
        b"tab_groups_layout" => {
            let request: Layout = parse(request)?;
            serde_json::to_value(groups::layout_items(
                &request.tabs,
                &request.groups,
                request.selected.as_deref(),
            ))
        }
        b"tab_groups_selection_after_collapsing" | b"tab_groups_selection_before_collapsing" => {
            let request: Collapsing = parse(request)?;
            let rule = if operation == b"tab_groups_selection_after_collapsing" {
                groups::selection_after_collapsing
            } else {
                groups::selection_before_collapsing
            };
            let selected = rule(
                &request.group,
                &request.tabs,
                &request.collapsed,
                request.selected.as_deref(),
            );
            Ok(serde_json::json!({ "selected": selected }))
        }
        b"tab_groups_apply" => {
            let request: Apply = parse(request)?;
            serde_json::to_value(request.strip.apply(&request.intent))
        }
        _ => return Err(ERR_INVALID),
    }
    .map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
