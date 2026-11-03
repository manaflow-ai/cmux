//! Agent hook helper: forwards one provider hook event to the cmux-tui
//! session journal.
//!
//! Providers (codex, cursor, gemini, grok) run hook commands synchronously
//! and block the agent until the command exits, so this helper never waits
//! for the journal commit in the provider's process: it reads the payload,
//! hands the request to a detached child, and exits once the child has
//! written the request to the server socket or queued it behind the agent's
//! earlier events. The child puts the event in the agent's queue on disk;
//! one child per agent sends that queue in order over one connection and
//! waits for each receipt (`journal_append`), so events reach the server in
//! provider order, a busy server never costs an event, and a busy server
//! never faces more than one retrying child per agent.

use std::env;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use anyhow::{Context, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

const MAX_NATIVE_PAYLOAD_BYTES: u64 = 1024 * 1024;
const MAX_REQUEST_ID_BYTES: usize = 128;
const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
/// Bound on the provider-facing wait for the child's "request written or
/// queued" signal: a liveness bound, so a slow server never holds the agent's
/// tool call longer. The child keeps the event queued and sends it anyway.
const HANDOFF_WAIT: Duration = Duration::from_secs(5);
/// codex kills SessionEnd hooks at 3s (its hard cap). The provider-facing
/// process must report an unconfirmed handoff before that instead of being
/// killed; the detached child keeps trying to deliver the event regardless.
const CODEX_SESSION_END_HANDOFF_WAIT: Duration = Duration::from_secs(2);
/// Hidden mode: the detached child on platforms without `fork`. The request id
/// arrives as the first stdin line and the encoded request follows.
const DETACHED_MODE_ARG: &str = "__detached-append";

#[derive(Debug, PartialEq, Eq)]
struct Args {
    source: String,
    native_event: String,
}

// cmux-tui embeds this file as a module and enters through `run_cli`.
#[allow(dead_code)]
fn main() -> ExitCode {
    run_cli(env::args().skip(1).collect(), &[])
}

/// Runs the helper with `arguments` (argv without the program name).
/// `exe_prefix` is the argv that re-enters this mode through `current_exe`:
/// empty for the standalone helper, `["__agent-hook"]` inside cmux-tui.
pub(crate) fn run_cli(arguments: Vec<String>, exe_prefix: &[&str]) -> ExitCode {
    if arguments.len() == 1 && arguments[0] == DETACHED_MODE_ARG {
        return match detached_child_from_stdin() {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("cmux-tui-hook: {error:#}");
                ExitCode::FAILURE
            }
        };
    }
    if arguments.iter().any(|argument| matches!(argument.as_str(), "-h" | "--help")) {
        println!("Usage: cmux-tui-hook <agent> <native-event>");
        return ExitCode::SUCCESS;
    }
    // Muse Code runs this command directly (no `||:` wrapper reads in every
    // shell it may use), so a failure stays quiet there instead of showing on
    // every hook; the agent never waits on cmux.
    let quiet = arguments.first().is_some_and(|source| source == "muse");
    match parse_args(arguments).and_then(|args| run(args, exe_prefix)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) if quiet => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-tui-hook: {error:#}");
            ExitCode::FAILURE
        }
    }
}

/// Runs the helper for `source`'s `native_event` with a payload already read
/// (classic cmux's hook commands, which pick the event from it).
#[allow(dead_code)] // cmux-tui only; the standalone helper reads stdin
pub(crate) fn run_with_payload(
    source: String,
    native_event: String,
    payload: &[u8],
    exe_prefix: &[&str],
) -> ExitCode {
    let result = parse_args([source, native_event])
        .and_then(|args| run_reading(args, exe_prefix, || read_native_payload(payload)));
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-tui-hook: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: Args, exe_prefix: &[&str]) -> anyhow::Result<()> {
    run_reading(args, exe_prefix, || read_native_payload(io::stdin().lock()))
}

