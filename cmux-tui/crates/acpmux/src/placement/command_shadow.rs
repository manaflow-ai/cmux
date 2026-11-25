//! The command placer of RFD 0144 ("The agentic computer"), in shadow: for each shell command an
//! agent runs, where the RFD's "Where a command runs" table would run it (here, here growing in
//! place, a run VM or a serve VM), decided before it starts from what is predicted about it. This
//! file is the pure half: a command's class, the prediction table and [`decide`]. The other half
//! (`command_sampler.rs`) sees each command start and end, measures it and writes the row.
//!
//! Nothing here moves, forks or resizes anything: the verdict is only written down, so a week of
//! our own lanes replaces the RFD's assumed thresholds (10 s, 8 vCPU / 16 GiB, fork p95 1 s) with
//! measured ones (RFD 0144, Building, piece 1b).
//!
//! The agent VM the verdict reasons about is RFD 0063's Code shape (2 vCPU / 4 GiB), the shape
//! every agent VM starts at, never the machine the daemon happens to run on: on a 32-core lane VM
//! everything would "fit as it is" and the rows would say nothing. The real machine's shape is
//! written beside it.

use serde::Serialize;
use std::collections::{HashMap, VecDeque};

/// The agent VM's shape when nothing has grown it (RFD 0063's Code shape).
pub const AGENT_VM_START: Shape = Shape { vcpu: 2.0, mem_gib: 4.0 };
/// The most the agent VM grows in place (RFD 0063's Build shape); past it work leaves (**A**).
pub const GROW_CEILING: Shape = Shape { vcpu: 8.0, mem_gib: 16.0 };
/// The largest single workload VM.
pub const MAX_WORKLOAD_VCPU: f64 = 64.0;
/// A command predicted to end sooner than this stays here when it fits (**A**).
pub const SHORT_WALL_S: f64 = 10.0;
/// Third-party code forks even when small once a fork's p95 is under this (**A**).
pub const FORK_P95_FOR_THIRD_PARTY_MS: u64 = 1_000;
/// Memory headroom over the predicted peak when a shape is sized (**A**).
pub const MEM_HEADROOM: f64 = 1.5;
/// How many of a class's last runs the prediction reads.
pub const HISTORY_RUNS: usize = 5;
/// How many classes the prediction table keeps (oldest use dropped first).
pub const MAX_CLASSES: usize = 4_096;

/// A machine shape: vCPU and GiB of memory.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Shape {
    pub vcpu: f64,
    #[serde(rename = "memGiB")]
    pub mem_gib: f64,
}

impl Shape {
    fn holds(self, need: Shape) -> bool {
        need.vcpu <= self.vcpu + f64::EPSILON && need.mem_gib <= self.mem_gib + f64::EPSILON
    }
}

/// Where the table would run a command.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Decision {
    /// On the agent VM as it is.
    Here,
    /// On the agent VM, grown in place first (RFD 0133).
    Grow,
    /// On a run VM, a fork that is deleted when the command ends.
    RunVm,
    /// On a serve VM, a fork that outlives the tool call.
    ServeVm,
}

/// Which row of the RFD's table decided, in the table's order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Row {
    /// 1: predicted under 10 s and fits the agent VM as it is.
    Short,
    /// 2: bounded, fits under 8 / 16, nothing else heavy running.
    GrowInPlace,
    /// 3: bounded, predicted above 8 / 16, or a second heavy command at once.
    Heavy,
    /// 4: listens on a port, or still runs when its tool call returns.
    Listens,
    /// 5: third-party code with no need for the agent's credentials, once fork p95 < 1 s.
    ThirdParty,
    /// 6: unknown and small.
    Unknown,
}

impl Row {
    pub fn number(self) -> u8 {
        match self {
            Row::Short => 1,
            Row::GrowInPlace => 2,
            Row::Heavy => 3,
            Row::Listens => 4,
            Row::ThirdParty => 5,
            Row::Unknown => 6,
        }
    }
}

/// Where a prediction came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    /// This repository's last runs of the class.
    History,
    /// RFD 0133's known-heavy list (`host_load::HEAVY`), first sight of the class.
    ClassDefault,
    /// Nothing known.
    None,
}

