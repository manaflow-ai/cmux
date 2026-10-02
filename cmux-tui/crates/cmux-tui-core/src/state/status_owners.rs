//! The daemon removes owned status entries when their owner ends
//! (plans/cmux-next/status-indicators.md section 5): a TTL passes, the owner
//! terminal exits, or the owner process exits. Each removal is one state
//! commit with its own transaction; clients never run timers for it.
//!
//! Nothing polls. A terminal owner is watched through the session host's
//! exit subscription, a process owner through the kernel's process-exit
//! notification (kqueue on macOS, pidfd on Linux), and TTLs by one thread
//! that sleeps until the earliest deadline and is woken by new deadlines.

use std::collections::HashSet;
use std::sync::{Condvar, Mutex, OnceLock, Weak};
use std::time::Duration;

use serde_json::json;

use crate::state::prelude::*;
use crate::state::status_meta::{self, OwnerEnd};
use crate::state::store::{StateChanges, StateCommit, state_upsert};
use crate::state::commit::StateEffects;
use crate::state::workspace_status_store as status;
use crate::resource::TerminalPublicId;
use crate::Mux;

impl Mux {
    /// Remove every status entry `end` owns, in one commit. `None` when
    /// nothing was owned.
    pub(crate) fn clear_owned_workspace_status(&self, end: &OwnerEnd) -> anyhow::Result<Option<StateCommit>> {
        if self.read_registry_state(|connection| status_meta::owned_entries(connection, end))?.is_empty() {
            return Ok(None);
        }
        let mutation = WorkspaceMutation::local("workspace_status.auto_clear");
        let fingerprint = json!({"operation": "workspace_status.auto_clear", "end": end});
        let commit = self.commit_state(
            &mutation,
            "workspace_status.auto_clear",
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _state| {
                // Read again inside the transaction: a set or clear may have
                // landed since the check above.
                let owned = status_meta::owned_entries(transaction, end)?;
                let workspaces = status_meta::remove_entries(transaction, &owned)?;
                let mut changes = Vec::with_capacity(workspaces.len());
                for workspace in &workspaces {
                    let snapshot = status::status_snapshot(transaction, workspace)?;
                    changes.push(state_upsert("workspace_status", workspace, snapshot));
                }
                Ok(StateChanges::new(json!({"removed": owned.len()}), changes))
            },
        )?;
        Ok(Some(commit))
    }

    /// The local machine id (process owners are scoped to it).
    pub(crate) fn status_machine_id(&self) -> String {
        self.workspace_registry.lock().unwrap().machine_id().as_str().to_owned()
    }
}

/// Whether a request asks for a process owner (`workspace_status.set` with
/// `owner.pid`). The transport admits it only from a trusted local client;
/// a remote client's process id means nothing on this machine.
pub(crate) fn names_process_owner(request: &crate::resource_router::ParsedResourceRequest) -> bool {
    request.envelope.operation == crate::resource::ResourceOperation::WorkspaceStatusSet
        && request.fields.get("owner").and_then(|owner| owner.get("pid")).is_some_and(|pid| !pid.is_null())
}

/// Start watching every owner a just-committed entry names. Called after a
/// successful `workspace_status.set` and once at daemon start.
pub(crate) fn watch_owners(mux: &Arc<Mux>, terminal: Option<&str>, pid: Option<u32>, has_ttl: bool) {
    if let Some(terminal) = terminal {
        watch_terminal(mux, terminal.to_owned());
    }
    if let Some(pid) = pid {
        watch_process(mux, pid);
    }
    if has_ttl {
        schedule_expiry(mux);
    }
}

/// Re-arm the watches of entries a previous daemon run left, and remove
/// entries whose TTL passed while the daemon was down.
pub(crate) fn resume(mux: &Arc<Mux>) {
    let machine = mux.status_machine_id();
    match mux.read_registry_state(|connection| status_meta::live_owners(connection, &machine)) {
        Ok((terminals, pids)) => {
            for terminal in terminals {
                watch_terminal(mux, terminal);
            }
            for pid in pids {
                watch_process(mux, pid);
            }
        }
        Err(error) => eprintln!("cmux-tui: status owner resume failed: {error}"),
    }
    schedule_expiry(mux);
}

fn mux_key(mux: &Arc<Mux>) -> usize {
    Arc::as_ptr(mux) as usize
}

fn watched() -> &'static Mutex<HashSet<(usize, String)>> {
    static WATCHED: OnceLock<Mutex<HashSet<(usize, String)>>> = OnceLock::new();
    WATCHED.get_or_init(Default::default)
}

/// Run `wait` on its own thread once per `(mux, label)`, then clear `end`.
fn spawn_watch(mux: &Arc<Mux>, label: String, end: OwnerEnd, wait: impl FnOnce(&Mux) + Send + 'static) {
    let key = (mux_key(mux), label);
    if !watched().lock().unwrap().insert(key.clone()) {
        return;
    }
    let mux = mux.clone();
    let spawned = std::thread::Builder::new().name("cmux-status-owner".into()).spawn(move || {
        wait(&mux);
        watched().lock().unwrap().remove(&key);
        if let Err(error) = mux.clear_owned_workspace_status(&end) {
            eprintln!("cmux-tui: clearing owned status failed: {error}");
        }
    });
    if let Err(error) = spawned {
        eprintln!("cmux-tui: status owner watch failed to start: {error}");
    }
}