fn run_reading(
    args: Args,
    exe_prefix: &[&str],
    payload: impl FnOnce() -> anyhow::Result<Value>,
) -> anyhow::Result<()> {
    let inbox = inbox::Delivery::for_event(&args.source, &args.native_event);
    if shadowed_by_grok(&args.source, env::var_os("GROK_HOOK_EVENT").as_deref()) {
        drain_native_payload()?;
        inbox::print_nothing(inbox);
        return Ok(());
    }
    if inherited_route_is_untrusted(&args.source, |name| env::var_os(name)) {
        drain_native_payload()?;
        inbox::print_nothing(inbox);
        return Ok(());
    }
    let (socket, terminal) = match session_route(&args.source) {
        Some(route) => route,
        None => {
            drain_native_payload()?;
            inbox::print_nothing(inbox);
            return Ok(());
        }
    };
    let native = payload()?;
    let start_source = native.get("source").and_then(Value::as_str).unwrap_or("").to_owned();
    // Read before the journal event redacts it; it travels beside the event, never inside it.
    let live = cmux_tui_core::agent_hook_live_fields(&args.source, &args.native_event, &native);
    let mut ingress = cmux_tui_core::agent_hook_journal_ingress(
        &args.source,
        &args.native_event,
        terminal.as_deref(),
        native,
    )?;
    cmux_tui_core::stamp_agent_hook_observed_now(&mut ingress);
    let event = serde_json::to_value(ingress)?;
    let (request_id, encoded) = encode_request(event, live)?;
    let handoff = handoff_wait(&args.source, &args.native_event);
    match detach::append_detached(&socket, &request_id, &encoded, handoff, exe_prefix)? {
        Handoff::Sent => {}
        Handoff::ChildExited => bail!("hook child gave up before writing the journal request"),
        Handoff::TimedOut => {
            bail!("journal request handoff was not confirmed within {} ms", handoff.as_millis())
        }
    }
    // Messages for this terminal's agent ride on the hook's own output. A
    // failed handoff means the daemon is not answering, so the helper fails
    // without output and the installed command prints the empty object.
    match inbox {
        Some(inbox::Delivery::SessionBanner) => {
            inbox::session_banner(terminal.as_deref(), &start_source);
        }
        Some(inbox) => inbox::deliver(inbox, &socket, terminal.as_deref()),
        None => {}
    }
    Ok(())
}

/// Set to `launch` by a hook command that carries its own route (the Codex
/// wrapper's per-launch hooks), as opposed to one inherited from a process
/// environment.
const HOOK_ROUTE_ENV: &str = "CMUX_TUI_HOOK_ROUTE";

/// Codex 0.162 runs hooks in a shared app-server daemon that keeps the
/// environment of whichever shell started it. An installed hook there would
/// read that shell's `CMUX_TUI_*` (or `TMUX`) values and post every Codex
/// session's events, from any terminal or none, to that one cmux terminal, so
/// it posts nothing. The wrapper's hooks name their own terminal and still
/// route.
fn inherited_route_is_untrusted(
    source: &str,
    getenv: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> bool {
    source == "codex"
        && getenv(HOOK_ROUTE_ENV).is_none_or(|value| value != "launch")
        && cmux_tui_core::platform::descends_from_codex_app_server_daemon()
}

/// One agent's queue of hook events on disk.
#[path = "cmux-tui-hook/hook_spool.rs"]
mod hook_spool;

/// Hands back `server` (the daemon's, now serving `socket`) after starting a
/// thread that sends the agent hook events a stop or crash left queued for
/// the session: the new owner picks them up (R2), instead of waiting for
/// some agent's next hook.
#[allow(
    dead_code,
    reason = "only the daemon (cmux-tui main) calls it; the standalone helper builds this file too"
)]
pub(crate) fn resume<Server>(server: Server, socket: &Path) -> Server {
    let socket = socket.to_path_buf();
    let _ = std::thread::Builder::new()
        .name("hook-queues".into())
        .spawn(move || journal_append::send_session_queues(&socket));
    server
}
/// One journal append over the session socket, with its retries.
#[path = "cmux-tui-hook/journal_append.rs"]
mod journal_append;
use journal_append::{
    AppendAttemptError, append_with_receipt, connect_before, read_before, remaining_before,
    write_before,
};

/// Agent messages handed over as the hook's output.
#[path = "cmux-tui-hook/inbox.rs"]
mod inbox;

/// cmux's line under Claude Code's startup banner: how the session compacts.
#[path = "cmux-tui-hook/session_banner.rs"]
mod session_banner;

