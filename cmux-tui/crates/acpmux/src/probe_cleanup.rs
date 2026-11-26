//! The model probes leave no chats behind (Lawrence 2026-10-11, "opening chat doesnt work").
//!
//! At daemon start acpmux asks every ACP harness for its models with one `session/new` in its own
//! `<acpmux home>/unattended` folder (`hub::model_probe` `probe_one`). Claude Code and Codex write a
//! transcript for that session, which showed up in All chats as "New chat · unattended". No
//! person works in that folder, so every transcript recorded there is a probe's: this removes
//! them after each probe and once at start (probes of earlier runs).

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// At daemon start: the probe transcripts earlier runs left in the
/// unattended folder, and `_acpmux/complete` run folders a crash left
/// behind (`complete::places`).
pub fn at_daemon_start() {
    let unattended = crate::protected_folders::unattended_cwd();
    let ended = end_earlier_probes(&unattended);
    if ended > 0 {
        tracing::info!(ended, "ended model probes an earlier daemon left running");
    }
    remove_probe_transcripts(&unattended);
    let places = crate::complete::places::Places::for_daemon();
    let swept = places.sweep_stale_runs(crate::complete::places::STALE_RUN);
    if swept > 0 {
        tracing::info!(swept, "removed stale one-shot run folders");
    }
}

/// Ends the processes an earlier daemon started in `unattended` and left running: its model
/// probes, model lists and titlers, which it ends itself only while it runs. A stop that does not
/// end them (a restart under systemd's `KillMode=process`, a crash, the stop watchdog's exit)
/// leaves them with nothing to end them, and an ACP harness such as `cursor-agent acp` waits on
/// its stdin forever (image roll 45732114266: two cursor-agent probes outlived the bake's restart
/// of acpmux by minutes). No person works in that folder, so every process of this user there
/// that started before this daemon is such a leftover; one this daemon started is never one.
/// Linux only (it reads `/proc`); returns how many it signalled.
pub fn end_earlier_probes(unattended: &Path) -> usize {
    #[cfg(target_os = "linux")]
    {
        let Some(own_start) = linux::start_ticks(std::process::id()) else { return 0 };
        linux::end_started_before(unattended, own_start)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = unattended;
        0
    }
}

#[cfg(target_os = "linux")]
pub(crate) mod linux {
    use std::os::unix::fs::MetadataExt;
    use std::path::Path;

    /// A process's start, in clock ticks since boot (`/proc/PID/stat` field 22).
    pub(crate) fn start_ticks(pid: u32) -> Option<u64> {
        stat_fields(pid).and_then(|f| f.get(19).and_then(|v| v.parse().ok()))
    }

    /// The fields of `/proc/PID/stat` after its `(comm)`, from field 3 (state) on.
    fn stat_fields(pid: u32) -> Option<Vec<String>> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let rest = &stat[stat.rfind(')')? + 1..];
        Some(rest.split_whitespace().map(str::to_owned).collect())
    }

    /// SIGKILL to every process of this user whose cwd is `dir` or under it and that started
    /// before `before` (clock ticks since boot), and to the group of each that leads one.
    pub(crate) fn end_started_before(dir: &Path, before: u64) -> usize {
        let Ok(entries) = std::fs::read_dir("/proc") else { return 0 };
        let uid = unsafe { libc::geteuid() };
        let own = std::process::id();
        let mut ended = 0;
        for entry in entries.flatten() {
            let Some(pid) = entry.file_name().to_str().and_then(|n| n.parse::<u32>().ok()) else {
                continue;
            };
            if pid <= 1 || pid == own {
                continue;
            }
            if entry.metadata().map(|m| m.uid() != uid).unwrap_or(true) {
                continue;
            }
            let Ok(cwd) = std::fs::read_link(entry.path().join("cwd")) else { continue };
            if !cwd.starts_with(dir) {
                continue;
            }
            let Some(fields) = stat_fields(pid) else { continue };
            let start = fields.get(19).and_then(|v| v.parse::<u64>().ok());
            if start.is_none_or(|s| s >= before) {
                continue;
            }
            let group = fields.get(2).and_then(|v| v.parse::<i32>().ok());
            let Ok(pid) = i32::try_from(pid) else { continue };
            // SAFETY: kill/killpg take a pid or group and a signal. The group is the process's
            // own (it leads it), never 0 or 1, which would name this daemon's group or every one.
            unsafe {
                if group == Some(pid) {
                    libc::killpg(pid, libc::SIGKILL);
                }
                libc::kill(pid, libc::SIGKILL);
            }
            ended += 1;
        }
        ended
    }
}

