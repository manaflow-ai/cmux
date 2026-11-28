//! The work placer in the command path: what feeds [`work_place::decide`] and what its verdict
//! does to a heavy shell call, behind `CMUX_WORK_PLACER=1` ([`work_place::enabled`]).
//!
//! Leo (2026-11-25): "how does its work auto-route to a bigger vm instead of your local machine?
//! ... what if a user suddently wants to close their computer?"
//!
//! The Claude PreToolUse hook (`bg_hook.rs` `answer`) asks [`hook_goes`] instead of
//! `run_vm::goes` when the switch is on. It samples this host ([`sample`]: load1, PSI and
//! MemAvailable from `/proc` on Linux; load, free memory, battery and lid from `sysctl`,
//! `vm_stat`, `pmset` and `ioreg` on macOS), reads the work's size ([`work_for`]: its class and
//! need from `host_load`, its wall and CPU seconds from the newest `command-placer.jsonl` rows),
//! the chat's machines ([`machines_now`]) and maps the verdict to one of the routes that exist
//! today ([`route`]): run here, or the run-VM fork (`acpmux run-vm`). Each decision writes one row
//! to `$ACPMUX_HOME/work-place.jsonl`: the inputs, the verdict and the route, or why the verdict's
//! place could not be reached.
//!
//! What does not exist yet, so a verdict asking for it runs here or on the fork with the cause on
//! its row: a create-or-grow with a shape (the fork copies this machine's shape), the pool from an
//! agent's call, a serve VM, and any VM for a daemon on the person's Mac (no machine to fork).
//! With the switch off nothing here runs.

use super::command_shadow::Shape;
use super::work_place::{
    self, Class, Host, Machines, Place, Policy, Reason, Verdict, Work, WorkVm,
};
use serde::Serialize;
use serde_json::Value;
use std::path::{Path, PathBuf};

/// What the host sampler reads: files and short commands, so tests feed canned text.
pub trait Probe {
    /// A file's text (`/proc/loadavg`), or None when it cannot be read.
    fn read(&self, path: &str) -> Option<String>;
    /// A command's stdout (`pmset -g batt`), or None when it did not run or failed.
    fn run(&self, program: &str, args: &[&str]) -> Option<String>;
    fn ncpu(&self) -> f64;
}

/// The real host.
pub struct System;

impl Probe for System {
    fn read(&self, path: &str) -> Option<String> {
        std::fs::read_to_string(path).ok()
    }

    fn run(&self, program: &str, args: &[&str]) -> Option<String> {
        let out = std::process::Command::new(program)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
    }

    fn ncpu(&self) -> f64 {
        std::thread::available_parallelism().map_or(1, usize::from) as f64
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    Linux,
    Mac,
}

impl Os {
    pub fn this() -> Self {
        if cfg!(target_os = "macos") { Os::Mac } else { Os::Linux }
    }
}

/// This host now. A reading that fails leaves its field at the quiet value (no load, no PSI,
/// plenty of memory, on power, lid open): a sampler that cannot see never moves work.
pub fn sample(probe: &dyn Probe, os: Os) -> Host {
    let mut host = Host {
        ncpu: probe.ncpu(),
        load1: 0.0,
        psi_cpu_some10: None,
        mem_available_gib: f64::INFINITY,
        sleeping: false,
        on_battery: false,
        battery_percent: None,
        person_cpu_share: 0.0,
        person_heavy: false,
    };
    match os {
        Os::Linux => {
            if let Some(l) = probe.read("/proc/loadavg").as_deref().and_then(loadavg) {
                host.load1 = l;
            }
            host.psi_cpu_some10 = probe.read("/proc/pressure/cpu").as_deref().and_then(psi_some10);
            if let Some(m) = probe.read("/proc/meminfo").as_deref().and_then(mem_available_gib) {
                host.mem_available_gib = m;
            }
        }
        Os::Mac => {
            if let Some(l) =
                probe.run("sysctl", &["-n", "vm.loadavg"]).as_deref().and_then(mac_loadavg)
            {
                host.load1 = l;
            }
            if let Some(m) = probe.run("vm_stat", &[]).as_deref().and_then(vm_stat_free_gib) {
                host.mem_available_gib = m;
            }
            if let Some((on_battery, percent)) =
                probe.run("pmset", &["-g", "batt"]).as_deref().map(pmset_batt)
            {
                host.on_battery = on_battery;
                host.battery_percent = percent;
            }
            host.sleeping = probe
                .run("ioreg", &["-r", "-k", "AppleClamshellState", "-d", "1"])
                .as_deref()
                .is_some_and(lid_closed);
        }
    }
    host
}

/// `/proc/loadavg`'s first field.
pub fn loadavg(text: &str) -> Option<f64> {
    text.split_whitespace().next()?.parse().ok()
}

/// `sysctl -n vm.loadavg`: `{ 1.23 1.10 1.00 }`.
pub fn mac_loadavg(text: &str) -> Option<f64> {
    text.split_whitespace().find(|w| *w != "{")?.parse().ok()
}

/// `/proc/pressure/cpu`'s `some avg10=`.
pub fn psi_some10(text: &str) -> Option<f64> {
    let line = text.lines().find(|l| l.starts_with("some "))?;
    line.split_whitespace().find_map(|w| w.strip_prefix("avg10="))?.parse().ok()
}

/// `/proc/meminfo`'s `MemAvailable`, in GiB.
pub fn mem_available_gib(text: &str) -> Option<f64> {
    let line = text.lines().find(|l| l.starts_with("MemAvailable:"))?;
    let kib: f64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kib / (1024.0 * 1024.0))
}

