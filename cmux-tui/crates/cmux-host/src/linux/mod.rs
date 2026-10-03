//! The Linux [`Platform`]: one epoll set over the clock-set timerfd,
//! rtnetlink, inotify on `/run/cmux` and `/etc/cmux`, a signalfd, three
//! one-shot timerfds (re-arm, backoff, stop deadline) and the session
//! host's pidfd.

pub mod fds;
pub mod identity;
pub mod procs;
pub mod spawn;

use std::fs;
use std::io;
use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::process::Child;
use std::time::Instant;

use crate::agent::{Exit, Platform, Wake};
use crate::announce::{arping_args, is_announce_target};
use crate::config::{
    AGENT_DIR, BAKE_FILE_NAME, BAKE_INSTANCE_FILE, BOUND_INSTANCE_FILE, Config, DAEMON_PID_FILE,
    DRIVER_FILE_NAME, ETC_DIR, GHOSTTY_VERSION_FILE, HOUSEKEEPING_TIMERS, LAYOUT_MARKER_FILE,
    RUN_DIR, STATUS_FILE, STOP_GRACE, TEMPLATE_BOUND_FILE, TEMPLATE_READY_FILE,
};
use crate::daemon_spec::{DaemonLayout, daemon_spec, ghostty_version};
use crate::machine::{Action, Input, Observation};
use crate::metadata::{InstanceIdSource, Mmds, read_instance_id};
use crate::retry::{CLOCK_REARM_ATTEMPTS, RearmOutcome, rearm_bounded};
use crate::status::Status;
use fds::{Clock, Epoll, Inotify, Netlink, PidFd, SignalFd, TimerFd};

const T_CLOCK: u64 = 1;
const T_NET: u64 = 2;
const T_INOTIFY: u64 = 3;
const T_SIGNAL: u64 = 4;
const T_REARM: u64 = 5;
const T_BACKOFF: u64 = 6;
const T_STOP: u64 = 7;
const T_DAEMON: u64 = 8;

struct Daemon {
    pid: u32,
    pidfd: PidFd,
    /// `None` when adopted from a previous agent run (not our child).
    child: Option<Child>,
    started: Instant,
}

#[derive(PartialEq, Eq)]
enum JobKind {
    Announce,
    Other,
}

struct Job {
    child: Child,
    kind: JobKind,
}

pub struct LinuxPlatform {
    cfg: Config,
    epoll: Epoll,
    clock: TimerFd,
    clock_armed: bool,
    netlink: Netlink,
    inotify: Inotify,
    wd_run: i32,
    wd_etc: i32,
    /// `server.json`'s directory watch and file name, when it exists.
    config_watch: Option<(i32, std::ffi::OsString)>,
    signals: SignalFd,
    rearm: TimerFd,
    backoff: TimerFd,
    stop_deadline: TimerFd,
    metadata: Box<dyn InstanceIdSource>,
    layout: Option<DaemonLayout>,
    daemon: Option<Daemon>,
    jobs: Vec<Job>,
}

fn read_trimmed(path: PathBuf) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_owned()).filter(|s| !s.is_empty())
}

