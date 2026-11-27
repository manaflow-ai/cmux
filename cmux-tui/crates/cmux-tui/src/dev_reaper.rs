//! `__dev-reaper`: ends every process a tagged DEV build started once that build's app exits
//! (https://github.com/manaflow-ai/cmux/issues/55842).
//!
//! A cmux NEXT app starts its helpers detached on purpose: the terminal owner (`cmux-tui
//! --headless`, `setsid`), acpmux and the Chief host (`/bin/sh -c 'set -m; … &'`), each under
//! `cmux-files-host run/host` in a Debug DEV build. A shipped app wants that: terminals and agents
//! outlive a quit and the next launch picks them up. A tagged DEV build does not: an agent builds
//! it, uses it, quits it or replaces it with `reload.sh`, and every build left its tree running
//! (one Mac held 136 processes for 7 quit builds, and one kept posting notifications).
//!
//! So a tagged DEV app starts this mode at launch (`DevBuildReaper.swift`), detached from it. It
//! waits for the app's process to exit, however it exits (Cmd-Q, the end-sessions quit, the
//! SIGTERM `reload.sh` sends, a crash, SIGKILL), then ends the build's tree:
//!
//! - **Which processes.** Every process whose executable is in the bundle, every shared
//!   `cmux-files-host host -- <bundle>/…` copy, every cmux terminal holder or host that names the
//!   build as its owner (`--owner <bundle id>:…`: they run from a copy outside the bundle and
//!   outlive a restarted daemon), and every descendant of one (shells, agents). A shell or agent
//!   that only names the bundle in an argument is not one. The reaper itself is spared.
//! - **Never a newer instance.** When another process runs the bundle's own app executable
//!   (`<bundle>/Contents/MacOS/…`), the tree belongs to it (a second launch shares the
//!   daemons), and nothing is ended. Only processes seen in the snapshot taken at exit are
//!   signaled, and a pid is SIGKILLed only when it still shows the same command line.
//! - **How.** SIGTERM to all of them at once (the helpers' own clean exit), a grace period, then
//!   SIGKILL to what is left. A process that a dying one started meanwhile (a hook that restarts
//!   acpmux) is caught by a second round, up to [`ROUNDS`].
//!
//! `CMUX_DEV_KEEP_HELPERS=1` in the app's environment keeps the old behaviour (the app does not
//! start the reaper), for testing that terminals survive a quit.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

/// The argv mode (private_mode.rs).
pub(crate) const MODE: &str = "__dev-reaper";

/// Grace between SIGTERM and SIGKILL when `--grace-ms` is absent.
const DEFAULT_GRACE: Duration = Duration::from_secs(5);
/// Passes over the process table: a helper that restarts another while it dies is caught by the
/// next one.
const ROUNDS: usize = 3;

/// One row of the process table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Process {
    pub pid: i32,
    pub ppid: i32,
    pub command: String,
    /// The executable's path (`ps -o comm=`), which an argument cannot spoof.
    pub exe: String,
}

/// What the reaper was asked to do.
#[derive(Debug, PartialEq, Eq)]
struct Options {
    app_pid: Option<i32>,
    bundle: String,
    bundle_id: Option<String>,
    grace: Duration,
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut app_pid = None;
    let mut bundle = None;
    let mut bundle_id = None;
    let mut grace = DEFAULT_GRACE;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let mut value = || rest.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--app-pid" => {
                let pid: i32 = value()?.parse().map_err(|_| "--app-pid takes a pid".to_owned())?;
                if pid <= 1 {
                    return Err("--app-pid takes a pid above 1".into());
                }
                app_pid = Some(pid);
            }
            "--bundle" => bundle = Some(value()?.clone()),
            "--bundle-id" => {
                let id = value()?.clone();
                if id.is_empty() || id.contains(char::is_whitespace) || id.contains(':') {
                    return Err(format!("--bundle-id takes a bundle id, not {id:?}"));
                }
                bundle_id = Some(id);
            }
            "--grace-ms" => {
                let ms: u64 =
                    value()?.parse().map_err(|_| "--grace-ms takes milliseconds".to_owned())?;
                grace = Duration::from_millis(ms);
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    let bundle = bundle.ok_or("--bundle is required")?;
    let bundle = bundle.trim_end_matches('/').to_owned();
    if !bundle.starts_with('/') || !bundle.ends_with(".app") {
        return Err(format!("--bundle must be an absolute .app path, not {bundle}"));
    }
    Ok(Options { app_pid, bundle, bundle_id, grace })
}

