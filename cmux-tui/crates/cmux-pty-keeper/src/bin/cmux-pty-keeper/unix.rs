//! Unix keeper: a single-threaded poll loop over one listening socket, its
//! clients, and a self-pipe fed by SIGCHLD and SIGTERM.

use std::ffi::{CStr, CString, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

use cmux_pty_keeper::protocol::{self, FRAME_LEN, Frame, Size};
use libc::c_int;

use crate::{Launch, report};

static SIGNAL_PIPE: AtomicI32 = AtomicI32::new(-1);
static TERM_REQUESTED: AtomicBool = AtomicBool::new(false);

fn fail(context: &str) -> ! {
    report(&format!("error {context}: {}", std::io::Error::last_os_error()));
    std::process::exit(1);
}

fn fail_with(message: &str) -> ! {
    report(&format!("error {message}"));
    std::process::exit(1);
}

pub fn run(launch: Launch) -> ! {
    // SAFETY: the keeper is single-threaded; every call below is a plain
    // syscall on descriptors this process owns.
    unsafe {
        sanitize_descriptors();
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);

        // Fork once so the spawner reaps its direct child immediately and
        // never owns the keeper.
        match libc::fork() {
            -1 => fail("fork"),
            0 => {}
            _ => libc::_exit(0),
        }
        libc::setsid();

        let path = launch.endpoint.as_bytes().to_vec();
        let listener = listen(&path);
        let path = CString::new(path).expect("checked at bind");
        let (master, slave) = open_pty(launch.cols, launch.rows);
        let signals = signal_pipe();
        let child = match spawn_child(&launch.program, &launch.args, slave) {
            Ok(pid) => pid,
            Err(message) => {
                libc::unlink(path.as_ptr());
                fail_with(&message);
            }
        };
        libc::close(slave);
        // The child has its directory; the keeper must not keep a user
        // directory or mount busy for its whole life.
        libc::chdir(c"/".as_ptr());

        report(&format!("ready {}", libc::getpid()));
        redirect_to_null(1);

        let mut keeper = Keeper {
            master,
            child,
            exit: None,
            delivered: false,
            clients: Vec::new(),
            size: Size::new(launch.cols, launch.rows),
            generation: 0,
            spare: open_spare(),
        };
        keeper.serve(listener, signals);
        libc::unlink(path.as_ptr());
        libc::_exit(0);
    }
}

struct Client {
    fd: c_int,
    buf: [u8; FRAME_LEN],
    len: usize,
    exit_sent: bool,
}

struct Keeper {
    master: c_int,
    child: libc::pid_t,
    exit: Option<c_int>,
    delivered: bool,
    clients: Vec<Client>,
    /// Last size applied to the PTY, reported after `HELLO`.
    size: Size,
    /// Number of resizes applied; lets clients order `SIZE` reports.
    generation: u64,
    /// A reserved descriptor so `accept` can always make progress.
    spare: c_int,
}

