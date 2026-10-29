//! Browser runtimes (`browser-runtime-v1`, cx-2cob slice 2): the daemon
//! starts the remote browser host (`cmux-remote-browser-host`) on its own
//! machine for a control client, so a cmux app on another machine can show a
//! page that runs here. The app reaches the host's loopback port through
//! `loopback-forward-v1` on the same daemon link: no new listening socket
//! leaves this machine.
//!
//! Rules:
//! - Off unless the connection asks: a Unix control client declares the
//!   capability with `set-client-info` (as for loopback forwarding).
//! - The host comes from a fixed install directory
//!   (`<data dir>/cmux-tui/browser-host/current`, or `CMUX_TUI_BROWSER_HOST_DIR`);
//!   a request never names a path or an argument other than the first page.
//! - The per-launch secret goes to the host on its stdin (the first line,
//!   then the pipe stays open as the host's lifeline) and to the requesting
//!   connection in the reply. It is never in argv, the environment, a log or
//!   an event.
//! - A runtime belongs to its connection: `browser-runtime-stop` and the end
//!   of the connection stop it. The daemon's end also ends the lifeline.
//! - Bounded: a start deadline that ends a host that never listens, and
//!   per-connection and daemon-wide runtime limits.
//!
//! Wire (JSON lines):
//! - `browser-runtime-status {id}` answers `{installed, platform, runtimes}`.
//! - `browser-runtime-start {id, url?}` answers `{runtime, port, secret,
//!   installed}` once the host listens, or an error with `error_code`.
//! - `browser-runtime-stop {id, runtime}` answers `{stopped: true}`.

use cmux_threads::sync::Mutex;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::net::SocketAddr;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::ChildStdin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, Weak};
use std::time::Duration;

use cmux_process::{Child, Command, Stdio};
use cmux_threads::blocking::{BlockingKind, scoped_blocking_call};
use cmux_threads::checked::{fs as files, sync as waits};
use cmux_threads::work::{Lane, Priority, Shutdown};
use serde::Deserialize;
use serde_json::{Value, json};

use super::routes::{Route, RouteLine, RouteName};
use super::{FrameStage, MessageWriter, Response, send_response};
use crate::mux::Mux;
use crate::supervised::{self, Fatal, ShutdownBehavior};

pub const BROWSER_RUNTIME_CAPABILITY: &str = "browser-runtime-v1";
/// Overrides the install directory (development and tests).
pub(crate) const HOST_DIR_ENV: &str = "CMUX_TUI_BROWSER_HOST_DIR";
const HOST_BINARY: &str = "cmux-remote-browser-host";
/// A cold CEF start lists its port in a few seconds; this ends a host that
/// never does.
const START_TIMEOUT: Duration = Duration::from_secs(45);
/// How long a host may take to exit after its lifeline closes.
const STOP_GRACE: Duration = Duration::from_secs(5);
pub(crate) const MAX_RUNTIMES_PER_CLIENT: usize = 4;
pub(crate) const MAX_RUNTIMES_TOTAL: usize = 16;
/// Status reads queued or running, per connection and in the daemon: a
/// connection that sends status lines back to back gets a refusal past it,
/// so it cannot fill the files lane (as the trust calls' `CallSlot`).
pub(crate) const MAX_STATUS_READS_PER_CLIENT: usize = 4;
pub(crate) const MAX_STATUS_READS_TOTAL: usize = 16;
const MAX_URL_BYTES: usize = 8 * 1024;
const LOG_TAIL_BYTES: u64 = 2 * 1024;

struct Runtime {
    owner: u64,
    child: Child,
    /// The host's stdin: closing it stops the host.
    lifeline: Option<ChildStdin>,
    port: u16,
    log: PathBuf,
}

#[derive(Default)]
struct State {
    runtimes: HashMap<u64, Runtime>,
    /// Starts in progress by connection (they count against the limits).
    starting: HashMap<u64, usize>,
    /// Status reads queued or running, by connection ([`StatusRead`]).
    status_reads: HashMap<u64, usize>,
}

