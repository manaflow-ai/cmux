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
//! (same build): a request is 8 bytes, `op:u8, reserved:[u8;3]=0,
//! slot:u32`, a reply 12 bytes, `op:u8, reserved:[u8;3]=0, count:u32,
//! slot:u32` (`count`: terminal slots the host runs; `slot`: the id of an
//! accepted slot, else 0).
//!
//! | Request | Descriptor | Reply |
//! | --- | --- | --- |
//! | `T` new terminal | the host end of a fresh bootstrap socket | `A` accepted, `F` full |
//! | `C` count | none | `C` |
//! | `K` end the uncommitted launch on `slot` | none | none |
//!
//! A `K` names a slot, never a terminal id, so it cannot reach a later
//! incarnation of the same terminal; a slot that already ended ignores it.

use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::AtomicU32;
use std::sync::{Condvar, Mutex, OnceLock, PoisonError, Weak};
use std::time::Instant;

use super::super::shared::host_serve::serve_shared_terminal;
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
const REQUEST_LEN: usize = 8;
const REPLY_LEN: usize = 12;
const OP_TERMINAL: u8 = b'T';
const OP_COUNT: u8 = b'C';
const OP_KILL: u8 = b'K';
const REPLY_ACCEPTED: u8 = b'A';
const REPLY_FULL: u8 = b'F';
/// How long the daemon waits for a control reply before it treats the
/// host as gone for new terminals. A new host answers its first request
/// only after its start, and the first start of a fresh host copy on macOS
/// took 1.7 s on a loaded mini, so this is not the 2 s of a host protocol
/// round trip.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(10);

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

fn request(op: u8, slot: u32) -> [u8; REQUEST_LEN] {
    let mut bytes = [0u8; REQUEST_LEN];
    bytes[0] = op;
    bytes[4..8].copy_from_slice(&slot.to_le_bytes());
    bytes
}

fn reply(op: u8, count: u32, slot: u32) -> [u8; REPLY_LEN] {
    let mut bytes = [0u8; REPLY_LEN];
    bytes[0] = op;
    bytes[4..8].copy_from_slice(&count.to_le_bytes());
    bytes[8..12].copy_from_slice(&slot.to_le_bytes());
    bytes
}

