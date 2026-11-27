//! A dial that does not wait on a dead kept circuit (Leo, 2026-11-25: "small, chatty calls stay
//! on whichever machine holds the files, batched over one always-open connection, never a new
//! connection per call").
//!
//! A kept circuit whose far end went away without a close (a Freestyle VM that paused, a relay
//! that dropped the slot, a NAT that forgot the mapping) still looks open here until its
//! keepalive misses two 30 s periods. A dial in that window sent its OPEN and a PING on it, heard
//! nothing for [`mux::ANSWER_SUSPECT`] (3 s), and only then opened a fresh circuit (0.4 to 2 s
//! more): the NOW weft probe charged those dials 1.7 s at its kept p95 and the whole 5 s deadline
//! at its tail (gcp-agent-lane-12, 2026-11-26 18:36Z to 18:44Z).
//!
//! The PING behind every OPEN is answered by the far machine's reader at once, whatever the
//! service does with the OPEN, so a live circuit hears a record within one round trip. When
//! nothing at all comes back in [`KEPT_HEDGE`], the dial opens a fresh kept circuit beside the
//! silent one, still listening on the old. Whichever shows life first carries the dial: an
//! answer on the old (it was only slow) keeps it and closes the fresh one; a fresh circuit whose
//! `mux` hello is answered while the old still heard nothing replaces it in the slot, the old is
//! closed (as `ANSWER_SUSPECT` would have closed it, only sooner), and the dial opens its stream
//! on the fresh one. Dials that hit the same silent circuit meanwhile wait on the one fresh open,
//! as parallel dials wait on one first open. A dial with early bytes keeps the old wait: those
//! bytes may have reached the far service, and no other circuit sends them again.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use bytes::Bytes;
use tokio::sync::{Mutex, OwnedMutexGuard};

use super::{CircuitLane, HubCarrier, HubStream, Path, ServiceRefusal, mux};

/// How long a dial's OPEN on a kept circuit may hear nothing at all (not the answer, not the
/// PONG to the PING behind it) before a fresh circuit opens beside it. A round trip to a relay
/// peer is 20 to 150 ms; the far machine's reader answers the PING before the service reads the
/// OPEN.
pub(crate) const KEPT_HEDGE: Duration = Duration::from_millis(500);

/// What a dial's open on a kept circuit came to.
pub(super) enum Hedged {
    /// The old circuit's answer (it showed life, or the fresh circuit did not open).
    Old(Result<Result<HubStream, ServiceRefusal>, mux::OpenFailed>),
    /// A fresh circuit took the silent one's place in the slot: open the stream there.
    Replaced,
    /// The old circuit failed and no fresh one opened either.
    Failed(String),
}

/// A fresh circuit not yet in a slot: closed if dropped there (a dial that took the old
/// circuit's answer instead, or was cancelled), so none idles on its keepalive for an hour.
struct Loose(Option<Arc<mux::Mux>>);

impl Loose {
    /// The circuit, out of the guard: no longer closed on drop.
    fn keep(mut self) -> Option<Arc<mux::Mux>> {
        self.0.take()
    }
}

impl Drop for Loose {
    fn drop(&mut self) {
        let Some(circuit) = self.0.take() else {
            return;
        };
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move { circuit.close().await });
        }
    }
}

/// The fresh side of the race.
enum Fresh {
    /// Another dial already replaced the silent circuit.
    Already,
    /// A fresh circuit whose `mux` hello was answered, with its slot still held.
    New(OwnedMutexGuard<mux::Kept>, Loose),
}

