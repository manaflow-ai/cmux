//! Catch-up from the relay edge with the Mac asleep (RFD 0142 R9, PROTOCOL.md "Relay cache
//! routes"): the phone asks the relay for every sealed delta after the position it holds of each
//! surface, unseals them, and applies each one as a `catch-up` reply from the Mac
//! ([`super::service`]) would be, so the same cursors and the same app code take them. Off unless
//! the app's `relay.deltaCatchup` setting is on.
//!
//! The relay holds ciphertext only (`cmux-relay-snapshot-v1`): each delta is sealed by the Mac's
//! identity key to the phone's key for one stream, and [`cmux_relay_snapshot::delta::apply`]
//! takes only the exact next position, so a relay can withhold a delta but never reorder, replay
//! or forge one. A surface the relay holds nothing for, has a gap in, or cut for the budget comes
//! back in [`RelayAnswer::cut`]: the phone asks the Mac for it on wake, as today.
//!
//! Surfaces, as the Mac names them when it publishes (the relay keys a surface's log by this
//! name; each delta is sealed on its [`cmux_relay_snapshot::delta::delta_stream`]):
//!
//! - `workspaces`: one delta is the `workspaces` object of a `catch-up` reply;
//! - `chat-list`: the `chatList` object (an `_acpmux/watch` follow);
//! - `chat/<sessionId>`: one entry of `chats` (an `_acpmux/attach` page).
//!
//! The relay position a phone may resume after comes from the Mac: a `catch-up` reply's
//! `relay` object (`{surface: {epoch, seq}}`, [`super::service::Answer::relay_heads`]) says which
//! relay position the state it answered with reached. With no position for a surface the relay is
//! not asked for it (there is no base state to apply deltas over).
//!
//! This module holds what is the phone's own: which surfaces to ask and from where ([`wanted`]),
//! and what an opened delta means ([`take`]). The relay calls themselves, the seal checks and the
//! in-order apply are the one relay cache client, `cmux_mobile_link::relay_cache` (its sans-I/O
//! `path`, `catch_up_body`, `read_catch_up`, `apply_catch_up` and `ack_body`).

use std::collections::BTreeMap;

use cmux_relay_snapshot::delta::ApplyError;
use cmux_relay_snapshot::{Floor, Position};
use serde_json::{Value, json};

use super::service::{self, Answer};

const FORMAT: &str = "cmux-relay-floors/1";
const WORKSPACES: &str = "workspaces";
const CHAT_LIST: &str = "chat-list";
const CHAT_PREFIX: &str = "chat/";

/// The relay surface of a chat.
pub fn chat_surface(session_id: &str) -> String {
    format!("{CHAT_PREFIX}{session_id}")
}

/// The `catch-up` reply's cut name of a relay surface (`workspaces`, `chatList`, `chats:<id>`).
pub fn cut_name(surface: &str) -> String {
    match surface {
        CHAT_LIST => "chatList".to_string(),
        _ => match surface.strip_prefix(CHAT_PREFIX) {
            Some(id) => format!("chats:{id}"),
            None => surface.to_string(),
        },
    }
}

/// The highest relay position the phone applied of each surface: the rollback guard
/// ([`Floor`]) and the position a catch-up resumes after. Kept by the app beside the cursors.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Floors {
    floors: BTreeMap<String, Position>,
}

impl Floors {
    pub fn get(&self, surface: &str) -> Option<Position> {
        self.floors.get(surface).copied()
    }

    /// The Mac answered with state reaching `heads` (a `catch-up` reply's `relay`): each
    /// surface resumes from there. A head of another epoch replaces the floor (the Mac restarted
    /// its log); an older one of the same epoch is ignored.
    pub fn set_from_mac(&mut self, heads: &BTreeMap<String, (u64, u64)>) {
        for (surface, &(epoch, seq)) in heads {
            let head = Position { epoch, seq };
            match self.floors.get(surface) {
                Some(have) if have.epoch == epoch && *have >= head => {}
                _ => {
                    self.floors.insert(surface.clone(), head);
                }
            }
        }
    }

    /// Forgets a surface (the phone dropped its state, e.g. a chat it no longer keeps).
    pub fn forget(&mut self, surface: &str) {
        self.floors.remove(surface);
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = format!("{FORMAT}\n");
        for (surface, position) in &self.floors {
            // Surfaces are relay stream names ([A-Za-z0-9._/-]), so no field escaping is needed.
            out.push_str(&format!("{surface}\t{}\t{}\n", position.epoch, position.seq));
        }
        out.into_bytes()
    }

    /// Reads [`Floors::encode`]'s bytes; anything else reads as none (the relay is not asked
    /// until the Mac answers again).
    pub fn decode(bytes: &[u8]) -> Self {
        let read = || -> Option<Self> {
            let text = std::str::from_utf8(bytes).ok()?;
            let mut lines = text.lines();
            if lines.next()? != FORMAT {
                return None;
            }
            let mut floors = BTreeMap::new();
            for line in lines {
                let [surface, epoch, seq] = line.split('\t').collect::<Vec<_>>()[..] else {
                    return None;
                };
                floors.insert(
                    surface.to_string(),
                    Position { epoch: epoch.parse().ok()?, seq: seq.parse().ok()? },
                );
            }
            Some(Self { floors })
        };
        read().unwrap_or_default()
    }
}

