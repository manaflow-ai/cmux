//! The process's thread registry: one row per cmux thread, with its name,
//! declared QoS, desired-QoS slot, effective QoS, scheduler priority, native
//! ids and the object it works for now.
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
use std::sync::atomic::{AtomicU8, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use crate::qos::{self, LiveQos, ThreadQos};

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
/// `Row::owner` while the thread works for no object.
const NO_OWNER: u64 = u64::MAX;

/// One registered thread.
#[derive(Debug)]
pub(crate) struct Row {
    name: String,
    declared: ThreadQos,
    desired: AtomicU8,
    effective: AtomicU8,
    refused: AtomicU32,
    /// The object the thread works for now ([`QosSlot::work_for`]), or
    /// [`NO_OWNER`].
    owner: AtomicU64,
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
}

/// A handle to a registered thread's desired-QoS slot. Another thread stores
/// the QoS it wants the owner to run at; the owner reads it at a point of its
/// choosing and applies it with [`qos::set_current`].
#[derive(Clone, Debug)]
pub struct QosSlot(Arc<Row>);

impl QosSlot {
    /// Asks the owning thread to run at `qos`.
    pub fn request(&self, qos: ThreadQos) {
        self.0.desired.store(qos as u8, Ordering::Relaxed);
    }

    /// The QoS last requested (the declared QoS until a request).
    pub fn desired(&self) -> ThreadQos {
        ThreadQos::from_u8(self.0.desired.load(Ordering::Relaxed))
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

    /// Records that the owning thread works for the object `owner` (an id
    /// its caller chooses: a daemon connection's client id), so a snapshot
    /// can say whose work its QoS is for, as Chromium's trace metadata
    /// names the frame or process a thread serves. Diagnostics only.
    pub fn work_for(&self, owner: u64) {
        self.0.owner.store(owner, Ordering::Relaxed);
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
    /// The object the thread works for ([`QosSlot::work_for`]), `None` when
    /// it was never set.
    pub owner: Option<u64>,
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
    let registered = CURRENT.try_with(|current| {
        let mut current = current.borrow_mut();
        if current.is_some() {
            return false;
        }
        let row = Arc::new(Row {
            name: name.into(),
            declared: qos,
            desired: AtomicU8::new(qos as u8),
            effective: AtomicU8::new(NOT_APPLIED),
            refused: AtomicU32::new(0),
            owner: AtomicU64::new(NO_OWNER),
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
            desired: ThreadQos::from_u8(row.desired.load(Ordering::Relaxed)),
            effective: row.effective(),
            live: qos::live_of(&row.native),
            priority: qos::priority_of(&row.native),
            refused_changes: row.refused.load(Ordering::Relaxed),
            tid: row.native.tid(),
            owner: match row.owner.load(Ordering::Relaxed) {
                NO_OWNER => None,
                owner => Some(owner),
            },
        })
        .collect()
}
