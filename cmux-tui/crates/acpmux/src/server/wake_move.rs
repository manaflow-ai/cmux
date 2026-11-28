//! An agent's wake moves before it starts: RFD 0181 B6 step 2, "activation is placement"
//! (cmuxterm-hq `docs/rfd/0181-cluster-as-one-computer.md`, T7).
//!
//! Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I
//! put in fleet wide pauses, esp when this is stuff that materially improves the app".
//!
//! Step 1 (`hub/wake_place.rs`) decides where a hibernated chat's wake should start and logs it.
//! This moves it there: a `session/prompt` from an agent or the daemon (its provenance names
//! the sender, `wake_place::agent_wake_cause`; a prompt that names none may be a person's and
//! never moves) for a hibernated chat whose decision has a `to`, with the registry's
//! `lane_overflow.rebalance` on for this host (absent: off, `rebalance.rs` `Conf::on_for`), runs
//! the move before the prompt reaches the chat: `acpmux session move --carry-changes`
//! (`place_set.rs` `move_for_wake`), which carries the chat's queue in its bundle
//! (`hub/transfer_out.rs`). Nothing of the chat runs yet, so the move takes no turn lock a
//! start holds. Once it committed, the prompt goes on to the copy there as any request for a
//! moved chat does (`peer_forward.rs` `MOVED_FORWARDED`; the outbox follows `transfer.moved`).
//!
//! The fence (G9): the plan holds the chat's ownership epoch it was decided at (every move bumps
//! it); a plan whose chat moved meanwhile is stale and moves nothing. One wake's move runs at a
//! time per chat ([`gate`]): a second prompt waits for it, then finds the chat moved (forwarded)
//! or awake (it starts here). A chat the move left mid-way (`moving`) stays frozen, so neither
//! side starts it until the move commits or aborts (`transfer_watch.rs`): it never starts twice.
//!
//! The deadline (G2): [`LIMIT`] bounds the move on its own clock, apart from the prompt's
//! admission pacing (`prompt_admission.rs`, which never runs while the move does) and from a
//! pick's 30-minute move bound. A move that fails or runs past it writes its failed line, logs
//! `wake-move` at warn, and the prompt wakes the chat here as before.

use crate::hub::Hub;
use crate::hub::wake_place::MovePlan;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How long a wake waits for its move before it starts here instead.
pub(super) const LIMIT: Duration = Duration::from_secs(120);
/// The `tracing` message every move line starts with.
pub const LOG_PREFIX: &str = "wake-move";

/// Where a wake's move left the chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Landed {
    /// Committed: the prompt follows the chat.
    Moved,
    /// Under way still (frozen here): the prompt answers `transfer.moving`.
    Moving,
    /// Not moved: the prompt wakes it here.
    Here,
}

pub(super) fn landed(moved_to: bool, moving: bool) -> Landed {
    match (moved_to, moving) {
        (true, _) => Landed::Moved,
        (false, true) => Landed::Moving,
        (false, false) => Landed::Here,
    }
}

/// Whether a plan decided at `planned` may still move a chat now at `now`.
pub(super) fn fresh(planned: u64, now: u64) -> bool {
    planned == now
}

/// The per-chat gate one wake's move holds.
fn gate(id: &str) -> Arc<tokio::sync::Mutex<()>> {
    static GATES: std::sync::OnceLock<Mutex<BTreeMap<String, Arc<tokio::sync::Mutex<()>>>>> =
        std::sync::OnceLock::new();
    let mut all = GATES.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
    // Gates nobody holds or waits on go, so the map holds only chats being woken.
    all.retain(|_, g| Arc::strong_count(g) > 1);
    all.entry(id.to_owned()).or_default().clone()
}

/// Before `session/prompt` `params` reaches its chat here (module docs). Returns when the chat
/// moved (the caller forwards), or when it starts here.
pub(super) async fn before_prompt(hub: &Arc<Hub>, params: &Value) {
    let Ok(key) = super::session_key(params) else { return };
    let provenance = params.pointer("/_meta/acpmux/provenance");
    let Some(cause) = crate::hub::wake_place::agent_wake_cause(provenance) else { return };
    let Ok(session) = hub.resolve(key) else { return };
    let gate = gate(&session.id);
    let _held = gate.lock().await;
    let Some(plan) = hub.wake_move_plan(&session.id, cause).await else { return };
    run(hub, plan).await;
}

async fn run(hub: &Arc<Hub>, plan: MovePlan) {
    let MovePlan { session, to, epoch, mut line } = plan;
    let now = session.ownership_epoch();
    if !fresh(epoch, now) {
        tracing::info!(session = %session.id, epoch, now, "{LOG_PREFIX}: stale plan, nothing moved");
        return;
    }
    let started = std::time::Instant::now();
    let outcome = super::place_set::move_for_wake(hub, &session, &to, LIMIT).await;
    let landed = landed(session.meta().moved_to.is_some(), session.moving().is_some());
    if let Some(o) = line.as_object_mut() {
        o.insert("move".into(), json!(to));
        o.insert("landed".into(), json!(format!("{landed:?}").to_lowercase()));
        o.insert("tookMs".into(), json!(started.elapsed().as_millis() as u64));
        o.insert("error".into(), json!(outcome.as_ref().err()));
        o.insert("limitSecs".into(), json!(LIMIT.as_secs()));
    }
    if landed == Landed::Moved {
        tracing::info!("{LOG_PREFIX} {line}");
    } else {
        tracing::warn!("{LOG_PREFIX} {line}");
    }
}

#[cfg(test)]
#[path = "wake_move_tests.rs"]
mod tests;
