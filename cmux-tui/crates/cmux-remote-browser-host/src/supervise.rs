//! `--supervise`: one shared remote browser host for every remote tab of an
//! app (or of one profile, such as the phone's tabs), and the rule that keeps
//! its tabs when it crashes (cmuxterm-hq docs/design/process-sharing.md,
//! "Remote and phone browser tabs").
//!
//! The supervisor is the lean process of the pair: it runs no Chromium, parses
//! no page and holds what a crash must not lose. It binds the loopback
//! listener once and hands it to each host it starts (so the port never
//! changes and viewers that reconnect during a restart wait in the backlog),
//! keeps every tab's record (id, last URL, token, cache directory) and starts
//! the CEF host (`--serve --shared --listen-fd 3`). When the host ends
//! without being asked, every tab it served reopens at its last URL in a new
//! host, with its own cache directory (cookies kept). A second end within
//! [`Policy::window`] of the first stays down until the app opens a tab again
//! (as plans/cmux-next/cef-helper-app-DESIGN.md: a crash loop never spins).
//!
//! Wire with the app (JSON lines; stdin is also the lifeline, end of file
//! quits and removes the cache root):
//! - in: `{"open":{"tab":ID,"url":URL}}`, `{"close":{"tab":ID}}`;
//! - out: `{"listening":"127.0.0.1:PORT"}` once; `{"tab":ID,"token":HEX,"url":URL}`
//!   once the tab's host knows it (a viewer's rd hello carries that token);
//!   `{"tab":ID,"url":URL}` when its page moves; `{"tab":ID,"reopened":G,"url":URL}`
//!   when host G opened it again after a crash (its viewer reconnects); `{"tab":ID,"closed":true}`;
//!   `{"host":{"pid":N,"generation":G}}` per host started; `{"down":{"reason":R}}`.
//!
//! Wire with the host (stdin, JSON lines): `{"open":{"tab","url","token","cache"}}`,
//! `{"close":{"tab"}}`, then `{"serve":true}` once the first batch is written
//! (the host accepts viewers only after it, so a reconnecting viewer never
//! meets a host that does not know its token yet). The host's stdout:
//! `{"listening":ADDR}`, `{"tab":ID,"ready":true}`, `{"tab":ID,"url":URL}`,
//! `{"tab":ID,"closed":true}`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// When a host that ended is started again.
#[derive(Debug, Clone, Copy)]
pub struct Policy {
    /// The wait before a crashed host restarts.
    pub backoff: Duration,
    /// A second end within this long of the first stays down.
    pub window: Duration,
}

impl Default for Policy {
    fn default() -> Self {
        Self { backoff: Duration::from_millis(250), window: Duration::from_secs(60) }
    }
}

/// One tab the supervisor keeps across hosts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabRecord {
    pub id: String,
    /// The page's last URL (the host reports each move).
    pub url: String,
    /// The tab's rd session token (64 hex characters).
    pub token: String,
    /// The tab's own CEF cache directory (its request context: cookies,
    /// storage), kept across hosts and removed when the tab closes.
    pub cache: PathBuf,
    /// The app has the token (sent once, when a host first knew the tab).
    replied: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Host {
    /// No host: none was needed yet, or it stayed down.
    Down,
    /// A host runs (generation).
    Up(u64),
    /// The host ended; a new one starts at this instant.
    Restarting(Instant),
}

/// What the supervisor's IO does next.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// Start host `generation`, writing `lines` to its stdin first.
    Spawn { generation: u64, lines: Vec<String> },
    /// A line for the running host.
    ToHost(String),
    /// A line for the app.
    ToApp(String),
    /// Close the running host's lifeline (it quits).
    StopHost,
    /// Create a tab's cache directory.
    MakeDir(PathBuf),
    /// Remove a closed tab's cache directory.
    RemoveDir(PathBuf),
    /// Remove the cache root and exit.
    Quit,
}

/// The supervisor's state: pure, with the clock and the token source passed in.
pub struct Supervisor {
    policy: Policy,
    root: PathBuf,
    tabs: BTreeMap<String, TabRecord>,
    /// Tabs closed while their host still has them: their directory goes
    /// when the host says closed (or the host ends).
    closing: BTreeMap<String, PathBuf>,
    next_dir: u64,
    host: Host,
    generation: u64,
    /// When the host last ended without being asked.
    last_end: Option<Instant>,
    stopping: bool,
}

