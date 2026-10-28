//! The cloud browser's CDP endpoint (`cmux-rd host --browser URL --browser-cdp-socket PATH`).
//!
//! Chrome speaks the DevTools protocol on an inherited pipe (`--remote-debugging-pipe`: it
//! reads fd 3 and writes fd 4, each message a JSON text ended by a NUL byte), so it opens no
//! TCP port that every local process could reach. The host serves that one connection on a
//! Unix socket that only its own user reaches:
//! - the socket has mode 0600 from the moment it has its name (bound in a new 0700 directory,
//!   set to 0600 there, then renamed into place), in a directory no other user can write;
//! - each client's peer uid (SO_PEERCRED on Linux, getpeereid on macOS) must equal the host's;
//! - one client at a time: while a client is connected, or while no browser runs (between a
//!   crash and its restart), a new client is closed at once;
//! - the framing is the pipe's (NUL-terminated JSON), and messages are forwarded whole: a
//!   client that leaves in the middle of a message leaves nothing in the browser's pipe;
//! - a browser restart attaches the new browser's pipe and closes the connected client, which
//!   connects again to reach the new browser.
//!
//! The pipe is the browser's one CDP connection: target sessions a client attached stay
//! attached after it leaves, and their late events may reach the next client (the same
//! user). A client starts with `Target.getTargets` / `Target.attachToTarget` and ignores
//! messages for ids and sessions it did not open.
//!
//! Design: plans/cmux-next/cloud-browser-DESIGN.md section 4a.

use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;

/// The largest message a client may send; a longer one closes the client.
pub const MAX_CLIENT_MESSAGE: usize = 64 << 20;

/// The largest message the browser may send a client (a big screenshot or
/// DOM result fits); a longer one is dropped and closes the client.
pub const MAX_BROWSER_MESSAGE: usize = 256 << 20;

/// How long a write to a client may wait before the client is closed.
const CLIENT_WRITE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// The host's effective uid: the only uid the CDP socket serves.
pub fn host_uid() -> u32 {
    // SAFETY: geteuid takes no arguments and cannot fail.
    unsafe { libc::geteuid() }
}

/// May a client whose peer uid is `peer` drive the browser of a host running as `host`?
/// Only the same user: root and every other uid are refused.
pub fn peer_allowed(peer: u32, host: u32) -> bool {
    peer == host
}

/// The uid of the process at the other end of `stream`, from the kernel.
#[cfg(target_os = "linux")]
pub fn peer_uid(stream: &UnixStream) -> io::Result<u32> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: `cred` and `len` are valid for writes and `len` is `cred`'s size.
    let r = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            std::ptr::addr_of_mut!(cred).cast(),
            &mut len,
        )
    };
    if r != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(cred.uid)
}

/// The uid of the process at the other end of `stream`, from the kernel.
#[cfg(not(target_os = "linux"))]
pub fn peer_uid(stream: &UnixStream) -> io::Result<u32> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: `uid` and `gid` are valid for writes.
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

/// Refuses a socket directory that another user owns or can write (group or other write,
/// sticky or not): such a user could replace or squat the socket's name.
fn check_private_dir(dir: &Path, uid: u32) -> io::Result<()> {
    let meta = std::fs::metadata(dir)?;
    let refuse = |why: &str| {
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "CDP socket directory {} {why}; use a directory only you can write (0700)",
                dir.display()
            ),
        ))
    };
    if !meta.is_dir() {
        return refuse("is not a directory");
    }
    if meta.uid() != uid {
        return refuse("belongs to another user");
    }
    if meta.mode() & 0o022 != 0 {
        return refuse("is writable by other users");
    }
    Ok(())
}