/// `__dev-reaper --bundle PATH [--bundle-id ID] [--app-pid PID] [--grace-ms MS]`: waits for PID to exit (no
/// PID: at once), then ends the bundle's tree.
pub(crate) fn run(args: &[String]) -> i32 {
    let options = match parse(args) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("cmux-tui {MODE}: {error}");
            return 2;
        }
    };
    // The app's quit must never end the reaper through its group or terminal.
    // SAFETY: SIG_IGN for catchable signals.
    unsafe {
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
        libc::signal(libc::SIGINT, libc::SIG_IGN);
    }
    if let Some(pid) = options.app_pid {
        wait_for_exit(pid);
    }
    let own = std::process::id() as i32;
    let build = Build::new(&options.bundle, options.bundle_id.as_deref());
    let ended = reap(&build, own, options.grace, &mut SystemTable);
    eprintln!("cmux-tui {MODE}: {} ended {} process(es)", options.bundle, ended.len());
    0
}

/// The process table and signals, so the policy is tested without real processes.
pub(crate) trait Table {
    fn snapshot(&mut self) -> Vec<Process>;
    fn signal(&mut self, pid: i32, signal: i32);
    fn alive(&mut self, pid: i32) -> bool;
    fn sleep(&mut self, duration: Duration);
}

/// Ends the bundle's tree in up to [`ROUNDS`] passes; returns every pid it signaled.
pub(crate) fn reap(build: &Build, own: i32, grace: Duration, table: &mut impl Table) -> Vec<i32> {
    let mut ended = Vec::new();
    for _ in 0..ROUNDS {
        let processes = table.snapshot();
        let targets = targets(build, own, &processes);
        if targets.is_empty() {
            break;
        }
        for process in &targets {
            table.signal(process.pid, libc::SIGTERM);
        }
        let step = Duration::from_millis(100);
        let mut waited = Duration::ZERO;
        while waited < grace && targets.iter().any(|p| table.alive(p.pid)) {
            table.sleep(step);
            waited += step;
        }
        // SIGKILL only a pid that still runs the same command: never one reused meanwhile.
        let now: BTreeMap<i32, String> =
            table.snapshot().into_iter().map(|p| (p.pid, p.command)).collect();
        for process in &targets {
            if now.get(&process.pid) == Some(&process.command) {
                table.signal(process.pid, libc::SIGKILL);
            }
        }
        ended.extend(targets.iter().map(|p| p.pid));
    }
    ended
}

/// The processes to end: none while another instance of the app runs; otherwise every process
/// naming the bundle and all their descendants, except `own`.
///
/// The bundle is matched by its name (`/cmux DEV <tag>.app/`), not its whole path: a helper may
/// name it through another spelling of the same folder (`/private/tmp` for `/tmp`), and every
/// copy of one tag is the same build.
pub(crate) fn targets(build: &Build, own: i32, processes: &[Process]) -> Vec<Process> {
    if processes.iter().any(|p| p.pid != own && runs_app(&p.exe, &build.marker)) {
        return Vec::new();
    }
    // Another reaper (a newer instance's, or a second start) ends on its own.
    let reaper = format!(" {MODE}");
    let spared = |p: &Process| p.pid == own || p.pid <= 1 || p.command.contains(&reaper);
    let mut chosen: BTreeSet<i32> =
        processes.iter().filter(|p| !spared(p) && build.names(p)).map(|p| p.pid).collect();
    let mut children: BTreeMap<i32, Vec<i32>> = BTreeMap::new();
    for process in processes {
        children.entry(process.ppid).or_default().push(process.pid);
    }
    let by_pid: BTreeMap<i32, &Process> = processes.iter().map(|p| (p.pid, p)).collect();
    let mut queue: Vec<i32> = chosen.iter().copied().collect();
    while let Some(pid) = queue.pop() {
        for &child in children.get(&pid).map(Vec::as_slice).unwrap_or_default() {
            if by_pid.get(&child).is_some_and(|p| !spared(p)) && chosen.insert(child) {
                queue.push(child);
            }
        }
    }
    processes.iter().filter(|p| chosen.contains(&p.pid)).cloned().collect()
}

/// How a build's processes name it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Build {
    /// `/<bundle name>/`, as in `/cmux DEV <tag>.app/`.
    marker: String,
    /// `--owner <bundle id>:`, as a terminal holder or host names its daemon's app.
    owner: Option<String>,
}

impl Build {
    pub(crate) fn new(bundle: &str, bundle_id: Option<&str>) -> Self {
        let name = bundle.trim_end_matches('/').rsplit('/').next().unwrap_or(bundle);
        Self { marker: format!("/{name}/"), owner: bundle_id.map(|id| format!("--owner {id}:")) }
    }

    /// Whether the build started `p`: its executable is inside the bundle; it is the shared
    /// `cmux-files-host host` copy running a program of the bundle; or it is one of cmux's own
    /// executables (a terminal holder or host) that names the app as its owner. A shell or an
    /// agent's command that only mentions the bundle in an argument never matches by itself.
    fn names(&self, p: &Process) -> bool {
        let base = p.exe.rsplit('/').next().unwrap_or(&p.exe);
        p.exe.contains(&self.marker)
            || (base == "cmux-files-host" && p.command.contains(&self.marker))
            || (base.starts_with("cmux")
                && self.owner.as_ref().is_some_and(|owner| p.command.contains(owner)))
    }
}