impl Supervisor {
    pub fn new(root: &Path, policy: Policy) -> Self {
        Self {
            policy,
            root: root.to_path_buf(),
            tabs: BTreeMap::new(),
            closing: BTreeMap::new(),
            next_dir: 1,
            host: Host::Down,
            generation: 0,
            last_end: None,
            stopping: false,
        }
    }

    pub fn tabs(&self) -> impl Iterator<Item = &TabRecord> {
        self.tabs.values()
    }

    /// The running host's generation.
    pub fn generation(&self) -> Option<u64> {
        match self.host {
            Host::Up(g) => Some(g),
            _ => None,
        }
    }

    /// When [`Self::tick`] must run next (a pending restart).
    pub fn deadline(&self) -> Option<Instant> {
        match self.host {
            Host::Restarting(at) => Some(at),
            _ => None,
        }
    }

    fn open_line(tab: &TabRecord) -> String {
        json!({"open": {"tab": tab.id, "url": tab.url, "token": tab.token,
            "cache": tab.cache.to_string_lossy()}})
        .to_string()
    }

    fn start_host(&mut self) -> Action {
        self.generation += 1;
        self.host = Host::Up(self.generation);
        let mut lines: Vec<String> = self.tabs.values().map(Self::open_line).collect();
        lines.push(json!({"serve": true}).to_string());
        Action::Spawn { generation: self.generation, lines }
    }

    /// A line from the app; `token` makes a new tab's token.
    pub fn app_line(&mut self, line: &str, token: impl FnOnce() -> String) -> Vec<Action> {
        let Ok(v) = serde_json::from_str::<Value>(line) else { return Vec::new() };
        if let Some(open) = v.get("open") {
            let (Some(id), Some(url)) =
                (open.get("tab").and_then(Value::as_str), open.get("url").and_then(Value::as_str))
            else {
                return Vec::new();
            };
            return self.open(id, url, token());
        }
        if let Some(id) = v.get("close").and_then(|c| c.get("tab")).and_then(Value::as_str) {
            return self.close(id);
        }
        Vec::new()
    }

    fn open(&mut self, id: &str, url: &str, token: String) -> Vec<Action> {
        if self.stopping || id.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        if let Some(tab) = self.tabs.get(id) {
            // Already open: the app asked again (it lost the reply); answer it.
            if tab.replied {
                out.push(Action::ToApp(reply(tab)));
            }
            return out;
        }
        // Chrome makes a profile only directly under its user data dir (the
        // root cache path): `root/tabs/1` was refused and fell back to memory.
        let cache = self.root.join(format!("tab-{}", self.next_dir));
        self.next_dir += 1;
        let tab = TabRecord {
            id: id.to_string(),
            url: url.to_string(),
            token,
            cache: cache.clone(),
            replied: false,
        };
        out.push(Action::MakeDir(cache));
        let line = Self::open_line(&tab);
        self.tabs.insert(id.to_string(), tab);
        match self.host {
            Host::Up(_) => out.push(Action::ToHost(line)),
            // A pending restart opens it with the rest.
            Host::Restarting(_) => {}
            // The first tab, or a tab after the host stayed down: the person
            // asked for a page, so a new host starts (and the rule starts over).
            Host::Down => {
                self.last_end = None;
                out.push(self.start_host());
            }
        }
        out
    }

    fn close(&mut self, id: &str) -> Vec<Action> {
        let Some(tab) = self.tabs.remove(id) else { return Vec::new() };
        match self.host {
            Host::Up(_) => {
                self.closing.insert(id.to_string(), tab.cache);
                vec![Action::ToHost(json!({"close": {"tab": id}}).to_string())]
            }
            _ => vec![Action::RemoveDir(tab.cache), Action::ToApp(closed(id))],
        }
    }

    /// The app's lifeline ended: stop the host, then quit.
    pub fn app_eof(&mut self) -> Vec<Action> {
        self.stopping = true;
        match self.host {
            Host::Up(_) => vec![Action::StopHost],
            _ => vec![Action::Quit],
        }
    }

