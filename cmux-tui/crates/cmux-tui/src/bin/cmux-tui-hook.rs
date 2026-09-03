//! Agent hook helper: forwards one provider hook event to the cmux-tui
//! session journal.
//!
//! Providers (codex, cursor, gemini, grok) run hook commands synchronously
//! and block the agent until the command exits, so this helper never waits
//! for the journal commit in the provider's process: it reads the payload,
//! hands the request to a detached child, and exits once the child has
//! written the request to the server socket. Waiting for that write, and not
//! for the receipt, keeps two properties: events reach the server in
//! provider order, and a server that stops accepting requests applies
//! backpressure to the provider instead of spawning an unbounded number of
//! retrying children. The child waits for the receipt and retries.

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
const SOCKET_TIMEOUT: Duration = Duration::from_secs(4);
/// Bound on the provider-facing wait for the child's "request written"
/// signal. The child itself gives up at `SOCKET_TIMEOUT` and closes the pipe,
/// so this only fires if the child is stuck; the margin keeps the child's own
/// deadline authoritative.
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

fn main() -> ExitCode {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
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
    match parse_args(arguments).and_then(run) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-tui-hook: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: Args) -> anyhow::Result<()> {
    if shadowed_by_grok(&args.source, env::var_os("GROK_HOOK_EVENT").as_deref()) {
        drain_native_payload()?;
        return Ok(());
    }
    let socket = match env::var_os("CMUX_TUI_SOCKET").filter(|value| !value.is_empty()) {
        Some(socket) => PathBuf::from(socket),
        None => {
            drain_native_payload()?;
            return Ok(());
        }
    };
    let terminal = env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|value| !value.is_empty());
    let native = read_native_payload(io::stdin().lock())?;
    let ingress = cmux_tui_core::agent_hook_journal_ingress(
        &args.source,
        &args.native_event,
        terminal.as_deref(),
        native,
    )?;
    let event = serde_json::to_value(ingress)?;
    let (request_id, encoded) = encode_request(event)?;
    let handoff = handoff_wait(&args.source, &args.native_event);
    match detach::append_detached(&socket, &request_id, &encoded, handoff)? {
        Handoff::Sent => Ok(()),
        Handoff::ChildExited => bail!("hook child gave up before writing the journal request"),
        Handoff::TimedOut => {
            bail!("journal request handoff was not confirmed within {} ms", handoff.as_millis())
        }
    }
}

/// Outcome of the provider-facing wait for the detached child.
#[derive(Debug, PartialEq, Eq)]
enum Handoff {
    /// The child wrote the full request to the server socket.
    Sent,
    /// The child exited without writing the request (no listener, or it gave
    /// up at `SOCKET_TIMEOUT`).
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
/// handed to a thread that would die with this one-shot process. The child has
/// its own `SOCKET_TIMEOUT` deadline; the OS owns its eventual orphaned
/// lifetime after this process exits.
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

fn encode_request(event: Value) -> anyhow::Result<(String, Vec<u8>)> {
    let (request_id, idempotency_key) = random_identifiers()?;
    let request = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":request_id,
        "operation":"session.journal.append",
        "params":{"machine":"current","session":"current","event":event},
        "idempotency_key":idempotency_key,
    });
    let mut encoded = serde_json::to_vec(&request)?;
    encoded.push(b'\n');
    if encoded.len() > MAX_MESSAGE_BYTES {
        bail!("agent hook request exceeds the 4 MiB protocol limit");
    }
    Ok((request_id, encoded))
}

/// Sends the request and waits for the journal receipt, retrying until
/// `SOCKET_TIMEOUT`. `on_sent` runs each time the full request has been
/// written to the server, so the parent can stop waiting for ordering.
fn append_with_receipt(
    socket: &Path,
    request_id: &str,
    encoded: &[u8],
    on_sent: &dyn Fn(),
) -> anyhow::Result<()> {
    retry_until(SOCKET_TIMEOUT, |deadline| {
        append_once(socket, encoded, request_id, deadline, on_sent)
    })
}

