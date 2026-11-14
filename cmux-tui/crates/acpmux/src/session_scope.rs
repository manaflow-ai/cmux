//! Each session's harness in its own cgroup scope on Linux (cx-v9s8g): the
//! guard for the harness limits acpmux lifts (`harness_limits.rs`), which
//! allow as many subagents and background commands as the agent starts.
//!
//! `systemd-run --user --scope` starts the harness (it execs it, so the pid
//! and process group stay the harness's) in a transient scope with a memory
//! ceiling (`MemoryMax`), a throttle a little below it (`MemoryHigh`), a
//! process and thread cap (`TasksMax`) and a lower CPU weight (`CPUWeight`).
//! The kernel enforces them: a runaway's memory is throttled, then reclaimed
//! or killed inside its own session (`OOMPolicy=continue`: the process the
//! kernel picks ends, not the whole scope and never another session), a fork
//! storm stops at the cap, and a busy session yields the CPU to the rest of
//! the machine. Nothing measures or scans processes
//! (plans/cmux-next/pty-holder.md 4).
//!
//! Every session scope is in [`SESSIONS_SLICE`], which caps all sessions
//! together, so several sessions at their own ceilings still leave the
//! machine (the daemon, ssh, the user manager) room ([`slice_settings`]).
//!
//! The per-session limits come from the profile's env, then the daemon's:
//! `ACPMUX_SESSION_MEMORY_MB` (default half the machine's memory),
//! `ACPMUX_SESSION_SWAP_MB` (default one quarter of the machine's swap),
//! `ACPMUX_SESSION_MEMORY_HIGH_MB` (default nine tenths of that),
//! `ACPMUX_SESSION_TASKS_MAX` (default 4096) and `ACPMUX_SESSION_CPU_WEIGHT`
//! (default 50; systemd's own is 100). 0 turns one off. The sessions slice
//! uses `ACPMUX_SESSIONS_SWAP_MAX` (default 75% of the machine's swap). The
//! two task caps, a scope's and the slice's, are read in one order for both
//! ([`knob_reader`]): the daemon config's `session.tasksMax` and
//! `session.sessionsTasksMax`, then the env, then the computed default, so
//! profiles that disagree in their env never take turns rewriting the
//! shared slice once the config names a cap. Where `systemd-run` is
//! missing or cannot make a scope (no user manager, as in a container), the
//! harness starts as before; that answer is asked once per `systemd-run` and
//! limits. macOS gets the process-group half of the valve on the holder track
//! (cx-t2sqm.3); its harnesses run at background CPU class once started (`cpu_class.rs`).
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use std::collections::BTreeMap;
use tokio::process::Command;

/// A session's harness command: `program` itself, or `program` under
/// `systemd-run` when this session's harness gets a scope.
pub(crate) fn command(
    program: &str,
    session: Option<&str>,
    env: &BTreeMap<String, String>,
    remote: bool,
) -> Command {
    // A remote profile's PATH is explicit child authority, not daemon-side
    // launcher authority. Never probe or execute a scope wrapper selected
    // from it before the reviewed harness starts.
    if remote {
        return Command::new(program);
    }
    let limits = daemon_limits();
    match session.and_then(|id| prefix(id, env, limits)) {
        Some(prefix) => {
            let mut cmd = Command::new(&prefix[0]);
            cmd.args(&prefix[1..]).arg(program);
            cmd
        }
        None => Command::new(program),
    }
}

#[cfg(not(target_os = "linux"))]
fn prefix(
    _session: &str,
    _env: &BTreeMap<String, String>,
    _limits: SessionLimits,
) -> Option<Vec<String>> {
    None
}

