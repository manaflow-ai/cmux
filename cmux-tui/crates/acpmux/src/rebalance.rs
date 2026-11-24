//! The lane rebalancer's decisions (`acpmux session rebalance`, `cli/run/rebalance.rs`): which
//! of this host's chats leave when it holds more live sessions than its `lanes.max_lanes`, and
//! where each goes. Pure, so its tests judge every case without a daemon.
//!
//! Leo, 2026-11-24 22:40Z: "well we have infinite gcp/freestyle capabilities. plus our speedup
//! optimizations. so". That day gcp-agent-lane-13 held 11 live sessions against a cap of 6 and
//! gcp-agent-lane-8 21 against 6: admission (`hub/admission.rs`) only warns, and a session placed
//! well when it started stays where it started however full its host gets.
//!
//! A pass: this host's live sessions (`counts_live`: running, ready or waiting, not filler, a
//! peer's never) against its cap. Past it, the excess leaves, at most `max_moves` a pass, and
//! only sessions at a turn boundary that hold nothing (`held`): ready with no turn, nothing
//! queued, no pending permission or ask, not starting, not being moved or moved, no person's
//! hold, not shown in a client, no parent or open child (a family stays together), idle for
//! `min_idle_secs`, and no work below it (`workingBelow`, which `Hub::holds_work_below_read`
//! fills; it covers the adaptive policy's `idle_holds_work` and more). Longest idle first.
//!
//! Old daemon, new client: a row's `workingBelow` is omitted when false only by a daemon that
//! lists `session-idle-facts-v1` (`capabilities.rs`). From any other daemon an absent field is
//! unknown, so no row of it moves. A row missing `queued` or `pendingPermissions` (an older
//! shape) is unknown too, never read as zero.
//!
//! Where: `_acpmux/place`'s hosts (`placement::place`) that are not this one, not refused, not a
//! person's machine or a last resort (`placement::auto_move_refusal`), not held
//! (`placement::held`), with room for one more lane; the most room first, each move taking one
//! lane of its target's room so a pass spreads. With no host that has room, the excess that
//! found none is `spill`: the caller asks the fleet for a fresh machine (`lane_overflow.providers`,
//! `hub/admission_scale_up.rs`), and the next pass moves to it once it is connected.
//!
//! Every move leaves a receipt ([`SCHEMA`], version [`VERSION`]) whose undo is the move back
//! (`acpmux session rebalance --undo ID`). A receipt of a later version is refused by an older
//! reader, never half read. The registry switch `lane_overflow.rebalance.enabled` (absent: off)
//! decides whether a pass moves anything; with it off a pass only plans (`--force` acts anyway,
//! on one person's or agent's say).

use serde_json::{Value, json};

/// A receipt's and a pass record's schema name.
pub const SCHEMA: &str = "acpmux-rebalance/v1";
/// The receipt shape version this build writes and reads.
pub const VERSION: u64 = 1;
/// The registry's switch and its settings: `{enabled, max_moves, min_idle_secs}`.
pub const SWITCH: &str = "/lane_overflow/rebalance";
/// Moves a pass makes at most, by default.
pub const MAX_MOVES: usize = 4;
/// How long a session must have been idle to move, by default: one that just ended a turn is
/// likely to be prompted again soon.
pub const MIN_IDLE_SECS: u64 = 300;
/// The capability with which an absent `workingBelow` means false.
pub const IDLE_FACTS: &str = crate::capabilities::SESSION_IDLE_FACTS;

/// The registry's `lane_overflow.rebalance`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Conf {
    pub enabled: bool,
    pub max_moves: usize,
    pub min_idle_secs: u64,
}

impl Default for Conf {
    fn default() -> Self {
        Conf { enabled: false, max_moves: MAX_MOVES, min_idle_secs: MIN_IDLE_SECS }
    }
}

/// `lane_overflow.rebalance` over the defaults. Off unless `enabled` is `true`.
pub fn conf(registry: Option<&Value>) -> Conf {
    let mut c = Conf::default();
    let Some(spec) = registry.and_then(|r| r.pointer(SWITCH)) else { return c };
    c.enabled = spec.get("enabled").and_then(Value::as_bool) == Some(true);
    if let Some(n) = spec.get("max_moves").and_then(Value::as_u64) {
        c.max_moves = n as usize;
    }
    if let Some(n) = spec.get("min_idle_secs").and_then(Value::as_u64) {
        c.min_idle_secs = n;
    }
    c
}

fn local(row: &Value) -> bool {
    row.get("peer").is_none_or(Value::is_null)
}

fn status(row: &Value) -> &str {
    row.get("status").and_then(Value::as_str).unwrap_or("")
}

/// Whether `row` is filler (idle_feeder's `filler=true` tag): work that runs only on spare room,
/// never counted against the cap (`admission_redirect::is_filler`) and never moved for it.
pub fn is_filler(row: &Value) -> bool {
    row.pointer("/tags/filler").and_then(Value::as_str) == Some("true")
}

/// Whether `row` takes one of this host's lanes: a local session whose harness runs (running,
/// ready or waiting), filler left out.
pub fn counts_live(row: &Value) -> bool {
    local(row) && matches!(status(row), "running" | "ready" | "waiting") && !is_filler(row)
}

