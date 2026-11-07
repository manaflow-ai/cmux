//! Which processes are the app's, what kind each is, and their CPU, wakeups
//! and memory per sample.
//!
//! The rules are `scripts/cmux-next/bench_memory.py`'s (`in_bundle`,
//! `kind_of`, `owned`): a process whose executable is under the app bundle is
//! the app's, and so is a `com.apple.WebKit.*` process the app is responsible
//! for (`responsibility_get_pid_responsible_for_pid`, looked up at run time:
//! without it WebKit processes are not attributed, and the summary says so).
//! On Linux (a headless cmux-tui host) the root is the folder above the
//! CLI's `bin`, and only its `cmux*` and `acpmux*` executables count.
//!
//! The process set is read again at every sample, so a process that starts
//! during the window is sampled from then on. A pid is known by its pid and
//! start time, so a reused pid is a new process.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

#[cfg(target_os = "linux")]
#[path = "process_linux.rs"]
mod platform;
#[cfg(target_os = "macos")]
#[path = "process_macos.rs"]
mod platform;

/// Where the processes come from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    /// The `.app` bundle (macOS), or the folder above the `bin` holding cmux.
    pub root: PathBuf,
    /// A process that counts whatever its executable (`--app PID`).
    pub pid: Option<i32>,
}

/// A process's cumulative counters at one moment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Usage {
    /// User plus system CPU time, in nanoseconds.
    pub cpu_ns: u64,
    /// macOS: package idle plus interrupt wakeups. Linux: voluntary plus
    /// involuntary context switches.
    pub wakeups: u64,
    /// macOS: phys_footprint (Activity Monitor's Memory). Linux: resident.
    pub memory: u64,
}

/// One process in a running system: its pid, start time and command line
/// (the executable's path first).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Process {
    pub pid: i32,
    pub start: u64,
    pub command: String,
}

/// Elsewhere nothing is sampled (the summary says the source is unavailable).
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod platform {
    pub fn list() -> Vec<(i32, u64)> {
        Vec::new()
    }

    pub fn command(_pid: i32) -> Option<String> {
        None
    }

    pub fn usage(_pid: i32) -> Option<super::Usage> {
        None
    }

    pub fn executable(_pid: i32) -> Option<std::path::PathBuf> {
        None
    }

    pub fn responsible(_pid: i32) -> Option<i32> {
        None
    }

    pub fn responsibility_available() -> bool {
        false
    }
}

/// Every process now, with its command line where it can be read.
pub fn processes() -> Vec<Process> {
    platform::list()
        .into_iter()
        .map(|(pid, start)| Process {
            pid,
            start,
            command: platform::command(pid).unwrap_or_default(),
        })
        .collect()
}

/// `pid`'s counters, or `None` once it is gone (or not ours to read).
pub fn usage(pid: i32) -> Option<Usage> {
    platform::usage(pid)
}

/// The executable file of `pid`.
pub fn executable(pid: i32) -> Option<PathBuf> {
    platform::executable(pid)
}

/// Whether WebKit processes can be attributed to the app here, and why not.
pub fn webkit_attribution() -> Result<(), &'static str> {
    if platform::responsibility_available() {
        Ok(())
    } else if cfg!(target_os = "macos") {
        Err("responsibility_get_pid_responsible_for_pid is missing on this macOS")
    } else {
        Err("macOS only")
    }
}

/// What the wakeups counter counts here, as a counter name.
pub fn wakeups_name() -> &'static str {
    if cfg!(target_os = "macos") { "wakeups_per_s" } else { "switches_per_s" }
}

/// What the memory counter is here, as a counter name.
pub fn memory_name() -> &'static str {
    if cfg!(target_os = "macos") { "footprint_mb" } else { "rss_mb" }
}

/// `command` relative to `root`, or `None`. The app runs from the real path
/// (`/private/tmp/...`) while its daemons keep the path it handed them
/// (`/tmp/...`), so both spellings count.
pub fn in_bundle<'a>(command: &'a str, root: &str) -> Option<&'a str> {
    [root, root.strip_prefix("/private").unwrap_or(root)]
        .into_iter()
        .find_map(|root| command.strip_prefix(root).filter(|rest| rest.starts_with('/')))
}

