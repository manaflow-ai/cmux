//! Daemon request QoS: a request runs at the class of
//! its cause, and a lowered thread is raised before it waits for a ranked
//! lock and while it holds one, so a frontend request never waits behind a
//! UTILITY thread.
//!
//! - [`WorkQos`]: the request's class for its whole run. Verified-app
//!   requests run at USER_INITIATED, automation at UTILITY. Chromium runs a
//!   BEST_EFFORT task on its background thread group and a USER_VISIBLE or
//!   USER_BLOCKING one on the foreground group
//!   (base/task/thread_pool/thread_group_impl.cc); here the thread changes
//!   class per request instead, because one connection thread runs them all.
//! - [`LockBoost`]: taken before the thread blocks on a ranked lock and held
//!   with it. The outermost boost of a thread lowered by a [`WorkQos`], or
//!   of a thread declared below Default at its start (a utility watcher, an
//!   idle worker, `cmux_threads::spawn`), raises it to USER_INITIATED until
//!   that lock is released (Chromium's
//!   `ScopedBoostPriority`, base/threading/scoped_thread_priority.h, entered
//!   before the wait too). A lock that hands itself to a parked waiter
//!   (parking_lot's eventual fairness, a fair pthread mutex) then never
//!   hands it to a starved UTILITY thread. The thread raises its own request
//!   (`pthread_set_qos_class_self_np` through [`cmux_threads::QosScope`])
//!   rather than taking an override (`pthread_override_qos_class_start_np`),
//!   the call for raising another thread: the change is then visible to
//!   `qos_class_self()`, the thread registry and the Linux nice value alike.
//! - [`spawn_outside_request`]: a thread started during a request runs at
//!   its creator's own class ([`outside_request_class`]), not the request's
//!   (a new thread inherits its creator's class on macOS and its nice value
//!   on Linux, so it states its class when it starts).
//!
//! The scopes are thread-local and nest. A boost costs two thread-local
//! reads when the thread is not lowered (its request class and its declared
//! class, cached after the first boost), and one QoS change each way when it
//! is. A
//! [`WorkQos`] entered while a boost is held changes nothing: the lock
//! holder stays raised until its lock is released.
//!
//! A class the process could not take back is never entered: on Linux
//! without root or an `RLIMIT_NICE` that allows nice 0 again
//! ([`cmux_threads::reversible`], asked once per thread), an automation
//! request runs at the thread's own nice value, no refusal is counted, and
//! nothing needs a boost.

use std::cell::{Cell, RefCell};
use std::marker::PhantomData;

use cmux_threads::{QosScope, ThreadQos};

/// The class a lock holder is raised to.
pub const LOCK_HOLDER_QOS: ThreadQos = ThreadQos::UserInitiated;

thread_local! {
    /// The class the innermost applied [`WorkQos`] runs this thread at;
    /// `None` outside every applied scope.
    static WORK: Cell<Option<ThreadQos>> = const { Cell::new(None) };
    /// Per class, whether the process can take a change to it back.
    static REVERSIBLE: Cell<[Option<bool>; ThreadQos::ALL.len()]> =
        const { Cell::new([None; ThreadQos::ALL.len()]) };
    /// Locks this thread holds or waits for with a [`LockBoost`].
    static BOOST_DEPTH: Cell<u32> = const { Cell::new(0) };
    /// The raise of the outermost boost, when it raised the thread.
    static RAISE: RefCell<Option<QosScope>> = const { RefCell::new(None) };
    /// The class this thread declared at its start, read once it is
    /// registered: a registered thread's declared class never changes.
    static DECLARED: Cell<Option<ThreadQos>> = const { Cell::new(None) };
}

/// The class this thread's innermost applied [`WorkQos`] runs it at.
pub fn work_qos() -> Option<ThreadQos> {
    WORK.with(Cell::get)
}

/// True while a [`LockBoost`] raises this thread.
pub fn boosted() -> bool {
    RAISE.with(|raise| raise.borrow().as_ref().is_some_and(QosScope::applied))
}

