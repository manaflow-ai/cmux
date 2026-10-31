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
mod tests {
    use super::*;

    const GIB: u64 = 1024 * 1024 * 1024;

    /// The tests that take `limit_slice`'s process-wide lock run one at a time.
    #[cfg(target_os = "linux")]
    static SLICE_TESTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn from(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> + use<> {
        let map: BTreeMap<String, String> =
            pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        move |key: &str| map.get(key).cloned()
    }

    fn joined(properties: &[String]) -> String {
        properties.join(" ")
    }

    #[test]
    fn a_session_scope_gets_memory_a_throttle_below_it_a_task_cap_and_a_cpu_weight() {
        // huge-blue: 63 GB.
        let props = properties(&from(&[]), 63 * GIB);
        let half = 63 * GIB / 2;
        assert_eq!(
            joined(&props),
            format!(
                "-p MemoryMax={half} -p MemoryHigh={} -p TasksMax=4096 -p CPUWeight=50",
                half / 10 * 9
            )
        );
    }

    #[test]
    fn a_session_gets_a_fraction_of_swap_and_can_override_or_disable_it() {
        let props = properties_with_swap(&from(&[]), 8 * GIB, 4 * GIB);
        assert!(joined(&props).contains(&format!("-p MemorySwapMax={}", GIB)));
        let explicit = from(&[("ACPMUX_SESSION_SWAP_MB", "512")]);
        assert!(
            joined(&properties_with_swap(&explicit, 0, 4 * GIB))
                .contains("-p MemorySwapMax=536870912")
        );
        let off = from(&[("ACPMUX_SESSION_SWAP_MB", "0")]);
        assert!(!joined(&properties_with_swap(&off, 0, 4 * GIB)).contains("MemorySwapMax"));
    }

    #[test]
    fn profile_env_wins_over_daemon_config_then_daemon_env() {
        let config = SessionLimits {
            memory_mb: Some(6144),
            swap_mb: Some(2048),
            ..SessionLimits::default()
        };
        let profile =
            BTreeMap::from([(String::from("ACPMUX_SESSION_MEMORY_MB"), String::from("4096"))]);
        let get = knob_reader(&profile, config);
        let props = properties_with_swap(&get, 32 * GIB, 8 * GIB);
        assert!(joined(&props).contains("MemoryMax=4294967296"));
        assert!(joined(&props).contains("MemorySwapMax=2147483648"));
    }

    #[test]
    fn cli_session_budget_reaches_a_new_scope() {
        let mut config = crate::config::Config::default();
        config.set_session_resource("session.memory_mb", "6144").unwrap();
        config.set_session_resource("session.swap_mb", "2048").unwrap();
        let profile = BTreeMap::new();
        let get = knob_reader(&profile, session_limits_from_config(&config));
        let props = properties_with_swap(&get, 32 * GIB, 8 * GIB);
        assert!(joined(&props).contains("MemoryMax=6442450944"));
        assert!(joined(&props).contains("MemorySwapMax=2147483648"));
    }

    #[test]
    fn the_sessions_slice_gets_a_larger_fraction_of_swap() {
        let got = slice_settings_with_swap(&from(&[]), 8 * GIB, 4 * GIB, SESSIONS_TASKS_FLOOR);
        assert!(
            got.iter()
                .any(|(key, value)| *key == "MemorySwapMax" && value == &(3 * GIB).to_string())
        );
        let off = slice_settings_with_swap(
            &from(&[("ACPMUX_SESSIONS_SWAP_MAX", "0")]),
            0,
            4 * GIB,
            SESSIONS_TASKS_FLOOR,
        );
        assert!(off.iter().any(|(key, value)| *key == "MemorySwapMax" && value == "infinity"));
        let sized = slice_settings_with_swap(
            &from(&[("ACPMUX_SESSIONS_SWAP_MAX", "4G")]),
            0,
            8 * GIB,
            SESSIONS_TASKS_FLOOR,
        );
        assert!(
            sized
                .iter()
                .any(|(key, value)| *key == "MemorySwapMax" && value == &(4 * GIB).to_string())
        );
    }

    #[test]
    fn each_limit_follows_its_env_and_zero_turns_it_off() {
        let get = from(&[
            ("ACPMUX_SESSION_MEMORY_MB", "512"),
            ("ACPMUX_SESSION_TASKS_MAX", "1000"),
            ("ACPMUX_SESSION_CPU_WEIGHT", "40"),
        ]);
        assert_eq!(
            joined(&properties(&get, 64 * GIB)),
            "-p MemoryMax=536870912 -p MemoryHigh=483183819 -p TasksMax=1000 -p CPUWeight=40"
        );
        // An explicit throttle; one above the ceiling is the ceiling.
        let get =
            from(&[("ACPMUX_SESSION_MEMORY_MB", "512"), ("ACPMUX_SESSION_MEMORY_HIGH_MB", "400")]);
        assert!(joined(&properties(&get, 0)).contains("-p MemoryHigh=419430400 "));
        let get =
            from(&[("ACPMUX_SESSION_MEMORY_MB", "512"), ("ACPMUX_SESSION_MEMORY_HIGH_MB", "900")]);
        assert!(joined(&properties(&get, 0)).contains("-p MemoryHigh=536870912 "));
        // Only the throttle off.
        let get = from(&[("ACPMUX_SESSION_MEMORY_HIGH_MB", "0")]);
        assert_eq!(
            joined(&properties(&get, 8 * GIB)),
            format!("-p MemoryMax={} -p TasksMax=4096 -p CPUWeight=50", 4 * GIB)
        );
        // No task cap, other limits on: an explicit `infinity`, not systemd's default.
        let get = from(&[("ACPMUX_SESSION_TASKS_MAX", "0"), ("ACPMUX_SESSION_MEMORY_MB", "0")]);
        assert_eq!(joined(&properties(&get, 0)), "-p TasksMax=infinity -p CPUWeight=50");
        // Every limit off: no scope at all.
        let off = from(&[
            ("ACPMUX_SESSION_MEMORY_MB", "0"),
            ("ACPMUX_SESSION_TASKS_MAX", "0"),
            ("ACPMUX_SESSION_CPU_WEIGHT", "0"),
        ]);
        assert!(properties(&off, 64 * GIB).is_empty());
        // Unknown memory and no env: still capped by tasks and weight.
        assert_eq!(joined(&properties(&from(&[]), 0)), "-p TasksMax=4096 -p CPUWeight=50");
        // Unreadable values fall back to the defaults.
        let junk = from(&[("ACPMUX_SESSION_TASKS_MAX", "lots")]);
        assert!(joined(&properties(&junk, 0)).contains("TasksMax=4096"));
    }

    #[test]
    fn the_scope_joins_the_sessions_slice_and_runs_the_harness_after_the_separator() {
        let props = properties(&from(&[("ACPMUX_SESSION_MEMORY_MB", "512")]), 0);
        let argv =
            scope_argv("/usr/bin/systemd-run", Some(SESSIONS_SLICE), "acpmux session s1", &props);
        assert_eq!(
            argv.join(" "),
            "/usr/bin/systemd-run --user --scope --quiet --collect \
             --slice=acpmuxsessions.slice --description=acpmux session s1 \
             -p MemoryMax=536870912 -p MemoryHigh=483183819 -p TasksMax=4096 -p CPUWeight=50 --"
        );
        // The probe stays out of the slice.
        let probe = scope_argv("/usr/bin/systemd-run", None, "acpmux scope probe", &props);
        assert!(!probe.iter().any(|a| a.starts_with("--slice")), "{probe:?}");
        assert!(!SESSIONS_SLICE.trim_end_matches(".slice").contains('-'), "a dash nests slices");
    }

    #[test]
    fn the_sessions_slice_caps_all_sessions_together_in_absolute_values() {
        let pair = |k: &'static str, v: &str| (k, v.to_owned());
        let default_max = (64 * GIB * 85 / 100).to_string();
        // 64 GiB: 85% and 80%, in bytes.
        assert_eq!(
            slice_settings(&from(&[]), 64 * GIB),
            [
                pair("MemoryMax", &default_max),
                pair("MemoryHigh", &(64 * GIB * 80 / 100).to_string()),
                pair("TasksMax", "16384"),
            ]
        );
        let get = from(&[
            ("ACPMUX_SESSIONS_MEMORY_MAX", "48G"),
            ("ACPMUX_SESSIONS_MEMORY_HIGH", "0"),
            ("ACPMUX_SESSIONS_TASKS_MAX", "infinity"),
        ]);
        assert_eq!(
            slice_settings(&get, 64 * GIB),
            [
                pair("MemoryMax", &(48 * GIB).to_string()),
                pair("MemoryHigh", "infinity"),
                pair("TasksMax", "infinity"),
            ],
            "0 turns a limit off explicitly, so one set earlier goes"
        );
        let get =
            from(&[("ACPMUX_SESSIONS_MEMORY_MAX", "50%"), ("ACPMUX_SESSIONS_TASKS_MAX", "0")]);
        let got = slice_settings(&get, 64 * GIB);
        assert_eq!(got[0], pair("MemoryMax", &(32 * GIB).to_string()));
        assert_eq!(got[2], pair("TasksMax", "infinity"));
        // Not a size or a count: the default, never passed through.
        for junk in ["1.5G", "120%", "-1", "85%; rm", "", "G", "0%", "99999999999T"] {
            let got = slice_settings(&from(&[("ACPMUX_SESSIONS_MEMORY_MAX", junk)]), 64 * GIB);
            assert_eq!(got[0], pair("MemoryMax", &default_max), "{junk:?}");
        }
        for junk in ["16K", "50%", "-1", "lots"] {
            let got = slice_settings(&from(&[("ACPMUX_SESSIONS_TASKS_MAX", junk)]), 64 * GIB);
            assert_eq!(got[2], pair("TasksMax", "16384"), "{junk:?}");
        }
        // Unknown memory: the percentages leave memory as it is.
        assert_eq!(slice_settings(&from(&[]), 0), [pair("TasksMax", "16384")]);
    }

    #[test]
    fn a_slice_that_has_its_limits_is_not_written_again() {
        let wanted = [
            ("MemoryMax", "1000".to_owned()),
            ("MemoryHigh", "infinity".to_owned()),
            ("TasksMax", "16384".to_owned()),
        ];
        assert_eq!(
            slice_changes("MemoryMax=infinity\nMemoryHigh=infinity\nTasksMax=4915\n", &wanted),
            ["MemoryMax=1000", "TasksMax=16384"]
        );
        let set = "MemoryMax=1000\nMemoryHigh=infinity\nTasksMax=16384\n";
        assert!(slice_changes(set, &wanted).is_empty());
        // Nothing shown: everything is set.
        assert_eq!(slice_changes("", &wanted).len(), 3);
        assert_eq!(
            slice_changes("MemoryMax=10000\n", &wanted[..1]),
            ["MemoryMax=1000"],
            "a prefix is not a match"
        );
    }

    /// With a real user manager: limits go onto a slice of this test's own
    /// (never the sessions slice), a second call with the same limits
    /// writes nothing, a limit turned off goes, and the slice is reverted.
    /// Without a user manager this says so and passes.
    #[test]
    #[cfg(target_os = "linux")]
    fn a_real_user_manager_takes_the_slice_limits_once() {
        let _serial = SLICE_TESTS.lock().unwrap_or_else(|e| e.into_inner());
        let systemctl = std::path::Path::new("/usr/bin/systemctl");
        let env = BTreeMap::new();
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let manager = run_bounded(systemctl, &args(&["--user", "show-environment"]), &env, false);
        if manager.is_none() {
            eprintln!("no user systemd manager here: skipped");
            return;
        }
        let slice = format!("acpmuxtest{}.slice", std::process::id());
        let wanted = |tasks: &str| {
            vec![
                ("MemoryMax", GIB.to_string()),
                ("MemoryHigh", "infinity".to_owned()),
                ("TasksMax", tasks.to_owned()),
            ]
        };
        let first = limit_slice(systemctl, &slice, &wanted("100"), &env);
        let again = limit_slice(systemctl, &slice, &wanted("100"), &env);
        let off = limit_slice(systemctl, &slice, &wanted("infinity"), &env);
        let shown = run_bounded(
            systemctl,
            &args(&["--user", "show", &slice, "-p", "MemoryMax", "-p", "TasksMax"]),
            &env,
            true,
        );
        run_bounded(systemctl, &args(&["--user", "revert", &slice]), &env, false);
        assert!(first.as_ref().is_ok_and(|n| *n >= 2), "{first:?}");
        assert_eq!(again, Ok(0), "unchanged limits are not written again");
        assert_eq!(off, Ok(1));
        let shown = shown.unwrap_or_default();
        assert!(shown.contains(&format!("MemoryMax={GIB}")), "{shown}");
        assert!(shown.contains("TasksMax=infinity"), "{shown}");
    }

    /// A second session start never queues behind one that is setting the
    /// slice's limits (its `systemctl` may hang for the full timeout).
    #[test]
    #[cfg(target_os = "linux")]
    fn a_session_start_never_waits_for_another_to_set_the_slice() {
        let _serial = SLICE_TESTS.lock().unwrap_or_else(|e| e.into_inner());
        let (held, release) = std::sync::mpsc::channel::<()>();
        let (go, ready) = std::sync::mpsc::channel::<()>();
        let marker = std::env::temp_dir().join(format!("acpmux-stalled-{}", std::process::id()));
        let _ = std::fs::remove_file(&marker);
        let seen = marker.clone();
        let holder = std::thread::spawn(move || {
            // A `systemctl` that says it started, then stalls.
            let stall = std::env::temp_dir().join(format!("acpmux-stall-{}", std::process::id()));
            crate::test_exec::write_executable(
                &stall,
                format!("#!/bin/sh\n: > '{}'\nsleep 2\n", seen.display()),
            );
            let wanted = [("TasksMax", "1".to_owned())];
            go.send(()).unwrap();
            let _ = limit_slice(&stall, "acpmuxunused.slice", &wanted, &BTreeMap::new());
            let _ = std::fs::remove_file(&stall);
            let _ = release.recv();
        });
        ready.recv().unwrap();
        // The holder is in its stalled `systemctl` (so it holds the lock).
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !marker.exists() {
            assert!(std::time::Instant::now() < deadline, "the stalled systemctl never ran");
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let _ = std::fs::remove_file(&marker);
        let started = std::time::Instant::now();
        let nowhere = std::path::Path::new("/nonexistent/systemctl");
        let wanted = [("TasksMax", "1".to_owned())];
        assert_eq!(limit_slice(nowhere, "acpmuxunused.slice", &wanted, &BTreeMap::new()), Ok(0));
        assert!(started.elapsed() < std::time::Duration::from_millis(500), "it waited");
        let _ = held.send(());
        holder.join().unwrap();
    }

    #[test]
    fn a_host_scope_takes_the_session_task_cap() {
        assert_eq!(tasks_max(&from(&[])), Some(SESSION_TASKS_MAX));
        assert_eq!(tasks_max(&from(&[("ACPMUX_SESSION_TASKS_MAX", "8192")])), Some(8192));
        assert_eq!(tasks_max(&from(&[("ACPMUX_SESSION_TASKS_MAX", "0")])), None);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn cached_scope_capability_still_reconciles_shared_slice_limits() {
        let _serial = SLICE_TESTS.lock().unwrap_or_else(|e| e.into_inner());
        let root = tempfile::tempdir().unwrap();
        let runner = root.path().join("systemd-run");
        let log = root.path().join("slice.log");
        crate::test_exec::write_executable(&runner, "#!/bin/sh\nexit 0\n");
        crate::test_exec::write_executable(
            root.path().join("systemctl"),
            "#!/bin/sh\necho \"$*\" >> \"$FAKE_SCOPE_LOG\"\n",
        );
        let mut env = BTreeMap::from([
            ("FAKE_SCOPE_LOG".to_owned(), log.to_string_lossy().into_owned()),
            ("ACPMUX_SESSIONS_SWAP_MAX".to_owned(), "1M".to_owned()),
        ]);
        assert!(can_scope(&runner, &[], &env, SessionLimits::default()));
        env.insert("ACPMUX_SESSIONS_SWAP_MAX".to_owned(), "0".to_owned());
        assert!(can_scope(&runner, &[], &env, SessionLimits::default()));
        env.insert("ACPMUX_SESSIONS_SWAP_MAX".to_owned(), "1M".to_owned());
        assert!(can_scope(&runner, &[], &env, SessionLimits::default()));
        let calls = std::fs::read_to_string(log).unwrap();
        let sets: Vec<_> = calls.lines().filter(|line| line.contains("set-property")).collect();
        assert_eq!(sets.len(), 3, "a cache hit must still reconcile: {calls}");
        assert!(sets[1].ends_with("MemorySwapMax=infinity"));
        assert!(sets[2].ends_with("MemorySwapMax=1048576"));
    }

    fn limits(tasks: Option<u64>, sessions: Option<u64>) -> SessionLimits {
        SessionLimits { tasks_max: tasks, sessions_tasks_max: sessions, ..SessionLimits::default() }
    }

    fn slice_tasks(wanted: &[(&'static str, String)]) -> Option<String> {
        wanted.iter().find(|(key, _)| *key == "TasksMax").map(|(_, value)| value.clone())
    }

    #[test]
    fn typed_config_task_caps_win_over_env() {
        let profile = BTreeMap::from([
            ("ACPMUX_SESSION_TASKS_MAX".to_owned(), "1000".to_owned()),
            ("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "20000".to_owned()),
        ]);
        let config = limits(Some(2048), Some(50_000));
        assert_eq!(scope_tasks_max(&profile, config), Some(2048));
        let props = properties(&knob_reader(&profile, config), 0);
        assert!(joined(&props).contains("-p TasksMax=2048 "), "{props:?}");
        let wanted = sessions_slice_wanted(&profile, config, 64 * GIB, 0, Some(514_402));
        assert_eq!(slice_tasks(&wanted).as_deref(), Some("50000"));
    }

    #[test]
    fn env_task_caps_win_over_the_computed_default() {
        let profile = BTreeMap::from([
            ("ACPMUX_SESSION_TASKS_MAX".to_owned(), "1000".to_owned()),
            ("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "20000".to_owned()),
        ]);
        let none = SessionLimits::default();
        assert_eq!(scope_tasks_max(&profile, none), Some(1000));
        let wanted = sessions_slice_wanted(&profile, none, 64 * GIB, 0, Some(514_402));
        assert_eq!(slice_tasks(&wanted).as_deref(), Some("20000"));
        // Nothing set: the computed defaults.
        let empty = BTreeMap::new();
        assert_eq!(scope_tasks_max(&empty, none), Some(SESSION_TASKS_MAX));
        let wanted = sessions_slice_wanted(&empty, none, 64 * GIB, 0, Some(514_402));
        assert_eq!(slice_tasks(&wanted).as_deref(), Some("128600"));
    }

    #[test]
    fn the_slice_task_default_scales_with_threads_max_between_a_floor_and_a_ceiling() {
        // A 64 GiB, 32-core fleet host: threads-max 514402, a quarter of it.
        assert_eq!(sessions_tasks_default(Some(514_402)), 128_600);
        // A small machine: never below the old fixed cap.
        assert_eq!(sessions_tasks_default(Some(30_000)), 16_384);
        assert_eq!(sessions_tasks_default(Some(65_536)), 16_384);
        assert_eq!(sessions_tasks_default(Some(0)), 16_384);
        // A very large machine: at most 262144.
        assert_eq!(sessions_tasks_default(Some(4_194_304)), 262_144);
        assert_eq!(sessions_tasks_default(Some(u64::MAX)), 262_144);
        // threads-max unreadable: the old fixed cap.
        assert_eq!(sessions_tasks_default(None), 16_384);
        assert_eq!(parse_threads_max("514402\n"), Some(514_402));
        assert_eq!(parse_threads_max("lots"), None);
        assert_eq!(parse_threads_max(""), None);
        let pair = |k: &'static str, v: &str| (k, v.to_owned());
        let got = slice_settings_with_swap(&from(&[]), 0, 0, sessions_tasks_default(Some(514_402)));
        assert_eq!(got, [pair("TasksMax", "128600")]);
        // A junk env value takes the computed default, not 16384.
        let junk = from(&[("ACPMUX_SESSIONS_TASKS_MAX", "lots")]);
        let got = slice_settings_with_swap(&junk, 0, 0, sessions_tasks_default(Some(514_402)));
        assert_eq!(got, [pair("TasksMax", "128600")]);
    }

    #[test]
    fn zero_and_infinity_still_turn_a_task_cap_off() {
        let empty = BTreeMap::new();
        // Typed config 0: no cap, written as `infinity`.
        let off = limits(Some(0), Some(0));
        assert_eq!(scope_tasks_max(&empty, off), None);
        let props = properties(&knob_reader(&empty, off), 0);
        assert!(joined(&props).contains("-p TasksMax=infinity "), "{props:?}");
        let wanted = sessions_slice_wanted(&empty, off, 0, 0, Some(514_402));
        assert_eq!(slice_tasks(&wanted).as_deref(), Some("infinity"));
        // The env's 0 and `infinity` as before.
        for value in ["0", "infinity"] {
            let env = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), value.to_owned())]);
            let wanted = sessions_slice_wanted(&env, SessionLimits::default(), 0, 0, Some(514_402));
            assert_eq!(slice_tasks(&wanted).as_deref(), Some("infinity"), "{value}");
        }
        let env = BTreeMap::from([("ACPMUX_SESSION_TASKS_MAX".to_owned(), "0".to_owned())]);
        assert_eq!(scope_tasks_max(&env, SessionLimits::default()), None);
        // A typed cap beats an env that turns it off, and the other way round.
        let env = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "0".to_owned())]);
        let wanted = sessions_slice_wanted(&env, limits(None, Some(40_000)), 0, 0, None);
        assert_eq!(slice_tasks(&wanted).as_deref(), Some("40000"));
        let env = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "40000".to_owned())]);
        let wanted = sessions_slice_wanted(&env, limits(None, Some(0)), 0, 0, None);
        assert_eq!(slice_tasks(&wanted).as_deref(), Some("infinity"));
    }

    #[test]
    fn the_slice_and_every_scope_read_the_task_caps_from_one_source() {
        // Two profiles that disagree in their env: with the typed config set,
        // both ask the shared slice for the same cap, so neither rewrites it.
        let a = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "20000".to_owned())]);
        let b = BTreeMap::from([("ACPMUX_SESSIONS_TASKS_MAX".to_owned(), "30000".to_owned())]);
        let config = limits(Some(3000), Some(100_000));
        let wa = sessions_slice_wanted(&a, config, 64 * GIB, 0, Some(514_402));
        let wb = sessions_slice_wanted(&b, config, 64 * GIB, 0, Some(514_402));
        assert_eq!(wa, wb);
        assert!(
            slice_changes("TasksMax=100000\n", &[("TasksMax", slice_tasks(&wb).unwrap())])
                .is_empty()
        );
        // The host scope (no profile env yet) and a session scope agree.
        assert_eq!(scope_tasks_max(&BTreeMap::new(), config), Some(3000));
        assert_eq!(scope_tasks_max(&a, config), Some(3000));
        // The CLI's typed setting reaches both.
        let mut cfg = crate::config::Config::default();
        cfg.set_session_resource("session.tasks_max", "3000").unwrap();
        cfg.set_session_resource("session.sessions_tasks_max", "100000").unwrap();
        assert_eq!(session_limits_from_config(&cfg), config);
    }
}