impl State {
    fn count(&self, client: u64) -> usize {
        self.runtimes.values().filter(|runtime| runtime.owner == client).count()
            + self.starting.get(&client).copied().unwrap_or(0)
    }

    fn total(&self) -> usize {
        self.runtimes.len() + self.starting.values().sum::<usize>()
    }

    fn release(&mut self, client: u64) {
        if let Some(count) = self.starting.get_mut(&client) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                self.starting.remove(&client);
            }
        }
    }
}

/// The daemon's browser runtimes, by connection.
#[derive(Default)]
pub(crate) struct BrowserRuntimes {
    /// Set by tests; else `HOST_DIR_ENV` or the platform data directory.
    root: Mutex<Option<PathBuf>>,
    next_id: AtomicU64,
    state: Mutex<State>,
    /// The mux whose work stops a host ([`Self::stop`]); bound once it is
    /// built.
    owner: OnceLock<Weak<Mux>>,
}

impl BrowserRuntimes {
    #[cfg(test)]
    pub(crate) fn set_root(&self, root: PathBuf) {
        *self.root.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(root);
    }

    fn root(&self) -> Option<PathBuf> {
        if let Some(root) =
            self.root.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
        {
            return Some(root);
        }
        if let Some(dir) = std::env::var_os(HOST_DIR_ENV).filter(|value| !value.is_empty()) {
            return Some(PathBuf::from(dir));
        }
        default_root()
    }

