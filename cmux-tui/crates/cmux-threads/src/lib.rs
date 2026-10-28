//! cmux's thread layer: every daemon thread is named, declares a QoS from one
//! table (Chromium's ThreadType, see [`qos`]), and is listed in a process-wide
//! registry that diagnostics read with [`snapshot`].
//!
//! Start threads with [`spawn`], change a thread's QoS with [`set_current`]
//! or for one scope with [`with_qos`], and register threads started by other
//! code (tokio workers) with [`register_current`]. A thread started with
//! [`spawn_following`] runs at the class its owner requests through a
//! [`DesiredQos`], applied by the thread itself with [`apply_pending_qos`].
//!
//! The registry is process-wide state on purpose: threads are a process
//! resource, as in Chromium's `ThreadIdNameManager`
//! (base/threading/thread_id_name_manager.h).
//!
//! Blocking rules (plans/cmux-next/chrome-parity/p02-threads.md, section 3F):
//! [`blocking`] is the detector (`disallow_blocking`, the [`AllowReason`]
//! friend list, `scoped_blocking_call`, the site table read with
//! [`blocking::snapshot`]) and [`checked`] has checked forms of the blocking
//! std primitives.
//!
//! [`hang`] watches scopes with a deadline on threads of the processes
//! that have no daemon request watchdog (Chrome's HangWatcher).
//!
//! [`lock_boost`] raises a lock's owner to the QoS of its highest waiter
//! until it unlocks (priority inheritance for locks that do not donate).
//!
//! [`lock_wait`] times contended lock acquisitions: a failed try on a thread
//! that disallows blocking is a `lock-wait` violation, and a wait over the
//! 2 ms budget is recorded with the holder's thread name.
//!
//! Blocking work runs on [`work`] lanes by kind, priority and shutdown
//! behavior (Chrome's base/task/thread_pool).
//!
//! [`sync`] channels (std `mpsc`, and `crossbeam_channel` behind the
//! `crossbeam` feature) know their producer: a blocking receive on a
//! higher-QoS thread raises the producer for the wait (macOS; Linux counts
//! it) and, in Debug, records a `priority-inversion` site. Release sends the
//! plain value.
//!
//! Tokio runtimes are built with [`tokio::builder`] (feature `tokio`): their
//! threads are named, registered and set to the runtime's QoS, and
//! [`tokio::block_on`] is a checked `BlockOn` call.
//!
//! Child processes never run at an echo thread's QoS: a user child starts
//! at Default and a helper runs at [`HELPER_CHILD`] (Utility) at most, see
//! [`process`]. [`process_role`] reads the process's Mach task role.
//!
//! A [`reaper`] waits for every child exit on one thread (kqueue on macOS,
//! pidfd and epoll on Linux) and completes each on a [`work`] lane.

pub mod blocking;
pub mod checked;
pub mod hang;
pub mod lock_boost;
pub mod lock_wait;
pub mod process;
pub mod process_role;
pub mod qos;
#[cfg(unix)]
pub mod reaper;
pub mod registry;
pub mod spawn;
pub mod sync;
#[cfg(feature = "tokio")]
pub mod tokio;
pub mod work;

pub use blocking::{
    AllowReason, BlockingCheck, BlockingKind, BlockingMode, BlockingSite, BlockingSnapshot,
    allow_blocking, assert_blocking_allowed, disallow_blocking, scoped_blocking_call,
    with_blocking_disallowed,
};
#[cfg(unix)]
pub use blocking::{
    OwnDescriptorToken, own_fd_read, own_fd_write, own_fd_write_all, register_own_descriptor,
};
pub use hang::{HangRecord, HangScope, HangSink, HangSite, HangSnapshot, HangWatcher};
pub use lock_boost::{BoostCounts, OwnerBoost, OwnerHold, WaitBoost};
pub use lock_wait::{
    LOCK_WAIT_BUDGET, LockHolder, LockWait, LockWaitSnapshot, lock_waits, note_thread_lock_wait,
    set_holder_tracking, thread_lock_wait_nanos,
};
pub use process::HELPER_CHILD;
pub use qos::{
    LiveQos, QosChange, QosScope, ThreadQos, current, current_effective, reachable,
    refused_changes, reversible, set_current, with_qos,
};
pub use registry::{
    DesiredQos, QosSlot, ThreadInfo, apply_pending_qos, current_slot, deregister_current,
    register_current, register_current_following, snapshot,
};
pub use spawn::{Scope, caller_qos, scope, spawn, spawn_following, spawn_with_stack};