impl Keeper {
    unsafe fn serve(&mut self, listener: c_int, signals: c_int) {
        while !(self.delivered && self.clients.is_empty()) {
            let mut fds = vec![
                libc::pollfd { fd: signals, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: listener, events: libc::POLLIN, revents: 0 },
            ];
            fds.extend(self.clients.iter().map(|c| libc::pollfd {
                fd: c.fd,
                events: libc::POLLIN,
                revents: 0,
            }));
            // SAFETY: `fds` is a valid array of `fds.len()` entries.
            if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, -1) } < 0 {
                continue;
            }
            if fds[0].revents != 0 {
                // SAFETY: drains the keeper's own nonblocking pipe.
                unsafe { self.on_signal(signals) };
            }
            let ready: Vec<c_int> =
                fds[2..].iter().filter(|p| p.revents != 0).map(|p| p.fd).collect();
            for fd in ready {
                // SAFETY: `fd` is a connected client socket owned by `self`.
                unsafe { self.on_client(fd) };
            }
            if fds[1].revents != 0 {
                // SAFETY: `listener` is the keeper's listening socket.
                unsafe { self.accept(listener) };
            }
        }
    }

    unsafe fn on_signal(&mut self, signals: c_int) {
        let mut sink = [0u8; 64];
        // SAFETY: reads into a local buffer from the keeper's own pipe.
        while unsafe { libc::read(signals, sink.as_mut_ptr().cast(), sink.len()) } > 0 {}
        if TERM_REQUESTED.swap(false, Ordering::SeqCst) {
            // SAFETY: plain syscalls on keeper-owned state.
            unsafe { self.hang_up() };
        }
        if self.exit.is_none() {
            let mut status = 0;
            // SAFETY: `child` is this process's unreaped child.
            if unsafe { libc::waitpid(self.child, &mut status, libc::WNOHANG) } == self.child {
                self.exit = Some(status);
                // SAFETY: closes the keeper's own master; clients keep theirs.
                unsafe { self.close_master() };
                let exit = Frame::new(protocol::EXIT, status as u32, 0, 0);
                for client in &mut self.clients {
                    // SAFETY: client sockets are owned by `self`.
                    client.exit_sent = unsafe { send(client.fd, &exit, None) };
                }
            }
        }
    }

    unsafe fn accept(&mut self, listener: c_int) {
        // SAFETY: plain accept on the listening socket.
        let mut fd = unsafe { libc::accept(listener, ptr::null_mut(), ptr::null_mut()) };
        if fd < 0 && descriptors_exhausted() && self.spare >= 0 {
            // Out of descriptors: a pending connection would keep the
            // listener readable and spin the loop. Spend the spare to
            // accept and refuse it, then reserve it again.
            // SAFETY: plain descriptor syscalls on keeper-owned descriptors.
            unsafe {
                libc::close(self.spare);
                fd = libc::accept(listener, ptr::null_mut(), ptr::null_mut());
                if fd >= 0 {
                    libc::close(fd);
                }
                self.spare = open_spare();
            }
            return;
        }
        if fd < 0 {
            return;
        }
        // SAFETY: configures and authenticates the new socket.
        unsafe {
            set_flags(fd);
            if peer_uid(fd) != Some(libc::geteuid()) {
                libc::close(fd);
                return;
            }
            let hello = Frame::new(protocol::HELLO, self.child as u32, 0, 0);
            let master = (self.master >= 0).then_some(self.master);
            if !send(fd, &hello, master) {
                libc::close(fd);
                return;
            }
            let report = Frame::size_report(self.current_size(), self.generation);
            if !send(fd, &report, None) {
                libc::close(fd);
                return;
            }
            let exit_sent = match self.exit {
                Some(status) => send(fd, &Frame::new(protocol::EXIT, status as u32, 0, 0), None),
                None => false,
            };
            self.clients.push(Client { fd, buf: [0; FRAME_LEN], len: 0, exit_sent });
        }
    }

    unsafe fn on_client(&mut self, fd: c_int) {
        let Some(index) = self.clients.iter().position(|c| c.fd == fd) else { return };
        let client = &mut self.clients[index];
        // SAFETY: reads into the client's own buffer.
        let n = unsafe {
            libc::read(fd, client.buf[client.len..].as_mut_ptr().cast(), FRAME_LEN - client.len)
        };
        if n == 0 || (n < 0 && !would_block()) {
            // SAFETY: closes a socket owned by `self`.
            unsafe { self.drop_client(index) };
            return;
        }
        if n < 0 {
            return;
        }
        client.len += n as usize;
        if client.len < FRAME_LEN {
            return;
        }
        client.len = 0;
        let Some(frame) = Frame::decode(&client.buf) else {
            // SAFETY: closes a socket owned by `self`.
            unsafe { self.drop_client(index) };
            return;
        };
        match frame.kind {
            // SAFETY: TIOCSWINSZ on the keeper's own master and writes to
            // keeper-owned client sockets.
            protocol::RESIZE => unsafe { self.resize(frame.size()) },
            // SAFETY: plain syscalls on keeper-owned state.
            protocol::TERMINATE => unsafe { self.hang_up() },
            _ => {}
        }
    }

    /// The keeper is done once a client received `EXIT` and every client
    /// disconnected, so no unread status is lost with the keeper.
    unsafe fn drop_client(&mut self, index: usize) {
        let client = self.clients.remove(index);
        // SAFETY: closes a socket owned by `self`.
        unsafe { libc::close(client.fd) };
        self.delivered |= client.exit_sent;
    }

    /// Applies a size and reports the result to every client, so all of
    /// them converge on the last writer's size.
    unsafe fn resize(&mut self, size: Size) {
        if self.master < 0 || size.cols == 0 || size.rows == 0 {
            return;
        }
        let wanted = libc::winsize {
            ws_row: size.rows,
            ws_col: size.cols,
            ws_xpixel: size.width_px,
            ws_ypixel: size.height_px,
        };
        // SAFETY: TIOCSWINSZ on the keeper's own master.
        if unsafe { libc::ioctl(self.master, libc::TIOCSWINSZ as _, &raw const wanted) } != 0 {
            return;
        }
        self.generation += 1;
        let report = Frame::size_report(self.current_size(), self.generation);
        for client in &self.clients {
            // SAFETY: client sockets are owned by `self`. A failed send
            // surfaces as a read error and drops the client.
            unsafe { send(client.fd, &report, None) };
        }
    }

    /// The PTY's real size, which also reflects a direct `TIOCSWINSZ` by a
    /// client.
    fn current_size(&mut self) -> Size {
        if self.master >= 0 {
            // SAFETY: zeroed winsize is valid; TIOCGWINSZ fills it.
            let mut size: libc::winsize = unsafe { std::mem::zeroed() };
            // SAFETY: TIOCGWINSZ on the keeper's own master.
            if unsafe { libc::ioctl(self.master, libc::TIOCGWINSZ as _, &raw mut size) } == 0 {
                self.size = Size {
                    cols: size.ws_col,
                    rows: size.ws_row,
                    width_px: size.ws_xpixel,
                    height_px: size.ws_ypixel,
                };
            }
        }
        self.size
    }

    unsafe fn hang_up(&mut self) {
        // SAFETY: closes the keeper's own master.
        unsafe { self.close_master() };
        if self.exit.is_none() {
            // SAFETY: the child is unreaped, so its pid cannot be reused.
            unsafe { libc::kill(self.child, libc::SIGHUP) };
        }
    }

    unsafe fn close_master(&mut self) {
        if self.master >= 0 {
            // SAFETY: the keeper owns `master`.
            unsafe { libc::close(self.master) };
            self.master = -1;
        }
    }
}