/// `/proc/meminfo`'s `MemTotal`, in GiB.
pub fn mem_total_gib(text: &str) -> Option<f64> {
    let line = text.lines().find(|l| l.starts_with("MemTotal:"))?;
    let kib: f64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kib / (1024.0 * 1024.0))
}

/// `vm_stat`: free, inactive, speculative and purgeable pages, in GiB.
pub fn vm_stat_free_gib(text: &str) -> Option<f64> {
    let page: f64 = text
        .lines()
        .next()?
        .split("page size of ")
        .nth(1)?
        .split_whitespace()
        .next()?
        .parse()
        .ok()?;
    let pages = |name: &str| -> f64 {
        text.lines()
            .find(|l| l.starts_with(name))
            .and_then(|l| l.rsplit(':').next())
            .and_then(|v| v.trim().trim_end_matches('.').parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    let free = pages("Pages free")
        + pages("Pages inactive")
        + pages("Pages speculative")
        + pages("Pages purgeable");
    Some(free * page / (1024.0 * 1024.0 * 1024.0))
}

/// `pmset -g batt`: on battery, and the internal battery's percent when it has one.
pub fn pmset_batt(text: &str) -> (bool, Option<u8>) {
    let on_battery = text.contains("'Battery Power'");
    let percent = text.lines().find(|l| l.contains("InternalBattery")).and_then(|l| {
        let head = l.split('%').next().filter(|_| l.contains('%'))?;
        let digits: String = head
            .chars()
            .rev()
            .take_while(char::is_ascii_digit)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        digits.parse().ok()
    });
    (on_battery, percent)
}

/// `ioreg -r -k AppleClamshellState`: the lid is shut.
pub fn lid_closed(text: &str) -> bool {
    text.lines().any(|l| l.contains("\"AppleClamshellState\"") && l.trim_end().ends_with("Yes"))
}

/// The pool's queue class of a shell command: its heavy program's.
pub fn class_of(command: &str) -> Class {
    let mut class = Class::Other;
    crate::host_load::for_each_command(command, &mut |argv: &[&str]| {
        if class != Class::Other {
            return;
        }
        let program = argv.first().map(|w| w.rsplit('/').next().unwrap_or(w)).unwrap_or_default();
        class = match program {
            "cargo" => Class::Rust,
            "swift" | "xcodebuild" => Class::Swift,
            _ => Class::Other,
        };
    });
    class
}

/// The agent session's own share, which `host_load`'s needs sit on top of.
const SESSION: Shape = Shape { vcpu: 2.0, mem_gib: 2.0 };

/// What one of this class's past runs took: wall and CPU seconds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Past {
    pub wall_s: f64,
    pub cpu_s: Option<f64>,
}

/// The work `command` is: its class, need, and the median of its class's newest runs.
pub fn work_for(command: &str, past: &[Past]) -> Work {
    let need = crate::host_load::classify_command(command).map(|h| Shape {
        vcpu: SESSION.vcpu + f64::from(h.need.vcpu),
        mem_gib: SESSION.mem_gib + f64::from(h.need.mem_gib),
    });
    let median = |mut v: Vec<f64>| {
        v.sort_by(f64::total_cmp);
        v.get(v.len() / 2).copied()
    };
    Work {
        class: class_of(command),
        local_s: median(past.iter().map(|p| p.wall_s).collect()),
        need,
        cpu_s: median(past.iter().filter_map(|p| p.cpu_s).collect()),
        // Servers never reach here: `run_vm::heavy_class` takes builds and test runs only.
        listens: false,
    }
}

/// How much of `command-placer.jsonl` the hook reads: a constant cost however long the file grows.
pub const HISTORY_TAIL_BYTES: u64 = 256 << 10;
/// Runs of a class the prediction looks at.
pub const HISTORY_RUNS: usize = 5;

/// The newest [`HISTORY_RUNS`] runs of `command`'s class in the sampler's rows file's tail.
pub fn history(path: &Path, command: &str) -> Vec<Past> {
    use std::io::{Read, Seek, SeekFrom};
    let class = super::command_shadow::class_of(command);
    let Ok(mut file) = std::fs::File::open(path) else { return Vec::new() };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    let from = len.saturating_sub(HISTORY_TAIL_BYTES);
    if file.seek(SeekFrom::Start(from)).is_err() {
        return Vec::new();
    }
    let mut text = String::new();
    if file.take(HISTORY_TAIL_BYTES).read_to_string(&mut text).is_err() {
        return Vec::new();
    }
    let mut runs: Vec<Past> = text
        .lines()
        .skip(usize::from(from > 0))
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|row| row.get("class").and_then(Value::as_str) == Some(class.as_str()))
        .filter_map(|row| {
            let wall_s = row.get("wallS").and_then(Value::as_f64)?;
            let cpu_s = row.pointer("/usage/cpuS").and_then(Value::as_f64);
            Some(Past { wall_s, cpu_s })
        })
        .collect();
    let keep = runs.len().saturating_sub(HISTORY_RUNS);
    runs.drain(..keep);
    runs
}

