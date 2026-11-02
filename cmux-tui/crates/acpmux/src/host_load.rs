//! `acpmux machine load` (`host load`): one sample of this machine's load, as one
//! JSON object, for whoever sizes the machine. cmux Cloud's server runs it on a
//! Cloud machine once a minute through its provider's exec and grows or shrinks
//! the VM from the samples (manaflow-ai/cmux-platform).
//!
//! Every field but `at` is left out when it cannot be read: off Linux most are,
//! and the command still prints `at` and exits 0. Reads only: it never starts a
//! daemon, and a daemon that does not answer quickly leaves `busy`,
//! `localTurns` and `heavy` out.
//!
//! `heavy` is the heaviest known build or test the daemon's agents run now: the
//! shell commands of their tool calls in flight (`hub/activity.rs`) and of their
//! running background processes (`hub/processes.rs`), as the daemon reports them
//! (`host_pressure.heavy`). Never a process scan (plans/cmux-next/pty-holder.md 4):
//! the agents report what they run.

use serde::{Deserialize, Serialize};
use std::time::Duration;

/// How long the two `/proc/stat` reads are apart.
#[cfg(target_os = "linux")]
const CPU_WINDOW: Duration = Duration::from_secs(1);
/// How long the daemon has to say whether a turn runs.
const DAEMON_WAIT: Duration = Duration::from_millis(1500);

#[derive(Debug, Default, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Load {
    /// Milliseconds since the epoch.
    pub at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_busy: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_some_avg60: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mem_some_avg60: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mem_full_avg60: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mem_available_fraction: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub swap_used_fraction: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oom_kills: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disk_free_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disk_free_fraction: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub busy: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_turns: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heavy: Option<Heavy>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Build,
    Test,
}

/// What a running build or test needs on top of the agent session's own 2 GiB / 2 cores.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Need {
    pub vcpu: u32,
    #[serde(rename = "memGiB")]
    pub mem_gib: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Heavy {
    pub kind: Kind,
    pub need: Need,
}

/// The known-heavy tools: (program, subcommand it must run or `None` for any, kind,
/// vCPU, GiB). From cmux#26617's sizing model. A program is a command's first word's
/// file name, or (under node or bun) its script's file name.
const HEAVY: &[(&str, Option<&str>, Kind, u32, u32)] = &[
    ("cargo", Some("build"), Kind::Build, 8, 15),
    ("cargo", Some("test"), Kind::Test, 8, 15),
    ("cargo", Some("clippy"), Kind::Build, 8, 15),
    ("rustc", None, Kind::Build, 8, 15),
    ("swift", Some("build"), Kind::Build, 4, 13),
    ("swift-build", None, Kind::Build, 4, 13),
    ("swift-frontend", None, Kind::Build, 4, 13),
    ("swift", Some("test"), Kind::Test, 6, 11),
    ("swift-test", None, Kind::Test, 6, 11),
    ("go", Some("build"), Kind::Build, 8, 8),
    ("go", Some("test"), Kind::Test, 8, 8),
    ("make", None, Kind::Build, 8, 8),
    ("cmake", None, Kind::Build, 8, 8),
    ("ninja", None, Kind::Build, 8, 8),
    ("gcc", None, Kind::Build, 8, 8),
    ("g++", None, Kind::Build, 8, 8),
    ("cc1", None, Kind::Build, 8, 8),
    ("cc1plus", None, Kind::Build, 8, 8),
    ("clang", None, Kind::Build, 8, 8),
    ("clang++", None, Kind::Build, 8, 8),
    ("bun", Some("test"), Kind::Test, 6, 2),
    ("npm", Some("test"), Kind::Test, 6, 2),
    ("pnpm", Some("test"), Kind::Test, 6, 2),
    ("yarn", Some("test"), Kind::Test, 6, 2),
    ("vitest", None, Kind::Test, 6, 2),
    ("jest", None, Kind::Test, 6, 2),
    ("playwright", None, Kind::Test, 6, 2),
    ("tsc", None, Kind::Build, 6, 2),
    ("vite", Some("build"), Kind::Build, 6, 2),
];

/// A path's file name without a script extension (`node_modules/.bin/vitest.mjs` → `vitest`).
fn program(word: &str) -> &str {
    let name = word.rsplit('/').next().unwrap_or(word);
    [".mjs", ".cjs", ".js"].iter().find_map(|ext| name.strip_suffix(ext)).unwrap_or(name)
}