/// The session socket and terminal that receive this event: the terminal's
/// own `CMUX_TUI_*` values; for an agent that clears its hooks' environment
/// (Muse Code), the values of the agent process the hook runs under; or, for
/// an agent in a tmux session started outside cmux-tui (which has none), the
/// cmux-tui terminal attached to the pane's tmux session.
pub(crate) fn session_route(source: &str) -> Option<(PathBuf, Option<String>)> {
    if let Some(socket) = env::var_os("CMUX_TUI_SOCKET").filter(|value| !value.is_empty()) {
        let terminal = env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|value| !value.is_empty());
        return Some((PathBuf::from(socket), terminal));
    }
    #[cfg(unix)]
    if ancestor_route::clears_environment(source) {
        let route = ancestor_route::ancestor_terminal()?;
        return Some((route.socket, route.terminal));
    }
    #[cfg(not(unix))]
    let _ = source;
    let route = tmux_route::attached_terminal()?;
    Some((route.socket, Some(route.terminal)))
}

/// Finds the cmux-tui terminal whose tmux client shows the hook's pane.
///
/// An agent in a tmux session started outside cmux-tui (by a launcher over
/// SSH, say) has no `CMUX_TUI_*` variables, but the `tmux attach` running in
/// a cmux-tui terminal does. Clients of the pane's session, or of a session
/// grouped with it, are candidates: one whose current window holds the pane
/// first, then the most recently active. The first whose environment names a
/// session socket and terminal wins. Client environments are read from
/// `/proc`, so this is Linux only.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
#[path = "cmux-tui-hook/tmux_route.rs"]
mod tmux_route;

/// The session route of an agent that runs hooks with a cleared environment.
#[cfg(unix)]
#[path = "cmux-tui-hook/ancestor_route.rs"]
mod ancestor_route;

/// Outcome of the provider-facing wait for the detached child.
#[derive(Debug, PartialEq, Eq)]
enum Handoff {
    /// The child wrote the full request to the server socket.
    Sent,
    /// The child exited without writing or queueing the request (no
    /// listener).
    ChildExited,
    /// The bound elapsed first; the child is still trying on its own.
    TimedOut,
}

/// Own a spawned helper while setup can still fail.
/// `std::process::Child` does not terminate or reap itself when dropped, so
/// this guard synchronously terminates and waits for a child on those error
/// paths. After a successful handoff, `settle_detached_child` explicitly
/// releases a still-running child because this one-shot process is about to
/// return and cannot host a reaper thread.
struct DetachedChildGuard(Option<std::process::Child>);

impl DetachedChildGuard {
    fn new(child: std::process::Child) -> Self {
        Self(Some(child))
    }

    fn child_mut(&mut self) -> &mut std::process::Child {
        self.0.as_mut().expect("detached child guard is occupied")
    }

    /// Release the process handle without waiting. The detached child owns
    /// its remaining bounded receipt attempt; on Unix a parent that exits
    /// reparents it for eventual collection, and on Windows closing this
    /// handle releases the parent's ownership of the process object.
    fn release(mut self) {
        drop(self.0.take());
    }
}

impl Drop for DetachedChildGuard {
    fn drop(&mut self) {
        let Some(mut child) = self.0.take() else {
            return;
        };
        let _ = child.kill();
        let _ = child.wait();
    }
}

/// Settle the parent-side ownership before the provider-facing process
/// returns. A child that already exited is reaped and its stdout reader is
/// joined. A child that is still running must continue waiting for its receipt,
/// so its process handle and reader are explicitly released instead of being
/// handed to a thread that would die with this one-shot process. The child
/// ends when the agent's queue is empty or the session is gone; the OS owns
/// its eventual orphaned lifetime after this process exits.
fn settle_detached_child(mut child: DetachedChildGuard, reader: std::thread::JoinHandle<()>) {
    let status = child.child_mut().try_wait();
    match status {
        Ok(Some(_)) => {
            child.release();
            // `is_finished` keeps the provider-facing path non-blocking even
            // if a platform leaves the pipe reader briefly behind the child.
            if reader.is_finished() {
                let _ = reader.join();
            } else {
                drop(reader);
            }
        }
        Ok(None) => {
            drop(reader);
            child.release();
        }
        Err(_) => {
            // A status-query error cannot justify an unbounded wait on the
            // provider path. Release both handles; this one-shot parent exits
            // immediately, while the child keeps its own bounded attempt.
            drop(reader);
            child.release();
        }
    }
}

fn handoff_wait(source: &str, native_event: &str) -> Duration {
    if source == "codex" && native_event == "SessionEnd" {
        CODEX_SESSION_END_HANDOFF_WAIT
    } else {
        HANDOFF_WAIT
    }
}

