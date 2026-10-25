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
//! `ACPMUX_SESSION_MEMORY_HIGH_MB` (default nine tenths of that),
//! `ACPMUX_SESSION_TASKS_MAX` (default 4096) and `ACPMUX_SESSION_CPU_WEIGHT`
//! (default 50; systemd's own is 100). 0 turns one off. Where `systemd-run` is
//! missing or cannot make a scope (no user manager, as in a container), the
//! harness starts as before; that answer is asked once per `systemd-run` and
//! limits. macOS gets the process-group half of the valve on the holder track
//! (cx-t2sqm.3).
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
    match session.and_then(|id| prefix(id, env)) {
        Some(prefix) => {
            let mut cmd = Command::new(&prefix[0]);
            cmd.args(&prefix[1..]).arg(program);
            cmd
        }
        None => Command::new(program),
    }
}

#[cfg(not(target_os = "linux"))]
fn prefix(_session: &str, _env: &BTreeMap<String, String>) -> Option<Vec<String>> {
    None
}

/// `systemd-run … --` for the session's scope, when it can make one.
#[cfg(target_os = "linux")]
fn prefix(session: &str, env: &BTreeMap<String, String>) -> Option<Vec<String>> {
    let properties = properties(&knob_reader(env), physical_memory());
    if properties.is_empty() {
        return None;
    }
    let runner = runner(env)?;
    // One runaway hitting `MemoryMax` ends that process, not the whole
    // scope (systemd 253+ stops a scope on OOM by default). An older systemd
    // refuses the property, and its scopes already continue.
    let mut continued = properties.clone();
    continued.extend(["-p".to_owned(), "OOMPolicy=continue".to_owned()]);
    let properties = [continued, properties]
        .into_iter()
        .find(|properties| can_scope(&runner, properties, env))?;
    Some(scope_argv(&runner.to_string_lossy(), &format!("acpmux session {session}"), &properties))
}

/// The slice every session scope joins. Dash-free: systemd reads dashes in a
/// slice name as nesting (`agent_host/scope.rs` `HOST_SLICE` likewise).
pub(crate) const SESSIONS_SLICE: &str = "acpmuxsessions.slice";

/// `runner --user --scope … --` with `properties`, in [`SESSIONS_SLICE`].
fn scope_argv(runner: &str, description: &str, properties: &[String]) -> Vec<String> {
    let mut argv = vec![
        runner.to_owned(),
        "--user".to_owned(),
        "--scope".to_owned(),
        "--quiet".to_owned(),
        "--collect".to_owned(),
        format!("--slice={SESSIONS_SLICE}"),
        format!("--description={description}"),
    ];
    argv.extend_from_slice(properties);
    argv.push("--".to_owned());
    argv
}

/// A knob's value: the profile's env, then the daemon's.
fn knob_reader(env: &BTreeMap<String, String>) -> impl Fn(&str) -> Option<String> + '_ {
    |key| env.get(key).cloned().or_else(|| std::env::var(key).ok())
}

/// The default `TasksMax` of a session scope: processes and threads
/// together. A fork storm (huge-blue, 2026-10-25: 849 git processes) stops
/// here, in its own session.
pub(crate) const SESSION_TASKS_MAX: u64 = 4096;

/// A session's `TasksMax` from `get` (`ACPMUX_SESSION_TASKS_MAX`; 0: none).
pub(crate) fn tasks_max(get: &dyn Fn(&str) -> Option<String>) -> Option<u64> {
    let n = get("ACPMUX_SESSION_TASKS_MAX")
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(SESSION_TASKS_MAX);
    (n > 0).then_some(n)
}

/// `-p` pairs for the scope's limits on a machine with `memory` bytes;
/// empty when every one is off.
fn properties(get: &dyn Fn(&str) -> Option<String>, memory: u64) -> Vec<String> {
    let knob = |key: &str| get(key).and_then(|v| v.trim().parse::<u64>().ok());
    let mb = |n: u64| n.saturating_mul(1024 * 1024);
    let max = knob("ACPMUX_SESSION_MEMORY_MB").map_or(memory / 2, mb);
    // Throttled (reclaim, slower allocation) a little before it is killed.
    let high = knob("ACPMUX_SESSION_MEMORY_HIGH_MB").map_or(max / 10 * 9, mb);
    let high = if max > 0 { high.min(max) } else { high };
    let weight = knob("ACPMUX_SESSION_CPU_WEIGHT").unwrap_or(50).min(10_000);
    let mut out = Vec::new();
    let mut set = |key: &str, value: u64| {
        if value > 0 {
            out.extend(["-p".to_owned(), format!("{key}={value}")]);
        }
    };
    set("MemoryMax", max);
    set("MemoryHigh", high);
    set("TasksMax", tasks_max(get).unwrap_or(0));
    set("CPUWeight", weight);
    out
}