/// The heavy work one command does, from its program's name and argv.
pub fn classify(comm: &str, argv: &[&str]) -> Option<Heavy> {
    let arg = |i: usize| argv.get(i).copied();
    let mut asks: Vec<(&str, Option<&str>)> = vec![(comm.trim(), arg(1))];
    if let Some(zero) = arg(0) {
        asks.push((program(zero), arg(1)));
        // `node …/vitest.mjs run`: the script is the tool; `bun x tsc` (and `bunx`, `npx`): the
        // tool after `x`.
        let (script, sub) = match (program(zero), arg(1)) {
            ("bun", Some("x")) => (arg(2), arg(3)),
            ("bunx" | "npx", s) => (s, arg(2)),
            ("node" | "bun", s) => (s, arg(2)),
            _ => (None, None),
        };
        if let Some(script) = script {
            asks.push((program(script), sub));
        }
    }
    let mut best: Option<Heavy> = None;
    for (name, sub) in asks {
        for (tool, needs, kind, vcpu, mem_gib) in HEAVY {
            if *tool == name && needs.is_none_or(|n| Some(n) == sub) {
                best = heavier(
                    best,
                    Heavy { kind: *kind, need: Need { vcpu: *vcpu, mem_gib: *mem_gib } },
                );
            }
        }
    }
    best
}

/// The heavier of two: more memory, then more cores.
pub(crate) fn heavier(a: Option<Heavy>, b: Heavy) -> Option<Heavy> {
    match a {
        Some(a) if (a.need.mem_gib, a.need.vcpu) >= (b.need.mem_gib, b.need.vcpu) => Some(a),
        _ => Some(b),
    }
}

/// The heaviest work any of these (program, argv) commands does.
pub fn heaviest<'a>(processes: impl IntoIterator<Item = (&'a str, Vec<&'a str>)>) -> Option<Heavy> {
    processes.into_iter().fold(None, |best, (comm, argv)| match classify(comm, &argv) {
        Some(h) => heavier(best, h),
        None => best,
    })
}

/// Words before a command's program that are not it: a wrapper that runs the rest.
const WRAPPERS: &[&str] = &["env", "time", "nice", "nohup", "exec", "command"];

/// The heavy work a shell command does: the heaviest of its simple commands (split at `;`,
/// `&&`, `||`, `|`, `&` and line ends), each read from its program on, past leading
/// `NAME=value` words, a wrapper and its options ([`WRAPPERS`]). `sh -c SCRIPT` (and `bash`,
/// `zsh`, `-lc`) is its script. A loose read, not a shell parse: it only names a build or test.
pub fn classify_command(script: &str) -> Option<Heavy> {
    script.split(['\n', ';', '|', '&']).fold(None, |best, segment| {
        let words: Vec<&str> = segment
            .split_whitespace()
            .map(|w| w.trim_matches(|c| matches!(c, '"' | '\'' | '(' | ')')))
            .filter(|w| !w.is_empty())
            .collect();
        let skip = |w: &&str| {
            WRAPPERS.contains(w)
                || w.starts_with('-')
                || w.bytes().all(|b| b.is_ascii_digit())
                || w.split_once('=').is_some_and(|(name, _)| {
                    !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                })
        };
        let argv: Vec<&str> = words.iter().copied().skip_while(skip).collect();
        let found = match (argv.first().copied().map(program), argv.get(1).copied()) {
            (Some("sh" | "bash" | "zsh"), Some("-c" | "-lc")) => {
                classify_command(&argv.get(2..).unwrap_or_default().join(" "))
            }
            (Some(name), _) => classify(name, &argv),
            (None, _) => None,
        };
        match found {
            Some(h) => heavier(best, h),
            None => best,
        }
    })
}

