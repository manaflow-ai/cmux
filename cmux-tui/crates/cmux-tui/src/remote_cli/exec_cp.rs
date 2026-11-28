//! `cmux remote exec` and `cmux remote cp`: run one command on a paired
//! machine with its output streamed back, and copy one file either way.
//!
//! Both open the daemon's `/` workspace (a daemon keeps every opened root, so
//! a root per call would grow its catalog) and address remote paths relative
//! to it. The process `exec` starts has workspace lifetime: it lives while
//! this CLI's connection does, and the daemon ends it when the CLI exits.

use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::io::{self, IsTerminal, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, anyhow};
use cmux_remote::client::{SpawnedProcess, WorkspaceClient};
use cmux_remote_protocol::{
    ByteString, FileKind, FilePrecondition, FileStat, ProcessEnvironment, ProcessEvent, ProcessId,
    ProcessIo, ProcessLifetime, ProcessSignal, PtyEofPolicy, RpcEvent, WorkspaceId,
    WorkspaceRequest, WorkspaceResponse,
};
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;
use tokio::signal::unix::{SignalKind, signal};

use cmux_remote::phase_timing::mark;

use super::{
    REMOTE_VALUE_OPTIONS, credential_free_route_hint, parse_connect_flags, start_connected,
    tokio_runtime,
};
use crate::localization::catalog;

/// The daemon's per-request bound on process input (`MAX_PROCESS_WRITE_BYTES`).
const PROCESS_WRITE_BYTES: usize = 32 * 1024;
/// The daemon's per-request bound on `read-file` (`MAX_READ_BYTES`).
const READ_CHUNK_BYTES: u32 = 4 * 1024 * 1024;
/// The daemon's bound on one `write-file` (`MAX_WRITE_BYTES`).
const WRITE_FILE_BYTES: usize = 8 * 1024 * 1024;
/// The daemon refuses `read-file` on larger files (`MAX_HASH_BYTES`).
const READ_FILE_MAX_SIZE: u64 = 128 * 1024 * 1024;
/// Reads in flight at once while downloading.
const READ_WINDOW: usize = 4;
/// Part writes in flight at once while uploading.
const UPLOAD_WINDOW: usize = 2;
/// Ctrl-C presses after which `exec` stops waiting for the command.
const INTERRUPTS_BEFORE_GIVING_UP: u32 = 3;
pub(super) const EXIT_TRANSPORT: i32 = 255;
const EXIT_INTERRUPTED: i32 = 130;
const EXIT_BROKEN_PIPE: i32 = 141;
const DEFAULT_TERMINAL: (u16, u16) = (80, 24);
/// The terminal's EOF character (`VEOF`, Control-D).
const CONTROL_D: u8 = 0x04;

/// Makes a private staging directory for an upload beside its
/// destination `$1` and prints its path. `mktemp -d` creates it exclusively
/// with mode 0700, so nobody else can plant or read a part in it.
const STAGING_SCRIPT: &str = r#"set -eu
d=$(dirname -- "$1")
mkdir -p -- "$d"
umask 077
case $d in */) ;; *) d=$d/ ;; esac
mktemp -d "${d}.cmux-cp.XXXXXXXX"
"#;

/// Name prefix of the staging directory `STAGING_SCRIPT` makes.
const STAGING_PREFIX: &str = ".cmux-cp.";

/// Joins the parts in the private staging directory `$1` into `$2`: `$3` is
/// the part count, `$4` the octal mode. The joined file is created
/// exclusively (`set -C`) under umask 077, gets its mode only once complete,
/// and is renamed into place. Only the staging directory's own files are
/// removed, whatever happens.
///
/// `mv` onto a directory moves into it, and BSD `mv` (macOS) has no `-T` to
/// forbid that, so a directory at `$2` is refused before the rename. The file
/// is renamed under the staging directory's own random name first: should a
/// directory appear at `$2` between the check and the `mv`, the file lands at
/// `$2/<that name>`, which no existing file has, and is taken back out.
/// Every command here is POSIX and takes the same options on BSD and GNU.
const ASSEMBLE_SCRIPT: &str = r#"set -eu
d=$1; f=$2; n=$3; m=$4
t=$d/${d##*/}
umask 077
cleanup() { rm -f -- "$d"/part.* "$d/assembled" "$t"; rmdir -- "$d" 2>/dev/null || true; }
trap cleanup EXIT
set -C
: > "$d/assembled"
set +C
i=0
while [ "$i" -lt "$n" ]; do cat "$(printf '%s/part.%06d' "$d" "$i")" >> "$d/assembled"; i=$((i+1)); done
chmod "$m" "$d/assembled"
mv -f -- "$d/assembled" "$t"
if [ -d "$f" ]; then printf '%s: is a directory\n' "$f" >&2; exit 1; fi
mv -f -- "$t" "$f"
if [ -d "$f" ]; then rm -f -- "$f/${d##*/}"; printf '%s: is a directory\n' "$f" >&2; exit 1; fi
"#;

/// Removes the staging directory `$1` of a failed upload.
const CLEANUP_STAGING_SCRIPT: &str = r#"rm -f -- "$1"/part.*; rmdir -- "$1""#;

/// An exit status `run` returns as is, printing `error` first when present.
#[derive(Debug)]
pub(super) struct ExitWith {
    pub(super) code: i32,
    pub(super) error: Option<anyhow::Error>,
}

impl fmt::Display for ExitWith {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.error {
            Some(error) => write!(formatter, "{error:#}"),
            None => write!(formatter, "exit status {}", self.code),
        }
    }
}

