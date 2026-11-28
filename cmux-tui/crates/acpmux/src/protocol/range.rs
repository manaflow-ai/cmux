//! The ABI range a peer speaks, and the one check every hello makes against it (hq RFD "One update
//! system for every place cmux runs", the versioning decision): each side names `{abi, abiMin}`
//! in `_meta.acpmux`, the newest wire ABI it speaks ([`super::ABI`]) and the oldest one it still
//! serves ([`ABI_MIN`]). Two sides talk at the newest ABI both speak; they refuse each other, with
//! the typed `version.incompatible` ([`crate::recovery::kind::VERSION_INCOMPATIBLE`]) that names
//! which side to update, only when the ranges do not overlap.
//!
//! A peer from before the fields names neither: its `abi` reads as 0 ([`super::peer_abi`]) and its
//! missing `abiMin` as its `abi`, the one revision it spoke. [`ABI_MIN`] stays 0 until a build
//! drops a revision on purpose, so an old client never breaks against a new daemon and the
//! reverse: N-1 and N+1 always overlap, and the refusal is for a gap the compat file
//! (`spec/acpmux-abi.compat.json`) says no rule bridges.

use serde_json::{Value, json};

/// The oldest wire ABI this build still serves, as a daemon, and still speaks, as a client. It
/// goes up only when a build stops carrying a revision's compat rules: never past `ABI - 1`, so
/// the build before this one always still talks to it (`range_tests::the_window_keeps_n_minus_1`).
pub const ABI_MIN: u32 = 0;

/// `_meta.acpmux` key next to `abi`: the oldest ABI the sender serves.
pub const ABI_MIN_FIELD: &str = "abiMin";

/// An inclusive ABI range `min..=max`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AbiRange {
    pub min: u32,
    pub max: u32,
}

impl AbiRange {
    /// This build's range.
    pub const fn ours() -> AbiRange {
        AbiRange { min: ABI_MIN, max: super::ABI }
    }

    /// The range a hello or initialize reply names (`_meta.acpmux.{abi,abiMin}`). No `abiMin`, or
    /// one above `abi`, is read as `abi` alone: a peer that names no floor is taken to speak only
    /// the revision it names, never more.
    pub fn of(message: &Value) -> AbiRange {
        let max = super::peer_abi(message);
        let min = message
            .pointer("/_meta/acpmux/abiMin")
            .and_then(Value::as_u64)
            .and_then(|m| u32::try_from(m).ok())
            .filter(|m| *m <= max)
            .unwrap_or(max);
        AbiRange { min, max }
    }

    /// The newest ABI both ranges hold, or `None` when they do not overlap.
    pub fn common(self, other: AbiRange) -> Option<u32> {
        let top = self.max.min(other.max);
        (top >= self.min.max(other.min)).then_some(top)
    }

    pub fn json(self) -> Value {
        json!({"min": self.min, "max": self.max})
    }
}

/// Which side of a refused hello is the older one, so the refusal names what to update.
pub fn update_side(ours: AbiRange, theirs: AbiRange) -> &'static str {
    if theirs.max < ours.min { "peer" } else { "self" }
}

/// The refusal's message, its recovery sentence and its details, for a hello whose range does not
/// overlap ours. `peer` names the other side (`the daemon`, `this client`).
pub fn incompatible(ours: AbiRange, theirs: AbiRange, peer: &str) -> (String, String, Value) {
    let message = format!(
        "{peer} speaks acpmux wire ABI {}..={}, and this build {}..={}: no revision in common",
        theirs.min, theirs.max, ours.min, ours.max
    );
    let recovery = if update_side(ours, theirs) == "peer" {
        format!(
            "{peer} is older than this build serves: run `acpmux host self-update` where it runs."
        )
    } else {
        format!("{peer} is newer than this build speaks: run `acpmux host self-update` here.")
    };
    let details =
        json!({"ours": ours.json(), "theirs": theirs.json(), "update": update_side(ours, theirs)});
    (message, recovery, details)
}

/// JSON-RPC's Invalid Request: the hello itself is what the daemon cannot serve.
const INVALID_REQUEST: i64 = -32600;

