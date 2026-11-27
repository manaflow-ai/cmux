//! The known-heavy precheck (cmuxterm-hq RFD 0133, "The warning", row "Known-heavy job"): before
//! an agent's shell command runs, whether it is a build this machine is too small for, read
//! from the command line and the machine's shape alone. It is the one warning that fires before
//! anything is lost, and it is a string match.
//!
//! Two kinds of match:
//! - a project with published minimums: Chromium (`fetch chromium`, `autoninja`,
//!   `ninja -C out/...`; 100 GB of disk, 16 GB of memory), LLVM (`cmake` of `llvm`, or a build
//!   in an `llvm-project` checkout; 15 to 20 GB of disk) and rustc (`x.py build`; 30 GB of disk,
//!   8 GB of memory). It warns when the machine has less free disk or less memory than that.
//! - a big build in a big checkout: `bazel build //...`, `cargo build` or `make -j`, when the
//!   checkout is bigger than the machine's free memory times [`CHECKOUT_PER_FREE_MEMORY`].
//!
//! Pure: the caller reads the shape (`/proc/meminfo`, `nproc`, `statvfs`) and the checkout's size.
//! The text is the chat row's first line. RFD 0144 turns RFD 0133's three buttons into a notice
//! row ([`notice`]) and its build machine into a run VM sized to the project's minimum
//! ([`memory_floor`]).

use serde::Serialize;

/// Checkout bytes per byte of free memory past which a `cargo build`, `make -j` or
/// `bazel build //...` warns (RFD 0133's table, an assumption marked [a] there).
pub const CHECKOUT_PER_FREE_MEMORY: u64 = 8;
/// A machine sold with N GB of memory shows a little less in `MemTotal` (the kernel's own); this
/// much short of a minimum still meets it.
const MEMORY_SLACK: f64 = 0.95;
/// Chromium's CPU-hours for a full build: 21 on a 4-core laptop to 46 on 64 cores; about 40 on
/// a 12-core i9 (randomascii.wordpress.com, 2020), the middle one.
const CHROMIUM_CPU_HOURS: f64 = 40.0;
/// The burst size the row quotes a time and a price for.
const BURST_VCPU: u32 = 32;
const BURST_MEM_GIB: u32 = 64;
/// cmux's unit rate at every size (RFD 0063, 0133): per vCPU-hour and per GiB-hour.
pub const VCPU_HOUR_USD: f64 = 0.045;
pub const GIB_HOUR_USD: f64 = 0.0145;

const GB: u64 = 1_000_000_000;
const GIB: u64 = 1 << 30;

/// The machine the command would run on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Shape {
    pub vcpu: u32,
    /// `MemTotal`, bytes.
    pub mem_total: u64,
    /// `MemAvailable`, bytes; None reads as `mem_total`.
    pub mem_available: Option<u64>,
    /// Free bytes on the disk the command writes (`statvfs` of its directory).
    pub disk_free: u64,
}

/// Where the command runs, as far as the caller knows it.
#[derive(Debug, Clone, Copy, Default)]
pub struct Place<'a> {
    /// The command's working directory.
    pub cwd: Option<&'a str>,
    /// The size of the checkout it builds, bytes.
    pub checkout_bytes: Option<u64>,
}

/// A project that publishes what a build of it needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Project {
    Chromium,
    Llvm,
    Rustc,
}

impl Project {
    pub fn name(self) -> &'static str {
        match self {
            Self::Chromium => "Chromium",
            Self::Llvm => "LLVM",
            Self::Rustc => "rustc",
        }
    }

    /// (disk bytes, memory bytes) its docs ask for: Chromium's `docs/linux/build_instructions.md`
    /// ("at least 100GB of free disk space", "More than 16GB is highly recommended"), LLVM's
    /// GettingStarted (15 to 20 GB for a debug build; the top), the rustc-dev-guide (30 GB, 8 GB).
    pub fn minimums(self) -> (u64, Option<u64>) {
        match self {
            Self::Chromium => (100 * GB, Some(16 * GB)),
            Self::Llvm => (20 * GB, None),
            Self::Rustc => (30 * GB, Some(8 * GB)),
        }
    }

    fn disk_text(self) -> &'static str {
        match self {
            Self::Llvm => "15 to 20 GB",
            Self::Chromium => "100 GB",
            Self::Rustc => "30 GB",
        }
    }
}

