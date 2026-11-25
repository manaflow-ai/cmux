//! Part of `Hub`; see `hub/mod.rs`. Idle chats leave this machine on their own while it stays
//! over its budget (Leo: "if my computer is too under load, go distribute the sessions into
//! other vms and whatnot").
//!
//! Off unless `autoEvacuate.enabled` is true (`config/auto_evacuate.rs`). Off runs no timer at
//! all; on runs one ([`Hub::start_auto_evacuate`], at start and on each config reload), which
//! ends at the first tick that reads it off, or when the daemon stops.
//!
//! Every [`TICK`] the timer reads this host's budget ([`crate::host_pressure::Meter`], the
//! sampler `daemon status` reads), turns it into a level that does not flicker
//! ([`crate::host_pressure::Tracker`]) and asks `cmux_host_budget::evacuate::evacuate_plan`
//! which chats go. The chats are listed only when that says so. Each one chosen gets a visible
//! `auto_evacuate` note in its history first (it travels with the chat: why it moved, how to
//! bring it back), then moves through `session move ID --host auto`'s own steps
//! (`cli/run/session_move.rs` `move_auto`, over this daemon's own socket), and one log line
//! says how it went. A move that fails leaves the chat here as it was, with a second note.
//! Moves run one after another inside the tick, so ticks never overlap.

use super::*;
use crate::host_pressure::{Reading, Tracker};
use cmux_host_budget::evacuate::{Candidate, Hysteresis, Plan, Setting, evacuate_plan};
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;

/// How often the timer looks. The meter samples at most every 3 s; the plan holds two minutes
/// before anything moves, so a tick every 15 s is precise enough and costs one read.
pub(crate) const TICK: std::time::Duration = std::time::Duration::from_secs(15);

/// The longest one automatic move may take before the timer gives it up and goes on.
const MOVE_BOUND: std::time::Duration = std::time::Duration::from_secs(20 * 60);

/// The note's kind in a chat's history.
pub(crate) const NOTE_KIND: &str = "auto_evacuate";

/// Whether the timer runs (one per daemon).
static RUNNING: AtomicBool = AtomicBool::new(false);

type Boxed<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// This host's budget reading, `None` when none was read.
pub(crate) trait BudgetSource: Send + Sync {
    fn read(&self) -> Boxed<'_, Option<Reading>>;
}

/// Moves one chat off this machine; `Ok`: the machine it went to.
pub(crate) trait Mover: Send + Sync {
    fn move_off<'a>(&'a self, id: &'a str) -> Boxed<'a, Result<String, String>>;
}

/// The daemon's budget: the shared meter.
struct MeterSource;

impl BudgetSource for MeterSource {
    fn read(&self) -> Boxed<'_, Option<Reading>> {
        Box::pin(async {
            crate::host_pressure::Meter::shared().current().await.map(|v| Reading::from(&v))
        })
    }
}

/// The daemon's mover: `session move ID --host auto`'s steps, driven over this daemon's own
/// socket, exactly as the CLI drives them.
struct SessionMove;

impl Mover for SessionMove {
    fn move_off<'a>(&'a self, id: &'a str) -> Boxed<'a, Result<String, String>> {
        Box::pin(async move {
            let socket = crate::config::socket_path();
            let client = crate::client::Client::connect_without_caller(&socket)
                .await
                .map_err(|e| format!("this daemon's socket: {e:#}"))?;
            let moved =
                tokio::time::timeout(MOVE_BOUND, crate::cli::run::move_auto(&client, id, false))
                    .await
                    .map_err(|_| {
                        format!("the move took longer than {} min", MOVE_BOUND.as_secs() / 60)
                    })?
                    .map_err(|e| format!("{e:#}"))?;
            Ok(moved.host)
        })
    }
}

/// What the timer keeps between ticks.
#[derive(Default)]
pub(crate) struct Evacuator {
    tracker: Tracker,
    state: Hysteresis,
    /// When each chat (by id and by name, so one brought back under a new id counts) was last
    /// moved or tried, in hub-clock ms. Entries past the cooldown are dropped each tick.
    moved: HashMap<String, u64>,
}

impl Evacuator {
    /// One tick: read the level, plan, and carry out the plan's moves.
    pub(crate) async fn tick(
        &mut self,
        hub: &Hub,
        reading: Option<Reading>,
        mover: &dyn Mover,
    ) -> Plan {
        let (setting, keep) = {
            let cfg = hub.config.read().await;
            (cfg.auto_evacuate.setting(), cfg.auto_evacuate.keep.clone())
        };
        let level = reading.map(|r| {
            self.tracker.feed(&r);
            self.tracker.level()
        });
        let now = hub.clock_now() / 1_000_000;
        let cooldown_ms = setting.cooldown_secs.saturating_mul(1000);
        self.moved.retain(|_, at| now.saturating_sub(*at) < cooldown_ms);
        let moved = &self.moved;
        let plan = evacuate_plan(
            &mut self.state,
            level,
            || hub.evacuate_candidates(&keep, moved),
            &setting,
            now,
        );
        for m in &plan.moves {
            self.moved.insert(m.id.clone(), now);
            self.moved.insert(m.name.clone(), now);
            hub.evacuate_one(m, &plan, &setting, mover).await;
        }
        plan
    }
}