/// `systemd-run … --` for the session's scope, when it can make one.
#[cfg(target_os = "linux")]
fn prefix(
    session: &str,
    env: &BTreeMap<String, String>,
    limits: SessionLimits,
) -> Option<Vec<String>> {
    let properties =
        properties_with_swap(&knob_reader(env, limits), physical_memory(), swap_memory());
    if properties.is_empty() {
        return None;
    }
    let runner = runner(env)?;
    // One runaway hitting `MemoryMax` ends that process, not the whole
    // scope (systemd 253+ stops a scope on OOM by default). An older systemd
    // refuses the property, and its scopes already continue.
    let mut continued = properties.clone();
    continued.extend(["-p".to_owned(), "OOMPolicy=continue".to_owned()]);
    let without_swap = without_swap(&properties);
    let mut continued_without_swap = without_swap.clone();
    continued_without_swap.extend(["-p".to_owned(), "OOMPolicy=continue".to_owned()]);
    let properties = [continued, properties.clone(), continued_without_swap, without_swap]
        .into_iter()
        .find(|properties| can_scope(&runner, properties, env, limits))?;
    let description = format!("acpmux session {session}");
    Some(scope_argv(&runner.to_string_lossy(), Some(SESSIONS_SLICE), &description, &properties))
}

/// The slice every session scope joins. Dash-free: systemd reads dashes in a
/// slice name as nesting (`agent_host/scope.rs` `HOST_SLICE` likewise).
pub(crate) const SESSIONS_SLICE: &str = "acpmuxsessions.slice";

/// The daemon's `systemd-run`, when one is installed and executable. This is
/// shared with the daemon launcher so it follows the same PATH rules as a
/// harness scope.
#[cfg(target_os = "linux")]
pub(crate) fn scope_runner() -> Option<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    ["/usr/bin/systemd-run", "/bin/systemd-run"]
        .into_iter()
        .map(std::path::PathBuf::from)
        .find(|path| {
            std::fs::metadata(path)
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
        .or_else(|| runner(&BTreeMap::new()))
}

/// Whether a user manager can create an unscoped transient scope. This probe
/// has no properties and therefore does not alter the sessions slice.
#[cfg(target_os = "linux")]
pub(crate) fn can_make_scope(runner: &std::path::Path) -> bool {
    probe(runner, &[], &BTreeMap::new())
}

/// `runner --user --scope … --` with `properties`, in `slice` when given.
fn scope_argv(
    runner: &str,
    slice: Option<&str>,
    description: &str,
    properties: &[String],
) -> Vec<String> {
    let mut argv = vec![
        runner.to_owned(),
        "--user".to_owned(),
        "--scope".to_owned(),
        "--quiet".to_owned(),
        "--collect".to_owned(),
    ];
    argv.extend(slice.map(|slice| format!("--slice={slice}")));
    argv.push(format!("--description={description}"));
    argv.extend_from_slice(properties);
    argv.push("--".to_owned());
    argv
}

/// Host-wide values loaded from the daemon config.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct SessionLimits {
    pub memory_mb: Option<u64>,
    pub swap_mb: Option<u64>,
    pub tasks_max: Option<u64>,
    pub sessions_tasks_max: Option<u64>,
}

fn daemon_limits() -> SessionLimits {
    #[cfg(not(target_os = "linux"))]
    return SessionLimits::default();
    #[cfg(target_os = "linux")]
    crate::config::Config::load()
        .map_or_else(|_| SessionLimits::default(), |config| session_limits_from_config(&config))
}

fn session_limits_from_config(config: &crate::config::Config) -> SessionLimits {
    let session = &config.session;
    SessionLimits {
        memory_mb: session.memory_mb,
        swap_mb: session.swap_mb,
        tasks_max: session.tasks_max,
        sessions_tasks_max: session.sessions_tasks_max,
    }
}

/// A knob's value. The task caps: the daemon config, then the profile's env,
/// then the daemon's, the same for a scope and the shared slice. The memory
/// knobs: the profile's env, then daemon config, then daemon env.
fn knob_reader(
    env: &BTreeMap<String, String>,
    limits: SessionLimits,
) -> impl Fn(&str) -> Option<String> + '_ {
    move |key| {
        let typed_first = match key {
            "ACPMUX_SESSION_TASKS_MAX" => limits.tasks_max,
            "ACPMUX_SESSIONS_TASKS_MAX" => limits.sessions_tasks_max,
            _ => None,
        };
        typed_first
            .map(|n| n.to_string())
            .or_else(|| env.get(key).cloned())
            .or_else(|| match key {
                "ACPMUX_SESSION_MEMORY_MB" => limits.memory_mb.map(|n| n.to_string()),
                "ACPMUX_SESSION_SWAP_MB" => limits.swap_mb.map(|n| n.to_string()),
                _ => None,
            })
            .or_else(|| std::env::var(key).ok())
    }
}

