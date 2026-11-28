//! Part of `Hub`; see `hub/mod.rs`. Where a hibernated chat's wake should start it: RFD 0181 B6,
//! "activation is placement" (cmuxterm-hq `docs/rfd/0181-cluster-as-one-computer.md`, T7).
//!
//! Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I
//! put in fleet wide pauses, esp when this is stuff that materially improves the app".
//!
//! A wake starts the chat's agent on the machine it slept on (`idle.rs`), however full that
//! machine got while it slept: admission (`admission.rs`) checks creates only, and the rebalancer
//! leaves a chat idle past `awake_secs` "until it next wakes" (`rebalance.rs` `stays`). B6 makes
//! that wake a placement: a chat waking on a host past its `lanes.max_lanes` or held starts where
//! `placement::place` picks. Step 1 decides and counts; step 2 moves an agent's wake there
//! before its agent starts, behind `lane_overflow.rebalance` ([`act`], `server/wake_move.rs`).
//!
//! Every wake on a lane host logs one `wake-place {JSON}` line ([`LOG_PREFIX`]) before its agent
//! starts: this host's live chats besides the waking one (`live`), its cap (`max`), whether it is
//! past it (`pastCap`) or held (`held`), the host a move would take (`to`, the rebalancer's own
//! target rule over `place`'s verdict: room, not held, no person's machine), and why it stays when
//! it would (`stays`). Counting the lines with `pastCap` or `held` gives the RFD's measurement,
//! wakes onto past-cap or held hosts, before the move is built. Once it is built, the count of
//! those that also have a `to` must reach 0.
//!
//! What stays even where a move would help ([`decide`]): a chat pinned to this machine (its place
//! mode is not Auto: nothing moves unasked, `place_pin.rs`), a person's own wake (they are waiting
//! on it here), and a chat in a family (a family moves together, `rebalance.rs` `held`). The
//! decision is pure; [`Hub::wake_place`] reads the registry off the start path and only on a host
//! with a `lanes` entry, so a laptop or a host outside the fleet reads nothing.

use super::*;
use serde_json::{Value, json};

/// The `tracing` message every decision line starts with.
pub const LOG_PREFIX: &str = "wake-place";

/// What [`decide`] reads about the wake and this host.
#[derive(Clone, Debug, Default)]
pub(crate) struct Facts {
    /// This host's live chats besides the waking one (`admission.rs` `is_live`).
    pub live: usize,
    /// This host's `lanes.max_lanes`, as admission reads it; `None`: no cap.
    pub max: Option<u64>,
    /// Why the registry holds this host (`placement::held`).
    pub held: Option<String>,
    /// The chat's place mode is not Auto.
    pub pinned: bool,
    /// A person's prompt, typing or click woke it.
    pub person: bool,
    /// It has a parent or an open child.
    pub family: bool,
}

/// Where the wake should start the chat.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Decision {
    /// Waking here would take this host past its cap.
    pub past_cap: bool,
    /// The registry holds this host.
    pub held: bool,
    /// The host a move takes: pick's best target with room; `None`: it starts here.
    pub to: Option<String>,
    /// Why it starts here though this host is past its cap or held.
    pub stays: Option<&'static str>,
}

impl Decision {
    /// The wake lands where B6 says it should not: past the cap or held, and not moved.
    pub fn misplaced(&self) -> bool {
        (self.past_cap || self.held) && self.to.is_none()
    }
}

/// The decision for a wake on `here` with `facts`, from `verdict` (`placement::place` over the
/// connected peers) and the `registry`.
pub(crate) fn decide(
    facts: &Facts,
    verdict: &Value,
    registry: Option<&Value>,
    here: &str,
) -> Decision {
    let past_cap = facts.max.is_some_and(|max| facts.live as u64 >= max);
    let held = facts.held.is_some();
    let mut d = Decision { past_cap, held, to: None, stays: None };
    if !past_cap && !held {
        return d;
    }
    d.stays = if facts.pinned {
        Some("pinned to this machine")
    } else if facts.person {
        Some("a person's wake")
    } else if facts.family {
        Some("in a family: families move together")
    } else {
        None
    };
    if d.stays.is_none() {
        match crate::rebalance::targets(verdict, registry, here).into_iter().next() {
            Some(target) => d.to = Some(target.name),
            None => d.stays = Some("no other host has room"),
        }
    }
    d
}

/// The decision's log line.
pub(crate) fn line(session: &str, cause: Option<&str>, facts: &Facts, d: &Decision) -> Value {
    json!({
        "ts": crate::store::now_ms(),
        "session": session,
        "cause": cause,
        "live": facts.live,
        "max": facts.max,
        "pastCap": d.past_cap,
        "held": d.held,
        "to": d.to,
        "stays": d.stays,
    })
}

/// What a wake does with its [`Decision`] (step 2): with the registry's
/// `lane_overflow.rebalance` on for this host (`rebalance::Conf::on_for`; absent: off), a wake
/// that has a `to` moves there before its agent starts (`server/wake_move.rs`); otherwise it
/// starts here, as in step 1.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Action {
    Move(String),
    Here(&'static str),
}

