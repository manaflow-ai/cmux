//! The QoS of a connection's threads (TYPING FIX 2, F7). Under full CPU a default-QoS thread waits for a CPU: the
//! fleet probe measured a default-QoS key thread's wake at p99 up to 7.7 ms and max up to 24.8 ms with 2 x cores busy
//! threads, and at user-interactive about half the max and no wait in the middle of a send (STATUS 6593). A key
//! crosses three threads of its connection: the `mux-conn` reader, the `mux-control-dispatch` request thread and the
//! `mux-line-out` writer. Once a connection carries the person's keys to a terminal it can type into (`send` or
//! `send-key` of an attached client that is not only a read-only viewer, the input lane of
//! `cmd_terminal_io::input_surface`), those three threads run at QOS_CLASS_USER_INTERACTIVE, as Chrome runs the
//! thread that carries input at the highest priority. Each thread raises itself (a QoS is set by the thread itself),
//! on its next line, request or reply. Automation's connections (CLI, MCP, agents writing to terminals they do not
//! view, read-only viewers) keep the default QoS, so they never compete with the person's input. Off macOS this sets
//! nothing.

use std::cell::Cell;
use std::sync::atomic::{AtomicBool, Ordering};

/// Whether a connection carries the person's keys; shared by its threads through its `MessageWriter`.
#[derive(Default)]
pub(super) struct InputLane {
    carries_person_input: AtomicBool,
}

thread_local! {
    static RAISED: Cell<bool> = const { Cell::new(false) };
}

impl InputLane {
    /// The connection carries the person's keys: the calling thread (the one that runs the key) raises itself now,
    /// the connection's other threads on their next line or reply.
    pub(super) fn mark_person_input(&self) {
        self.carries_person_input.store(true, Ordering::Release);
        raise_this_thread();
    }

    /// Whether the connection is marked as carrying the person's keys (test hook).
    #[cfg(test)]
    pub(super) fn carries_person_input(&self) -> bool {
        self.carries_person_input.load(Ordering::Acquire)
    }

    /// Raises the calling thread when its connection carries the person's keys. One atomic load per line, request
    /// or reply, one system call per thread.
    pub(super) fn raise_this_thread_if_marked(&self) {
        if self.carries_person_input.load(Ordering::Acquire) {
            raise_this_thread();
        }
    }
}

/// Raises the calling thread to user-interactive QoS, once per thread: a thread that carries the person's keys (the
/// connection threads above, and a terminal's input port writer once it takes a person's key,
/// `surface::input_port`). Off macOS this sets nothing.
pub(crate) fn raise_this_thread() {
    if RAISED.with(Cell::get) {
        return;
    }
    RAISED.with(|raised| raised.set(true));
    #[cfg(target_os = "macos")]
    {
        // SAFETY: sets the calling thread's own QoS; no pointer is passed.
        let rc = unsafe {
            libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0)
        };
        if rc != 0 {
            eprintln!("cmux: could not raise the input thread's QoS ({rc})");
        }
    }
}

/// Test hook: each connection thread (`mux-conn` reader, `mux-control-dispatch`, `mux-line-out` writer) records its
/// own QoS before each line, request or reply, so a test reads it after that reply arrives (no timing).
#[cfg(test)]
pub(super) fn note_thread_qos(role: &'static str) {
    OBSERVED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .insert(role, current_thread_qos());
}

#[cfg(not(test))]
#[inline(always)]
pub(super) fn note_thread_qos(_role: &'static str) {}

/// The QoS a connection thread last recorded (test hook; the QoS tests run on macOS).
#[cfg(all(test, target_os = "macos"))]
pub(super) fn observed_thread_qos(role: &'static str) -> Option<u32> {
    OBSERVED.lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(role).copied()
}

#[cfg(test)]
static OBSERVED: std::sync::LazyLock<
    std::sync::Mutex<std::collections::HashMap<&'static str, u32>>,
> = std::sync::LazyLock::new(Default::default);

/// This thread's QoS class (`qos_class_t` as u32); 0 off macOS.
#[cfg(test)]
pub(crate) fn current_thread_qos() -> u32 {
    #[cfg(target_os = "macos")]
    {
        let mut qos = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
        let mut relative = 0;
        // SAFETY: valid out pointers for this thread's own QoS.
        unsafe { libc::pthread_get_qos_class_np(libc::pthread_self(), &mut qos, &mut relative) };
        qos as u32
    }
    #[cfg(not(target_os = "macos"))]
    {
        0
    }
}