/// A session scope's `TasksMax` with the profile's `env` and the daemon
/// config's `limits` ([`knob_reader`]); None is no cap.
pub(crate) fn scope_tasks_max(
    env: &BTreeMap<String, String>,
    limits: SessionLimits,
) -> Option<u64> {
    tasks_max(&knob_reader(env, limits))
}

/// An agent host scope's `TasksMax`: the daemon's, read as a session scope
/// reads it, without a profile's env (a host is placed before its session's
/// profile reaches it).
pub(crate) fn host_tasks_max() -> Option<u64> {
    scope_tasks_max(&BTreeMap::new(), daemon_limits())
}

/// The fewest tasks the sessions slice defaults to, the fixed cap it had.
pub(crate) const SESSIONS_TASKS_FLOOR: u64 = 16_384;
/// The most tasks the sessions slice defaults to, however large the machine.
pub(crate) const SESSIONS_TASKS_CEILING: u64 = 262_144;

/// The sessions slice's default `TasksMax` on a machine whose kernel allows
/// `threads_max` threads: a quarter of them, between [`SESSIONS_TASKS_FLOOR`]
/// and [`SESSIONS_TASKS_CEILING`]; the floor when it is unknown. A fixed
/// 16384 was hit on a 32-core, 64 GiB host with 105 sessions while memory and
/// the kernel had room to spare (threads-max 514402: 128600 here).
pub(crate) fn sessions_tasks_default(threads_max: Option<u64>) -> u64 {
    threads_max.map_or(SESSIONS_TASKS_FLOOR, |n| {
        (n / 4).clamp(SESSIONS_TASKS_FLOOR, SESSIONS_TASKS_CEILING)
    })
}

/// `/proc/sys/kernel/threads-max` text as a count.
fn parse_threads_max(text: &str) -> Option<u64> {
    text.trim().parse().ok()
}

/// The kernel's thread limit, None when unreadable.
fn threads_max() -> Option<u64> {
    std::fs::read_to_string("/proc/sys/kernel/threads-max")
        .ok()
        .as_deref()
        .and_then(parse_threads_max)
}

/// What the sessions slice should have, from the profile's `env` and the
/// daemon config's `limits`, read as a scope reads them ([`knob_reader`]).
fn sessions_slice_wanted(
    env: &BTreeMap<String, String>,
    limits: SessionLimits,
    memory: u64,
    swap: u64,
    threads_max: Option<u64>,
) -> Vec<(&'static str, String)> {
    slice_settings_with_swap(
        &knob_reader(env, limits),
        memory,
        swap,
        sessions_tasks_default(threads_max),
    )
}

/// The default `TasksMax` of a session scope: processes and threads
/// together. A fork storm (huge-blue, 2026-10-25: 849 git processes) stops
/// here, in its own session.
pub(crate) const SESSION_TASKS_MAX: u64 = 4096;

/// A session's `TasksMax` from `get` (`ACPMUX_SESSION_TASKS_MAX`; 0: no cap,
/// which a scope gets as `infinity`, never systemd's `DefaultTasksMax`).
pub(crate) fn tasks_max(get: &dyn Fn(&str) -> Option<String>) -> Option<u64> {
    let n = get("ACPMUX_SESSION_TASKS_MAX")
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(SESSION_TASKS_MAX);
    (n > 0).then_some(n)
}

/// `-p` pairs for the scope's limits on a machine with `memory` and `swap`
/// bytes; empty when every one is off. The two argument form is kept for
/// deterministic tests and callers that do not know the host's swap.
#[cfg(test)]
fn properties(get: &dyn Fn(&str) -> Option<String>, memory: u64) -> Vec<String> {
    properties_with_swap(get, memory, 0)
}