/// What is predicted about a command before it starts.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Predicted {
    pub source: Source,
    /// How many past runs it read (History only).
    pub runs: usize,
    /// Wall time in seconds, when known.
    pub wall_s: Option<f64>,
    /// The shape it needs, headroom included, when known.
    pub need: Option<Shape>,
    /// It (or its class's last runs) listens on a port.
    pub listens: bool,
    /// It is asked to run past its tool call (a background shell), or its class did.
    pub outlives: bool,
    /// It runs code we did not write (a dependency install's scripts).
    pub third_party: bool,
}

/// What else is true when the command starts.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Situation {
    /// The agent VM as it is now.
    pub agent_vm: Shape,
    /// The session's other commands in flight whose verdict was heavy (grow or run).
    pub heavy_running: u32,
    /// The measured fork-to-first-command p95, when piece 1a has one.
    pub fork_p95_ms: Option<u64>,
}

/// The table's verdict.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Verdict {
    pub decision: Decision,
    pub row: Row,
    /// The shape it would run at: the grown agent VM, or the workload VM.
    pub shape: Shape,
}

/// RFD 0144's "Where a command runs", top to bottom where rows overlap: a command that listens or
/// outlives its call is served whatever its size; third-party code forks once forks are cheap; an
/// unknown command stays here; a short one that fits stays here; a heavy one runs on a run VM when
/// it is past the grow ceiling or another heavy command of the session runs; else it grows here.
pub fn decide(p: &Predicted, s: &Situation) -> Verdict {
    let sized = |need: Option<Shape>| need.map(workload_shape).unwrap_or(AGENT_VM_START);
    if p.listens || p.outlives {
        return Verdict { decision: Decision::ServeVm, row: Row::Listens, shape: sized(p.need) };
    }
    if p.third_party && s.fork_p95_ms.is_some_and(|ms| ms < FORK_P95_FOR_THIRD_PARTY_MS) {
        return Verdict { decision: Decision::RunVm, row: Row::ThirdParty, shape: sized(p.need) };
    }
    let Some(need) = p.need.filter(|_| p.source != Source::None) else {
        return Verdict { decision: Decision::Here, row: Row::Unknown, shape: s.agent_vm };
    };
    let fits_now = s.agent_vm.holds(need);
    if fits_now {
        let row =
            if p.wall_s.is_some_and(|w| w < SHORT_WALL_S) { Row::Short } else { Row::GrowInPlace };
        return Verdict { decision: Decision::Here, row, shape: s.agent_vm };
    }
    if !GROW_CEILING.holds(need) || s.heavy_running > 0 {
        return Verdict { decision: Decision::RunVm, row: Row::Heavy, shape: workload_shape(need) };
    }
    let grown = Shape {
        vcpu: need.vcpu.ceil().max(s.agent_vm.vcpu).min(GROW_CEILING.vcpu),
        mem_gib: need.mem_gib.ceil().max(s.agent_vm.mem_gib).min(GROW_CEILING.mem_gib),
    };
    Verdict { decision: Decision::Grow, row: Row::GrowInPlace, shape: grown }
}

/// A workload VM's shape for a need: whole vCPU, 1 to 64; whole GiB, at least 1.
fn workload_shape(need: Shape) -> Shape {
    Shape {
        vcpu: need.vcpu.ceil().clamp(1.0, MAX_WORKLOAD_VCPU),
        mem_gib: need.mem_gib.ceil().max(1.0),
    }
}

/// Programs whose second word is a verb worth keeping in a class (`cargo test`, `git status`).
const VERB_TOOLS: &[&str] = &[
    "cargo",
    "git",
    "npm",
    "pnpm",
    "yarn",
    "bun",
    "go",
    "swift",
    "docker",
    "podman",
    "kubectl",
    "gh",
    "make",
    "uv",
    "pip",
    "pip3",
    "poetry",
    "deno",
    "rails",
    "bundle",
    "mix",
    "dotnet",
    "gradle",
    "mvn",
    "xcodebuild",
    "bazel",
    "cmux-ci",
    "cmux",
    "acpmux",
    "terraform",
    "flask",
    "next",
    "vite",
    "brew",
    "apt",
    "apt-get",
    "nix",
    "turbo",
    "nx",
    "rustup",
    "zig",
    "tsc",
    "vitest",
    "jest",
];
/// Interpreters whose first argument is a script file: the class keeps the script's file name.
const INTERPRETERS: &[&str] = &[
    "python", "python3", "node", "bun", "deno", "ruby", "perl", "bash", "sh", "zsh", "tsx",
    "ts-node",
];
/// Commands that only set up the shell: a class skips them when anything else runs.
const SETUP: &[&str] = &[
    "cd", "pushd", "popd", "export", "set", "unset", "source", ".", "echo", "printf", "true",
    "false", ":", "test", "[", "[[", "local", "declare", "trap", "shopt", "ulimit", "umask",
];

