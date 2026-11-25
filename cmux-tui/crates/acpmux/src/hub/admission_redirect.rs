//! A create this lane host has no room for starts on the peer the placement
//! engine picks (2026-11-24). 25 of 32 lane hosts ran past their
//! `lanes.max_lanes` (1,647 live sessions on about 300 slots): admission
//! (`admission.rs`) only warned and started each one here. Leo: "we can design
//! out hosts becoming overloaded by building and using our designs and
//! gradually migrating and testing and creating experiments and trialing as we
//! go in order to fan out", and "acpmux/cmux protocols need to be able to work
//! in lockstep with these".
//!
//! The lockstep: a daemon that can place lists [`CAPABILITY`] at `initialize`;
//! a client that can follow a placed create sends `_meta.acpmux.placeRedirect: 1`
//! ([`FIELD`]) on `session/new`; the create placed elsewhere answers with the
//! peer's session (its `peer`, the route the client already follows) and
//! `_meta.acpmux.placedOn` ([`PLACED_ON`]) with `_meta.acpmux.placement`
//! (`{version, reason, why, live, maxLanes}`). An old client sends no opt-in
//! and its create starts here, warned, as before; a new client facing an old
//! daemon sees no capability and sends none.
//!
//! A create moves only when every one of these holds ([`considered`]): the
//! caller asked; this machine has a `lanes` entry (a lane host); this host is at
//! its cap, or the shadow host-budget verdict for it would defer (full or busy,
//! `shadow_admission.rs`); the caller may learn this host's peers
//! (`Ask::local`, `Ask::peers`: never a Web client or a peer daemon's
//! connection); it is no person's own start; and `ACPMUX_PLACE_REDIRECT` is not
//! `0`. The request must carry only what a peer start carries the same way
//! ([`movable`]): no worktree, env, credential, ephemeral run, workspace,
//! adopt, successor or fixed id. The host is the one `placement::place` picks
//! from the connected peers' readings (the one engine `new --host auto` and the
//! cap warning use), never one whose shadow verdict would defer too.
//!
//! No start is ever dropped for a cap (Leo's C1): with no peer that has room,
//! or a forward that fails, the create starts here as before, warned, and the
//! scale-up trigger runs as before (`admission_scale_up.rs`). Each decision
//! logs one `admission-place {JSON}` line ([`LOG_PREFIX`]) with its `outcome`.

use super::admission::Ask;
use serde_json::{Value, json};

/// Listed at `initialize` by a daemon that places a create with no room here.
pub const CAPABILITY: &str = "place-redirect-v1";
/// `_meta.acpmux` key of `session/new`: the caller follows a create placed on a peer.
pub const FIELD: &str = "placeRedirect";
/// `_meta.acpmux` key of a placed create's answer: the peer it started on.
pub const PLACED_ON: &str = "placedOn";
/// `_meta.acpmux` key of a placed create's answer: why it moved.
pub const PLACEMENT: &str = "placement";
/// The answer's shape version.
pub const VERSION: u64 = 1;
/// Set to `0` to start every create here, warned, as before this module.
pub const OFF_ENV: &str = "ACPMUX_PLACE_REDIRECT";
/// The `tracing` message every decision line starts with.
pub const LOG_PREFIX: &str = "admission-place";

/// The `_meta.acpmux` keys a create may carry and still start on a peer: the ones
/// a `new --host` start carries the same way there (`peer_forward::strip_new_meta`
/// drops the lineage, `argv` and the prompt file text, which the CLI sends again).
const MOVABLE_META: &[&str] = &[
    "argv",
    "createKey",
    "disallowedTools",
    "effort",
    "forceAdmit",
    "harness",
    "ifNameTaken",
    "mode",
    "model",
    "name",
    "policy",
    "preset",
    "promptFileText",
    "tags",
    FIELD,
];

