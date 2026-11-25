//! The fleet's elastic add/drain state on the wire (version 1).
//!
//! Two small objects, both versioned with `v` so a client tells a reply it knows from a
//! newer one, and both optional so an old daemon (no field) and an old client (field ignored)
//! keep working in lockstep with a new peer. Leo, 2026-11-24: "of course acpmux/cmux protocols
//! need to be able to work in lockstep with these and improve ever further".
//!
//! - `_acpmux/status` `scaleUp` (this daemon's own scale-up, `hub/admission_scale_up.rs`):
//!   `{"v":1, "state":"idle"|"adding"|"cooling", "lastStartedMs", "lastEndedMs", "lastHost",
//!   "lastError", "lastProvider"}`; the times are Unix ms, the rest null until a run ended.
//! - every machine row of `_acpmux/peers` (`acpmux machine ls`, `status` `peers`) `elastic`
//!   (that machine's fleet registry `lanes`): `{"v":1, "acceptNew": bool|null,
//!   "state":"steady"|"adding"|"draining"|"drained", "since", "why"}`; the row has no
//!   `elastic` when the registry has no `lanes` entry for the machine.
//!
//! The wire is camelCase like the rest of `status`. The fleet scaler (`leo-workspace
//! tools/lane_elastic.py`) decides add and drain at run time and writes no registry: it writes
//! its slots' states as `maker-slots.json` (`{"at": unix s, "slots": {name: {"state", "seats",
//! "elastic": {"state", "since": unix s, "why"}}}}`) into the freestyle-lanes state folder on
//! the maker and on the broker host. A fresh file ([`MAKER_FRESH_S`]) wins over the registry's
//! `lanes` (`accept_new`, `lanes.elastic`) for the machines it names.
//!
//! Readers ([`Elastic`], [`ScaleUpStatus`]) take every field as optional and every state as a
//! string they keep raw: an unknown `v` or state never fails a parse.

use crate::placement;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

/// The version of both objects this build writes.
pub const VERSION: u64 = 1;

/// How old the maker's `maker-slots.json` may be and still count (lane_overflow's
/// SNAPSHOT_FRESH_S): older, the scaler is not running and the registry alone speaks.
pub const MAKER_FRESH_S: f64 = 900.0;

/// A machine's `elastic` object as a client reads it. Unknown fields are ignored; a missing
/// one is `None`; `state` stays the raw string so a state added later still parses.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Elastic {
    pub v: Option<u64>,
    pub accept_new: Option<bool>,
    pub state: Option<String>,
    pub since: Option<String>,
    pub why: Option<String>,
}

impl Elastic {
    /// The `elastic` of a machine row (a `_acpmux/peers` element): None from an old daemon
    /// (no field) or a field that is not an object.
    pub fn from_row(row: &Value) -> Option<Self> {
        let field = row.get("elastic").filter(|v| v.is_object())?;
        serde_json::from_value(field.clone()).ok()
    }

    /// Whether this client knows the shape: version 1 and a state it names.
    pub fn known(&self) -> bool {
        self.v == Some(1)
            && matches!(self.state.as_deref(), Some("steady" | "adding" | "draining" | "drained"))
    }

    /// A short word for a machine list, only when not steady: `adding`, `draining`,
    /// `drained`, or `no new` (accepting no new lanes with no state); an unknown state is
    /// shown as written.
    pub fn label(&self) -> Option<String> {
        match self.state.as_deref() {
            Some("steady") | None if self.accept_new != Some(false) => None,
            Some("steady") | None => Some("no new".into()),
            Some(other) => Some(other.to_owned()),
        }
    }
}

/// `scaleUp` of `_acpmux/status` as a client reads it (same tolerance as [`Elastic`]).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ScaleUpStatus {
    pub v: Option<u64>,
    pub state: Option<String>,
    pub last_started_ms: Option<u64>,
    pub last_ended_ms: Option<u64>,
    pub last_host: Option<String>,
    pub last_error: Option<String>,
    pub last_provider: Option<String>,
}

impl ScaleUpStatus {
    /// The `scaleUp` of a `_acpmux/status` reply; None from an old daemon.
    pub fn from_status(status: &Value) -> Option<Self> {
        let field = status.get("scaleUp").filter(|v| v.is_object())?;
        serde_json::from_value(field.clone()).ok()
    }
}

/// The `elastic` object for the registry machine `name` (by name or alias), from its `lanes`.
/// None: no registry, the machine is not in it, or it has no `lanes` object.
///
/// With a `lanes.elastic.state` the state is that string, as written. Without one, `accept_new`
/// false reads `draining` (the registry's `accept_new_why` as why), else `steady`.
pub fn derive(registry: Option<&Value>, name: &str) -> Option<Value> {
    derive_with(registry, None, name)
}

