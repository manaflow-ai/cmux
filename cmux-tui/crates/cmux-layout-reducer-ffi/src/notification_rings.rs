//! `cmux_window_rules::notification_rings` over the JSON channel (ops
//! `notification_rings_*`): the notification service's attention rings and
//! reads. The app reads its tab models, the settings and its view state into
//! facts, sends them and applies the answer (the ring it draws, the daemon
//! read, the blink, where an arrival goes). Ring generations go out as
//! decimal text (a mark's sets bit 63).

use cmux_window_rules::notification_rings::{
    self as rings, ArrivalFacts, EntryFacts, HighlightFacts, InteractionFacts, MarkFacts, MarkSend,
    ReadPolicy, ReplyFacts, Tab, Trigger, TurnEndFacts,
};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::ERR_INVALID;

const PREFIX: &[u8] = b"notification_rings_";

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(PREFIX)
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn value<T: Serialize>(answer: &T) -> Result<Vec<u8>, i32> {
    serde_json::to_vec(answer).map_err(|_| ERR_INVALID)
}

/// `notification_rings_ring`: one tab's ring generation.
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Ring {
    tab: Tab,
    dismissed: u64,
}

/// `notification_rings_reads`: whether a look reads a tab's ring.
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Reads {
    trigger: Trigger,
    tab: Tab,
    turn: bool,
    /// Ask whether the tab is read on sight (`readsOnSight`) instead.
    on_sight: bool,
    policy: ReadPolicy,
}

/// `notification_rings_program_seen`: a visible OSC 7501 status.
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ProgramSeen {
    clears_focus: bool,
}

/// A ring generation as decimal text: a mark's or a request's sets the top
/// bits, past the integers every JSON reader keeps exactly (2^53).
fn generation(ring: u64) -> String {
    ring.to_string()
}

/// One pane's mark on the wire (`AttentionMark`).
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireMark {
    pane: String,
    generation: String,
    agent_chat: bool,
    quiet: bool,
    color: rings::MarkColor,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let name = operation.strip_prefix(PREFIX).ok_or(ERR_INVALID)?;
    match name {
        b"ring" => {
            let ask: Ring = read(request)?;
            let ring = rings::unread_ring(&ask.tab, ask.dismissed);
            value(&json!({ "generation": ring.map(generation) }))
        }
        b"reads" => {
            let ask: Reads = read(request)?;
            let reads = if ask.on_sight {
                rings::reads_on_sight(&ask.tab, ask.policy)
            } else {
                rings::reads(ask.trigger, &ask.tab, ask.turn, ask.policy)
            };
            value(&json!({ "reads": reads }))
        }
        b"marks" => {
            let marks: Vec<WireMark> = rings::marks(&read::<MarkFacts>(request)?)
                .into_iter()
                .map(|mark| WireMark {
                    pane: mark.pane,
                    generation: generation(mark.generation),
                    agent_chat: mark.agent_chat,
                    quiet: mark.quiet,
                    color: mark.color,
                })
                .collect();
            value(&json!({ "marks": marks }))
        }
        b"entered" => value(&json!({ "panes": rings::entered(&read::<EntryFacts>(request)?) })),
        b"interaction" => value(&rings::interaction(&read::<InteractionFacts>(request)?)),
        b"dismiss_highlight" => value(&rings::dismiss_highlight(&read::<HighlightFacts>(request)?)),
        b"turn_ended" => value(&rings::turn_ended(&read::<TurnEndFacts>(request)?)),
        b"reply" => {
            value(&json!({ "allowed": rings::reply_allowed(&read::<ReplyFacts>(request)?) }))
        }
        b"arrival" => value(&json!({ "route": rings::arrival(&read::<ArrivalFacts>(request)?) })),
        b"program_seen" => {
            let ask: ProgramSeen = read(request)?;
            value(&json!({ "route": rings::seen(ask.clears_focus) }))
        }
        b"mark_send" => {
            value(&json!({ "send": rings::mark_needs_send(&read::<MarkSend>(request)?) }))
        }
        _ => Err(ERR_INVALID),
    }
}