/// What the machine is short of.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Short {
    Disk,
    Memory,
}

/// The warning row's facts and its first line.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Warning {
    /// The simple command that matched, its words joined (`fetch --nohooks chromium`).
    pub command: String,
    /// The project whose minimums it misses; None for a big checkout.
    pub project: Option<Project>,
    pub short: Vec<Short>,
    /// Free disk it asks for, bytes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub needs_disk: Option<u64>,
    /// Memory it asks for, bytes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub needs_memory: Option<u64>,
    pub text: String,
}

/// What a simple command is, if it is a known-heavy one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Job {
    Project(Project),
    BigBuild,
}

/// The warning for `script` (a shell command, as the agent's tool call names it) on a machine
/// of `shape` at `place`, or None when it is not a known-heavy job or the machine is big enough.
/// Of several simple commands the first that warns wins.
pub fn precheck(script: &str, shape: &Shape, place: &Place<'_>) -> Option<Warning> {
    let mut found = None;
    crate::host_load::for_each_command(script, &mut |argv| {
        if found.is_none()
            && let Some(job) = job_of(argv, place.cwd)
        {
            found = warn(job, argv, shape, place);
        }
    });
    found
}

/// The warning for an ACP tool call (`tool_call` or `tool_call_update`) of kind `execute`: its
/// `rawInput.command`, a script or an argv.
pub fn precheck_tool(
    update: &serde_json::Value,
    shape: &Shape,
    place: &Place<'_>,
) -> Option<Warning> {
    use serde_json::Value;
    if update.get("kind").and_then(Value::as_str).is_some_and(|k| k != "execute") {
        return None;
    }
    let script = match update.pointer("/rawInput/command")? {
        Value::String(script) => script.clone(),
        Value::Array(argv) => argv
            .iter()
            .filter_map(Value::as_str)
            .map(|w| format!("'{}'", w.replace('\'', r"'\''")))
            .collect::<Vec<_>>()
            .join(" "),
        _ => return None,
    };
    let cwd = place.cwd.or_else(|| update.pointer("/rawInput/cwd").and_then(Value::as_str));
    precheck(&script, shape, &Place { cwd, ..*place })
}

/// The memory a known-heavy command's project publishes as its minimum, the floor a sized run VM
/// starts at (RFD 0144 piece 8): Chromium's 16 GB, rustc's 8 GB. None for anything else (LLVM
/// publishes only disk, which the fork ladder does not size). Of several simple commands the
/// largest floor wins.
pub fn memory_floor(script: &str, cwd: Option<&str>) -> Option<(Project, u64)> {
    let mut floor: Option<(Project, u64)> = None;
    crate::host_load::for_each_command(script, &mut |argv| {
        if let Some(Job::Project(project)) = job_of(argv, cwd)
            && let (_, Some(memory)) = project.minimums()
            && floor.is_none_or(|(_, m)| memory > m)
        {
            floor = Some((project, memory));
        }
    });
    floor
}

/// Whether `script` runs a known-heavy job at all, before any shape is read.
pub fn is_known_heavy(script: &str, cwd: Option<&str>) -> bool {
    let mut found = false;
    crate::host_load::for_each_command(script, &mut |argv| {
        found |= job_of(argv, cwd).is_some();
    });
    found
}

/// The notice row that replaces RFD 0133's three-button warning (RFD 0144, "This supersedes two
/// asks": Leo, "we simply ... do it"): the warning's facts and what happens, no question.
/// `grows` is whether AutoSize grows this machine as the command works.
pub fn notice(warning: &Warning, grows: bool) -> String {
    let then = if grows {
        "Running it here; this machine grows as it works."
    } else {
        "Running it here as it is."
    };
    format!("[autosize] {} {then}", warning.text)
}

