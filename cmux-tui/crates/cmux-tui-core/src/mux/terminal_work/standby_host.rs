//! The terminal-host processes started ahead of the next new tabs (R81;
//! prepared with their PTY and shell launcher, new-terminal-100x).
//!
//! Most of a new tab's launch is starting its host process, then its PTY
//! and shell (login(1) alone prints its first text some 40 ms after it
//! starts). The owner keeps up to [`SPARES`] host processes started ahead
//! ([`StandbyTerminalHost`]). On Unix each is prepared for the latest new
//! tab's launch: it already runs its PTY and the shell's launcher, which
//! waits for the next tab's own ids (`terminal_host_runtime` shell_handoff).
//! A `new-tab` prelaunch adopts one and sends the tab's directory, command,
//! environment and size in the Launch frame; the host hands its prepared
//! launch over only when that is the same launch but the tab's ids, and
//! launches cold otherwise, so a spare never carries a previous tab's
//! environment. Rules:
//!
//! - Lazy: spares exist only after the first new tab of this owner, so a
//!   headless daemon that never opens a tab never starts one.
//! - Prepared for the latest launch: spares for an earlier one are dropped
//!   when a tab with another launch runs.
//! - Refills run on the terminal work pool, one at a time, up to the cap.
//! - A spare that died before adoption is dropped and the tab launches as
//!   before, with no error.
//! - Each prepared spare holds a PTY: a launch that finds none free drops
//!   them all, and none is kept until a launch succeeds again.
//! - Memory pressure (macOS) drops the spares.
//! - A spare never outlives the daemon: its bootstrap pipe's EOF ends its
//!   host, and closing its PTY hangs its prepared session up.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

use crate::terminal_host_runtime::{HostLaunch, StandbyTerminalHost};

/// Spares kept at most, all for the latest launch (new-terminal-100x: two,
/// so a quick second new tab also finds one).
pub(crate) const SPARES: usize = 2;

/// Which launch a spare was prepared for: the new tab's directory and
/// command as asked (before defaults), the cheap part of its launch.
pub(crate) type PrepareKey = (Option<String>, Option<Vec<String>>);

#[derive(Default)]
struct StandbyState {
    /// A new tab ran on this owner; spares are worth keeping from now on.
    wanted: bool,
    /// A refill job is queued or running.
    refilling: bool,
    /// Memory pressure is warning or critical: keep no spare until normal.
    suppressed: bool,
    /// The last launch found no free PTY: keep no spare (each holds a PTY)
    /// until a launch succeeds again.
    pty_starved: bool,
    /// The launch the next spares are prepared for (its key and Launch).
    prepare: Option<(PrepareKey, HostLaunch)>,
    hosts: Vec<(Option<PrepareKey>, StandbyTerminalHost)>,
}

/// Starts a spare process, prepared for a launch when one is given
/// ([`StandbyTerminalHost::spawn_prepared`]; tests start a stand-in).
pub(crate) type SpareSpawner = fn(Option<&HostLaunch>) -> anyhow::Result<StandbyTerminalHost>;

fn spawn_spare(prepare: Option<&HostLaunch>) -> anyhow::Result<StandbyTerminalHost> {
    #[cfg(unix)]
    if let Some(template) = prepare {
        return StandbyTerminalHost::spawn_prepared(template);
    }
    let _ = prepare;
    StandbyTerminalHost::spawn()
}

/// The spare host slot of one owner (up to [`SPARES`]).
pub(crate) struct StandbyHostSlot {
    state: Mutex<StandbyState>,
    spawn: SpareSpawner,
    #[cfg(target_os = "macos")]
    pressure: std::sync::OnceLock<()>,
}

impl Default for StandbyHostSlot {
    fn default() -> Self {
        Self::with_spawner(spawn_spare)
    }
}