    /// The installed host: its version (the name of the directory that
    /// `current` names) and its executable. It reads the disk: work items
    /// and the start thread call it, never the reader thread.
    fn installed(&self) -> Option<(String, PathBuf)> {
        let version = files::canonicalize(self.root()?.join("current")).ok()?;
        let executable = executable_in(&version);
        if !files::metadata(&executable).is_ok_and(|metadata| metadata.is_file()) {
            return None;
        }
        Some((version.file_name()?.to_string_lossy().into_owned(), executable))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The connection ended: its runtimes stop.
    pub(super) fn disconnect(&self, client: u64) {
        let stopped: Vec<Runtime> = {
            let mut state = self.lock();
            let ids: Vec<u64> = state
                .runtimes
                .iter()
                .filter(|(_, runtime)| runtime.owner == client)
                .map(|(id, _)| *id)
                .collect();
            ids.into_iter().filter_map(|id| state.runtimes.remove(&id)).collect()
        };
        for runtime in stopped {
            self.stop(runtime);
        }
    }

    /// Closes the lifeline; a host that is still running after the grace
    /// time ends with its process group. The child is reaped only after any
    /// kill, so the kill never reaches a reused pid. The grace wait is a
    /// `will_block` work item, not a thread per stop.
    fn stop(&self, runtime: Runtime) {
        let Runtime { mut child, lifeline, log, .. } = runtime;
        drop(lifeline);
        let finish = move || {
            cmux_threads::work::will_block(|| {
                if !matches!(child.wait_timeout(STOP_GRACE), Ok(Some(_))) {
                    if let Ok(group) = libc::pid_t::try_from(child.id()) {
                        // SAFETY: plain syscall; the group's leader is unreaped.
                        unsafe { libc::killpg(group, libc::SIGKILL) };
                    }
                    let _ = child.wait();
                }
            });
            let _ = files::remove_file(&log);
        };
        // With no work (shutdown began, or the mux is gone) the host is left
        // to its closed lifeline: it exits by itself, unreaped until the
        // daemon ends.
        if let Some(mux) = self.owner.get().and_then(Weak::upgrade) {
            let _ = mux.work.post(
                Priority::BestEffort,
                Lane::System,
                Shutdown::ContinueOnShutdown,
                finish,
            );
        }
    }
}

impl super::ClientRegistry {
    /// Binds the mux whose work stops browser hosts.
    pub(crate) fn bind_browser_runtime_owner(&self, mux: Weak<Mux>) {
        let _ = self.browser_runtimes.owner.set(mux);
    }
}

#[cfg(target_os = "macos")]
fn default_root() -> Option<PathBuf> {
    cmux_tui_platform::platform::home_dir()
        .map(|home| home.join("Library/Application Support/cmux-tui/browser-host"))
}

#[cfg(not(target_os = "macos"))]
fn default_root() -> Option<PathBuf> {
    std::env::var_os("XDG_DATA_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| cmux_tui_platform::platform::home_dir().map(|home| home.join(".local/share")))
        .map(|data| data.join("cmux-tui/browser-host"))
}

/// The host executable of one installed version: a standalone app bundle on
/// macOS (the host carries its own CEF framework), a plain file elsewhere.
fn executable_in(version: &Path) -> PathBuf {
    if cfg!(target_os = "macos") {
        version.join("host.app/Contents/MacOS").join(HOST_BINARY)
    } else {
        version.join(HOST_BINARY)
    }
}

fn platform() -> String {
    format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH)
}

// MARK: Requests

#[derive(Deserialize)]
struct RuntimeRequest {
    id: Option<Value>,
    #[serde(flatten)]
    command: RuntimeCommand,
}

#[derive(Deserialize)]
#[serde(tag = "cmd")]
enum RuntimeCommand {
    #[serde(rename = "browser-runtime-status")]
    Status,
    #[serde(rename = "browser-runtime-start")]
    Start {
        #[serde(default)]
        url: Option<String>,
    },
    #[serde(rename = "browser-runtime-stop")]
    Stop { runtime: u64 },
}

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[Route] = &[Route {
    names: &[RouteName::Prefix("browser-runtime-")],
    stage: FrameStage::BrowserRuntime,
    entry: handle,
}];

/// The route's typed handler for a `browser-runtime-*` line, on the
/// connection's reader thread: the line's `cmd` named this family, so it
/// decodes the line once into its [`RuntimeCommand`] and answers it. A start
/// runs on its own thread and answers when the host listens. A line that is
/// none of the three commands is left to the `Command` parse (`None`).
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let RuntimeRequest { id, command } = crate::line_parses::parse(message).ok()?;
    let runtimes = &mux.control_clients.browser_runtimes;
    if !(mux.control_clients.is_unix(client)
        && mux.control_clients.supports_capability(client, BROWSER_RUNTIME_CAPABILITY))
    {
        return Some(fail(
            writer,
            id,
            "browser-runtime.not-enabled",
            "browser runtimes are not enabled on this connection",
        ));
    }
    match command {
        RuntimeCommand::Status => Some(status(mux, client, id, writer)),
        RuntimeCommand::Stop { runtime } => {
            let removed = {
                let mut state = runtimes.lock();
                match state.runtimes.get(&runtime) {
                    Some(found) if found.owner == client => state.runtimes.remove(&runtime),
                    _ => None,
                }
            };
            match removed {
                Some(runtime) => {
                    runtimes.stop(runtime);
                    Some(ok(writer, id, json!({"stopped": true})))
                }
                None => Some(fail(
                    writer,
                    id,
                    "browser-runtime.unknown",
                    "no such browser runtime on this connection",
                )),
            }
        }
        RuntimeCommand::Start { url } => Some(start(mux, client, id, url, writer)),
    }
}

/// A status read queued or running for `client`; its drop (the item ran,
/// or shutdown dropped it unrun) frees the slot.
struct StatusRead {
    mux: Arc<Mux>,
    client: u64,
}

impl StatusRead {
    /// A slot, or `None` past the per-connection or daemon-wide bound.
    fn take(mux: &Arc<Mux>, client: u64) -> Option<Self> {
        let mut state = mux.control_clients.browser_runtimes.lock();
        let own = state.status_reads.get(&client).copied().unwrap_or(0);
        let total: usize = state.status_reads.values().sum();
        if own >= MAX_STATUS_READS_PER_CLIENT || total >= MAX_STATUS_READS_TOTAL {
            return None;
        }
        state.status_reads.insert(client, own + 1);
        Some(Self { mux: mux.clone(), client })
    }
}

impl Drop for StatusRead {
    fn drop(&mut self) {
        let mut state = self.mux.control_clients.browser_runtimes.lock();
        if let Some(count) = state.status_reads.get_mut(&self.client) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                state.status_reads.remove(&self.client);
            }
        }
    }
}