fn watch_terminal(mux: &Arc<Mux>, terminal: String) {
    let end = OwnerEnd::Terminal { terminal: terminal.clone() };
    spawn_watch(mux, format!("terminal:{terminal}"), end, move |mux| {
        let Ok(id) = TerminalPublicId::parse(terminal) else { return };
        // Returns at exit; an unknown terminal is already gone.
        while let Ok(state) = mux.wait_for_terminal_exit(&id, None) {
            if state["state"] == "exited" {
                return;
            }
        }
    });
}

fn watch_process(mux: &Arc<Mux>, pid: u32) {
    let end = OwnerEnd::Process { pid, machine: mux.status_machine_id() };
    spawn_watch(mux, format!("pid:{pid}"), end, move |_| {
        if let Err(error) = wait_for_process_exit(pid) {
            eprintln!("cmux-tui: cannot watch process {pid}: {error}");
        }
    });
}

/// Whether `pid` names a running process (`kill(pid, 0)`).
pub(crate) fn process_is_running(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: signal 0 performs only the existence and permission check.
    let result = unsafe { libc::kill(pid, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Block until `pid` exits. Returns at once when it is not running.
#[cfg(target_vendor = "apple")]
fn wait_for_process_exit(pid: u32) -> std::io::Result<()> {
    let pid = libc::pid_t::try_from(pid).map_err(|_| std::io::ErrorKind::InvalidInput)?;
    // SAFETY: plain kqueue calls on a descriptor this function owns.
    unsafe {
        let queue = libc::kqueue();
        if queue < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let mut change: libc::kevent = std::mem::zeroed();
        change.ident = pid as libc::uintptr_t;
        change.filter = libc::EVFILT_PROC;
        change.flags = libc::EV_ADD | libc::EV_ONESHOT;
        change.fflags = libc::NOTE_EXIT;
        let mut event: libc::kevent = std::mem::zeroed();
        let mut result = libc::kevent(queue, &change, 1, &mut event, 1, std::ptr::null());
        while result < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            result = libc::kevent(queue, std::ptr::null(), 0, &mut event, 1, std::ptr::null());
        }
        let error = std::io::Error::last_os_error();
        libc::close(queue);
        if result < 0 && error.raw_os_error() != Some(libc::ESRCH) {
            return Err(error);
        }
    }
    Ok(())
}

/// Block until `pid` exits. Returns at once when it is not running.
#[cfg(target_os = "linux")]
fn wait_for_process_exit(pid: u32) -> std::io::Result<()> {
    let pid = libc::pid_t::try_from(pid).map_err(|_| std::io::ErrorKind::InvalidInput)?;
    // SAFETY: pidfd_open and poll on a descriptor this function owns.
    unsafe {
        let fd = libc::syscall(libc::SYS_pidfd_open, pid, 0) as libc::c_int;
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            return if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) };
        }
        let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        while libc::poll(&mut poll, 1, -1) < 0
            && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
        {}
        libc::close(fd);
    }
    Ok(())
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
fn wait_for_process_exit(_pid: u32) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}

struct Expiry {
    muxes: Mutex<(Vec<Weak<Mux>>, u64)>,
    wake: Condvar,
}

fn expiry() -> &'static Expiry {
    static EXPIRY: OnceLock<Expiry> = OnceLock::new();
    EXPIRY.get_or_init(|| {
        let spawned = std::thread::Builder::new().name("cmux-status-expiry".into()).spawn(run_expiry);
        if let Err(error) = spawned {
            eprintln!("cmux-tui: status expiry thread failed to start: {error}");
        }
        Expiry { muxes: Mutex::new((Vec::new(), 0)), wake: Condvar::new() }
    })
}

/// Make the expiry thread look at `mux` again (a new or changed deadline).
fn schedule_expiry(mux: &Arc<Mux>) {
    let expiry = expiry();
    let mut guard = expiry.muxes.lock().unwrap();
    let weak = Arc::downgrade(mux);
    if !guard.0.iter().any(|known| known.ptr_eq(&weak)) {
        guard.0.push(weak);
    }
    guard.1 = guard.1.wrapping_add(1);
    expiry.wake.notify_all();
}

/// Sleep until the earliest deadline of any live daemon, clear what expired,
/// repeat. Woken early by `schedule_expiry`.
fn run_expiry() {
    let expiry = expiry();
    loop {
        let (muxes, generation) = {
            let mut guard = expiry.muxes.lock().unwrap();
            guard.0.retain(|mux| mux.strong_count() > 0);
            (guard.0.clone(), guard.1)
        };
        let mut next: Option<u64> = None;
        for mux in muxes.iter().filter_map(Weak::upgrade) {
            let now = crate::mux::now_ms();
            if let Err(error) = mux.clear_owned_workspace_status(&OwnerEnd::Expired { now_ms: now }) {
                eprintln!("cmux-tui: status expiry failed: {error}");
            }
            if let Ok(Some(deadline)) = mux.read_registry_state(status_meta::next_expiry_ms) {
                next = Some(next.map_or(deadline, |current| current.min(deadline)));
            }
        }
        let guard = expiry.muxes.lock().unwrap();
        if guard.1 != generation {
            continue;
        }
        match next {
            Some(deadline) => {
                let wait = Duration::from_millis(deadline.saturating_sub(crate::mux::now_ms()).max(1));
                drop(expiry.wake.wait_timeout_while(guard, wait, |state| state.1 == generation));
            }
            None => {
                drop(expiry.wake.wait_while(guard, |state| state.1 == generation));
            }
        }
    }
}

#[cfg(test)]
#[path = "status_owners_tests.rs"]
mod tests;