/// One simple command's class: its program's file name and, for a tool that takes a verb, the verb
/// (`cargo test`, `pnpm run dev`, `python3 -m pytest`, `python3 build.py`). Never an argument that
/// could hold data: a class names what ran, not what it was given.
pub fn class_of_argv(argv: &[&str]) -> Option<String> {
    let zero = argv.first()?;
    let prog = zero.rsplit('/').next().unwrap_or(zero);
    if prog.is_empty() {
        return None;
    }
    let is_word = |w: &str| {
        !w.is_empty()
            && w.len() <= 32
            && w.starts_with(|c: char| c.is_ascii_lowercase())
            && w.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ':' | '.'))
    };
    let file_name = |w: &str| {
        let name = w.rsplit('/').next().unwrap_or(w);
        (!name.is_empty() && name.len() <= 48 && name.contains('.')).then(|| name.to_owned())
    };
    let arg = |i: usize| argv.get(i).copied();
    let mut class = prog.to_owned();
    match (prog, arg(1)) {
        ("npx" | "bunx", Some(tool)) => class = format!("{prog} {}", tool.rsplit('/').next()?),
        (p, Some("-m")) if p.starts_with("python") => {
            if let Some(module) = arg(2).filter(|m| is_word(m)) {
                class = format!("{p} -m {module}");
            }
        }
        (p, Some(sub)) if VERB_TOOLS.contains(&p) && is_word(sub) => {
            class = format!("{p} {sub}");
            // `npm run dev`, `pnpm run build`, `bun x tsc`, `uv run pytest`: the script or tool too.
            if matches!(sub, "run" | "x" | "exec" | "dlx")
                && let Some(next) = arg(2).filter(|n| is_word(n))
            {
                class = format!("{class} {next}");
            }
        }
        (p, Some(script)) if INTERPRETERS.contains(&p) && !script.starts_with('-') => {
            if let Some(name) = file_name(script) {
                class = format!("{p} {name}");
            }
        }
        _ => {}
    }
    Some(class)
}

/// A shell command's class: the class of its heaviest simple command when one is known-heavy,
/// else of its first that does more than set up the shell, else of its first. Lowercased words,
/// at most 80 characters, so the row never carries an argument.
pub fn class_of(script: &str) -> String {
    let mut first: Option<String> = None;
    let mut first_real: Option<String> = None;
    let mut heavy: Option<(crate::host_load::Heavy, String)> = None;
    crate::host_load::for_each_command(script, &mut |argv| {
        let Some(class) = class_of_argv(argv) else { return };
        let prog = argv.first().map(|z| z.rsplit('/').next().unwrap_or(z)).unwrap_or_default();
        if let Some(h) = crate::host_load::classify(prog, argv) {
            let heavier = match &heavy {
                Some((best, _)) => {
                    (h.need.mem_gib, h.need.vcpu) > (best.need.mem_gib, best.need.vcpu)
                }
                None => true,
            };
            if heavier {
                heavy = Some((h, class.clone()));
            }
        }
        if first_real.is_none() && !SETUP.contains(&prog) {
            first_real = Some(class.clone());
        }
        first.get_or_insert(class);
    });
    let class = heavy.map(|(_, c)| c).or(first_real).or(first).unwrap_or_default();
    class.chars().take(80).collect()
}

/// Classes that listen when first seen: dev servers and services.
/// More than half.
fn most(count: usize, of: usize) -> bool {
    count * 2 > of
}

fn listens_by_class(class: &str) -> bool {
    let words: Vec<&str> = class.split(' ').collect();
    let last = words.last().copied().unwrap_or_default();
    match words.first().copied().unwrap_or_default() {
        "npm" | "pnpm" | "yarn" | "bun" => matches!(last, "dev" | "serve" | "start" | "preview"),
        "next" | "vite" | "astro" | "nuxt" => matches!(last, "dev" | "start" | "preview" | "serve"),
        "rails" => matches!(last, "server" | "s"),
        "flask" => last == "run",
        "docker" | "podman" => class.ends_with("compose") || last == "up",
        "uvicorn" | "gunicorn" | "http-server" | "serve" | "redis-server" | "postgres"
        | "mongod" | "wrangler" => true,
        p if p.starts_with("python") => class.ends_with("-m http.server"),
        _ => false,
    }
}