/// `browser-runtime-status`: the install is on disk, so a work item reads
/// it and answers; the reader thread goes on to the next line. At most
/// [`MAX_STATUS_READS_PER_CLIENT`] reads per connection wait at a time.
fn status(mux: &Arc<Mux>, client: u64, id: Option<Value>, writer: &MessageWriter) -> bool {
    let Some(slot) = StatusRead::take(mux, client) else {
        return fail(writer, id, "browser-runtime.limit", "too many browser runtime status reads");
    };
    let (worker_writer, worker_id) = (writer.clone(), id.clone());
    let posted =
        mux.work.post(Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown, move || {
            let runtimes = &slot.mux.control_clients.browser_runtimes;
            let installed = runtimes.installed().map(|(version, _)| version);
            let state = runtimes.lock();
            let mut own: Vec<(u64, u16)> = state
                .runtimes
                .iter()
                .filter(|(_, runtime)| runtime.owner == client)
                .map(|(id, runtime)| (*id, runtime.port))
                .collect();
            drop(state);
            // Free the slot before the answer, so a client that waits for
            // each answer never meets the bound.
            drop(slot);
            own.sort_unstable();
            let rows: Vec<Value> =
                own.into_iter().map(|(id, port)| json!({"runtime": id, "port": port})).collect();
            ok(
                &worker_writer,
                worker_id,
                json!({"installed": installed, "platform": platform(), "runtimes": rows}),
            );
        });
    posted.is_ok() || fail(writer, id, "browser-runtime.unavailable", "the daemon is shutting down")
}

fn start(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    url: Option<String>,
    writer: &MessageWriter,
) -> bool {
    if let Some(url) = url.as_deref() {
        let web = url.len() <= MAX_URL_BYTES
            && url::Url::parse(url).is_ok_and(|parsed| matches!(parsed.scheme(), "http" | "https"));
        if !web {
            return fail(
                writer,
                id,
                "browser-runtime.bad-url",
                "the first page must be an http or https URL",
            );
        }
    }
    let runtimes = &mux.control_clients.browser_runtimes;
    {
        let mut state = runtimes.lock();
        if state.count(client) >= MAX_RUNTIMES_PER_CLIENT || state.total() >= MAX_RUNTIMES_TOTAL {
            drop(state);
            return fail(writer, id, "browser-runtime.limit", "too many browser runtimes");
        }
        *state.starting.entry(client).or_insert(0) += 1;
    }
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    // The start waits up to START_TIMEOUT for the host's first line
    // (`request_wait.rs`).
    let posted = mux.post_request_wait(move || {
        let runtimes = &worker_mux.control_clients.browser_runtimes;
        // The install is on disk: read here, not on the reader thread.
        let Some((version, executable)) = runtimes.installed() else {
            runtimes.lock().release(client);
            fail(
                &worker_writer,
                worker_id,
                "browser-runtime.not-installed",
                "the browser is not installed on this machine",
            );
            return;
        };
        let launched = launch(runtimes, client, &executable, url.as_deref());
        runtimes.lock().release(client);
        match launched {
            Ok((runtime_id, port, secret)) => {
                // The connection may have ended during the start.
                if !worker_mux.control_clients.is_unix(client) {
                    runtimes.disconnect(client);
                    return;
                }
                let reply = json!({
                    "runtime": runtime_id,
                    "port": port,
                    "secret": secret,
                    "installed": version,
                });
                ok(&worker_writer, worker_id, reply);
            }
            Err(message) => {
                fail(&worker_writer, worker_id, "browser-runtime.start-failed", &message);
            }
        }
    });
    if posted.is_err() {
        runtimes.lock().release(client);
        return fail(writer, id, "browser-runtime.start-failed", "the daemon is shutting down");
    }
    true
}