impl LinuxPlatform {
    /// Opens every descriptor. Blocks SIGTERM, SIGINT and SIGCHLD for the
    /// signalfd, so call it before any thread starts.
    pub fn new(cfg: Config) -> io::Result<Self> {
        let signals = SignalFd::new(&[libc::SIGTERM, libc::SIGINT, libc::SIGCHLD])?;
        let paths = &cfg.paths;
        fs::create_dir_all(paths.at(RUN_DIR))?;
        fs::create_dir_all(paths.at(ETC_DIR))?;
        let inotify = Inotify::new()?;
        let wd_run = inotify.watch_dir(&paths.at(RUN_DIR))?;
        let wd_etc = inotify.watch_dir(&paths.at(ETC_DIR))?;
        let config_watch =
            match cfg.server_config.as_deref().map(|p| paths.at(&p.to_string_lossy())) {
                Some(file) if file.parent().is_some_and(std::path::Path::is_dir) => {
                    let dir = file.parent().expect("checked");
                    let name =
                        file.file_name().map(std::ffi::OsStr::to_os_string).unwrap_or_default();
                    Some((inotify.watch_dir(dir)?, name))
                }
                _ => None,
            };
        let metadata = Box::new(Mmds { addr: cfg.metadata_addr, timeout: cfg.metadata_timeout });
        let platform = Self {
            epoll: Epoll::new()?,
            clock: TimerFd::new(Clock::Realtime)?,
            clock_armed: false,
            netlink: Netlink::new()?,
            inotify,
            wd_run,
            wd_etc,
            config_watch,
            signals,
            rearm: TimerFd::new(Clock::Boottime)?,
            backoff: TimerFd::new(Clock::Monotonic)?,
            stop_deadline: TimerFd::new(Clock::Monotonic)?,
            metadata,
            layout: None,
            daemon: None,
            jobs: Vec::new(),
            cfg,
        };
        let e = &platform.epoll;
        e.add(platform.clock.raw(), T_CLOCK)?;
        e.add(platform.netlink.raw(), T_NET)?;
        e.add(platform.inotify.raw(), T_INOTIFY)?;
        e.add(platform.signals.raw(), T_SIGNAL)?;
        e.add(platform.rearm.raw(), T_REARM)?;
        e.add(platform.backoff.raw(), T_BACKOFF)?;
        e.add(platform.stop_deadline.raw(), T_STOP)?;
        let mut platform = platform;
        platform.arm_clock();
        Ok(platform)
    }

    /// Re-arms the clock-set timer with the bounded `ECANCELED` retry. On
    /// give-up the timer is disarmed (so it cannot stay readable) and the
    /// next wake of any kind tries again.
    fn arm_clock(&mut self) {
        let clock = &self.clock;
        match rearm_bounded(CLOCK_REARM_ATTEMPTS, || clock.arm_clock_set(), || clock.drain()) {
            RearmOutcome::Armed { .. } => self.clock_armed = true,
            RearmOutcome::GaveUp { attempts, last } => {
                let _ = self.clock.disarm();
                self.clock_armed = false;
                eprintln!(
                    "cmux-host: clock-set timer re-arm gave up after {attempts} attempts ({last:?})"
                );
            }
        }
    }

    fn layout(&mut self) -> io::Result<&DaemonLayout> {
        let stale = self.layout.as_ref().is_none_or(|l| !spawn::is_executable(&l.bin));
        if stale {
            self.layout = Some(spawn::select_layout(&self.cfg)?);
        }
        Ok(self.layout.as_ref().expect("selected above"))
    }

    fn inotify_wakes(&mut self, out: &mut Vec<Wake>) -> io::Result<()> {
        for event in self.inotify.read_events()? {
            if event.mask & libc::IN_Q_OVERFLOW != 0 {
                out.push(Wake::DriverFile);
            } else if event.mask & libc::IN_IGNORED != 0
                && (event.wd == self.wd_run || event.wd == self.wd_etc)
            {
                // The directory was removed: recreate it and watch again.
                let dir = if event.wd == self.wd_run { RUN_DIR } else { ETC_DIR };
                let path = self.cfg.paths.at(dir);
                fs::create_dir_all(&path)?;
                let wd = self.inotify.watch_dir(&path)?;
                if dir == RUN_DIR {
                    self.wd_run = wd;
                } else {
                    self.wd_etc = wd;
                }
                out.push(Wake::DriverFile);
            } else if event.wd == self.wd_run && event.name == DRIVER_FILE_NAME {
                out.push(Wake::DriverFile);
            } else if event.wd == self.wd_etc && event.name == BAKE_FILE_NAME {
                out.push(Wake::BakeFile);
            } else if self
                .config_watch
                .as_ref()
                .is_some_and(|(wd, name)| *wd == event.wd && event.name == *name)
            {
                out.push(Wake::ConfigFile);
            }
        }
        Ok(())
    }