impl StandbyHostSlot {
    /// The state; a poisoned lock still yields it (the memory-pressure
    /// handler runs in a C callback, where a panic would abort the daemon).
    fn state(&self) -> MutexGuard<'_, StandbyState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn with_spawner(spawn: SpareSpawner) -> Self {
        Self {
            state: Mutex::default(),
            spawn,
            #[cfg(target_os = "macos")]
            pressure: std::sync::OnceLock::new(),
        }
    }

    /// A spare for a new tab whose launch has `key`: one prepared for it
    /// first, else one prepared for nothing, else any (its host then
    /// launches cold). Marks spares as wanted. A spare killed before
    /// adoption is dropped: the tab launches as before, with no error.
    pub(crate) fn take(&self, key: Option<&PrepareKey>) -> Option<StandbyTerminalHost> {
        let mut host = {
            let mut state = self.state();
            state.wanted = true;
            let index = state
                .hosts
                .iter()
                .position(|(prepared, _)| key.is_some() && prepared.as_ref() == key)
                .or_else(|| state.hosts.iter().position(|(prepared, _)| prepared.is_none()))
                .or(if state.hosts.is_empty() { None } else { Some(0) })?;
            let (prepared, host) = state.hosts.remove(index);
            crate::debug_spans::mark(match prepared {
                Some(prepared) if key == Some(&prepared) => "spare.prepared_for_this_launch",
                Some(_) => "spare.prepared_for_another_launch",
                None => "spare.unprepared",
            });
            host
        };
        host.is_alive().then_some(host)
    }

    /// Spares from now on are prepared for `template`, the Launch of the
    /// tab whose launch had `key`; spares prepared for another launch are
    /// dropped (killed), so the refill prepares the latest one.
    pub(crate) fn prepare_for(&self, key: PrepareKey, template: HostLaunch) {
        let stale = {
            let mut state = self.state();
            state.pty_starved = false;
            let (keep, stale): (Vec<_>, Vec<_>) = std::mem::take(&mut state.hosts)
                .into_iter()
                .partition(|(prepared, _)| prepared.as_ref() == Some(&key));
            state.hosts = keep;
            state.prepare = Some((key, template));
            stale
        };
        drop(stale);
    }

    /// A launch found no free PTY: drop every spare (each holds one) and
    /// keep none until a launch succeeds. Returns how many it dropped.
    pub(crate) fn release_for_pty_capacity(&self) -> usize {
        let hosts = {
            let mut state = self.state();
            state.pty_starved = true;
            std::mem::take(&mut state.hosts)
        };
        hosts.len()
    }

    /// Whether a refill should start now; marks it started.
    fn begin_refill(&self) -> bool {
        let mut state = self.state();
        if !state.wanted
            || state.suppressed
            || state.pty_starved
            || state.refilling
            || state.hosts.len() >= SPARES
        {
            return false;
        }
        state.refilling = true;
        true
    }

    /// What the next spare is prepared for.
    fn next_prepare(&self) -> Option<(PrepareKey, HostLaunch)> {
        self.state().prepare.clone()
    }

    /// A refill finished with `spawned` (prepared for `key`); a spare that is
    /// no longer wanted (dropped meanwhile, or the slot full) is killed as it
    /// drops. Returns whether another spare is still wanted.
    fn finish_refill(&self, key: Option<PrepareKey>, spawned: Option<StandbyTerminalHost>) -> bool {
        let (unused, more) = {
            let mut state = self.state();
            state.refilling = false;
            let room = state.wanted
                && !state.suppressed
                && !state.pty_starved
                && state.hosts.len() < SPARES
                && (key.is_none()
                    || state.prepare.as_ref().map(|(current, _)| current) == key.as_ref());
            let unused = match spawned {
                Some(host) if room => {
                    state.hosts.push((key, host));
                    None
                }
                other => other,
            };
            let more = room && unused.is_none() && state.hosts.len() < SPARES;
            (unused, more)
        };
        drop(unused);
        more
    }

    /// Memory pressure changed: under warning or critical pressure the
    /// spares are dropped and no new one starts; back to normal, the next
    /// new tab refills them.
    #[cfg(any(target_os = "macos", test))]
    pub(crate) fn set_memory_pressure(&self, pressured: bool) {
        let hosts = {
            let mut state = self.state();
            state.suppressed = pressured;
            if pressured { std::mem::take(&mut state.hosts) } else { Vec::new() }
        };
        drop(hosts);
    }

    #[cfg(test)]
    pub(crate) fn has_spare(&self) -> bool {
        !self.state().hosts.is_empty()
    }

    #[cfg(test)]
    pub(crate) fn spares(&self) -> usize {
        self.state().hosts.len()
    }

    #[cfg(test)]
    pub(crate) fn finish_refill_for_test(&self, host: StandbyTerminalHost) {
        self.state().refilling = true;
        self.finish_refill(None, Some(host));
    }

    /// Starts refills on `pool` until [`SPARES`] spares exist, one at a time,
    /// when spares are wanted.
    pub(crate) fn refill(self: &Arc<Self>, pool: &super::TerminalWorkPool) {
        if !self.begin_refill() {
            return;
        }
        #[cfg(target_os = "macos")]
        self.pressure.get_or_init(|| memory_pressure::watch(Arc::downgrade(self)));
        let slot: Weak<Self> = Arc::downgrade(self);
        let spawn = self.spawn;
        let job: Box<dyn FnOnce() + Send> = Box::new(move || {
            loop {
                let Some(current) = slot.upgrade() else { return };
                let prepare = current.next_prepare();
                drop(current);
                let spawned = spawn(prepare.as_ref().map(|(_, template)| template)).ok();
                let Some(current) = slot.upgrade() else { return };
                if !current.finish_refill(prepare.map(|(key, _)| key), spawned)
                    || !current.begin_refill()
                {
                    return;
                }
            }
        });
        if let Err(job) = pool.try_submit(job) {
            // A saturated pool: skip this refill rather than start a process
            // inline on the caller's thread; the next new tab tries again.
            drop(job);
            self.state().refilling = false;
        }
    }
}