fn descriptors_exhausted() -> bool {
    let error = std::io::Error::last_os_error().raw_os_error();
    error == Some(libc::EMFILE) || error == Some(libc::ENFILE)
}

fn open_spare() -> c_int {
    // SAFETY: opens /dev/null as a reserved close-on-exec descriptor.
    unsafe { libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) }
}

fn would_block() -> bool {
    let error = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
    error == libc::EAGAIN || error == libc::EWOULDBLOCK || error == libc::EINTR
}

/// Sends one frame, optionally with one descriptor. A short write counts as
/// failure; a fresh socket always has room for 32 bytes.
unsafe fn send(fd: c_int, frame: &Frame, attach: Option<c_int>) -> bool {
    let bytes = frame.encode();
    let mut iov = libc::iovec { iov_base: bytes.as_ptr() as *mut _, iov_len: bytes.len() };
    let mut control = [0u64; 4];
    // SAFETY: zeroed msghdr is valid; every referenced buffer outlives sendmsg.
    unsafe {
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        if let Some(attach) = attach {
            let space = libc::CMSG_SPACE(size_of::<c_int>() as u32) as usize;
            msg.msg_control = control.as_mut_ptr().cast();
            msg.msg_controllen = space as _;
            let cmsg = libc::CMSG_FIRSTHDR(&msg);
            (*cmsg).cmsg_level = libc::SOL_SOCKET;
            (*cmsg).cmsg_type = libc::SCM_RIGHTS;
            (*cmsg).cmsg_len = libc::CMSG_LEN(size_of::<c_int>() as u32) as _;
            ptr::write_unaligned(libc::CMSG_DATA(cmsg).cast::<c_int>(), attach);
        }
        libc::sendmsg(fd, &msg, 0) == bytes.len() as isize
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
unsafe fn peer_uid(fd: c_int) -> Option<libc::uid_t> {
    // SAFETY: SO_PEERCRED fills a ucred of the given length.
    unsafe {
        let mut cred: libc::ucred = std::mem::zeroed();
        let mut len = size_of::<libc::ucred>() as libc::socklen_t;
        let ok = libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut cred).cast(),
            &mut len,
        );
        (ok == 0).then_some(cred.uid)
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
unsafe fn peer_uid(fd: c_int) -> Option<libc::uid_t> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: getpeereid writes two ids for a connected Unix socket.
    (unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } == 0).then_some(uid)
}

