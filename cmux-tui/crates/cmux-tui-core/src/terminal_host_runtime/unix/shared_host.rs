//! Shared terminal hosts: one host process runs many terminals.
//!
//! A one-terminal host (`__terminal-host --bootstrap-stdio`) costs a
//! process per terminal: about 7 MB of resident memory and its own
//! threads, signal guard and binary mapping. With
//! `CMUX_TUI_SHARED_TERMINAL_HOSTS=1` the daemon instead starts
//! `__terminal-host --shared-host --capacity N` and hands it each new
//! terminal as a bootstrap socket (`SCM_RIGHTS` over the host's control
//! socket, its stdin). On that socket the host runs the exact private-pipe
//! handshake of a one-terminal host (`Bootstrap`, `Ready`, `Launch`,
//! `Ready`), so the daemon's launch code does not change. Each terminal
//! keeps everything that makes it a CMTH v4 host: its own endpoint, owner
//! token, discovery record, liveness lease, PTY lock, exit sidecar, signal
//! breadcrumbs and PTY custody. The record's `host_pid` is the shared
//! process; nothing in the protocol or the record says "shared", so every
//! daemon build that adopts a one-terminal host adopts these terminals.
//!
//! Lifetime: the control socket belongs to the daemon that started the
//! host. When that daemon ends (SIGTERM, crash, upgrade), the host takes no
//! new terminal, keeps serving the ones it runs (the next daemon adopts
//! them through their records like any host), and exits after the last one
//! ends. The next daemon starts its own shared host for new terminals, so a
//! machine runs one shared host per daemon generation that still has live
//! terminals, each of the build that started it.
//!
//! Blast radius: a crash of the shared process ends all of its terminals'
//! hosts at once, not one. The daemon holds PTY custody of every terminal it
//! serves, so while it runs the shells survive (it starts a one-terminal
//! replacement host on each held master); a crash while no daemon runs
//! loses up to `capacity` shells. The capacity bounds that loss and the
//! process's thread count.
//!
//! The control protocol is private to one daemon and the host it started
//! (same build): a request is 20 bytes, `op:u8, reserved:[u8;3]=0,
//! terminal_id:[u8;16]`, a reply 8 bytes, `op:u8, reserved:[u8;3]=0,
//! count:u32` (terminals the host runs).
//!
//! | Request | Descriptor | Reply |
//! | --- | --- | --- |
//! | `T` new terminal | the host end of a bootstrap socket | `A` accepted, `F` full |
//! | `C` count | none | `C` |
//! | `K` end an uncommitted launch of `terminal_id` | none | none |

use std::collections::HashSet;
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::{Condvar, Mutex, OnceLock, PoisonError, Weak};
use std::time::Instant;

use super::super::shared::host_shared::HostShared;
use super::pty_custody::{receive_with_descriptor, send_with_descriptor};
use super::*;

/// The host argument that selects a shared host.
pub(crate) const SHARED_HOST_FLAG: &str = "--shared-host";
const CAPACITY_FLAG: &str = "--capacity";
/// The daemon's switch; any other value than `1` keeps one host per
/// terminal.
pub(crate) const SHARED_HOSTS_ENV: &str = "CMUX_TUI_SHARED_TERMINAL_HOSTS";
/// Terminals per shared host process.
pub(crate) const SHARED_HOST_CAPACITY_ENV: &str = "CMUX_TUI_SHARED_TERMINAL_HOST_CAPACITY";
const DEFAULT_CAPACITY: u32 = 64;
/// macOS allows 4,096 threads per process; a terminal uses about seven.
const MAX_CAPACITY: u32 = 256;
const REQUEST_LEN: usize = 20;
const REPLY_LEN: usize = 8;
const OP_TERMINAL: u8 = b'T';
const OP_COUNT: u8 = b'C';
const OP_KILL: u8 = b'K';
const REPLY_ACCEPTED: u8 = b'A';
const REPLY_FULL: u8 = b'F';
/// How long the daemon waits for a control reply before it treats the
/// host as gone for new terminals.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(2);

/// Whether this daemon starts terminals on shared hosts.
pub(crate) fn enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var(SHARED_HOSTS_ENV).is_ok_and(|value| value == "1"))
}

fn configured_capacity() -> u32 {
    std::env::var(SHARED_HOST_CAPACITY_ENV)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .unwrap_or(DEFAULT_CAPACITY)
        .clamp(1, MAX_CAPACITY)
}

pub(crate) fn is_shared_host(args: &[String]) -> bool {
    args.iter().any(|arg| arg == SHARED_HOST_FLAG)
}