    fn spawn_daemon(&mut self) -> io::Result<Option<Input>> {
        let bind = self.cfg.remote_ws_bind.clone();
        let paths = self.cfg.paths.clone();
        let layout = self.layout()?.clone();
        let _ = identity::write_atomic(
            &paths.at(LAYOUT_MARKER_FILE),
            format!("{}\n", layout.kind.as_str()).as_bytes(),
            0o644,
        );
        let version =
            ghostty_version(fs::read_to_string(paths.at(GHOSTTY_VERSION_FILE)).ok().as_deref());
        let spec = daemon_spec(&layout, &version, &bind, &paths.at(TEMPLATE_BOUND_FILE));
        let child = spawn::spawn_daemon(&spec)?;
        let pid = child.id();
        let pidfd = PidFd::open(pid)?;
        self.epoll.add(pidfd.raw(), T_DAEMON)?;
        ensure_agent_dir(&paths)?;
        identity::write_atomic(&paths.at(DAEMON_PID_FILE), format!("{pid}\n").as_bytes(), 0o600)?;
        self.daemon = Some(Daemon { pid, pidfd, child: Some(child), started: Instant::now() });
        Ok(None)
    }

    fn signal_daemon(&self, signal: libc::c_int) -> io::Result<()> {
        match &self.daemon {
            Some(daemon) => daemon.pidfd.signal(signal),
            None => Ok(()),
        }
    }

    fn job(&mut self, program: &str, args: &[String], kind: JobKind, low: bool) -> io::Result<()> {
        let path = spawn::which(program).unwrap_or_else(|| PathBuf::from(program));
        let child = spawn::spawn_job(&path, args, low)?;
        self.jobs.push(Job { child, kind });
        Ok(())
    }

    fn announce(&mut self) -> io::Result<Option<Input>> {
        if !self.cfg.announce || spawn::which("arping").is_none() {
            return Ok(Some(Input::AnnounceDone));
        }
        let mut started = 0;
        for (name, addr) in ipv4_addresses() {
            if is_announce_target(&name, addr)
                && self.job("arping", &arping_args(&name, addr), JobKind::Announce, false).is_ok()
            {
                started += 1;
            }
        }
        Ok((started == 0).then_some(Input::AnnounceDone))
    }

    fn rekey(&mut self, id: &str) -> io::Result<Option<Input>> {
        let mut argv = self.cfg.self_argv.clone();
        if argv.is_empty() {
            argv.push(std::env::current_exe()?.display().to_string());
        }
        let program = argv.remove(0);
        argv.extend([
            "rekey".to_owned(),
            "--root".to_owned(),
            self.cfg.paths.root().display().to_string(),
            id.to_owned(),
        ]);
        let child = spawn::spawn_job(PathBuf::from(program).as_path(), &argv, true)?;
        self.jobs.push(Job { child, kind: JobKind::Other });
        Ok(None)
    }

    fn systemd(&mut self, args: &[&str], background: bool) -> io::Result<Option<Input>> {
        if !spawn::has_systemd(&self.cfg.paths) {
            return Ok(None);
        }
        let args: Vec<String> = args.iter().map(|s| (*s).to_owned()).collect();
        if background {
            self.job("systemctl", &args, JobKind::Other, false)?;
        } else {
            let _ = std::process::Command::new("systemctl").args(&args).status();
        }
        Ok(None)
    }

    fn park_housekeeping(&mut self) -> io::Result<Option<Input>> {
        let mut args = vec!["stop"];
        args.extend(HOUSEKEEPING_TIMERS);
        self.systemd(&args, false)?;
        if spawn::has_systemd(&self.cfg.paths) {
            let _ = std::process::Command::new("systemd-analyze")
                .args(["service-watchdogs", "no"])
                .status();
        }
        Ok(None)
    }

    fn rearm_housekeeping(&mut self) -> io::Result<Option<Input>> {
        if !spawn::has_systemd(&self.cfg.paths) {
            return Ok(None);
        }
        let script = format!(
            "systemd-analyze service-watchdogs yes; systemctl start {}",
            HOUSEKEEPING_TIMERS.join(" ")
        );
        self.job("/bin/sh", &["-c".to_owned(), script], JobKind::Other, true)?;
        Ok(None)
    }

    fn stop_terminal_hosts(&mut self) -> io::Result<Option<Input>> {
        let layout = self.layout()?.clone();
        let keep = if self.cfg.paths.at(TEMPLATE_READY_FILE).exists() {
            procs::template_host_pids(&layout.home)
        } else {
            Vec::new()
        };
        let killed = procs::stop_terminal_hosts(layout.uid, &keep);
        eprintln!("cmux-host: stopped terminal hosts {killed:?}, kept template {keep:?}");
        Ok(None)
    }