#[derive(Debug)]
enum AppendAttemptError {
    Retryable(anyhow::Error),
    Fatal(anyhow::Error),
}

fn retry_until<T>(
    timeout: Duration,
    mut attempt: impl FnMut(Instant) -> Result<T, AppendAttemptError>,
) -> anyhow::Result<T> {
    let deadline = Instant::now() + timeout;
    let mut last_error = None;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            let error = last_error.unwrap_or_else(|| anyhow!("journal append timed out"));
            return Err(error).context(format!(
                "journal append was not acknowledged within {} ms",
                timeout.as_millis()
            ));
        }
        match attempt(deadline) {
            Ok(value) => return Ok(value),
            Err(AppendAttemptError::Fatal(error)) => return Err(error),
            Err(AppendAttemptError::Retryable(error)) => {
                last_error = Some(error);
                // Admission reopens as short-lived clients finish. Yielding lets
                // the server make progress without adding a timer to hook paths.
                std::thread::yield_now();
            }
        }
    }
}

fn append_once(
    socket: &Path,
    encoded: &[u8],
    request_id: &str,
    deadline: Instant,
    on_sent: &dyn Fn(),
) -> Result<(), AppendAttemptError> {
    let mut stream = connect_before(socket, deadline)?;
    write_before(&mut *stream, encoded, deadline)?;
    on_sent();
    let response = read_before(stream, deadline)?;
    let response: Value = serde_json::from_slice(&response)
        .map_err(|error| AppendAttemptError::Fatal(error.into()))?;
    if response.get("protocol").and_then(Value::as_str) != Some("cmux.protocol/2")
        || response.get("type").and_then(Value::as_str) != Some("response")
    {
        return Err(AppendAttemptError::Fatal(anyhow!(
            "journal append returned an invalid response envelope"
        )));
    }
    if response.get("id").and_then(Value::as_str) != Some(request_id) {
        return Err(AppendAttemptError::Fatal(anyhow!(
            "journal append returned a mismatched request id"
        )));
    }
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        let error = response
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("journal append failed");
        let error = anyhow!(error.to_owned());
        return Err(
            if response
                .get("error")
                .and_then(|error| error.get("retryable"))
                .and_then(Value::as_bool)
                == Some(true)
            {
                AppendAttemptError::Retryable(error)
            } else {
                AppendAttemptError::Fatal(error)
            },
        );
    }
    Ok(())
}

fn remaining_before(deadline: Instant) -> Result<Duration, AppendAttemptError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(AppendAttemptError::Retryable(anyhow!("journal append deadline expired")))
    } else {
        Ok(remaining)
    }
}

fn connect_before(
    socket: &Path,
    deadline: Instant,
) -> Result<Box<dyn transport::Stream>, AppendAttemptError> {
    let remaining = remaining_before(deadline)?;
    let socket = socket.to_path_buf();
    let display = socket.display().to_string();
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let connector = std::thread::Builder::new()
        .name("journal-hook-connect".into())
        .spawn(move || {
            let _ = sender.send(transport::connect(&socket));
        })
        .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
    let result = match receiver.recv_timeout(remaining) {
        Ok(result) => {
            let _ = connector.join();
            result
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            let _ = connector.join();
            return Err(AppendAttemptError::Retryable(anyhow!(
                "journal socket connector stopped without a result"
            )));
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            // This helper is a short-lived process. Dropping the join handle is
            // safe here because retry_until immediately reaches the same final
            // deadline and main exits, which terminates the blocked connector.
            drop(connector);
            return Err(AppendAttemptError::Retryable(anyhow!("connect to {display} timed out")));
        }
    };
    result.map_err(|error| {
        let transient = matches!(
            error.kind(),
            io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        );
        let error = anyhow!(error).context(format!("connect to {display}"));
        if transient {
            AppendAttemptError::Retryable(error)
        } else {
            // No listener means this terminal is no longer attached to a live
            // cmux-tui. Retrying a stale path only delays synchronous providers.
            AppendAttemptError::Fatal(error)
        }
    })
}