fn set(row: &Value, key: &str) -> bool {
    row.get(key).is_some_and(|v| match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_u64() != Some(0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(_) => true,
    })
}

/// `updatedAt` in ms (a value in seconds, from an older shape, is scaled).
fn updated_ms(row: &Value) -> Option<u64> {
    let v = row.get("updatedAt").and_then(Value::as_u64)?;
    Some(if v < 100_000_000_000 { v.saturating_mul(1000) } else { v })
}

/// Why `row`, a live local session, stays where it is this pass; `None`: it may move.
/// `idle_facts`: its daemon lists [`IDLE_FACTS`].
pub fn held(row: &Value, idle_facts: bool, now_ms: u64, min_idle_ms: u64) -> Option<&'static str> {
    if !local(row) {
        return Some("a peer's session");
    }
    if is_filler(row) {
        return Some("filler");
    }
    if status(row) != "ready" {
        return Some("not at a turn boundary (status is not ready)");
    }
    if set(row, "turn") {
        return Some("a turn runs");
    }
    let (Some(queued), Some(asks)) = (
        row.get("queued").and_then(Value::as_u64),
        row.get("pendingPermissions").and_then(Value::as_u64),
    ) else {
        return Some("its queue or permissions are unknown (an older daemon's row)");
    };
    if queued > 0 {
        return Some("prompts are queued");
    }
    if asks > 0 || set(row, "waitingOn") {
        return Some("it waits on a person");
    }
    match row.get("workingBelow") {
        Some(Value::Bool(true)) => return Some("work runs below it"),
        Some(Value::Bool(false)) => {}
        _ if idle_facts => {}
        _ => return Some("work below it is unknown (its daemon predates session-idle-facts-v1)"),
    }
    if set(row, "starting") {
        return Some("it is starting");
    }
    if set(row, "moving") || set(row, "movedTo") {
        return Some("it is being moved or moved already");
    }
    if set(row, "personHold") {
        return Some("a person holds it");
    }
    if set(row, "shown") {
        return Some("a client shows it");
    }
    if set(row, "parent") || set(row, "children") {
        return Some("it is in a family (a parent or an open child): families move together");
    }
    let Some(at) = updated_ms(row) else {
        return Some("its last activity is unknown");
    };
    if now_ms.saturating_sub(at) < min_idle_ms {
        return Some("active lately (under min_idle_secs)");
    }
    None
}

/// A host that may take a moved session, and its room in lanes.
#[derive(Clone, Debug, PartialEq)]
pub struct Target {
    pub name: String,
    pub room: f64,
}