/// Binds `path` so that the socket is never reachable with a wider mode than 0600: it is
/// bound in a new 0700 directory beside `path`, set to 0600 there, then renamed onto `path`.
/// A socket bound in place and chmod-ed afterwards has the umask's mode until the chmod.
/// Refuses a parent directory another user can write, a live socket at `path` (another
/// server) and a path that is not a socket; a stale socket file is replaced.
pub fn bind_owner_only(path: &Path) -> io::Result<UnixListener> {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, format!("no socket name in {}", path.display()))
    })?;
    check_private_dir(parent, host_uid())?;
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_socket() => {
            if UnixStream::connect(path).is_ok() {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    format!("another server is listening on {}", path.display()),
                ));
            }
        }
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("{} exists and is not a socket", path.display()),
            ))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    static NEXT: AtomicU32 = AtomicU32::new(0);
    // A short sibling name, so the staged path fits sun_path when `path` does.
    let staging = parent.join(format!(
        ".cdp{:x}-{:x}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::DirBuilder::new().mode(0o700).create(&staging)?;
    let staged = staging.join(name);
    let result = (|| {
        let listener = UnixListener::bind(&staged)?;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o600))?;
        std::fs::rename(&staged, path)?;
        Ok(listener)
    })();
    let _ = std::fs::remove_file(&staged);
    let _ = std::fs::remove_dir(&staging);
    result
}

/// The host's ends of one browser's CDP pipe.
pub struct BrowserPipe {
    /// Written by the host, read by the browser (its fd 3).
    pub to_browser: File,
    /// Written by the browser (its fd 4), read by the host.
    pub from_browser: File,
}

/// The browser's ends of its CDP pipe, installed as fds 3 and 4 before exec.
pub struct ChildEnds {
    read: OwnedFd,
    write: OwnedFd,
}

impl ChildEnds {
    /// The raw (read, write) fds for [`install_child_fds`] in the child.
    pub fn raw(&self) -> (RawFd, RawFd) {
        (self.read.as_raw_fd(), self.write.as_raw_fd())
    }
}

/// Two pipes for one browser launch. Every end is close-on-exec in the host, so no other
/// child inherits them; the parent drops [`ChildEnds`] once the browser has started.
pub fn browser_pipes() -> io::Result<(BrowserPipe, ChildEnds)> {
    let (child_read, to_browser) = pipe()?;
    let (from_browser, child_write) = pipe()?;
    Ok((
        BrowserPipe { to_browser: File::from(to_browser), from_browser: File::from(from_browser) },
        ChildEnds { read: child_read, write: child_write },
    ))
}

fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds: [RawFd; 2] = [-1, -1];
    // Linux sets close-on-exec atomically, so a concurrent spawn cannot inherit an end.
    #[cfg(target_os = "linux")]
    // SAFETY: `fds` is a valid two-element array for pipe2 to fill.
    let made = unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) };
    #[cfg(not(target_os = "linux"))]
    // SAFETY: `fds` is a valid two-element array for pipe to fill.
    let made = unsafe { libc::pipe(fds.as_mut_ptr()) };
    if made != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the call succeeded, so both fds are open and owned here.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    #[cfg(not(target_os = "linux"))]
    for fd in [read.as_raw_fd(), write.as_raw_fd()] {
        // SAFETY: fd is open; F_SETFD with FD_CLOEXEC touches no memory.
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok((read, write))
}

/// In the forked child before exec: the pipe ends become fds 3 (read) and 4 (write), which
/// stay open across exec. Both are first copied above fd 10 so that neither dup2 overwrites
/// the other's source. Calls only async-signal-safe functions.
pub fn install_child_fds(read: RawFd, write: RawFd) -> io::Result<()> {
    // SAFETY: fcntl, dup2 and close on fds the child inherited; no memory is touched.
    unsafe {
        let high_read = libc::fcntl(read, libc::F_DUPFD, 10);
        let high_write = libc::fcntl(write, libc::F_DUPFD, 10);
        if high_read < 0 || high_write < 0 {
            return Err(io::Error::last_os_error());
        }
        if libc::dup2(high_read, 3) < 0 || libc::dup2(high_write, 4) < 0 {
            return Err(io::Error::last_os_error());
        }
        libc::close(high_read);
        libc::close(high_write);
    }
    Ok(())
}