impl std::error::Error for ExitWith {}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct ExecArgs {
    pub(super) connect: Vec<String>,
    pub(super) cwd: Option<String>,
    pub(super) env: BTreeMap<String, String>,
    pub(super) tty: bool,
    pub(super) timeout_seconds: Option<u64>,
    pub(super) argv: Vec<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum CopyEndpoint {
    Local(PathBuf),
    /// An absolute path on the remote machine.
    Remote(String),
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct CopyArgs {
    pub(super) connect: Vec<String>,
    pub(super) source: CopyEndpoint,
    pub(super) destination: CopyEndpoint,
    pub(super) json: bool,
}

fn take_value(args: &mut std::slice::Iter<'_, String>, option: &str) -> anyhow::Result<String> {
    args.next().cloned().ok_or_else(|| anyhow!(catalog().remote_client.option_needs_value(option)))
}

/// Splits `exec`'s argv at the first `--`: exec options and connect options
/// before it (the connect ones pass through untouched), the command after.
pub(super) fn parse_exec_args(args: &[String]) -> anyhow::Result<ExecArgs> {
    let messages = &catalog().remote_client;
    let split = args
        .iter()
        .position(|argument| argument == "--")
        .ok_or_else(|| anyhow!(messages.exec_needs_command))?;
    let (options, argv) = args.split_at(split);
    let argv = argv.get(1..).unwrap_or_default();
    if argv.is_empty() {
        return Err(anyhow!(messages.exec_needs_command));
    }
    let mut parsed = ExecArgs {
        connect: Vec::new(),
        cwd: None,
        env: BTreeMap::new(),
        tty: false,
        timeout_seconds: None,
        argv: argv.to_vec(),
    };
    let mut options = options.iter();
    while let Some(argument) = options.next() {
        match argument.as_str() {
            "--cwd" => {
                let cwd = take_value(&mut options, "--cwd")?;
                if !cwd.starts_with('/') {
                    return Err(anyhow!(messages.exec_cwd_absolute));
                }
                if parsed.cwd.replace(cwd).is_some() {
                    return Err(anyhow!(messages.option_once("--cwd")));
                }
            }
            "--env" => {
                let pair = take_value(&mut options, "--env")?;
                let (key, value) = pair
                    .split_once('=')
                    .filter(|(key, _)| !key.is_empty())
                    .ok_or_else(|| anyhow!(messages.invalid_option_value("--env", "KEY=VALUE")))?;
                parsed.env.insert(key.to_owned(), value.to_owned());
            }
            "--tty" | "-t" => parsed.tty = true,
            "--timeout-seconds" => {
                let seconds = take_value(&mut options, "--timeout-seconds")?
                    .parse::<u64>()
                    .ok()
                    .filter(|seconds| *seconds > 0)
                    .ok_or_else(|| {
                        anyhow!(messages.option_must_be_positive("--timeout-seconds"))
                    })?;
                parsed.timeout_seconds = Some(seconds);
            }
            option if REMOTE_VALUE_OPTIONS.contains(&option) => {
                let value = take_value(&mut options, option)?;
                parsed.connect.extend([option.to_owned(), value]);
            }
            other => parsed.connect.push(other.to_owned()),
        }
    }
    Ok(parsed)
}

/// `remote:PATH` names a remote path; anything else is local. `None` for a
/// local path, the absolute remote path otherwise.
pub(super) fn parse_remote_path(argument: &str) -> Option<anyhow::Result<String>> {
    let path = argument.strip_prefix("remote:")?;
    Some(if path.starts_with('/') {
        Ok(path.to_owned())
    } else {
        Err(anyhow!(catalog().remote_client.cp_remote_absolute(path)))
    })
}

/// `[ROUTE] [OPTIONS] SRC DST`; after a `--`, every word is positional.
pub(super) fn parse_cp_args(args: &[String]) -> anyhow::Result<CopyArgs> {
    let messages = &catalog().remote_client;
    let mut connect = Vec::new();
    let mut positionals = Vec::new();
    let mut json = false;
    let mut args = args.iter();
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--" => {
                positionals.extend(args.by_ref().cloned());
                break;
            }
            "--json" => json = true,
            option if REMOTE_VALUE_OPTIONS.contains(&option) => {
                let value = take_value(&mut args, option)?;
                connect.extend([option.to_owned(), value]);
            }
            option if option.starts_with('-') => connect.push(option.to_owned()),
            positional => positionals.push(positional.to_owned()),
        }
    }
    let (source, destination) = match positionals.as_slice() {
        [route, source, destination] => {
            connect.push(route.clone());
            (source, destination)
        }
        [source, destination] => (source, destination),
        _ => return Err(anyhow!(messages.cp_usage)),
    };
    let endpoint = |argument: &str| -> anyhow::Result<CopyEndpoint> {
        match parse_remote_path(argument) {
            Some(path) => path.map(CopyEndpoint::Remote),
            None => Ok(CopyEndpoint::Local(PathBuf::from(argument))),
        }
    };
    let (source, destination) = (endpoint(source)?, endpoint(destination)?);
    if matches!(source, CopyEndpoint::Remote(_)) == matches!(destination, CopyEndpoint::Remote(_)) {
        return Err(anyhow!(messages.cp_one_remote));
    }
    Ok(CopyArgs { connect, source, destination, json })
}

