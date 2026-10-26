//! Daemon request QoS (p06-scheduler-035): a request runs at the class of
//! its cause, and a lowered thread is raised while it holds a state or
//! registry lock, so a frontend request never waits behind a UTILITY holder.
//!
//! - [`WorkQos`]: the request's class for its whole run. Verified-app
//!   requests run at USER_INITIATED, automation at UTILITY. Chromium runs a
//!   BEST_EFFORT task on its background thread group and a USER_VISIBLE or
//!   USER_BLOCKING one on the foreground group
//!   (base/task/thread_pool/thread_group_impl.cc); here the thread changes
//!   class per request instead, because one connection thread runs them all.
//! - [`LockBoost`]: held with a state or registry lock. The outermost boost
//!   of a thread lowered by a [`WorkQos`] raises it to USER_INITIATED until
//!   that lock is released (Chromium's `ScopedBoostPriority`,
//!   base/threading/scoped_thread_priority.h). The thread raises its own
//!   request (`pthread_set_qos_class_self_np` through
//!   [`cmux_threads::QosScope`]) rather than taking an override
//!   (`pthread_override_qos_class_start_np`), the call for raising another
//!   thread: the change is then visible to `qos_class_self()`, the thread
//!   registry and the Linux nice value alike.
//!
//! Both are thread-local and nest. A boost costs one thread-local read when
//! the thread is not lowered, and one QoS change each way when it is. A
//! [`WorkQos`] entered while a boost is held changes nothing: the lock
//! holder stays raised until its lock is released.
//!
//! On Linux a lowering the thread could not undo is refused (see
//! [`cmux_threads::qos`]): without `RLIMIT_NICE` an automation request runs
//! at the thread's own nice value, and nothing needs a boost.

use std::cell::{Cell, RefCell};
use std::marker::PhantomData;

use cmux_threads::{QosScope, ThreadQos};

/// The class a lock holder is raised to.
pub const LOCK_HOLDER_QOS: ThreadQos = ThreadQos::UserInitiated;

thread_local! {
    /// The class the innermost applied [`WorkQos`] runs this thread at;
    /// `None` outside every applied scope.
    static WORK: Cell<Option<ThreadQos>> = const { Cell::new(None) };
    /// Locks this thread holds with a [`LockBoost`].
    static BOOST_DEPTH: Cell<u32> = const { Cell::new(0) };
    /// The raise of the outermost boost, when it raised the thread.
    static RAISE: RefCell<Option<QosScope>> = const { RefCell::new(None) };
}

/// The class this thread's innermost applied [`WorkQos`] runs it at.
pub fn work_qos() -> Option<ThreadQos> {
    WORK.with(Cell::get)
}

/// True while a [`LockBoost`] raises this thread.
pub fn boosted() -> bool {
    RAISE.with(|raise| raise.borrow().as_ref().is_some_and(QosScope::applied))
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
    /// the thread already runs at `qos` in an outer scope, or while it holds
    /// a lock with a boost (scopes and boosts then end in reverse order).
    pub fn enter(qos: ThreadQos) -> Self {
        let previous = work_qos();
        let holds_lock = BOOST_DEPTH.with(Cell::get) > 0;
        if previous == Some(qos) || holds_lock {
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

/// Held with a state or registry lock: the outermost one raises a lowered
/// thread to [`LOCK_HOLDER_QOS`] until it drops. Hold it in the lock guard,
/// declared after the lock, so the lock is released first.
#[must_use = "the boost holds only while the guard lives"]
pub struct LockBoost {
    counted: bool,
    _not_send: PhantomData<*const ()>,
}

impl LockBoost {
    /// For a lock this thread just took.
    pub fn hold() -> Self {
        let depth = BOOST_DEPTH.with(|depth| {
            let next = depth.get().saturating_add(1);
            depth.set(next);
            next
        });
        if depth == 1 && work_qos().is_some_and(|qos| qos < LOCK_HOLDER_QOS) {
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

#[cfg(test)]
#[path = "qos_tests.rs"]
mod tests;