/// Whether `exe` is the app's own executable: its first `.app/Contents/` is the bundle's
/// (`marker`) and goes on to `MacOS/`. A helper inside it (`Contents/Resources/bin/…`, the
/// nested `Contents/Library/cmux Files (dev).app/Contents/MacOS/…`) is not the app.
fn runs_app(exe: &str, marker: &str) -> bool {
    const CONTENTS: &str = ".app/Contents/";
    let Some(first) = exe.find(CONTENTS) else { return false };
    exe[..first + ".app/".len()].ends_with(marker)
        && exe[first + CONTENTS.len()..].starts_with("MacOS/")
}

/// Joins `ps -axww -o pid=,ppid=,command=` (`commands`) with `ps -axww -o pid=,comm=`
/// (`executables`) by pid; a process missing from either listing is left out.
pub(crate) fn parse_ps(commands: &str, executables: &str) -> Vec<Process> {
    let split = |line: &str| -> Option<(i32, String)> {
        let line = line.trim_start();
        let (pid, rest) = line.split_once(char::is_whitespace).unwrap_or((line, ""));
        Some((pid.parse().ok()?, rest.trim_start().to_owned()))
    };
    let exes: BTreeMap<i32, String> = executables.lines().filter_map(split).collect();
    commands
        .lines()
        .filter_map(|line| {
            let (pid, rest) = split(line)?;
            let (ppid, command) = rest.split_once(char::is_whitespace).unwrap_or((&rest, ""));
            Some(Process {
                pid,
                ppid: ppid.parse().ok()?,
                command: command.trim_start().to_owned(),
                exe: exes.get(&pid)?.clone(),
            })
        })
        .collect()
}

struct SystemTable;

impl Table for SystemTable {
    fn snapshot(&mut self) -> Vec<Process> {
        // The one process listing in cmux-next that is not a ratchet to remove
        // (scripts/cmux-next/process-scan-baseline.tsv, `keep`): it runs in a DEV build only,
        // after the app has exited, when no registry is left to ask, to end that build's tree.
        let ps = |columns: &str| match cmux_process::Command::new("/bin/ps")
            .args(["-axww", "-o", columns])
            .stdin(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::null())
            .output()
        {
            Ok(output) => Some(String::from_utf8_lossy(&output.stdout).into_owned()),
            Err(error) => {
                eprintln!("cmux-tui {MODE}: cannot list processes: {error}");
                None
            }
        };
        match (ps("pid=,ppid=,command="), ps("pid=,comm=")) {
            (Some(commands), Some(executables)) => parse_ps(&commands, &executables),
            _ => Vec::new(),
        }
    }

    fn signal(&mut self, pid: i32, signal: i32) {
        // SAFETY: a signal to one positive pid.
        unsafe { libc::kill(pid, signal) };
    }

    fn alive(&mut self, pid: i32) -> bool {
        // SAFETY: signal 0 only checks the pid.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    fn sleep(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// Blocks until `pid` exits (at once when it already has).
#[cfg(target_os = "macos")]
fn wait_for_exit(pid: i32) {
    // SAFETY: kqueue has no preconditions; closed below.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return poll_for_exit(pid);
    }
    let change = libc::kevent {
        ident: pid as usize,
        filter: libc::EVFILT_PROC,
        flags: libc::EV_ADD | libc::EV_ONESHOT,
        fflags: libc::NOTE_EXIT,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    // SAFETY: one valid change, no events out.
    let registered = unsafe {
        libc::kevent(queue, &raw const change, 1, std::ptr::null_mut(), 0, std::ptr::null())
    } == 0;
    if registered {
        loop {
            // SAFETY: a zeroed kevent is a valid out buffer.
            let mut out: libc::kevent = unsafe { std::mem::zeroed() };
            // SAFETY: one out event, no changes, no timeout.
            let count = unsafe {
                libc::kevent(queue, std::ptr::null(), 0, &raw mut out, 1, std::ptr::null())
            };
            if count > 0 {
                break;
            }
            if count < 0
                && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
            {
                // SAFETY: closes the queue opened above.
                unsafe { libc::close(queue) };
                return poll_for_exit(pid);
            }
        }
    }
    // SAFETY: closes the queue opened above.
    unsafe { libc::close(queue) };
}

#[cfg(not(target_os = "macos"))]
fn wait_for_exit(pid: i32) {
    poll_for_exit(pid);
}

fn poll_for_exit(pid: i32) {
    // SAFETY: signal 0 only checks the pid.
    while unsafe { libc::kill(pid, 0) } == 0 {
        std::thread::sleep(Duration::from_millis(500));
    }
}

#[cfg(test)]
#[path = "dev_reaper_tests.rs"]
mod tests;
