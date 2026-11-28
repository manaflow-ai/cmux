//! Part of `Hub`; see `hub/mod.rs`. A lane on a peer that died tells the session here that
//! started it, once per death (`lane_death_watch.rs` has the rules and why).
//!
//! On unless `ACPMUX_LANE_DEATH_WATCH=0`. Every [`TICK`] one pass reads this daemon's peer rows
//! (`remote_sessions`, kept live by every peer's list stream, and marked `unreachable` when a
//! peer's link drops) and this daemon's live sessions. A dead row whose starter tag names a
//! session here (its id, its name, or `HOST/NAME` with this machine's name) puts one hub-set
//! prompt in that session's chat, steered into a running turn: `{kind: "lane_death", from,
//! fromName, to, host, why, since, route}`, with the step the product's recovery decision
//! takes next (`death_route::route`) and the command that runs it. Its prompt id is the same
//! for every try of one death, so a resend never doubles it. Rows of this machine's own
//! sessions are not read: a dead lane here is the local reports' (`hub/lane_reports.rs`).

use super::*;
use crate::lane_death_watch::{GRACE_MS, KIND, Notice, Watch};
use std::collections::HashMap;

/// How often the watch looks: a pass reads two in-memory lists.
pub(crate) const TICK: std::time::Duration = std::time::Duration::from_secs(60);

/// Notices one pass sends at most; the rest go next pass.
const MAX_PER_PASS: usize = 20;

/// Whether the watch is on (`ACPMUX_LANE_DEATH_WATCH=0` turns it off).
fn enabled() -> bool {
    std::env::var("ACPMUX_LANE_DEATH_WATCH").map_or(true, |v| v.trim() != "0")
}

/// The local sessions a starter tag can name: id, name and `HOST/NAME` for this machine's
/// names, each to its session.
fn local_idents(sessions: &[Arc<Session>], hosts: &[String]) -> HashMap<String, Arc<Session>> {
    let mut out = HashMap::new();
    for s in sessions {
        let name = s.read_meta(|m| m.name.clone());
        for h in hosts {
            out.insert(format!("{h}/{name}"), s.clone());
        }
        out.insert(s.id.clone(), s.clone());
        out.insert(name, s.clone());
    }
    out
}

impl Hub {
    /// Starts the watch once per daemon (module docs).
    pub(crate) fn start_lane_death_watch(self: &Arc<Self>) {
        static RUNNING: AtomicBool = AtomicBool::new(false);
        if !enabled() || RUNNING.swap(true, Ordering::SeqCst) {
            return;
        }
        let weak = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("lane-death-watch", async move {
            let mut every = tokio::time::interval(TICK);
            every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut watch = Watch::default();
            loop {
                every.tick().await;
                let Some(hub) = weak.upgrade() else { break };
                if hub.stopping.load(Ordering::SeqCst) {
                    break;
                }
                hub.lane_death_pass(&mut watch, crate::store::now_ms()).await;
            }
            RUNNING.store(false, Ordering::SeqCst);
        });
    }

    /// One pass: each new death of a lane started here, told to its starter.
    pub(crate) async fn lane_death_pass(self: &Arc<Self>, watch: &mut Watch, now_ms: u64) {
        let hosts = {
            let mut h = vec![crate::pairing::machine_name(), crate::pairing::host_label()];
            h.dedup();
            h
        };
        let local = local_idents(&self.live_session_handles(), &hosts);
        let rows = self.remote_sessions.snapshot();
        let values: Vec<(String, String, Value)> =
            rows.iter().map(|(key, r)| (key.clone(), r.peer.clone(), r.summary.value())).collect();
        let notices = watch.pass(
            values.iter().map(|(k, h, v)| (k.as_str(), h.as_str(), v)),
            now_ms,
            GRACE_MS,
            |p| local.contains_key(p),
            |host| self.peer_by_name(host).is_some_and(|peer| peer.idle_parked()),
        );
        for n in notices.into_iter().take(MAX_PER_PASS) {
            let Some(parent) = local.get(&n.parent).cloned() else { continue };
            match self.lane_death_to_parent(parent, &n, now_ms).await {
                Ok(()) => {
                    tracing::info!(lane = %n.key, host = %n.host, parent = %n.parent,
                        why = n.dead.why, "lane death told to its starter");
                    watch.told(&n);
                }
                Err(e) => tracing::warn!(lane = %n.key, parent = %n.parent,
                    "lane death notice not sent; next pass tries again: {}", e.message),
            }
        }
    }

    /// Puts notice `n` in its starter `p`'s chat as a hub-set prompt; done once it is accepted.
    async fn lane_death_to_parent(
        self: &Arc<Self>,
        p: Arc<Session>,
        n: &Notice,
        now_ms: u64,
    ) -> Result<(), RpcError> {
        let provenance = json!({
            "kind": KIND, "from": n.key, "fromName": n.name, "to": p.id, "host": n.host,
            "why": n.dead.why, "since": n.dead.since_ms, "route": n.route,
        });
        let blocks = vec![json!({"type": "text", "text": n.text(now_ms)})];
        let (tx, rx) = oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some(n.prompt_id()),
            resend: true,
            provenance: Some(provenance),
            agent: Some(n.name.clone()),
            class: Some(crate::prompt_class::PromptClass::Result),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            ..PromptOptions::default()
        };
        let hub = self.clone();
        // The hub's scope owns the prompt: it ends with the daemon.
        let run = self.scope.spawn_named("lane-death-notice", async move {
            hub.prompt_with(&p, blocks, "acpmux", true, opts).await
        });
        if rx.await.is_ok() {
            return Ok(());
        }
        match run.await {
            Ok(Ok(_)) => Ok(()),
            Ok(Err(e)) if e.data.as_ref().is_some_and(|d| d["held"] == true) => Ok(()),
            Ok(Err(e)) => Err(e),
            Err(e) => Err(RpcError::internal(e.to_string())),
        }
    }
}