/// The status `exec` exits with for a remote exit: the code, 128+N for
/// signal N, 255 when neither is known or the code does not fit.
pub(super) fn exit_status_code(code: Option<i32>, signal: Option<i32>) -> i32 {
    match (code, signal) {
        (Some(code), _) if (0..=255).contains(&code) => code,
        (None, Some(signal)) if (1..=127).contains(&signal) => 128 + signal,
        _ => EXIT_TRANSPORT,
    }
}

/// A remote absolute path relative to the `/` workspace.
pub(super) fn workspace_relative(path: &str) -> String {
    path.trim_start_matches('/').to_owned()
}

fn unexpected(request: &str) -> anyhow::Error {
    anyhow!(catalog().remote_client.remote_unexpected_response(request))
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

pub(super) async fn open_root(client: &WorkspaceClient) -> anyhow::Result<WorkspaceId> {
    match client.request(WorkspaceRequest::OpenWorkspace { root: "/".into() }).await? {
        WorkspaceResponse::Workspace { id, .. } => Ok(id),
        _ => Err(unexpected("open-workspace")),
    }
}

async fn remote_stat(
    client: &WorkspaceClient,
    workspace: &WorkspaceId,
    path: &str,
    host: &str,
) -> anyhow::Result<FileStat> {
    let request = WorkspaceRequest::Stat {
        workspace: workspace.clone(),
        path: workspace_relative(path),
        follow_symlinks: true,
    };
    match client.request(request).await {
        Ok(WorkspaceResponse::Stat { stat }) => Ok(stat),
        Ok(_) => Err(unexpected("stat")),
        Err(error) => Err(remote_path_error(error, host, path)),
    }
}

/// A daemon refusal about remote `path`, said as which side and which file:
/// `not-found` becomes "remote file not found on HOST: PATH" instead of the
/// daemon's own "resolve RELATIVE: os error 2".
pub(super) fn remote_path_error(
    error: cmux_remote_protocol::RpcError,
    host: &str,
    path: &str,
) -> anyhow::Error {
    if error.code == "not-found" {
        return anyhow!(catalog().remote_client.cp_remote_not_found(host, path));
    }
    error.into()
}

/// The machine a route names, for messages: its host when it has one
/// (`ssh://leo@box:22` is `box`), else the route without credentials.
pub(super) fn route_host(route: &str) -> String {
    match url::Url::parse(route) {
        Ok(url) => match url.host_str() {
            Some(host) if !host.is_empty() => host.to_owned(),
            _ => credential_free_route_hint(route).unwrap_or_else(|_| url.scheme().to_owned()),
        },
        Err(_) => catalog().remote_client.cp_remote_machine.to_owned(),
    }
}

/// The local source's metadata; a missing file says it is the local side.
pub(super) fn local_source_metadata(local: &Path) -> anyhow::Result<std::fs::Metadata> {
    let name = local.display().to_string();
    std::fs::metadata(local).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            anyhow!(catalog().remote_client.cp_local_not_found(&name))
        } else {
            anyhow::Error::new(error).context(format!("could not read {name}"))
        }
    })
}

// ---------------------------------------------------------------- exec

pub(super) fn run_exec(args: &[String]) -> anyhow::Result<()> {
    match exec(args) {
        Ok(0) => Ok(()),
        Ok(code) => Err(ExitWith { code, error: None }.into()),
        Err(error) => Err(ExitWith { code: EXIT_TRANSPORT, error: Some(error) }.into()),
    }
}

fn exec(args: &[String]) -> anyhow::Result<i32> {
    let parsed = parse_exec_args(args)?;
    let flags = parse_connect_flags(&parsed.connect)?;
    let connected = start_connected(flags)?;
    mark("connected");
    let runtime = tokio_runtime()?;
    let result = runtime.block_on(async {
        let client = WorkspaceClient::connect(connected.runtime.multiplexer().clone()).await?;
        mark("workspace-client");
        exec_on(client, parsed, None).await
    });
    mark("exited");
    // The command's status is the answer; a slow or failed teardown after it
    // does not change what the command did.
    let _ = connected.runtime.shutdown();
    mark("shutdown");
    result
}

fn local_terminal_size() -> (u16, u16) {
    if !io::stdout().is_terminal() {
        return DEFAULT_TERMINAL;
    }
    crossterm::terminal::size()
        .ok()
        .filter(|(cols, rows)| *cols > 0 && *rows > 0)
        .unwrap_or(DEFAULT_TERMINAL)
}

/// Puts the local terminal in raw mode for `--tty` and restores it on drop.
struct RawMode;

