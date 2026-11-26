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