fn request(op: u8, terminal: Option<&TerminalId>) -> [u8; REQUEST_LEN] {
    let mut bytes = [0u8; REQUEST_LEN];
    bytes[0] = op;
    if let Some(terminal) = terminal {
        bytes[4..].copy_from_slice(terminal.as_bytes());
    }
    bytes
}

fn reply(op: u8, count: u32) -> [u8; REPLY_LEN] {
    let mut bytes = [0u8; REPLY_LEN];
    bytes[0] = op;
    bytes[4..].copy_from_slice(&count.to_le_bytes());
    bytes
}

// ---------------------------------------------------------------------------
// Host side.

/// The terminals a shared host runs, by id, for `K`.
static TERMINALS: Mutex<Vec<(TerminalId, Weak<HostShared>)>> = Mutex::new(Vec::new());
/// `K` requests for terminals that had not started yet.
static PENDING_KILLS: Mutex<Option<HashSet<[u8; 16]>>> = Mutex::new(None);

/// Called by a shared host's terminal once it runs; ends it at once when
/// its launcher already gave it up.
pub(crate) fn note_started(shared: &Arc<HostShared>) {
    let killed = PENDING_KILLS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .as_mut()
        .is_some_and(|kills| kills.remove(shared.terminal_id.as_bytes()));
    TERMINALS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push((shared.terminal_id, Arc::downgrade(shared)));
    if killed {
        shared.request_termination();
    }
}

/// Called by a shared host's terminal when its serve loop ends.
pub(crate) fn note_ended(terminal: &TerminalId) {
    TERMINALS.lock().unwrap_or_else(PoisonError::into_inner).retain(|(id, _)| id != terminal);
}

fn kill(terminal: TerminalId) {
    let running = TERMINALS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .find(|(id, _)| *id == terminal)
        .and_then(|(_, host)| host.upgrade());
    match running {
        Some(host) => host.request_termination(),
        None => {
            PENDING_KILLS
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get_or_insert_with(HashSet::new)
                .insert(*terminal.as_bytes());
        }
    }
}

