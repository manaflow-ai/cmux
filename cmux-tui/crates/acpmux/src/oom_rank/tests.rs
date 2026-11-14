use super::*;

#[test]
fn reads_what_the_kernel_writes() {
    assert_eq!(parse(b"200\n"), Some(200));
    assert_eq!(parse(b"-900\n"), Some(-900));
    assert_eq!(parse(b"0"), Some(0));
    assert_eq!(parse(b""), None);
    assert_eq!(parse(b"-"), None);
    assert_eq!(parse(b"x"), None);
    assert_eq!(parse(&AGENT.to_string().into_bytes()), Some(AGENT));
}

/// The kernel refuses a value below the floor it set (no
/// `CAP_SYS_RESOURCE`): the daemon stays where it was, says so, and agents
/// at [`AGENT`] still rank above it.
#[test]
fn a_refused_lowering_keeps_the_daemon_and_agents_still_rank_first() {
    let mut tried = Vec::new();
    let kept = lower(200, |step| {
        tried.push(String::from_utf8_lossy(step).into_owned());
        false
    });
    assert_eq!(kept, 200);
    assert_eq!(tried, ["-900", "-500", "0", "100"], "every lower step, lowest first");
    assert!(AGENT > kept);
    let line = describe(Protection { was: 200, now: kept });
    assert!(
        line.contains("refused") && line.contains("agents (500) are still ended first"),
        "{line}"
    );
    // A floor of 100 (a stock systemd user manager): the first step it takes stays.
    assert_eq!(lower(200, |step| step == b"100"), 100);
    assert_eq!(lower(200, |step| step == b"0" || step == b"100"), 0);
    // Never raised: nothing below where it already is is tried.
    assert_eq!(lower(-900, |_| panic!("tried to write")), -900);
    assert_eq!(lower(50, |step| step == b"100"), 50);
    assert!(describe(Protection { was: 200, now: 100 }).contains("200 -> 100"));
    assert!(describe(Protection { was: 600, now: 600 }).contains("do not rank above"));
}

/// A child's own `oom_score_adj` after `hook` ran at its exec.
#[cfg(target_os = "linux")]
async fn child_adj(hook: impl Fn() + Send + Sync + 'static) -> i32 {
    let mut cmd = tokio::process::Command::new("cat");
    cmd.arg("/proc/self/oom_score_adj");
    // SAFETY: test hooks call only this module's allocation-free functions.
    unsafe {
        cmd.pre_exec(move || {
            hook();
            Ok(())
        });
    }
    let out = cmd.output().await.unwrap();
    parse(&out.stdout).unwrap()
}

/// The daemon ends at or below where it started, an agent it starts at
/// [`AGENT`] or above, and the agent stays above the daemon whatever floor
/// this host's manager set.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn agents_rank_above_the_daemon_for_the_oom_killer() {
    let start = child_adj(|| {}).await;
    let daemon = child_adj(|| {
        imp::protect_daemon();
    })
    .await;
    assert!(daemon <= start, "the daemon went up: {start} -> {daemon}");
    let agent = child_adj(|| {
        imp::protect_daemon();
        imp::raise_agent();
    })
    .await;
    assert!(agent >= AGENT, "an agent of the daemon kept {agent}");
    assert!(agent > daemon);
    let mut cmd = tokio::process::Command::new("cat");
    cmd.arg("/proc/self/oom_score_adj");
    agent_at_exec(&mut cmd);
    let harness = parse(&cmd.output().await.unwrap().stdout).unwrap();
    assert!(harness >= AGENT, "a harness kept {harness}");
}
