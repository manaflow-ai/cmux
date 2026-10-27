//! Each session's harness in its own cgroup scope on Linux (cx-v9s8g): the
//! guard for the harness limits acpmux lifts (`harness_limits.rs`), which
//! allow as many subagents and background commands as the agent starts.
//!
//! `systemd-run --user --scope` starts the harness (it execs it, so the pid
//! and process group stay the harness's) in a transient scope with a memory
//! ceiling (`MemoryMax`) and a lower CPU weight (`CPUWeight`). The kernel
//! enforces both: a runaway's memory is reclaimed or killed inside its own
//! session, and a busy session yields the CPU to the rest of the machine.
//! Nothing measures or scans processes (plans/cmux-next/pty-holder.md 4).
//!
//! The limits come from the profile's env, then the daemon's:
//! `ACPMUX_SESSION_MEMORY_MB` (default half the machine's memory) and
//! `ACPMUX_SESSION_CPU_WEIGHT` (default 50; systemd's own is 100). 0 turns one
//! off. Where `systemd-run` is missing or cannot make a scope (no user
//! manager, as in a container), the harness starts as before; that answer is
//! asked once per `systemd-run` and limits. macOS gets the process-group
//! half of the valve on the holder track (cx-t2sqm.3).

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
        Some(prefix) => match prefix.split_first() {
            Some((scope, args)) => {
                let mut cmd = Command::new(scope);
                cmd.args(args).arg(program);
                cmd
            }
            None => Command::new(program),
        },
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
    let properties = properties(env);
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
    let mut argv = vec![
        runner.to_string_lossy().into_owned(),
        "--user".to_owned(),
        "--scope".to_owned(),
        "--quiet".to_owned(),
        "--collect".to_owned(),
        format!("--description=acpmux session {session}"),
    ];
    argv.extend(properties);
    argv.push("--".to_owned());
    Some(argv)
}

/// `-p` pairs for the scope's limits; empty when both are off.
#[cfg(target_os = "linux")]
fn properties(env: &BTreeMap<String, String>) -> Vec<String> {
    let knob = |key: &str| {
        env.get(key)
            .cloned()
            .or_else(|| std::env::var(key).ok())
            .and_then(|v| v.trim().parse::<u64>().ok())
    };
    let memory = knob("ACPMUX_SESSION_MEMORY_MB")
        .map_or(physical_memory() / 2, |mb| mb.saturating_mul(1024 * 1024));
    let weight = knob("ACPMUX_SESSION_CPU_WEIGHT").unwrap_or(50).min(10_000);
    let mut out = Vec::new();
    if memory > 0 {
        out.extend(["-p".to_owned(), format!("MemoryMax={memory}")]);
    }
    if weight > 0 {
        out.extend(["-p".to_owned(), format!("CPUWeight={weight}")]);
    }
    out
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
    let probe = || probe(runner, properties, env);
    let multi_thread = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    let ok = if multi_thread { tokio::task::block_in_place(probe) } else { probe() };
    answers.lock().unwrap_or_else(|e| e.into_inner()).insert(key, (ok, Instant::now()));
    ok
}

/// How long a probe's answer holds.
#[cfg(target_os = "linux")]
const ANSWER_TTL: std::time::Duration = std::time::Duration::from_secs(300);

/// How long the probe may take before the answer is no.
#[cfg(target_os = "linux")]
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

#[cfg(target_os = "linux")]
fn probe(runner: &std::path::Path, properties: &[String], env: &BTreeMap<String, String>) -> bool {
    use std::process::Stdio;
    let child = std::process::Command::new(runner)
        .args(["--user", "--scope", "--quiet", "--collect", "--description=acpmux scope probe"])
        .args(properties)
        .args(["--", "true"])
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