impl Shape {
    /// This machine's shape: its CPUs, `/proc/meminfo`, and the free disk under `dir`. None when
    /// memory cannot be read (not Linux).
    pub fn here(dir: &std::path::Path) -> Option<Self> {
        let meminfo = std::fs::read_to_string("/proc/meminfo").ok()?;
        let (mem_total, mem_available) = parse_meminfo(&meminfo);
        Some(Self {
            vcpu: std::thread::available_parallelism().map_or(1, |n| n.get() as u32),
            mem_total: mem_total?,
            mem_available,
            disk_free: crate::disk_usage::statvfs(dir).map_or(0, |root| root.free),
        })
    }
}

/// (`MemTotal`, `MemAvailable`) in bytes from `/proc/meminfo`'s text.
fn parse_meminfo(text: &str) -> (Option<u64>, Option<u64>) {
    let field = |name: &str| {
        text.lines().find_map(|l| {
            let rest = l.strip_prefix(name)?.strip_prefix(':')?;
            let kib: u64 = rest.trim().trim_end_matches("kB").trim().parse().ok()?;
            Some(kib * 1024)
        })
    };
    (field("MemTotal"), field("MemAvailable"))
}

fn file_name(word: &str) -> &str {
    word.trim_end_matches('/').rsplit('/').next().unwrap_or(word)
}

/// The job one simple command (`argv`, from its program on) runs, if a known-heavy one.
fn job_of(argv: &[&str], cwd: Option<&str>) -> Option<Job> {
    let program = file_name(argv.first()?);
    let args = argv.get(1..).unwrap_or_default();
    let positional = || args.iter().copied().filter(|a| !a.starts_with(['-', '+']));
    let in_llvm = cwd.is_some_and(|c| c.split('/').any(|p| p == "llvm-project"));
    match program {
        "fetch" if positional().any(|a| a == "chromium") => Some(Job::Project(Project::Chromium)),
        "autoninja" => Some(Job::Project(Project::Chromium)),
        "ninja" | "make" | "gmake" | "cmake" if in_llvm => Some(Job::Project(Project::Llvm)),
        "ninja" if ninja_out_dir(args) => Some(Job::Project(Project::Chromium)),
        "cmake" if cmake_of_llvm(args) => Some(Job::Project(Project::Llvm)),
        "x.py" | "x" if x_py_builds(args) => Some(Job::Project(Project::Rustc)),
        p if p.starts_with("python")
            && args.first().is_some_and(|s| file_name(s) == "x.py")
            && x_py_builds(args.get(1..).unwrap_or_default()) =>
        {
            Some(Job::Project(Project::Rustc))
        }
        "bazel" | "bazelisk"
            // A whole-tree target (`//...`, `//src/...`), not one target (`//foo:bar`).
            if positional().next() == Some("build")
                && args.iter().any(|a| a.starts_with("//") && a.ends_with("...")) =>
        {
            Some(Job::BigBuild)
        }
        "cargo" if positional().next() == Some("build") => Some(Job::BigBuild),
        "make" | "gmake" if args.iter().any(|a| a.starts_with("-j") || a.starts_with("--jobs")) => {
            Some(Job::BigBuild)
        }
        _ => None,
    }
}

/// `ninja -C out/Default`, `ninja -Cout/Release`, `ninja -C src/out/x`.
fn ninja_out_dir(args: &[&str]) -> bool {
    let is_out = |d: &str| d.starts_with("out/") || d.contains("/out/") || d == "out";
    args.iter().enumerate().any(|(i, a)| match a.strip_prefix("-C") {
        Some("") => args.get(i + 1).is_some_and(|d| is_out(d)),
        Some(dir) => is_out(dir),
        None => false,
    })
}

/// `cmake -S llvm ...`, `cmake ../llvm`, `cmake -G Ninja llvm-project/llvm`.
fn cmake_of_llvm(args: &[&str]) -> bool {
    args.iter().any(|a| {
        let a = a.strip_prefix("-S").unwrap_or(a);
        file_name(a) == "llvm" || a.contains("llvm-project")
    })
}

fn x_py_builds(args: &[&str]) -> bool {
    matches!(args.iter().find(|a| !a.starts_with('-')), Some(&("build" | "dist" | "install")))
}