/// Removes Claude Code's and Codex's transcripts of sessions that ran in `unattended`.
pub fn remove_probe_transcripts(unattended: &Path) {
    let Some(home) = dirs::home_dir() else { return };
    let claude =
        login_var("CLAUDE_CONFIG_DIR").map(PathBuf::from).unwrap_or_else(|| home.join(".claude"));
    remove_claude(&claude, unattended);
    let codex = login_var("CODEX_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".codex"));
    remove_codex(&codex, unattended, Duration::from_secs(3 * 24 * 3600));
}

/// A variable from the daemon's environment, else the imported login environment (under launchd
/// the daemon lacks what `.zshenv` exports), as the chat index reads its roots.
fn login_var(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .or_else(|| crate::login_env::var(key).filter(|v| !v.is_empty()))
}

/// Claude Code keeps a folder's sessions in `projects/<the folder, every non-alphanumeric
/// character a '-'>`: the probe folder's project folder holds only probes.
fn remove_claude(config: &Path, unattended: &Path) {
    let name: String = unattended
        .to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let project = config.join("projects").join(name);
    if project.is_dir() {
        let _ = crate::home_fs::remove_dir_all(&project);
    }
}

/// Codex keeps rollouts by day (`sessions/YYYY/MM/DD/rollout-*.jsonl`); the first line's
/// `session_meta` names the session's folder. Only recent files are read (a probe's is fresh).
fn remove_codex(codex: &Path, unattended: &Path, window: Duration) {
    let cutoff = SystemTime::now().checked_sub(window).unwrap_or(SystemTime::UNIX_EPOCH);
    let target = unattended.to_string_lossy();
    let mut stack = vec![codex.join("sessions")];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                // Day folders older than the window hold no probe of this run or the last ones.
                if meta.modified().map(|m| m >= cutoff).unwrap_or(true) {
                    stack.push(path);
                }
            } else if meta.modified().map(|m| m >= cutoff).unwrap_or(false)
                && path.extension().is_some_and(|e| e == "jsonl")
                && rollout_cwd(&path).is_some_and(|cwd| cwd == target)
            {
                let _ = crate::home_fs::remove_file(&path);
            }
        }
    }
}

/// The `cwd` of a Codex rollout's first line (`{"type":"session_meta","payload":{"cwd":...}}`).
fn rollout_cwd(path: &Path) -> Option<String> {
    use std::io::{BufRead, BufReader, Read};
    let file = fs::File::open(path).ok()?;
    let mut first = String::new();
    // A session_meta line carries instructions too; 1 MiB bounds a broken file.
    BufReader::new(file.take(1 << 20)).read_line(&mut first).ok().filter(|n| *n > 0)?;
    let value: serde_json::Value = serde_json::from_str(first.trim()).ok()?;
    value.get("payload")?.get("cwd")?.as_str().map(str::to_owned)
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use std::time::{Duration, Instant};

    fn gone(pid: u32) -> bool {
        // Reaped, or a zombie this test has yet to reap.
        std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .map(|s| s[s.rfind(')').unwrap() + 1..].trim_start().starts_with('Z'))
            .unwrap_or(true)
    }

    #[test]
    fn an_earlier_daemons_probe_in_unattended_ends_and_a_later_one_stays() {
        let dir = tempfile::tempdir().unwrap();
        let unattended = dir.path().join("unattended");
        std::fs::create_dir_all(&unattended).unwrap();
        let spawn = || {
            let mut cmd = std::process::Command::new("sleep");
            cmd.arg("30").current_dir(&unattended);
            std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
            cmd.spawn().unwrap()
        };
        let mut earlier = spawn();
        // Start ticks are 10 ms apart: the next process starts on a later tick.
        std::thread::sleep(Duration::from_millis(50));
        let cutoff = super::linux::start_ticks(earlier.id()).unwrap() + 1;
        std::thread::sleep(Duration::from_millis(50));
        let mut later = spawn();
        let elsewhere_dir = tempfile::tempdir().unwrap();
        let mut elsewhere = std::process::Command::new("sleep")
            .arg("30")
            .current_dir(elsewhere_dir.path())
            .spawn()
            .unwrap();
        assert_eq!(super::linux::end_started_before(&unattended, cutoff), 1);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !gone(earlier.id()) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(gone(earlier.id()), "the earlier probe still runs");
        assert!(!gone(later.id()), "a probe of this daemon was ended");
        assert!(!gone(elsewhere.id()), "a process outside unattended was ended");
        for child in [&mut earlier, &mut later, &mut elsewhere] {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