/// Detached-child confirmation on platforms that respawn instead of forking:
/// one byte on stdout once the request is written.
fn confirm_handoff_on_stdout() {
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(b"1");
    let _ = stdout.flush();
}

/// Entry point of the detached child spawned by `DETACHED_MODE_ARG`.
fn detached_child_from_stdin() -> anyhow::Result<()> {
    let socket = env::var_os("CMUX_TUI_SOCKET")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .context("CMUX_TUI_SOCKET is required in detached mode")?;
    let mut reader = BufReader::new(io::stdin().lock());
    let request_id = read_detached_request_id(&mut reader)?;
    let mut encoded = Vec::new();
    reader
        .take(MAX_MESSAGE_BYTES as u64 + 1)
        .read_to_end(&mut encoded)
        .context("read detached request")?;
    anyhow::ensure!(encoded.len() <= MAX_MESSAGE_BYTES, "detached request exceeds 4 MiB");
    append_with_receipt(&socket, &request_id, &encoded, &confirm_handoff_on_stdout)
}

/// Read the detached request id without allowing a missing delimiter to grow
/// the destination string indefinitely. `read_line` otherwise keeps reading
/// until a newline or EOF, so the `Take` limit is part of the framing contract.
fn read_detached_request_id(reader: &mut impl BufRead) -> anyhow::Result<String> {
    // Allow an optional carriage return before the required newline. The
    // delimiter itself is not part of the request id byte limit.
    let line_limit =
        MAX_REQUEST_ID_BYTES.checked_add(2).expect("detached request id limit fits usize");
    let mut line = String::new();
    let bytes_read =
        reader.take(line_limit as u64).read_line(&mut line).context("read detached request id")?;
    if bytes_read == 0 {
        bail!("detached request id is empty");
    }
    if !line.ends_with('\n') {
        if bytes_read >= line_limit {
            bail!("detached request id exceeds {MAX_REQUEST_ID_BYTES} bytes");
        }
        bail!("detached request id is missing newline delimiter");
    }
    let request_id = line.trim_end_matches(['\r', '\n']);
    anyhow::ensure!(!request_id.is_empty(), "detached request id is empty");
    anyhow::ensure!(
        request_id.len() <= MAX_REQUEST_ID_BYTES,
        "detached request id exceeds {MAX_REQUEST_ID_BYTES} bytes"
    );
    Ok(request_id.to_owned())
}

fn shadowed_by_grok(source: &str, grok_hook_event: Option<&std::ffi::OsStr>) -> bool {
    matches!(source, "claude" | "cursor") && grok_hook_event.is_some_and(|value| !value.is_empty())
}

fn drain_native_payload() -> io::Result<()> {
    io::copy(&mut io::stdin().take(MAX_NATIVE_PAYLOAD_BYTES + 1), &mut io::sink()).map(|_| ())
}

fn parse_args(args: impl IntoIterator<Item = String>) -> anyhow::Result<Args> {
    let mut values = args.into_iter();
    let source = values.next().context("agent source is required")?;
    let native_event = values.next().context("native event is required")?;
    if let Some(extra) = values.next() {
        bail!("unexpected argument {extra:?}");
    }
    anyhow::ensure!(!source.is_empty(), "agent source cannot be empty");
    anyhow::ensure!(!native_event.is_empty(), "native event cannot be empty");
    Ok(Args { source, native_event })
}

fn read_native_payload(reader: impl Read) -> anyhow::Result<Value> {
    let mut bytes = Vec::new();
    reader.take(MAX_NATIVE_PAYLOAD_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_NATIVE_PAYLOAD_BYTES {
        bail!("agent hook payload exceeds 1048576 bytes");
    }
    if bytes.is_empty() {
        return Ok(json!({}));
    }
    if let Ok(value) = serde_json::from_slice(&bytes) {
        return Ok(value);
    }
    if let Ok(text) = String::from_utf8(bytes.clone()) {
        return Ok(json!({"encoding":"utf8","data":text}));
    }
    Ok(json!({"encoding":"base64","data":BASE64.encode(bytes)}))
}

/// `live` holds a turn-start hook's prompt for the hover card and a finished turn's last
/// message for its banner (`agent_hook_live_fields`): the daemon keeps them in memory only
/// (`session.journal.append` `live_prompt`, `live_reply`), never in the journal.
fn encode_request(
    event: Value,
    live: serde_json::Map<String, Value>,
) -> anyhow::Result<(String, Vec<u8>)> {
    let (request_id, idempotency_key) = random_identifiers()?;
    let mut params = json!({"machine":"current","session":"current","event":event});
    if let Some(object) = params.as_object_mut() {
        object.extend(live);
    }
    let request = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":request_id,
        "operation":"session.journal.append",
        "params":params,
        "idempotency_key":idempotency_key,
    });
    let mut encoded = serde_json::to_vec(&request)?;
    encoded.push(b'\n');
    if encoded.len() > MAX_MESSAGE_BYTES {
        bail!("agent hook request exceeds the 4 MiB protocol limit");
    }
    Ok((request_id, encoded))
}