fn properties_with_swap(
    get: &dyn Fn(&str) -> Option<String>,
    memory: u64,
    swap: u64,
) -> Vec<String> {
    let knob = |key: &str| get(key).and_then(|v| v.trim().parse::<u64>().ok());
    let mb = |n: u64| n.saturating_mul(1024 * 1024);
    let max = knob("ACPMUX_SESSION_MEMORY_MB").map_or(memory / 2, mb);
    // Throttled (reclaim, slower allocation) a little before it is killed.
    let high = knob("ACPMUX_SESSION_MEMORY_HIGH_MB").map_or(max / 10 * 9, mb);
    let high = if max > 0 { high.min(max) } else { high };
    let swap_max = knob("ACPMUX_SESSION_SWAP_MB").map_or(swap / 4, mb);
    let weight = knob("ACPMUX_SESSION_CPU_WEIGHT").unwrap_or(50).min(10_000);
    let tasks = tasks_max(get);
    let on = |value: u64| (value > 0).then(|| value.to_string());
    let limits = [
        ("MemoryMax", on(max)),
        ("MemoryHigh", on(high)),
        ("MemorySwapMax", on(swap_max)),
        ("TasksMax", tasks.map(|n| n.to_string())),
        ("CPUWeight", on(weight)),
    ];
    // Every limit off: no scope at all.
    if limits.iter().all(|(_, value)| value.is_none()) {
        return Vec::new();
    }
    let mut out = Vec::new();
    for (key, value) in limits {
        // A scope without `TasksMax` gets systemd's `DefaultTasksMax`; off is no cap.
        let value = match value {
            Some(value) => value,
            None if key == "TasksMax" => "infinity".to_owned(),
            None => continue,
        };
        out.extend(["-p".to_owned(), format!("{key}={value}")]);
    }
    out
}

fn without_swap(properties: &[String]) -> Vec<String> {
    properties
        .chunks_exact(2)
        .filter(|pair| !pair.get(1).is_some_and(|p| p.starts_with("MemorySwapMax=")))
        .flat_map(|pair| pair.iter().cloned())
        .collect()
}

/// What [`SESSIONS_SLICE`] caps for all sessions together, on a machine
/// with `memory` bytes, from the profile's env, then the daemon's:
/// `ACPMUX_SESSIONS_MEMORY_MAX`
/// (default 85% of the memory), `ACPMUX_SESSIONS_MEMORY_HIGH` (default 80%)
/// and `ACPMUX_SESSIONS_TASKS_MAX` (default `tasks_default`, from
/// [`sessions_tasks_default`]). A memory value is bytes,
/// optionally with `K`/`M`/`G`/`T` (powers of 1024) or `%` (1 to 100), a
/// task value a count; either may be `infinity`. 0 turns a limit off, which
/// is set as `infinity` so a limit set earlier goes; anything else is the
/// default. Values are absolute (bytes, counts), as `systemctl show` prints
/// them, so a slice already set is never written again ([`slice_changes`]).
/// A percentage on a machine of unknown memory leaves that property as it is.
#[cfg(test)]
fn slice_settings(
    get: &dyn Fn(&str) -> Option<String>,
    memory: u64,
) -> Vec<(&'static str, String)> {
    slice_settings_with_swap(get, memory, 0, SESSIONS_TASKS_FLOOR)
}