impl RawMode {
    fn enter() -> Option<Self> {
        (io::stdin().is_terminal() && crossterm::terminal::enable_raw_mode().is_ok())
            .then_some(Self)
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        let _ = crossterm::terminal::disable_raw_mode();
    }
}

/// Runs `parsed` on `client`'s machine with its output streamed here.
/// `first_output` (`cmux spill --timings`) is set when the first byte of
/// stdout or stderr arrives.
pub(super) async fn exec_on(
    client: Arc<WorkspaceClient>,
    parsed: ExecArgs,
    first_output: Option<&std::sync::OnceLock<Instant>>,
) -> anyhow::Result<i32> {
    let workspace = open_root(&client).await?;
    mark("root-open");
    let io = if parsed.tty {
        let (cols, rows) = local_terminal_size();
        ProcessIo::Pty {
            cols,
            rows,
            term: std::env::var("TERM")
                .ok()
                .filter(|term| !term.is_empty())
                .unwrap_or_else(|| "xterm-256color".into()),
            eof: PtyEofPolicy::ControlD,
        }
    } else {
        ProcessIo::Pipes { stdin: true }
    };
    let cwd = parsed.cwd.as_deref().map(workspace_relative).filter(|cwd| !cwd.is_empty());
    let process = client.allocate_process_handle();
    let request = WorkspaceRequest::SpawnProcess {
        workspace,
        argv: parsed.argv,
        cwd,
        env: parsed.env,
        io,
        lifetime: ProcessLifetime::Workspace,
        operation: None,
        timeout_ms: parsed.timeout_seconds.map(|seconds| seconds.saturating_mul(1000)),
        retained_output_bytes: None,
        environment: ProcessEnvironment::Inherit,
    };
    let spawned = client.spawn_process_with_events(process, request).await?;
    mark("spawned");
    let _raw = if parsed.tty { RawMode::enter() } else { None };
    // Input runs beside the output loop in this future (no task to own): the
    // command's status ends both, and an input side that finished waits.
    let input = async {
        forward_stdin(&client, process, parsed.tty).await;
        std::future::pending::<anyhow::Result<i32>>().await
    };
    tokio::select! {
        status = stream_process(&client, spawned, parsed.tty, first_output) => status,
        status = input => status,
    }
}

pub(super) enum StdinChunk {
    Data(Vec<u8>),
    End,
}

/// Reads local stdin on a thread (stdin has no portable async read) and
/// hands chunks no larger than one process write to `forward_stdin`.
fn spawn_stdin_reader() -> anyhow::Result<tokio::sync::mpsc::Receiver<StdinChunk>> {
    let (sender, receiver) = tokio::sync::mpsc::channel(4);
    thread::Builder::new()
        .name("cmux-exec-stdin".into())
        .spawn(move || {
            let stdin = io::stdin();
            let mut stdin = stdin.lock();
            let mut buffer = vec![0_u8; PROCESS_WRITE_BYTES];
            loop {
                let chunk = match stdin.read(&mut buffer) {
                    Ok(0) | Err(_) => StdinChunk::End,
                    Ok(read) => StdinChunk::Data(buffer.get(..read).unwrap_or_default().to_vec()),
                };
                let end = matches!(chunk, StdinChunk::End);
                if sender.blocking_send(chunk).is_err() || end {
                    break;
                }
            }
        })
        .context("could not start the stdin reader")?;
    Ok(receiver)
}

/// How many stdin writes may be unacknowledged at once: 16 writes of
/// PROCESS_WRITE_BYTES, 512 KiB in flight. One write per round trip moved
/// 27 KiB per RTT (0.26 MiB/s at 100 ms; cmuxterm-hq#34078) while stdout
/// streams. The daemon still applies writes one at a time in receive order on
/// the process-input stream and blocks on a full pipe, so the window bounds
/// buffering without reordering input.
const STDIN_WRITES_IN_FLIGHT: usize = 16;

/// A write's acknowledgement: true when the daemon accepted it.
type StdinAck<'a> = std::pin::Pin<Box<dyn std::future::Future<Output = bool> + 'a>>;