/// [`derive`] with the maker's states (`maker-slots.json`, already judged fresh): a slot's
/// `elastic` there wins over the registry's `lanes.elastic`, and a draining or drained slot
/// accepts no new lanes. A slot the maker names gets `elastic` even with no `lanes` entry.
pub fn derive_with(registry: Option<&Value>, maker: Option<&Value>, name: &str) -> Option<Value> {
    let run = maker
        .and_then(|m| m.get("slots"))
        .and_then(|s| s.get(name))
        .and_then(|s| s.get("elastic"))
        .filter(|e| e.get("state").and_then(Value::as_str).is_some());
    let lanes =
        placement::machine(registry, name).and_then(|m| m.get("lanes")).filter(|l| l.is_object());
    if lanes.is_none() && run.is_none() {
        return None;
    }
    let closed = run
        .and_then(|e| e.get("state"))
        .and_then(Value::as_str)
        .is_some_and(|s| s == "draining" || s == "drained");
    let accept_new = if closed {
        Some(false)
    } else {
        lanes.and_then(|l| l.get("accept_new")).and_then(Value::as_bool)
    };
    let block = run.or_else(|| lanes.and_then(|l| l.get("elastic")).filter(|e| e.is_object()));
    let text = |v: Option<&Value>| match v {
        Some(Value::Number(n)) => n
            .as_f64()
            .and_then(|s| chrono::DateTime::from_timestamp(s as i64, 0))
            .map(|t| t.format("%Y-%m-%dT%H:%M:%SZ").to_string()),
        v => v.and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned),
    };
    let field = |key: &str| text(block.and_then(|b| b.get(key)));
    let (state, since, why) = match field("state") {
        Some(state) => (state, field("since"), field("why")),
        None if accept_new == Some(false) => (
            "draining".to_owned(),
            field("since"),
            field("why").or_else(|| text(lanes.and_then(|l| l.get("accept_new_why")))),
        ),
        None => ("steady".to_owned(), None, None),
    };
    Some(json!({"v": VERSION, "acceptNew": accept_new, "state": state, "since": since, "why": why}))
}

type Cached = Option<(PathBuf, SystemTime, u64, Arc<Value>)>;
static CACHE: Mutex<Cached> = Mutex::new(None);

/// The fleet registry (`placement::registry_path`), reread only when its file changed (size or
/// mtime), so every `peers` read is one `stat`. None when there is none or it cannot be read.
pub fn registry() -> Option<Arc<Value>> {
    let path = placement::registry_path()?;
    let meta = std::fs::metadata(&path).ok()?;
    let (mtime, len) = (meta.modified().ok()?, meta.len());
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((p, t, l, v)) = cache.as_ref()
        && *p == path
        && *t == mtime
        && *l == len
    {
        return Some(v.clone());
    }
    let value: Value = serde_json::from_slice(&std::fs::read(&path).ok()?).ok()?;
    let value = Arc::new(value);
    *cache = Some((path, mtime, len, value.clone()));
    Some(value)
}

static MAKER: Mutex<Cached> = Mutex::new(None);

/// The freestyle-lanes state folder, as `tools/freestyle_lanes.py` names it.
fn maker_states_path() -> Option<PathBuf> {
    let var = |k: &str| std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from);
    let dir = var("FREESTYLE_LANES_STATE").or_else(|| {
        var("LANE_OVERFLOW_STATE")
            .or_else(|| dirs::home_dir().map(|h| h.join(".cache/lane-overflow")))
            .map(|d| d.join("freestyle-lanes"))
    })?;
    Some(dir.join("maker-slots.json"))
}

/// The maker's slot states when this host holds a fresh copy (the maker itself, or the broker
/// host it pushes to), reread only when the file changed. None: no file, unreadable, or stale.
pub fn maker_states() -> Option<Arc<Value>> {
    let path = maker_states_path()?;
    let meta = std::fs::metadata(&path).ok()?;
    let (mtime, len) = (meta.modified().ok()?, meta.len());
    let mut cache = MAKER.lock().unwrap_or_else(|e| e.into_inner());
    let doc = match cache.as_ref() {
        Some((p, t, l, v)) if *p == path && *t == mtime && *l == len => v.clone(),
        _ => {
            let value =
                Arc::new(serde_json::from_slice::<Value>(&std::fs::read(&path).ok()?).ok()?);
            *cache = Some((path, mtime, len, value.clone()));
            value
        }
    };
    fresh(&doc, SystemTime::now()).then_some(doc)
}

