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
use std::sync::{Condvar, Mutex, MutexGuard, OnceLock, PoisonError, Weak};
use std::time::Duration;

use serde_json::json;

use crate::Mux;
use crate::resource::TerminalPublicId;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::status_meta::{self, OwnerEnd, OwnerProcess};
use crate::state::store::{StateChanges, StateCommit, state_upsert};
use crate::state::workspace_status_store as status;

impl Mux {
    /// Remove every status entry `end` owns, in one commit. `None` when
    /// nothing was owned.
    pub(crate) fn clear_owned_workspace_status(
        &self,
        end: &OwnerEnd,
    ) -> anyhow::Result<Option<StateCommit>> {
        if self
            .read_registry_state(|connection| status_meta::owned_entries(connection, end))?
            .is_empty()
        {
            return Ok(None);
        }
        let mutation = WorkspaceMutation::daemon_local("workspace_status.auto_clear");
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
        self.machine_public_id.as_str().to_owned()
    }
}

/// Start watching every owner a just-committed entry names. Called after a
/// successful `workspace_status.set` and once at daemon start.
pub(crate) fn watch_owners(
    mux: &Arc<Mux>,
    terminal: Option<&str>,
    pid: Option<u32>,
    has_ttl: bool,
) {
    if let Some(terminal) = terminal {
        watch_terminal(mux, terminal.to_owned());
    }
    if let Some(pid) = pid {
        match OwnerProcess::current(pid) {
            Some(process) => watch_process(mux, process),
            // It ended between the commit and now: no process runs under
            // this pid, so every entry recorded for it is dead.
            None => clear_now(
                mux,
                &OwnerEnd::Process { pid, machine: mux.status_machine_id(), started: None },
            ),
        }
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
        Ok((terminals, processes)) => {
            for terminal in terminals {
                watch_terminal(mux, terminal);
            }
            for recorded in processes {
                // A pid reused by another process is not the owner.
                match OwnerProcess::current(recorded.pid) {
                    Some(current) if recorded.started == 0 || current == recorded => {
                        watch_process(mux, current);
                    }
                    // Another process holds the pid now: only the rows of
                    // the recorded start time are dead.
                    Some(_) => clear_now(
                        mux,
                        &OwnerEnd::Process {
                            pid: recorded.pid,
                            machine: machine.clone(),
                            started: Some(recorded.started),
                        },
                    ),
                    None => clear_now(
                        mux,
                        &OwnerEnd::Process {
                            pid: recorded.pid,
                            machine: machine.clone(),
                            started: None,
                        },
                    ),
                }
            }
        }
        Err(error) => eprintln!("cmux-tui: status owner resume failed: {error}"),
    }
    // Only a daemon with a TTL to keep joins the expiry thread, which holds
    // a strong handle while it looks at one.
    if !matches!(mux.read_registry_state(status_meta::next_expiry_ms), Ok(None)) {
        schedule_expiry(mux);
    }
}

fn clear_now(mux: &Mux, end: &OwnerEnd) {
    if let Err(error) = mux.clear_owned_workspace_status(end) {
        eprintln!("cmux-tui: clearing owned status failed: {error}");
    }
}

/// A poisoned lock still guards plain data here (sets and lists of weak
/// handles), so a panic elsewhere never stops auto-clear.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn mux_key(mux: &Arc<Mux>) -> usize {
    Arc::as_ptr(mux) as usize
}

fn watched() -> &'static Mutex<HashSet<(usize, String)>> {
    static WATCHED: OnceLock<Mutex<HashSet<(usize, String)>>> = OnceLock::new();
    WATCHED.get_or_init(Default::default)
}

/// What a watch saw.
enum Watch {
    /// The owner ended: remove its entries.
    Ended,
    /// The watch could not be armed or failed; the owner may still run, so
    /// its entries stay (a TTL or an explicit clear still removes them).
    Failed,
}

/// Run `wait` on its own thread once per `(mux, label)`, then clear `end`
/// when the owner ended.
fn spawn_watch(
    mux: &Arc<Mux>,
    label: String,
    end: OwnerEnd,
    wait: impl FnOnce(&Weak<Mux>) -> Watch + Send + 'static,
) {
    let key = (mux_key(mux), label);
    if !lock(watched()).insert(key.clone()) {
        return;
    }
    let weak = Arc::downgrade(mux);
    let thread_key = key.clone();
    let spawned = std::thread::Builder::new().name("cmux-status-owner".into()).spawn(move || {
        let outcome = wait(&weak);
        lock(watched()).remove(&thread_key);
        if let (Watch::Ended, Some(mux)) = (outcome, weak.upgrade()) {
            clear_now(&mux, &end);
        }
    });
    if let Err(error) = spawned {
        lock(watched()).remove(&key);
        eprintln!("cmux-tui: status owner watch failed to start: {error}");
    }
}

