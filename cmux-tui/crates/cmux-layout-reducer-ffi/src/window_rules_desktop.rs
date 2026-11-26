//! The desktop notification rules' ops (`window_notifications_desktop_*`):
//! whether a launch uses Notification Center, a banner's category and what
//! its actions do, the Needs you banners a mark change posts or withdraws,
//! agent-finished bursts and VoiceOver's status line.

use std::collections::HashMap;

use cmux_window_rules::{desktop_announce, desktop_attention, desktop_bursts, desktop_center};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// The prefix of this module's ops.
const PREFIX: &[u8] = b"window_notifications_desktop_";

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(PREFIX)
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn value<T: Serialize>(answer: T) -> Result<Value, i32> {
    serde_json::to_value(answer).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Launch {
    #[serde(default)]
    environment: HashMap<String, String>,
    #[serde(default)]
    automation: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Action {
    action: String,
    #[serde(default)]
    system_default: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Marks {
    previous: Option<Vec<String>>,
    #[serde(default)]
    current: Vec<String>,
    eligible: Option<Vec<String>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Banner {
    banner: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Retained {
    #[serde(default)]
    retained: Vec<String>,
    #[serde(default)]
    current_launch: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Join {
    burst: Option<desktop_bursts::Burst>,
    #[serde(flatten)]
    arrival: desktop_bursts::Arrival,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadTab {
    #[serde(default)]
    burst: desktop_bursts::Burst,
    tab: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Level {
    level: String,
    source: Option<String>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Speaks {
    attention: bool,
    acknowledge: bool,
    desktop: bool,
    banners_denied: bool,
    app_active: bool,
    pane_is_viewed: bool,
}

pub(crate) fn respond_desktop(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // How this launch uses Notification Center.
        b"window_notifications_desktop_launch" => {
            let request: Launch = read(request)?;
            value(desktop_center::center(&request.environment, request.automation))?
        }
        // A banner's category and redaction.
        b"window_notifications_desktop_banner" => {
            value(desktop_center::banner(&read::<desktop_center::BannerAsk>(request)?))?
        }
        // What a click on a banner's action does.
        b"window_notifications_desktop_response" => {
            let request: Action = read(request)?;
            value(desktop_center::response(&request.action, request.system_default))?
        }
        // The Needs you banners a change in the marks posts and withdraws.
        b"window_notifications_desktop_attention_changes" => {
            let request: Marks = read(request)?;
            let changes = desktop_attention::changes(request.previous.as_deref(), &request.current);
            let posts = desktop_attention::posts(
                request.previous.as_deref(),
                &request.current,
                request.eligible.as_deref(),
            );
            json!({ "post": changes.post, "withdraw": changes.withdraw, "posts": posts })
        }
        b"window_notifications_desktop_attention_tab" => {
            json!({ "tab": desktop_attention::tab(&read::<Banner>(request)?.banner) })
        }
        b"window_notifications_desktop_attention_stale" => {
            let request: Retained = read(request)?;
            json!({ "stale": desktop_attention::stale(&request.retained, &request.current_launch) })
        }
        // An agent-finished banner joining its workspace's burst.
        b"window_notifications_desktop_burst_join" => {
            let request: Join = read(request)?;
            value(desktop_bursts::join(request.burst, &request.arrival))?
        }
        b"window_notifications_desktop_burst_read" => {
            let request: ReadTab = read(request)?;
            value(desktop_bursts::read(request.burst, &request.tab))?
        }
        // VoiceOver's status line: an agent notification's kind and whether it is said.
        b"window_notifications_desktop_announce_kind" => {
            let request: Level = read(request)?;
            json!({ "kind": desktop_announce::kind(&request.level, request.source.as_deref()) })
        }
        b"window_notifications_desktop_announce_speaks" => {
            let request: Speaks = read(request)?;
            let speaks = desktop_announce::speaks(desktop_announce::Said {
                attention: request.attention,
                acknowledge: request.acknowledge,
                desktop: request.desktop,
                banners_denied: request.banners_denied,
                app_active: request.app_active,
                pane_is_viewed: request.pane_is_viewed,
            });
            json!({ "speaks": speaks })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