/// The shared host process's main loop (`__terminal-host --shared-host`).
/// The process already left the daemon's session and installed the signal
/// guard (`enter_terminal_host_process`); its stdin is the control socket.
pub(crate) fn serve(args: &[String]) -> anyhow::Result<()> {
    mark_shared_host_process();
    shared::host_crash::install_shared();
    let capacity = args
        .iter()
        .position(|arg| arg == CAPACITY_FLAG)
        .and_then(|index| args.get(index + 1))
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(DEFAULT_CAPACITY)
        .clamp(1, MAX_CAPACITY);
    // Many terminals need many descriptors; every shell still starts with
    // the limit cmux started with (`cmux_pty` restores it in the child).
    let _ = cmux_pty::raise_open_file_limit(cmux_pty::OPEN_FILE_LIMIT_CEILING);
    // SAFETY: fd 0 is the control socket the daemon passed as stdin; this
    // process owns it from here on.
    let control = unsafe { UnixStream::from_raw_fd(libc::STDIN_FILENO) };
    // SAFETY: fcntl on the descriptor owned above.
    unsafe { libc::fcntl(control.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
    let live: Arc<(Mutex<u32>, Condvar)> = Arc::new((Mutex::new(0), Condvar::new()));
    let count =
        |live: &(Mutex<u32>, Condvar)| *live.0.lock().unwrap_or_else(PoisonError::into_inner);
    loop {
        let Ok((bytes, descriptor)) = receive_with_descriptor(&control, REQUEST_LEN) else {
            break;
        };
        match bytes[0] {
            OP_TERMINAL => {
                let accepted = descriptor.and_then(|socket| start_slot(socket, &live, capacity));
                let op = if accepted.is_some() { REPLY_ACCEPTED } else { REPLY_FULL };
                if (&control).write_all(&reply(op, count(&live))).is_err() {
                    break;
                }
            }
            OP_COUNT => {
                if (&control).write_all(&reply(OP_COUNT, count(&live))).is_err() {
                    break;
                }
            }
            OP_KILL => {
                if let Ok(id) = <[u8; 16]>::try_from(&bytes[4..]) {
                    kill(TerminalId::from_bytes(id));
                }
            }
            // A request this build does not know: the daemon is not the
            // one that started this host. Take no further terminal.
            _ => break,
        }
    }
    drop(control);
    // The daemon is gone: no new terminal comes. Serve the running ones
    // (the next daemon adopts them), then end.
    let mut running = live.0.lock().unwrap_or_else(PoisonError::into_inner);
    while *running > 0 {
        running = live.1.wait(running).unwrap_or_else(PoisonError::into_inner);
    }
    Ok(())
}

/// Start one terminal slot on `socket`, if the host has room.
fn start_slot(socket: OwnedFd, live: &Arc<(Mutex<u32>, Condvar)>, capacity: u32) -> Option<()> {
    {
        let mut running = live.0.lock().unwrap_or_else(PoisonError::into_inner);
        if *running >= capacity {
            return None;
        }
        *running += 1;
    }
    let slot_live = live.clone();
    let release = move || {
        let mut running = slot_live.0.lock().unwrap_or_else(PoisonError::into_inner);
        *running -= 1;
        slot_live.1.notify_all();
    };
    let stream = UnixStream::from(socket);
    let started = thread::Builder::new().name("terminal-host-slot".into()).spawn(move || {
        if let Ok(mut reader) = stream.try_clone() {
            let mut writer = stream;
            let args = ["--bootstrap-stdio".to_string()];
            if let Err(error) = serve_terminal_host_stdio(&args, &mut reader, &mut writer) {
                eprintln!("terminal-host: a shared terminal ended with an error: {error}");
            }
        }
        release();
    });
    match started {
        Ok(_) => Some(()),
        Err(_) => {
            let mut running = live.0.lock().unwrap_or_else(PoisonError::into_inner);
            *running -= 1;
            live.1.notify_all();
            None
        }
    }
}

// ---------------------------------------------------------------------------
// Daemon side.

struct PoolHost {
    pid: u32,
    control: UnixStream,
    /// Saw `F` since its last `C`.
    full: bool,
}

impl PoolHost {
    /// Send `bytes` (with `descriptor`) and read the reply.
    fn call(
        &self,
        bytes: &[u8; REQUEST_LEN],
        descriptor: Option<RawFd>,
    ) -> std_io::Result<[u8; REPLY_LEN]> {
        match descriptor {
            Some(descriptor) => send_with_descriptor(&self.control, bytes, descriptor)?,
            None => (&self.control).write_all(bytes)?,
        }
        let mut answer = [0u8; REPLY_LEN];
        (&self.control).read_exact(&mut answer)?;
        Ok(answer)
    }
}

/// The shared hosts this daemon started and can still give terminals.
static POOL: Mutex<Vec<PoolHost>> = Mutex::new(Vec::new());

/// A bootstrap socket on a shared host, in place of a host process
/// (`SpawnedHostProcess`). It is the launch-time ownership of one terminal
/// of that host: dropped before `commit`, it asks the host to end the
/// terminal; the host closes its end when the terminal is gone.
pub(crate) struct SharedHostSlot {
    socket: UnixStream,
    host_pid: u32,
    terminal: Option<TerminalId>,
    committed: bool,
}

impl SharedHostSlot {
    pub(crate) fn bind_terminal(&mut self, terminal: TerminalId) {
        self.terminal = Some(terminal);
    }

    pub(crate) fn commit(mut self) {
        self.committed = true;
    }

    /// Whether the host still serves this slot (it closes the socket when
    /// the slot's terminal, or the host, ends).
    pub(crate) fn is_open(&self) -> bool {
        !self.closed_within(Duration::ZERO)
    }

    /// Wait at most `timeout` for the host to close this slot.
    pub(crate) fn closed_within(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            let mut poll =
                libc::pollfd { fd: self.socket.as_raw_fd(), events: libc::POLLIN, revents: 0 };
            let remaining = deadline.saturating_duration_since(Instant::now());
            let millis = libc::c_int::try_from(remaining.as_millis()).unwrap_or(libc::c_int::MAX);
            // SAFETY: one valid pollfd for the duration of the call.
            let ready = unsafe { libc::poll(&mut poll, 1, millis) };
            if ready < 0 {
                if std_io::Error::last_os_error().kind() == std_io::ErrorKind::Interrupted {
                    continue;
                }
                return false;
            }
            if ready == 0 {
                return false;
            }
            if poll.revents & (libc::POLLHUP | libc::POLLERR) != 0 {
                return true;
            }
            // The host never writes after its launch reply: readable means
            // the end of the stream, or a stray byte to skip.
            let mut byte = [0u8; 64];
            // SAFETY: a valid buffer for a nonblocking peek-free read.
            let count = unsafe {
                libc::recv(
                    self.socket.as_raw_fd(),
                    byte.as_mut_ptr().cast(),
                    byte.len(),
                    libc::MSG_DONTWAIT,
                )
            };
            if count == 0 {
                return true;
            }
            if count < 0 && Instant::now() >= deadline {
                return false;
            }
        }
    }
}

impl Drop for SharedHostSlot {
    fn drop(&mut self) {
        if self.committed {
            return;
        }
        let Some(terminal) = self.terminal else { return };
        let pool = POOL.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(host) = pool.iter().find(|host| host.pid == self.host_pid) {
            let _ = (&host.control).write_all(&request(OP_KILL, Some(&terminal)));
        }
    }
}

/// A terminal slot on a shared host: the next free one, or one on a new
/// host when every host this daemon started is full.
pub(crate) fn take_slot() -> anyhow::Result<StandbyTerminalHost> {
    let (daemon_end, host_end) =
        UnixStream::pair().context("create a terminal bootstrap socket")?;
    let mut pool = POOL.lock().unwrap_or_else(PoisonError::into_inner);
    let host_pid = 'placed: {
        for refresh in [false, true] {
            let mut index = pool.len();
            while index > 0 {
                index -= 1;
                if refresh && pool[index].full {
                    match pool[index].call(&request(OP_COUNT, None), None) {
                        Ok(answer) if answer[0] == OP_COUNT => {
                            let count =
                                u32::from_le_bytes([answer[4], answer[5], answer[6], answer[7]]);
                            pool[index].full = count >= configured_capacity();
                        }
                        _ => {
                            pool.remove(index);
                            continue;
                        }
                    }
                }
                if pool[index].full {
                    continue;
                }
                match pool[index].call(&request(OP_TERMINAL, None), Some(host_end.as_raw_fd())) {
                    Ok(answer) if answer[0] == REPLY_ACCEPTED => break 'placed pool[index].pid,
                    Ok(answer) if answer[0] == REPLY_FULL => pool[index].full = true,
                    // A host that does not answer takes no new terminal; its
                    // running terminals stay adoptable through their records.
                    _ => {
                        pool.remove(index);
                    }
                }
            }
        }
        let host = spawn_shared_host()?;
        let answer = host
            .call(&request(OP_TERMINAL, None), Some(host_end.as_raw_fd()))
            .context("hand a terminal to a new shared host")?;
        anyhow::ensure!(
            answer[0] == REPLY_ACCEPTED,
            "a new shared terminal host refused a terminal"
        );
        let pid = host.pid;
        pool.push(host);
        pid
    };
    drop(pool);
    drop(host_end);
    let socket = daemon_end.try_clone().context("keep a terminal bootstrap socket")?;
    let stdout = daemon_end.try_clone().context("read a terminal bootstrap socket")?;
    Ok(StandbyTerminalHost {
        process: SpawnedHostProcess {
            child: None,
            slot: Some(SharedHostSlot { socket, host_pid, terminal: None, committed: false }),
        },
        stdin: Box::new(daemon_end),
        stdout: Box::new(stdout),
        host_pid,
    })
}

