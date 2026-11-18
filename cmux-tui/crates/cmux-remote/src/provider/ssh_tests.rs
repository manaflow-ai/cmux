use super::*;

#[cfg(unix)]
#[tokio::test]
async fn close_lets_the_remote_command_observe_eof_before_reaping_ssh() {
    let directory = tempfile::tempdir().unwrap();
    let outcome = directory.path().join("outcome");
    let mut command = Command::new("/bin/sh");
    command
        .args(["-c", "cat >/dev/null; printf graceful > \"$CMUX_TEST_OUTCOME\""])
        .env("CMUX_TEST_OUTCOME", &outcome)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().unwrap();
    let stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let link = SshProcessLink {
        inner: LengthDelimitedLink::new("ssh://test", 1024, stdout, stdin),
        child: Mutex::new(Some(child)),
        stderr: None,
        forwarding: None,
    };

    link.close().await.unwrap();

    assert_eq!(std::fs::read_to_string(outcome).unwrap(), "graceful");
}

/// A fake `ssh` that appends its arguments, one run per line, to
/// `args`, says `stderr` on its stderr and exits.
#[cfg(unix)]
fn fake_ssh(directory: &std::path::Path, stderr: &str) -> (String, std::path::PathBuf) {
    use std::os::unix::fs::PermissionsExt as _;
    let args = directory.join("args");
    let script = directory.join("ssh");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\necho \"$*\" >> '{}'\nprintf '%s\\n' '{stderr}' >&2\nexit 255\n",
            args.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    (script.to_str().unwrap().to_owned(), args)
}

#[cfg(unix)]
async fn group_with(ssh_binary: String, extra_args: &[&str]) -> Arc<dyn LinkGroup> {
    let provider = SshProvider::new(SshProviderConfig {
        ssh_binary,
        extra_args: extra_args.iter().map(|argument| (*argument).to_owned()).collect(),
        ..SshProviderConfig::default()
    })
    .unwrap();
    provider
        .connect(ConnectRequest {
            endpoint: url::Url::parse("ssh://host.example").unwrap(),
            session: cmux_remote_protocol::SessionId::ZERO,
            lane_policy: cmux_remote_protocol::LanePolicy::Single,
            routing: std::collections::BTreeMap::new(),
        })
        .await
        .unwrap()
}

/// Opens one link of `generation` and waits for its ssh run to end.
#[cfg(unix)]
async fn open_and_end(group: &Arc<dyn LinkGroup>, generation: u64) {
    let link = group
        .open(LinkRequest { lane: cmux_remote_protocol::Lane::Interactive, generation })
        .await
        .unwrap();
    assert!(matches!(link.receive().await, Ok(None) | Err(_)));
    link.close().await.unwrap();
}

/// Each run's ConnectTimeout as ssh reads it: the first one given.
#[cfg(unix)]
fn connect_timeouts(args: &std::path::Path) -> Vec<String> {
    std::fs::read_to_string(args)
        .unwrap()
        .lines()
        .map(|run| {
            let words: Vec<&str> = run.split_whitespace().collect();
            words
                .windows(2)
                .find_map(|pair| {
                    (pair[0] == "-o" && pair[1].starts_with("ConnectTimeout="))
                        .then(|| pair[1].to_owned())
                })
                .or_else(|| {
                    words.iter().find_map(|word| {
                        word.strip_prefix("-o")
                            .filter(|option| option.starts_with("ConnectTimeout="))
                            .map(str::to_owned)
                    })
                })
                .unwrap_or_default()
        })
        .collect()
}

/// The probe's 10 s drops: a redial with the caller's 15 s ConnectTimeout
/// sat in TCP's SYN backoff when the network came back. A redial gets 3 s;
/// the first connect keeps the caller's.
#[cfg(unix)]
#[tokio::test]
async fn a_redial_gives_up_on_a_dead_network_within_three_seconds() {
    let directory = tempfile::tempdir().unwrap();
    let (ssh, args) = fake_ssh(directory.path(), "ssh: connect to host: Operation timed out");
    let group = group_with(ssh, &["-oBatchMode=yes", "-oConnectTimeout=15"]).await;

    open_and_end(&group, 0).await;
    open_and_end(&group, 1).await;
    open_and_end(&group, 2).await;

    assert_eq!(
        connect_timeouts(&args),
        ["ConnectTimeout=15", "ConnectTimeout=3", "ConnectTimeout=3"]
    );
}

/// A host slow to send its banner is not a dead network: once ssh says
/// so, redials keep the caller's timeout, as acpmux's peer does.
#[cfg(unix)]
#[tokio::test]
async fn a_banner_timeout_gives_later_redials_the_callers_timeout() {
    let directory = tempfile::tempdir().unwrap();
    let (ssh, args) = fake_ssh(directory.path(), "Connection timed out during banner exchange");
    let group = group_with(ssh, &["-oConnectTimeout=15"]).await;

    open_and_end(&group, 1).await;
    open_and_end(&group, 2).await;
    open_and_end(&group, 3).await;

    assert_eq!(
        connect_timeouts(&args),
        ["ConnectTimeout=3", "ConnectTimeout=15", "ConnectTimeout=15"]
    );
}

/// Lanes of one generation open while the first lane's ssh still runs:
/// its stderr stays open, and a later lane must not wait for it.
#[cfg(unix)]
#[tokio::test]
async fn another_lane_of_the_same_redial_does_not_wait_for_a_live_stderr() {
    use std::os::unix::fs::PermissionsExt as _;
    let directory = tempfile::tempdir().unwrap();
    let script = directory.path().join("ssh");
    std::fs::write(&script, "#!/bin/sh\nexec sleep 30\n").unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let group = group_with(script.to_str().unwrap().to_owned(), &[]).await;
    let request = || LinkRequest { lane: cmux_remote_protocol::Lane::Interactive, generation: 1 };

    let first = group.open(request()).await.unwrap();
    let started = std::time::Instant::now();
    let second = group.open(request()).await.unwrap();

    assert!(started.elapsed() < STDERR_SETTLE, "waited {:?}", started.elapsed());
    first.close().await.unwrap();
    second.close().await.unwrap();
}

#[test]
fn a_callers_shorter_connect_timeout_stays() {
    assert_eq!(caller_connect_timeout(&["-oConnectTimeout=2".into()]), Some(2));
    assert_eq!(caller_connect_timeout(&["-o".into(), "connecttimeout=7".into()]), Some(7));
    assert_eq!(caller_connect_timeout(&["-oBatchMode=yes".into()]), None);
    assert_eq!(caller_connect_timeout(&["--".into(), "-oConnectTimeout=2".into()]), None);
}
