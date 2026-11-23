//! Status items (`cmux.status/1`): a small live scene an installed extension draws in the
//! window's titlebar or in cmux's menu bar menu. The daemon answers which items show and where
//! (`apps.status.list`); the Mac only mounts and draws what this returns, so with no installed,
//! enabled and visible app that implements the interface nothing shows.
//!
//! Each call reads the live catalog, so a save of an installed local app's manifest changes the
//! next answer: the local reload (`local_reload.rs`) swaps the catalog and broadcasts
//! `apps-changed`, on which the Mac lists again. None in safe mode (every extension is off).

use serde::Serialize;
use serde_json::{Value, json};

use super::store::text;
use super::supervisor::Supervisor;

pub(super) const INTERFACE: &str = "cmux.status/1";

/// Where an item shows when its manifest names no placement.
const DEFAULT_PLACEMENT: &str = "titlebar";
/// The placements the interface allows (`interfaces/cmux.status/1.json`).
const PLACEMENTS: [&str; 4] = ["titlebar", "roomBar", "statusStrip", "menuBar"];
/// The most items `apps.status.list` answers, over every app.
const MAX_ITEMS: usize = 32;

#[derive(Debug, Serialize)]
struct StatusItem {
    app: String,
    /// The app's name, for an accessibility label and the menu's row.
    extension: String,
    /// The item's title, else the app's name.
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    symbol: Option<String>,
    /// `titlebar`, `roomBar`, `statusStrip` or `menuBar`; `titlebar` when absent.
    placement: String,
    /// Where cmux NEXT draws it: `menuBar` (a row of the menu bar item's menu) or `titlebar` (the
    /// window's top row), which also takes `roomBar` and `statusStrip`, places NEXT has no strip for.
    place: &'static str,
}

impl Supervisor {
    /// `apps.status.list`: the status items of installed, enabled and visible apps, in app id
    /// order (one per app: a v2 app implements an interface once).
    pub(super) fn status_items(&self) -> Value {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if inner.safe_mode.is_some() {
            return json!({ "items": [] });
        }
        let items: Vec<StatusItem> = inner
            .mirror
            .apps
            .iter()
            .filter(|(_, record)| record.installed && record.enabled && !record.hidden)
            .filter_map(|(app, _)| {
                let manifest = &inner.catalog.packages.get(app)?.manifest;
                let entry = manifest.get("implements")?.get(INTERFACE)?;
                let extension = manifest
                    .get("name")
                    .map(text)
                    .filter(|n| !n.is_empty())
                    .unwrap_or_else(|| app.clone());
                let placement = entry
                    .pointer("/options/placement")
                    .and_then(Value::as_str)
                    .filter(|p| PLACEMENTS.contains(p))
                    .unwrap_or(DEFAULT_PLACEMENT);
                Some(StatusItem {
                    app: app.clone(),
                    title: entry
                        .get("title")
                        .map(text)
                        .filter(|t| !t.is_empty())
                        .unwrap_or_else(|| extension.clone()),
                    extension,
                    symbol: entry
                        .get("symbol")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())
                        .map(str::to_string),
                    placement: placement.to_string(),
                    place: if placement == "menuBar" { "menuBar" } else { "titlebar" },
                })
            })
            .take(MAX_ITEMS)
            .collect();
        json!({ "items": items })
    }
}
