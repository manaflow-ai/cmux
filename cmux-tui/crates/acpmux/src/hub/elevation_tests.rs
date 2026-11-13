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
  if [ -e '{listing}' ]; then cat '{listing}'; exit 0; fi
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
        listing = dir.join("listing").display(),
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
    let out = run(
        &sudo,
        &ask(&["sh", "-c", "printf ran:; cat"], 30),
        Zeroizing::new(PASSWORD.to_owned()),
    )
    .await;
    assert_eq!(out["exitCode"], 0, "{out}");
    // The command ran and `cat` copied every byte of its stdin, which was empty: none of the
    // password reached it. (No `od`: an empty input prints its zero offset on some macOS
    // releases and nothing on others.)
    assert_eq!(out["stdout"], "ran:", "the command read the password: {out}");
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

/// `sudo -l` as an account with one passwordless rule and the rest behind a password lists it.
const MIXED: &str = "Matching Defaults entries for leo on mac:\n    env_reset\n\n\
User leo may run the following commands on mac:\n    (ALL) NOPASSWD: /usr/bin/pmset, PASSWD: /usr/sbin/fs_usage\n    (ALL) ALL\n";

/// Whether a passwordless rule could run the command is read per command; anything unclear
/// counts as passwordless, which only costs the password (review follow-ups of #37949).
#[test]
fn a_listing_says_which_commands_a_passwordless_rule_could_run() {
    assert!(listing_may_skip_password(MIXED, "pmset"));
    assert!(listing_may_skip_password(MIXED, "/usr/bin/pmset"));
    assert!(!listing_may_skip_password(MIXED, "fs_usage"));
    assert!(!listing_may_skip_password(MIXED, "dtruss"));
    let rules =
        |line: &str| format!("User leo may run the following commands on mac:\n    {line}\n");
    assert!(!listing_may_skip_password(&rules("(ALL) ALL"), "fs_usage"));
    assert!(listing_may_skip_password(&rules("(ALL) NOPASSWD: ALL"), "fs_usage"));
    assert!(listing_may_skip_password(&rules("(root) NOPASSWD: SHUTDOWN_CMDS"), "fs_usage"));
    assert!(listing_may_skip_password(&rules("(root) NOPASSWD: /usr/sbin/*"), "fs_usage"));
    assert!(listing_may_skip_password(
        &rules("(ALL : ALL) SETENV: NOPASSWD: /usr/sbin/fs_usage -w"),
        "fs_usage"
    ));
    assert!(listing_may_skip_password(
        &rules("(root) NOPASSWD: TIMEOUT=1m /usr/sbin/fs_usage"),
        "fs_usage"
    ));
    assert!(!listing_may_skip_password(
        &rules("(root) NOPASSWD: !/usr/sbin/fs_usage, PASSWD: ALL"),
        "fs_usage"
    ));
    assert!(listing_may_skip_password(&rules("something sudo prints we do not read"), "fs_usage"));
    assert!(listing_may_skip_password(
        "Defaults !authenticate\nUser leo may run the following commands on mac:\n    (ALL) ALL\n",
        "id"
    ));
    assert!(listing_may_skip_password("", "id"), "no rules read: passwordless");
}

/// With one passwordless rule for another command, a command behind a password still gets the
/// person's password through sudo's prompt (the run no longer goes `sudo -n` for every command).
#[cfg(unix)]
#[tokio::test]
async fn a_passwordless_rule_for_another_command_leaves_this_one_on_the_password() {
    let _one = FAKES.lock().await;
    let dir = temp("mixed");
    let sudo = fake_sudo(&dir);
    std::fs::write(dir.join("listing"), MIXED).unwrap();
    let out =
        run(&sudo, &ask(&["sh", "-c", "echo ok"], 30), Zeroizing::new(PASSWORD.to_owned())).await;
    assert_eq!(out["exitCode"], 0, "{out}");
    assert_eq!(out["stdout"], "ok\n", "{out}");
    let calls = std::fs::read_to_string(dir.join("calls")).unwrap();
    assert!(calls.lines().any(|l| l.starts_with("-S -k -p [acpmux-sudo-")), "{calls}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// stderr stays within its cap with acpmux's own notes on it.
#[cfg(unix)]
#[tokio::test]
async fn stderr_stays_within_its_cap_with_the_notes() {
    let _one = FAKES.lock().await;
    let dir = temp("cap");
    let sudo = fake_sudo(&dir);
    std::fs::write(dir.join("nopasswd"), "").unwrap();
    let script = format!("head -c {} /dev/zero | tr '\\0' x >&2", MAX_OUTPUT_BYTES * 2);
    let out =
        run(&sudo, &ask(&["sh", "-c", &script], 30), Zeroizing::new(PASSWORD.to_owned())).await;
    let stderr = out["stderr"].as_str().unwrap();
    assert!(stderr.len() <= MAX_OUTPUT_BYTES, "{}", stderr.len());
    assert!(stderr.contains("acpmux: a passwordless sudo rule"), "the note was cut");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A card the daemon no longer holds (it restarted while the card was open) closes on the next
/// answer to it: its request gets a `cancelled` decision, so no client keeps showing it.
#[test]
fn an_answer_to_a_card_lost_in_a_restart_closes_it() {
    use crate::store::{META_SCHEMA, SessionMeta};
    let config: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": "elev-stale", "name": "elev-stale", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    let request = |seq: u64, id: &str, at: u64| crate::store::EventRecord {
        seq,
        at,
        dir: "mux".into(),
        kind: "elevation_request".into(),
        msg: json!({
            "secretId": id, "argv": ["id"], "reason": "r", "host": "h",
            "decisionNonce": "n", "personInstance": "i",
        }),
        host_seq: None,
    };
    // Asked by an earlier run of the daemon, and by this one (its ask settles it).
    hub.store.append(&session.id, &request(1, "card-1", hub.started_at - 1)).unwrap();
    hub.store.append(&session.id, &request(2, "card-2", hub.started_at)).unwrap();
    assert!(hub.submit_secret(&session, "card-2", None).is_err());
    assert!(hub.submit_secret(&session, "card-1", None).is_err());
    let mut decisions = Vec::new();
    hub.store
        .scan_kinds(&session.id, &["elevation_decision"], &mut |e| {
            decisions.push(e.msg);
            true
        })
        .unwrap();
    assert_eq!(decisions.len(), 1, "{decisions:?}");
    assert_eq!(decisions[0]["secretId"], "card-1");
    assert_eq!(decisions[0]["outcome"], "cancelled");
    assert!(decisions[0].get("decisionNonce").is_none(), "{decisions:?}");
    // A second late answer finds it closed and writes nothing more.
    assert!(hub.submit_secret(&session, "card-1", None).is_err());
    let mut again = 0;
    hub.store
        .scan_kinds(&session.id, &["elevation_decision"], &mut |_| {
            again += 1;
            true
        })
        .unwrap();
    assert_eq!(again, 1);
}

/// A NOPASSWD rule for a directory allows every command in it.
#[test]
fn a_passwordless_directory_rule_counts() {
    let rules =
        "User leo may run the following commands on mac:\n    (root) NOPASSWD: /usr/local/bin/\n";
    assert!(listing_may_skip_password(rules, "fs_usage"));
}