/// What [`SESSIONS_SLICE`] caps for all sessions together, as `systemctl
/// set-property` takes it: `ACPMUX_SESSIONS_MEMORY_MAX` (default 85% of
/// the machine's memory), `ACPMUX_SESSIONS_MEMORY_HIGH` (default 80%) and
/// `ACPMUX_SESSIONS_TASKS_MAX` (default 16384), from the daemon's env. A
/// value is a number with an optional `K`/`M`/`G`/`T` or `%`, or
/// `infinity`; 0 leaves that one unset, anything else is the default.
fn slice_settings(get: &dyn Fn(&str) -> Option<String>) -> Vec<String> {
    let valid = |v: &str| {
        v == "infinity"
            || v.strip_suffix(['K', 'M', 'G', 'T', '%'])
                .unwrap_or(v)
                .parse::<u64>()
                .is_ok_and(|n| n > 0 && !(v.ends_with('%') && n > 100))
    };
    [
        ("MemoryMax", "ACPMUX_SESSIONS_MEMORY_MAX", "85%"),
        ("MemoryHigh", "ACPMUX_SESSIONS_MEMORY_HIGH", "80%"),
        ("TasksMax", "ACPMUX_SESSIONS_TASKS_MAX", "16384"),
    ]
    .into_iter()
    .filter_map(|(key, env, default)| {
        let value = get(env).map(|v| v.trim().to_owned());
        match value.as_deref() {
            Some("0") => None,
            Some(v) if valid(v) => Some(format!("{key}={v}")),
            _ => Some(format!("{key}={default}")),
        }
    })
    .collect()
}

/// The `systemctl` arguments that set [`slice_settings`] on
/// [`SESSIONS_SLICE`]: a runtime drop-in (`--runtime`, under
/// `$XDG_RUNTIME_DIR/systemd/user.control`), which holds until the user's
/// runtime directory goes (logout without linger, reboot) and applies
/// whenever the slice loads, also when it has no session now. Set again at
/// each fresh scope probe, so a reboot or a lost drop-in heals at the next
/// session start. None when every setting is off.
fn slice_argv(get: &dyn Fn(&str) -> Option<String>) -> Option<Vec<String>> {
    let settings = slice_settings(get);
    if settings.is_empty() {
        return None;
    }
    let mut argv: Vec<String> = ["--user", "set-property", "--runtime", SESSIONS_SLICE]
        .into_iter()
        .map(str::to_owned)
        .collect();
    argv.extend(settings);
    Some(argv)
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
) -> bool {
    use std::sync::{Mutex, OnceLock};
    use std::time::Instant;
    type Answers = Mutex<BTreeMap<(std::path::PathBuf, Vec<String>), (bool, Instant)>>;
    static ANSWERS: OnceLock<Answers> = OnceLock::new();
    let answers = ANSWERS.get_or_init(Default::default);
    let key = (runner.to_path_buf(), properties.to_vec());
    if let Some((known, at)) = answers.lock().unwrap_or_else(|e| e.into_inner()).get(&key)
        && at.elapsed() < ANSWER_TTL
    {
        return *known;
    }
    let probe = || {
        let ok = probe(runner, properties, env);
        if ok {
            limit_sessions_slice(runner, env);
        }
        ok
    };
    let multi_thread = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    let ok = if multi_thread { tokio::task::block_in_place(probe) } else { probe() };
    answers.lock().unwrap_or_else(|e| e.into_inner()).insert(key, (ok, Instant::now()));
    ok
}

/// Sets [`SESSIONS_SLICE`]'s limits ([`slice_argv`]) with the `systemctl`
/// beside `runner`, after a probe made a scope (so a user manager answers).
/// Best effort: a failure is logged, and each session still has its own
/// scope's limits. Runs with each fresh probe, so at most once per
/// [`ANSWER_TTL`] for a set of limits, and only when a session starts.
#[cfg(target_os = "linux")]
fn limit_sessions_slice(runner: &std::path::Path, env: &BTreeMap<String, String>) {
    let Some(args) = slice_argv(&|key| std::env::var(key).ok()) else {
        return;
    };
    let systemctl = runner.with_file_name("systemctl");
    if !systemctl.is_file() {
        tracing::warn!(
            "no systemctl beside {}: {SESSIONS_SLICE} keeps no limit for all sessions together",
            runner.display()
        );
        return;
    }
    if !run_bounded(&systemctl, &args, env) {
        tracing::warn!(
            "systemctl {} failed: {SESSIONS_SLICE} keeps no limit for all sessions together",
            args.join(" ")
        );
    }
}

/// How long a probe's answer holds.
#[cfg(target_os = "linux")]
const ANSWER_TTL: std::time::Duration = std::time::Duration::from_secs(300);

/// How long the probe may take before the answer is no.
#[cfg(target_os = "linux")]
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

#[cfg(target_os = "linux")]
fn probe(runner: &std::path::Path, properties: &[String], env: &BTreeMap<String, String>) -> bool {
    let mut argv = scope_argv("", "acpmux scope probe", properties);
    argv.push("true".to_owned());
    run_bounded(runner, &argv[1..], env)
}