/// The relay's most surfaces in one catch-up (`CATCH_UP_MAX_SURFACES`).
pub const MAX_SURFACES: usize = 64;

/// The catch-up budget for `budget` (0: the wake's, [`super::WAKE_BUDGET_BYTES`]); the relay
/// client caps it at the relay's most.
pub fn budget(budget: u64) -> usize {
    let budget = if budget == 0 { super::WAKE_BUDGET_BYTES } else { budget };
    usize::try_from(budget).unwrap_or(usize::MAX)
}

/// The surfaces to ask the relay for, of `surfaces` (most wanted first: the budget cuts from the end), each
/// with the floor it resumes after: only those with a floor, once each, at most [`MAX_SURFACES`].
/// The relay cache client (`cmux_mobile_link::relay_cache`) asks and opens them.
pub fn wanted(floors: &Floors, surfaces: &[String]) -> Vec<(String, Floor)> {
    let mut seen = std::collections::BTreeSet::new();
    surfaces
        .iter()
        .filter(|surface| seen.insert(surface.as_str()))
        .filter_map(|surface| Some((surface.clone(), Floor::at(floors.get(surface)?))))
        .take(MAX_SURFACES)
        .collect()
}

/// One surface as the relay cache client opened it.
#[derive(Debug, Clone, Copy)]
pub struct Opened<'a> {
    pub surface: &'a str,
    /// The deltas that opened, in order.
    pub applied: &'a [cmux_relay_snapshot::Opened],
    /// Why it stopped before the end, if it did.
    pub stopped: Option<&'a ApplyError>,
    /// Where the relay says the surface's log reached.
    pub head: Position,
}

/// What one relay catch-up gave.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct RelayAnswer {
    /// One `catch-up` answer per delta applied, in order: apply each as the Mac's would be.
    pub answers: Vec<Answer>,
    /// Surfaces not brought up (cut names, as a Mac reply's `cut`): ask the Mac on wake.
    pub cut: Vec<String>,
    /// Why each was cut.
    pub cut_why: BTreeMap<String, String>,
    /// `(surface, through)` to acknowledge (the `ack` call per surface), after applying.
    pub acks: Vec<(String, Position)>,
}

/// Turns what the relay cache client opened into `catch-up` answers: each delta's plaintext is one
/// surface's answer. A surface that stopped (a hole, a seal refusal, a plaintext that is not its
/// surface's answer) or that the relay held back (`cut`, or a head past what applied) keeps what
/// applied before and is cut. `floors` rises to what applied.
pub fn take(floors: &mut Floors, relay_cut: &[String], opened: &[Opened<'_>]) -> RelayAnswer {
    let mut out = RelayAnswer::default();
    let cut = |out: &mut RelayAnswer, surface: &str, why: &str| {
        let name = cut_name(surface);
        if !out.cut.contains(&name) {
            out.cut_why.insert(name.clone(), why.to_string());
            out.cut.push(name);
        }
    };
    for surface in relay_cut {
        cut(&mut out, surface, "relay");
    }
    for entry in opened {
        let surface = entry.surface;
        let Some(have) = floors.get(surface) else { continue };
        let mut through = None;
        let mut bad = entry.stopped.map(|error| match error {
            ApplyError::NotNext { .. } => "hole",
            ApplyError::Seal(_) => "seal",
        });
        for delta in entry.applied {
            match answer_of(surface, &delta.plaintext) {
                Some(answer) => {
                    out.answers.push(answer);
                    through = Some(delta.position);
                }
                None => {
                    bad = Some("plaintext");
                    break;
                }
            }
        }
        if let Some(position) = through {
            floors.floors.insert(surface.to_string(), position);
            out.acks.push((surface.to_string(), position));
        }
        if let Some(why) = bad {
            cut(&mut out, surface, why);
        } else if entry.head > through.unwrap_or(have) {
            // The relay holds more than it sent: it withheld the tail.
            cut(&mut out, surface, "short");
        }
    }
    out
}

/// One delta's (or a cold open's first screen's) plaintext as the `catch-up` answer of its
/// surface; `None` when it is not that surface's answer.
pub fn answer_of(surface: &str, plaintext: &[u8]) -> Option<Answer> {
    let value: Value = serde_json::from_slice(plaintext).ok()?;
    if !value.is_object() {
        return None;
    }
    let reply = match surface {
        WORKSPACES => json!({ "v": service::VERSION, "workspaces": value }),
        CHAT_LIST => json!({ "v": service::VERSION, "chatList": value }),
        _ => {
            let id = surface.strip_prefix(CHAT_PREFIX)?;
            if value.get("sessionId").and_then(Value::as_str) != Some(id) {
                return None;
            }
            json!({ "v": service::VERSION, "chats": [value] })
        }
    };
    service::read(reply.to_string().as_bytes()).ok()
}

#[cfg(test)]
#[path = "relay_tests.rs"]
mod tests;