    /// A line from host `generation`'s stdout.
    pub fn host_line(&mut self, generation: u64, line: &str) -> Vec<Action> {
        if self.host != Host::Up(generation) {
            return Vec::new();
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else { return Vec::new() };
        let Some(id) = v.get("tab").and_then(Value::as_str) else { return Vec::new() };
        if v.get("closed").and_then(Value::as_bool) == Some(true) {
            return match self.closing.remove(id) {
                Some(dir) => vec![Action::RemoveDir(dir), Action::ToApp(closed(id))],
                None => Vec::new(),
            };
        }
        let Some(tab) = self.tabs.get_mut(id) else { return Vec::new() };
        let mut out = Vec::new();
        if let Some(url) = v.get("url").and_then(Value::as_str)
            && !url.is_empty()
            && url != tab.url
        {
            tab.url = url.to_string();
            out.push(Action::ToApp(json!({"tab": id, "url": url}).to_string()));
        }
        if v.get("ready").and_then(Value::as_bool) == Some(true) {
            if tab.replied {
                // A new host has the tab again: its viewer reconnects now.
                out.push(Action::ToApp(
                    json!({"tab": id, "reopened": generation, "url": tab.url}).to_string(),
                ));
            } else {
                tab.replied = true;
                out.push(Action::ToApp(reply(tab)));
            }
        }
        out
    }

    /// Host `generation` exited.
    pub fn host_ended(&mut self, generation: u64, now: Instant) -> Vec<Action> {
        if self.host != Host::Up(generation) {
            return Vec::new();
        }
        // Tabs closed in the host that died: nothing holds their profile now.
        let mut out: Vec<Action> = std::mem::take(&mut self.closing)
            .into_iter()
            .flat_map(|(id, dir)| [Action::RemoveDir(dir), Action::ToApp(closed(&id))])
            .collect();
        if self.stopping {
            self.host = Host::Down;
            out.push(Action::Quit);
            return out;
        }
        let again = self.last_end.is_some_and(|t| now.duration_since(t) < self.policy.window);
        self.last_end = Some(now);
        if again {
            self.host = Host::Down;
            let reason = format!(
                "the remote browser host ended twice within {} s; it starts again when a tab opens",
                self.policy.window.as_secs()
            );
            out.push(Action::ToApp(json!({"down": {"reason": reason}}).to_string()));
        } else if self.tabs.is_empty() {
            // Nothing to reopen: the next tab starts a host.
            self.host = Host::Down;
        } else {
            self.host = Host::Restarting(now + self.policy.backoff);
        }
        out
    }

    /// Time passed: a due restart starts the new host with every tab.
    pub fn tick(&mut self, now: Instant) -> Vec<Action> {
        match self.host {
            Host::Restarting(at) if now >= at => vec![self.start_host()],
            _ => Vec::new(),
        }
    }
}

fn reply(tab: &TabRecord) -> String {
    json!({"tab": tab.id, "token": tab.token, "url": tab.url}).to_string()
}

fn closed(id: &str) -> String {
    json!({"tab": id, "closed": true}).to_string()
}

/// 32 random bytes as 64 lowercase hex characters (the rd session token).
pub fn random_token() -> std::io::Result<String> {
    use std::io::Read;
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(unix)]
pub mod run {
    //! The supervisor's IO on one thread: a `poll` over the app's stdin, the
    //! host's stdout and the host's exit (a pidfd on Linux, a kqueue
    //! `NOTE_EXIT` on macOS), with the restart deadline as its timeout. No
    //! thread and no timer runs while nothing happens.

    use std::io::{Read, Write};
    use std::net::{SocketAddr, TcpListener};
    use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd, RawFd};
    use std::path::PathBuf;
    use std::process::{ChildStdin, ChildStdout};
    use std::time::Instant;

    use super::{Action, Policy, Supervisor, random_token};

    /// The fd a host gets the listener on (`--listen-fd`).
    pub const LISTEN_FD: RawFd = 3;

    /// `--supervise` options.
    #[derive(Debug, Clone)]
    pub struct Options {
        pub listen: SocketAddr,
        /// The host binary (this binary, normally).
        pub host: PathBuf,
        /// Arguments after `--serve --shared --listen-fd 3 --lifeline`.
        pub host_args: Vec<String>,
        /// The cache root (every tab's directory is under it).
        pub root: PathBuf,
        pub policy: Policy,
    }

    /// The running host.
    struct Host {
        generation: u64,
        child: cmux_process::Child,
        stdin: Option<ChildStdin>,
        stdout: Option<ChildStdout>,
        out: Lines,
        /// Readable once the host exited; `None`: it had exited before the
        /// watch was set, so it ended already.
        exit: Option<OwnedFd>,
    }

