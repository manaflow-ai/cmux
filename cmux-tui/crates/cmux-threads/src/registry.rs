//! The process's thread registry: one row per cmux thread, with its name,
//! declared QoS, desired-QoS slot, effective QoS, scheduler priority and
//! native ids.
//!
//! A row's desired QoS is a [`DesiredQos`] that another thread sets and the
//! row's thread applies itself with [`crate::apply_pending_qos`] at the top
//! of its loop, so a change costs no wake and no cross-thread syscall.
//! Chromium changes a thread's type only from the thread itself
//! (`PlatformThread::SetCurrentThreadType`, base/threading/platform_thread.h).
//! Threads of one owner (a terminal) can share one [`DesiredQos`].
//!
//! A thread's row lives in a thread-local of this crate and is removed when
//! the thread deregisters (at the end of [`crate::spawn`], or by its
//! thread-local destructor), always before the thread exits. Callers cannot
//! keep a row alive past its thread, which is what makes the live-QoS read in
//! [`snapshot`] sound.
//!
//! Lock carve-out: the row list is one std `Mutex`, held only to push or
//! remove a row and for [`snapshot`]'s per-row reads (no I/O, no waits), as
//! Chromium's `ThreadIdNameManager` (base/threading/thread_id_name_manager.cc)
//! holds its lock. The per-thread fields are atomics: no QoS change or
//! request takes the lock.

use std::cell::RefCell;
use std::sync::atomic::{AtomicU8, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use crate::qos::{self, LiveQos, QosChange, ThreadQos};

/// The native ids of a registered thread.
#[derive(Clone, Copy, Debug)]
pub(crate) struct NativeThread {
    tid: Option<u64>,
    #[cfg(target_vendor = "apple")]
    pthread: usize,
}

impl NativeThread {
    fn current() -> Self {
        Self {
            tid: current_tid(),
            // SAFETY: pthread_self has no preconditions.
            #[cfg(target_vendor = "apple")]
            pthread: unsafe { libc::pthread_self() } as usize,
        }
    }

    pub(crate) fn tid(&self) -> Option<u64> {
        self.tid
    }

    #[cfg(target_vendor = "apple")]
    pub(crate) fn pthread(&self) -> libc::pthread_t {
        self.pthread as libc::pthread_t
    }
}

/// The kernel thread id of the calling thread.
pub(crate) fn current_tid() -> Option<u64> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        // SAFETY: gettid has no preconditions.
        let tid = unsafe { libc::syscall(libc::SYS_gettid) };
        (tid > 0).then_some(tid as u64)
    }
    #[cfg(target_vendor = "apple")]
    {
        let mut tid = 0u64;
        // SAFETY: a null pthread means the calling thread; `tid` is valid.
        let rc = unsafe { libc::pthread_threadid_np(0 as libc::pthread_t, &mut tid) };
        (rc == 0).then_some(tid)
    }
    #[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple")))]
    {
        None
    }
}

/// `Row::effective` before the thread's first QoS change succeeds.
const NOT_APPLIED: u8 = u8::MAX;

/// A QoS that one or more threads are asked to run at. The owner of the
/// threads requests a class; each thread that follows it applies the class
/// at its next [`crate::apply_pending_qos`].
#[derive(Clone, Debug)]
pub struct DesiredQos(Arc<AtomicU8>);

impl DesiredQos {
    /// A desired QoS that starts at `qos`.
    pub fn new(qos: ThreadQos) -> Self {
        Self(Arc::new(AtomicU8::new(qos as u8)))
    }

    /// Asks the following threads to run at `qos`. True when that changed
    /// the request.
    pub fn request(&self, qos: ThreadQos) -> bool {
        self.0.swap(qos as u8, Ordering::Relaxed) != qos as u8
    }

    /// The QoS last requested.
    pub fn get(&self) -> ThreadQos {
        ThreadQos::from_u8(self.0.load(Ordering::Relaxed))
    }
}

