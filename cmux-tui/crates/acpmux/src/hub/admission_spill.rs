//! A create no host has room for starts on a host the fleet adds for it, not
//! piled onto this one (Leo, 2026-11-24: "well we have infinite gcp/freestyle
//! capabilities. plus our speedup optimizations. so"). Lane hosts ran at 2-4x
//! their `lanes.max_lanes` (gcp-agent-lane-8 at 21 against 6) because a cap only
//! warns, the redirect (`admission_redirect.rs`) took a peer whose room nobody
//! knew, and the scale-up (`admission_scale_up.rs`) ran detached, so the create
//! that asked for a machine never used it.
//!
//! A spill: a create that may move (`admission_redirect::considered`: it asked,
//! nothing ties it here, an agent's on a lane host at its cap or busy) and asked
//! to spill ([`FIELD`]), on a host whose registry turns spills on ([`config`]),
//! where no connected peer has room it is known to have ([`known_room`]: a pick
//! with a health reading and room for a lane, not one whose resources are
//! unknown), waits for the scale-up's host (`ScaleUp::host_for_spill`: a run the
//! burst shares, or a host one added within the cooldown while it has room for
//! spills), then for that host to join (connected, as `placement::peer_down`
//! reads it), and starts there the way a redirect does. The client is told
//! ([`PROGRESS`]) that it is starting on a new host while it waits. With no host,
//! or none joined, by the deadline, the create starts here, warned, as before:
//! a launch is never refused.
//!
//! The lockstep, as the redirect's: a daemon that spills lists [`CAPABILITY`] at
//! `initialize`; a client that can wait sends `_meta.acpmux.placeSpill:
//! {"v": 1, "waitMs": N}` beside `placeRedirect` (a bare `true` or `1` means the
//! default wait); the answer's `_meta.acpmux.placement.spill` is
//! `{"v", "host", "fresh", "waitedMs"}` ([`note`]). An old client sends none and
//! gets the redirect or the warned start it always did; a new client facing an
//! old daemon sees no capability and sends none; a forward to a peer never
//! carries the ask (`admission_redirect::forwarded`), so no peer spills again.
//!
//! The switch is the registry's `lane_overflow.spill` (`{"enabled": true,
//! "wait_seconds": N, "max_spills_per_host": N}`); with no `enabled` it follows
//! `lane_place.one_lane_per_host` ([`one_per_host`]: then a host holding a live session
//! has no room for a create that may move, and each added host takes one).
//! `ACPMUX_SPILL=0` turns it off on one host and `ACPMUX_SPILL=1` on. Each decision logs an `admission-place`
//! line: `spill_waiting`, `spilled`, `spill_failed`.

use super::admission_redirect::Reason;
use serde_json::{Value, json};
use std::time::Duration;

/// Listed at `initialize` by a daemon that spills a create no host has room for.
pub const CAPABILITY: &str = "place-spill-v1";
/// `_meta.acpmux` key of `session/new`: the caller waits for a spill.
pub const FIELD: &str = "placeSpill";
/// The notification a waiting create's connection gets.
pub const PROGRESS: &str = "_acpmux/new_progress";
/// The shape version of the ask, the answer's note and [`PROGRESS`].
pub const VERSION: u64 = 1;
/// `0`: no spill on this host; `1`: spills with no registry switch.
pub const ENV: &str = "ACPMUX_SPILL";
/// The wait with none asked or configured, and its bound.
pub const WAIT_DEFAULT: Duration = Duration::from_secs(300);
const WAIT_MAX: Duration = Duration::from_secs(900);
/// Spills one added host takes before a new one is asked for, with no registry number.
const PER_HOST_DEFAULT: u64 = 6;
/// How often a joining host is looked for.
pub const JOIN_POLL: Duration = Duration::from_secs(2);

/// This host's spill settings (`lane_overflow.spill`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Config {
    pub wait: Duration,
    pub per_host: u64,
}

/// The settings in `registry`, when spills are on: the switch, or `ACPMUX_SPILL`.
pub(crate) fn config(registry: Option<&Value>) -> Option<Config> {
    config_with(registry, std::env::var(ENV).ok().as_deref())
}