#[cfg(any())]
mod detach {
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::path::Path;

    use anyhow::Context;

    use super::{Handoff, append_with_receipt};

    /// Forks a detached child that performs the append, then returns once the
    /// child has written the request (normally milliseconds) or has given up
    /// on delivering it. Ordering and backpressure both follow from that: the
    /// next provider hook cannot start until this request is in the server's
    /// socket buffer or queued behind the agent's earlier events, and a server
    /// that stops accepting stalls the provider for at most `handoff_wait`.
    pub(super) fn append_detached(
        socket: &Path,
        request_id: &str,
        encoded: &[u8],
        handoff_wait: std::time::Duration,
        _exe_prefix: &[&str],
    ) -> anyhow::Result<Handoff> {
        let mut fds = [0_i32; 2];
        // SAFETY: `fds` is a valid two-element array for pipe(2) to fill.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error()).context("create hook handoff pipe");
        }
        // SAFETY: pipe(2) returned two fresh descriptors this process owns.
        let (read_end, write_end) =
            unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        // SAFETY: the process is single-threaded here. The payload was read on
        // the main thread and the connector thread is only spawned by the
        // child after the fork, so no lock can be held by a vanished thread.
        let pid = unsafe { libc::fork() };
        if pid < 0 {
            return Err(io::Error::last_os_error()).context("fork hook child");
        }
        if pid == 0 {
            drop(read_end);
            let code = child_main(socket, request_id, encoded, write_end);
            // SAFETY: _exit only terminates the child without running
            // destructors that could touch parent-owned state.
            unsafe { libc::_exit(code) };
        }
        drop(write_end);
        Ok(wait_for_handoff(&read_end, handoff_wait))
    }

    fn child_main(socket: &Path, request_id: &str, encoded: &[u8], handoff: OwnedFd) -> i32 {
        // SAFETY: setsid has no memory-safety preconditions; failure only
        // means this process already leads a session, which is harmless.
        unsafe { libc::setsid() };
        if redirect_stdio_to_null().is_err() {
            return 1;
        }
        // Signal once, then close the pipe: retries after a parent timeout must
        // not write into a pipe nobody reads (Rust ignores SIGPIPE, so a
        // second write would only fail, but closing keeps the contract exact).
        let handoff = std::cell::Cell::new(Some(handoff));
        let signal_sent = move || {
            if let Some(handoff) = handoff.take() {
                let byte = [1_u8];
                // SAFETY: `handoff` is open until dropped below and the buffer
                // is one valid byte. A failed write only delays the parent.
                let _ = unsafe { libc::write(handoff.as_raw_fd(), byte.as_ptr().cast(), 1) };
                drop(handoff);
            }
        };
        match append_with_receipt(socket, request_id, encoded, &signal_sent) {
            Ok(()) => 0,
            Err(_) => 1,
        }
    }

    /// The provider waits for EOF on the hook's stdout, so the child must
    /// drop the inherited pipes before the parent exits.
    fn redirect_stdio_to_null() -> io::Result<()> {
        let null = std::fs::OpenOptions::new().read(true).write(true).open("/dev/null")?;
        for fd in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
            // SAFETY: both descriptors are open; dup2 replaces `fd` atomically.
            if unsafe { libc::dup2(null.as_raw_fd(), fd) } < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }

    /// Returns when the child reports the request was written (one byte) or
    /// exits (EOF). `handoff_wait` is an absolute deadline, so a signal storm
    /// cannot extend it through repeated `EINTR`.
    fn wait_for_handoff(read_end: &OwnedFd, handoff_wait: std::time::Duration) -> Handoff {
        let deadline = std::time::Instant::now() + handoff_wait;
        let mut descriptor =
            libc::pollfd { fd: read_end.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Handoff::TimedOut;
            }
            let timeout_ms = i32::try_from(remaining.as_millis().max(1)).unwrap_or(i32::MAX);
            // SAFETY: `descriptor` is one valid pollfd for the poll duration.
            let ready = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
            if ready == 0 {
                return Handoff::TimedOut;
            }
            if ready < 0 {
                if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Handoff::TimedOut;
            }
            let mut byte = [0_u8; 1];
            // SAFETY: `read_end` is open and `byte` is a valid one-byte buffer.
            let read = unsafe { libc::read(read_end.as_raw_fd(), byte.as_mut_ptr().cast(), 1) };
            return if read == 1 { Handoff::Sent } else { Handoff::ChildExited };
        }
    }
}