/// Sends local stdin to the process in order, with up to
/// STDIN_WRITES_IN_FLIGHT writes unacknowledged, and EOF at local EOF. It runs
/// beside the output loop so a command blocked on a full stdout can never
/// stall its own input. A write the daemon refuses (the command closed stdin
/// or exited) stops forwarding.
///
/// On a PTY, EOF is the daemon's one Control-D, which ends input only at the
/// start of a line: after an unterminated line it just hands that line to
/// the reader. So when the last byte sent was not a newline, an extra
/// Control-D goes first to release the line (`printf foo | ... --tty -- cat`).
async fn forward_stdin(client: &WorkspaceClient, process: ProcessId, tty: bool) {
    let Ok(input) = spawn_stdin_reader() else { return };
    forward_stdin_chunks(input, tty, STDIN_WRITES_IN_FLIGHT, |write_id, data, eof| {
        let request = WorkspaceRequest::WriteProcess {
            process,
            write_id,
            data: ByteString::from_bytes(&data),
            eof,
        };
        Box::pin(async move {
            let pending = client.begin_request(request).await.ok()?;
            Some(Box::pin(async move { pending.receive().await.is_ok() }) as StdinAck<'_>)
        })
    })
    .await;
}

/// The order and window of [`forward_stdin`]: `send` starts write `write_id`
/// (None when it could not be sent) and returns its acknowledgement. Returns
/// once EOF is acknowledged or a write fails.
pub(super) async fn forward_stdin_chunks<'a, S>(
    mut input: tokio::sync::mpsc::Receiver<StdinChunk>,
    tty: bool,
    window: usize,
    mut send: S,
) where
    S: FnMut(
        u64,
        Vec<u8>,
        bool,
    )
        -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<StdinAck<'a>>> + 'a>>,
{
    let window = window.max(1);
    let mut in_flight: VecDeque<StdinAck<'a>> = VecDeque::new();
    let mut write_id = 0_u64;
    let mut last_sent = None;
    loop {
        let next = if in_flight.len() >= window {
            None
        } else {
            tokio::select! {
                biased;
                accepted = async {
                    match in_flight.front_mut() {
                        Some(oldest) => oldest.await,
                        None => std::future::pending().await,
                    }
                }, if !in_flight.is_empty() => {
                    in_flight.pop_front();
                    if !accepted {
                        return;
                    }
                    continue;
                }
                chunk = input.recv() => Some(chunk),
            }
        };
        let Some(chunk) = next else {
            let Some(oldest) = in_flight.pop_front() else { continue };
            if !oldest.await {
                return;
            }
            continue;
        };
        let (data, eof) = match chunk {
            Some(StdinChunk::Data(data)) => (data, false),
            Some(StdinChunk::End) | None if tty && pty_line_open(last_sent) => {
                (vec![CONTROL_D], false)
            }
            Some(StdinChunk::End) | None => (Vec::new(), true),
        };
        if let Some(last) = data.last() {
            last_sent = Some(*last);
        }
        write_id += 1;
        let Some(ack) = send(write_id, data, eof).await else { return };
        in_flight.push_back(ack);
        if eof {
            while let Some(ack) = in_flight.pop_front() {
                if !ack.await {
                    return;
                }
            }
            return;
        }
    }
}

/// Whether a PTY's line is unterminated after `last_sent`, the last input byte
/// written: a Control-D there releases the line instead of ending input.
pub(super) fn pty_line_open(last_sent: Option<u8>) -> bool {
    last_sent.is_some_and(|byte| byte != b'\n' && byte != CONTROL_D)
}

fn write_output(output: &mut impl Write, data: &ByteString) -> anyhow::Result<()> {
    let bytes = data.decode().map_err(|_| unexpected("process output"))?;
    output.write_all(&bytes)?;
    output.flush()?;
    Ok(())
}

async fn stream_process(
    client: &WorkspaceClient,
    spawned: SpawnedProcess,
    tty: bool,
    first_output: Option<&std::sync::OnceLock<Instant>>,
) -> anyhow::Result<i32> {
    let process = spawned.process;
    let mut interrupt = signal(SignalKind::interrupt())?;
    let mut resize = signal(SignalKind::window_change())?;
    let mut interrupts = 0;
    let mut lost = false;
    let stdout = io::stdout();
    let stderr = io::stderr();
    loop {
        tokio::select! {
            event = spawned.events.receive() => {
                let event = match event? {
                    Some(RpcEvent { event, .. }) => event,
                    None => return final_status(wait_exit(client, process).await?, lost),
                };
                if let (Some(first), ProcessEvent::Stdout { .. } | ProcessEvent::Stderr { .. }) =
                    (first_output, &event)
                {
                    let _ = first.set(Instant::now());
                }
                let written = match &event {
                    ProcessEvent::Stdout { data, .. } => write_output(&mut stdout.lock(), data),
                    ProcessEvent::Stderr { data, .. } => write_output(&mut stderr.lock(), data),
                    ProcessEvent::OutputTruncated { reason, .. } => {
                        lost = true;
                        eprintln!(
                            "{}",
                            catalog().remote_client.exec_output_truncated(&format!("{reason:?}"))
                        );
                        Ok(())
                    }
                    ProcessEvent::ReplayGap { .. } => {
                        return final_status(wait_exit(client, process).await?, true);
                    }
                    ProcessEvent::Exit { code, signal, .. } => {
                        return final_status(exit_status_code(*code, *signal), lost);
                    }
                };
                if let Err(error) = written {
                    if error
                        .downcast_ref::<io::Error>()
                        .is_some_and(|error| error.kind() == io::ErrorKind::BrokenPipe)
                    {
                        // The reader went away (`| head`): end the command the
                        // way a local pipeline would.
                        return Ok(EXIT_BROKEN_PIPE);
                    }
                    return Err(error);
                }
            }
            _ = interrupt.recv() => {
                interrupts += 1;
                if interrupts >= INTERRUPTS_BEFORE_GIVING_UP {
                    return Ok(EXIT_INTERRUPTED);
                }
                let _ = client
                    .request(WorkspaceRequest::SignalProcess {
                        process,
                        signal: ProcessSignal::Interrupt,
                    })
                    .await;
            }
            _ = resize.recv(), if tty => {
                let (cols, rows) = local_terminal_size();
                let _ = client
                    .request(WorkspaceRequest::ResizeProcess { process, cols, rows })
                    .await;
            }
        }
    }
}