/// Close-on-exec and nonblocking, so no keeper descriptor reaches the child
/// and no client can stall the loop.
unsafe fn set_flags(fd: c_int) {
    // SAFETY: fcntl on a descriptor this process owns.
    unsafe {
        libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
}

/// Keeps 0..=2 open and closes everything else the spawner leaked, because
/// a keeper can live for months.
unsafe fn sanitize_descriptors() {
    // SAFETY: plain descriptor syscalls during single-threaded startup.
    unsafe {
        for fd in 0..3 {
            if libc::fcntl(fd, libc::F_GETFD) < 0 {
                let null = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
                if null >= 0 && null != fd {
                    libc::dup2(null, fd);
                    libc::close(null);
                }
            }
        }
        let mut limit: libc::rlimit = std::mem::zeroed();
        let max = if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) == 0 {
            limit.rlim_cur.min(65_536) as c_int
        } else {
            1024
        };
        for fd in 3..max {
            libc::close(fd);
        }
    }
}

unsafe fn redirect_to_null(fd: c_int) {
    // SAFETY: replaces `fd` with /dev/null.
    unsafe {
        let null = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR | libc::O_CLOEXEC);
        if null >= 0 {
            libc::dup2(null, fd);
            libc::close(null);
        }
    }
}

unsafe fn listen(path: &[u8]) -> c_int {
    // SAFETY: zeroed sockaddr_un is valid; plain socket syscalls.
    unsafe {
        let mut addr: libc::sockaddr_un = std::mem::zeroed();
        if path.is_empty() || path.contains(&0) || path.len() >= addr.sun_path.len() {
            fail_with("endpoint path is empty or too long");
        }
        addr.sun_family = libc::AF_UNIX as _;
        for (dst, src) in addr.sun_path.iter_mut().zip(path) {
            *dst = *src as _;
        }
        let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
        if fd < 0 {
            fail("socket");
        }
        set_flags(fd);
        let len =
            (std::mem::offset_of!(libc::sockaddr_un, sun_path) + path.len() + 1) as libc::socklen_t;
        // Owner-only socket; the child must keep the spawner's umask.
        let umask = libc::umask(0o077);
        let bound = libc::bind(fd, (&raw const addr).cast(), len);
        libc::umask(umask);
        if bound != 0 {
            fail("bind");
        }
        if libc::listen(fd, libc::SOMAXCONN) != 0 {
            fail("listen");
        }
        fd
    }
}