impl HubCarrier {
    /// Open a stream with no early bytes on `old`, the live kept circuit in `slot`; past
    /// [`KEPT_HEDGE`] of silence, race a fresh kept circuit to `daemon` against it.
    pub(super) async fn open_or_replace(
        &self,
        old: &Arc<mux::Mux>,
        slot: &Arc<Mutex<mux::Kept>>,
        daemon: &str,
        lane: CircuitLane,
        path: Path,
        hello: Bytes,
    ) -> Hedged {
        let asked = Instant::now();
        let open = old.open(hello, &[], self.timings.handshake);
        tokio::pin!(open);
        tokio::select! {
            opened = &mut open => return Hedged::Old(opened),
            () = tokio::time::sleep(KEPT_HEDGE) => {}
        }
        if old.heard_since(asked) {
            return Hedged::Old(open.await);
        }
        // A silent direct or punched circuit: the relay is the fresh circuit. Its caller holds
        // the machine off that path a while and dials the relay's kept circuit, where a fresh
        // direct handshake to a machine that stopped answering on it waits its whole 2 s.
        if !matches!(path, Path::Relay) {
            return Hedged::Failed(format!(
                "the kept circuit heard nothing {}ms into a dial",
                KEPT_HEDGE.as_millis()
            ));
        }
        tracing::info!(
            "hub carrier: a kept circuit heard nothing {}ms into a dial; opening a fresh one beside it",
            KEPT_HEDGE.as_millis()
        );
        let fresh = self.fresh_beside(old, slot.clone(), daemon, lane, path);
        tokio::pin!(fresh);
        tokio::select! {
            opened = &mut open => match opened {
                Err(e) if !e.early_out => match fresh.await {
                    Ok(Fresh::New(kept, circuit)) => self.replace(old, kept, circuit, path).await,
                    Ok(Fresh::Already) => Hedged::Replaced,
                    Err(f) => Hedged::Failed(format!("{}; a fresh circuit beside it: {f}", e.why)),
                },
                opened => Hedged::Old(opened),
            },
            fresh = &mut fresh => match fresh {
                Ok(Fresh::Already) if !old.heard_since(asked) => Hedged::Replaced,
                Ok(Fresh::New(kept, circuit)) if !old.heard_since(asked) => {
                    self.replace(old, kept, circuit, path).await
                }
                // The old circuit spoke while the fresh one opened: it is alive, only slow.
                Ok(_) => Hedged::Old(open.await),
                Err(f) => match open.await {
                    Err(e) if !e.early_out => {
                        Hedged::Failed(format!("{}; a fresh circuit beside it: {f}", e.why))
                    }
                    opened => Hedged::Old(opened),
                },
            },
        }
    }

    /// A fresh kept circuit to `daemon` for `slot`, its `mux` hello answered, unless another
    /// dial already put one in place of `old`.
    async fn fresh_beside(
        &self,
        old: &Arc<mux::Mux>,
        slot: Arc<Mutex<mux::Kept>>,
        daemon: &str,
        lane: CircuitLane,
        path: Path,
    ) -> Result<Fresh, String> {
        let kept = slot.lock_owned().await;
        if kept.live.as_ref().is_some_and(|live| !Arc::ptr_eq(live, old) && !live.is_closed()) {
            return Ok(Fresh::Already);
        }
        let (circuit, said, stages) = self.open_kept(daemon, lane, path).await?;
        let circuit = Loose(Some(circuit));
        match tokio::time::timeout(self.timings.handshake, said).await {
            Ok(Ok(Ok(()))) => {
                stages.log(daemon, "fresh beside a silent kept circuit");
                Ok(Fresh::New(kept, circuit))
            }
            Ok(Ok(Err(refusal))) => Err(refusal.to_string()),
            _ => Err(circuit.0.as_ref().and_then(|c| c.ended()).unwrap_or_else(|| {
                "the machine did not answer the fresh kept circuit's hello".into()
            })),
        }
    }

    /// Put `circuit` in the slot in place of `old`, and close `old`.
    async fn replace(
        &self,
        old: &Arc<mux::Mux>,
        mut kept: OwnedMutexGuard<mux::Kept>,
        circuit: Loose,
        path: Path,
    ) -> Hedged {
        old.close().await;
        self.stats.kept_circuits.fetch_add(1, Ordering::Relaxed);
        kept.live = circuit.keep();
        kept.path = Some(path);
        kept.reopen_at = None;
        Hedged::Replaced
    }
}