/// The status `exec` exits with once the command ended. `lost` says some of
/// its output never arrived (truncated by the daemon, or a replay gap).
pub(super) fn final_status(status: i32, lost: bool) -> anyhow::Result<i32> {
    if lost {
        // The caller saw an incomplete stream: never let it pass for the
        // command's own result, even a success.
        return Err(anyhow!(catalog().remote_client.exec_output_lost));
    }
    Ok(status)
}

async fn wait_exit(client: &WorkspaceClient, process: ProcessId) -> anyhow::Result<i32> {
    match client.request(WorkspaceRequest::WaitProcess { process }).await? {
        WorkspaceResponse::ProcessExit { code, signal, .. } => Ok(exit_status_code(code, signal)),
        _ => Err(unexpected("wait-process")),
    }
}

/// Runs a short helper command (stdin closed) to completion and returns its
/// status and stderr. Stdout is dropped, or written to `stdout` when given.
pub(super) async fn run_remote(
    client: &WorkspaceClient,
    workspace: &WorkspaceId,
    argv: Vec<String>,
    mut stdout: Option<&mut dyn Write>,
) -> anyhow::Result<(i32, String)> {
    let process = client.allocate_process_handle();
    let request = WorkspaceRequest::SpawnProcess {
        workspace: workspace.clone(),
        argv,
        cwd: None,
        env: BTreeMap::new(),
        io: ProcessIo::Pipes { stdin: false },
        lifetime: ProcessLifetime::Workspace,
        operation: None,
        timeout_ms: None,
        retained_output_bytes: None,
        environment: ProcessEnvironment::Inherit,
    };
    let spawned = client.spawn_process_with_events(process, request).await?;
    let mut stderr = Vec::new();
    loop {
        let Some(RpcEvent { event, .. }) = spawned.events.receive().await? else {
            return Ok((
                wait_exit(client, process).await?,
                String::from_utf8_lossy(&stderr).into(),
            ));
        };
        match event {
            ProcessEvent::Stdout { data, .. } => {
                if let Some(output) = stdout.as_deref_mut() {
                    output.write_all(&data.decode().map_err(|_| unexpected("process output"))?)?;
                }
            }
            ProcessEvent::Stderr { data, .. } => {
                if stderr.len() < 64 * 1024 {
                    stderr.extend(data.decode().unwrap_or_default());
                }
            }
            ProcessEvent::OutputTruncated { .. } | ProcessEvent::ReplayGap { .. } => {
                return Err(anyhow!(catalog().remote_client.exec_output_lost));
            }
            ProcessEvent::Exit { code, signal, .. } => {
                return Ok((
                    exit_status_code(code, signal),
                    String::from_utf8_lossy(&stderr).into(),
                ));
            }
        }
    }
}

fn check_step(step: &str, (status, stderr): (i32, String)) -> anyhow::Result<()> {
    if status == 0 {
        return Ok(());
    }
    Err(anyhow!(catalog().remote_client.cp_remote_step_failed(step, status, stderr.trim())))
}

// ------------------------------------------------------------------ cp

pub(super) fn run_cp(args: &[String]) -> anyhow::Result<()> {
    let parsed = parse_cp_args(args)?;
    let mut flags = parse_connect_flags(&parsed.connect)?;
    // A refusal that ends the connect is a JSON line too.
    flags.json |= parsed.json;
    let connected = start_connected(flags)?;
    let runtime = tokio_runtime()?;
    let result = runtime.block_on(async {
        let client = WorkspaceClient::connect(connected.runtime.multiplexer().clone()).await?;
        let workspace = open_root(&client).await?;
        let host = route_host(&connected.route);
        let started = Instant::now();
        let bytes = match (&parsed.source, &parsed.destination) {
            (CopyEndpoint::Remote(remote), CopyEndpoint::Local(local)) => {
                download(&client, &workspace, remote, local, &host).await?
            }
            (CopyEndpoint::Local(local), CopyEndpoint::Remote(remote)) => {
                upload(&client, &workspace, local, remote, &host).await?
            }
            _ => return Err(anyhow!(catalog().remote_client.cp_one_remote)),
        };
        Ok::<_, anyhow::Error>((bytes, started.elapsed()))
    });
    let shutdown = connected.runtime.shutdown();
    let (bytes, elapsed) = result?;
    shutdown?;
    if parsed.json {
        println!("{}", transfer_report(bytes, elapsed));
    }
    Ok(())
}

pub(super) fn transfer_report(bytes: u64, elapsed: Duration) -> serde_json::Value {
    let seconds = elapsed.as_secs_f64();
    let mib = bytes as f64 / (1024.0 * 1024.0);
    let rate = if seconds > 0.0 { mib / seconds } else { 0.0 };
    serde_json::json!({
        "bytes": bytes,
        "seconds": (seconds * 1000.0).round() / 1000.0,
        "mib_per_s": (rate * 100.0).round() / 100.0,
    })
}

