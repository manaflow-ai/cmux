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

/// A resize in flight from a connection (`set-split-ratio`, `set-viewport-pane-width`, `set-layout-sizes`): the
/// person's drag when it runs in a drag transaction, the protocol the app's dividers, windows and sidebars use
/// (`set-layout-sizes` always does). The connection is marked like a key marks it, so its threads serve the
/// following frames at user-interactive QoS, and the process's interaction state notes a drag, so lower classes
/// (`cmux-interactivity`'s policy: agent output parsing, journal sync and indexing) yield for the next 400 ms.
/// A one-shot CLI call without a transaction is automation's and changes nothing. It runs before the command, not
/// after its reply: the layout work and the frames it sets off are the drag's, so lower classes yield for them too
/// and the connection's thread is raised before it does that work. A command the mux then refuses noted 400 ms of a
/// drag the app was in anyway.
pub(super) fn note_drag(writer: &super::MessageWriter, in_drag_transaction: bool) {
    if in_drag_transaction {
        writer.input_lane.mark_person_input();
        cmux_interactivity::note(cmux_interactivity::InteractionKind::Drag);
    }
}

/// Whether a resize came from the verified cmux app (`Actor::Frontend`): only the app's drags mark the connection and
/// note a drag. A CLI or agent connection sending the same command stays at its QoS, so automation cannot hold the
/// interaction state up or promote its connection for good (router review follow-up F1 on #53142).
pub(super) fn from_app(actor: &crate::workspace_registry::Actor) -> bool {
    matches!(actor, crate::workspace_registry::Actor::Frontend { .. })
}

/// An app view's terminal took a new size (`resize-attached-view`): a window live resize or a divider drag moves
/// the view every frame and sends it, with no layout command until the release. Notes a drag, so lower classes
/// yield while the pointer moves. The connection is not marked: the view's size alone is not the person's keys.
pub(super) fn note_view_resize() {
    cmux_interactivity::note(cmux_interactivity::InteractionKind::Drag);
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

#[cfg(test)]
mod from_app_tests {
    use crate::workspace_registry::Actor;

    #[test]
    fn only_the_verified_app_counts_as_a_drag() {
        assert!(super::from_app(&Actor::Frontend { install_id: "signed_app".into() }));
        assert!(!super::from_app(&Actor::local_user()));
        assert!(!super::from_app(&Actor::Terminal { id: "t1".into() }));
        assert!(!super::from_app(&Actor::Peer { id: "peer:websocket".into() }));
    }
}
