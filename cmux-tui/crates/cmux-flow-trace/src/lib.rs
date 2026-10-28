//! Key-press flow hops (plans/cmux-next/trace.md, "Key-press flows") as records of the process's
//! trace ring (`cmux-trace`, "Release trace ring v1"). The API is the one the daemon, the terminal
//! host and the holder call; the ring does the work, so this crate has no ring, file or thread of
//! its own.
//!
//! A hop is one record in category [`category::KEY`], or two for a hop that carries a flow id:
//! - name: the hop name, interned in the ring at its first record ([`hop_name`]);
//! - phase: a hop that carries the press's flow id is a step of that flow, Chrome's
//!   `TRACE_EVENT_FLAG_FLOW_IN | TRACE_EVENT_FLAG_FLOW_OUT` (base/trace_event/trace_event.h;
//!   `perfetto::Flow`, not `TerminatingFlow`, in perfetto/tracing/track_event_args.h): a
//!   [`Phase::FlowIn`] record (the press arrived here), then a [`Phase::FlowOut`] record (it goes
//!   on), both with arg1 the flow id. Every Rust hop is a middle step; only the app's last hop ends
//!   the flow (a `FlowIn` with no `FlowOut`). A reader takes the `FlowIn`'s time as the hop's. A hop
//!   no message carries the id to is one [`Phase::Instant`] with arg1 0, which trace.py places by
//!   its terminal;
//! - arg0: the terminal key, the first 8 bytes of its 16-byte id read big-endian ([`terminal_key`]),
//!   the same number from a hex id (the daemon) and from the raw bytes (the host, the holder).
//!
//! The ring stamps the clock (`CLOCK_UPTIME_RAW` on macOS) and the thread. Off, a hop is one
//! relaxed load and a branch; on, it is a ring write: no lock, allocation or system call.
//!
//! Hops record only while a recording runs ([`cmux_trace::recording`]) and flows are on. Flows turn
//! on when [`init`] finds `CMUX_TRACE_FLOWS` naming a directory and starts the process's recording
//! there, or when [`set_enabled`] turns them on for a recording someone else started. The key
//! category is in the black box's defaults, so the recording gate keeps per-key hops out of the
//! black box: after a `trace.stop` a hop writes nothing until the next recording starts.
//!
//! `CMUX_TRACE_FLOWS` means "the recording is a file in this directory". When it cannot be (the
//! process's `main` started its black box in another directory, or the recording could not be
//! mapped as a file), [`init`] stops a recording it started, writes one line to stderr and leaves
//! flows off. Ring files are unix only until task p09-observability-132, so flows are too.
//!
//! std and libc only (cmux-trace is too): the holder (`cmux-holder`) links it.

#![cfg_attr(not(test), deny(clippy::disallowed_methods))]
#![forbid(unsafe_code)]

use std::ffi::OsStr;
use std::path::Path;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_trace::{InternedName, Phase, Role, category};

/// The key category's bit index: the `category` byte of every hop name.
const KEY_BIT: u8 = category::KEY.trailing_zeros() as u8;

/// Whether hops are wanted (see the module doc); they write only while a recording runs as well.
/// Off by default.
static FLOWS: AtomicBool = AtomicBool::new(false);
/// What the first [`init`] found, so later calls neither read the environment nor start again.
static INIT: OnceLock<bool> = OnceLock::new();

/// Starts flow hops in this process when `CMUX_TRACE_FLOWS` names a directory: the process's black
/// box (as this process's [`Role`], unless its `main` started one already) and a recording of the
/// key category, both in that directory. Call it once at process start, before any request or PTY
/// work; later calls do nothing. Returns whether hops are on.
pub fn init() -> bool {
    *INIT.get_or_init(|| {
        let Some(dir) = std::env::var_os("CMUX_TRACE_FLOWS").filter(|dir| !dir.is_empty()) else {
            return false;
        };
        match start_in(Path::new(&dir), process_role()) {
            Ok(()) => true,
            Err(why) => {
                eprintln!("cmux-flow-trace: key-press flows are off: {why}");
                false
            }
        }
    })
}

/// [`init`]'s work with the directory and role given: the black box, a key recording, and the
/// switch on. When the recording is not a file in `dir`, a recording this call started stops and
/// the error says why.
fn start_in(dir: &Path, role: Role) -> Result<(), String> {
    if !cfg!(unix) {
        return Err("cmux-trace maps ring files on unix only (task p09-observability-132)".into());
    }
    // The ring-open thread runs on its own; a process never waits for its file.
    drop(cmux_trace::init_blackbox(dir, role));
    // `AlreadyRecording`: a `trace.start` came first, and its recording takes the hops.
    let started = cmux_trace::start_recording(category::KEY).is_ok();
    let problem = cmux_trace::status().map_or_else(
        || Some("cmux-trace did not start".to_owned()),
        |status| recording_problem(&status, dir),
    );
    match problem {
        None => {
            FLOWS.store(true, Ordering::Relaxed);
            Ok(())
        }
        Some(problem) => {
            if started {
                let _ = cmux_trace::stop();
            }
            Err(problem)
        }
    }
}

