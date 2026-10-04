//! The one terminal-host process started ahead of the next new tab (R81).
//!
//! Most of a new tab's launch is starting its host process. The owner keeps
//! at most one host process that has only run `exec` and waits on its
//! bootstrap pipe ([`StandbyTerminalHost`]): no identity, no PTY, no child,
//! no timers, so it uses no CPU. A `new-tab` prelaunch adopts it and sends
//! the tab's directory, command, environment and size in the Launch frame,
//! so the spare never carries a previous tab's environment. Rules:
//!
//! - Lazy: the spare exists only after the first new tab of this owner, so a
//!   headless daemon that never opens a tab never starts one.
//! - A burst of new tabs takes the spare once; the rest launch as before. The
//!   refill runs on the terminal work pool, one at a time, cap one spare.
//! - A spare that died before adoption is dropped and the tab launches as
//!   before, with no error.
//! - Memory pressure (macOS) drops the spare.

use std::sync::{Arc, Mutex, Weak};

use crate::terminal_host_runtime::StandbyTerminalHost;

#[derive(Default)]
struct StandbyState {
    /// A new tab ran on this owner; spares are worth keeping from now on.
    wanted: bool,
    /// A refill job is queued or running.
    refilling: bool,
    host: Option<StandbyTerminalHost>,
}

/// The spare host slot of one owner (cap one).
pub(crate) struct StandbyHostSlot {
    state: Mutex<StandbyState>,
    /// Starts a spare process ([`StandbyTerminalHost::spawn`]; tests start a
    /// stand-in that also waits on its stdin).
    spawn: fn() -> anyhow::Result<StandbyTerminalHost>,
    #[cfg(target_os = "macos")]
    pressure: std::sync::OnceLock<()>,
}

impl Default for StandbyHostSlot {
    fn default() -> Self {
        Self::with_spawner(StandbyTerminalHost::spawn)
    }
}

impl StandbyHostSlot {
    pub(crate) fn with_spawner(spawn: fn() -> anyhow::Result<StandbyTerminalHost>) -> Self {
        Self {
            state: Mutex::default(),
            spawn,
            #[cfg(target_os = "macos")]
            pressure: std::sync::OnceLock::new(),
        }
    }

    /// The spare for a new tab, if one is alive; marks spares as wanted.
    /// A spare killed before adoption is dropped here: the tab launches as
    /// before, with no error.
    pub(crate) fn take(&self) -> Option<StandbyTerminalHost> {
        let mut host = {
            let mut state = self.state.lock().unwrap();
            state.wanted = true;
            state.host.take()?
        };
        host.is_alive().then_some(host)
    }

    /// Whether a refill should start now; marks it started.
    fn begin_refill(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        if !state.wanted || state.refilling || state.host.is_some() {
            return false;
        }
        state.refilling = true;
        true
    }

    /// A refill finished with `spawned`; a spare that is no longer wanted
    /// (dropped meanwhile, or the slot filled) is killed as it drops.
    fn finish_refill(&self, spawned: Option<StandbyTerminalHost>) {
        let unused = {
            let mut state = self.state.lock().unwrap();
            state.refilling = false;
            if state.wanted && state.host.is_none() {
                state.host = spawned;
                None
            } else {
                spawned
            }
        };
        drop(unused);
    }

    /// Drops the spare (memory pressure); the next new tab refills it.
    pub(crate) fn drop_spare(&self) {
        let host = self.state.lock().unwrap().host.take();
        drop(host);
    }

    #[cfg(test)]
    pub(crate) fn has_spare(&self) -> bool {
        self.state.lock().unwrap().host.is_some()
    }

    #[cfg(test)]
    pub(crate) fn finish_refill_for_test(&self, host: StandbyTerminalHost) {
        self.state.lock().unwrap().refilling = true;
        self.finish_refill(Some(host));
    }

    /// Starts one refill on `pool` when a spare is wanted and none exists.
    pub(crate) fn refill(self: &Arc<Self>, pool: &super::TerminalWorkPool) {
        if !self.begin_refill() {
            return;
        }
        #[cfg(target_os = "macos")]
        self.pressure.get_or_init(|| memory_pressure::watch(Arc::downgrade(self)));
        let slot: Weak<Self> = Arc::downgrade(self);
        let spawn = self.spawn;
        let job: Box<dyn FnOnce() + Send> = Box::new(move || {
            let spawned = spawn().ok();
            match slot.upgrade() {
                Some(slot) => slot.finish_refill(spawned),
                None => drop(spawned),
            }
        });
        if let Err(job) = pool.try_submit(job) {
            // A saturated pool: skip this refill rather than start a process
            // inline on the caller's thread; the next new tab tries again.
            drop(job);
            self.state.lock().unwrap().refilling = false;
        }
    }
}

/// Memory pressure through libdispatch (macOS): a warning or critical event
/// drops the spare. Event-driven; no thread or timer of our own.
#[cfg(target_os = "macos")]
mod memory_pressure {
    use std::ffi::c_void;
    use std::sync::Weak;

    use super::StandbyHostSlot;

    #[allow(non_camel_case_types)]
    type dispatch_object_t = *mut c_void;
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
    }

    extern "C" fn on_pressure(context: *mut c_void) {
        // SAFETY: the context is the leaked `Weak` set in `watch`, alive for
        // the source's lifetime (the process).
        let slot = unsafe { &*(context as *const Weak<StandbyHostSlot>) };
        if let Some(slot) = slot.upgrade() {
            slot.drop_spare();
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
                DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
                queue,
            );
            if source.is_null() {
                return;
            }
            dispatch_set_context(source, Box::into_raw(Box::new(slot)).cast());
            dispatch_source_set_event_handler_f(source, on_pressure);
            dispatch_resume(source);
        }
    }
}

#[cfg(test)]
#[path = "standby_host_tests.rs"]
mod tests;