pub(crate) fn config_with(registry: Option<&Value>, env: Option<&str>) -> Option<Config> {
    let spec = registry.and_then(|r| r.pointer("/lane_overflow/spill"));
    let solo = one_per_host(registry);
    let on = match env.map(str::trim) {
        Some("0") => false,
        Some("1") => true,
        // Unset, the switch follows one lane per machine: no host is packed past it.
        _ => spec.and_then(|s| s.get("enabled")).and_then(Value::as_bool).unwrap_or(solo),
    };
    if !on {
        return None;
    }
    let secs = |k: &str| spec.and_then(|s| s.get(k)).and_then(Value::as_f64).filter(|n| *n >= 1.0);
    let wait =
        secs("wait_seconds").map_or(WAIT_DEFAULT, |s| Duration::from_secs(s as u64)).min(WAIT_MAX);
    // One lane per machine wins over max_spills_per_host: an added host takes one.
    let per_host = match secs("max_spills_per_host") {
        _ if solo => 1,
        Some(n) => n as u64,
        None => PER_HOST_DEFAULT,
    };
    Some(Config { wait, per_host })
}

/// Whether the registry puts one lane on each machine (`lane_place.one_lane_per_host`, Leo,
/// 2026-11-24: "stop packing if you're still packing. each guy gets their individual lil
/// machine for now"): a host holding a live session has no room for another create that may
/// move, and a host the fleet adds takes one.
pub(crate) fn one_per_host(registry: Option<&Value>) -> bool {
    registry.and_then(|r| r.pointer("/lane_place/one_lane_per_host")).and_then(Value::as_bool)
        == Some(true)
}

/// How long the caller of `params` waits for a spill; None when it asked for none. A
/// later version is read as this one: its `waitMs` still bounds the wait.
pub(crate) fn asked(params: &Value) -> Option<Duration> {
    match params.pointer(&format!("/_meta/acpmux/{FIELD}"))? {
        Value::Bool(true) => Some(WAIT_DEFAULT),
        Value::Number(n) if n.as_u64().is_some_and(|n| n >= 1) => Some(WAIT_DEFAULT),
        Value::Object(o) => {
            let v = o.get("v").and_then(Value::as_u64).unwrap_or(1);
            if v < 1 {
                return None;
            }
            Some(
                o.get("waitMs").and_then(Value::as_u64).map_or(WAIT_DEFAULT, Duration::from_millis),
            )
        }
        _ => None,
    }
}

/// The wait of a create that asked `asked` on a host spilling with `config`: the shorter.
pub(crate) fn wait(asked: Option<Duration>, config: Option<Config>) -> Option<Duration> {
    let (asked, config) = (asked?, config?);
    Some(asked.min(config.wait)).filter(|w| !w.is_zero())
}

/// Whether the placement engine's `verdict` over the connected peers names one with room
/// it is known to have: a reading that shows room for a lane, no overload, and no shadow
/// defer; with `solo` (`one_per_host`), no live session there either. A pick whose resources
/// are unknown is no room (it may be as full as this host).
pub(crate) fn known_room(verdict: &Value, solo: bool) -> bool {
    let pick = verdict.get("pick").and_then(Value::as_str);
    let empty = || {
        let hosts = verdict.get("hosts").and_then(Value::as_array);
        let row =
            hosts.and_then(|h| h.iter().find(|r| r.get("name").and_then(Value::as_str) == pick));
        row.and_then(|r| r.get("live")).and_then(Value::as_u64) == Some(0)
    };
    pick.is_some()
        && verdict.get("overloaded").and_then(Value::as_bool) != Some(true)
        && verdict.get("room").and_then(Value::as_f64).is_some_and(|r| r >= 1.0)
        && verdict.pointer("/shadow/would_defer").and_then(Value::as_bool) != Some(true)
        && (!solo || empty())
}

/// A create admission chose to spill (`Admitted::spill`).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Spill {
    pub reason: Reason,
    pub live: usize,
    pub max: Option<u64>,
    pub wait: Duration,
    pub per_host: u64,
    /// The scale-up's providers (`admission_scale_up::plan`); None when the fleet declares
    /// none here, and nothing is waited for.
    pub plan: Option<super::admission_scale_up::Plan>,
}

