//! `apps.meters` (extensions DESIGN.md section 14 step 2, "Meter in Settings and on
//! headers"): one row per installed extension with what the host's budget saw, for the
//! Settings > Extensions meter. Read-only; the counts are since this daemon started.
//!
//! A row is `{app, step, paused?, runState?, host, crashes, mounts, widgets, slowedMounts,
//! batches: {in, out}, held}`:
//!
//! - `step`: the budget ladder (`budget.rs`): `normal`, `slowed` (a mount over the batch
//!   rate) or `paused`, with `paused` the cause in words.
//! - `runState`: what the listing says when the app cannot run (safe mode, paused, failed).
//! - `host`: `none`, `starting`, `running`, `stopping`, `restarting` or `waiting` (crashed,
//!   restarting after its backoff); `crashes` since its host last came up healthy.
//! - `mounts`, `widgets`, `slowedMounts`: its live views (no store previews), the widget
//!   mounts among them, and the ones Slowed now.
//! - `batches`: scene batches the app sent and the host forwarded, over every mount;
//!   `held`: batches its live mounts had to wait (coalesced by the budget).
//!
//! What the VM spends (memory, CPU time) is not reported to the daemon, so no row has it.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::budget::Step;
use super::supervisor::{HostKey, HostState, Inner, Supervisor};
use crate::panic_free::RecoverPoison;

fn host_state(state: HostState) -> &'static str {
    match state {
        HostState::Starting => "starting",
        HostState::Running => "running",
        HostState::Stopping => "stopping",
        HostState::Restarting => "restarting",
        HostState::Waiting => "waiting",
    }
}

#[derive(Default)]
struct Live {
    mounts: u64,
    widgets: u64,
    slowed: u64,
    held: u64,
}

impl Supervisor {
    /// `apps.meters`: the meter rows of every installed app, in app id order.
    pub(super) fn meters(&self) -> Value {
        let inner = self.inner.lock().recover_poison();
        json!({ "meters": meter_rows(&inner) })
    }
}

fn meter_rows(inner: &Inner) -> Vec<Value> {
    let mut live: BTreeMap<&str, Live> = BTreeMap::new();
    for mount in inner.mounts.values().filter(|m| !m.host.preview) {
        let row = live.entry(mount.host.app.as_str()).or_default();
        row.mounts += 1;
        row.widgets += u64::from(mount.widget.is_some());
        row.slowed += u64::from(mount.budget.step() == Step::Slowed);
        row.held = row.held.saturating_add(mount.budget.held);
    }
    inner
        .mirror
        .apps
        .iter()
        .filter(|(_, record)| record.installed)
        .map(|(app, _)| {
            let own = live.remove(app.as_str()).unwrap_or_default();
            let ladder = inner.ladders.get(app);
            let host = inner.hosts.get(&HostKey { app: app.clone(), preview: false });
            let (run_state, _) = Supervisor::run_facts(inner, app);
            let mut row = json!({
                "app": app,
                "step": Supervisor::budget_step_locked(inner, app).as_str(),
                "host": host.map_or("none", |h| host_state(h.state)),
                "crashes": host.map_or(0, |h| h.crashes),
                "mounts": own.mounts,
                "widgets": own.widgets,
                "slowedMounts": own.slowed,
                "batches": json!({
                    "in": ladder.map_or(0, |l| l.batches_in),
                    "out": ladder.map_or(0, |l| l.batches_out),
                }),
                "held": own.held,
            });
            if let Some(obj) = row.as_object_mut() {
                if let Some(cause) = ladder.and_then(|l| l.paused) {
                    obj.insert("paused".into(), json!(cause.describe()));
                }
                if let Some(run_state) = run_state {
                    obj.insert("runState".into(), json!(run_state));
                }
            }
            row
        })
        .collect()
}