/// Watch a terminal owner through the session host's exit subscription. The
/// wait holds the daemon while it blocks; a terminal ends with its daemon.
const TERMINAL_WAIT_SLICE: Duration = Duration::from_secs(30);

fn watch_terminal(mux: &Arc<Mux>, terminal: String) {
    let end = OwnerEnd::Terminal { terminal: terminal.clone() };
    spawn_watch(mux, format!("terminal:{terminal}"), end, move |weak| {
        let Ok(id) = TerminalPublicId::parse(terminal) else { return Watch::Failed };
        let mut backoff = Duration::from_secs(1);
        loop {
            // A bounded wait, so the watch never keeps a dropped or
            // shutting-down daemon alive for long.
            let Some(mux) = weak.upgrade() else { return Watch::Failed };
            if mux.daemon_shutdown_requested() {
                return Watch::Failed;
            }
            match mux.wait_for_terminal_exit(&id, Some(TERMINAL_WAIT_SLICE)) {
                Ok(state) if state["state"] == "exited" => return Watch::Ended,
                Ok(_) => {}
                // The session host no longer knows the terminal: it is gone.
                Err(error) if is_gone(&error) => return Watch::Ended,
                Err(error) => {
                    eprintln!("cmux-tui: watching terminal {id} failed: {error}; retrying");
                    drop(mux);
                    std::thread::sleep(backoff);
                    backoff = (backoff * 2).min(Duration::from_secs(60));
                }
            }
        }
    });
}

/// The session host no longer runs the terminal: unknown, never placed, or
/// closed (tombstoned) without an exit record.
fn is_gone(error: &anyhow::Error) -> bool {
    if error.downcast_ref::<ResourceError>().is_some_and(|error| error.code == "terminal.closed") {
        return true;
    }
    let text = error.to_string();
    text.contains("is not live") || text.contains("no durable placement")
}

/// Watch a process owner through the kernel's exit notification. The wait
/// holds no daemon reference.
fn watch_process(mux: &Arc<Mux>, process: OwnerProcess) {
    let end = OwnerEnd::Process {
        pid: process.pid,
        machine: mux.status_machine_id(),
        started: Some(process.started),
    };
    spawn_watch(mux, format!("pid:{}:{}", process.pid, process.started), end, move |_| {
        match wait_for_process_exit(process.pid) {
            Ok(()) => Watch::Ended,
            Err(error) => {
                eprintln!("cmux-tui: cannot watch process {}: {error}", process.pid);
                Watch::Failed
            }
        }
    });
}

/// Whether `pid` names a running process this daemon may signal (and so
/// watch): `kill(pid, 0)` succeeds.
#[cfg(unix)]
pub(crate) fn process_is_running(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: signal 0 performs only the existence and permission check.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// No process owners where the daemon cannot watch a process exit.
#[cfg(not(unix))]
pub(crate) fn process_is_running(_pid: u32) -> bool {
    false
}

/// Block until `pid` exits. `Ok` at once when it is not running.
#[cfg(any(target_vendor = "apple", target_os = "linux"))]
fn wait_for_process_exit(pid: u32) -> std::io::Result<()> {
    wait_for_process_exit_if(pid, || true)
}

/// Block until `pid` exits. `still_ours` runs once the watch holds the
/// process (registered on macOS, a pidfd on Linux): false (another process
/// took a reused pid before the watch began) returns `Ok` at once, as an
/// exit. `Ok` at once when it is not running.
#[cfg(target_vendor = "apple")]
pub(crate) fn wait_for_process_exit_if(
    pid: u32,
    still_ours: impl FnOnce() -> bool,
) -> std::io::Result<()> {
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
        change.flags = libc::EV_ADD | libc::EV_ONESHOT | libc::EV_RECEIPT;
        change.fflags = libc::NOTE_EXIT;
        let mut event: libc::kevent = std::mem::zeroed();
        // EV_RECEIPT: registration reports its outcome as an EV_ERROR event.
        let registered = libc::kevent(queue, &change, 1, &mut event, 1, std::ptr::null());
        let outcome = if registered < 0 {
            Err(std::io::Error::last_os_error())
        } else if event.flags & libc::EV_ERROR != 0 && event.data != 0 {
            let code = i32::try_from(event.data).unwrap_or(libc::EINVAL);
            if code == libc::ESRCH { Ok(()) } else { Err(std::io::Error::from_raw_os_error(code)) }
        } else if !still_ours() {
            Ok(())
        } else {
            loop {
                let ready =
                    libc::kevent(queue, std::ptr::null(), 0, &mut event, 1, std::ptr::null());
                if ready > 0 {
                    break Ok(());
                }
                let error = std::io::Error::last_os_error();
                if ready < 0 && error.kind() != std::io::ErrorKind::Interrupted {
                    break Err(error);
                }
            }
        };
        libc::close(queue);
        outcome
    }
}

