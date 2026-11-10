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
//!
//! The connection of the person's app (hello role main, proved, not bound to an agent:
//! `origin_gate::person_app_connection`) is on the lane from its hello on, before any key: each request on it is an
//! action the person waits for. A terminal create it asks for runs on the shared `mux-terminal-work` pool at
//! user-initiated ([`PersonWork`]).
//!
//! These classes have an effect only because the process has an application task role
//! (`cmux_tui_platform::task_role`, taken in `owner_start::prepare`). Without a role the kernel holds every thread
//! at the default priority (31), and the lane above ran at 31 until the role was added.

use std::cell::Cell;
use std::sync::atomic::{AtomicBool, Ordering};

/// Whether a connection carries the person's keys; shared by its threads through its `MessageWriter`.
#[derive(Default)]
pub(super) struct InputLane {
    carries_person_input: AtomicBool,
    /// Test hook: the QoS each thread of this connection last recorded, by thread name ([`Self::note_thread_qos`]).
    #[cfg(test)]
    observed: std::sync::Mutex<std::collections::HashMap<&'static str, u32>>,
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

    /// The connection is the person's app (`origin_gate::person_app_connection`): each request on it is an action
    /// the person waits for (a split, a new tab, a close, a focus), so its threads run on the same lane as a key,
    /// from the hello on. The calling thread (the reader, which ran the hello) raises itself now.
    pub(super) fn mark_person_app(&self) {
        self.mark_person_input();
    }

    /// Whether the connection is marked as carrying the person's keys or actions.
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

/// The calling thread at user-initiated QoS until dropped, then back at the class it had: a job the person waits for
/// on a thread other requests share (a terminal create on the `mux-terminal-work` pool). Chromium runs such work at
/// `ThreadType::kDefault`, which is user-initiated on macOS (`base/threading/platform_thread_apple.mm`). A thread
/// that runs at user-initiated or higher already (a create that ran inline on the connection's dispatcher) keeps
/// its class. Off macOS this sets nothing.
pub(super) struct PersonWork {
    #[cfg(target_os = "macos")]
    restore: Option<libc::qos_class_t>,
}

impl PersonWork {
    pub(super) fn enter() -> Self {
        #[cfg(target_os = "macos")]
        {
            let mut current = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
            let mut relative = 0;
            // SAFETY: valid out pointers for the calling thread's own QoS.
            unsafe {
                libc::pthread_get_qos_class_np(libc::pthread_self(), &mut current, &mut relative);
            }
            if current as u32 >= libc::qos_class_t::QOS_CLASS_USER_INITIATED as u32 {
                return Self { restore: None };
            }
            set_this_thread(libc::qos_class_t::QOS_CLASS_USER_INITIATED);
            // An unspecified class cannot be set again; default is what such a thread runs at.
            let restore = match current {
                libc::qos_class_t::QOS_CLASS_UNSPECIFIED => libc::qos_class_t::QOS_CLASS_DEFAULT,
                class => class,
            };
            Self { restore: Some(restore) }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self {}
        }
    }
}

impl Drop for PersonWork {
    fn drop(&mut self) {
        #[cfg(target_os = "macos")]
        {
            if let Some(class) = self.restore.take() {
                set_this_thread(class);
            }
        }
    }
}

/// `pthread_set_qos_class_self_np(class, 0)` for the calling thread, reported when the kernel refuses it.
#[cfg(target_os = "macos")]
fn set_this_thread(class: libc::qos_class_t) {
    let wanted = class as u32;
    // SAFETY: sets the calling thread's own QoS; no pointer is passed.
    let rc = unsafe { libc::pthread_set_qos_class_self_np(class, 0) };
    if rc != 0 {
        eprintln!("cmux: could not set the thread's QoS to {wanted:#x} ({rc})");
    }
}

impl InputLane {
    /// Test hook: each thread of the connection (`mux-conn` reader, `mux-control-dispatch`, `mux-line-out` writer, a
    /// `mux-terminal-work` creation job) records its own QoS before each line, request, reply or job, so a test reads
    /// it after that reply arrives (no timing). Kept per connection: tests that run at the same time do not mix.
    #[cfg(test)]
    pub(super) fn note_thread_qos(&self, role: &'static str) {
        self.observed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(role, current_thread_qos());
    }

    #[cfg(not(test))]
    #[inline(always)]
    pub(super) fn note_thread_qos(&self, _role: &'static str) {}

    /// The QoS a thread of this connection last recorded (test hook; the QoS tests run on macOS).
    #[cfg(all(test, target_os = "macos"))]
    pub(super) fn observed_thread_qos(&self, role: &'static str) -> Option<u32> {
        self.observed.lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(role).copied()
    }
}

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