#[cfg(unix)]
mod detach {
    use super::{DETACHED_MODE_ARG, Handoff};
    use anyhow::Context;
    use std::io::{Read, Write};
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::sync::mpsc;
    use std::time::Duration;

    /// Spawn performs the platform fork+exec transition. The child does not
    /// run Rust code before exec, avoiding the POSIX post-fork restrictions.
    pub(super) fn append_detached(
        socket: &Path,
        request_id: &str,
        encoded: &[u8],
        handoff_wait: Duration,
        exe_prefix: &[&str],
    ) -> anyhow::Result<Handoff> {
        use std::os::unix::process::CommandExt;
        let exe = std::env::current_exe().context("locate hook helper")?;
        let mut command = Command::new(exe);
        command
            .args(exe_prefix)
            .arg(DETACHED_MODE_ARG)
            .env("CMUX_TUI_SOCKET", socket)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        // `pre_exec` runs in the child after fork and is therefore unsafe to
        // call unless the closure is limited to async-signal-safe operations.
        // `setsid` is async-signal-safe.
        let detach_session = || {
            // SAFETY: `setsid` takes no arguments and only changes the
            // calling process's session membership.
            if unsafe { libc::setsid() } < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        };
        unsafe {
            command.pre_exec(detach_session);
        }
        let mut child =
            super::DetachedChildGuard::new(command.spawn().context("spawn detached hook child")?);
        let mut stdin =
            child.child_mut().stdin.take().context("detached hook child has no stdin")?;
        stdin.write_all(request_id.as_bytes())?;
        stdin.write_all(b"\n")?;
        stdin.write_all(encoded)?;
        stdin.flush()?;
        drop(stdin);
        let mut stdout =
            child.child_mut().stdout.take().context("detached hook child has no stdout")?;
        let (sender, receiver) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut byte = [0_u8; 1];
            let outcome = match stdout.read(&mut byte) {
                Ok(1) => Handoff::Sent,
                _ => Handoff::ChildExited,
            };
            let _ = sender.send(outcome);
        });
        let outcome = receiver.recv_timeout(handoff_wait).unwrap_or(Handoff::TimedOut);
        super::settle_detached_child(child, reader);
        Ok(outcome)
    }
}

// Unix uses the `setsid`-based implementation above. Keep this fallback
// explicitly limited to targets that are neither Unix nor Windows, where no
// common process-group detachment API is available.
#[cfg(not(unix))]
mod detach {
    use std::io::{Read, Write};
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::sync::mpsc;
    use std::time::Duration;

    use anyhow::Context;

    use super::{DETACHED_MODE_ARG, Handoff};