/// The chat's machines: on a Cloud machine, this machine is its work VM, its shape this host's.
/// Nothing pins a chat yet (S11 waits on a by-hand machine's mark).
pub fn machines_now(machine: Option<&str>, host: &Host, mem_total_gib: Option<f64>) -> Machines {
    let work_vm = machine.filter(|m| !m.trim().is_empty()).map(|_| WorkVm {
        shape: Shape { vcpu: host.ncpu, mem_gib: mem_total_gib.unwrap_or(host.mem_available_gib) },
        paused: false,
    });
    Machines { work_vm, pinned: None }
}

/// What the hook does with a verdict, over the APIs that exist.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "route", content = "cause")]
pub enum Route {
    /// Run the call as asked.
    Here,
    /// Rewrite it into `acpmux run-vm`: a fork of this machine runs it.
    Fork,
    /// The verdict's place has no API from here yet: run it here, the cause on the row.
    Unreached(&'static str),
}

/// Where `verdict` sends the call from `machine` (this Cloud machine, or None on a person's
/// computer).
pub fn route(verdict: &Verdict, machine: Option<&str>) -> Route {
    let cloud = machine.is_some_and(|m| !m.trim().is_empty());
    match verdict.place {
        Place::Local => Route::Here,
        // The work VM is this machine: kept there (S2, S11), it runs here. Sent there because
        // this machine is short (stretch, memory, the lid), a fork of it is a VM of the same
        // shape with nothing else on it.
        Place::WorkVm { .. } if cloud => match verdict.reason {
            Reason::OnVm | Reason::Pinned | Reason::Fits => Route::Here,
            _ => Route::Fork,
        },
        Place::WorkVm { .. } => Route::Unreached("no work VM for this computer yet"),
        // The fork copies this machine's shape: the work gets a whole machine to itself, not the
        // bigger shape asked for, until a create-or-grow with a shape exists.
        Place::Grow { .. } | Place::BiggerVm { .. } | Place::Pool if cloud => Route::Fork,
        Place::Grow { .. } | Place::BiggerVm { .. } => {
            Route::Unreached("no VM create with a shape from this computer yet")
        }
        Place::Pool => Route::Unreached("no pool dispatch from an agent's call yet"),
        Place::ServeVm => Route::Unreached("no serve VMs yet"),
    }
}

/// One `work-place.jsonl` row.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row<'a> {
    pub class: &'static str,
    pub work: &'a Work,
    pub host: &'a Host,
    pub machines: &'a Machines,
    pub verdict: &'a Verdict,
    #[serde(flatten)]
    pub route: &'a Route,
}

/// The rows file: `$ACPMUX_HOME/work-place.jsonl`.
pub fn rows_path() -> PathBuf {
    crate::config::home().join("work-place.jsonl")
}

fn write_row(row: &Row<'_>) {
    let mut v = serde_json::to_value(row).unwrap_or_default();
    if let Some(o) = v.as_object_mut() {
        // An unread memory figure (infinite) is written as null.
        o.insert("at".into(), serde_json::json!(chrono::Utc::now().to_rfc3339()));
    }
    let path = rows_path();
    if let Some(dir) = path.parent() {
        let _ = crate::home_fs::create_dirs(dir);
    }
    if let Ok(mut f) = crate::home_fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = std::io::Write::write_all(&mut f, format!("{v}\n").as_bytes());
    }
}

/// The decision for one call from its inputs: pure, so each branch is tested.
pub fn place(command: &str, host: &Host, machines: &Machines, past: &[Past]) -> (Work, Verdict) {
    let work = work_for(command, past);
    let verdict = work_place::decide(&work, host, machines, &Policy::default());
    (work, verdict)
}

/// The hook's question with the placer on: the heavy class when `command` goes to the fork, else
/// None (it runs as asked). The run-VM kill switch still keeps every call here. Writes its row.
pub fn hook_goes(on: bool, machine: Option<&str>, command: &str) -> Option<&'static str> {
    let class = super::run_vm::heavy_class(command)?;
    if !on {
        return None;
    }
    let host = sample(&System, Os::this());
    let total = System.read("/proc/meminfo").as_deref().and_then(mem_total_gib);
    let machines = machines_now(machine, &host, total);
    let past = history(&super::command_sampler::file_path(), command);
    let (work, verdict) = place(command, &host, &machines, &past);
    let route = route(&verdict, machine);
    write_row(&Row {
        class,
        work: &work,
        host: &host,
        machines: &machines,
        verdict: &verdict,
        route: &route,
    });
    (route == Route::Fork).then_some(class)
}

#[cfg(test)]
#[path = "work_wire_tests.rs"]
mod tests;