fn slice_settings_with_swap(
    get: &dyn Fn(&str) -> Option<String>,
    memory: u64,
    swap_bytes: u64,
    tasks_default: u64,
) -> Vec<(&'static str, String)> {
    let size = |total: u64, v: &str| -> Option<String> {
        if v == "infinity" || v == "0" {
            return Some("infinity".to_owned());
        }
        if let Some(pct) = v.strip_suffix('%') {
            let pct = pct.parse::<u64>().ok().filter(|p| (1..=100).contains(p))?;
            return (total > 0).then(|| (u128::from(total) * u128::from(pct) / 100).to_string());
        }
        let (digits, unit) = match v.strip_suffix(['K', 'M', 'G', 'T']) {
            Some(digits) => (digits, 1u64 << (10 * (1 + "KMGT".find(v.chars().last()?)?))),
            None => (v, 1),
        };
        let n = digits.parse::<u64>().ok().filter(|n| *n > 0)?.checked_mul(unit)?;
        Some(n.to_string())
    };
    let bytes = |v: &str| size(memory, v);
    let count = |v: &str| -> Option<String> {
        if v == "infinity" || v == "0" {
            return Some("infinity".to_owned());
        }
        v.parse::<u64>().ok().filter(|n| *n > 0).map(|n| n.to_string())
    };
    let pick = |env: &str, parse: &dyn Fn(&str) -> Option<String>, default: &str| {
        get(env).and_then(|v| parse(v.trim())).or_else(|| parse(default))
    };
    let mut out = Vec::new();
    if let Some(v) = pick("ACPMUX_SESSIONS_MEMORY_MAX", &bytes, "85%") {
        out.push(("MemoryMax", v));
    }
    if let Some(v) = pick("ACPMUX_SESSIONS_MEMORY_HIGH", &bytes, "80%") {
        out.push(("MemoryHigh", v));
    }
    if let Some(v) = pick("ACPMUX_SESSIONS_TASKS_MAX", &count, &tasks_default.to_string()) {
        out.push(("TasksMax", v));
    }
    let swap_value = |v: &str| size(swap_bytes, v);
    if let Some(v) = pick("ACPMUX_SESSIONS_SWAP_MAX", &swap_value, "75%") {
        out.push(("MemorySwapMax", v));
    }
    out
}

/// The `Key=value` assignments of `wanted` that `shown` (`systemctl show
/// -p …` output, `Key=value` lines) does not already have.
fn slice_changes(shown: &str, wanted: &[(&str, String)]) -> Vec<String> {
    wanted
        .iter()
        .map(|(key, value)| format!("{key}={value}"))
        .filter(|assignment| !shown.lines().any(|line| line.trim() == assignment))
        .collect()
}

/// `systemd-run` on the PATH the harness gets: the profile's, else the
/// agent PATH (`login_env.rs`), else the daemon's.
#[cfg(target_os = "linux")]
fn runner(env: &BTreeMap<String, String>) -> Option<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let path = env
        .get("PATH")
        .map(std::ffi::OsString::from)
        .or_else(crate::login_env::agent_path)
        .or_else(|| std::env::var_os("PATH"))?;
    std::env::split_paths(&path).map(|dir| dir.join("systemd-run")).find(|file| {
        file.is_absolute()
            && std::fs::metadata(file)
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    })
}

/// Whether `runner` makes a scope with `properties`: a scope around `true`,
/// remembered for `ANSWER_TTL` (the user manager can stop or start later).
#[cfg(target_os = "linux")]
fn can_scope(
    runner: &std::path::Path,
    properties: &[String],
    env: &BTreeMap<String, String>,
    limits: SessionLimits,
) -> bool {
    use std::sync::{Mutex, OnceLock};
    use std::time::Instant;
    type Answers = Mutex<
        BTreeMap<(std::path::PathBuf, Vec<String>, Vec<(String, Option<String>)>), (bool, Instant)>,
    >;
    static ANSWERS: OnceLock<Answers> = OnceLock::new();
    let answers = ANSWERS.get_or_init(Default::default);
    let slice_key = [
        "ACPMUX_SESSIONS_MEMORY_MAX",
        "ACPMUX_SESSIONS_MEMORY_HIGH",
        "ACPMUX_SESSIONS_TASKS_MAX",
        "ACPMUX_SESSIONS_SWAP_MAX",
    ]
    .into_iter()
    .map(|name| (name.to_owned(), env.get(name).cloned().or_else(|| std::env::var(name).ok())))
    .collect();
    let key = (runner.to_path_buf(), properties.to_vec(), slice_key);
    let cached = answers
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&key)
        .filter(|(_, at)| at.elapsed() < ANSWER_TTL)
        .map(|(known, _)| *known);
    let probe = || {
        let ok = cached.unwrap_or_else(|| probe(runner, properties, env));
        if ok {
            // The capability is cached; the shared slice's current settings
            // are not. Another profile may have changed them since our probe.
            limit_sessions_slice(runner, env, limits);
        }
        ok
    };
    let multi_thread = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    let ok = if multi_thread { tokio::task::block_in_place(probe) } else { probe() };
    if cached.is_none() {
        answers.lock().unwrap_or_else(|e| e.into_inner()).insert(key, (ok, Instant::now()));
    }
    ok
}