    /// Respawns this helper with the request on its stdin, then waits (bounded)
    /// for the child's one-byte confirmation that the request reached the
    /// server socket, giving the same ordering and backpressure as the fork
    /// path. Windows adds process-detachment flags; other non-Unix targets use
    /// a regular child spawn because Rust has no common process-group API for
    /// them.
    pub(super) fn append_detached(
        socket: &Path,
        request_id: &str,
        encoded: &[u8],
        handoff_wait: Duration,
        exe_prefix: &[&str],
    ) -> anyhow::Result<Handoff> {
        let exe = std::env::current_exe().context("locate hook helper")?;
        let mut command = Command::new(exe);
        command
            .args(exe_prefix)
            .arg(DETACHED_MODE_ARG)
            .env("CMUX_TUI_SOCKET", socket)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        configure_detached_command(&mut command);
        let mut child =
            super::DetachedChildGuard::new(command.spawn().context("spawn detached hook child")?);
        let mut stdin =
            child.child_mut().stdin.take().context("detached hook child has no stdin")?;
        let mut stdout =
            child.child_mut().stdout.take().context("detached hook child has no stdout")?;
        stdin.write_all(request_id.as_bytes())?;
        stdin.write_all(b"\n")?;
        stdin.write_all(encoded)?;
        stdin.flush()?;
        drop(stdin);
        // Pipe reads have no timeout on Windows; a reader thread plus a
        // bounded channel wait gives the same absolute deadline as poll(2).
        let (sender, receiver) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut byte = [0_u8; 1];
            let outcome = match stdout.read(&mut byte) {
                Ok(1) => Handoff::Sent,
                _ => Handoff::ChildExited,
            };
            let _ = sender.send(outcome);
        });
        let outcome = receiver.recv_timeout(handoff_wait).unwrap_or(Handoff::TimedOut);
        super::settle_detached_child(child, reader);
        Ok(outcome)
    }

    #[cfg(windows)]
    fn configure_detached_command(command: &mut Command) {
        use std::os::windows::process::CommandExt;

        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }

    #[cfg(all(not(unix), not(windows)))]
    fn configure_detached_command(_command: &mut Command) {}
}