/// The kind of a process (`app`, `cef-renderer`, `tui-daemon`,
/// `terminal-host`, `acpmux-<role>`, `webkit-webcontent`, ...).
pub fn kind_of(command: &str, root: &str) -> String {
    let rel = in_bundle(command, root).unwrap_or(command);
    if rel.contains(" Helper") {
        for (flag, name) in [
            ("--type=renderer", "cef-renderer"),
            ("--type=gpu-process", "cef-gpu"),
            ("--type=utility", "cef-utility"),
            ("--type=plugin", "cef-plugin"),
        ] {
            if rel.contains(flag) {
                return name.to_owned();
            }
        }
        return "cef-helper".to_owned();
    }
    if rel.starts_with("/Contents/MacOS/") {
        return "app".to_owned();
    }
    if rel.contains("/bin/cmux-tui") || rel.contains("/bin/cmux ") || rel.ends_with("/bin/cmux") {
        if rel.contains("__terminal-host") {
            return "terminal-host".to_owned();
        }
        if rel.contains("--session cmux-chief") {
            return "tui-daemon-chief".to_owned();
        }
        return "tui-daemon".to_owned();
    }
    if let Some((_, after)) = rel.split_once("/bin/acpmux") {
        return format!("acpmux-{}", after.split_whitespace().next().unwrap_or("agent"));
    }
    if let Some((_, after)) = rel.split_once("/bin/") {
        return after.split_whitespace().next().unwrap_or(after).to_owned();
    }
    if let Some((_, after)) = command.split_once("com.apple.WebKit.") {
        let word = after.split_whitespace().next().unwrap_or("");
        return format!("webkit-{}", word.split('.').next().unwrap_or("").to_lowercase());
    }
    let first = command.split_whitespace().next().unwrap_or(command);
    Path::new(first).file_name().map_or(first, |name| name.to_str().unwrap_or(first)).to_owned()
}

/// Whether a process with `command` under `root` is the app's (WebKit and
/// `--app PID` aside): anything in a `.app` bundle, or a `cmux*` or `acpmux*`
/// in the root's `bin`.
pub fn from_root(command: &str, root: &str) -> bool {
    let Some(rel) = in_bundle(command, root) else { return false };
    if root.ends_with(".app") {
        return true;
    }
    rel.strip_prefix("/bin/")
        .is_some_and(|name| name.starts_with("cmux") || name.starts_with("acpmux"))
}

/// `exec_path arg1 arg2 ...` of a macOS `KERN_PROCARGS2` buffer: argc, the
/// exec path, NUL padding, then argv (argv[0] is dropped: the path says it).
pub fn parse_procargs(buffer: &[u8]) -> Option<String> {
    let argc = i32::from_ne_bytes(buffer.get(..4)?.try_into().ok()?).max(0) as usize;
    let mut rest = &buffer[4..];
    let end = rest.iter().position(|byte| *byte == 0)?;
    let mut words = vec![String::from_utf8_lossy(&rest[..end]).into_owned()];
    rest = &rest[end..];
    let start = rest.iter().position(|byte| *byte != 0).unwrap_or(rest.len());
    let mut args = rest[start..].split(|byte| *byte == 0).take(argc);
    let _argv0 = args.next();
    words.extend(args.map(|word| String::from_utf8_lossy(word).into_owned()));
    Some(words.join(" "))
}

/// The CPU of one core used between two readings `elapsed_ns` apart, in percent.
pub fn cpu_pct(before: &Usage, after: &Usage, elapsed_ns: u64) -> f64 {
    if elapsed_ns == 0 {
        return 0.0;
    }
    after.cpu_ns.saturating_sub(before.cpu_ns) as f64 * 100.0 / elapsed_ns as f64
}