/// Whether a `maker-slots.json` was written within [`MAKER_FRESH_S`] of `now`.
fn fresh(doc: &Value, now: SystemTime) -> bool {
    let now = now.duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    doc.get("at")
        .and_then(Value::as_f64)
        .is_some_and(|at| (0.0..=MAKER_FRESH_S).contains(&(now - at)))
}

/// Sets `elastic` on each machine row (`{"name": ...}`) the registry lists with `lanes`.
pub fn annotate(rows: &mut [Value], registry: Option<&Value>) {
    annotate_with(rows, registry, None);
}

/// [`annotate`] with the maker's fresh states ([`maker_states`]) over the registry.
pub fn annotate_with(rows: &mut [Value], registry: Option<&Value>, maker: Option<&Value>) {
    for row in rows {
        let Some(name) = row.get("name").and_then(Value::as_str) else { continue };
        if let (Some(elastic), Some(obj)) =
            (derive_with(registry, maker, name), row.as_object_mut())
        {
            obj.insert("elastic".into(), elastic);
        }
    }
}

/// The suffix of a plain-text `machine ls` line: empty when steady, absent, or an old
/// daemon's row.
pub fn suffix(row: &Value) -> String {
    Elastic::from_row(row).and_then(|e| e.label()).map(|l| format!("  [{l}]")).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn registry() -> Value {
        json!({"machines": {
            "lane-a": {"lanes": {"max_lanes": 6}},
            "lane-b": {"aliases": ["Bee.local"], "lanes": {"accept_new": false, "accept_new_why": "retiring"}},
            "lane-c": {"lanes": {"accept_new": false, "elastic": {
                "state": "drained", "since": "2026-11-24T10:00:00Z", "why": "idle 2h"}}},
            "lane-d": {"lanes": {"accept_new": true, "elastic": {"state": "adding", "since": "2026-11-24T11:00:00Z"}}},
            "lane-e": {"lanes": {"elastic": {"state": "resting", "why": "future"}}},
            "owned": {"roles": ["leo-mac"]},
        }})
    }

    fn of(name: &str) -> Option<Value> {
        derive(Some(&registry()), name)
    }

    #[test]
    fn elastic_derives_steady_draining_and_the_scalers_block() {
        assert_eq!(
            of("lane-a"),
            Some(json!({"v": 1, "acceptNew": null, "state": "steady", "since": null, "why": null}))
        );
        assert_eq!(
            of("bee"),
            Some(
                json!({"v": 1, "acceptNew": false, "state": "draining", "since": null, "why": "retiring"})
            ),
            "accept_new false with no block reads draining, by alias"
        );
        assert_eq!(
            of("lane-c"),
            Some(json!({"v": 1, "acceptNew": false, "state": "drained",
                "since": "2026-11-24T10:00:00Z", "why": "idle 2h"}))
        );
        assert_eq!(
            of("lane-d"),
            Some(json!({"v": 1, "acceptNew": true, "state": "adding",
                "since": "2026-11-24T11:00:00Z", "why": null}))
        );
        assert_eq!(
            of("lane-e").unwrap()["state"],
            "resting",
            "an unknown state is kept as written"
        );
    }

    #[test]
    fn elastic_the_makers_run_time_state_wins_over_the_registry() {
        let maker = json!({"at": 1_795_525_000.0, "slots": {
            "lane-a": {"state": "ready", "elastic": {"state": "draining", "since": 1_795_524_000.0, "why": "idle 31 min"}},
            "lane-new": {"state": "made", "elastic": {"state": "adding", "since": 1_795_524_900.0}},
            "lane-d": {"state": "ready"},
        }});
        let of = |n: &str| derive_with(Some(&registry()), Some(&maker), n);
        assert_eq!(
            of("lane-a"),
            Some(json!({"v": 1, "acceptNew": false, "state": "draining",
                        "since": "2026-11-24T12:40:00Z", "why": "idle 31 min"}))
        );
        assert_eq!(
            of("lane-new").unwrap()["state"],
            "adding",
            "a new slot with no lanes entry yet"
        );
        assert_eq!(of("lane-new").unwrap()["acceptNew"], Value::Null);
        assert_eq!(
            of("lane-d").unwrap()["state"],
            "adding",
            "no run-time state: the registry speaks"
        );
        assert!(fresh(
            &maker,
            SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_795_525_600)
        ));
        assert!(!fresh(
            &maker,
            SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_795_526_000)
        ));
    }

    #[test]
    fn elastic_is_absent_without_a_lanes_entry() {
        assert_eq!(of("owned"), None, "a machine with no lanes");
        assert_eq!(of("nobody"), None, "a machine not in the registry");
        assert_eq!(derive(None, "lane-a"), None, "no registry");
    }

    #[test]
    fn elastic_annotates_only_the_rows_the_registry_lists() {
        let mut rows = vec![json!({"name": "lane-b"}), json!({"name": "owned"}), json!({"x": 1})];
        annotate(&mut rows, Some(&registry()));
        assert_eq!(rows[0]["elastic"]["state"], "draining");
        assert!(rows[1].get("elastic").is_none() && rows[2].get("elastic").is_none());
    }

    #[test]
    fn elastic_list_suffix_only_when_not_steady() {
        let row = |e: Value| json!({"name": "m", "elastic": e});
        assert_eq!(suffix(&json!({"name": "m"})), "", "an old daemon's row");
        assert_eq!(suffix(&row(json!({"v": 1, "state": "steady"}))), "");
        assert_eq!(suffix(&row(json!({"v": 1, "state": "draining"}))), "  [draining]");
        assert_eq!(suffix(&row(json!({"v": 1, "state": "adding"}))), "  [adding]");
        assert_eq!(suffix(&row(json!({"v": 1, "acceptNew": false}))), "  [no new]");
        assert_eq!(suffix(&row(json!({"v": 3, "state": "resting"}))), "  [resting]");
    }

    /// What an old client deserialized, before these fields: it names none of them.
    #[derive(Deserialize)]
    struct OldPeerRow {
        name: String,
        connected: bool,
    }
    #[derive(Deserialize)]
    #[allow(dead_code)]
    struct OldStatus {
        version: String,
    }

    #[test]
    fn elastic_old_reply_parses_in_the_new_client() {
        let old_row = json!({"name": "lane-a", "connected": true});
        assert_eq!(Elastic::from_row(&old_row), None, "no field: None, no failure");
        assert_eq!(Elastic::from_row(&json!({"elastic": null})), None);
        assert_eq!(Elastic::from_row(&json!({"elastic": "x"})), None);
        assert_eq!(ScaleUpStatus::from_status(&json!({"version": "1.0"})), None);
    }

    #[test]
    fn elastic_new_reply_parses_in_the_old_client_and_the_new() {
        let mut row = json!({"name": "lane-b", "connected": true});
        annotate(std::slice::from_mut(&mut row), Some(&registry()));
        let old: OldPeerRow = serde_json::from_value(row.clone()).unwrap();
        assert_eq!((old.name.as_str(), old.connected), ("lane-b", true), "unknown field ignored");
        let new = Elastic::from_row(&row).unwrap();
        assert_eq!(new.v, Some(1));
        assert_eq!(new.accept_new, Some(false));
        assert_eq!(new.state.as_deref(), Some("draining"));
        assert!(new.known());
        let status = json!({"version": "1.0", "scaleUp": {"v": 1, "state": "cooling",
            "lastStartedMs": 5, "lastEndedMs": 9, "lastHost": "lane-9", "lastError": null,
            "lastProvider": "lanes"}});
        let _: OldStatus = serde_json::from_value(status.clone()).unwrap();
        let s = ScaleUpStatus::from_status(&status).unwrap();
        assert_eq!(
            (s.v, s.state.as_deref(), s.last_started_ms, s.last_ended_ms, s.last_host.as_deref()),
            (Some(1), Some("cooling"), Some(5), Some(9), Some("lane-9"))
        );
        assert_eq!(s.last_error, None);
    }

    #[test]
    fn elastic_future_version_and_unknown_state_do_not_fail() {
        let row = json!({"elastic": {"v": 2, "state": "hibernating", "acceptNew": true,
            "since": "t", "why": "w", "newField": {"a": 1}}});
        let e = Elastic::from_row(&row).unwrap();
        assert_eq!((e.v, e.state.as_deref()), (Some(2), Some("hibernating")));
        assert!(!e.known());
        let s = ScaleUpStatus::from_status(
            &json!({"scaleUp": {"v": 2, "state": "teleporting", "lastStartedMs": 1, "extra": true}}),
        )
        .unwrap();
        assert_eq!((s.v, s.state.as_deref()), (Some(2), Some("teleporting")));
        // A wrong-typed field fails only that object's parse, never the reply around it.
        assert_eq!(ScaleUpStatus::from_status(&json!({"scaleUp": {"v": "one"}})), None);
    }
}