/// The heavy work an ACP tool call (`tool_call` or `tool_call_update`) runs: its shell command,
/// `rawInput.command`, a script (Claude Code's Bash) or an argv (Codex). A call of a kind other
/// than `execute` runs none.
pub fn heavy_of_tool(update: &serde_json::Value) -> Option<Heavy> {
    use serde_json::Value;
    if update.get("kind").and_then(Value::as_str).is_some_and(|k| k != "execute") {
        return None;
    }
    match update.pointer("/rawInput/command")? {
        Value::String(script) => classify_command(script),
        Value::Array(argv) => {
            classify_command(&argv.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
        }
        _ => None,
    }
}

/// `busy` and `localTurns` from `daemon status`'s `host_pressure.local_turns`.
pub fn turns_of(status: &serde_json::Value) -> Option<u64> {
    status.pointer("/host_pressure/local_turns")?.as_u64()
}

/// `heavy` from `daemon status`'s `host_pressure.heavy`.
pub fn heavy_of(status: &serde_json::Value) -> Option<Heavy> {
    serde_json::from_value(status.pointer("/host_pressure/heavy")?.clone()).ok()
}

/// The sample: the `/proc` reads (blocking, about [`CPU_WINDOW`]) beside the daemon's answer.
pub async fn sample() -> Load {
    let reads = tokio::task::spawn_blocking(read_host);
    let status = tokio::time::timeout(DAEMON_WAIT, daemon_status()).await.ok().flatten();
    let mut load = reads.await.unwrap_or_default();
    load.at = crate::store::now_ms();
    let turns = status.as_ref().and_then(turns_of);
    load.local_turns = turns;
    load.busy = turns.map(|n| n > 0);
    load.heavy = status.as_ref().and_then(heavy_of);
    load
}

/// The running daemon's status; none when there is no daemon (never starts one).
async fn daemon_status() -> Option<serde_json::Value> {
    let client = crate::client::Client::connect(&crate::config::socket_path()).await.ok()?;
    client.request(crate::rpc::method::MUX_STATUS, serde_json::json!({})).await.ok()
}

fn read_host() -> Load {
    let mut load = Load::default();
    disk(&mut load);
    #[cfg(target_os = "linux")]
    linux(&mut load);
    load
}

#[cfg(unix)]
fn disk(load: &mut Load) {
    use std::os::unix::ffi::OsStrExt;
    let Some(home) = std::env::var_os("HOME") else { return };
    let Ok(path) = std::ffi::CString::new(home.as_bytes()) else { return };
    // SAFETY: an all-zero statvfs is a valid value of this plain C struct.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `path` is NUL-terminated and `st` is writable storage of the right type.
    if unsafe { libc::statvfs(path.as_ptr(), &raw mut st) } != 0 {
        return;
    }
    let frsize = st.f_frsize as u64;
    let free = (st.f_bavail as u64).saturating_mul(frsize);
    let total = (st.f_blocks as u64).saturating_mul(frsize);
    load.disk_free_bytes = Some(free);
    load.disk_free_fraction = (total > 0).then(|| free as f64 / total as f64);
}

#[cfg(not(unix))]
fn disk(_: &mut Load) {}

#[cfg(target_os = "linux")]
fn linux(load: &mut Load) {
    use crate::host_pressure as p;
    let read = |path: &str| std::fs::read_to_string(path).ok();
    let stat = || read("/proc/stat").and_then(|s| p::parse_proc_stat_cpu(&s));
    if let Some(cpu) = read("/proc/pressure/cpu") {
        load.cpu_some_avg60 = p::parse_psi_avg60(&cpu, "some");
    }
    if let Some(mem) = read("/proc/pressure/memory") {
        load.mem_some_avg60 = p::parse_psi_avg60(&mem, "some");
        load.mem_full_avg60 = p::parse_psi_avg60(&mem, "full");
    }
    if let Some(meminfo) = read("/proc/meminfo") {
        load.mem_available_fraction = p::parse_meminfo_available(&meminfo);
        load.swap_used_fraction = p::parse_meminfo_swap_used(&meminfo);
    }
    load.oom_kills = read("/proc/vmstat").and_then(|s| p::parse_vmstat_oom_kill(&s));
    // The window is the sleep alone: the reads above stay out of it.
    let before = stat();
    std::thread::sleep(CPU_WINDOW);
    load.cpu_busy = before.zip(stat()).and_then(|(a, b)| p::cpu_busy(a, b));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn need(kind: Kind, vcpu: u32, mem_gib: u32) -> Option<Heavy> {
        Some(Heavy { kind, need: Need { vcpu, mem_gib } })
    }

    #[test]
    fn builds_and_tests_are_known_from_comm_and_argv() {
        assert_eq!(classify("cargo", &["cargo", "build", "-p", "x"]), need(Kind::Build, 8, 15));
        assert_eq!(classify("cargo", &["/usr/bin/cargo", "test"]), need(Kind::Test, 8, 15));
        assert_eq!(classify("cargo", &["cargo", "fmt"]), None, "not a build");
        assert_eq!(classify("rustc", &["rustc", "--crate-name", "a"]), need(Kind::Build, 8, 15));
        assert_eq!(classify("swift-frontend", &[]), need(Kind::Build, 4, 13));
        assert_eq!(classify("swift", &["swift", "test"]), need(Kind::Test, 6, 11));
        assert_eq!(classify("go", &["go", "test", "./..."]), need(Kind::Test, 8, 8));
        assert_eq!(classify("go", &["go", "run", "."]), None);
        assert_eq!(classify("cc1plus", &[]), need(Kind::Build, 8, 8));
        assert_eq!(classify("bun", &["bun", "test", "a.test.ts"]), need(Kind::Test, 6, 2));
        assert_eq!(classify("bun", &["bun", "run", "dev"]), None);
        assert_eq!(classify("bun", &["bun", "x", "tsc", "-b"]), need(Kind::Build, 6, 2));
        assert_eq!(classify("npx", &["npx", "vitest", "run"]), need(Kind::Test, 6, 2));
        assert_eq!(classify("npx", &["npx", "vite", "build"]), need(Kind::Build, 6, 2));
        // A node script is its tool.
        let vitest = ["node", "/w/node_modules/.bin/vitest.mjs", "run"];
        assert_eq!(classify("node", &vitest), need(Kind::Test, 6, 2));
        assert_eq!(
            classify("node", &["node", "/w/node_modules/typescript/bin/tsc"]),
            need(Kind::Build, 6, 2)
        );
        assert_eq!(
            classify("node", &["node", "/w/node_modules/.bin/vite", "build"]),
            need(Kind::Build, 6, 2)
        );
        assert_eq!(classify("node", &["node", "/w/node_modules/.bin/vite"]), None, "a dev server");
        assert_eq!(classify("bash", &["bash", "-c", "cargo build"]), None);
        assert_eq!(classify("claude", &["claude"]), None);
    }

    #[test]
    fn the_heaviest_process_wins() {
        let ps = vec![
            ("node", vec!["node", "vitest.mjs"]),
            ("cargo", vec!["cargo", "test"]),
            ("make", vec!["make", "-j8"]),
            ("zsh", vec!["-zsh"]),
        ];
        assert_eq!(heaviest(ps), need(Kind::Test, 8, 15));
        assert_eq!(heaviest(vec![("zsh", vec!["zsh"])]), None);
    }

    #[test]
    fn the_sample_is_camel_case_and_omits_what_it_could_not_read() {
        let bare = Load { at: 7, ..Load::default() };
        assert_eq!(serde_json::to_value(&bare).unwrap(), json!({"at": 7}));
        let full = Load {
            at: 1,
            cpu_busy: Some(0.5),
            mem_some_avg60: Some(1.0),
            swap_used_fraction: Some(0.1),
            busy: Some(true),
            local_turns: Some(2),
            heavy: need(Kind::Build, 8, 15),
            ..Load::default()
        };
        assert_eq!(
            serde_json::to_value(&full).unwrap(),
            json!({"at": 1, "cpuBusy": 0.5, "memSomeAvg60": 1.0, "swapUsedFraction": 0.1,
                   "busy": true, "localTurns": 2,
                   "heavy": {"kind": "build", "need": {"vcpu": 8, "memGiB": 15}}})
        );
    }

    #[test]
    fn turns_come_from_daemon_status() {
        assert_eq!(turns_of(&json!({"host_pressure": {"local_turns": 3}})), Some(3));
        assert_eq!(turns_of(&json!({"host_pressure": {"ok": null}})), None);
    }

    #[test]
    fn a_shell_command_is_known_from_its_simple_commands() {
        assert_eq!(classify_command("cargo build -p acpmux"), need(Kind::Build, 8, 15));
        assert_eq!(classify_command("cd /w && cargo test --locked"), need(Kind::Test, 8, 15));
        assert_eq!(
            classify_command("RUST_LOG=1 nice -n 10 cargo clippy"),
            need(Kind::Build, 8, 15)
        );
        assert_eq!(classify_command("bash -lc 'go test ./...'"), need(Kind::Test, 8, 8));
        assert_eq!(classify_command("bun test a.test.ts; make -j8"), need(Kind::Build, 8, 8));
        assert_eq!(classify_command("npx vitest run | tee log"), need(Kind::Test, 6, 2));
        assert_eq!(classify_command("git status && rg cargo"), None);
        assert_eq!(classify_command("echo cargo build"), None, "an argument, not the program");
        assert_eq!(classify_command(""), None);
    }

    #[test]
    fn a_tool_call_runs_its_execute_command() {
        let bash = json!({"kind": "execute", "rawInput": {"command": "cargo test"}});
        assert_eq!(heavy_of_tool(&bash), need(Kind::Test, 8, 15));
        let argv = json!({"rawInput": {"command": ["bash", "-lc", "swift build"]}});
        assert_eq!(heavy_of_tool(&argv), need(Kind::Build, 4, 13));
        let mcp = json!({"kind": "other", "rawInput": {"command": "cargo build"}});
        assert_eq!(heavy_of_tool(&mcp), None, "only a shell command runs");
        assert_eq!(heavy_of_tool(&json!({"kind": "execute"})), None);
    }

    #[test]
    fn heavy_comes_from_daemon_status() {
        let status =
            json!({"host_pressure": {"heavy": {"kind": "test", "need": {"vcpu": 6, "memGiB": 2}}}});
        assert_eq!(heavy_of(&status), need(Kind::Test, 6, 2));
        assert_eq!(heavy_of(&json!({"host_pressure": {"local_turns": 0}})), None);
    }
}
