//! Which app actions an app may run through `action.run` (js/ABI.md). The
//! host decides; the runtime's local filtering is a courtesy.
//!
//! Source: the action catalog (`plans/cmux-next/action-surfaces.json`), whose
//! `mcp` field is the agent surface decision: `offered`, or the reason an
//! agent may not run the action. An app is held to the same line: actions
//! that sign in or hold secrets (`credentials`), quit the app (`endsApp`),
//! change preferences or the system (`systemChange`), act on live input or
//! the user's selection (`liveInput`, which holds destructive ones such as
//! killing a process), or are not real actions (`devOnly`, `unimplemented`,
//! `paletteInternal`, `dragGesture`) are refused. Every action the app may
//! run changes what the user sees (windows, tabs, focus, panels), so each
//! one needs a live gesture token and spends it.

use std::collections::HashMap;
use std::sync::OnceLock;

use serde_json::Value;

const ACTIONS_JSON: &str = include_str!("../../../../../plans/cmux-next/action-surfaces.json");

/// Agent-surface exemptions an app may never run.
const REFUSED: &[&str] = &[
    "credentials",
    "endsApp",
    "systemChange",
    "liveInput",
    "devOnly",
    "unimplemented",
    "paletteInternal",
    "dragGesture",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActionDecision {
    /// Allowed with a live gesture (which it spends).
    NeedsGesture,
    /// Not an action of this cmux version.
    Unknown,
    /// Refused for apps, with the catalog's reason.
    Refused(&'static str),
}

fn catalog() -> &'static HashMap<String, String> {
    static CATALOG: OnceLock<HashMap<String, String>> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let doc: Value = serde_json::from_str(ACTIONS_JSON).expect("action catalog is JSON");
        doc["actions"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|a| {
                Some((
                    a["id"].as_str()?.to_string(),
                    a["mcp"].as_str().unwrap_or("offered").to_string(),
                ))
            })
            .collect()
    })
}

/// The decision for `action.run {id}` from an app.
pub fn decide(id: Option<&str>) -> ActionDecision {
    let Some(mcp) = id.and_then(|id| catalog().get(id)) else { return ActionDecision::Unknown };
    match REFUSED.iter().find(|reason| **reason == mcp.as_str()) {
        Some(reason) => ActionDecision::Refused(reason),
        None => ActionDecision::NeedsGesture,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_exemptions_bind_apps_and_everything_else_needs_a_gesture() {
        assert_eq!(decide(Some("palette.auth.signIn")), ActionDecision::Refused("credentials"));
        assert_eq!(decide(Some("quit")), ActionDecision::Refused("endsApp"));
        assert_eq!(decide(Some("keepMacAwake")), ActionDecision::Refused("systemChange"));
        assert_eq!(decide(Some("taskManager.killProcess")), ActionDecision::Refused("liveInput"));
        assert_eq!(decide(Some("newWindow")), ActionDecision::NeedsGesture);
        assert_eq!(decide(Some("openSettings")), ActionDecision::NeedsGesture);
        assert_eq!(decide(Some("made.up")), ActionDecision::Unknown);
        assert_eq!(decide(None), ActionDecision::Unknown);
    }
}