/// One registered thread.
#[derive(Debug)]
pub(crate) struct Row {
    name: String,
    declared: ThreadQos,
    desired: DesiredQos,
    /// The desired QoS the thread last acted on (applied or refused), so
    /// an unchanged request costs no syscall.
    acted: AtomicU8,
    effective: AtomicU8,
    refused: AtomicU32,
    native: NativeThread,
}

impl Row {
    pub(crate) fn effective(&self) -> Option<ThreadQos> {
        match self.effective.load(Ordering::Relaxed) {
            NOT_APPLIED => None,
            raw => Some(ThreadQos::from_u8(raw)),
        }
    }

    pub(crate) fn set_effective(&self, qos: Option<ThreadQos>) {
        self.effective.store(qos.map_or(NOT_APPLIED, |qos| qos as u8), Ordering::Relaxed);
    }

    /// The class the thread runs at by its own changes: the last one that
    /// succeeded, else the class it was registered with (a refused change
    /// still says what it wants).
    pub(crate) fn class(&self) -> ThreadQos {
        self.effective().unwrap_or(self.declared)
    }

    pub(crate) fn record_refusal(&self) {
        self.refused.fetch_add(1, Ordering::Relaxed);
    }

    /// The desired QoS when it changed since the thread last acted on it,
    /// marked as acted on.
    pub(crate) fn take_pending(&self) -> Option<ThreadQos> {
        let desired = self.desired.get();
        (self.acted.swap(desired as u8, Ordering::Relaxed) != desired as u8).then_some(desired)
    }
}

/// A handle to a registered thread's desired-QoS slot. Another thread stores
/// the QoS it wants the owner to run at; the owner reads it at a point of its
/// choosing and applies it with [`qos::set_current`].
#[derive(Clone, Debug)]
pub struct QosSlot(Arc<Row>);

impl QosSlot {
    /// Asks the owning thread to run at `qos`. A thread that follows a
    /// shared [`DesiredQos`] shares the request with the others that follow it.
    pub fn request(&self, qos: ThreadQos) {
        self.0.desired.request(qos);
    }

    /// The QoS last requested (the declared QoS until a request).
    pub fn desired(&self) -> ThreadQos {
        self.0.desired.get()
    }

    /// The QoS the thread was registered with: its own class, whatever it
    /// was asked for since.
    pub fn declared(&self) -> ThreadQos {
        self.0.declared
    }

    /// The owning thread's name.
    pub fn name(&self) -> &str {
        &self.0.name
    }
}

/// One row of [`snapshot`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThreadInfo {
    pub name: String,
    /// The QoS the thread was registered with.
    pub declared: ThreadQos,
    /// The QoS last requested through its [`QosSlot`].
    pub desired: ThreadQos,
    /// The QoS the thread last applied successfully, `None` before any
    /// change succeeded.
    pub effective: Option<ThreadQos>,
    /// What the kernel reports now.
    pub live: LiveQos,
    /// The scheduler priority the thread runs at now (macOS `pth_curpri`,
    /// Linux 20 + nice), `None` when it could not be read.
    pub priority: Option<i32>,
    /// QoS changes the kernel or the Linux nice rule refused.
    pub refused_changes: u32,
    /// The kernel thread id (Linux tid, macOS pthread_threadid_np).
    pub tid: Option<u64>,
}

static ROWS: Mutex<Vec<Arc<Row>>> = Mutex::new(Vec::new());

fn rows() -> MutexGuard<'static, Vec<Arc<Row>>> {
    ROWS.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Removes its row from the registry when the thread-local is destroyed.
struct Registered(Arc<Row>);

impl Drop for Registered {
    fn drop(&mut self) {
        let mut rows = rows();
        if let Some(index) = rows.iter().position(|row| Arc::ptr_eq(row, &self.0)) {
            rows.swap_remove(index);
        }
    }
}

thread_local! {
    static CURRENT: RefCell<Option<Registered>> = const { RefCell::new(None) };
}