/// Reads one NUL-terminated message into `buf` (without the NUL). `Ok(false)` at the end of
/// the stream: a partial message there is dropped. Fails when a message passes `cap` bytes.
fn read_message(r: &mut impl BufRead, buf: &mut Vec<u8>, cap: usize) -> io::Result<bool> {
    buf.clear();
    loop {
        let chunk = match r.fill_buf() {
            Ok(chunk) => chunk,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        if chunk.is_empty() {
            return Ok(false);
        }
        let (take, done) = match chunk.iter().position(|&b| b == 0) {
            Some(i) => (i, true),
            None => (chunk.len(), false),
        };
        buf.extend_from_slice(&chunk[..take]);
        r.consume(if done { take + 1 } else { take });
        if buf.len() > cap {
            // InvalidInput: the message ended here (its NUL is read); InvalidData: it goes on.
            let kind = if done { io::ErrorKind::InvalidInput } else { io::ErrorKind::InvalidData };
            return Err(io::Error::new(kind, format!("a CDP message passed {cap} bytes")));
        }
        if done {
            return Ok(true);
        }
    }
}

struct Client {
    id: u64,
    stream: Arc<UnixStream>,
}

#[derive(Default)]
struct State {
    /// Bumped by each browser launch.
    generation: u64,
    /// The running browser's fd 3, or None between a crash and its restart.
    browser: Option<Arc<Mutex<File>>>,
    client: Option<Client>,
    next_client: u64,
}

impl State {
    fn close_client(&mut self) {
        if let Some(c) = self.client.take() {
            let _ = c.stream.shutdown(std::net::Shutdown::Both);
        }
    }
}

struct Inner {
    uid: u32,
    stop: AtomicBool,
    state: Mutex<State>,
}

impl Inner {
    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Serves the browser's CDP pipe on an owner-only Unix socket, one client at a time.
pub struct CdpBridge {
    path: PathBuf,
    /// The socket file's (device, inode), so `Drop` removes only its own socket.
    file_id: (u64, u64),
    inner: Arc<Inner>,
    /// Shared with the accept thread, so `Drop` can shut it down while its fd is open.
    listener: Arc<UnixListener>,
    accept: Option<JoinHandle<()>>,
}

impl CdpBridge {
    /// Binds `path` owner-only ([`bind_owner_only`]) and serves clients of the host's uid.
    pub fn serve(path: &Path) -> io::Result<Self> {
        Self::serve_for_uid(path, host_uid())
    }

    /// As [`CdpBridge::serve`], admitting peers of `uid` only (tests inject another uid).
    pub fn serve_for_uid(path: &Path, uid: u32) -> io::Result<Self> {
        let listener = Arc::new(bind_owner_only(path)?);
        let accept_listener = Arc::clone(&listener);
        let meta = std::fs::symlink_metadata(path)?;
        let inner = Arc::new(Inner { uid, stop: AtomicBool::new(false), state: Mutex::default() });
        let accept_inner = Arc::clone(&inner);
        // The accept loop blocks in accept(2) and admits one client at a time: Utility.
        // supervise-allow: owned by CdpBridge and joined in its Drop; a panic ends CDP service only and is printed to stderr.
        let accept = cmux_threads::spawn(
            "cmux-rd-cdp-accept",
            cmux_threads::ThreadQos::Utility,
            move || accept_loop(&accept_listener, &accept_inner),
        )?;
        Ok(Self {
            path: path.to_path_buf(),
            file_id: (meta.dev(), meta.ino()),
            inner,
            listener,
            accept: Some(accept),
        })
    }

    /// A browser started with this pipe: it replaces the previous browser's, and the
    /// connected client (a client of the previous browser) is closed.
    pub fn attach(&self, pipe: BrowserPipe) {
        let generation = {
            let mut st = self.inner.state();
            st.generation += 1;
            st.browser = Some(Arc::new(Mutex::new(pipe.to_browser)));
            st.close_client();
            st.generation
        };
        let inner = Arc::clone(&self.inner);
        let from_browser = pipe.from_browser;
        // Reads this browser's messages until its pipe ends (the browser exited): Utility.
        // supervise-allow: ends with its browser's pipe; its end, a panic (a drop guard) or a spawn failure detaches that browser, so clients are refused until the supervisor's next restart.
        let spawned = cmux_threads::spawn(
            "cmux-rd-cdp-browser",
            cmux_threads::ThreadQos::Utility,
            move || browser_loop(&inner, generation, from_browser),
        );
        if let Err(e) = spawned {
            eprintln!("cmux-rd host: CDP pipe reader failed to start: {e}");
            detach(&self.inner, generation);
        }
    }
}

impl Drop for CdpBridge {
    fn drop(&mut self) {
        self.inner.stop.store(true, Ordering::SeqCst);
        // Wakes accept(2) (it fails on a shut-down listener on Linux; the connect covers
        // other systems); the loop sees `stop` before it serves anything.
        // SAFETY: shutdown takes integers only; `self.listener` keeps the fd open.
        unsafe { libc::shutdown(self.listener.as_raw_fd(), libc::SHUT_RDWR) };
        let _ = UnixStream::connect(&self.path);
        if let Some(t) = self.accept.take() {
            let _ = t.join();
        }
        {
            let mut st = self.inner.state();
            st.browser = None;
            st.close_client();
        }
        if let Ok(meta) = std::fs::symlink_metadata(&self.path) {
            if (meta.dev(), meta.ino()) == self.file_id {
                let _ = std::fs::remove_file(&self.path);
            }
        }
    }
}

/// The browser of `generation` is gone: no browser until the next attach, and its client
/// is closed.
fn detach(inner: &Inner, generation: u64) {
    let mut st = inner.state();
    if st.generation == generation {
        st.browser = None;
        st.close_client();
    }
}

fn accept_loop(listener: &UnixListener, inner: &Arc<Inner>) {
    for conn in listener.incoming() {
        if inner.stop.load(Ordering::SeqCst) {
            return;
        }
        match conn {
            Ok(stream) => admit(inner, stream),
            Err(e) => eprintln!("cmux-rd host: CDP socket accept failed: {e}"),
        }
    }
}

/// Serves `stream` when its peer is the host's user, a browser runs and no other client is
/// connected; otherwise drops it, which closes it.
fn admit(inner: &Arc<Inner>, stream: UnixStream) {
    match peer_uid(&stream) {
        Ok(uid) if peer_allowed(uid, inner.uid) => {}
        Ok(uid) => {
            eprintln!(
                "cmux-rd host: CDP socket refused a client of uid {uid} (serves uid {})",
                inner.uid
            );
            return;
        }
        Err(e) => {
            eprintln!("cmux-rd host: CDP socket refused a client: no peer credentials ({e})");
            return;
        }
    }
    // A client that stops reading is closed instead of stalling the browser's messages.
    let _ = stream.set_write_timeout(Some(CLIENT_WRITE_TIMEOUT));
    let stream = Arc::new(stream);
    let id = {
        let mut st = inner.state();
        if st.browser.is_none() {
            eprintln!("cmux-rd host: CDP socket refused a client: the browser is not running");
            return;
        }
        if st.client.is_some() {
            eprintln!("cmux-rd host: CDP socket refused a second client (one client at a time)");
            return;
        }
        let id = st.next_client;
        st.next_client += 1;
        st.client = Some(Client { id, stream: Arc::clone(&stream) });
        id
    };
    let client_inner = Arc::clone(inner);
    // Forwards one client's messages to the browser until either side ends: Utility.
    // supervise-allow: ends with its client's connection; its end, a panic (a drop guard) or a spawn failure closes that client, and the next one is served.
    let spawned =
        cmux_threads::spawn("cmux-rd-cdp-client", cmux_threads::ThreadQos::Utility, move || {
            client_loop(&client_inner, id, &stream)
        });
    if let Err(e) = spawned {
        eprintln!("cmux-rd host: CDP client thread failed to start: {e}");
        end_client(inner, id);
    }
}

fn end_client(inner: &Inner, id: u64) {
    let mut st = inner.state();
    if st.client.as_ref().is_some_and(|c| c.id == id) {
        st.close_client();
    }
}

/// Runs its closure when dropped: at a loop's end and when it panics.
struct OnEnd<F: FnMut()>(F);

impl<F: FnMut()> Drop for OnEnd<F> {
    fn drop(&mut self) {
        (self.0)();
    }
}

/// Client to browser: whole messages only, while this client is the current one.
fn client_loop(inner: &Inner, id: u64, stream: &UnixStream) {
    let _end = OnEnd(|| end_client(inner, id));
    let mut reader = BufReader::new(stream);
    let mut buf = Vec::new();
    loop {
        match read_message(&mut reader, &mut buf, MAX_CLIENT_MESSAGE) {
            Ok(true) => {}
            Ok(false) => break,
            Err(e) => {
                if matches!(e.kind(), io::ErrorKind::InvalidData | io::ErrorKind::InvalidInput) {
                    eprintln!("cmux-rd host: CDP client closed: {e}");
                }
                break;
            }
        }
        let browser = {
            let st = inner.state();
            match (&st.client, &st.browser) {
                (Some(c), Some(browser)) if c.id == id => Arc::clone(browser),
                _ => break,
            }
        };
        buf.push(0);
        let mut pipe = browser.lock().unwrap_or_else(PoisonError::into_inner);
        if pipe.write_all(&buf).is_err() {
            break;
        }
    }
}

/// What [`next_browser_message`] read.
#[derive(Debug, PartialEq, Eq)]
enum BrowserMessage {
    /// One whole message is in the buffer.
    Whole,
    /// A message passed the limit: it was skipped to its NUL, never buffered whole.
    TooLarge,
    /// The pipe ended.
    End,
}

/// The browser's next message into `buf`; one over `cap` bytes is read past
/// and dropped, so the host never holds more than `cap` bytes of it.
fn next_browser_message(
    r: &mut impl BufRead,
    buf: &mut Vec<u8>,
    cap: usize,
) -> io::Result<BrowserMessage> {
    match read_message(r, buf, cap) {
        Ok(true) => Ok(BrowserMessage::Whole),
        Ok(false) => Ok(BrowserMessage::End),
        Err(e) if e.kind() == io::ErrorKind::InvalidInput => {
            buf.clear();
            Ok(BrowserMessage::TooLarge)
        }
        Err(e) if e.kind() == io::ErrorKind::InvalidData => {
            buf.clear();
            loop {
                let chunk = match r.fill_buf() {
                    Ok(chunk) => chunk,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                };
                if chunk.is_empty() {
                    return Ok(BrowserMessage::End);
                }
                if let Some(i) = chunk.iter().position(|&b| b == 0) {
                    r.consume(i + 1);
                    return Ok(BrowserMessage::TooLarge);
                }
                let n = chunk.len();
                r.consume(n);
            }
        }
        Err(e) => Err(e),
    }
}

/// Browser to client: each whole message goes to the current client of this browser, or
/// nowhere when none is connected. A message over [`MAX_BROWSER_MESSAGE`] is dropped and
/// closes the client (it lost a reply).
fn browser_loop(inner: &Inner, generation: u64, from_browser: File) {
    let _end = OnEnd(|| detach(inner, generation));
    let mut reader = BufReader::with_capacity(1 << 16, from_browser);
    let mut buf = Vec::new();
    loop {
        let read = next_browser_message(&mut reader, &mut buf, MAX_BROWSER_MESSAGE);
        let too_large = match read {
            Ok(BrowserMessage::Whole) => false,
            Ok(BrowserMessage::TooLarge) => true,
            Ok(BrowserMessage::End) | Err(_) => break,
        };
        let client = {
            let st = inner.state();
            if st.generation != generation {
                continue;
            }
            st.client.as_ref().map(|c| (c.id, Arc::clone(&c.stream)))
        };
        let Some((id, stream)) = client else { continue };
        if too_large {
            end_client(inner, id);
            continue;
        }
        buf.push(0);
        if (&*stream).write_all(&buf).is_err() {
            end_client(inner, id);
        }
    }
}

#[cfg(test)]
#[path = "cdp_socket_tests.rs"]
mod tests;