/// Why a create moved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Reason {
    /// At this host's `lanes.max_lanes`.
    OverCap,
    /// The shadow host-budget verdict for this host would defer.
    Busy,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::OverCap => "over-cap",
            Self::Busy => "busy",
        }
    }
}

/// Where admission placed a create, which the create starts there (`server/requests.rs`).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Placed {
    pub host: String,
    /// `placement::placed`'s "placed on NAME: ...".
    pub why: String,
    pub reason: Reason,
    pub live: usize,
    pub max: Option<u64>,
}

/// The acpmux tag every session `tools/idle_feeder.py` (leo-workspace) starts carries, as
/// `filler=true`: work that soaks up idle room, which a real start takes back.
pub(crate) const FILLER_TAG: &str = "filler";

/// Whether `session` is filler work (`FILLER_TAG`), whose room a real start takes: that start
/// stays here, never moved for it, and the filler is hibernated (`free_filler`).
pub(crate) fn is_filler(session: &super::Session) -> bool {
    session.read_meta(|m| m.tags.get(FILLER_TAG).is_some_and(|t| t.value == "true"))
}

/// Hands the room of filler session `id` to the real start that took it (`admission.rs`
/// `admit_new`): hibernated as `session pause` does (`pause.rs`), and when its turn holds it up,
/// that turn is stopped first (filler work is preemptible), then hibernated. In the background:
/// the start never waits for it. The filler resumes its conversation on its next prompt.
pub(crate) fn free_filler(hub: std::sync::Arc<super::Hub>, id: String, reason: Reason) {
    // The hub's scope owns it: a closing hub ends it.
    let owner = hub.clone();
    owner.scope.spawn_named("free-filler", async move {
        let Some(session) = hub.session_by_id(&id) else { return };
        let mut stopped = false;
        let mut last = String::new();
        for _ in 0..20 {
            match hub.pause(&session).await {
                Ok(v) if v.get("paused").and_then(Value::as_bool) == Some(true) => {
                    let how = if stopped { "stopped, then hibernated" } else { "hibernated" };
                    log("filler_hibernated", reason, None, Some(&format!("{id}: {how}")));
                    return;
                }
                // Already stopped or hibernated: its room is free.
                Ok(_) => return,
                Err(e) if !stopped => {
                    tracing::info!(session = %id, "filler busy ({}): turn stopped", e.message);
                    stopped = true;
                    if let Err(e) = hub.cancel(&session).await {
                        tracing::info!(session = %id, "filler stop: {}", e.message);
                    }
                }
                Err(e) => last = e.message,
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
        log("filler_not_freed", reason, None, Some(&format!("{id}: {last}")));
    });
}

/// Whether `params` asks to follow a placed create.
pub(crate) fn asked(params: &Value) -> bool {
    match params.pointer(&format!("/_meta/acpmux/{FIELD}")) {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_u64().is_some_and(|n| n >= 1),
        _ => false,
    }
}

/// Whether a create of `params` starts on a peer the same as here: asked, and
/// nothing in it ties it to this machine (module docs).
pub(crate) fn movable(params: &Value) -> bool {
    if !asked(params) {
        return false;
    }
    let top_ok = params
        .as_object()
        .is_some_and(|o| o.keys().all(|k| matches!(k.as_str(), "cwd" | "mcpServers" | "_meta")));
    let servers_ok = params
        .get("mcpServers")
        .is_none_or(|s| s.as_array().is_some_and(Vec::is_empty) || s.is_null());
    let meta = params.get("_meta").and_then(Value::as_object);
    let meta_ok = meta.is_none_or(|m| m.keys().all(|k| k == "acpmux"));
    let mux_ok = params
        .pointer("/_meta/acpmux")
        .and_then(Value::as_object)
        .is_none_or(|m| m.keys().all(|k| MOVABLE_META.contains(&k.as_str())));
    top_ok && servers_ok && meta_ok && mux_ok
}

fn off() -> bool {
    std::env::var(OFF_ENV).is_ok_and(|v| v.trim() == "0")
}

/// The reason to place a create elsewhere, when every gate holds (module docs):
/// `lane_host`, this machine has a `lanes` entry; `over`, at its cap; `busy`, its
/// shadow verdict would defer.
pub(crate) fn considered(ask: &Ask<'_>, lane_host: bool, over: bool, busy: bool) -> Option<Reason> {
    let reason = if over {
        Reason::OverCap
    } else if busy {
        Reason::Busy
    } else {
        return None;
    };
    (ask.redirect && lane_host && ask.local && ask.peers && !ask.person && !off()).then_some(reason)
}

/// Where the placement engine's `verdict` over the peers puts the create: its pick,
/// when one has room and its own shadow verdict would not defer.
pub(crate) fn pick(
    verdict: &Value,
    reason: Reason,
    live: usize,
    max: Option<u64>,
) -> Option<Placed> {
    let why = super::admission_scale_up::room_elsewhere(verdict)?;
    let host = verdict.get("pick").and_then(Value::as_str)?.to_owned();
    if verdict.pointer("/shadow/would_defer").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    Some(Placed { host, why, reason, live, max })
}

/// One decision's log line (module docs): `outcome` is `redirected`,
/// `local_no_room`, `local_forward_failed`, `local_not_asked` or `local_filler_room`.
pub(crate) fn log(
    outcome: &str,
    reason: Reason,
    host: Option<&str>,
    detail: Option<&str>,
) -> Value {
    let line = json!({
        "ts": crate::store::now_ms(),
        "outcome": outcome,
        "reason": reason.as_str(),
        "host": host,
        "detail": detail,
    });
    tracing::info!("{LOG_PREFIX} {line}");
    line
}

/// The request sent to `placed.host`: no folder of this machine (the peer picks
/// its own, as a `new --host` start with none), no opt-in, the peer named, and a
/// taken name suffixed there.
pub(crate) fn forwarded(params: &Value, placed: &Placed) -> Value {
    let mut p = params.clone();
    if let Some(o) = p.as_object_mut() {
        o.remove("cwd");
    }
    if let Some(m) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        m.remove(FIELD);
        m.insert("peer".into(), json!(placed.host));
        if m.contains_key("name") {
            m.insert("ifNameTaken".into(), json!(super::SUFFIX_TAKEN_NAME));
        }
    } else if let Some(o) = p.as_object_mut() {
        o.insert("_meta".into(), json!({"acpmux": {"peer": placed.host}}));
    }
    p
}

/// The placed create's answer: the peer's, with `placedOn` and `placement`.
pub(crate) fn answer(mut result: Value, placed: &Placed) -> Value {
    let note = json!({
        "version": VERSION,
        "reason": placed.reason.as_str(),
        "why": placed.why,
        "live": placed.live,
        "maxLanes": placed.max,
    });
    if let Some(o) = result.as_object_mut() {
        let meta = o.entry("_meta").or_insert_with(|| json!({}));
        if !meta.is_object() {
            *meta = json!({});
        }
        let mux = meta
            .as_object_mut()
            .map(|m| m.entry("acpmux").or_insert_with(|| json!({})))
            .filter(|m| m.is_object());
        if let Some(Value::Object(mux)) = mux {
            mux.insert(PLACED_ON.into(), json!(placed.host));
            mux.insert(PLACEMENT.into(), note);
        }
    }
    result
}

/// The text a create that could not move adds to its warning.
pub(crate) fn forward_failed(placed: &Placed, error: &str) -> String {
    format!("placing it on {} failed ({error}), so it started here.", placed.host)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ask(redirect: bool, person: bool, local: bool, peers: bool) -> Ask<'static> {
        Ask {
            force: false,
            can_force: true,
            person,
            name: None,
            who: "test",
            local,
            peers,
            redirect,
            auto: false,
            waiting: None,
            harness: None,
        }
    }

    #[test]
    fn only_an_asking_agent_caller_on_a_lane_host_with_no_room_moves() {
        let agent = ask(true, false, true, true);
        assert_eq!(considered(&agent, true, true, false), Some(Reason::OverCap));
        assert_eq!(considered(&agent, true, false, true), Some(Reason::Busy));
        assert_eq!(considered(&agent, true, false, false), None, "room here: it stays");
        assert_eq!(considered(&agent, false, true, true), None, "no lanes entry: not a lane host");
        assert_eq!(
            considered(&ask(false, false, true, true), true, true, false),
            None,
            "old client"
        );
        assert_eq!(considered(&ask(true, true, true, true), true, true, false), None, "a person");
        assert_eq!(considered(&ask(true, false, false, true), true, true, false), None, "Web");
        assert_eq!(considered(&ask(true, false, true, false), true, true, false), None, "a peer");
    }

    #[test]
    fn a_create_tied_to_this_machine_never_moves() {
        let plain = json!({"cwd": "/w", "mcpServers": [], "_meta": {"acpmux": {
            "name": "r", "harness": "codex", "createKey": "k", "argv": ["acpmux"], FIELD: 1,
        }}});
        assert!(asked(&plain));
        assert!(movable(&plain));
        let without = json!({"cwd": "/w", "_meta": {"acpmux": {"name": "r"}}});
        assert!(!asked(&without) && !movable(&without), "no opt-in: an old client");
        for key in
            ["worktree", "env", "ephemeral", "workspaceId", "adopt", "credentials", "reportTo"]
        {
            let mut p = plain.clone();
            p["_meta"]["acpmux"][key] = json!(true);
            assert!(!movable(&p), "{key} ties it here");
        }
        let mut servers = plain.clone();
        servers["mcpServers"] = json!([{"name": "x"}]);
        assert!(!movable(&servers), "an MCP server of this machine");
    }

    #[test]
    fn the_pick_must_have_room_and_no_shadow_defer() {
        let verdict = json!({"pick": "far", "why": "far: 4 cores free", "hosts": []});
        let room = |v: &Value| pick(v, Reason::OverCap, 13, Some(12));
        let p = room(&verdict).expect("a pick with room");
        assert_eq!((p.host.as_str(), p.why.as_str()), ("far", "placed on far: 4 cores free"));
        let full = json!({"pick": "far", "overloaded": true, "why": "every host is full"});
        assert_eq!(room(&full), None);
        let mut deferring = verdict.clone();
        deferring["shadow"] = json!({"would_defer": true});
        assert_eq!(room(&deferring), None);
    }

    #[test]
    fn the_forward_names_the_peer_and_keeps_no_folder_or_opt_in() {
        let placed = Placed {
            host: "far".into(),
            why: "placed on far".into(),
            reason: Reason::OverCap,
            live: 13,
            max: Some(12),
        };
        let p =
            json!({"cwd": "/here", "mcpServers": [], "_meta": {"acpmux": {"name": "r", FIELD: 1}}});
        let f = forwarded(&p, &placed);
        assert_eq!(f.get("cwd"), None);
        assert_eq!(f.pointer("/_meta/acpmux/peer"), Some(&json!("far")));
        assert_eq!(f.pointer(&format!("/_meta/acpmux/{FIELD}")), None);
        assert_eq!(
            f.pointer("/_meta/acpmux/ifNameTaken"),
            Some(&json!(super::super::SUFFIX_TAKEN_NAME))
        );
        let a = answer(json!({"sessionId": "s1", "peer": "far"}), &placed);
        assert_eq!(a.pointer("/_meta/acpmux/placedOn"), Some(&json!("far")));
        assert_eq!(a.pointer("/_meta/acpmux/placement/version"), Some(&json!(VERSION)));
        assert_eq!(a.pointer("/_meta/acpmux/placement/reason"), Some(&json!("over-cap")));
    }
}