/// Runs `program args` with `env` on top of the daemon's, no input or
/// output; whether it succeeded within [`PROBE_TIMEOUT`] (else it is killed).
#[cfg(target_os = "linux")]
fn run_bounded(program: &std::path::Path, args: &[String], env: &BTreeMap<String, String>) -> bool {
    use std::process::Stdio;
    let child = std::process::Command::new(program)
        .args(args)
        .envs(env)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else {
        return false;
    };
    let started = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if started.elapsed() < PROBE_TIMEOUT => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

/// The machine's memory in bytes (0 when unknown, which leaves memory off).
#[cfg(target_os = "linux")]
fn physical_memory() -> u64 {
    // SAFETY: sysconf only reads system configuration.
    let (pages, size) =
        unsafe { (libc::sysconf(libc::_SC_PHYS_PAGES), libc::sysconf(libc::_SC_PAGESIZE)) };
    u64::try_from(pages).unwrap_or(0).saturating_mul(u64::try_from(size).unwrap_or(0))
}

#[cfg(test)]
mod tests {
    use super::*;

    const GIB: u64 = 1024 * 1024 * 1024;

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
        let argv = scope_argv("/usr/bin/systemd-run", "acpmux session s1", &props);
        assert_eq!(
            argv.join(" "),
            "/usr/bin/systemd-run --user --scope --quiet --collect \
             --slice=acpmuxsessions.slice --description=acpmux session s1 \
             -p MemoryMax=536870912 -p MemoryHigh=483183819 -p TasksMax=4096 -p CPUWeight=50 --"
        );
        assert!(!SESSIONS_SLICE.trim_end_matches(".slice").contains('-'), "a dash nests slices");
    }

    #[test]
    fn the_sessions_slice_caps_all_sessions_together() {
        assert_eq!(
            slice_argv(&from(&[])).unwrap().join(" "),
            "--user set-property --runtime acpmuxsessions.slice \
             MemoryMax=85% MemoryHigh=80% TasksMax=16384"
        );
        let get = from(&[
            ("ACPMUX_SESSIONS_MEMORY_MAX", "48G"),
            ("ACPMUX_SESSIONS_MEMORY_HIGH", "0"),
            ("ACPMUX_SESSIONS_TASKS_MAX", "infinity"),
        ]);
        assert_eq!(slice_settings(&get), ["MemoryMax=48G", "TasksMax=infinity"]);
        // Not a systemd size: the default, never passed through.
        for junk in ["1.5G", "120%", "-1", "85%; rm", "", "G", "0%"] {
            let get = from(&[("ACPMUX_SESSIONS_MEMORY_MAX", junk)]);
            assert_eq!(slice_settings(&get)[0], "MemoryMax=85%", "{junk:?}");
        }
        let off = from(&[
            ("ACPMUX_SESSIONS_MEMORY_MAX", "0"),
            ("ACPMUX_SESSIONS_MEMORY_HIGH", "0"),
            ("ACPMUX_SESSIONS_TASKS_MAX", "0"),
        ]);
        assert_eq!(slice_argv(&off), None);
    }

    /// With a real user manager (CI has one): a scope probe in the sessions
    /// slice succeeds, and the slice then holds its limits, also though no
    /// session runs in it. Without one this says so and passes.
    #[test]
    #[cfg(target_os = "linux")]
    fn a_real_user_manager_takes_the_slice_limits() {
        use std::process::Command;
        let running = Command::new("systemctl")
            .args(["--user", "is-system-running"])
            .output()
            .is_ok_and(|o| {
                matches!(String::from_utf8_lossy(&o.stdout).trim(), "running" | "degraded")
            });
        let runner = std::path::Path::new("/usr/bin/systemd-run");
        if !running || !runner.is_file() {
            eprintln!("no user systemd manager here: skipped");
            return;
        }
        let props = properties(&from(&[]), physical_memory());
        let mut continued = props.clone();
        continued.extend(["-p".to_owned(), "OOMPolicy=continue".to_owned()]);
        let env = BTreeMap::new();
        assert!(
            can_scope(runner, &continued, &env) || can_scope(runner, &props, &env),
            "systemd-run made no scope with {props:?}"
        );
        let show = |key: &str| {
            let out = Command::new("systemctl")
                .args(["--user", "show", SESSIONS_SLICE, "-p", key, "--value"])
                .output()
                .unwrap();
            String::from_utf8_lossy(&out.stdout).trim().to_owned()
        };
        assert_eq!(show("TasksMax"), "16384");
        for key in ["MemoryMax", "MemoryHigh"] {
            let bytes: u64 = show(key).parse().unwrap_or_else(|_| panic!("{key}: {}", show(key)));
            assert!(bytes > 0 && bytes < physical_memory(), "{key}={bytes}");
        }
    }

    #[test]
    fn a_host_scope_takes_the_session_task_cap() {
        assert_eq!(tasks_max(&from(&[])), Some(SESSION_TASKS_MAX));
        assert_eq!(tasks_max(&from(&[("ACPMUX_SESSION_TASKS_MAX", "8192")])), Some(8192));
        assert_eq!(tasks_max(&from(&[("ACPMUX_SESSION_TASKS_MAX", "0")])), None);
    }
}
