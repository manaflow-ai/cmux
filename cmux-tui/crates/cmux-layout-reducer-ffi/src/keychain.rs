//! `cmux_keychain_bounded`: the app's calls into its own Keychain items, each bounded by
//! `cmux-cloud-config`'s [`keychain::DEADLINE`].
//!
//! A Security call cannot be cancelled: a Keychain that is locked, asking for its password, or stuck holds the
//! calling thread until it answers, which may be never. So the app hands the call to Rust: [`Gate::run`] runs it on
//! a thread of its own and answers its result, or nothing once the deadline passes, and the C entry then gives the
//! app [`keychain::refusal`], which names the item. The thread a stuck call holds stays parked in the Keychain;
//! at most one per item, since a later call on an item whose call is still running waits for it within its own
//! deadline, and one whose earlier call is already past the deadline is refused at once, never stacking another.

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::{Arc, Condvar, LazyLock, Mutex, MutexGuard, PoisonError, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use cmux_cloud_config::keychain::{self, Item};

use crate::{ERR_INVALID, ERR_NULL, OK, input};

/// The process's gate: every call of the C entry goes through it, so one stuck item is known to all callers.
static GATE: LazyLock<Gate> = LazyLock::new(Gate::default);

/// The Keychain calls in flight, by item, and when each started.
#[derive(Clone, Default)]
pub struct Gate {
    inner: Arc<Inner>,
}

#[derive(Default)]
struct Inner {
    calls: Mutex<HashMap<Item, Instant>>,
    ended: Condvar,
}

impl Inner {
    fn calls(&self) -> MutexGuard<'_, HashMap<Item, Instant>> {
        self.calls.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Ends a call's entry when its work returns or unwinds, so a panicking call never marks its item stuck for good.
struct Running {
    inner: Arc<Inner>,
    item: Item,
}

impl Drop for Running {
    fn drop(&mut self) {
        self.inner.calls().remove(&self.item);
        self.inner.ended.notify_all();
    }
}

impl Gate {
    /// Runs `work`, the Keychain call on `item`, on its own thread: its answer, or `None` when `deadline` passes
    /// first. A call on an item whose earlier call still runs waits for that one within the same `deadline`; when
    /// the earlier one is already past `deadline` (the Keychain is stuck on the item), it answers `None` at once and
    /// `work` never runs.
    pub fn run<T: Send + 'static>(
        &self,
        item: &Item,
        deadline: Duration,
        work: impl FnOnce() -> T + Send + 'static,
    ) -> Option<T> {
        let end = Instant::now() + deadline;
        let mut calls = self.inner.calls();
        while let Some(&started) = calls.get(item) {
            let now = Instant::now();
            let stuck = started + deadline;
            if now >= stuck || now >= end {
                return None;
            }
            calls = self
                .inner
                .ended
                .wait_timeout(calls, stuck.min(end) - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        calls.insert(item.clone(), Instant::now());
        drop(calls);
        let running = Running { inner: Arc::clone(&self.inner), item: item.clone() };
        let (answered, answer) = mpsc::sync_channel(1);
        let spawned = thread::Builder::new().name("cmux-keychain".into()).spawn(move || {
            let _running = running;
            let _ = answered.send(work());
        });
        // A thread that could not start drops `running` (and `work`) with the closure: the item is free again.
        spawned.ok()?;
        answer.recv_timeout(end.saturating_duration_since(Instant::now())).ok()
    }
}

/// The Keychain call: makes it with `context` and keeps its own result there.
pub type Work = unsafe extern "C" fn(context: *mut c_void);
/// The outcome: `answered` 1 when `work` returned within the deadline (its result is in `context`); 0 with
/// `refusal` (`refusal_len` bytes of JSON, valid for this call only) when it did not.
pub type Done = unsafe extern "C" fn(
    context: *mut c_void,
    answered: u8,
    refusal: *const u8,
    refusal_len: usize,
);
/// Frees `context`, once `work` (if it ran) and `done` both returned.
pub type Release = unsafe extern "C" fn(context: *mut c_void);

/// The app's context: shared by the work thread and the waiter, released when the last of them lets go. A call
/// that never returns keeps it (and its thread) for good, which is the cost of a call that cannot be cancelled.
struct Context {
    pointer: *mut c_void,
    release: Release,
}

// SAFETY: the C caller promises `context` and its callbacks may be used from any thread (cmux_keychain_bounded).
unsafe impl Send for Context {}
// SAFETY: as above; Rust never reads through the pointer, it only hands it back to the caller's callbacks.
unsafe impl Sync for Context {}

impl Drop for Context {
    fn drop(&mut self) {
        // SAFETY: called exactly once, after the last callback that used the pointer returned.
        unsafe { (self.release)(self.pointer) }
    }
}

/// Runs one Keychain call within `deadline` through `gate`; what [`cmux_keychain_bounded`] does with the process's
/// gate and [`keychain::DEADLINE`] (tests pass their own).
///
/// # Safety
///
/// As [`cmux_keychain_bounded`].
pub unsafe fn bounded(
    gate: &Gate,
    deadline: Duration,
    request: &[u8],
    context: *mut c_void,
    work: Work,
    done: Done,
    release: Release,
) -> i32 {
    let Ok(item) = serde_json::from_slice::<Item>(request) else { return ERR_INVALID };
    let context = Arc::new(Context { pointer: context, release });
    let gate = gate.clone();
    let waiter = Arc::clone(&context);
    let started = thread::Builder::new().name("cmux-keychain-wait".into()).spawn(move || {
        let worker = Arc::clone(&waiter);
        // SAFETY: the caller's callback, with its own context, on a thread of ours (allowed by the caller).
        let answered = gate.run(&item, deadline, move || unsafe { work(worker.pointer) }).is_some();
        let refusal = if answered {
            Vec::new()
        } else {
            keychain::refusal(&item, deadline).to_string().into_bytes()
        };
        // SAFETY: as above; `refusal` outlives the call.
        unsafe { done(waiter.pointer, u8::from(answered), refusal.as_ptr(), refusal.len()) };
    });
    match started {
        Ok(_) => OK,
        Err(_) => {
            // Nothing was called: the caller keeps its context and frees it itself.
            if let Ok(context) = Arc::try_unwrap(context) {
                std::mem::forget(context);
            }
            crate::ERR_PANIC
        }
    }
}

/// Runs one Keychain call of the app's own, `request` `{service, account}` (the item it reads or writes), within
/// [`keychain::DEADLINE`]: `work(context)` runs on a thread of Rust's, then `done(context, …)` once, on another, with
/// `answered` 1 when the call returned in time, else 0 and the refusal naming the item; then
/// `release(context)`, once both returned. A call that never returns never reaches `release`. Answers `OK` right
/// away, never waiting on the call; any other code (a bad request, no thread) means no callback ran and the caller
/// still owns `context`.
///
/// # Safety
///
/// `request` points to `request_len` readable bytes (or is null with length 0). `context` and the three callbacks
/// may be used from any thread, until `release`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_keychain_bounded(
    request: *const u8,
    request_len: usize,
    context: *mut c_void,
    work: Option<Work>,
    done: Option<Done>,
    release: Option<Release>,
) -> i32 {
    let Some(request) = (unsafe { input(request, request_len) }) else { return ERR_NULL };
    let (Some(work), Some(done), Some(release)) = (work, done, release) else { return ERR_NULL };
    // SAFETY: the caller's promises, passed on.
    unsafe { bounded(&GATE, keychain::DEADLINE, request, context, work, done, release) }
}