/// The JSON-RPC refusal a daemon answers a hello it shares no ABI with.
pub fn refusal(ours: AbiRange, theirs: AbiRange) -> crate::rpc::RpcError {
    refusal_of(ours, theirs, "this client")
}

/// [`refusal`], naming the other side `peer` (`the peer daemon`, `the daemon`).
pub fn refusal_of(ours: AbiRange, theirs: AbiRange, peer: &str) -> crate::rpc::RpcError {
    let (message, recovery, details) = incompatible(ours, theirs, peer);
    crate::rpc::RpcError::new(INVALID_REQUEST, message).with_data(typed(recovery, details))
}

/// The `data` of a `version.incompatible` refusal: its kind, the sentence that says what to do,
/// and the two ranges with the side to update.
pub fn typed(recovery: String, details: Value) -> Value {
    json!({
        "errorKind": crate::recovery::kind::VERSION_INCOMPATIBLE,
        "recovery": recovery,
        "details": details,
    })
}

/// The check a side that sent a hello makes on the answer (a peer link's `initialize` reply):
/// an answer that names an ABI range sharing nothing with this build's is refused, typed, as the
/// far side would refuse the hello. An answer that names no `abi` is a build from before the
/// field and is served as before.
pub fn check_reply(reply: &Value, peer: &str) -> Result<(), crate::rpc::RpcError> {
    if reply.pointer("/_meta/acpmux/abi").is_none() {
        return Ok(());
    }
    let (ours, theirs) = (AbiRange::ours(), AbiRange::of(reply));
    match ours.common(theirs) {
        Some(_) => Ok(()),
        None => Err(refusal_of(ours, theirs, peer)),
    }
}

/// A refusal as one line for a link's last error: its message, then, for a typed
/// `version.incompatible`, the sentence that says which side to update. Any other error is its
/// message alone.
pub fn describe(error: &crate::rpc::RpcError) -> String {
    let data = error.data.as_ref();
    let kind = data.and_then(|d| d.get("errorKind")).and_then(Value::as_str);
    match data.and_then(|d| d.get("recovery")).and_then(Value::as_str) {
        Some(recovery) if kind == Some(crate::recovery::kind::VERSION_INCOMPATIBLE) => {
            format!(
                "{} ({}): {recovery}",
                error.message,
                crate::recovery::kind::VERSION_INCOMPATIBLE
            )
        }
        _ => error.message.clone(),
    }
}

/// The message and typed `data` for an agent host whose protocol range
/// (`agent_host::{PROTOCOL_MIN, PROTOCOL_MAX}`) shares no revision with this daemon's: the host
/// answered its hello `Incompatible`.
///
/// The agent host's own protocol range (`agent_host::{PROTOCOL_MIN, PROTOCOL_MAX}`): a host that
/// answered `Incompatible` shares no revision with this daemon. It runs the build that started
/// it until its agent ends, so no update of the host fixes it: the side to update is this
/// daemon when the host is newer, and the chat, restarted on this build, when it is older.
pub fn agent_host_incompatible(
    ours: (u16, u16),
    theirs: (u16, u16),
    host_build: &str,
) -> (String, Value) {
    let (ours, theirs) = (
        AbiRange { min: ours.0.into(), max: ours.1.into() },
        AbiRange { min: theirs.0.into(), max: theirs.1.into() },
    );
    let side = update_side(ours, theirs);
    let message = format!(
        "the agent host (build {host_build}) speaks agent-host protocol {}..={}, and this daemon {}..={}: no revision in common",
        theirs.min, theirs.max, ours.min, ours.max
    );
    let recovery = if side == "peer" {
        "the agent host is older than this daemon serves: restart the chat to start its agent on this build.".to_owned()
    } else {
        "the agent host is newer than this daemon speaks: run `acpmux host self-update` here."
            .to_owned()
    };
    let details = json!({"ours": ours.json(), "theirs": theirs.json(), "update": side, "link": "agent-host", "hostBuild": host_build});
    let mut data = typed(recovery, details);
    data["message"] = json!(message);
    (message, data)
}

#[cfg(test)]
#[path = "range_tests.rs"]
mod range_tests;
