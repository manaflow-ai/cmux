//! `debug-panic {kind: "panic" | "abort" | "segv"}`: make this daemon crash
//! on purpose, so crash-matrix.py can check that each kind of daemon crash
//! yields exactly one report (plans/cmux-next/chrome-parity/p09-observability.md,
//! task 101).
//!
//! Chrome's debug URLs do the same for its processes
//! (content/browser/renderer_host/debug_urls.cc `HandleDebugURL`:
//! chrome://crash, chrome://inducebrowsercrashforrealz, chrome://kill), and
//! only a browser-initiated navigation may start one, never a page. Here
//! only the trusted local connection may: a WebSocket or remote relay client
//! gets a refusal (remote frames never reach a route; the check repeats it).
//!
//! The module exists only in debug builds and `--features bench` builds: a
//! release daemon has no such route and answers the line as an unknown
//! command. Like `oracle-state`, it is answered before the `Command` parse,
//! so it is not in the `Command` enum, its name table or the SDK catalog.
//!
//! The crash runs on a thread of its own, started before the reply. A
//! `panic` ends only that thread (the owner's panic log records it); `abort`
//! and `segv` end the process, so their reply may not reach the caller.

use std::sync::Arc;

use serde_json::{Map, Value, json};

use super::{MessageWriter, Response, send_request_error, send_response};
use crate::Mux;

/// The line's `cmd`.
pub(super) const COMMAND: &str = "debug-panic";
/// The thread the crash runs on: crash reports name it.
pub(super) const THREAD: &str = "debug-crash-inject";

/// The `cmd` this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[crate::server::routes::Route] =
    &[crate::server::routes::Route {
        names: &[crate::server::routes::RouteName::Exact(COMMAND)],
        stage: crate::server::FrameStage::Route,
        entry: |line| {
            try_handle(line.mux, line.client, line.message, line.writer, |kind| {
                fire(kind).map(drop)
            })
        },
    }];

/// How the daemon ends.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CrashKind {
    /// A Rust panic on [`THREAD`]: the panic hook writes one panic-log line.
    Panic,
    /// `std::process::abort`: SIGABRT.
    Abort,
    /// A store to an unmapped address: a real SIGSEGV with a fault address, as
    /// Chrome's `CrashIntentionally` (content/renderer/render_frame_impl.cc)
    /// writes through a null pointer.
    Segv,
}

impl CrashKind {
    pub(super) const ALL: [Self; 3] = [Self::Panic, Self::Abort, Self::Segv];

    pub(super) const fn wire_name(self) -> &'static str {
        match self {
            Self::Panic => "panic",
            Self::Abort => "abort",
            Self::Segv => "segv",
        }
    }

    fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.wire_name() == name)
    }
}

/// Why a `debug-panic` line was refused.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum DebugPanicRefused {
    /// A WebSocket or remote relay client asked.
    NotLocal,
    /// `kind` is missing or names no [`CrashKind`].
    BadKind,
    /// A field other than `kind`.
    UnknownField(String),
    /// The crash thread did not start.
    Spawn(String),
}

impl std::fmt::Display for DebugPanicRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotLocal => f.write_str("debug-panic requires a trusted local connection"),
            Self::BadKind => {
                f.write_str("bad request: debug-panic kind must be panic, abort or segv")
            }
            Self::UnknownField(field) => {
                write!(f, "bad request: {COMMAND} takes no field {field:?}")
            }
            Self::Spawn(error) => write!(f, "debug-panic could not start its thread: {error}"),
        }
    }
}

impl std::error::Error for DebugPanicRefused {}

/// Answer a `debug-panic` line, handing its kind to `crash`; `None` for any
/// other line.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
    crash: impl FnOnce(CrashKind) -> Result<(), DebugPanicRefused>,
) -> Option<bool> {
    let Ok(Value::Object(mut request)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    if request.get("cmd").and_then(Value::as_str) != Some(COMMAND) {
        return None;
    }
    let id = request.remove("id");
    request.remove("cmd");
    let local = mux.control_clients.is_unix(client) && !mux.is_remote_client(client);
    let kind = if local { parse(request) } else { Err(DebugPanicRefused::NotLocal) };
    let started = kind.and_then(|kind| crash(kind).map(|()| kind));
    let kind = match started {
        Ok(kind) => kind,
        Err(refused) => return Some(send_request_error(writer, id, &refused.to_string())),
    };
    let data = json!({"kind": kind.wire_name(), "pid": std::process::id()});
    Some(send_response(
        writer,
        Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
    ))
}

fn parse(mut fields: Map<String, Value>) -> Result<CrashKind, DebugPanicRefused> {
    let kind = fields.remove("kind");
    if let Some(field) = fields.keys().next() {
        return Err(DebugPanicRefused::UnknownField(field.clone()));
    }
    kind.as_ref()
        .and_then(Value::as_str)
        .and_then(CrashKind::parse)
        .ok_or(DebugPanicRefused::BadKind)
}

/// Crash as `kind` says, on [`THREAD`].
pub(super) fn fire(kind: CrashKind) -> Result<std::thread::JoinHandle<()>, DebugPanicRefused> {
    // supervise-allow: the injected `panic` must end only this thread (module doc); crash-matrix.py counts its one panic-log report.
    cmux_threads::spawn(THREAD, cmux_threads::ThreadQos::Utility, move || crash_now(kind))
        .map_err(|error| DebugPanicRefused::Spawn(error.to_string()))
}

/// Crash the calling thread (`Panic`) or the process (`Abort`, `Segv`).
#[allow(
    clippy::panic,
    reason = "debug-panic's panic kind: a debug and bench build crash injector, not in release"
)]
pub(super) fn crash_now(kind: CrashKind) {
    match kind {
        // crash-allow: debug-panic's panic kind; the module is not in release builds
        CrashKind::Panic => panic!("debug-panic: injected daemon panic"),
        CrashKind::Segv => fault(),
        CrashKind::Abort => {}
    }
    // crash-allow: debug-panic's abort kind, and the end of a segv store the kernel let through
    std::process::abort();
}

/// An address in the first page, which is never mapped: macOS reserves it
/// (`__PAGEZERO`) and Linux refuses to map below `vm.mmap_min_addr`.
const UNMAPPED: usize = 0x10;

/// Store to [`UNMAPPED`]: the CPU faults, and the kernel ends the process
/// with SIGSEGV (EXC_BAD_ACCESS, KERN_INVALID_ADDRESS on macOS). Should the
/// store return, [`crash_now`] aborts.
fn fault() {
    let address = std::ptr::with_exposed_provenance_mut::<u8>(UNMAPPED);
    // SAFETY: none in the language's sense: this store is the crash. The
    // address is in the never-mapped first page, so it can change no memory;
    // the store is volatile so it is emitted as written.
    unsafe { std::ptr::write_volatile(address, 1) };
}

#[cfg(test)]
#[path = "debug_crash_inject_tests.rs"]
mod tests;
