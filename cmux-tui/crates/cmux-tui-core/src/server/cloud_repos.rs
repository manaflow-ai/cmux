//! The shared repo actions on local sockets and authenticated Cloud links.
use super::{ClientTransport, MessageWriter, Mux};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::sync::{Mutex, OnceLock};
static WORKERS: AtomicUsize = AtomicUsize::new(0);
const MAX_WORKERS: usize = 16;
/// Threads running or waiting for a worker slot. A request past
/// `MAX_WORKERS` waits for a slot (up to `SLOT_WAIT`) instead of being
/// refused with "retry after the current action finishes".
static QUEUED: AtomicUsize = AtomicUsize::new(0);
const MAX_QUEUED: usize = MAX_WORKERS * 4;
const SLOT_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// One add per destination can run at a time. The runtime keeps the same
/// serialization around the seed job, but taking this gate before the worker
/// slot prevents duplicate adds from parking scarce workers while they wait
/// for the first clone to finish.
static DESTINATION_GATES: OnceLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();

fn destination_lock(key: &str) -> Arc<Mutex<()>> {
    let mut gates =
        DESTINATION_GATES.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
    gates.retain(|_, gate| Arc::strong_count(gate) > 1);
    gates.entry(key.to_owned()).or_default().clone()
}

/// Derive the folder destination used by `git.seed.start` from an add frame.
/// Invalid requests return no key and continue through normal validation.
fn destination_key(request: &Value) -> Option<String> {
    let session = request.get("session")?.as_str()?.trim();
    let input = request.get("repo")?.as_str()?.trim().trim_end_matches('/');
    if session.is_empty() || input.is_empty() {
        return None;
    }
    let normalized = crate::cloud_repos::normalize(input).ok()?;
    let leaf = normalized.rsplit('/').next()?;
    Some(format!("{}/{}", session, leaf.to_ascii_lowercase()))
}

fn busy(message: &str) -> Value {
    json!({"code":"seed.clone_failed","message":message})
}

/// Waits (bounded, quietly) for one of the `max` worker slots of `workers`.
fn take_slot(workers: &AtomicUsize, max: usize, wait: std::time::Duration) -> bool {
    use crate::retry::{Attempt, Patience};
    Patience::new("a repository worker", wait)
        .quiet()
        .spaced(std::time::Duration::from_millis(50), std::time::Duration::from_millis(500))
        .run(|| {
            workers
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| (n < max).then_some(n + 1))
                .map(|_| ())
                .map_err(|_| Attempt::Retry(()))
        })
        .is_ok()
}

pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    line: &super::line_value::LineValue<'_>,
    writer: &MessageWriter,
) -> Option<bool> {
    let cmd = crate::cloud_repos::frame_command_of(line.value()?)?;
    let request = line.value()?.clone();
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let permitted = permitted(mux, client, &cmd, &request);
    if !permitted {
        return Some(writer.send_control(&json!({"id":id,"ok":false,"error_code":"remote_denied","error":"permission denied"})).is_ok());
    }
    if QUEUED
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| (n < MAX_QUEUED).then_some(n + 1))
        .is_err()
    {
        let message = format!(
            "Repository actions are busy: {MAX_QUEUED} are already running or waiting for a turn."
        );
        return Some(
            writer.send_control(&json!({"id":id,"ok":true,"data":busy(&message)})).is_ok(),
        );
    }
    let mux = mux.clone();
    let writer = writer.clone();
    let fallback = writer.clone();
    let fallback_id = id.clone();
    let destination = (cmd == "cloud.repo.add").then(|| destination_key(&request)).flatten();
    match std::thread::Builder::new().name("cloud-repo".into()).spawn(move || {
        struct Queued;
        impl Drop for Queued {
            fn drop(&mut self) {
                QUEUED.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _queued = Queued;
        // Wait for another add targeting the same destination before taking a
        // worker. The queued-thread cap bounds parked duplicate requests.
        let destination_lock = destination.as_deref().map(destination_lock);
        let _destination =
            destination_lock.as_ref().map(|lock| lock.lock().unwrap_or_else(|e| e.into_inner()));
        if !take_slot(&WORKERS, MAX_WORKERS, SLOT_WAIT) {
            let message = format!(
                "Repository actions stayed busy for {} s: {MAX_WORKERS} were still running.",
                SLOT_WAIT.as_secs()
            );
            let _ = writer.send_control(&json!({"id":id,"ok":true,"data":busy(&message)}));
            return;
        }
        struct Done;
        impl Drop for Done {
            fn drop(&mut self) {
                WORKERS.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _done = Done;
        let result = crate::cloud_repos::handle(&mux, &cmd, &request);
        let _ = writer.send_control(&json!({"id":id,"ok":true,"data":result}));
    }) {
        Ok(_) => Some(true),
        Err(_) => {
            QUEUED.fetch_sub(1, Ordering::AcqRel);
            // The OS refused a thread (resource exhaustion): nothing ran.
            Some(fallback.send_control(&json!({"id":fallback_id,"ok":false,"error_code":"seed.clone_failed","error":"The repository action did not run: this machine could not start a worker thread."})).is_ok())
        }
    }
}

#[cfg(test)]
#[test]
fn a_full_worker_pool_is_waited_for_instead_of_refused() {
    let workers = Arc::new(AtomicUsize::new(2));
    std::thread::scope(|scope| {
        scope.spawn(|| {
            std::thread::sleep(std::time::Duration::from_millis(200));
            workers.fetch_sub(1, Ordering::AcqRel);
        });
        assert!(take_slot(&workers, 2, std::time::Duration::from_secs(5)));
    });
    assert_eq!(workers.load(Ordering::Acquire), 2);
    assert!(!take_slot(&workers, 2, std::time::Duration::from_millis(150)));
}

/// Local user and linked Mac requests retain their existing access. A
/// presented agent identity, however, may address only its own chat, and a
/// linked Mac frame must name the chat its surface currently shows.
fn permitted(mux: &Mux, client: u64, cmd: &str, request: &Value) -> bool {
    let transport = mux.control_clients.transport_of(client);
    let principal = mux.frame_principal(client);
    if !matches!(transport, Some(ClientTransport::Unix | ClientTransport::Remote))
        || principal.is_none()
        || (matches!(cmd, "cloud.repo.local" | "cloud.repo.remember")
            && !matches!(transport, Some(ClientTransport::Unix)))
    {
        return false;
    }
    // The ones that write under the file roots: on a machine of the person's own, the owner's
    // connections only, as for the fs ops.
    if !matches!(cmd, "cloud.repo.local" | "cloud.repo.remember")
        && !super::fs_wire::transport_allows_fs(mux, client)
    {
        return false;
    }
    if matches!(principal, Some(super::remote_relay::Principal::Remote(_)))
        && cmd != "cloud.repo.sync"
        && !session_matches_surface(mux, request)
    {
        return false;
    }
    let credential = match request.get("credential") {
        None => None,
        Some(Value::String(value)) if !value.is_empty() => Some(value.as_str()),
        Some(_) => return false,
    };
    match mux.request_actor(super::origin_gate::connection_actor(mux, client), credential) {
        Ok(crate::Actor::AcpSession { id, .. }) => {
            request.get("session").and_then(Value::as_str) == Some(id.as_str())
        }
        Ok(_) => true,
        Err(_) => false,
    }
}

/// A linked Mac frame names the session currently shown by its surface.
/// The principal and transport checks still apply independently; sync has no chat.
fn session_matches_surface(mux: &Mux, request: &Value) -> bool {
    let session = request.get("session").and_then(Value::as_str).filter(|s| !s.is_empty());
    let stored = request
        .get("surface")
        .and_then(Value::as_u64)
        .and_then(|surface| super::agent_session_attach::tab_session(mux, surface));
    session.is_some() && session == stored.as_deref()
}

#[cfg(test)]
#[path = "cloud_repos_tests.rs"]
mod tests;