/// Memory pressure through libdispatch (macOS): warning or critical drops the
/// spare and stops refills until pressure is normal again. Event-driven; no
/// thread or timer of our own.
#[cfg(target_os = "macos")]
mod memory_pressure {
    use std::ffi::c_void;
    use std::sync::Weak;

    use super::StandbyHostSlot;

    #[allow(non_camel_case_types)]
    type dispatch_object_t = *mut c_void;
    const DISPATCH_MEMORYPRESSURE_NORMAL: usize = 0x01;
    const DISPATCH_MEMORYPRESSURE_WARN: usize = 0x02;
    const DISPATCH_MEMORYPRESSURE_CRITICAL: usize = 0x04;

    unsafe extern "C" {
        static _dispatch_source_type_memorypressure: c_void;
        fn dispatch_get_global_queue(identifier: isize, flags: usize) -> dispatch_object_t;
        fn dispatch_source_create(
            kind: *const c_void,
            handle: usize,
            mask: usize,
            queue: dispatch_object_t,
        ) -> dispatch_object_t;
        fn dispatch_set_context(object: dispatch_object_t, context: *mut c_void);
        fn dispatch_source_set_event_handler_f(
            source: dispatch_object_t,
            handler: extern "C" fn(*mut c_void),
        );
        fn dispatch_resume(object: dispatch_object_t);
        fn dispatch_source_get_data(source: dispatch_object_t) -> usize;
    }

    /// The source, for reading the pressure level in the handler.
    struct Watch {
        slot: Weak<StandbyHostSlot>,
        source: dispatch_object_t,
    }

    extern "C" fn on_pressure(context: *mut c_void) {
        // SAFETY: the context is the leaked `Watch` set in `watch`, alive for
        // the source's lifetime (the process); its source is that source.
        let watch = unsafe { &*(context as *const Watch) };
        let level = unsafe { dispatch_source_get_data(watch.source) };
        if let Some(slot) = watch.slot.upgrade() {
            slot.set_memory_pressure(level & DISPATCH_MEMORYPRESSURE_NORMAL == 0);
        }
    }

    /// Watches memory pressure for `slot` for the rest of the process.
    pub(super) fn watch(slot: Weak<StandbyHostSlot>) {
        // SAFETY: plain libdispatch calls on a source this function creates;
        // the context outlives it (leaked, one per owner that made a spare).
        unsafe {
            let queue = dispatch_get_global_queue(0, 0);
            let source = dispatch_source_create(
                &raw const _dispatch_source_type_memorypressure,
                0,
                DISPATCH_MEMORYPRESSURE_NORMAL
                    | DISPATCH_MEMORYPRESSURE_WARN
                    | DISPATCH_MEMORYPRESSURE_CRITICAL,
                queue,
            );
            if source.is_null() {
                return;
            }
            dispatch_set_context(source, Box::into_raw(Box::new(Watch { slot, source })).cast());
            dispatch_source_set_event_handler_f(source, on_pressure);
            dispatch_resume(source);
        }
    }
}

#[cfg(all(test, unix))]
#[path = "standby_host_tests.rs"]
mod tests;
