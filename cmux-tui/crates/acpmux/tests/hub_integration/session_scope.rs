//! Each chat's harness in its own cgroup scope on Linux (cx-v9s8g): the
//! guard for the harness limits acpmux lifts. `systemd-run --user --scope`
//! starts it with a memory ceiling and a lower CPU weight, which the kernel
//! enforces; nothing measures or scans processes. Where systemd cannot make a
//! scope (no user manager), the harness starts as before.
//!
//! A fake `systemd-run` on the profile's PATH logs each call and, unless told
//! to fail, runs the command after `--` as the real one does.

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
        &[("ACPMUX_SESSION_MEMORY_MB", "512"), ("ACPMUX_SESSION_CPU_WEIGHT", "40")],
    )
    .await;
    let launches = launches(&log);
    assert_eq!(launches.len(), 1, "one scoped launch: {log:?}");
    let line = launches[0];
    for part in [
        "--user",
        "--scope",
        "-p MemoryMax=536870912",
        "-p CPUWeight=40",
        "-p OOMPolicy=continue",
        "-- python3",
    ] {
        assert!(line.contains(part), "{part:?} in {line:?}");
    }
}

#[tokio::test]
async fn a_chat_starts_unscoped_when_systemd_cannot_make_a_scope() {
    let log = chat_scope_log("noscope", &[("FAKE_SCOPE_FAIL", "1")]).await;
    // systemd-run was asked whether it can make a scope, and said no.
    assert!(!log.is_empty() && log.iter().all(|l| l.contains("--scope")), "{log:?}");
    assert!(launches(&log).is_empty(), "{log:?}");
}

#[tokio::test]
async fn no_limits_set_means_no_scope() {
    let log = chat_scope_log(
        "nolimits",
        &[("ACPMUX_SESSION_MEMORY_MB", "0"), ("ACPMUX_SESSION_CPU_WEIGHT", "0")],
    )
    .await;
    assert!(log.is_empty(), "{log:?}");
}