fn random_identifiers() -> anyhow::Result<(String, String)> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| anyhow!("allocate hook identity: {error}"))?;
    let mut suffix = String::with_capacity(32);
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in bytes {
        suffix.push(char::from(HEX[usize::from(byte >> 4)]));
        suffix.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    Ok((format!("request_{suffix}"), format!("mutation_{suffix}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A server may answer and close before the hook child reads. macOS then
    /// refuses `setsockopt(SO_RCVTIMEO)` with EINVAL although the receipt is
    /// still readable; treating that as a failed attempt re-sent the event,
    /// so the journal received it twice and out of order.
    #[cfg(unix)]
    #[test]
    fn codex_hook_receipt_from_a_server_that_already_closed_is_still_read() {
        let (client, mut server) = std::os::unix::net::UnixStream::pair().unwrap();
        server.write_all(b"{\"type\":\"response\"}\n").unwrap();
        drop(server);
        let deadline = Instant::now() + Duration::from_secs(2);
        match read_before(Box::new(client), deadline) {
            Ok(response) => assert_eq!(response, b"{\"type\":\"response\"}\n"),
            Err(AppendAttemptError::Retryable(error) | AppendAttemptError::Fatal(error)) => {
                panic!("the written receipt was not read: {error:#}")
            }
        }
    }

    fn cmux_environ(pid: u32) -> Option<std::collections::HashMap<String, String>> {
        let environment = |terminal: &str| {
            Some(
                [("CMUX_TUI_SOCKET", "/run/cmux.sock"), ("CMUX_TUI_TERMINAL_ID", terminal)]
                    .map(|(key, value)| (key.to_owned(), value.to_owned()))
                    .into(),
            )
        };
        match pid {
            10 => environment("term_other_window"),
            11 => environment("term_shows_pane"),
            12 => environment("term_recent"),
            // A plain SSH client: no cmux-tui terminal.
            13 => Some([("SSH_TTY".to_owned(), "/dev/pts/3".to_owned())].into()),
            _ => None,
        }
    }

    #[test]
    fn tmux_route_prefers_the_client_showing_the_pane() {
        let clients = "10\t500\t$1\t\t@2\n11\t100\t$1\t\t@1\n12\t900\t$7\t\t@9\n";
        let route = tmux_route::select("$1\t\t@1\n", clients, cmux_environ).unwrap();
        assert_eq!(route.terminal, "term_shows_pane");
        assert_eq!(route.socket, PathBuf::from("/run/cmux.sock"));
    }

    #[test]
    fn tmux_route_falls_back_to_the_most_recent_client_of_the_session_group() {
        // Client 13 shows the pane but is a plain SSH client; 12 attaches a
        // grouped session and is newer than 10.
        let clients = "13\t999\t$1\tgrp\t@1\n10\t500\t$1\tgrp\t@2\n12\t900\t$7\tgrp\t@9\n";
        let route = tmux_route::select("$1\tgrp\t@1", clients, cmux_environ).unwrap();
        assert_eq!(route.terminal, "term_recent");
    }

    #[test]
    fn tmux_route_ignores_other_sessions_and_non_cmux_clients() {
        let clients = "12\t900\t$7\t\t@9\n13\t999\t$1\t\t@1\n";
        assert_eq!(tmux_route::select("$1\t\t@1", clients, cmux_environ), None);
        assert_eq!(tmux_route::select("", clients, cmux_environ), None);
        assert_eq!(tmux_route::select("$1\t\t@1", "garbage\n1\t0\t$1\t\t@1\n", cmux_environ), None);
    }

    /// claude `SessionStart` carries cmux's startup line as `systemMessage`
    /// (shown to the person, never added to the model's context); with no
    /// line it is the empty object the installed command expects.
    #[test]
    fn claude_session_start_writes_the_startup_line_as_a_system_message() {
        let delivery = inbox::Delivery::for_event("claude", "SessionStart")
            .expect("claude SessionStart writes cmux's startup line");
        assert_eq!(delivery.output(None), json!({}));
        assert_eq!(delivery.output(Some("line")), json!({"systemMessage": "line"}));
        assert_eq!(inbox::Delivery::for_event("codex", "SessionStart"), None);
    }

    #[test]
    fn codex_session_end_handoff_stays_below_the_codex_hook_cap() {
        assert!(handoff_wait("codex", "SessionEnd") < Duration::from_secs(3));
        assert_eq!(handoff_wait("codex", "Stop"), HANDOFF_WAIT);
        assert_eq!(handoff_wait("claude", "SessionEnd"), HANDOFF_WAIT);
    }

    #[test]
    fn parses_short_positional_source_and_event() {
        assert_eq!(
            parse_args(["codex", "Stop"].map(str::to_owned)).unwrap(),
            Args { source: "codex".into(), native_event: "Stop".into() }
        );
    }

    #[test]
    fn grok_compatibility_events_are_deduplicated_inside_the_helper() {
        use std::ffi::OsStr;

        assert!(shadowed_by_grok("claude", Some(OsStr::new("Stop"))));
        assert!(shadowed_by_grok("cursor", Some(OsStr::new("stop"))));
        assert!(!shadowed_by_grok("codex", Some(OsStr::new("Stop"))));
        assert!(!shadowed_by_grok("claude", None));
    }

    #[test]
    fn invalid_utf8_is_retained_as_base64() {
        let native = read_native_payload(&[0xff, 0x00][..]).unwrap();
        assert_eq!(native, json!({"encoding":"base64","data":"/wA="}));
    }

    #[test]
    fn bounded_detached_request_id_preserves_uuid_and_payload() {
        use std::io::Cursor;

        let request_id = "550e8400-e29b-41d4-a716-446655440000";
        let mut reader =
            BufReader::new(Cursor::new(format!("{request_id}\n{{\"event\":\"Stop\"}}")));
        assert_eq!(read_detached_request_id(&mut reader).unwrap(), request_id);

        let mut payload = Vec::new();
        reader.read_to_end(&mut payload).unwrap();
        assert_eq!(payload, br#"{"event":"Stop"}"#);
    }

    #[test]
    fn bounded_detached_request_id_accepts_maximum_length_with_crlf() {
        use std::io::Cursor;

        let request_id = "x".repeat(MAX_REQUEST_ID_BYTES);
        let mut input = request_id.as_bytes().to_vec();
        input.extend_from_slice(b"\r\n{}");
        let mut reader = BufReader::new(Cursor::new(input));
        assert_eq!(read_detached_request_id(&mut reader).unwrap(), request_id);

        let mut payload = Vec::new();
        reader.read_to_end(&mut payload).unwrap();
        assert_eq!(payload, b"{}");
    }

    #[test]
    fn bounded_detached_request_id_rejects_an_unterminated_line() {
        use std::io::Cursor;

        let mut reader = BufReader::new(Cursor::new(b"550e8400-e29b-41d4-a716-446655440000"));
        let error = read_detached_request_id(&mut reader).unwrap_err();
        assert_eq!(error.to_string(), "detached request id is missing newline delimiter");
    }

    #[test]
    fn bounded_detached_request_id_rejects_an_oversized_line() {
        use std::io::Cursor;

        let mut input = vec![b'x'; MAX_REQUEST_ID_BYTES + 1];
        input.push(b'\n');
        let mut reader = BufReader::new(Cursor::new(input));
        let error = read_detached_request_id(&mut reader).unwrap_err();
        assert_eq!(
            error.to_string(),
            format!("detached request id exceeds {MAX_REQUEST_ID_BYTES} bytes")
        );
    }
}