pub(crate) fn with_current<R>(f: impl FnOnce(&Row) -> R) -> Option<R> {
    CURRENT
        .try_with(|current| current.borrow().as_ref().map(|registered| f(&registered.0)))
        .ok()
        .flatten()
}

/// The QoS the calling thread runs at: the class it last applied, else the
/// one it declared. `None` when the thread is not registered.
#[cfg(debug_assertions)]
pub(crate) fn current_qos() -> Option<ThreadQos> {
    with_current(|row| row.effective().unwrap_or(row.declared))
}

/// Registers the calling thread as `name` and sets its QoS to `qos`. For
/// threads cmux does not start itself (a tokio worker's `on_thread_start`);
/// [`crate::spawn`] registers its threads already. The row is removed by
/// [`deregister_current`] or when the thread exits. Returns `false`, and
/// changes nothing, when the thread is registered already.
pub fn register_current(name: impl Into<String>, qos: ThreadQos) -> bool {
    register(name.into(), qos, DesiredQos::new(qos))
}

/// [`register_current`] for a thread that follows `desired`: its row's
/// desired QoS is `desired`, which the thread applies at its next
/// [`crate::apply_pending_qos`].
pub fn register_current_following(
    name: impl Into<String>,
    qos: ThreadQos,
    desired: DesiredQos,
) -> bool {
    register(name.into(), qos, desired)
}

fn register(name: String, qos: ThreadQos, desired: DesiredQos) -> bool {
    let registered = CURRENT.try_with(|current| {
        let mut current = current.borrow_mut();
        if current.is_some() {
            return false;
        }
        let row = Arc::new(Row {
            name,
            declared: qos,
            desired,
            // The declared class is applied below: a request still at it
            // is acted on.
            acted: AtomicU8::new(qos as u8),
            effective: AtomicU8::new(NOT_APPLIED),
            refused: AtomicU32::new(0),
            native: NativeThread::current(),
        });
        rows().push(Arc::clone(&row));
        *current = Some(Registered(row));
        true
    });
    if registered != Ok(true) {
        return false;
    }
    qos::set_current(qos);
    true
}

/// Removes the calling thread's row, if it has one.
pub fn deregister_current() {
    let registered = CURRENT.try_with(|current| current.borrow_mut().take());
    drop(registered);
}

/// The calling thread's desired-QoS slot, `None` when it is not registered.
pub fn current_slot() -> Option<QosSlot> {
    CURRENT
        .try_with(|current| {
            current.borrow().as_ref().map(|registered| QosSlot(Arc::clone(&registered.0)))
        })
        .ok()
        .flatten()
}

/// Applies the QoS another thread requested for the calling thread (its
/// row's [`DesiredQos`]) when the request changed since the last call;
/// `None`, with no syscall, when it did not or the thread is not registered.
/// A thread calls it at the top of its loop, so a request takes effect at
/// the thread's next wake and never wakes it.
///
/// A class the thread could not leave again is not applied: on Linux an
/// unprivileged thread that raised its nice could never return to nice 0,
/// so the demotion is refused and counted ([`qos::reversible`]).
pub fn apply_pending_qos() -> Option<QosChange> {
    let pending = with_current(Row::take_pending).flatten()?;
    if !qos::reversible(pending) {
        qos::record_refusal();
        return Some(QosChange::Refused);
    }
    Some(qos::set_current(pending))
}

/// Every registered thread with its live QoS.
pub fn snapshot() -> Vec<ThreadInfo> {
    // The lock stays held across the live reads: a thread removes its row
    // under this lock before it exits, so every native id read here belongs
    // to a running thread.
    let rows = rows();
    rows.iter()
        .map(|row| ThreadInfo {
            name: row.name.clone(),
            declared: row.declared,
            desired: row.desired.get(),
            effective: row.effective(),
            live: qos::live_of(&row.native),
            priority: qos::priority_of(&row.native),
            refused_changes: row.refused.load(Ordering::Relaxed),
            tid: row.native.tid(),
        })
        .collect()
}

#[cfg(test)]
#[path = "registry_tests.rs"]
mod tests;