/// The class this thread declared when it started (`cmux_threads::spawn`);
/// `None` for a thread that is not registered.
fn declared() -> Option<ThreadQos> {
    DECLARED.with(|cache| {
        if let Some(declared) = cache.get() {
            return Some(declared);
        }
        let declared = cmux_threads::current_slot().map(|slot| slot.declared())?;
        cache.set(Some(declared));
        Some(declared)
    })
}

/// Whether a lock this thread takes now must raise it: it runs a [`WorkQos`]
/// below [`LOCK_HOLDER_QOS`], or outside every request it rests at a class
/// it declared below Default and could be raised from and lowered back to
/// (on Linux: nice 0 again, [`reversible`]).
fn holder_needs_raise() -> bool {
    match work_qos() {
        Some(qos) => qos < LOCK_HOLDER_QOS,
        None => declared().is_some_and(|qos| qos < ThreadQos::Default && reversible(qos)),
    }
}

/// Whether the process can enter `qos` and take it back
/// ([`cmux_threads::reversible`]), asked once per thread and class.
fn reversible(qos: ThreadQos) -> bool {
    REVERSIBLE.with(|cache| {
        let mut known = cache.get();
        let slot = &mut known[qos as usize];
        if let Some(reversible) = *slot {
            return reversible;
        }
        let reversible = cmux_threads::reversible(qos);
        *slot = Some(reversible);
        cache.set(known);
        reversible
    })
}

/// A request's class for its run on this thread; the previous class comes
/// back when it drops.
#[must_use = "the class holds only while the scope lives"]
pub struct WorkQos {
    /// `Some` when this scope changed the thread; dropped before `previous`
    /// is restored.
    scope: Option<QosScope>,
    previous: Option<ThreadQos>,
    _not_send: PhantomData<*const ()>,
}

impl WorkQos {
    /// Runs this thread at `qos` until the scope drops. Nothing changes when
    /// the thread already runs at `qos` in an outer scope, while it holds or
    /// waits for a lock with a boost (scopes and boosts then end in reverse
    /// order), or when the process could not take `qos` back.
    pub fn enter(qos: ThreadQos) -> Self {
        let previous = work_qos();
        let holds_lock = BOOST_DEPTH.with(Cell::get) > 0;
        if previous == Some(qos) || holds_lock || !reversible(qos) {
            return Self { scope: None, previous, _not_send: PhantomData };
        }
        let scope = QosScope::enter(qos);
        if scope.applied() {
            WORK.with(|work| work.set(Some(qos)));
        }
        Self { scope: Some(scope), previous, _not_send: PhantomData }
    }

    /// True when the thread runs at the scope's class because of it.
    pub fn applied(&self) -> bool {
        self.scope.as_ref().is_some_and(QosScope::applied)
    }
}

impl Drop for WorkQos {
    fn drop(&mut self) {
        let Some(scope) = self.scope.take() else { return };
        drop(scope);
        let previous = self.previous;
        let _ = WORK.try_with(|work| work.set(previous));
    }
}

/// Taken before the thread blocks on a ranked lock and held with it: the
/// outermost one raises a lowered thread (a [`WorkQos`] below it, or a
/// declared utility or background thread) to [`LOCK_HOLDER_QOS`] until it
/// drops. Hold it in the lock guard, declared after the lock, so the lock is
/// released first.
#[must_use = "the boost holds only while the guard lives"]
pub struct LockBoost {
    counted: bool,
    _not_send: PhantomData<*const ()>,
}

impl LockBoost {
    /// For a lock this thread is about to wait for, or took without waiting.
    pub fn hold() -> Self {
        let depth = BOOST_DEPTH.with(|depth| {
            let next = depth.get().saturating_add(1);
            depth.set(next);
            next
        });
        if depth == 1 && holder_needs_raise() {
            let scope = QosScope::enter(LOCK_HOLDER_QOS);
            RAISE.with(|raise| *raise.borrow_mut() = Some(scope));
        }
        Self { counted: true, _not_send: PhantomData }
    }