fn word(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

// ---------------------------------------------------------------------------
// Host side.

/// One terminal slot of a shared host: the terminal it started, and whether
/// its launcher gave it up (`K`) before that.
struct SlotState {
    id: u32,
    host: Option<Weak<HostShared>>,
    killed: bool,
}

/// The slots of this shared host; an entry lives as long as its thread.
static SLOTS: Mutex<Vec<SlotState>> = Mutex::new(Vec::new());
static NEXT_SLOT: AtomicU32 = AtomicU32::new(1);

thread_local! {
    /// The slot the current thread serves (0: none).
    static CURRENT_SLOT: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

fn slots() -> std::sync::MutexGuard<'static, Vec<SlotState>> {
    SLOTS.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Called by a shared host's terminal once it runs, on its slot's thread;
/// ends it at once when its launcher already gave it up.
pub(crate) fn note_started(shared: &Arc<HostShared>) {
    let id = CURRENT_SLOT.with(std::cell::Cell::get);
    let killed = slots().iter_mut().find(|slot| slot.id == id).is_some_and(|slot| {
        slot.host = Some(Arc::downgrade(shared));
        slot.killed
    });
    if killed {
        shared.request_termination();
    }
}

fn kill(id: u32) {
    let started = {
        let mut slots = slots();
        let Some(slot) = slots.iter_mut().find(|slot| slot.id == id) else { return };
        slot.killed = true;
        slot.host.as_ref().and_then(Weak::upgrade)
    };
    if let Some(host) = started {
        host.request_termination();
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
    let workers = thread::available_parallelism().map_or(2, |count| count.get()).min(4);
    shared_exec::start(workers).context("start the shared host's event loop")?;
    // Many terminals need many descriptors; every shell still starts with
    // the limit cmux started with (`cmux_pty` restores it in the child).
    let _ = cmux_pty::raise_open_file_limit(cmux_pty::OPEN_FILE_LIMIT_CEILING);
    let control = take_control_socket()?;
    let live: Arc<(Mutex<u32>, Condvar)> = Arc::new((Mutex::new(0), Condvar::new()));
    let count =
        |live: &(Mutex<u32>, Condvar)| *live.0.lock().unwrap_or_else(PoisonError::into_inner);
    loop {
        let Ok((bytes, descriptor)) = receive_with_descriptor(&control, REQUEST_LEN) else {
            break;
        };
        match bytes[0] {
            OP_TERMINAL => {
                let slot = descriptor.and_then(|socket| start_slot(socket, &live, capacity));
                let op = if slot.is_some() { REPLY_ACCEPTED } else { REPLY_FULL };
                if (&control).write_all(&reply(op, count(&live), slot.unwrap_or(0))).is_err() {
                    break;
                }
            }
            OP_COUNT => {
                if (&control).write_all(&reply(OP_COUNT, count(&live), 0)).is_err() {
                    break;
                }
            }
            OP_KILL => kill(word(&bytes, 4)),
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

/// The control socket the daemon passed as stdin, moved off fd 0 (a later
/// `open` must never get descriptor 0); fd 0 becomes `/dev/null`.
fn take_control_socket() -> anyhow::Result<UnixStream> {
    // SAFETY: fcntl duplicates the inherited stdin to a new close-on-exec
    // descriptor this process then owns.
    let moved = unsafe { libc::fcntl(libc::STDIN_FILENO, libc::F_DUPFD_CLOEXEC, 3) };
    if moved < 0 {
        return Err(std_io::Error::last_os_error()).context("take the shared host control socket");
    }
    // SAFETY: `moved` was just returned by fcntl and is owned here.
    let control = unsafe { UnixStream::from_raw_fd(moved) };
    let null = OpenOptions::new().read(true).write(true).open("/dev/null")?;
    // SAFETY: dup2 replaces fd 0 with this process's own /dev/null.
    if unsafe { libc::dup2(null.as_raw_fd(), libc::STDIN_FILENO) } < 0 {
        return Err(std_io::Error::last_os_error()).context("replace the shared host stdin");
    }
    Ok(control)
}

/// A running slot's count and registry entry; dropped when its thread ends,
/// also by a panic.
struct SlotGuard {
    id: u32,
    live: Arc<(Mutex<u32>, Condvar)>,
}

impl Drop for SlotGuard {
    fn drop(&mut self) {
        slots().retain(|slot| slot.id != self.id);
        let mut running = self.live.0.lock().unwrap_or_else(PoisonError::into_inner);
        *running -= 1;
        self.live.1.notify_all();
    }
}

/// Start one terminal slot on `socket`, if the host has room. Returns the
/// slot's id.
fn start_slot(socket: OwnedFd, live: &Arc<(Mutex<u32>, Condvar)>, capacity: u32) -> Option<u32> {
    {
        let mut running = live.0.lock().unwrap_or_else(PoisonError::into_inner);
        if *running >= capacity {
            return None;
        }
        *running += 1;
    }
    let id = NEXT_SLOT.fetch_add(1, Ordering::Relaxed);
    slots().push(SlotState { id, host: None, killed: false });
    let guard = SlotGuard { id, live: live.clone() };
    let stream = UnixStream::from(socket);
    let executor = shared_exec::executor()?;
    let fd = stream.as_raw_fd();
    // The slot waits for its Bootstrap on the event loop, not a thread: a
    // standby slot may wait for a long time.
    let started = executor.on_readable(fd, move || {
        CURRENT_SLOT.with(|current| current.set(id));
        if let (Ok(mut reader), Ok(keep)) = (stream.try_clone(), stream.try_clone()) {
            let mut writer = stream;
            // The slot's guard and a copy of its socket live as long as its
            // terminal: the daemon sees the socket close when it ends.
            let keepalive: Box<dyn Send> = Box::new((guard, keep));
            if let Err(error) = serve_shared_terminal(&mut reader, &mut writer, keepalive) {
                eprintln!("terminal-host: a shared terminal ended with an error: {error}");
            }
        }
        CURRENT_SLOT.with(|current| current.set(0));
    });
    // A handler that was not registered dropped its guard with it.
    started.ok().map(|_| id)
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
/// of that host: dropped before `commit`, it asks the host to end that
/// slot's terminal; the host closes its end when the terminal is gone.
pub(crate) struct SharedHostSlot {
    socket: UnixStream,
    host_pid: u32,
    slot: u32,
    committed: bool,
}

impl SharedHostSlot {
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
        // A closed slot's terminal is gone already.
        if self.committed || !self.is_open() {
            return;
        }
        let pool = POOL.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(host) = pool.iter().find(|host| host.pid == self.host_pid) {
            let _ = (&host.control).write_all(&request(OP_KILL, self.slot));
        }
    }
}

/// Hand a fresh bootstrap socket to `host`. `Ok(None)`: the host is full.
fn place(host: &PoolHost) -> std_io::Result<Option<(UnixStream, u32)>> {
    // A fresh pair per attempt: a host that answered late (or not at all)
    // keeps only its own copy, never a socket another host serves.
    let (daemon_end, host_end) = UnixStream::pair()?;
    let answer = host.call(&request(OP_TERMINAL, 0), Some(host_end.as_raw_fd()))?;
    drop(host_end);
    match answer[0] {
        REPLY_ACCEPTED if word(&answer, 8) != 0 => Ok(Some((daemon_end, word(&answer, 8)))),
        REPLY_FULL => Ok(None),
        _ => Err(std_io::Error::other("unexpected shared host reply")),
    }
}

/// A terminal slot on a shared host: the next free one, or one on a new
/// host when every host this daemon started is full.
pub(crate) fn take_slot() -> anyhow::Result<StandbyTerminalHost> {
    let placed = {
        let mut pool = POOL.lock().unwrap_or_else(PoisonError::into_inner);
        let mut placed = None;
        'search: for refresh in [false, true] {
            let mut index = pool.len();
            while index > 0 {
                index -= 1;
                if refresh && pool[index].full {
                    match pool[index].call(&request(OP_COUNT, 0), None) {
                        Ok(answer) if answer[0] == OP_COUNT => {
                            pool[index].full = word(&answer, 4) >= configured_capacity();
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
                match place(&pool[index]) {
                    Ok(Some((socket, slot))) => {
                        placed = Some((socket, slot, pool[index].pid));
                        break 'search;
                    }
                    Ok(None) => pool[index].full = true,
                    // A host that does not answer takes no new terminal; its
                    // running terminals stay adoptable through their records.
                    Err(_) => {
                        pool.remove(index);
                    }
                }
            }
        }
        placed
    };
    let (daemon_end, slot, host_pid) = match placed {
        Some(placed) => placed,
        None => {
            // Outside the pool lock: starting a host (and its scope) must
            // not hold up other launches or rollbacks.
            let host = spawn_shared_host()?;
            let (socket, slot) = place(&host)
                .context("hand a terminal to a new shared host")?
                .context("a new shared terminal host refused a terminal")?;
            let pid = host.pid;
            POOL.lock().unwrap_or_else(PoisonError::into_inner).push(host);
            (socket, slot, pid)
        }
    };
    let socket = daemon_end.try_clone().context("keep a terminal bootstrap socket")?;
    let stdout = daemon_end.try_clone().context("read a terminal bootstrap socket")?;
    Ok(StandbyTerminalHost {
        process: SpawnedHostProcess {
            child: None,
            slot: Some(SharedHostSlot { socket, host_pid, slot, committed: false }),
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