/// Starts the host, gives it the secret and waits for its port. The
/// runtime is registered before this returns.
fn launch(
    runtimes: &BrowserRuntimes,
    client: u64,
    executable: &Path,
    url: Option<&str>,
) -> Result<(u64, u16, String), String> {
    let runtime_id = runtimes.next_id.fetch_add(1, Ordering::Relaxed) + 1;
    let root = runtimes.root().ok_or("the browser has no install directory")?;
    let logs = root.join("logs");
    scoped_blocking_call(BlockingKind::Fs, || {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(&logs)
    })
    .map_err(|error| format!("cannot create {}: {error}", logs.display()))?;
    let log = logs.join(format!("runtime-{}-{runtime_id}.log", std::process::id()));
    let log_file = files::open_with(
        fs::File::options().create(true).write(true).truncate(true).mode(0o600),
        &log,
    )
    .map_err(|error| format!("cannot create {}: {error}", log.display()))?;
    // mq14-allow: the start thread spawns the host, never the reader thread.
    let mut command = Command::new(executable);
    command.args(["--serve", "--listen", "127.0.0.1:0", "--lifeline"]);
    if let Some(url) = url {
        command.arg("--url").arg(url);
    }
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(log_file))
        // Its own process group: a signal to the daemon's group does not
        // reach it, and a stop can end its helper processes with it.
        .process_group(0);
    crate::request_path::note(crate::request_path::BlockingKind::ProcessSpawn);
    let mut child =
        command.spawn().map_err(|error| format!("cannot start the browser: {error}"))?;
    let mut lifeline = child.stdin.take();
    let stdout = child.stdout.take();
    let secret = new_secret()?;
    let written = lifeline.as_mut().map(|stdin| {
        stdin.write_all(format!("{secret}\n").as_bytes()).and_then(|()| stdin.flush())
    });
    let (line_tx, line_rx) = std::sync::mpsc::sync_channel(1);
    let reader = stdout.map(|stdout| {
        supervised::spawn_at(
            "mux-browser-runtime-out",
            crate::thread_qos::ThreadType::Utility.qos(),
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                let mut reader = BufReader::new(stdout);
                let mut line = String::new();
                let read = reader.read_line(&mut line).map(|_| line);
                let _ = line_tx.send(read.ok());
                // Keep the pipe drained until the host exits.
                let _ = std::io::copy(&mut reader, &mut std::io::sink());
            },
        )
    });
    let port = match (written, reader) {
        (Some(Ok(())), Some(Ok(_))) => match waits::recv_timeout(&line_rx, START_TIMEOUT) {
            Ok(Some(line)) => listening_port(&line),
            Ok(None) | Err(_) => None,
        },
        _ => None,
    };
    let runtime = Runtime { owner: client, child, lifeline, port: port.unwrap_or(0), log };
    let Some(port) = port else {
        let tail = log_tail(&runtime.log);
        runtimes.stop(runtime);
        return Err(if tail.is_empty() {
            "the browser did not start".into()
        } else {
            format!("the browser did not start: {tail}")
        });
    };
    runtimes.lock().runtimes.insert(runtime_id, runtime);
    Ok((runtime_id, port, secret))
}

/// The port of the host's `{"listening":"127.0.0.1:PORT"}` line; only a
/// loopback address counts.
fn listening_port(line: &str) -> Option<u16> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    let address: SocketAddr = value.get("listening")?.as_str()?.parse().ok()?;
    (address.ip().is_loopback() && address.port() != 0).then_some(address.port())
}

fn new_secret() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| format!("no random source: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// The end of a host's log, on one line (a start failure's reason).
fn log_tail(log: &Path) -> String {
    let Ok(mut file) = files::open(log) else { return String::new() };
    let length = file.metadata().map(|metadata| metadata.len()).unwrap_or(0);
    let _ = file.seek(SeekFrom::Start(length.saturating_sub(LOG_TAIL_BYTES)));
    let mut bytes = Vec::new();
    let _ = file.read_to_end(&mut bytes);
    String::from_utf8_lossy(&bytes).split_whitespace().collect::<Vec<_>>().join(" ")
}

fn ok(writer: &MessageWriter, id: Option<Value>, data: Value) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
    )
}

fn fail(writer: &MessageWriter, id: Option<Value>, code: &str, message: &str) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: None,
            error: Some(message.to_string()),
            error_code: Some(code.to_string()),
            error_delivery: None,
        },
    )
}

#[cfg(test)]
#[path = "browser_runtime_tests.rs"]
mod tests;
