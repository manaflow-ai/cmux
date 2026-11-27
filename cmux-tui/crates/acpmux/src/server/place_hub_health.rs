//! Part of `place.rs`. Before a placement weighs the machines only the mesh hub reaches, their
//! health is read through the hub (`server/mesh_read.rs` `host_health`, kept by
//! `hub/hub_health.rs`). A machine with no reading yet is waited for up to [`FIRST_WAIT`]; one
//! with a reading is weighed by it while a fresh one is asked. After a placement, a refresh asks
//! again each minute for `INTEREST_MS`, then stops.

use crate::hub::Hub;
use crate::hub::hub_health::{EVERY_MS, HubHealth};
use crate::mesh::MeshHub;
use std::collections::BTreeSet;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

/// How long a placement waits for the machines it has no reading of.
// timeout: placement goes on without a reading (it reads as unknown) once this passes.
const FIRST_WAIT: Duration = Duration::from_secs(6);

/// The session a machine's health read goes through (`mesh_read.rs` `host_health`), looked up at
/// each ask: the book's rows change while a refresh keeps readings fresh.
pub(super) type Via = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// Read the health of the machines only the hub reaches, as [`refresh_with`] does.
pub(super) async fn refresh(hub: &Hub) {
    let Some(mesh) = hub.mesh.get() else { return };
    let hosts = hub.hub_only_hosts();
    if hosts.is_empty() {
        return;
    }
    let book = hub.hub_ref.get().cloned().unwrap_or_default();
    let via: Via =
        Arc::new(move |host| book.upgrade().and_then(|hub| hub.mesh_book_session_on(host)));
    refresh_with(&hub.scope, mesh, hub.hub_health.clone(), hosts, via, FIRST_WAIT).await;
}

/// Ask `hosts` for their health through `mesh` into `cache`: the ones due (`HubHealth::due`),
/// waiting up to `wait` for those with no reading yet, and keep them fresh in the background
/// while placements come. Its asks are `scope`'s tasks.
pub(super) async fn refresh_with(
    scope: &cmux_scope::Scope,
    mesh: Arc<dyn MeshHub>,
    cache: Arc<StdMutex<HubHealth>>,
    hosts: Vec<String>,
    via: Via,
    wait: Duration,
) {
    let now = crate::store::now_ms();
    let (due, missing, running) = {
        let mut h = cache.lock().unwrap_or_else(|e| e.into_inner());
        h.retain(&hosts.iter().cloned().collect::<BTreeSet<_>>());
        let running = h.interested(now);
        let due = h.due(&hosts, now);
        let missing: BTreeSet<String> =
            due.iter().filter(|host| h.reading(host).is_none()).cloned().collect();
        (due, missing, running)
    };
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
    hosts: Vec<String>,
) {
    loop {
        tokio::time::sleep(Duration::from_millis(EVERY_MS)).await;
        let now = crate::store::now_ms();
        let due = {
            let mut h = cache.lock().unwrap_or_else(|e| e.into_inner());
            if !h.wanted(now) {
                return;
            }
            h.due(&hosts, now)
        };
        // At most `IN_FLIGHT`, each within `HEALTH_WAIT`.
        let asks = due.into_iter().map(|host| ask(mesh.clone(), cache.clone(), &via, host));
        futures::future::join_all(asks).await;
    }
}

#[cfg(test)]
mod tests {
    //! RFD 0181 B1's measure, in one harness: a placement over N machines only the hub reaches,
    //! through a hub whose machines never answer a read (the slowest of N, every time). With no
    //! published records it asks each machine and waits [`FIRST_WAIT`]; with each machine's
    //! record on the book (`HubHealth::published`) it asks none and waits on nothing.
    use super::*;
    use crate::mesh::{Ack, Heartbeat, HeartbeatReply, HubError, InMessage, OutMessage, Receipt};
    use futures::future::BoxFuture;
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A hub that takes every read and never answers one.
    #[derive(Default)]
    struct Silent {
        asks: AtomicUsize,
    }

    impl MeshHub for Silent {
        fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
            Box::pin(futures::future::pending())
        }
        fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
            Box::pin(async { Ok(()) })
        }
        fn heartbeat<'a>(
            &'a self,
            _: &'a Heartbeat,
        ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
            Box::pin(async { Ok(HeartbeatReply { daemon_id: "d".into(), ttl_seconds: 90 }) })
        }
        fn send<'a>(&'a self, _: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
            self.asks.fetch_add(1, Ordering::SeqCst);
            Box::pin(futures::future::pending())
        }
        fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
            Box::pin(futures::future::pending())
        }
    }

    const MACHINES: usize = 139;

    /// How long one placement's refresh waits, and how many machines it asked.
    async fn place_once(cache: Arc<StdMutex<HubHealth>>) -> (Duration, usize) {
        let scope = cmux_scope::Scope::new("hub health test");
        let silent = Arc::new(Silent::default());
        let hosts: Vec<String> = (0..MACHINES).map(|i| format!("lane-{i}")).collect();
        let via: Via = Arc::new(|host| Some(format!("{host}-session")));
        let began = tokio::time::Instant::now();
        refresh_with(&scope, silent.clone(), cache, hosts, via, FIRST_WAIT).await;
        (began.elapsed(), silent.asks.load(Ordering::SeqCst))
    }

    #[tokio::test(start_paused = true)]
    async fn a_placement_over_published_records_asks_no_machine_and_waits_on_none() {
        let (waited, asked) = place_once(Arc::default()).await;
        assert_eq!(waited, FIRST_WAIT, "before: it waits on the machines it has no reading of");
        assert!(asked > 0, "before: it asks them ({asked} of {MACHINES}, `IN_FLIGHT` at once)");

        let cache: Arc<StdMutex<HubHealth>> = Arc::default();
        let now = crate::store::now_ms();
        {
            let mut h = cache.lock().unwrap();
            for i in 0..MACHINES {
                h.published(&format!("lane-{i}"), json!({"cpus": 8, "liveSessions": 1}), now, now);
            }
        }
        let (waited, asked) = place_once(cache.clone()).await;
        assert_eq!((waited, asked), (Duration::ZERO, 0), "after: a replica read");
        let h = cache.lock().unwrap();
        assert!((0..MACHINES).all(|i| h.reading(&format!("lane-{i}")).is_some()), "none unknown");
    }
}
