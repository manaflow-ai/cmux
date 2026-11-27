//! Held carrier circuits (RFD 0056 part 4, RFD 0061 G5: "0.2 s new, 0 for a held circuit").
//!
//! A kept circuit (`hub_carrier_mux.rs`) opens on the first named-service dial to a machine and
//! closes after [`super::Timings::kept_idle`] with no stream, so the first call to a machine, and
//! the first one after an idle hour, still pays a whole new circuit: ticket, relay, peer join,
//! Noise and the `mux` hello. A held circuit is a kept circuit this carrier opens itself, before
//! any dial, and never lets idle out: every dial to that machine, the first included, is one
//! stream OPEN and its ANSWER on it. One that ends under the carrier (the far machine restarted,
//! the relay dropped it) is opened again by [`super::HubCarrier::keep_reopening`] as any kept
//! circuit is; one that could not open at all is tried again here, backing off to a minute.
//!
//! Off by default: `ACPMUX_HUB_HOLD_CIRCUITS` names the machines (`daemonId`s, comma or space
//! separated) whose circuits this carrier holds, both lanes each. An idle held circuit costs one
//! keepalive PING every [`super::Timings::keepalive`] on each lane.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use super::{CircuitLane, DialStages, HubCarrier, Path, mux};

/// The machines whose circuits a carrier holds open (`daemonId`s); unset or empty holds none.
pub const HOLD_CIRCUITS_ENV: &str = "ACPMUX_HUB_HOLD_CIRCUITS";

/// The machines `value` (an [`HOLD_CIRCUITS_ENV`] value) names, each once, in order.
pub fn held_machines(value: Option<&str>) -> Vec<String> {
    let mut machines: Vec<String> = Vec::new();
    for machine in value.unwrap_or_default().split([',', ' ', '\n', '\t']) {
        let machine = machine.trim();
        if !machine.is_empty() && !machines.iter().any(|m| m == machine) {
            machines.push(machine.to_owned());
        }
    }
    machines
}

impl HubCarrier {
    /// Hold the `lane` circuit to `daemon` open: open it now on the relay if none is open, and
    /// keep it (and every circuit opened again on its slot) from idling out. The opened
    /// circuit's set-up stages when this call opened it, None when one was already open.
    pub async fn hold_circuit(
        &self,
        daemon: &str,
        lane: CircuitLane,
    ) -> Result<Option<DialStages>, String> {
        if !self.key_current() {
            return Err("the node key was replaced; this carrier is stopped".into());
        }
        let slot = self.kept.slot(daemon, lane);
        let mut kept = slot.lock().await;
        kept.held = true;
        if let Some(live) = kept.live.clone().filter(|mux| !mux.is_closed()) {
            live.hold();
            return Ok(None);
        }
        if kept.no_mux_until.is_some_and(|until| Instant::now() < until) {
            return Err("the machine keeps no circuits".into());
        }
        let (circuit, said, mut stages) = self.open_kept(daemon, lane, Path::Relay).await?;
        let asked = Instant::now();
        match tokio::time::timeout(self.timings.handshake, said).await {
            Ok(Ok(Ok(()))) => {
                stages.answer = asked.elapsed();
                stages.log(daemon, "held");
                circuit.hold();
                self.stats.kept_circuits.fetch_add(1, Ordering::Relaxed);
                kept.live = Some(circuit);
                kept.path = Some(Path::Relay);
                kept.reopen_at = None;
                kept.reopen_wait = Duration::ZERO;
                tracing::info!(daemon, lane = lane.name(), "hub carrier: holding a circuit");
                Ok(Some(stages))
            }
            Ok(Ok(Err(refusal))) => {
                circuit.close().await;
                kept.no_mux_until = Some(Instant::now() + mux::NO_MUX_ASK_AGAIN);
                Err(format!("the machine keeps no circuits: {refusal}"))
            }
            Ok(Err(_)) | Err(_) => {
                circuit.close().await;
                Err(circuit.ended().unwrap_or_else(|| {
                    "the machine did not answer the kept circuit's hello".into()
                }))
            }
        }
    }

    /// Whether the `lane` circuit to `daemon` is open and held now.
    pub fn holds_circuit(&self, daemon: &str, lane: CircuitLane) -> bool {
        self.kept.live_on(daemon, lane).is_some_and(|mux| mux.is_held())
    }

    /// Hold both lanes' circuits to each machine [`HOLD_CIRCUITS_ENV`] names, in the background
    /// until each opened (then [`Self::keep_reopening`] keeps it) or the carrier is gone.
    pub fn hold_configured(self: &Arc<Self>) {
        self.hold_machines(held_machines(std::env::var(HOLD_CIRCUITS_ENV).ok().as_deref()));
    }

    /// [`Self::hold_configured`] for `machines`.
    pub fn hold_machines(self: &Arc<Self>, machines: Vec<String>) {
        for daemon in machines {
            for lane in [CircuitLane::Cheap, CircuitLane::Bulk] {
                let carrier = Arc::downgrade(self);
                let daemon = daemon.clone();
                mux::spawn_reopening(async move {
                    let mut wait = Duration::ZERO;
                    loop {
                        let Some(carrier) = carrier.upgrade() else { return };
                        match carrier.hold_circuit(&daemon, lane).await {
                            Ok(_) => return,
                            Err(e) => {
                                wait = (wait * 2)
                                    .clamp(mux::REOPEN_BACKOFF_MIN, mux::REOPEN_BACKOFF_MAX);
                                tracing::debug!(
                                    daemon,
                                    lane = lane.name(),
                                    "hub carrier: a held circuit did not open ({e}); next try in {wait:?}"
                                );
                            }
                        }
                        drop(carrier);
                        tokio::time::sleep(wait).await;
                    }
                });
            }
        }
    }
}