impl Hub {
    /// Starts the timer when `autoEvacuate.enabled` is on and none runs (module docs).
    pub(crate) async fn start_auto_evacuate(self: &Arc<Self>) {
        if !self.config.read().await.auto_evacuate.enabled {
            return;
        }
        if RUNNING.swap(true, Ordering::SeqCst) {
            return;
        }
        tracing::info!(
            "autoEvacuate is on: idle chats leave this machine while it stays over budget"
        );
        let weak = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("auto-evacuate", async move {
            auto_evacuate_loop(weak, &MeterSource, &SessionMove).await;
            RUNNING.store(false, Ordering::SeqCst);
        });
    }

    /// The live chats here as the plan reads them: one pass.
    fn evacuate_candidates(&self, keep: &[String], moved: &HashMap<String, u64>) -> Vec<Candidate> {
        self.live_session_handles()
            .iter()
            .filter(|s| s.moving().is_none())
            .filter_map(|s| {
                let (name, gone) = s.read_meta(|m| (m.name.clone(), m.moved_to.is_some()));
                if gone {
                    return None;
                }
                let running = s.turn().is_some() || s.turn_claimed() || s.queued() > 0;
                let moved_at = moved.get(&s.id).or_else(|| moved.get(&name)).copied();
                Some(Candidate {
                    id: s.id.clone(),
                    kept: keep.iter().any(|k| k == &name),
                    name,
                    idle_since_ms: s.last_active.load(Ordering::Relaxed) / 1_000_000,
                    running,
                    attended: self.attended(s),
                    moved_at_ms: moved_at,
                })
            })
            .collect()
    }

    /// The note, the move, and the log line for one chat the plan chose.
    async fn evacuate_one(
        &self,
        m: &cmux_host_budget::evacuate::Move,
        plan: &Plan,
        setting: &Setting,
        mover: &dyn Mover,
    ) {
        let session = self.session_get(&m.id);
        let Some(session) = session else { return };
        let idle_min = m.idle_ms / 60_000;
        let back = format!("cmux move {} --from MACHINE --to here", m.name);
        let text = format!(
            "Moved off this machine automatically: {} and this chat was idle for {idle_min} min. \
             To bring it back, run `{back}` with the machine it runs on now; to keep a chat here, \
             add its name to autoEvacuate.keep.",
            plan.why
        );
        self.append(
            &session,
            "mux",
            NOTE_KIND,
            json!({"text": text, "why": plan.why, "idleMs": m.idle_ms, "back": back,
                   "cooldownSecs": setting.cooldown_secs}),
        );
        match mover.move_off(&m.id).await {
            Ok(host) => tracing::info!(
                session = %m.id, name = %m.name, to = %host, idle_min, why = %plan.why,
                back = %format!("cmux move {} --from {host} --to here", m.name),
                "autoEvacuate: moved an idle chat off this over-budget machine"
            ),
            Err(why_not) => {
                tracing::warn!(
                    session = %m.id, name = %m.name, idle_min, why = %plan.why, error = %why_not,
                    "autoEvacuate: an idle chat did not move; it stays here"
                );
                self.append(
                    &session,
                    "mux",
                    NOTE_KIND,
                    json!({"text": format!("It stayed on this machine: {why_not}"),
                           "failed": why_not}),
                );
            }
        }
    }
}

/// The timer: a tick every [`TICK`] until the setting is off or the daemon stops.
pub(crate) async fn auto_evacuate_loop(
    weak: std::sync::Weak<Hub>,
    source: &dyn BudgetSource,
    mover: &dyn Mover,
) {
    let mut every = tokio::time::interval(TICK);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut evacuator = Evacuator::default();
    loop {
        every.tick().await;
        let reading = source.read().await;
        let Some(hub) = weak.upgrade() else { return };
        if hub.stopping.load(Ordering::SeqCst) || !hub.config.read().await.auto_evacuate.enabled {
            tracing::info!("autoEvacuate is off: its timer ends");
            return;
        }
        evacuator.tick(&hub, reading, mover).await;
    }
}

/// A level as the plan reads it, for tests that feed readings.
#[cfg(test)]
pub(crate) fn reading_at(level: crate::host_pressure::Level) -> Reading {
    use crate::host_pressure::Level;
    match level {
        Level::Normal => Reading {
            pressure: "normal".into(),
            over: Vec::new(),
            load1: Some(0.5),
            load_limit: 8.0,
        },
        Level::Warning => Reading {
            pressure: "normal".into(),
            over: vec!["load1 9.0 >= 8 (8 cores)".into()],
            load1: Some(9.0),
            load_limit: 8.0,
        },
        Level::Critical => Reading {
            pressure: "critical".into(),
            over: vec!["load1 20.0 >= 8 (8 cores)".into(), "memory pressure critical".into()],
            load1: Some(20.0),
            load_limit: 8.0,
        },
    }
}

#[cfg(test)]
#[path = "auto_evacuate_tests.rs"]
mod tests;
