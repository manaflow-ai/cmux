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
//! Surfaces, as the Mac names them when it publishes (each relay stream is the surface's
//! [`cmux_relay_snapshot::delta::delta_stream`]):
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
//! Sans-I/O: [`path`] and [`request`] build the HTTPS call, [`read`] takes the reply body, and
//! [`ack`] the drain call the phone sends after it applied (the app does the I/O).

use std::collections::BTreeMap;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_relay_snapshot::delta::{self, ApplyError};
use cmux_relay_snapshot::{Floor, Position, Viewer};
use p256::PublicKey;
use serde_json::{Value, json};

use super::service::{self, Answer};

/// The relay's most surfaces in one catch-up (`CATCH_UP_MAX_SURFACES`).
pub const MAX_SURFACES: usize = 64;
/// The relay's most `budgetBytes` (`CATCH_UP_BUDGET_MAX`).
pub const MAX_BUDGET_BYTES: u64 = 256 * 1024;

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

fn surface_of_stream(stream: &str) -> Option<&str> {
    stream.strip_suffix("/delta")
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

/// The relay route of a call (`catch-up` or `ack`) to `source`'s cache, as `viewer`.
pub fn path(source_device: &str, what: &str, viewer_device: &str) -> String {
    format!("/v1/relay-cache/{source_device}/{what}?deviceId={viewer_device}")
}

/// The catch-up body for `surfaces` (most wanted first: the budget cuts from the end), only
/// those with a floor, at most [`MAX_SURFACES`]. None when there is nothing to ask.
pub fn request(floors: &Floors, surfaces: &[String], budget: u64) -> Option<Value> {
    let mut seen = std::collections::BTreeSet::new();
    let asks: Vec<Value> = surfaces
        .iter()
        .filter(|surface| seen.insert(surface.as_str()))
        .filter_map(|surface| {
            let after = floors.get(surface)?;
            Some(json!({
                "surface": delta::delta_stream(surface),
                "after": { "epoch": u64_json(after.epoch), "seq": u64_json(after.seq) },
            }))
        })
        .take(MAX_SURFACES)
        .collect();
    if asks.is_empty() {
        return None;
    }
    let budget = if budget == 0 { super::WAKE_BUDGET_BYTES } else { budget.min(MAX_BUDGET_BYTES) };
    Some(json!({ "surfaces": asks, "budgetBytes": budget }))
}

/// The body of the `ack` call that drains a surface's relay log through what the phone applied
/// (the route's `?stream=` is `stream`).
pub fn ack(through: Position) -> Value {
    json!({ "through": { "epoch": u64_json(through.epoch), "seq": u64_json(through.seq) } })
}

/// The JSON of a u64 as the relay writes it: a number while exact, else a decimal string.
fn u64_json(value: u64) -> Value {
    if value <= (1u64 << 53) - 1 { json!(value) } else { json!(value.to_string()) }
}

fn u64_of(value: &Value) -> Option<u64> {
    value.as_u64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))
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
    /// `(stream, through)` to acknowledge (the `ack` call per surface), after applying.
    pub acks: Vec<(String, Position)>,
}

/// Why a relay reply could not be read at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadError {
    NotJson(String),
    /// Not the relay's catch-up reply (`fromRelay`).
    NotRelay,
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotJson(error) => write!(f, "relay catch-up reply is not JSON: {error}"),
            Self::NotRelay => f.write_str("not a relay catch-up reply"),
        }
    }
}

impl std::error::Error for ReadError {}

/// Reads the relay's reply body: unseals each surface's deltas under its floor, in order, and
/// turns each into a `catch-up` answer. A surface whose deltas stop (a hole, a seal refusal, a
/// plaintext that is not one surface's answer) keeps what applied before and is cut.
pub fn read<V: Viewer + ?Sized>(
    floors: &mut Floors,
    viewer: &V,
    source: &PublicKey,
    body: &[u8],
) -> Result<RelayAnswer, ReadError> {
    let reply: Value =
        serde_json::from_slice(body).map_err(|error| ReadError::NotJson(error.to_string()))?;
    if reply.get("fromRelay").and_then(Value::as_bool) != Some(true) {
        return Err(ReadError::NotRelay);
    }
    let mut out = RelayAnswer::default();
    let cut = |out: &mut RelayAnswer, surface: &str, why: &str| {
        let name = cut_name(surface);
        if !out.cut.contains(&name) {
            out.cut_why.insert(name.clone(), why.to_string());
            out.cut.push(name);
        }
    };
    for stream in reply.get("cut").and_then(Value::as_array).into_iter().flatten() {
        if let Some(surface) = stream.as_str().and_then(surface_of_stream) {
            cut(&mut out, surface, "relay");
        }
    }
    for entry in reply.get("surfaces").and_then(Value::as_array).into_iter().flatten() {
        let Some(surface) =
            entry.get("surface").and_then(Value::as_str).and_then(surface_of_stream)
        else {
            continue;
        };
        let Some(have) = floors.get(surface) else { continue };
        let envelopes: Option<Vec<Vec<u8>>> = entry
            .get("sealed")
            .and_then(Value::as_array)
            .map(|sealed| {
                sealed
                    .iter()
                    .map(|b64| b64.as_str().and_then(|b| URL_SAFE_NO_PAD.decode(b).ok()))
                    .collect()
            })
            .unwrap_or(Some(Vec::new()));
        let Some(envelopes) = envelopes else {
            cut(&mut out, surface, "malformed");
            continue;
        };
        let mut floor = Floor::at(have);
        let (opened, stopped) = delta::apply(&mut floor, viewer, source, surface, &envelopes);
        let mut through = None;
        let mut bad = stopped.map(|error| match error {
            ApplyError::NotNext { .. } => "hole",
            ApplyError::Seal(_) => "seal",
        });
        for delta in opened {
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
            out.acks.push((delta::delta_stream(surface), position));
        }
        if let Some(why) = bad {
            cut(&mut out, surface, why);
        }
        // The head the relay says it reached: deltas missing before it mean it withheld some.
        let head = entry.get("head").and_then(|head| {
            Some(Position { epoch: u64_of(head.get("epoch")?)?, seq: u64_of(head.get("seq")?)? })
        });
        if bad.is_none() && head.is_some_and(|head| head > floors.get(surface).unwrap_or(have)) {
            cut(&mut out, surface, "short");
        }
    }
    Ok(out)
}

/// One delta's plaintext as the `catch-up` answer of its surface.
fn answer_of(surface: &str, plaintext: &[u8]) -> Option<Answer> {
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