/// Classes that run third-party code: dependency installs and their scripts.
fn third_party_by_class(class: &str) -> bool {
    let mut words = class.split(' ');
    let prog = words.next().unwrap_or_default();
    let sub = words.next().unwrap_or_default();
    match prog {
        "npm" | "pnpm" | "yarn" | "bun" => {
            matches!(sub, "install" | "i" | "add" | "ci") || class == "yarn"
        }
        "pip" | "pip3" | "poetry" | "bundle" => sub == "install",
        "uv" => matches!(sub, "sync" | "pip" | "add"),
        "cargo" => sub == "fetch",
        "go" => sub == "mod",
        p if p.starts_with("python") => class.ends_with("-m pip"),
        _ => false,
    }
}

/// One finished run, as the prediction table keeps it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Run {
    pub wall_s: f64,
    pub cpu_s: Option<f64>,
    pub peak_mem_gib: Option<f64>,
    pub listened: bool,
    pub outlived: bool,
}

/// The prediction table: per repository and class, the last [`HISTORY_RUNS`] runs. In memory,
/// refilled from the rows file when the daemon starts (`command_sampler.rs`).
#[derive(Debug, Default)]
pub struct Table {
    classes: HashMap<(String, String), VecDeque<Run>>,
    order: VecDeque<(String, String)>,
}

impl Table {
    /// Adds a finished run of `class` in `repo`.
    pub fn record(&mut self, repo: &str, class: &str, run: Run) {
        let key = (repo.to_owned(), class.to_owned());
        if !self.classes.contains_key(&key) {
            if self.order.len() >= MAX_CLASSES
                && let Some(old) = self.order.pop_front()
            {
                self.classes.remove(&old);
            }
            self.order.push_back(key.clone());
        }
        let runs = self.classes.entry(key).or_default();
        if runs.len() >= HISTORY_RUNS {
            runs.pop_front();
        }
        runs.push_back(run);
    }

    /// What is predicted for `class` in `repo`, asked to run in the background or not: from its
    /// last runs when there are any, else RFD 0133's class default, else nothing.
    pub fn predict(&self, repo: &str, class: &str, script: &str, background: bool) -> Predicted {
        let listens = listens_by_class(class);
        let third_party = third_party_by_class(class);
        let runs = self.classes.get(&(repo.to_owned(), class.to_owned()));
        if let Some(runs) = runs.filter(|r| !r.is_empty()) {
            let mut walls: Vec<f64> = runs.iter().map(|r| r.wall_s).collect();
            walls.sort_by(f64::total_cmp);
            let wall = walls.get(walls.len() / 2).copied().unwrap_or_default();
            let peak = runs
                .iter()
                .filter_map(|r| r.peak_mem_gib)
                .fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v))));
            // Cores: the busiest run's CPU-seconds over its wall time.
            let cores = runs
                .iter()
                .filter_map(|r| Some(r.cpu_s? / r.wall_s.max(0.001)))
                .fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v))));
            let need = match (peak, cores) {
                (Some(peak), Some(cores)) => {
                    Some(Shape { vcpu: cores.max(0.1), mem_gib: (peak * MEM_HEADROOM).max(0.1) })
                }
                _ => None,
            };
            return Predicted {
                source: if need.is_some() { Source::History } else { Source::None },
                runs: runs.len(),
                wall_s: Some(wall),
                need,
                // Most of its last runs, not any one: `python3 -c` that once served a port is
                // not a server the next time.
                listens: listens || most(runs.iter().filter(|r| r.listened).count(), runs.len()),
                outlives: background
                    || most(runs.iter().filter(|r| r.outlived).count(), runs.len()),
                third_party,
            };
        }
        let heavy = crate::host_load::classify_command(script);
        Predicted {
            source: if heavy.is_some() { Source::ClassDefault } else { Source::None },
            runs: 0,
            wall_s: None,
            // `host_load`'s need is on top of the session's own 2 vCPU / 2 GiB.
            need: heavy.map(|h| Shape {
                vcpu: f64::from(h.need.vcpu) + 2.0,
                mem_gib: f64::from(h.need.mem_gib) + 2.0,
            }),
            listens,
            outlives: background,
            third_party,
        }
    }
}

#[cfg(test)]
#[path = "command_shadow_tests.rs"]
mod tests;