unsafe fn open_pty(cols: u16, rows: u16) -> (c_int, c_int) {
    // SAFETY: POSIX PTY allocation during single-threaded startup.
    unsafe {
        let master = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
        if master < 0 {
            fail("posix_openpt");
        }
        libc::fcntl(master, libc::F_SETFD, libc::FD_CLOEXEC);
        if libc::grantpt(master) != 0 || libc::unlockpt(master) != 0 {
            fail("grantpt");
        }
        let name = libc::ptsname(master);
        if name.is_null() {
            fail("ptsname");
        }
        let name = CStr::from_ptr(name).to_owned();
        let slave = libc::open(name.as_ptr(), libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC);
        if slave < 0 {
            fail("open pty slave");
        }
        let size = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
        libc::ioctl(master, libc::TIOCSWINSZ as _, &raw const size);
        (master, slave)
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
unsafe fn errno_location() -> *mut c_int {
    // SAFETY: returns the calling thread's errno slot.
    unsafe { libc::__errno_location() }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
unsafe fn errno_location() -> *mut c_int {
    // SAFETY: returns the calling thread's errno slot.
    unsafe { libc::__error() }
}

extern "C" fn on_signal(signal: c_int) {
    // SAFETY: the handler must not change errno seen by the interrupted code.
    let saved = unsafe { *errno_location() };
    if signal == libc::SIGTERM {
        TERM_REQUESTED.store(true, Ordering::SeqCst);
    }
    let fd = SIGNAL_PIPE.load(Ordering::SeqCst);
    if fd >= 0 {
        let byte = 0u8;
        // SAFETY: write(2) is async-signal-safe. The result is ignored: a
        // full pipe already wakes the loop.
        unsafe { libc::write(fd, (&raw const byte).cast(), 1) };
    }
    // SAFETY: restores the value read above.
    unsafe { *errno_location() = saved };
}

unsafe fn signal_pipe() -> c_int {
    // SAFETY: plain pipe and sigaction setup before the child exists.
    unsafe {
        let mut fds = [0; 2];
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            fail("pipe");
        }
        set_flags(fds[0]);
        set_flags(fds[1]);
        SIGNAL_PIPE.store(fds[1], Ordering::SeqCst);
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_signal as extern "C" fn(c_int) as usize;
        action.sa_flags = libc::SA_RESTART | libc::SA_NOCLDSTOP;
        libc::sigemptyset(&mut action.sa_mask);
        libc::sigaction(libc::SIGCHLD, &action, ptr::null_mut());
        libc::sigaction(libc::SIGTERM, &action, ptr::null_mut());
        fds[0]
    }
}

/// Forks the terminal child on `slave`. An exec failure comes back through
/// a close-on-exec pipe so the spawner gets an `error` line, not a child that
/// exits with 127.
unsafe fn spawn_child(
    program: &OsStr,
    args: &[std::ffi::OsString],
    slave: c_int,
) -> Result<libc::pid_t, String> {
    let to_c = |value: &OsStr| {
        CString::new(value.as_bytes()).unwrap_or_else(|_| fail_with("argument contains NUL"))
    };
    let program = to_c(program);
    let args: Vec<CString> =
        std::iter::once(program.clone()).chain(args.iter().map(|a| to_c(a))).collect();
    let mut argv: Vec<*const libc::c_char> = args.iter().map(|a| a.as_ptr()).collect();
    argv.push(ptr::null());
    // SAFETY: fork from a single-threaded process; the child runs only
    // async-signal-safe calls on prepared buffers before exec.
    unsafe {
        let mut errors = [0; 2];
        if libc::pipe(errors.as_mut_ptr()) != 0 {
            fail("pipe");
        }
        libc::fcntl(errors[0], libc::F_SETFD, libc::FD_CLOEXEC);
        libc::fcntl(errors[1], libc::F_SETFD, libc::FD_CLOEXEC);
        let pid = libc::fork();
        if pid < 0 {
            fail("fork");
        }
        if pid == 0 {
            for signal in [libc::SIGHUP, libc::SIGPIPE, libc::SIGTERM, libc::SIGCHLD] {
                libc::signal(signal, libc::SIG_DFL);
            }
            let mut empty: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut empty);
            libc::sigprocmask(libc::SIG_SETMASK, &empty, ptr::null_mut());
            libc::setsid();
            libc::ioctl(slave, libc::TIOCSCTTY as _, 0);
            for fd in 0..3 {
                libc::dup2(slave, fd);
            }
            libc::execvp(program.as_ptr(), argv.as_ptr());
            let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            libc::write(errors[1], (&raw const errno).cast(), size_of::<c_int>());
            libc::_exit(127);
        }
        libc::close(errors[1]);
        let mut errno: c_int = 0;
        let n = loop {
            let n = libc::read(errors[0], (&raw mut errno).cast(), size_of::<c_int>());
            if n >= 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                break n;
            }
        };
        libc::close(errors[0]);
        if n > 0 {
            let mut status = 0;
            libc::waitpid(pid, &mut status, 0);
            return Err(format!(
                "exec {}: {}",
                program.to_string_lossy(),
                std::io::Error::from_raw_os_error(errno)
            ));
        }
        Ok(pid)
    }
}