/// The local mode of a downloaded file. A new file is 0600 (0700 when the
/// remote file is executable) less the umask; a replaced file (`existing`)
/// keeps its own mode, narrowed to that. A download never widens access.
pub(super) fn download_mode(executable: bool, umask: u32, existing: Option<u32>) -> u32 {
    let source = if executable { 0o700 } else { 0o600 };
    let allowed = source & !umask & 0o777;
    match existing {
        Some(mode) => mode & 0o777 & allowed,
        None => allowed,
    }
}

/// This process's file-creation mask.
// `mode_t` is u32 on Linux and u16 on macOS: the conversion is a no-op only here.
#[allow(clippy::useless_conversion)]
fn current_umask() -> u32 {
    // SAFETY: umask only swaps the process mask; it is put back at once, and
    // `cp` runs no other thread that creates files meanwhile.
    let mask = unsafe { libc::umask(0o077) };
    // SAFETY: as above, restoring the mask read on the previous line.
    unsafe { libc::umask(mask) };
    u32::from(mask) & 0o777
}

fn file_name_of(path: &str) -> &str {
    path.trim_end_matches('/').rsplit('/').next().unwrap_or(path)
}

async fn download(
    client: &WorkspaceClient,
    workspace: &WorkspaceId,
    remote: &str,
    local: &Path,
    host: &str,
) -> anyhow::Result<u64> {
    let messages = &catalog().remote_client;
    let stat = remote_stat(client, workspace, remote, host).await?;
    match stat.kind {
        FileKind::File => {}
        FileKind::Directory => return Err(anyhow!(messages.cp_directory(remote))),
        _ => return Err(anyhow!(messages.cp_not_a_file(remote))),
    }
    let target =
        if local.is_dir() { local.join(file_name_of(remote)) } else { local.to_path_buf() };
    let parent = match target.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
        _ => PathBuf::from("."),
    };
    let mut temporary = tempfile::Builder::new()
        .prefix(".cmux-cp-")
        .suffix(".part")
        .tempfile_in(&parent)
        .with_context(|| format!("could not create a temporary file in {}", parent.display()))?;
    let bytes = if stat.size > READ_FILE_MAX_SIZE {
        let argv = vec!["cat".into(), "--".into(), remote.to_owned()];
        check_step(
            "cat",
            run_remote(client, workspace, argv, Some(temporary.as_file_mut() as &mut dyn Write))
                .await?,
        )?;
        temporary.as_file().metadata()?.len()
    } else {
        read_file_chunks(client, workspace, remote, stat.size, temporary.as_file_mut()).await?
    };
    let existing = std::fs::metadata(&target).ok().map(|metadata| metadata.permissions().mode());
    let mode = download_mode(stat.executable, current_umask(), existing);
    temporary.as_file().set_permissions(std::fs::Permissions::from_mode(mode))?;
    temporary.as_file().sync_all()?;
    temporary.persist(&target).with_context(|| format!("could not write {}", target.display()))?;
    Ok(bytes)
}

/// Reads the whole file with up to `READ_WINDOW` reads in flight, writes it
/// in order and checks it against the daemon's SHA-256 of the file.
async fn read_file_chunks(
    client: &WorkspaceClient,
    workspace: &WorkspaceId,
    remote: &str,
    size: u64,
    file: &mut std::fs::File,
) -> anyhow::Result<u64> {
    let path = workspace_relative(remote);
    let chunk = u64::from(READ_CHUNK_BYTES);
    let mut pending = VecDeque::new();
    let mut next = 0_u64;
    let mut written = 0_u64;
    let mut hasher = Sha256::new();
    let mut expected_hash = None;
    loop {
        while pending.len() < READ_WINDOW && (next < size || pending.is_empty()) {
            let request = WorkspaceRequest::ReadFile {
                workspace: workspace.clone(),
                path: path.clone(),
                offset: next,
                limit: READ_CHUNK_BYTES,
            };
            pending.push_back((next, client.begin_request(request).await?));
            next += chunk;
        }
        let Some((offset, request)) = pending.pop_front() else { break };
        let WorkspaceResponse::File { data, offset: answered, eof, content_hash } =
            request.receive().await?
        else {
            return Err(unexpected("read-file"));
        };
        let bytes = data.decode().map_err(|_| unexpected("read-file"))?;
        if answered != offset || (!eof && bytes.len() as u64 != chunk) {
            return Err(unexpected("read-file"));
        }
        if expected_hash.get_or_insert_with(|| content_hash.clone()) != &content_hash {
            return Err(anyhow!(catalog().remote_client.cp_hash_mismatch(remote)));
        }
        hasher.update(&bytes);
        file.write_all(&bytes)?;
        written += bytes.len() as u64;
        if eof {
            break;
        }
    }
    let actual: String = hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    if expected_hash.is_some_and(|expected| expected != actual) {
        return Err(anyhow!(catalog().remote_client.cp_hash_mismatch(remote)));
    }
    Ok(written)
}

