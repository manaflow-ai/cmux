//! Part of `place.rs`. Before a placement weighs the machines only the mesh hub reaches, their
//! health is read through the hub (`server/mesh_read.rs` `host_health`, kept by
//! `hub/hub_health.rs`). A machine with no reading yet, or one older than
//! `placement::reach::STALE_MS`, is waited for up to [`FIRST_WAIT`]; one with a fresh reading is
//! weighed by it while a newer one is asked. After a placement, a refresh asks
//! again each minute for `INTEREST_MS`, then stops.
//!
//! Of the machines with no reading, a placement waits on [`SAMPLE`] chosen at random (RFD 0181
//! B3, Sparrow's power of d choices): every one due is still asked, the rest in the background
//! for the next placement, so a pick's wait is the slowest of [`SAMPLE`], whatever N grows to.
//! The RFD's "plus the last good one" needs no wait of its own: a machine that answered holds a
//! reading, so placement already weighs it (an earlier draft waited on it too, but it was only
//! ever missing a reading after that reading was dropped).

use crate::hub::Hub;
use crate::hub::hub_health::{EVERY_MS, HealthHosts, HubHealth};
use crate::mesh::MeshHub;
use std::collections::BTreeSet;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

/// How long a placement waits for the machines it has no reading of.
// timeout: placement goes on without a reading (it reads as unknown) once this passes.
const FIRST_WAIT: Duration = Duration::from_secs(6);

/// How many machines with no reading, chosen at random, a placement waits on: the rest are
/// asked without holding it.
const SAMPLE: usize = 3;

/// The session a machine's health read goes through (`mesh_read.rs` `host_health`), looked up at
/// each ask: the book's rows change while a refresh keeps readings fresh.
pub(super) type Via = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// Each pass uses the current address book, including pushes received since the previous pass.
type Hosts = Arc<dyn Fn(u64) -> HealthHosts + Send + Sync>;

/// Read the health of the machines only the hub reaches.
pub(super) async fn refresh(hub: &Hub) {
    let Some(mesh) = hub.mesh.get() else { return };
    let book = hub.hub_ref.get().cloned().unwrap_or_default();
    let targets = book.clone();
    let hosts: Hosts = Arc::new(move |now| {
        targets.upgrade().map(|hub| hub.mesh_health_hosts(now)).unwrap_or_default()
    });
    let via: Via =
        Arc::new(move |host| book.upgrade().and_then(|hub| hub.mesh_book_session_on(host)));
    refresh_drawn(&hub.scope, mesh, hub.hub_health.clone(), hosts, via, FIRST_WAIT, seed()).await;
}

/// Ask for the machines due, waiting only for the sampled ones missing a reading.
async fn refresh_drawn(
    scope: &cmux_scope::Scope,
    mesh: Arc<dyn MeshHub>,
    cache: Arc<StdMutex<HubHealth>>,
    hosts: Hosts,
    via: Via,
    wait: Duration,
    seed: u64,
) {
    let now = crate::store::now_ms();
    let targets = hosts(now);
    let (due, missing, running) = {
        let mut h = cache.lock().unwrap_or_else(|e| e.into_inner());
        let due = targets.due(&mut h, now);
        if targets.listed.is_empty() {
            return;
        }
        let running = h.interested(now);
        // Wait for a sampled machine when it has no usable reading.
        let missing: BTreeSet<String> = due
            .iter()
            .filter(|host| {
                h.reading(host).is_none_or(|(at, _)| {
                    now.saturating_sub(at) > crate::placement::reach::STALE_MS
                        || h.failed_at(host).is_some_and(|failed| failed > at)
                })
            })
            .cloned()
            .collect();
        (due, missing, running)
    };
    let missing = wait_on(&missing, seed);
    let mut first = Vec::new();
    for host in due {
        let task = scope
            .spawn_named("hub health read", ask(mesh.clone(), cache.clone(), &via, host.clone()));
        if missing.contains(&host) {
            first.push(task);
        }
    }
    if !first.is_empty() {
        let _ = tokio::time::timeout(wait, futures::future::join_all(first)).await;
    }
    if !running {
        scope.spawn_until_cancelled("hub health refresh", keep_fresh(mesh, cache, via, hosts));
    }
}

/// Of `missing` (machines with no reading), the ones a placement waits on: [`SAMPLE`] drawn by
/// `seed`. All of them while they are that few.
fn wait_on(missing: &BTreeSet<String>, seed: u64) -> BTreeSet<String> {
    if missing.len() <= SAMPLE {
        return missing.clone();
    }
    let mut pool: Vec<&String> = missing.iter().collect();
    let mut out = BTreeSet::new();
    let mut x = seed | 1;
    for _ in 0..SAMPLE {
        // xorshift64: a draw needs no more than uniform here.
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        let at = (x % pool.len() as u64) as usize;
        out.insert(pool.swap_remove(at).clone());
    }
    out
}

/// A fresh draw for [`wait_on`] (the OS generator; the clock when it cannot answer).
fn seed() -> u64 {
    let mut b = [0u8; 8];
    match getrandom::fill(&mut b) {
        Ok(()) => u64::from_le_bytes(b),
        Err(_) => crate::store::now_ms(),
    }
}

#[cfg(test)]
#[path = "place_hub_health_sample_tests.rs"]
mod sample_tests;

/// One machine's ask, through the session `via` names on it, its answer kept.
fn ask(
    mesh: Arc<dyn MeshHub>,
    cache: Arc<StdMutex<HubHealth>>,
    via: &Via,
    host: String,
) -> impl std::future::Future<Output = ()> + Send + 'static {
    let session = via(&host);
    ask_through(mesh, cache, host, session)
}

async fn ask_through(
    mesh: Arc<dyn MeshHub>,
    cache: Arc<StdMutex<HubHealth>>,
    host: String,
    session: Option<String>,
) {
    let read =
        crate::server::mesh_relay::read::host_health(mesh.as_ref(), &host, session.as_deref());
    let reading = match read.await {
        Ok(v) => Some(v),
        Err(e) => {
            tracing::debug!(host, error = %e.message, "no health reading through the hub");
            None
        }
    };
    cache.lock().unwrap_or_else(|e| e.into_inner()).answered(
        &host,
        reading,
        crate::store::now_ms(),
    );
}

/// Ask `hosts` again each minute while a placement wants readings (`HubHealth::wanted`).
async fn keep_fresh(
    mesh: Arc<dyn MeshHub>,
    cache: Arc<StdMutex<HubHealth>>,
    via: Via,
    hosts: Hosts,
) {
    loop {
        tokio::time::sleep(Duration::from_millis(EVERY_MS)).await;
        let now = crate::store::now_ms();
        let targets = hosts(now);
        let due = {
            let mut h = cache.lock().unwrap_or_else(|e| e.into_inner());
            if !h.wanted(now) {
                return;
            }
            targets.due(&mut h, now)
        };
        // At most `IN_FLIGHT`, each within `HEALTH_WAIT`.
        let asks = due.into_iter().map(|host| ask(mesh.clone(), cache.clone(), &via, host));
        futures::future::join_all(asks).await;
    }
}
