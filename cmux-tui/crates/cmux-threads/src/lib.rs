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
//! Blocking work runs on [`work`] lanes by kind, priority and shutdown
//! behavior (Chrome's base/task/thread_pool).

pub mod qos;
pub mod registry;
pub mod spawn;
pub mod work;

pub use qos::{LiveQos, QosChange, ThreadQos, current, refused_changes, set_current, with_qos};
pub use registry::{
    QosSlot, ThreadInfo, current_slot, deregister_current, register_current, snapshot,
};
pub use spawn::spawn;
