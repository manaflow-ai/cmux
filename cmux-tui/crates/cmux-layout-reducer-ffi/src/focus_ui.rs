//! `cmux-focus-core`'s focus UI decisions over the JSON channel (ops
//! `focus_ui_*`): the macOS app keeps the AppKit objects and timers and asks
//! these rules (cmux_focus_core::ui).
//!
//! - `focus_ui_no_activate`: `{guard, host, event}` → `{guard, effects,
//!   sequence?, accepted?}`; the app keeps `guard` and sends it back.
//! - `focus_ui_hint_policy`: `{policy, event}` → `{policy, shows?, armed?}`.
//! - `focus_ui_pane_hints`: a plan → `{chips}`.
//! - `focus_ui_responder_move`: a move's facts → `{unseen, takesFromTyping}`.
//! - `focus_ui_cross_window`: a key's windows → `{drops}`.

use crate::ERR_INVALID;
use cmux_focus_core::ui::guards::{self, KeyWindows, ResponderMove};
use cmux_focus_core::ui::hint_policy::ShortcutHintPolicy;
use cmux_focus_core::ui::no_activate::{Effect, Event, HostReading, NoActivateGuard};
use cmux_focus_core::ui::pane_hints::{self, Chip, Plan};
use serde::{Deserialize, Serialize};

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"focus_ui_")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NoActivateRequest {
    #[serde(rename = "guard")]
    guardian: NoActivateGuard,
    host: HostReading,
    event: Event,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NoActivateResponse {
    #[serde(rename = "guard")]
    guardian: NoActivateGuard,
    effects: Vec<Effect>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sequence: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    accepted: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum HintEvent {
    #[serde(rename_all = "camelCase")]
    KeyDown {
        #[serde(default)]
        keeps_hints: bool,
    },
    #[serde(rename_all = "camelCase")]
    Update { flags: u64, eligible: bool, elapsed_ns: i64 },
}

#[derive(Deserialize)]
struct HintRequest {
    #[serde(default)]
    policy: ShortcutHintPolicy,
    event: HintEvent,
}

#[derive(Serialize)]
struct HintResponse {
    policy: ShortcutHintPolicy,
    #[serde(skip_serializing_if = "Option::is_none")]
    shows: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    armed: Option<u64>,
}

#[derive(Serialize)]
struct ChipsResponse {
    chips: Vec<Chip>,
}

#[derive(Serialize)]
struct DropsResponse {
    drops: bool,
}

fn parse<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn reply<T: Serialize>(value: &T) -> Result<Vec<u8>, i32> {
    serde_json::to_vec(value).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    match operation {
        b"focus_ui_no_activate" => {
            let NoActivateRequest { mut guardian, host, event } = parse(request)?;
            let answer = guardian.handle(host, event);
            reply(&NoActivateResponse {
                guardian,
                effects: answer.effects,
                sequence: answer.sequence,
                accepted: answer.accepted,
            })
        }
        b"focus_ui_hint_policy" => {
            let HintRequest { mut policy, event } = parse(request)?;
            let (shows, armed) = match event {
                HintEvent::KeyDown { keeps_hints } => {
                    policy.key_down(keeps_hints);
                    (None, None)
                }
                HintEvent::Update { flags, eligible, elapsed_ns } => (
                    Some(policy.update(flags, eligible, elapsed_ns)),
                    ShortcutHintPolicy::armed(flags),
                ),
            };
            reply(&HintResponse { policy, shows, armed })
        }
        b"focus_ui_pane_hints" => {
            let plan: Plan = parse(request)?;
            reply(&ChipsResponse { chips: pane_hints::chips(&plan) })
        }
        b"focus_ui_responder_move" => {
            let facts: ResponderMove = parse(request)?;
            reply(&guards::responder_move(&facts))
        }
        b"focus_ui_cross_window" => {
            let facts: KeyWindows = parse(request)?;
            reply(&DropsResponse { drops: guards::drops_key(&facts) })
        }
        _ => Err(ERR_INVALID),
    }
}
