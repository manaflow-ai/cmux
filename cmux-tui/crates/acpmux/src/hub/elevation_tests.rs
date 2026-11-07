use super::*;

const PASSWORD: &str = "hunter2-sentinel-9f3c";

fn ask(argv: &[&str], timeout: u64) -> Ask {
    Ask {
        argv: argv.iter().map(|a| (*a).to_owned()).collect(),
        reason: "test".to_owned(),
        timeout: Duration::from_secs(timeout),
    }
}

/// A stand-in for sudo: prints its `-p` prompt to stderr, reads the password line from stdin,
/// says whether it matched, logs every call's arguments to `calls`, and runs what follows `--`
/// (with the rest of stdin). With a `nopasswd` file beside it, it asks for nothing, as a
/// `NOPASSWD` rule does, and the command gets stdin as is.
#[cfg(unix)]
fn fake_sudo(dir: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join("sudo");
    let script = format!(
        r#"#!/bin/sh
echo "$*" >> '{calls}'
[ "$1" = "-k" ] && exit 0
if [ "$1" = "-n" ] && [ "$3" = "-l" ]; then
  [ -e '{nopasswd}' ] && exit 0
  echo "sudo: a password is required" >&2; exit 1
fi
if [ "$1" = "-n" ]; then
  [ -e '{nopasswd}' ] || {{ echo "sudo: a password is required" >&2; exit 1; }}
elif [ ! -e '{nopasswd}' ]; then
  printf '%s' "$4" >&2
  IFS= read -r pw
  if [ "$pw" != '{PASSWORD}' ]; then echo "sudo: incorrect password" >&2; exit 1; fi
fi
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
"#,
        calls = dir.join("calls").display(),
        nopasswd = dir.join("nopasswd").display(),
    );
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// One test at a time writes and runs a stand-in sudo: a test that forks while another still
/// holds its new script open for writing makes that script's exec fail with ETXTBSY.
static FAKES: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn temp(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-elev-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn check_takes_argv_reason_and_this_host_only() {
    let ok = check(&json!({"argv": ["fs_usage", "-w", "-t", "5"], "reason": "why is disk busy"}))
        .unwrap();
    assert_eq!(ok.argv, ["fs_usage", "-w", "-t", "5"]);
    assert_eq!(ok.timeout, DEFAULT_TIMEOUT);
    let here = super::super::start_gate::host_label();
    assert!(check(&json!({"argv": ["id"], "reason": "r", "host": here})).is_ok());
    assert!(check(&json!({"argv": ["id"], "reason": "r", "host": "localhost"})).is_ok());
    for bad in [
        json!({"argv": "rm -rf /", "reason": "a shell string"}),
        json!({"argv": [], "reason": "empty"}),
        json!({"argv": ["-u", "root", "id"], "reason": "a sudo option first"}),
        json!({"argv": ["id\u{0}x"], "reason": "nul"}),
        json!({"argv": ["echo", "safe\u{202E}fr- mr"], "reason": "a bidi override"}),
        json!({"argv": ["echo", "a\u{2066}b\u{2069}"], "reason": "a bidi isolate"}),
        json!({"argv": ["echo", "a\u{200B}b"], "reason": "an invisible space"}),
        json!({"argv": ["echo", "a\nb"], "reason": "a newline"}),
        json!({"argv": ["echo", "a\u{1b}[2Kb"], "reason": "an escape"}),
        json!({"argv": ["id"], "reason": "looks fine\u{202E}"}),
        json!({"argv": ["echo", "a\u{E0001}b"], "reason": "a language tag"}),
        json!({"argv": ["echo", "\u{0600}1"], "reason": "an arabic number sign"}),
        json!({"argv": ["r\u{043C}", "x"], "reason": "a cyrillic look-alike"}),
        json!({"argv": ["echo", "caf\u{00E9}"], "reason": "any non-ascii"}),
        json!({"argv": ["id"], "reason": "tagged\u{E0041}"}),
        json!({"argv": ["id"], "reason": "sign\u{0600}"}),
        json!({"argv": ["id"]}),
        json!({"argv": ["id"], "reason": "r", "host": "some-other-host-7c2e"}),
        json!({"argv": ["id"], "reason": "r", "timeoutSecs": 0}),
        json!({"argv": ["id"], "reason": "r", "timeoutSecs": 601}),
    ] {
        assert!(check(&bad).is_err(), "accepted {bad}");
    }
}

#[cfg(unix)]
#[tokio::test]
async fn run_writes_the_password_to_sudo_masks_it_and_forgets_the_timestamp() {
    let _one = FAKES.lock().await;
    let dir = temp("run");
    let sudo = fake_sudo(&dir);
    // A command that echoes its stdin would print the password: it comes back masked.
    let out = run(
        &sudo,
        &ask(&["sh", "-c", "echo out; echo err >&2; cat; exit 3"], 10),
        Zeroizing::new(PASSWORD.to_owned()),
    )
    .await;
    assert_eq!(out["exitCode"], 3, "{out}");
    assert_eq!(out["timedOut"], false);
    assert_eq!(out["stdout"].as_str().unwrap().trim_end(), "out");
    assert_eq!(out["stderr"].as_str().unwrap().trim_end(), "err");
    assert!(!out.to_string().contains(PASSWORD), "{out}");
    let calls = std::fs::read_to_string(dir.join("calls")).unwrap();
    let lines: Vec<&str> = calls.lines().collect();
    assert_eq!(lines[0], "-n -k -l", "no passwordless-rule probe first: {calls}");
    assert!(lines[1].starts_with("-S -k -p [acpmux-sudo-"), "{calls}");
    assert!(lines[1].contains("] -- sh -c"), "{calls}");
    assert_eq!(lines.last(), Some(&"-k"), "no `sudo -k` after the run: {calls}");
    assert!(!calls.contains(PASSWORD));

    let wrong = run(&sudo, &ask(&["true"], 10), Zeroizing::new("nope".to_owned())).await;
    assert_eq!(wrong["exitCode"], 1, "{wrong}");
    assert!(wrong["stderr"].as_str().unwrap().contains("incorrect password"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[tokio::test]
async fn run_stops_a_command_past_its_timeout() {
    let _one = FAKES.lock().await;
    let dir = temp("timeout");
    let sudo = fake_sudo(&dir);
    let started = std::time::Instant::now();
    let out = run(&sudo, &ask(&["sleep", "30"], 1), Zeroizing::new(PASSWORD.to_owned())).await;
    assert_eq!(out["timedOut"], true, "{out}");
    assert!(out["exitCode"].is_null());
    assert!(started.elapsed() < Duration::from_secs(15), "{:?}", started.elapsed());
    let calls = std::fs::read_to_string(dir.join("calls")).unwrap();
    assert_eq!(calls.lines().last(), Some("-k"), "{calls}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn only_roots_setuid_sudo_is_trusted() {
    let _one = FAKES.blocking_lock();
    let dir = temp("trust");
    let mine = fake_sudo(&dir);
    let seam = std::env::var_os("ACPMUX_ELEVATION_SUDO");
    if seam.is_none() {
        assert!(!trusted_sudo(&mine), "a sudo the user owns was trusted");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// A command that ignores SIGTERM and leaves a child holding its pipes is ended with its whole
/// process group at the timeout: nothing of it outlives the run (review F1).
#[cfg(unix)]
#[tokio::test]
async fn a_timeout_ends_the_whole_group_even_past_an_ignored_sigterm() {
    let _one = FAKES.lock().await;
    let dir = temp("group");
    let sudo = fake_sudo(&dir);
    let started = std::time::Instant::now();
    let script = format!(
        "trap '' TERM; sleep 60 & echo $! > '{}'; wait; sleep 60",
        dir.join("child").display()
    );
    let out =
        run(&sudo, &ask(&["sh", "-c", &script], 1), Zeroizing::new(PASSWORD.to_owned())).await;
    assert_eq!(out["timedOut"], true, "{out}");
    assert_eq!(out["stillRunning"], "unknown", "{out}");
    assert!(started.elapsed() < Duration::from_secs(20), "{:?}", started.elapsed());
    let child: i32 = std::fs::read_to_string(dir.join("child")).unwrap().trim().parse().unwrap();
    // SAFETY: signal 0 checks for the process and sends nothing.
    let alive = unsafe { libc::kill(child, 0) } == 0;
    assert!(!alive, "the background child {child} outlived the timeout");
    let _ = std::fs::remove_dir_all(&dir);
}

/// An account with a passwordless rule (`NOPASSWD`) runs the command with `sudo -n` and an empty
/// stdin: the command never reads the password (review F1 of e4f5ef1 and of 852e490).
#[cfg(unix)]
#[tokio::test]
async fn a_sudo_that_asks_for_no_password_never_hands_it_to_the_command() {
    let _one = FAKES.lock().await;
    let dir = temp("nopasswd");
    let sudo = fake_sudo(&dir);
    std::fs::write(dir.join("nopasswd"), "").unwrap();
    let started = std::time::Instant::now();
    let out =
        run(&sudo, &ask(&["sh", "-c", "cat | od -c"], 30), Zeroizing::new(PASSWORD.to_owned()))
            .await;
    assert_eq!(out["exitCode"], 0, "{out}");
    // `od -c` of an empty stdin prints only the zero offset.
    assert_eq!(
        out["stdout"].as_str().unwrap().trim(),
        "0000000",
        "the command read the password: {out}"
    );
    // The account's passwordless rule was found before anything ran: sudo -n, no password and
    // no prompt to wait for (review F1 of 852e490: a command could print the prompt itself).
    let calls = std::fs::read_to_string(dir.join("calls")).unwrap();
    assert!(calls.lines().any(|l| l.starts_with("-n -k -- sh -c")), "{calls}");
    assert!(!calls.contains("-S"), "the password path ran: {calls}");
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
    let _ = std::fs::remove_dir_all(&dir);
}

/// The prompt sudo prints is this run's marker, and it never reaches the agent's stderr.
#[cfg(unix)]
#[tokio::test]
async fn the_prompt_marker_is_unique_and_kept_out_of_stderr() {
    assert_ne!(prompt_marker(), prompt_marker());
    let _one = FAKES.lock().await;
    let dir = temp("marker");
    let sudo = fake_sudo(&dir);
    let out =
        run(&sudo, &ask(&["sh", "-c", "echo seen >&2"], 30), Zeroizing::new(PASSWORD.to_owned()))
            .await;
    assert_eq!(out["exitCode"], 0, "{out}");
    assert_eq!(out["stderr"], "seen\n", "{out}");
    let _ = std::fs::remove_dir_all(&dir);
}