/// Whether row `row` of `Hub::peers` is `host`, joined.
pub(crate) fn joined(rows: &[Value], host: &str) -> bool {
    rows.iter().any(|r| {
        r.get("name").and_then(Value::as_str) == Some(host)
            && crate::placement::peer_down(r).is_none()
    })
}

/// Waits until `host` has joined (`rows` reads the peers) or `left` passes: whether it did.
pub(crate) async fn wait_joined(
    host: &str,
    left: Duration,
    poll: Duration,
    rows: impl Fn() -> Vec<Value>,
) -> bool {
    let until = tokio::time::Instant::now() + left;
    loop {
        if joined(&rows(), host) {
            return true;
        }
        let now = tokio::time::Instant::now();
        if now >= until {
            return false;
        }
        tokio::time::sleep(poll.min(until - now)).await;
    }
}

/// What the waiting client is told (`PROGRESS`).
pub(crate) fn progress(state: &str, host: Option<&str>, wait: Duration) -> Value {
    let text = match (state, host) {
        ("joining", Some(h)) => format!("starting on a new host: waiting for {h} to join"),
        _ => "starting on a new host: no host has room, so the fleet is adding one".into(),
    };
    json!({"v": VERSION, "state": state, "host": host, "waitMs": wait.as_millis() as u64, "text": text})
}

/// The `placement.spill` note of a spilled create's answer.
pub(crate) fn note(host: &str, fresh: bool, waited: Duration) -> Value {
    json!({"v": VERSION, "host": host, "fresh": fresh, "waitedMs": waited.as_millis() as u64})
}

/// `result` (a placed create's answer, `admission_redirect::answer`) with its spill note.
pub(crate) fn with_note(mut result: Value, note: Value) -> Value {
    if let Some(p) = result.pointer_mut("/_meta/acpmux/placement").and_then(Value::as_object_mut) {
        p.insert("spill".into(), note);
    }
    result
}

