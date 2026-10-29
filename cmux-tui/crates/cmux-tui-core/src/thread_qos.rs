//! The role of each daemon and terminal-host thread, mapped to a QoS class in
//! one place.
//!
//! Chromium names a thread by what it does (`ThreadType`) and maps the type
//! to a macOS QoS class in one function, `ThreadTypeToQoSClass` in
//! base/threading/platform_thread_apple.mm. cmux does the same in two steps:
//! [`ThreadType::qos`] maps a role to a [`ThreadQos`], and cmux-threads maps
//! that class to the OS (`pthread_set_qos_class_self_np` on macOS, a nice
//! value on Linux, no change elsewhere; see `cmux_threads::qos`).
//!
//! | ThreadType         | ThreadQos       | macOS QoS class            | Chromium ThreadType |
//! | ------------------ | --------------- | -------------------------- | ------------------- |
//! | InputCritical      | UserInteractive | QOS_CLASS_USER_INTERACTIVE | kDisplayCritical    |
//! | Interactive        | UserInitiated   | QOS_CLASS_USER_INITIATED   | kDefault            |
//! | UnclassifiedClient | Default         | QOS_CLASS_DEFAULT          | (none)              |
//! | Utility            | Utility         | QOS_CLASS_UTILITY          | kUtility            |
//! | Background         | Background      | QOS_CLASS_BACKGROUND       | kBackground         |
//!
//! The daemon's class constants come from this map:
//! `echo_thread::ECHO_PATH_QOS` (InputCritical), the server's
//! `REQUEST_THREAD_QOS` (Interactive) and `CONNECTION_READER_QOS`
//! (UnclassifiedClient). A thread started with `cmux_threads::spawn` at one
//! of them is registered at that class before its body runs; a thread
//! started any other way calls [`set`] as the first statement of its body.
//!
//! The InputCritical threads are the ones a key press and its echo go
//! through: terminal-host-client-input, terminal-host-pty and
//! terminal-host-parser (`echo_thread::spawn`), and holder-link, which routes
//! holder output to its surfaces (cmux-holder's `link::LINK_READER_QOS`; that
//! crate sits below this one, and a test here keeps the two equal). The connection
//! reader (mux-conn) and the sequenced pool's control workers
//! (mux-seq-control) serve automation clients too, so they stay below
//! InputCritical until the client's class is known (p02-threads task 224).
//! The cmux-tui client's key writers (remote-input-writer, relay-input) are
//! InputCritical too. The terminal resource stream writer
//! (mux-resource-terminal-attach) is not: it waits for its attach to commit,
//! so it is a control stream at Interactive. Watchers and
//! best-effort writers are Utility: sqlite-wal-sync,
//! mux-session-journal-fanout, terminal-host-record-mirror and
//! cmux-config-watch (cmux-config's `watch::WATCH_THREAD_QOS`, kept equal
//! by a test here; the daemon's settings and keybindings reloads run on a
//! work lane, not on it); mux-inventory-watch and mux-project-sources start
//! through [`spawn_raisable`], so a ranked lock raises them. Upkeep threads
//! that hold the workspace registry a request waits for
//! (terminal-command-history, mux-output-store-writer) start at
//! `request_qos::UPKEEP_THREAD_QOS` and run each pass at utility, so the
//! lock can raise them; mux-project-sources runs each import pass that way
//! too.

pub use cmux_threads::QosChange;
use cmux_threads::ThreadQos;
/// For a Utility or Background thread that may take a ranked lock.
pub use cmux_tui_platform::qos::spawn_raisable;

/// What a thread does, which sets the QoS class it runs at.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ThreadType {
    /// On the path from a key press to its echo on screen (Chromium
    /// kDisplayCritical).
    InputCritical,
    /// Request work the person waits on (Chromium kDefault).
    Interactive,
    /// Serves a client whose class is not known yet, person or automation:
    /// a connection reader before p02-threads task 224 classes it.
    UnclassifiedClient,
    /// Automation, watchers and best-effort work (Chromium kUtility).
    Utility,
    /// Idle work only (Chromium kBackground).
    Background,
}

impl ThreadType {
    /// Every type, highest priority first.
    pub const ALL: [Self; 5] = [
        Self::InputCritical,
        Self::Interactive,
        Self::UnclassifiedClient,
        Self::Utility,
        Self::Background,
    ];

    /// The QoS class of the type: the one map from a thread role to a class.
    pub const fn qos(self) -> ThreadQos {
        match self {
            Self::InputCritical => ThreadQos::UserInteractive,
            Self::Interactive => ThreadQos::UserInitiated,
            Self::UnclassifiedClient => ThreadQos::Default,
            Self::Utility => ThreadQos::Utility,
            Self::Background => ThreadQos::Background,
        }
    }
}

/// Sets the calling thread's QoS class to the class of `thread_type`. A
/// thread registered with cmux-threads also gets its registry row updated.
/// A refused change is counted by cmux-threads (`refused_changes`); the
/// thread then keeps running at its current class.
pub fn set(thread_type: ThreadType) -> QosChange {
    cmux_threads::set_current(thread_type.qos())
}

#[cfg(test)]
#[path = "thread_qos_tests.rs"]
pub(crate) mod tests;
