//! Each chat's harness in its own cgroup scope on Linux (cx-v9s8g): the
//! guard for the harness limits acpmux lifts. `systemd-run --user --scope`
//! starts it with a memory ceiling and a lower CPU weight, which the kernel
//! enforces; nothing measures or scans processes. Where systemd cannot make a
//! scope (no user manager), the harness starts as before.
//!
//! A fake `systemd-run` on the profile's PATH logs each call and, unless told
//! to fail, runs the command after `--` as the real one does. A fake
//! `systemctl` beside it logs the sessions slice's limits.

use super::*;

/// A fake `systemd-run` in `dir`, logging to `dir/scope.log`.
fn fake_systemd_run(dir: &std::path::Path) -> String {
    let script = dir.join("systemd-run");
    std::fs::write(
        &script,
        "#!/bin/sh\necho \"$*\" >> \"$FAKE_SCOPE_LOG\"\n\
         [ \"$FAKE_SCOPE_FAIL\" = 1 ] && exit 1\n\
         while [ \"$1\" != \"--\" ]; do shift; done\nshift\nexec \"$@\"\n",
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let systemctl = dir.join("systemctl");
    std::fs::write(&systemctl, "#!/bin/sh\necho \"systemctl $*\" >> \"$FAKE_SCOPE_LOG\"\n")
        .unwrap();
    std::fs::set_permissions(&systemctl, std::fs::Permissions::from_mode(0o755)).unwrap();
    format!("{}:{}", dir.display(), std::env::var("PATH").unwrap_or_default())
}

/// Start a chat with `env` in its profile, prompt it once, and return the
/// fake `systemd-run`'s log lines.
async fn chat_scope_log(name: &str, env: &[(&str, &str)]) -> Vec<String> {
    let root = std::env::temp_dir().join(format!("acpmux-{name}-{}", uuid::Uuid::now_v7()));
    let (claude, bin) = (root.join("claude"), root.join("bin"));
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::create_dir_all(&bin).unwrap();
    let path = fake_systemd_run(&bin);
    let log = bin.join("scope.log");
    let log_s = log.to_string_lossy().into_owned();
    let mut env: Vec<(&str, &str)> = env.to_vec();
    env.extend([("PATH", path.as_str()), ("FAKE_SCOPE_LOG", log_s.as_str())]);
    let (hub, mut c) = claude_setup(&claude, &env).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    let answer = c.request(method::SESSION_PROMPT, prompt).await;
    assert!(answer.is_ok(), "the chat answers: {answer:?}");
    hub.shutdown_all().await;
    let lines = std::fs::read_to_string(&log).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&root);
    lines.lines().map(str::to_owned).collect()
}

/// The `systemd-run` calls that started the harness (not the probe).
fn launches(log: &[String]) -> Vec<&String> {
    log.iter().filter(|l| l.contains("fake_claude.py")).collect()
}

#[tokio::test]
async fn a_chats_harness_runs_in_its_own_cgroup_scope() {
    let log = chat_scope_log(
        "scope",
        &[
            ("ACPMUX_SESSION_MEMORY_MB", "512"),
            ("ACPMUX_SESSION_SWAP_MB", "0"),
            ("ACPMUX_SESSIONS_SWAP_MAX", "0"),
            ("ACPMUX_SESSION_CPU_WEIGHT", "40"),
        ],
    )
    .await;
    let launches = launches(&log);
    assert_eq!(launches.len(), 1, "one scoped launch: {log:?}");
    let line = launches[0];
    for part in [
        "--user",
        "--scope",
        "--slice=acpmuxsessions.slice",
        "-p MemoryMax=536870912",
        "-p MemoryHigh=483183819",
        "-p TasksMax=4096",
        "-p CPUWeight=40",
        "-p OOMPolicy=continue",
        "-- python3",
    ] {
        assert!(line.contains(part), "{part:?} in {line:?}");
    }
    // The slice that caps every session together was read, then got its
    // limits (the fake shows none) in bytes and tasks, before the launch.
    let calls: Vec<&String> = log.iter().filter(|l| l.starts_with("systemctl ")).collect();
    assert_eq!(calls.len(), 2, "{log:?}");
    assert_eq!(
        calls[0],
        "systemctl --user --no-pager show acpmuxsessions.slice -p MemoryMax -p MemoryHigh -p TasksMax -p MemorySwapMax"
    );
    let set = calls[1];
    // The slice's task default is a quarter of this machine's threads-max,
    // between 16384 and 262144 (16384 when it can't be read).
    let tasks = std::fs::read_to_string("/proc/sys/kernel/threads-max")
        .ok()
        .and_then(|text| text.trim().parse::<u64>().ok())
        .map_or(16_384, |n| (n / 4).clamp(16_384, 262_144));
    assert!(
        set.starts_with("systemctl --user set-property --runtime acpmuxsessions.slice MemoryMax=")
            && set.contains(" MemoryHigh=")
            && set.ends_with(&format!(" TasksMax={tasks} MemorySwapMax=infinity")),
        "{set}"
    );
    let at = |needle: &str| log.iter().position(|l| l.contains(needle)).unwrap();
    assert!(at("set-property") < at("fake_claude.py"), "the slice is limited before it fills");
    // The probe ran outside the slice.
    let probe = log.iter().find(|l| l.contains("scope probe")).unwrap();
    assert!(!probe.contains("--slice"), "{probe}");
}

#[tokio::test]
async fn a_chat_starts_unscoped_when_systemd_cannot_make_a_scope() {
    let log = chat_scope_log("noscope", &[("FAKE_SCOPE_FAIL", "1")]).await;
    // systemd-run was asked whether it can make a scope, and said no; the
    // slice is left alone.
    assert!(!log.is_empty() && log.iter().all(|l| l.contains("--scope")), "{log:?}");
    assert!(launches(&log).is_empty(), "{log:?}");
}

#[tokio::test]
async fn no_limits_set_means_no_scope() {
    let log = chat_scope_log(
        "nolimits",
        &[
            ("ACPMUX_SESSION_MEMORY_MB", "0"),
            ("ACPMUX_SESSION_SWAP_MB", "0"),
            ("ACPMUX_SESSIONS_SWAP_MAX", "0"),
            ("ACPMUX_SESSION_TASKS_MAX", "0"),
            ("ACPMUX_SESSION_CPU_WEIGHT", "0"),
        ],
    )
    .await;
    assert!(log.is_empty(), "{log:?}");
}
