//! cmux's thread layer: every daemon thread is named, declares a QoS from one
//! table (Chromium's ThreadType, see [`qos`]), and is listed in a process-wide
//! registry that diagnostics read with [`snapshot`].
//!
//! Start threads with [`spawn`], change a thread's QoS with [`set_current`]
//! or for one scope with [`with_qos`], and register threads started by other
//! code (tokio workers) with [`register_current`].
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
//! Blocking work runs on [`work`] lanes by kind, priority and shutdown
//! behavior (Chrome's base/task/thread_pool).

pub mod blocking;
pub mod checked;
pub mod qos;
pub mod registry;
pub mod spawn;
pub mod work;

pub use blocking::{
    AllowReason, BlockingKind, BlockingMode, BlockingSite, BlockingSnapshot, allow_blocking,
    assert_blocking_allowed, disallow_blocking, scoped_blocking_call, with_blocking_disallowed,
};
#[cfg(unix)]
pub use blocking::{
    OwnDescriptorToken, own_fd_read, own_fd_write, own_fd_write_all, register_own_descriptor,
};
pub use qos::{LiveQos, QosChange, ThreadQos, current, refused_changes, set_current, with_qos};
pub use registry::{
    QosSlot, ThreadInfo, current_slot, deregister_current, register_current, snapshot,
};
pub use spawn::spawn;