/// `wait_for_process_exit_if` on Linux (a pidfd).
#[cfg(target_os = "linux")]
pub(crate) fn wait_for_process_exit_if(
    pid: u32,
    still_ours: impl FnOnce() -> bool,
) -> std::io::Result<()> {
    let pid = libc::pid_t::try_from(pid).map_err(|_| std::io::ErrorKind::InvalidInput)?;
    // SAFETY: pidfd_open and poll on a descriptor this function owns.
    unsafe {
        let fd = libc::syscall(libc::SYS_pidfd_open, pid, 0) as libc::c_int;
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            return if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) };
        }
        if !still_ours() {
            libc::close(fd);
            return Ok(());
        }
        let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let outcome = loop {
            if libc::poll(&mut poll, 1, -1) >= 0 {
                break Ok(());
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                break Err(error);
            }
        };
        libc::close(fd);
        outcome
    }
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
        let spawned =
            std::thread::Builder::new().name("cmux-status-expiry".into()).spawn(run_expiry);
        if let Err(error) = spawned {
            eprintln!("cmux-tui: status expiry thread failed to start: {error}");
        }
        Expiry { muxes: Mutex::new((Vec::new(), 0)), wake: Condvar::new() }
    })
}

/// Make the expiry thread look at `mux` again (a new or changed deadline).
fn schedule_expiry(mux: &Arc<Mux>) {
    let expiry = expiry();
    let mut guard = lock(&expiry.muxes);
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
    let mut failures: u32 = 0;
    loop {
        let (muxes, generation) = {
            let mut guard = lock(&expiry.muxes);
            guard.0.retain(|mux| mux.strong_count() > 0);
            (guard.0.clone(), guard.1)
        };
        let mut next: Option<u64> = None;
        let mut failed = false;
        let mut idle: Vec<Weak<Mux>> = Vec::new();
        for weak in &muxes {
            let Some(mux) = weak.upgrade() else { continue };
            let now = crate::mux::now_ms();
            if let Err(error) = mux.clear_owned_workspace_status(&OwnerEnd::Expired { now_ms: now })
            {
                eprintln!("cmux-tui: status expiry failed: {error}");
                failed = true;
            }
            match mux.read_registry_state(status_meta::next_expiry_ms) {
                Ok(Some(deadline)) => {
                    next = Some(next.map_or(deadline, |current| current.min(deadline)));
                }
                // No deadline left: leave the list until a new TTL arrives.
                Ok(None) => idle.push(weak.clone()),
                Err(error) => {
                    eprintln!("cmux-tui: reading the next status expiry failed: {error}");
                    failed = true;
                }
            }
        }
        // After a failure the expired row stays; retry with a growing delay
        // (1 s to about 4 min) instead of spinning on a past deadline.
        failures = if failed { failures.saturating_add(1) } else { 0 };
        if failures > 0 {
            next = Some(crate::mux::now_ms().saturating_add(1_000u64 << failures.min(8)));
        }
        let mut guard = lock(&expiry.muxes);
        if guard.1 != generation {
            continue;
        }
        guard.0.retain(|known| !idle.iter().any(|weak| weak.ptr_eq(known)));
        match next {
            Some(deadline) => {
                let wait =
                    Duration::from_millis(deadline.saturating_sub(crate::mux::now_ms()).max(1));
                drop(expiry.wake.wait_timeout_while(guard, wait, |state| state.1 == generation));
            }
            None => {
                drop(expiry.wake.wait_while(guard, |state| state.1 == generation));
            }
        }
    }
}