/// Why the recording `status` describes is not a file in `dir` a reader finds, if it is not.
fn recording_problem(status: &cmux_trace::Status, dir: &Path) -> Option<String> {
    if !status.recording {
        return Some("no recording runs".to_owned());
    }
    if !status.recording_file_backed {
        return Some(format!("the recording could not be mapped as a file in {}", dir.display()));
    }
    match status.recording_path.as_deref().and_then(Path::parent) {
        Some(parent) if parent == dir => None,
        Some(parent) => Some(format!(
            "this process's recording is in {}, not in CMUX_TRACE_FLOWS {}",
            parent.display(),
            dir.display()
        )),
        None => Some("the recording has no path".to_owned()),
    }
}

/// The role this process's rings are named by, from its executable and first argument: the holder
/// (its own binary, or `__holder` of the host binary or of `cmux-tui`), a terminal host (its own
/// binary, or `cmux-tui __terminal-host` on Linux), else the daemon.
fn process_role() -> Role {
    let mut args = std::env::args_os();
    let exe = args.next();
    let first = args.next();
    role_of(exe.as_deref().and_then(|exe| Path::new(exe).file_stem()), first.as_deref())
}

fn role_of(exe_stem: Option<&OsStr>, first_arg: Option<&OsStr>) -> Role {
    let stem = exe_stem.and_then(OsStr::to_str).unwrap_or("");
    // `__holder` before the host binary's name: `cmux-tui-host __holder` is the holder.
    if stem.starts_with("cmux-holder") || first_arg == Some(OsStr::new("__holder")) {
        Role::Holder
    } else if stem.starts_with("cmux-tui-host") || first_arg == Some(OsStr::new("__terminal-host"))
    {
        Role::TerminalHost
    } else {
        Role::Daemon
    }
}

/// Turns hops on or off for the recordings that run (a `trace.start` with keys, its stop). Hops
/// write only while a recording runs and the key category is on as well.
pub fn set_enabled(on: bool) {
    FLOWS.store(on, Ordering::Relaxed);
}

/// Whether hops are recorded in this process now.
pub fn enabled() -> bool {
    on() && cmux_trace::enabled(category::KEY)
}

/// The hop gate: flows wanted (one relaxed load, all a hop costs when off), then a recording runs.
#[inline(always)]
fn on() -> bool {
    FLOWS.load(Ordering::Relaxed) && cmux_trace::recording()
}

/// Records hop `name` of flow `flow` (0: a hop no message carries the id to) on the terminal whose
/// lowercase hex id is `terminal`. No allocation, lock or system call.
#[inline]
pub fn hop(name: &'static str, flow: u64, terminal: &str) {
    if on() {
        write_hop(name, flow, terminal_key(terminal.as_bytes()));
    }
}

/// [`hop`] for a terminal named by its 16 raw id bytes (the holder, the terminal host).
#[inline]
pub fn hop_id(name: &'static str, flow: u64, terminal: &[u8; 16]) {
    if on() {
        let mut first = [0u8; 8];
        first.copy_from_slice(&terminal[..8]);
        write_hop(name, flow, u64::from_be_bytes(first));
    }
}

/// A hop's records: one instant with no flow id, else a flow step (see the module doc).
#[inline(never)]
fn write_hop(name: &'static str, flow: u64, terminal: u64) {
    let name = hop_name(name);
    if flow == 0 {
        cmux_trace::write_interned(category::KEY, name, Phase::Instant, 0, terminal, 0);
    } else {
        cmux_trace::write_interned(category::KEY, name, Phase::FlowIn, 0, terminal, flow);
        cmux_trace::write_interned(category::KEY, name, Phase::FlowOut, 0, terminal, flow);
    }
}

/// Whether every hop recorded before the call can be read from the recording file: true while
/// hops are on, since a hop is in the file's shared mapping when it returns. Never waits.
pub fn flush() -> bool {
    enabled()
}

/// The terminal key of a lowercase hex terminal id: its first 16 hex digits as a big-endian u64,
/// a shorter id left-aligned (so it is [`hop_id`]'s number for the same bytes). 0 for an id that is
/// empty or not hex (a browser surface, a local PTY with no host identity).
fn terminal_key(hex: &[u8]) -> u64 {
    let digits = &hex[..hex.len().min(16)];
    let mut key = 0u64;
    for &digit in digits {
        let value = match digit {
            b'0'..=b'9' => digit - b'0',
            b'a'..=b'f' => digit - b'a' + 10,
            b'A'..=b'F' => digit - b'A' + 10,
            _ => return 0,
        };
        key = key << 4 | u64::from(value);
    }
    if digits.is_empty() { 0 } else { key << (4 * (16 - digits.len())) }
}