async fn upload(
    client: &WorkspaceClient,
    workspace: &WorkspaceId,
    local: &Path,
    remote: &str,
    host: &str,
) -> anyhow::Result<u64> {
    let messages = &catalog().remote_client;
    let local_name = local.display().to_string();
    let metadata = local_source_metadata(local)?;
    if metadata.is_dir() {
        return Err(anyhow!(messages.cp_directory(&local_name)));
    }
    if !metadata.is_file() {
        return Err(anyhow!(messages.cp_not_a_file(&local_name)));
    }
    let into_directory = remote.ends_with('/')
        || remote_stat(client, workspace, remote, host)
            .await
            .is_ok_and(|stat| stat.kind == FileKind::Directory);
    let remote = if into_directory {
        let name = local.file_name().map(|name| name.to_string_lossy().into_owned());
        let name = name.ok_or_else(|| anyhow!(messages.cp_not_a_file(&local_name)))?;
        format!("{}/{name}", remote.trim_end_matches('/'))
    } else {
        remote.to_owned()
    };
    // Give the copy the local file's permission bits, as scp does. Every
    // upload, a small one too, is joined in private staging and gets its mode
    // there, before it is renamed into place: writing the destination first
    // and `chmod` after would show a private file with the old file's mode
    // until then (and for good if the connection drops in between).
    let mode = format!("{:o}", metadata.permissions().mode() & 0o777);
    let size = metadata.len();
    let staging = make_staging(client, workspace, &remote).await?;
    let parts = match upload_parts(client, workspace, local, &staging, &remote).await {
        Ok(parts) => parts,
        Err(error) => {
            let argv = vec![
                "/bin/sh".into(),
                "-c".into(),
                CLEANUP_STAGING_SCRIPT.into(),
                "sh".into(),
                staging.clone(),
            ];
            let _ = run_remote(client, workspace, argv, None).await;
            return Err(error);
        }
    };
    let argv = assemble_argv(&staging, &remote, parts, &mode);
    check_step("/bin/sh", run_remote(client, workspace, argv, None).await?)?;
    Ok(size)
}

/// Creates the private staging directory for an upload to `remote`.
async fn make_staging(
    client: &WorkspaceClient,
    workspace: &WorkspaceId,
    remote: &str,
) -> anyhow::Result<String> {
    let argv =
        vec!["/bin/sh".into(), "-c".into(), STAGING_SCRIPT.into(), "sh".into(), remote.to_owned()];
    let mut output = Vec::new();
    check_step(
        "mktemp",
        run_remote(client, workspace, argv, Some(&mut output as &mut dyn Write)).await?,
    )?;
    let staging = String::from_utf8_lossy(&output).trim_end_matches('\n').to_owned();
    let name = staging.rsplit('/').next().unwrap_or_default();
    if !staging.starts_with('/') || !name.starts_with(STAGING_PREFIX) || staging.contains('\n') {
        return Err(unexpected("mktemp"));
    }
    Ok(staging)
}

/// Where part `index` of an upload goes, in its staging directory.
pub(super) fn upload_part_path(staging: &str, remote: &str, index: u64) -> String {
    let _ = remote;
    format!("{staging}/part.{index:06}")
}

/// The remote command that joins `parts` parts in `staging` into `remote`
/// with mode `mode` (octal).
pub(super) fn assemble_argv(staging: &str, remote: &str, parts: u64, mode: &str) -> Vec<String> {
    vec![
        "/bin/sh".into(),
        "-c".into(),
        ASSEMBLE_SCRIPT.into(),
        "sh".into(),
        staging.to_owned(),
        remote.to_owned(),
        parts.to_string(),
        mode.to_owned(),
    ]
}

/// Writes the file as 8 MiB parts into `staging`, each a new file
/// (`Missing`: never an existing one), `UPLOAD_WINDOW` writes in flight,
/// each checked against its own SHA-256. Returns the part count.
async fn upload_parts(
    client: &WorkspaceClient,
    workspace: &WorkspaceId,
    local: &Path,
    staging: &str,
    remote: &str,
) -> anyhow::Result<u64> {
    let mut file = tokio::fs::File::open(local).await?;
    let mut pending = VecDeque::new();
    let mut index = 0_u64;
    let mut done = false;
    loop {
        while !done && pending.len() < UPLOAD_WINDOW {
            let mut buffer = Vec::with_capacity(WRITE_FILE_BYTES);
            (&mut file).take(WRITE_FILE_BYTES as u64).read_to_end(&mut buffer).await?;
            if buffer.is_empty() {
                done = true;
                break;
            }
            done = buffer.len() < WRITE_FILE_BYTES;
            let path = upload_part_path(staging, remote, index);
            let request = WorkspaceRequest::WriteFile {
                workspace: workspace.clone(),
                path: workspace_relative(&path),
                data: ByteString::from_bytes(&buffer),
                precondition: FilePrecondition::Missing,
                create_parents: false,
            };
            pending.push_back((path, sha256_hex(&buffer), client.begin_request(request).await?));
            index += 1;
        }
        let Some((path, expected, request)) = pending.pop_front() else { break };
        let WorkspaceResponse::Written { content_hash, .. } = request.receive().await? else {
            return Err(unexpected("write-file"));
        };
        if content_hash != expected {
            return Err(anyhow!(catalog().remote_client.cp_hash_mismatch(&path)));
        }
    }
    Ok(index)
}

#[cfg(test)]
#[path = "exec_cp_stdin_tests.rs"]
mod stdin_tests;