    /// Bytes read so far, split into lines.
    #[derive(Default)]
    struct Lines(Vec<u8>);

    impl Lines {
        fn push(&mut self, bytes: &[u8]) -> Vec<String> {
            self.0.extend_from_slice(bytes);
            let mut lines = Vec::new();
            while let Some(end) = self.0.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = self.0.drain(..=end).collect();
                lines.push(String::from_utf8_lossy(&line[..end]).into_owned());
            }
            lines
        }
    }

    fn emit(line: &str) {
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{line}");
        let _ = out.flush();
    }

    /// An fd that turns readable when `pid` exits.
    #[cfg(target_os = "linux")]
    fn exit_watch(pid: u32) -> Option<OwnedFd> {
        // SAFETY: pidfd_open takes a pid and flags; a valid fd is ours.
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0) };
        // SAFETY: a non-negative return is a new fd nothing else owns.
        (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd as RawFd) })
    }

    /// An fd that turns readable when `pid` exits.
    #[cfg(not(target_os = "linux"))]
    fn exit_watch(pid: u32) -> Option<OwnedFd> {
        // SAFETY: kqueue makes a new fd; we own it.
        let kq = unsafe { libc::kqueue() };
        if kq < 0 {
            return None;
        }
        // SAFETY: a new fd nothing else owns.
        let kq = unsafe { OwnedFd::from_raw_fd(kq) };
        // SAFETY: a zeroed kevent is a valid value to fill in.
        let mut ev: libc::kevent = unsafe { std::mem::zeroed() };
        ev.ident = pid as libc::uintptr_t;
        ev.filter = libc::EVFILT_PROC;
        ev.flags = libc::EV_ADD | libc::EV_ONESHOT;
        ev.fflags = libc::NOTE_EXIT;
        // SAFETY: one change, no event list; the pointers outlive the call.
        let set = unsafe {
            libc::kevent(kq.as_raw_fd(), &ev, 1, std::ptr::null_mut(), 0, std::ptr::null())
        };
        // ESRCH: it exited already (the caller treats None as ended).
        (set == 0).then_some(kq)
    }

    fn read_some(fd: &mut impl Read) -> Option<Vec<u8>> {
        let mut buf = [0u8; 16 * 1024];
        match fd.read(&mut buf) {
            Ok(0) | Err(_) => None,
            Ok(n) => Some(buf[..n].to_vec()),
        }
    }

    /// Runs until the app's lifeline ends and the host quit; returns the exit code.
    pub fn supervise(opts: Options) -> i32 {
        let listener = match TcpListener::bind(opts.listen) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("supervise: bind {}: {e}", opts.listen);
                return 1;
            }
        };
        let Ok(bound) = listener.local_addr() else { return 1 };
        if let Err(e) = std::fs::create_dir_all(&opts.root) {
            eprintln!("supervise: cache root {}: {e}", opts.root.display());
            return 1;
        }
        // CEF resolves its root cache path (/tmp is /private/tmp on macOS) and
        // refuses a tab's cache path that is not under the resolved one: that
        // tab gets an in-memory profile. Every path starts from the resolved root.
        let opts = match std::fs::canonicalize(&opts.root) {
            Ok(root) => Options { root, ..opts },
            Err(e) => {
                eprintln!("supervise: cache root {}: {e}", opts.root.display());
                return 1;
            }
        };
        emit(&crate::launch::listening_line(bound));
        let mut core = Supervisor::new(&opts.root, opts.policy);
        let mut host: Option<Host> = None;
        let mut app = Lines::default();
        let mut app_open = true;
        let mut stdin = std::io::stdin();
        loop {
            // What to wait on: the app, the host's lines, the host's exit.
            let mut fds: Vec<libc::pollfd> = Vec::with_capacity(3);
            let pollfd = |fd: RawFd| libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
            if app_open {
                fds.push(pollfd(0));
            }
            let out_at = host.as_ref().and_then(|h| h.stdout.as_ref()).map(|o| {
                fds.push(pollfd(o.as_raw_fd()));
                fds.len() - 1
            });
            let exit_at = host.as_ref().and_then(|h| h.exit.as_ref()).map(|e| {
                fds.push(pollfd(e.as_raw_fd()));
                fds.len() - 1
            });
            let ended_already = host.as_ref().is_some_and(|h| h.exit.is_none());
            let timeout = if ended_already {
                0
            } else {
                core.deadline().map_or(-1, |at| {
                    let ms = at.saturating_duration_since(Instant::now()).as_millis();
                    libc::c_int::try_from(ms.saturating_add(1)).unwrap_or(libc::c_int::MAX)
                })
            };
            // SAFETY: `fds` is a valid array of `fds.len()` pollfds for the call.
            let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
            if n < 0 {
                if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return 1;
            }
            let ready = |i: Option<usize>| i.is_some_and(|i: usize| fds[i].revents != 0);
            let mut actions = Vec::new();
            if app_open && fds[0].revents != 0 {
                match read_some(&mut stdin) {
                    Some(bytes) => {
                        for line in app.push(&bytes) {
                            actions.extend(core.app_line(&line, || {
                                random_token().unwrap_or_else(|e| {
                                    // No token, no tab: an empty token admits nobody.
                                    eprintln!("supervise: no random bytes: {e}");
                                    String::new()
                                })
                            }));
                        }
                    }
                    None => {
                        app_open = false;
                        actions.extend(core.app_eof());
                    }
                }
            }
            if ready(out_at)
                && let Some(h) = host.as_mut()
            {
                match h.stdout.as_mut().and_then(read_some) {
                    Some(bytes) => {
                        for line in h.out.push(&bytes) {
                            actions.extend(core.host_line(h.generation, &line));
                        }
                    }
                    // Its stdout ended (the exit watch says when it ended).
                    None => h.stdout = None,
                }
            }
            if (ready(exit_at) || ended_already)
                && let Some(mut h) = host.take()
            {
                let status = h.child.wait();
                eprintln!("supervise: host {} ended: {status:?}", h.generation);
                actions.extend(core.host_ended(h.generation, Instant::now()));
            }
            if n == 0 && !ended_already {
                actions.extend(core.tick(Instant::now()));
            }
            for action in actions {
                match action {
                    Action::Spawn { generation, lines } => {
                        host = start(&opts, &listener, generation, &lines);
                        if host.is_none() {
                            // It never ran: the same rule as an end.
                            actions_after_failed_start(&mut core, generation);
                        }
                    }
                    Action::ToHost(line) => {
                        if let Some(s) = host.as_mut().and_then(|h| h.stdin.as_mut()) {
                            let _ = writeln!(s, "{line}").and_then(|()| s.flush());
                        }
                    }
                    Action::ToApp(line) => emit(&line),
                    // The lifeline: the host quits, and its exit ends the loop.
                    Action::StopHost => {
                        if let Some(h) = host.as_mut() {
                            h.stdin = None;
                        }
                    }
                    Action::MakeDir(dir) => {
                        let _ = std::fs::create_dir_all(dir);
                    }
                    Action::RemoveDir(dir) => {
                        let _ = std::fs::remove_dir_all(dir);
                    }
                    Action::Quit => {
                        let _ = std::fs::remove_dir_all(&opts.root);
                        return 0;
                    }
                }
            }
        }
    }

    /// A host that never started: its end now (the restart rule applies).
    fn actions_after_failed_start(core: &mut Supervisor, generation: u64) {
        for action in core.host_ended(generation, Instant::now()) {
            if let Action::ToApp(line) = action {
                emit(&line);
            }
        }
    }

    fn start(
        opts: &Options,
        listener: &TcpListener,
        generation: u64,
        lines: &[String],
    ) -> Option<Host> {
        let mut cmd = cmux_process::Command::new(&opts.host);
        cmd.args(["--serve", "--shared", "--listen-fd", "3", "--lifeline"])
            .args(&opts.host_args)
            .env("CMUX_RB_CACHE_DIR", &opts.root)
            .stdin(cmux_process::Stdio::piped())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::inherit());
        if let Err(e) = cmd.inherit_fd(listener.as_fd(), LISTEN_FD) {
            eprintln!("supervise: listener for the host: {e}");
            return None;
        }
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("supervise: start host: {e}");
                return None;
            }
        };
        let pid = child.id();
        let exit = exit_watch(pid);
        emit(&serde_json::json!({"host": {"pid": pid, "generation": generation}}).to_string());
        let mut stdin = child.stdin.take();
        if let Some(s) = stdin.as_mut() {
            for line in lines {
                if writeln!(s, "{line}").is_err() {
                    break;
                }
            }
            let _ = s.flush();
        }
        let stdout = child.stdout.take();
        Some(Host { generation, child, stdin, stdout, out: Lines::default(), exit })
    }
}