/// The interned name of hop `name`. Each hop of trace.md's table has its own; a name not in it
/// records as `flow.hop.unknown`, so a new hop is added here with its call site.
fn hop_name(name: &str) -> &'static InternedName {
    static DAEMON_SEND_WRITE: InternedName = InternedName::new("daemon.send.write", KEY_BIT);
    static DAEMON_SEND_WRITTEN: InternedName = InternedName::new("daemon.send.written", KEY_BIT);
    static HOST_PTY_WRITE: InternedName = InternedName::new("host.pty.write", KEY_BIT);
    static DAEMON_PTY_WRITE: InternedName = InternedName::new("daemon.pty.write", KEY_BIT);
    static HOST_PTY_READ: InternedName = InternedName::new("host.pty.read", KEY_BIT);
    static HOLDER_PTY_READ: InternedName = InternedName::new("holder.pty.read", KEY_BIT);
    static DAEMON_OUTPUT_HOST: InternedName = InternedName::new("daemon.output.host", KEY_BIT);
    static DAEMON_OUTPUT_HOLDER: InternedName = InternedName::new("daemon.output.holder", KEY_BIT);
    static DAEMON_OUTPUT_ATTACH: InternedName = InternedName::new("daemon.output.attach", KEY_BIT);
    static UNKNOWN: InternedName = InternedName::new("flow.hop.unknown", KEY_BIT);
    match name {
        "daemon.send.write" => &DAEMON_SEND_WRITE,
        "daemon.send.written" => &DAEMON_SEND_WRITTEN,
        "host.pty.write" => &HOST_PTY_WRITE,
        "daemon.pty.write" => &DAEMON_PTY_WRITE,
        "host.pty.read" => &HOST_PTY_READ,
        "holder.pty.read" => &HOLDER_PTY_READ,
        "daemon.output.host" => &DAEMON_OUTPUT_HOST,
        "daemon.output.holder" => &DAEMON_OUTPUT_HOLDER,
        "daemon.output.attach" => &DAEMON_OUTPUT_ATTACH,
        _ => &UNKNOWN,
    }
}

const HEX: &[u8; 16] = b"0123456789abcdef";

/// Lowercase hex of a terminal's 16-byte id (the daemon's `TerminalId::to_hex`).
pub fn hex(id: &[u8]) -> String {
    let mut out = String::with_capacity(id.len() * 2);
    for byte in id {
        out.push(char::from(HEX[usize::from(byte >> 4)]));
        out.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Rust hops of trace.md's "Key-press flows" table.
    const HOPS: [&str; 9] = [
        "daemon.send.write",
        "daemon.send.written",
        "host.pty.write",
        "daemon.pty.write",
        "host.pty.read",
        "holder.pty.read",
        "daemon.output.host",
        "daemon.output.holder",
        "daemon.output.attach",
    ];

    #[test]
    fn hex_matches_the_daemon_terminal_id() {
        assert_eq!(hex(&[0x00, 0x0f, 0xa5, 0xff]), "000fa5ff");
    }

    #[test]
    fn a_hex_id_and_its_bytes_give_one_terminal_key() {
        let id: [u8; 16] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 9, 9, 9, 9, 9, 9, 9, 9];
        assert_eq!(terminal_key(hex(&id).as_bytes()), 0x0123_4567_89ab_cdef);
        assert_eq!(terminal_key(b"00ff"), 0x00ff_0000_0000_0000);
        assert_eq!(terminal_key(b"ABCD"), 0xabcd_0000_0000_0000);
        assert_eq!(terminal_key(b""), 0);
        assert_eq!(terminal_key(b"00zz"), 0);
    }

    #[test]
    fn every_hop_of_the_table_has_its_own_name() {
        let mut seen = std::collections::HashSet::new();
        for name in HOPS {
            let interned: *const InternedName = hop_name(name);
            assert!(!std::ptr::eq(interned, hop_name("flow.hop.unknown")), "{name} has no name");
            assert!(seen.insert(interned as usize), "{name} shares a name");
        }
    }

    #[test]
    fn the_role_comes_from_the_executable() {
        let os = |text: &'static str| Some(OsStr::new(text));
        assert_eq!(role_of(os("cmux-holder"), None), Role::Holder);
        assert_eq!(role_of(os("cmux-tui-host"), os("__holder")), Role::Holder);
        assert_eq!(role_of(os("cmux-tui"), os("__holder")), Role::Holder);
        assert_eq!(role_of(os("cmux-tui-host"), os("--bootstrap-stdio")), Role::TerminalHost);
        assert_eq!(role_of(os("cmux-tui"), os("__terminal-host")), Role::TerminalHost);
        assert_eq!(role_of(os("cmux-tui"), os("serve")), Role::Daemon);
        assert_eq!(role_of(None, None), Role::Daemon);
    }
}