/// The text a create that could not spill adds to its warning.
pub(crate) fn failed(why: &str) -> String {
    format!("No host had room and none was added in time ({why}), so it started here.")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spill_config_is_off_without_the_switch_and_bounded_with_it() {
        let off = json!({"lane_overflow": {"providers": []}});
        assert_eq!(config_with(Some(&off), None), None, "no switch: no spill");
        assert_eq!(config_with(None, None), None);
        let on = json!({"lane_overflow": {"spill": {"enabled": true, "wait_seconds": 5000}}});
        let c = config_with(Some(&on), None).unwrap();
        assert_eq!(c.wait, WAIT_MAX);
        assert_eq!(c.per_host, PER_HOST_DEFAULT);
        assert_eq!(config_with(Some(&on), Some("0")), None, "ACPMUX_SPILL=0 wins");
        let one = config_with(Some(&off), Some("1")).unwrap();
        assert_eq!(one.wait, WAIT_DEFAULT, "ACPMUX_SPILL=1 with no switch");
        // One lane per machine turns it on, one spill a host, unless the switch says off.
        let solo = json!({"lane_place": {"one_lane_per_host": true}, "lane_overflow": {}});
        assert_eq!(config_with(Some(&solo), None).map(|c| c.per_host), Some(1));
        let solo_six = json!({"lane_place": {"one_lane_per_host": true},
            "lane_overflow": {"spill": {"max_spills_per_host": 6}}});
        assert_eq!(config_with(Some(&solo_six), None).map(|c| c.per_host), Some(1), "solo wins");
        let solo_off = json!({"lane_place": {"one_lane_per_host": true},
            "lane_overflow": {"spill": {"enabled": false}}});
        assert_eq!(config_with(Some(&solo_off), None), None);
    }

    #[test]
    fn spill_ask_reads_every_version_and_an_old_client_asks_none() {
        let p = |v: Value| json!({"_meta": {"acpmux": {FIELD: v}}});
        assert_eq!(asked(&json!({"_meta": {"acpmux": {"placeRedirect": 1}}})), None, "old client");
        assert_eq!(asked(&p(json!(true))), Some(WAIT_DEFAULT));
        assert_eq!(asked(&p(json!(1))), Some(WAIT_DEFAULT));
        assert_eq!(asked(&p(json!(false))), None);
        assert_eq!(asked(&p(json!({"v": 1, "waitMs": 90_000}))), Some(Duration::from_secs(90)));
        assert_eq!(
            asked(&p(json!({"v": 7, "waitMs": 1000, "later": "field"}))),
            Some(Duration::from_secs(1)),
            "a newer client's ask still bounds the wait"
        );
        assert_eq!(asked(&p(json!({"v": 0}))), None);
        let c = Config { wait: Duration::from_secs(300), per_host: 6 };
        assert_eq!(wait(Some(Duration::from_secs(60)), Some(c)), Some(Duration::from_secs(60)));
        assert_eq!(wait(Some(Duration::from_secs(900)), Some(c)), Some(c.wait));
        assert_eq!(wait(None, Some(c)), None, "an old client never waits");
        assert_eq!(wait(Some(Duration::from_secs(60)), None), None, "switch off: never waits");
        assert_eq!(wait(Some(Duration::ZERO), Some(c)), None);
    }

    #[test]
    fn spill_needs_room_known_not_a_pick_whose_resources_are_unknown() {
        // gcp-agent-lane-8, 2026-11-24: every over-cap create named a hub-only pick with no
        // reading, which kept the scale-up from ever running.
        let unknown = json!({"pick": "gcp-agent-lane-1", "overloaded": false, "room": null,
            "why": "gcp-agent-lane-1: resources unknown: only the mesh hub reaches it"});
        assert!(!known_room(&unknown, false));
        assert!(known_room(&json!({"pick": "big-red", "room": 3.0, "overloaded": false}), false));
        assert!(!known_room(&json!({"pick": "big-red", "room": 0.0}), false));
        assert!(!known_room(&json!({"pick": "big-red", "room": 3.0, "overloaded": true}), false));
        assert!(!known_room(
            &json!({"pick": "big-red", "room": 3.0, "shadow": {"would_defer": true}}),
            false
        ));
        assert!(!known_room(&json!({"pick": null, "error": "no candidates"}), false));
        // One lane per machine: a pick with room is no room while it holds a live session.
        let busy = json!({"pick": "e1", "room": 3.0, "hosts": [{"name": "e1", "live": 2}]});
        let empty = json!({"pick": "e1", "room": 3.0, "hosts": [{"name": "e1", "live": 0}]});
        assert!(known_room(&busy, false) && !known_room(&busy, true));
        assert!(known_room(&empty, true));
    }

    #[tokio::test(start_paused = true)]
    async fn spill_waits_for_the_new_host_to_join_within_its_bound() {
        let row = json!({"name": "gcp-agent-lane-e1", "connected": true, "state": "connected"});
        let joined_after = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let n = joined_after.clone();
        let rows = move || {
            let k = n.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if k >= 3 { vec![row.clone()] } else { vec![] }
        };
        assert!(wait_joined("gcp-agent-lane-e1", Duration::from_secs(60), JOIN_POLL, rows).await);
        let down = json!({"name": "gcp-agent-lane-e2", "connected": false});
        let start = tokio::time::Instant::now();
        let never = move || vec![down.clone()];
        assert!(!wait_joined("gcp-agent-lane-e2", Duration::from_secs(30), JOIN_POLL, never).await);
        assert!(start.elapsed() <= Duration::from_secs(31), "bounded: {:?}", start.elapsed());
    }

    #[test]
    fn spill_note_rides_on_the_placement_answer() {
        let a = json!({"sessionId": "s", "_meta": {"acpmux": {"placedOn": "e1",
            "placement": {"version": 1, "reason": "over-cap"}}}});
        let a = with_note(a, note("e1", true, Duration::from_millis(41_000)));
        assert_eq!(a.pointer("/_meta/acpmux/placement/spill/host"), Some(&json!("e1")));
        assert_eq!(a.pointer("/_meta/acpmux/placement/spill/waitedMs"), Some(&json!(41_000)));
        assert_eq!(a.pointer("/_meta/acpmux/placement/spill/v"), Some(&json!(VERSION)));
        let p = progress("waiting", None, WAIT_DEFAULT);
        assert!(p["text"].as_str().unwrap().starts_with("starting on a new host"));
    }
}