fn write_before(
    stream: &mut dyn transport::Stream,
    encoded: &[u8],
    deadline: Instant,
) -> Result<(), AppendAttemptError> {
    let mut offset = 0;
    while offset < encoded.len() {
        stream
            .set_write_timeout(Some(remaining_before(deadline)?))
            .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        match stream.write(&encoded[offset..]) {
            Ok(0) => {
                return Err(AppendAttemptError::Retryable(
                    io::Error::from(io::ErrorKind::WriteZero).into(),
                ));
            }
            Ok(written) => offset += written,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(AppendAttemptError::Retryable(error.into())),
        }
    }
    loop {
        stream
            .set_write_timeout(Some(remaining_before(deadline)?))
            .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        match stream.flush() {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(AppendAttemptError::Retryable(error.into())),
        }
    }
}

fn read_before(
    stream: Box<dyn transport::Stream>,
    deadline: Instant,
) -> Result<Vec<u8>, AppendAttemptError> {
    let mut reader = BufReader::new(stream);
    let mut response = Vec::new();
    loop {
        reader
            .get_ref()
            .set_read_timeout(Some(remaining_before(deadline)?))
            .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        let available =
            reader.fill_buf().map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        if available.is_empty() {
            return Err(AppendAttemptError::Retryable(anyhow!(
                "journal append closed without a complete response"
            )));
        }
        let consumed = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |newline| newline + 1);
        if response.len().saturating_add(consumed) > MAX_RESPONSE_BYTES {
            return Err(AppendAttemptError::Fatal(anyhow!(
                "journal append response exceeds 16 MiB"
            )));
        }
        let complete = available[consumed - 1] == b'\n';
        response.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        if complete {
            return Ok(response);
        }
    }
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
    /// socket buffer, and a server that stops accepting stalls the provider
    /// for at most the child's `SOCKET_TIMEOUT` instead of fanning out.
    pub(super) fn append_detached(
        socket: &Path,
        request_id: &str,
        encoded: &[u8],
        handoff_wait: std::time::Duration,
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
    ) -> anyhow::Result<Handoff> {
        use std::os::unix::process::CommandExt;
        let exe = std::env::current_exe().context("locate hook helper")?;
        let mut command = Command::new(exe);
        command
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
    ) -> anyhow::Result<Handoff> {
        let exe = std::env::current_exe().context("locate hook helper")?;
        let mut command = Command::new(exe);
        command
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

    #[test]
    fn codex_session_end_handoff_stays_below_the_codex_hook_cap() {
        assert!(handoff_wait("codex", "SessionEnd") < Duration::from_secs(3));
        assert!(handoff_wait("codex", "Stop") > SOCKET_TIMEOUT);
        assert!(handoff_wait("claude", "SessionEnd") > SOCKET_TIMEOUT);
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

    #[test]
    fn retries_transient_admission_loss_within_one_bounded_receipt_window() {
        let mut attempts = 0;
        retry_until(Duration::from_millis(100), |_| {
            attempts += 1;
            if attempts < 3 {
                Err(AppendAttemptError::Retryable(anyhow!("connection dropped")))
            } else {
                Ok(())
            }
        })
        .unwrap();
        assert_eq!(attempts, 3);
    }

    #[test]
    fn does_not_retry_a_durable_rejection() {
        let mut attempts = 0;
        let error = retry_until(Duration::from_millis(100), |_| {
            attempts += 1;
            Err::<(), _>(AppendAttemptError::Fatal(anyhow!("invalid event")))
        })
        .unwrap_err();
        assert_eq!(attempts, 1);
        assert_eq!(error.to_string(), "invalid event");
    }

    #[test]
    fn missing_session_socket_is_immediately_inactive() {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("missing.sock");
        let result = append_once(
            &socket,
            b"{}\n",
            "request_missing_socket",
            Instant::now() + Duration::from_millis(100),
            &|| {},
        );

        assert!(matches!(result, Err(AppendAttemptError::Fatal(_))));
    }
}