fn warn(job: Job, argv: &[&str], shape: &Shape, place: &Place<'_>) -> Option<Warning> {
    let command = argv.join(" ");
    let free_mem = shape.mem_available.unwrap_or(shape.mem_total);
    match job {
        Job::Project(project) => {
            let (disk, memory) = project.minimums();
            let mut short = Vec::new();
            // At the minimum the build fills the disk to the last byte: short too.
            if shape.disk_free <= disk {
                short.push(Short::Disk);
            }
            if memory.is_some_and(|m| (shape.mem_total as f64) < m as f64 * MEMORY_SLACK) {
                short.push(Short::Memory);
            }
            if short.is_empty() {
                return None;
            }
            let text = project_text(project, shape);
            Some(Warning {
                command,
                project: Some(project),
                short,
                needs_disk: Some(disk),
                needs_memory: memory,
                text,
            })
        }
        Job::BigBuild => {
            let checkout = place.checkout_bytes?;
            let limit = free_mem.saturating_mul(CHECKOUT_PER_FREE_MEMORY);
            if checkout <= limit {
                return None;
            }
            let text = format!(
                "This build wants more than this machine has: `{}` in a {} GiB checkout, with {} GiB of memory free on {} vCPUs.",
                one_line(&command),
                gib(checkout),
                gib(free_mem),
                shape.vcpu,
            );
            Some(Warning {
                command,
                project: None,
                short: vec![Short::Memory],
                needs_disk: None,
                needs_memory: Some(checkout.div_ceil(CHECKOUT_PER_FREE_MEMORY)),
                text,
            })
        }
    }
}

/// "Chromium needs 100 GB of disk and 16 GB of memory; this machine has 20 GB free and 4 GB."
/// For Chromium, the time here and on the burst size.
fn project_text(project: Project, shape: &Shape) -> String {
    let (_, memory) = project.minimums();
    let needs = match memory {
        Some(m) => format!("{} of disk and {} GB of memory", project.disk_text(), m / GB),
        None => format!("{} of disk", project.disk_text()),
    };
    let has = match memory {
        Some(_) => format!("{} GB free and {} GB", gb(shape.disk_free), gb(shape.mem_total)),
        None => format!("{} GB free", gb(shape.disk_free)),
    };
    let mut text = format!("{} needs {needs}; this machine has {has}.", project.name());
    if project == Project::Chromium && shape.vcpu > 0 {
        let here = hours(CHROMIUM_CPU_HOURS / f64::from(shape.vcpu));
        text.push_str(&format!(" About {here} here if it fit"));
        if shape.vcpu < BURST_VCPU {
            let wall = CHROMIUM_CPU_HOURS / f64::from(BURST_VCPU);
            let usd = wall
                * (f64::from(BURST_VCPU) * VCPU_HOUR_USD + f64::from(BURST_MEM_GIB) * GIB_HOUR_USD);
            text.push_str(&format!(
                ", about {} and ${} on {BURST_VCPU} vCPU",
                hours(wall),
                usd.round()
            ));
        }
        text.push('.');
    }
    text
}

/// "20 hours", "1.5 hours", "1 hour": whole hours from 10, else up to the next half hour.
fn hours(h: f64) -> String {
    let h = if h >= 10.0 { h.round() } else { (h * 2.0).ceil() / 2.0 };
    if h == 1.0 { "1 hour".to_owned() } else { format!("{h} hours") }
}

fn gb(bytes: u64) -> u64 {
    (bytes as f64 / GB as f64).round() as u64
}

fn gib(bytes: u64) -> String {
    let g = bytes as f64 / GIB as f64;
    if g >= 10.0 { format!("{}", g.round()) } else { format!("{:.1}", g) }
}

/// A command for one line of text: its first 80 characters.
fn one_line(command: &str) -> String {
    let mut s: String = command.chars().take(80).collect();
    if s.len() < command.len() {
        s.push('…');
    }
    s
}

#[cfg(test)]
#[path = "heavy_precheck_tests.rs"]
mod tests;