pub(crate) fn act(d: &Decision, on: bool) -> Action {
    match &d.to {
        None => Action::Here(d.stays.unwrap_or("fits here")),
        Some(_) if !on => Action::Here("lane_overflow.rebalance is off for this host"),
        Some(to) => Action::Move(to.clone()),
    }
}

/// The wake cause of a prompt with `provenance` when an agent or the daemon sent it
/// (`idle_governor.rs` `prompt_wake_cause`); `None` for one that names no sender this knows,
/// which may be a person's and so never moves.
pub(crate) fn agent_wake_cause(provenance: Option<&Value>) -> Option<&'static str> {
    let cause = super::idle_governor::prompt_wake_cause(false, provenance);
    (cause != "prompt").then_some(cause)
}

/// A wake the decision moves (`Hub::wake_move_plan`): where to, and the chat's ownership epoch
/// when it was decided (every move bumps it, `session.rs`; the move's fence, `server/wake_move.rs`).
pub(crate) struct MovePlan {
    pub session: Arc<Session>,
    pub to: String,
    pub epoch: u64,
    pub line: Value,
}

impl Hub {
    /// The wake decision for `session`, logged (module docs); `None` on a host with no `lanes`
    /// entry, or when the registry cannot be read. Called only when the start is a wake.
    pub(super) async fn wake_place(&self, session: &Arc<Session>) -> Option<Decision> {
        let cause = *session.wake_cause.lock().unwrap_or_else(|e| e.into_inner());
        let (facts, d, _) = self.wake_read(session, cause).await?;
        let line = line(&session.id, cause, &facts, &d);
        if d.misplaced() {
            tracing::warn!("{LOG_PREFIX} {line}");
        } else {
            tracing::info!("{LOG_PREFIX} {line}");
        }
        Some(d)
    }

    /// Before a prompt with `cause` (an agent's: `idle_governor.rs` `prompt_wake_cause`) wakes
    /// the hibernated chat `key`: the move its wake should make, when the decision has a `to`
    /// and the switch is on ([`act`]). `None`: it wakes here, and `wake_place` logs that start.
    /// Reads nothing for a chat that is awake, closed, moving or moved.
    pub(crate) async fn wake_move_plan(&self, key: &str, cause: &'static str) -> Option<MovePlan> {
        let session = self.resolve(key).ok()?;
        if !self.waking(&session)
            || session.status() == SessionStatus::Closed
            || session.moving().is_some()
            || session.read_meta(|m| m.moved_to.is_some())
        {
            return None;
        }
        let epoch = session.ownership_epoch();
        let (facts, d, on) = self.wake_read(&session, Some(cause)).await?;
        let Action::Move(to) = act(&d, on) else { return None };
        let line = line(&session.id, Some(cause), &facts, &d);
        Some(MovePlan { session, to, epoch, line })
    }

    /// What `decide` reads for a wake of `session` by `cause`, its decision, and whether the
    /// registry's `lane_overflow.rebalance` is on for this host.
    async fn wake_read(
        &self,
        session: &Arc<Session>,
        cause: Option<&'static str>,
    ) -> Option<(Facts, Decision, bool)> {
        let read = tokio::task::spawn_blocking(|| {
            let (source, set) = super::admission::registry_source();
            let (registry, _) = super::admission::read_registry(&source, set);
            let registry = registry?;
            let origin = std::env::var("FLEET_ORIGIN").ok();
            let machine = super::admission::machine_of(
                &registry,
                origin.as_deref(),
                super::start_gate::host_label(),
            )?;
            let max = super::admission::max_lanes(&registry, &machine)?;
            let hosted = Hub::live_host_sessions();
            Some((registry, machine, max, hosted))
        });
        let (registry, machine, max, hosted) = read.await.ok()??;
        let others: Vec<Arc<Session>> = self
            .sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .filter(|s| s.id != session.id)
            .cloned()
            .collect();
        let live = others
            .iter()
            .filter(|s| super::admission::is_live(s.status(), hosted.contains(&s.id)))
            .filter(|s| !super::admission_redirect::is_filler(s))
            .count();
        // A family as the rebalancer reads it: an agent started it, or it has an open child.
        let parent = session.read_meta(|m| m.lineage.is_some());
        let children = others.iter().any(|s| {
            s.status() != SessionStatus::Closed
                && s.read_meta(|m| m.lineage.as_ref().is_some_and(|l| l.parent == session.id))
        });
        let facts = Facts {
            live,
            max: Some(max),
            held: crate::placement::held(Some(&registry), &machine),
            pinned: !matches!(self.place_mode_of(session), crate::place_mode::PlaceMode::Auto),
            person: matches!(cause, Some("person" | "typing" | "click")),
            family: parent || children,
        };
        let verdict = if facts.max.is_some_and(|m| live as u64 >= m) || facts.held.is_some() {
            self.peer_verdict(Some(&registry))
        } else {
            Value::Null
        };
        let d = decide(&facts, &verdict, Some(&registry), &machine);
        let on = crate::rebalance::conf(Some(&registry)).on_for(&machine);
        Some((facts, d, on))
    }
}

#[cfg(test)]
#[path = "wake_place_tests.rs"]
mod tests;