    fn notify_ready(&self) {
        let Some(path) = std::env::var_os("NOTIFY_SOCKET") else { return };
        let Ok(socket) = UnixDatagram::unbound() else { return };
        let bytes = path.as_encoded_bytes();
        let sent = if let Some(name) = bytes.strip_prefix(b"@") {
            use std::os::linux::net::SocketAddrExt;
            std::os::unix::net::SocketAddr::from_abstract_name(name)
                .and_then(|addr| socket.send_to_addr(b"READY=1", &addr))
        } else {
            socket.send_to(b"READY=1", &path)
        };
        if let Err(err) = sent {
            eprintln!("cmux-host: sd_notify failed: {err}");
        }
    }

    fn daemon_gone(&mut self) -> Option<Exit> {
        let daemon = self.daemon.take()?;
        self.epoll.remove(daemon.pidfd.raw());
        let _ = fs::remove_file(self.cfg.paths.at(DAEMON_PID_FILE));
        let lived_ms = daemon.started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64;
        eprintln!("cmux-host: session host {} exited after {lived_ms} ms", daemon.pid);
        Some(Exit::Daemon { lived_ms })
    }
}

/// `/run/cmux-host`: root-owned, not writable by anyone else, so the pid
/// file the agent trusts for adoption cannot be planted.
fn ensure_agent_dir(paths: &crate::config::Paths) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let dir = paths.at(AGENT_DIR);
    fs::create_dir_all(&dir)?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755))
}

/// Every IPv4 address with its interface name (`getifaddrs`).
fn ipv4_addresses() -> Vec<(String, std::net::Ipv4Addr)> {
    let mut out = Vec::new();
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs allocates the list freed below; every node is
    // read only while the list is alive.
    unsafe {
        if libc::getifaddrs(&mut head) != 0 {
            return out;
        }
        let mut at = head;
        while !at.is_null() {
            let ifa = &*at;
            if !ifa.ifa_addr.is_null() && i32::from((*ifa.ifa_addr).sa_family) == libc::AF_INET {
                let sin = &*ifa.ifa_addr.cast::<libc::sockaddr_in>();
                let addr = std::net::Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
                let name = std::ffi::CStr::from_ptr(ifa.ifa_name).to_string_lossy().into_owned();
                out.push((name, addr));
            }
            at = ifa.ifa_next;
        }
        libc::freeifaddrs(head);
    }
    out
}

impl Platform for LinuxPlatform {
    fn wait(&mut self) -> io::Result<Vec<Wake>> {
        loop {
            let tokens = self.epoll.wait()?;
            let mut wakes = Vec::new();
            for token in tokens {
                match token {
                    T_CLOCK => {
                        self.clock.drain();
                        self.arm_clock();
                        wakes.push(Wake::ClockSet);
                    }
                    T_NET => {
                        self.netlink.drain();
                        wakes.push(Wake::Address);
                    }
                    T_INOTIFY => self.inotify_wakes(&mut wakes)?,
                    T_SIGNAL => {
                        for signal in self.signals.read_all()? {
                            let signal = signal as libc::c_int;
                            wakes.push(if signal == libc::SIGCHLD {
                                Wake::ProcessExit
                            } else {
                                Wake::Terminate
                            });
                        }
                    }
                    T_REARM => {
                        self.rearm.drain();
                        wakes.push(Wake::Rearm);
                    }
                    T_BACKOFF => {
                        self.backoff.drain();
                        wakes.push(Wake::Backoff);
                    }
                    T_STOP => {
                        self.stop_deadline.drain();
                        wakes.push(Wake::StopDeadline);
                    }
                    T_DAEMON => wakes.push(Wake::ProcessExit),
                    _ => {}
                }
            }
            if !self.clock_armed {
                self.arm_clock();
            }
            if !wakes.is_empty() {
                return Ok(wakes);
            }
        }
    }

