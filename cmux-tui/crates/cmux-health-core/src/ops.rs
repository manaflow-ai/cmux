//! The one JSON entry point: `call(health, op, request) -> reply`, the
//! contract's op table. Field names are camelCase; times are ms on the
//! host's one monotonic clock (`nowMs`).
//!
//! | op | request | reply |
//! |----|---------|-------|
//! | `register` | `{id, kind, label, nowMs?, visible?}` | `{nextTickMs}` |
//! | `unregister` | `{id}` | `{nextTickMs}` |
//! | `beat` | `{id, nowMs}` | `{nextTickMs}` |
//! | `input` | `{id, sent, handled, nowMs}` | `{nextTickMs}` |
//! | `visibility` | `{id, visible, nowMs}` | `{nextTickMs}` |
//! | `event` | `{id, event, nowMs, pid?, value?}` | `{nextTickMs}` |
//! | `size` | `{id, bytes, nowMs}` | `{nextTickMs}` |
//! | `tick` | `{nowMs}` | `{actions, nextTickMs}` |
//! | `repairResult` | `{id, action, ok, nowMs}` | `{nextTickMs}` |
//! | `repairNow` | `{id, nowMs}` | `{actions, nextTickMs}` |
//! | `snapshot` | `{}` | the snapshot |
//! | `pending` | `{id, label, nowMs}` | `{nextTickMs}` |
//! | `pendingDone` | `{id, ok, nowMs}` | `{nextTickMs}` |
//! | `inject` | `{id, fault}` | `{ok: true}` (the host makes the hang) |
//!
//! Every op that changes the model answers `nextTickMs`, so the host re-arms
//! its one timer after any call (a `crashed` event or a show arms a deadline
//! too); `null` means no timer. An op on an unknown id changes nothing (a
//! beat racing an unregister).

use crate::model::Health;
use crate::{Kind, RepairAction};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of these.
    Unknown,
    /// The request is not the object the op takes.
    Invalid,
}

fn de<T: DeserializeOwned>(request: &Value) -> Result<T, OpError> {
    serde_json::from_value(request.clone()).map_err(|_| OpError::Invalid)
}

/// A time or counter: JavaScript may send `12.0`.
fn ms<'de, D: serde::Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
    let value = f64::deserialize(d)?;
    if value.is_finite() && value >= 0.0 {
        Ok(value as u64)
    } else {
        Err(serde::de::Error::custom("not a time"))
    }
}

/// An optional time or value: missing or `null` is none.
fn ms_opt<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
    match Option::<f64>::deserialize(d)? {
        Some(value) if value.is_finite() && value >= 0.0 => Ok(Some(value as u64)),
        Some(_) => Err(serde::de::Error::custom("not a time")),
        None => Ok(None),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Register {
    id: String,
    kind: Kind,
    #[serde(default)]
    label: String,
    #[serde(default, deserialize_with = "ms_opt")]
    now_ms: Option<u64>,
    #[serde(default = "yes")]
    visible: bool,
}

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
struct Id {
    id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct At {
    #[serde(default)]
    id: String,
    #[serde(deserialize_with = "ms")]
    now_ms: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Input {
    id: String,
    #[serde(deserialize_with = "ms")]
    sent: u64,
    #[serde(deserialize_with = "ms")]
    handled: u64,
    #[serde(deserialize_with = "ms")]
    now_ms: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Visibility {
    id: String,
    visible: bool,
    #[serde(deserialize_with = "ms")]
    now_ms: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Event {
    id: String,
    event: String,
    #[serde(deserialize_with = "ms")]
    now_ms: u64,
    // `pid` is accepted and not read: the model keys the daemon by its one
    // id, and `started` / `ready` order is what the loop rule needs.
    #[serde(default, deserialize_with = "ms_opt")]
    value: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Size {
    id: String,
    #[serde(deserialize_with = "ms")]
    bytes: u64,
    #[serde(deserialize_with = "ms")]
    now_ms: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RepairResult {
    id: String,
    action: RepairAction,
    ok: bool,
    #[serde(deserialize_with = "ms")]
    now_ms: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Pending {
    id: String,
    #[serde(default)]
    label: String,
    #[serde(deserialize_with = "ms")]
    now_ms: u64,
}

/// Runs one op on `health`.
pub fn call(health: &mut Health, op: &str, request: &Value) -> Result<Value, OpError> {
    match op {
        "register" => {
            let r: Register = de(request)?;
            health.register(&r.id, r.kind, &r.label, r.now_ms, r.visible);
        }
        "unregister" => health.unregister(&de::<Id>(request)?.id),
        "beat" => {
            let r: At = de(request)?;
            health.beat(&r.id, r.now_ms);
        }
        "input" => {
            let r: Input = de(request)?;
            health.input(&r.id, r.sent, r.handled, r.now_ms);
        }
        "visibility" => {
            let r: Visibility = de(request)?;
            health.visibility(&r.id, r.visible, r.now_ms);
        }
        "event" => {
            let r: Event = de(request)?;
            health.event(&r.id, &r.event, r.now_ms, r.value);
        }
        "size" => {
            let r: Size = de(request)?;
            health.size(&r.id, r.bytes, r.now_ms);
        }
        "tick" => {
            let r: At = de(request)?;
            let actions = health.tick(r.now_ms);
            return Ok(json!({ "actions": actions, "nextTickMs": health.next_tick_ms() }));
        }
        "repairResult" => {
            let r: RepairResult = de(request)?;
            health.repair_result(&r.id, r.action, r.ok, r.now_ms);
        }
        "repairNow" => {
            let r: At = de(request)?;
            let actions = health.repair_now(&r.id, r.now_ms);
            return Ok(json!({ "actions": actions, "nextTickMs": health.next_tick_ms() }));
        }
        "snapshot" => {
            return serde_json::to_value(health.snapshot()).map_err(|_| OpError::Invalid);
        }
        "pending" => {
            let r: Pending = de(request)?;
            health.pending(&r.id, &r.label, r.now_ms);
        }
        "pendingDone" => health.pending_done(&de::<Id>(request)?.id),
        // Debug only: the host hangs the part for real; nothing to record.
        "inject" => return Ok(json!({ "ok": true })),
        _ => return Err(OpError::Unknown),
    }
    Ok(json!({ "nextTickMs": health.next_tick_ms() }))
}