fn spawn_shared_host() -> anyhow::Result<PoolHost> {
    let (control, host_control) =
        UnixStream::pair().context("create a shared host control socket")?;
    let session_env = host_session_env();
    let orphan_env = host_orphan_env();
    let capacity = configured_capacity().to_string();
    let child = crate::host_exe::spawn_host(|command| {
        for (name, value) in session_env.iter().chain(&orphan_env) {
            command.env(name, value);
        }
        let stdin = host_control
            .try_clone()
            .map_or_else(|_| Stdio::null(), |fd| Stdio::from(OwnedFd::from(fd)));
        command
            .args(["__terminal-host", SHARED_HOST_FLAG, CAPACITY_FLAG, &capacity])
            .args(host_owner_args())
            .stdin(stdin)
            .stdout(Stdio::null())
            // A host outlives its daemon: no daemon log pipe.
            .stderr(Stdio::null());
    })
    .context("spawn shared terminal-host process")?;
    drop(host_control);
    let pid = child.id();
    // A Cloud daemon's unit stop must not end the host (host_scope.rs).
    host_scope::place_host(pid);
    control.set_read_timeout(Some(CONTROL_TIMEOUT))?;
    control.set_write_timeout(Some(CONTROL_TIMEOUT))?;
    // Reap the host when it ends; it outlives this daemon otherwise.
    let mut child = child;
    let _ = thread::Builder::new().name("shared-host-reaper".into()).spawn(move || {
        let _ = child.wait();
    });
    Ok(PoolHost { pid, control, full: false })
}