    fn reap(&mut self) -> Vec<Exit> {
        let mut exits = Vec::new();
        let daemon_done = match self.daemon.as_mut() {
            Some(Daemon { child: Some(child), .. }) => {
                matches!(child.try_wait(), Ok(Some(_)) | Err(_))
            }
            Some(Daemon { child: None, pidfd, .. }) => pidfd.exited(),
            None => false,
        };
        if daemon_done {
            exits.extend(self.daemon_gone());
        }
        let before = self.jobs.iter().filter(|j| j.kind == JobKind::Announce).count();
        self.jobs.retain_mut(|job| !matches!(job.child.try_wait(), Ok(Some(_)) | Err(_)));
        let after = self.jobs.iter().filter(|j| j.kind == JobKind::Announce).count();
        if before > 0 && after == 0 {
            exits.push(Exit::Announce);
        }
        exits
    }

    fn observe(&mut self) -> Observation {
        let read = read_instance_id(self.metadata.as_mut(), self.cfg.metadata_attempts);
        if read.instance_id.is_none() {
            eprintln!("cmux-host: no instance id after {} metadata attempts", read.attempts);
        }
        Observation {
            instance_id: read.instance_id,
            bake_id: read_trimmed(self.cfg.paths.at(BAKE_INSTANCE_FILE)),
            bound_id: read_trimmed(self.cfg.paths.at(BOUND_INSTANCE_FILE)),
        }
    }

    fn adopt_daemon(&mut self) -> Option<u32> {
        let layout = self.layout().ok()?.clone();
        let (pid, pidfd) =
            procs::find_session_host(&self.cfg.paths.at(DAEMON_PID_FILE), &layout.bin, layout.uid)?;
        self.epoll.add(pidfd.raw(), T_DAEMON).ok()?;
        self.daemon = Some(Daemon { pid, pidfd, child: None, started: Instant::now() });
        Some(pid)
    }

    fn run(&mut self, action: &Action) -> io::Result<Option<Input>> {
        let paths = self.cfg.paths.clone();
        match action {
            Action::Reseed(id) => identity::reseed(id).map(|()| None),
            Action::MarkCloneStarted => identity::mark_clone_started(&paths).map(|()| None),
            Action::DropRemoteIdentity => {
                let home = self.layout()?.home.clone();
                identity::drop_remote_identity(&home).map(|()| None)
            }
            Action::WriteBound(id) => identity::write_bound(&paths, id).map(|()| None),
            Action::SpawnDaemon => self.spawn_daemon(),
            Action::TerminateDaemon => {
                self.stop_deadline.arm_after(STOP_GRACE)?;
                self.signal_daemon(libc::SIGTERM).map(|()| None)
            }
            Action::KillDaemon => self.signal_daemon(libc::SIGKILL).map(|()| None),
            Action::DisarmStopDeadline => self.stop_deadline.disarm().map(|()| None),
            Action::StopTerminalHosts => self.stop_terminal_hosts(),
            Action::Announce => self.announce(),
            Action::Rekey(id) => self.rekey(id),
            Action::RestartPromptSync => {
                self.systemd(&["--no-block", "restart", "cmux-prompt-sync.service"], true)
            }
            Action::ArmRearm => self.rearm.arm_after(self.cfg.rearm_delay).map(|()| None),
            Action::DisarmRearm => self.rearm.disarm().map(|()| None),
            Action::RearmHousekeeping => self.rearm_housekeeping(),
            Action::ParkHousekeeping => self.park_housekeeping(),
            Action::ArmBackoff(ms) => {
                self.backoff.arm_after(std::time::Duration::from_millis(*ms)).map(|()| None)
            }
            Action::DisarmBackoff => self.backoff.disarm().map(|()| None),
            Action::RemoveDriverFile => identity::remove_driver_file(&paths).map(|()| None),
            Action::Ready => {
                self.notify_ready();
                Ok(None)
            }
            Action::StartRoles(_)
            | Action::ParkRoles
            | Action::ShutdownRoles
            | Action::Notify(_)
            | Action::Exit => Ok(None),
        }
    }

    fn daemon_pid(&self) -> Option<u32> {
        self.daemon.as_ref().map(|d| d.pid)
    }

    fn write_status(&mut self, status: &Status) -> io::Result<()> {
        let path = self.cfg.paths.at(STATUS_FILE);
        ensure_agent_dir(&self.cfg.paths)?;
        identity::write_atomic(&path, status.to_json().as_bytes(), 0o644)
    }
}