    /// For a rank that is not a lock (the journal writer's loop scope).
    pub const fn none() -> Self {
        Self { counted: false, _not_send: PhantomData }
    }
}

impl Drop for LockBoost {
    fn drop(&mut self) {
        if !self.counted {
            return;
        }
        // Guards may drop during thread teardown.
        let Ok(depth) = BOOST_DEPTH.try_with(|depth| {
            let next = depth.get().saturating_sub(1);
            depth.set(next);
            next
        }) else {
            return;
        };
        if depth == 0 {
            // Taken out first: the scope's restore runs outside the borrow.
            let raise = RAISE.try_with(|raise| raise.borrow_mut().take()).ok().flatten();
            drop(raise);
        }
    }
}

impl std::fmt::Debug for LockBoost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LockBoost").field("counted", &self.counted).finish()
    }
}

/// Starts thread `name` through [`cmux_threads::spawn`] at
/// [`outside_request_class`]. For a thread that outlives the request that
/// starts it (a terminal's reader, a pool worker).
pub fn spawn_outside_request<F, T>(
    name: impl Into<String>,
    f: F,
) -> std::io::Result<std::thread::JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    // supervise-allow: a spawn primitive: it returns the JoinHandle, so each caller keeps it and owns its thread's failure policy.
    cmux_threads::spawn(name, outside_request_class(), f)
}

/// Starts thread `name` through [`cmux_threads::spawn`] at `qos`, a class
/// below Default (a watcher at Utility, an idle loop at Background), for a
/// thread that may take a ranked lock: a lock it waits for or holds raises
/// it to [`LOCK_HOLDER_QOS`] ([`LockBoost`]). Where the process could not
/// take that raise back ([`cmux_threads::reversible`]: Linux without root or
/// an `RLIMIT_NICE` that allows nice 0) it starts at Default instead, so it
/// never holds a lock below the threads that wait for it, or at the
/// creator's own class where Default is out of reach too
/// ([`raisable_class`]). `stack` is its
/// stack size in bytes, `None` for the platform default.
pub fn spawn_raisable<F, T>(
    name: impl Into<String>,
    qos: ThreadQos,
    stack: Option<usize>,
    f: F,
) -> std::io::Result<std::thread::JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    let class = raisable_class(qos);
    match stack {
        Some(bytes) => cmux_threads::spawn_with_stack(name, class, bytes, f),
        None => cmux_threads::spawn(name, class, f),
    }
}

/// The class [`spawn_raisable`] starts a thread at for `qos`, asked on the
/// creator. A class it could not raise for a lock falls back to Default, or,
/// where the creator cannot reach Default either (a daemon started under
/// `nice -n 10` without the right to lower nice), to the highest class
/// below it that the creator can reach: its own, which the new thread
/// starts at anyway, so its start is never a refused change.
pub fn raisable_class(qos: ThreadQos) -> ThreadQos {
    if qos >= ThreadQos::Default || cmux_threads::reversible(qos) {
        return qos;
    }
    [ThreadQos::Default, ThreadQos::Utility, ThreadQos::Background]
        .into_iter()
        .find(|&class| cmux_threads::reachable(class))
        .unwrap_or(qos)
}

/// The class of a thread the calling thread starts now: the class the
/// creator declared (`cmux_threads::spawn`), or Default for a thread that
/// declared none, never the class of a request or lock boost the creator is
/// in. The creator entered a request class only because it could take it
/// back, so the new thread can change back the same way.
pub fn outside_request_class() -> ThreadQos {
    own_class()
}

/// The calling thread's class outside every request: the class it declared.
/// Not its desired class, which a connection thread sets to the class it
/// rests at (cmux-tui-core server/connection_qos.rs): a thread it starts
/// serves every connection, not only that one.
fn own_class() -> ThreadQos {
    cmux_threads::current_slot().map_or(ThreadQos::Default, |slot| slot.declared())
}

#[cfg(test)]
#[path = "qos_tests.rs"]
mod tests;