/// The hosts of a `_acpmux/place` verdict that may take a session from `here`: not this one, not
/// refused, not a person's or a last-resort machine, not held, with room for a lane. Most room
/// first, then the verdict's order.
pub fn targets(verdict: &Value, registry: Option<&Value>, here: &str) -> Vec<Target> {
    let here = crate::placement::canonical(here);
    let mut out: Vec<Target> = verdict
        .get("hosts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|h| h.get("local").and_then(Value::as_bool) != Some(true))
        .filter(|h| h.get("refused").is_none_or(Value::is_null))
        .filter_map(|h| {
            let name = h.get("name").and_then(Value::as_str)?;
            let room = h.get("room").and_then(Value::as_f64)?;
            (room >= 1.0
                && crate::placement::canonical(name) != here
                && crate::placement::auto_move_refusal(registry, name).is_none()
                && crate::placement::held(registry, name).is_none())
            .then(|| Target { name: name.to_owned(), room })
        })
        .collect();
    out.sort_by(|a, b| b.room.partial_cmp(&a.room).unwrap_or(std::cmp::Ordering::Equal));
    out
}

/// One session a pass moves, and where.
#[derive(Clone, Debug, PartialEq)]
pub struct Move {
    pub session_id: String,
    pub name: String,
    pub target: String,
}

/// A pass's decision.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Plan {
    /// This host's live sessions and its cap (`None`: no `lanes.max_lanes`, never over).
    pub live: usize,
    pub cap: Option<u64>,
    /// Live past the cap.
    pub excess: usize,
    pub moves: Vec<Move>,
    /// Sessions over the cap that could move but found no host with room: a fresh machine's worth.
    pub spill: usize,
    /// Each live session that stays, and why (only while over the cap).
    pub held: Vec<(String, &'static str)>,
    pub why: String,
}

impl Plan {
    pub fn to_json(&self) -> Value {
        json!({
            "schema": SCHEMA, "version": VERSION, "live": self.live, "cap": self.cap,
            "excess": self.excess, "spill": self.spill, "why": self.why,
            "moves": self.moves.iter().map(|m| json!({"sessionId": m.session_id, "name": m.name,
                "target": m.target})).collect::<Vec<_>>(),
            "held": self.held.iter().map(|(id, why)| json!({"sessionId": id, "why": why}))
                .collect::<Vec<_>>(),
        })
    }
}

/// The pass for this host's session `rows` (the local list), its daemon listing [`IDLE_FACTS`]
/// or not, its `cap`, and the `targets` that may take a session.
pub fn plan(
    rows: &[Value],
    idle_facts: bool,
    cap: Option<u64>,
    mut targets: Vec<Target>,
    conf: &Conf,
    now_ms: u64,
) -> Plan {
    let live: Vec<&Value> = rows.iter().filter(|r| counts_live(r)).collect();
    let mut p = Plan { live: live.len(), cap, ..Plan::default() };
    let Some(cap) = cap else {
        p.why = "no lanes.max_lanes for this host: never over".into();
        return p;
    };
    p.excess = live.len().saturating_sub(cap as usize);
    if p.excess == 0 {
        p.why = format!("{} live, at or under its cap of {cap}", live.len());
        return p;
    }
    let min_idle_ms = conf.min_idle_secs.saturating_mul(1000);
    let mut movable: Vec<&Value> = Vec::new();
    for r in &live {
        let id = r.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned();
        match held(r, idle_facts, now_ms, min_idle_ms) {
            Some(why) => p.held.push((id, why)),
            None => movable.push(r),
        }
    }
    // Longest idle first: the least likely to be prompted while it moves.
    movable.sort_by_key(|r| updated_ms(r).unwrap_or(u64::MAX));
    let want = p.excess.min(conf.max_moves);
    for r in movable.into_iter().take(want) {
        let Some(t) = targets.iter_mut().find(|t| t.room >= 1.0) else {
            p.spill += 1;
            continue;
        };
        t.room -= 1.0;
        let id = r.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned();
        let name = r.get("name").and_then(Value::as_str).unwrap_or(&id).to_owned();
        p.moves.push(Move { session_id: id, name, target: t.name.clone() });
    }
    p.why = format!(
        "{} live over its cap of {cap}: {} to move (at most {} a pass), {} with no host that has \
         room, {} held",
        live.len(),
        p.moves.len(),
        conf.max_moves,
        p.spill,
        p.held.len()
    );
    p
}

/// What one move did, as its receipt records it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Done {
    pub source: String,
    pub session_id: String,
    pub name: String,
    pub target: String,
    /// Where it is now (`movedTo`): the target's host and session id; `None` when it failed.
    pub there: Option<(String, String)>,
    pub error: Option<String>,
    /// The move's wall time: the longest the session could not take a prompt.
    pub unavailable_ms: u64,
    /// The receipt this one undoes, for a move back.
    pub undoes: Option<String>,
}

/// A move's receipt: one JSON line in the rebalance log.
pub fn receipt(id: &str, at_ms: u64, d: &Done, why: &str) -> Value {
    json!({
        "schema": SCHEMA, "version": VERSION, "kind": if d.undoes.is_some() { "undo" } else { "move" },
        "id": id, "atMs": at_ms, "source": d.source, "sessionId": d.session_id, "name": d.name,
        "target": d.target, "ok": d.error.is_none(),
        "there": d.there.as_ref().map(|(h, s)| json!({"host": h, "sessionId": s})),
        "error": d.error, "unavailableMs": d.unavailable_ms, "undoes": d.undoes, "why": why,
        "undo": d.error.is_none().then(|| format!("acpmux session rebalance --undo {id}")),
    })
}

/// The move back a receipt's undo makes: `(host, session id there)`, brought back here.
pub fn undo_of(receipt: &Value) -> Result<(String, String), String> {
    if receipt.get("schema").and_then(Value::as_str) != Some(SCHEMA) {
        return Err("not a rebalance receipt".into());
    }
    match receipt.get("version").and_then(Value::as_u64) {
        Some(v) if v <= VERSION => {}
        Some(v) => {
            return Err(format!(
                "receipt version {v} is newer than this acpmux reads ({VERSION}): undo it with \
                 the acpmux that wrote it"
            ));
        }
        None => return Err("the receipt has no version".into()),
    }
    if receipt.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err("that move did not happen: nothing to undo".into());
    }
    let host = receipt.pointer("/there/host").and_then(Value::as_str);
    let id = receipt.pointer("/there/sessionId").and_then(Value::as_str);
    match (host, id) {
        (Some(h), Some(s)) if !h.is_empty() && !s.is_empty() => Ok((h.to_owned(), s.to_owned())),
        _ => Err("the receipt names no host and session there".into()),
    }
}

/// Where a finished `session move --json` says the chat went: `(host, session id)`.
pub fn moved_to(out: &Value) -> Option<(String, String)> {
    let row = out
        .get("moved")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
        .or_else(|| out.get("results").and_then(Value::as_array).and_then(|a| a.first()))
        .unwrap_or(out);
    let host = row
        .get("host")
        .or_else(|| row.pointer("/movedTo/host"))
        .or_else(|| row.get("target"))
        .and_then(Value::as_str)?;
    let id = row
        .get("there")
        .or_else(|| row.pointer("/movedTo/sessionId"))
        .or_else(|| row.get("thereId"))
        .and_then(Value::as_str)?;
    Some((host.to_owned(), id.to_owned()))
}

#[cfg(test)]
#[path = "rebalance_tests.rs"]
mod tests;