/// How many times a second a counter went up between two readings.
pub fn per_second(before: u64, after: u64, elapsed_ns: u64) -> f64 {
    if elapsed_ns == 0 {
        return 0.0;
    }
    after.saturating_sub(before) as f64 * 1e9 / elapsed_ns as f64
}

/// One process in one sample.
#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    pub pid: i32,
    pub kind: String,
    /// Since the previous sample; `None` in a process's first sample.
    pub cpu_pct: Option<f64>,
    pub wakeups_per_s: Option<f64>,
    pub memory_mb: f64,
}

/// One sample: when it was taken and every process of the app then.
#[derive(Debug, Clone, PartialEq)]
pub struct Tick {
    pub at_us: i64,
    pub rows: Vec<Row>,
}

/// A process the sampler has seen: its start time, kind and whether it is the app's.
struct Known {
    start: u64,
    kind: String,
    command: String,
    from_root: bool,
}

/// Samples the app's processes; keeps what it needs between samples.
pub struct Sampler {
    target: Target,
    root: String,
    known: HashMap<i32, Known>,
    previous: HashMap<i32, (u64, Usage)>,
    /// Every pid sampled at least once, with its kind (for the trace's process names).
    pub seen: Vec<(i32, String)>,
    seen_set: HashSet<i32>,
    webkit: bool,
}

impl Sampler {
    pub fn new(target: Target) -> Self {
        let root = target.root.to_string_lossy().into_owned();
        Self {
            target,
            root,
            known: HashMap::new(),
            previous: HashMap::new(),
            seen: Vec::new(),
            seen_set: HashSet::new(),
            webkit: webkit_attribution().is_ok(),
        }
    }

    /// One sample at `at_us` (wall clock) and `mono_ns` (a monotonic clock, for the rates).
    pub fn sample(&mut self, at_us: i64, mono_ns: u64) -> Tick {
        // Command lines are read once per process: a sample only lists pids and start times.
        let listed = platform::list();
        let live: HashSet<i32> = listed.iter().map(|(pid, _)| *pid).collect();
        self.known.retain(|pid, _| live.contains(pid));
        self.previous.retain(|pid, _| live.contains(pid));
        for (pid, start) in listed {
            if self.known.get(&pid).is_some_and(|known| known.start == start) {
                continue;
            }
            self.previous.remove(&pid);
            let command = platform::command(pid).unwrap_or_default();
            let known = Known {
                start,
                kind: kind_of(&command, &self.root),
                from_root: from_root(&command, &self.root),
                command,
            };
            self.known.insert(pid, known);
        }
        // The app: the target pid, else a process of the bundle's Contents/MacOS.
        let app = self.target.pid.or_else(|| {
            self.known
                .iter()
                .find(|(_, known)| known.from_root && known.kind == "app")
                .map(|(pid, _)| *pid)
        });
        let mut owned: Vec<(i32, String)> = self
            .known
            .iter()
            .filter(|(pid, known)| {
                known.from_root
                    || Some(**pid) == self.target.pid
                    || (self.webkit
                        && app.is_some()
                        && known.command.contains("com.apple.WebKit.")
                        && platform::responsible(**pid) == app)
            })
            .map(|(pid, known)| (*pid, known.kind.clone()))
            .collect();
        owned.sort();
        let mut rows = Vec::new();
        for (pid, kind) in owned {
            let Some(usage) = usage(pid) else { continue };
            let before = self.previous.insert(pid, (mono_ns, usage));
            let rates = before.map(|(then, old)| {
                let elapsed = mono_ns.saturating_sub(then);
                (cpu_pct(&old, &usage, elapsed), per_second(old.wakeups, usage.wakeups, elapsed))
            });
            if self.seen_set.insert(pid) {
                self.seen.push((pid, kind.clone()));
            }
            rows.push(Row {
                pid,
                kind,
                cpu_pct: rates.map(|rates| rates.0),
                wakeups_per_s: rates.map(|rates| rates.1),
                memory_mb: usage.memory as f64 / 1_048_576.0,
            });
        }
        Tick { at_us, rows }
    }
}