/// Sets [`SESSIONS_SLICE`]'s limits ([`slice_settings`]) with the
/// `systemctl` beside `runner`, after a probe made a scope (so a user manager
/// answers) and before the session's scope joins the slice. Best effort: a
/// failure is logged, and each session still has its own scope's limits.
#[cfg(target_os = "linux")]
fn limit_sessions_slice(
    runner: &std::path::Path,
    env: &BTreeMap<String, String>,
    limits: SessionLimits,
) {
    let wanted =
        sessions_slice_wanted(env, limits, physical_memory(), swap_memory(), threads_max());
    let systemctl = runner.with_file_name("systemctl");
    if !systemctl.is_file() {
        tracing::warn!(
            "no systemctl beside {}: {SESSIONS_SLICE} keeps no limit for all sessions together",
            runner.display()
        );
        return;
    }
    if let Err(e) = limit_slice(&systemctl, SESSIONS_SLICE, &wanted, env) {
        tracing::warn!("{e}: {SESSIONS_SLICE} may lack its limit for all sessions together");
    }
}

/// Sets `wanted` on `slice` as a runtime drop-in (`set-property --runtime`,
/// under `$XDG_RUNTIME_DIR/systemd/user.control`: it holds until the user's
/// runtime directory goes, a reboot or a logout without linger, and applies
/// whenever the slice loads, also while no session is in it). Only what
/// `systemctl show` does not already report is written: writing an
/// unchanged `MemoryHigh` makes the kernel reclaim the slice down to it in
/// the user manager, so a slice that has its limits is never touched again.
/// One call at a time: a concurrent caller returns at once and leaves it to
/// the one at work. Returns how many settings this call changed. Each `systemctl` call is
/// bounded by [`PROBE_TIMEOUT`].
#[cfg(target_os = "linux")]
fn limit_slice(
    systemctl: &std::path::Path,
    slice: &str,
    wanted: &[(&str, String)],
    env: &BTreeMap<String, String>,
) -> Result<usize, String> {
    static ONE_AT_A_TIME: std::sync::Mutex<()> = std::sync::Mutex::new(());
    // A session start that finds another one setting the limits does not
    // wait for it: that one sets them, so no start waits past its own calls.
    let _one = match ONE_AT_A_TIME.try_lock() {
        Ok(guard) => guard,
        Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner(),
        Err(std::sync::TryLockError::WouldBlock) => return Ok(0),
    };
    if wanted.is_empty() {
        return Ok(0);
    }
    let mut show: Vec<String> =
        vec!["--user".into(), "--no-pager".into(), "show".into(), slice.into()];
    for (key, _) in wanted {
        show.extend(["-p".to_owned(), (*key).to_owned()]);
    }
    let shown = run_bounded(systemctl, &show, env, true)
        .ok_or_else(|| format!("systemctl {} failed", show.join(" ")))?;
    let changes = slice_changes(&shown, wanted);
    if changes.is_empty() {
        return Ok(0);
    }
    let mut set: Vec<String> =
        ["--user", "set-property", "--runtime", slice].into_iter().map(str::to_owned).collect();
    set.extend(changes.iter().cloned());
    if run_bounded(systemctl, &set, env, false).is_some() {
        return Ok(changes.len());
    }
    // MemorySwapMax was added after the other cgroup properties. An older
    // systemd can still apply the memory and task limits, so retry without
    // the unsupported property instead of dropping the whole slice update.
    let without_swap: Vec<String> =
        changes.iter().filter(|change| !change.starts_with("MemorySwapMax=")).cloned().collect();
    if without_swap.len() < changes.len() {
        let mut retry = ["--user", "set-property", "--runtime", slice]
            .into_iter()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        retry.extend(without_swap.iter().cloned());
        if without_swap.is_empty() || run_bounded(systemctl, &retry, env, false).is_some() {
            return Ok(without_swap.len());
        }
    }
    Err(format!("systemctl {} failed", set.join(" ")))
}

/// How long a probe's answer holds.
#[cfg(target_os = "linux")]
const ANSWER_TTL: std::time::Duration = std::time::Duration::from_secs(300);

/// How long the probe may take before the answer is no.
#[cfg(target_os = "linux")]
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// A scope around `true` with `properties`, outside [`SESSIONS_SLICE`]: a
/// slice at its limits (sessions using all its memory or tasks) never makes
/// systemd look unusable, which would start the next harnesses unscoped. A
/// launch into a full slice fails instead.
#[cfg(target_os = "linux")]
fn probe(runner: &std::path::Path, properties: &[String], env: &BTreeMap<String, String>) -> bool {
    let mut argv = scope_argv("", None, "acpmux scope probe", properties);
    argv.push("true".to_owned());
    run_bounded(runner, argv.get(1..).unwrap_or_default(), env, false).is_some()
}

/// Runs `program args` with `env` on top of the daemon's and no input; its
/// output (with `output`, else nothing) when it succeeded within
/// [`PROBE_TIMEOUT`], else None. It runs in a process group of its own, and
/// a run past the deadline is killed with that whole group. The output goes
/// to an unlinked temporary file, never a pipe, so a child that leaves a
/// process behind holding it cannot make the read wait.
#[cfg(target_os = "linux")]
fn run_bounded(
    program: &std::path::Path,
    args: &[String],
    env: &BTreeMap<String, String>,
    output: bool,
) -> Option<String> {
    use std::io::{Read, Seek};
    use std::os::unix::process::CommandExt;
    use std::process::Stdio;
    let mut file = None;
    let stdout = if output {
        let path = std::env::temp_dir().join(format!(
            "acpmux-run-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        let opened =
            std::fs::OpenOptions::new().read(true).write(true).create_new(true).open(&path).ok()?;
        let _ = std::fs::remove_file(&path);
        let stdout = Stdio::from(opened.try_clone().ok()?);
        file = Some(opened);
        stdout
    } else {
        Stdio::null()
    };
    let mut child = std::process::Command::new(program)
        .args(args)
        .envs(env)
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let started = std::time::Instant::now();
    let succeeded = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Ok(None) if started.elapsed() < PROBE_TIMEOUT => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            _ => {
                if let Ok(pid) = i32::try_from(child.id()) {
                    // SAFETY: signals the process group this call made.
                    unsafe { libc::kill(-pid, libc::SIGKILL) };
                }
                let _ = child.wait();
                break false;
            }
        }
    };
    if !succeeded {
        return None;
    }
    let mut text = String::new();
    if let Some(mut file) = file {
        file.rewind().ok()?;
        file.take(64 * 1024).read_to_string(&mut text).ok()?;
    }
    Some(text)
}

/// The machine's memory in bytes (0 when unknown, which leaves memory off).
#[cfg(target_os = "linux")]
fn physical_memory() -> u64 {
    // SAFETY: sysconf only reads system configuration.
    let (pages, size) =
        unsafe { (libc::sysconf(libc::_SC_PHYS_PAGES), libc::sysconf(libc::_SC_PAGESIZE)) };
    u64::try_from(pages).unwrap_or(0).saturating_mul(u64::try_from(size).unwrap_or(0))
}

/// The machine's total swap in bytes. A missing or unreadable `/proc` entry
/// means swap limits stay off, just like an unknown physical memory size.
#[cfg(target_os = "linux")]
fn swap_memory() -> u64 {
    std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                let (key, value) = line.split_once(':')?;
                (key == "SwapTotal")
                    .then(|| value.split_whitespace().next()?.parse::<u64>().ok())?
            })
        })
        .unwrap_or(0)
        .saturating_mul(1024)
}

#[cfg(test)]
mod tests;
