//! `cmux chat send SESSION --wait` to a chat on a Cloud VM: the send's own exec waits for the turn it started, and
//! no read answers the turn before the send. A child of `tests`, so its fakes and helpers are in scope.

use super::*;

/// `cmux chat send` to `sess-1` on `vm-1`, as `send_existing` asks it.
fn existing(wait: bool) -> Request {
    Request {
        prompt: Some("And 2+3?".into()),
        agent: String::new(),
        model: None,
        effort: None,
        mode: None,
        cwd: None,
        from_folder: None,
        environment: None,
        account: None,
        connection: None,
        machine: Machine::Target("vm-1".into()),
        wait,
        timeout: Duration::from_secs(60),
        make_room: false,
        until: None,
        allow_large: false,
        timings: false,
        no_focus: false,
    }
}

/// The send's part of its exec: the turn before it (seq 3) and the send.
const SENT: &str = "@@before\n{\"turns\":[{\"seq\":3,\"status\":\"completed\",\"endedAt\":9}]}\n\
                    @@send\nd-2\n@@exit 0\n@@cwd\n\n";
/// A wait whose `acp wait --until running` resolved: the machine's CLI serves it.
const STARTED: &str = "@@startedexit 0\n@@started\nsess-1                   running\n";
/// The sent turn's end and its reply.
const ENDED: &str = "@@wait 0\n@@history\n{\"turns\":[{\"seq\":4,\"status\":\"completed\",\"endedAt\":12}]}\n\
                     @@last\n{\"sessionId\":\"sess-1\",\"replies\":[\"5\"]}\n@@lastexit 0\n";
/// Still the turn before the send, and its reply.
const BEFORE: &str = "@@wait 0\n@@history\n{\"turns\":[{\"seq\":3,\"status\":\"completed\",\"endedAt\":9}]}\n\
                      @@last\n{\"sessionId\":\"sess-1\",\"replies\":[\"old\"]}\n@@lastexit 0\n";

fn script(ran: &[String]) -> &str {
    &ran[5]
}

#[test]
fn a_send_that_waits_answers_its_turn_from_the_send_s_own_exec() {
    let mut fake = Fake::new(vec![exec_out(&format!("{SENT}{STARTED}{ENDED}"))]);
    let Outcome::Done(answer) = send_to(&mut fake, &existing(true), "vm-1", "sess-1") else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "5");
    assert_eq!(answer["wait_route"], "send");
    // One Cloud round trip, no pause.
    assert_eq!(fake.ran.len(), 1, "{:?}", fake.ran);
    assert_eq!(fake.paused, Duration::ZERO);
    let sent = script(&fake.ran[0]);
    // The exec's slice starts at its first command; the baseline is read before the send, the folder after it (off
    // the prompt's way), then the wait in what is left of the slice: first for the sent turn to start, then for
    // its end.
    assert!(sent.starts_with("e=$(( $(date +%s) + 20 )); "), "{sent}");
    let at = |needle: &str| sent.find(needle).unwrap_or_else(|| panic!("{needle} in {sent}"));
    assert!(at("echo @@before") < at("acp send --no-wait sess-1 -"));
    assert!(at("acp send --no-wait sess-1 -") < at("acp ls --live"));
    assert!(at("acp ls --live") < at("acp wait sess-1 --timeout \"$s\" --until running"));
    assert!(at("--until running") < at("acp wait sess-1 --timeout \"$s\" >/dev/null"));
    assert!(
        sent.contains("if [ \"$x\" = 0 ] && [ \"$s\" -ge 1 ]; then"),
        "no wait after a refused send or with no time left: {sent}"
    );
}

/// Runs a send's exec `script` in `sh` against a stand-in machine: its `date` reads a clock that only the stand-in
/// `cmux-tui`'s `acp send` moves, by `send_cost` seconds. Answers the stand-in's log of its calls and the stdout.
#[cfg(unix)]
fn run_send_exec(script: &str, send_cost: u64) -> (String, String) {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().display().to_string();
    let bin = dir.path().join("bin");
    let guest_bin = dir.path().join("home/.cmux/bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&guest_bin).unwrap();
    std::fs::write(dir.path().join("clock"), "1000\n").unwrap();
    let cmux_tui = format!(
        "#!/bin/sh\n\
         echo \"$*\" >> '{root}/log'\n\
         case \"$2\" in\n\
         send) cat >/dev/null; echo $(( $(cat '{root}/clock') + {send_cost} )) > '{root}/clock'; echo d-2 ;;\n\
         history) echo '{{\"turns\":[{{\"seq\":4,\"status\":\"completed\",\"endedAt\":12}}]}}' ;;\n\
         wait) case \"$*\" in *--until*) echo 'sess-1 running' ;; esac ;;\n\
         last) echo '{{\"sessionId\":\"sess-1\",\"replies\":[\"5\"]}}' ;;\n\
         ls) echo '[]' ;;\n\
         esac\n"
    );
    let tools = [
        (guest_bin.join("cmux-tui"), cmux_tui),
        (bin.join("date"), format!("#!/bin/sh\ncat '{root}/clock'\n")),
        (bin.join("timeout"), "#!/bin/sh\nshift\nexec \"$@\"\n".to_owned()),
    ];
    for (path, body) in tools {
        std::fs::write(&path, body).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
    let ran = cmux_process::Command::new("sh")
        .arg("-c")
        .arg(script)
        .env("HOME", dir.path().join("home"))
        .env("PATH", path)
        .output()
        .unwrap();
    let log = std::fs::read_to_string(dir.path().join("log")).unwrap_or_default();
    let stderr = String::from_utf8_lossy(&ran.stderr);
    (log, format!("{}\n@@stderr\n{stderr}", String::from_utf8_lossy(&ran.stdout)))
}

/// The send's exec is bounded from its first command: a slow send leaves the wait only what is left of the slice,
/// and a send that spent it all runs no wait in that exec, so the exec ends inside the Cloud's 25 s limit instead of
/// being killed after the prompt was delivered.
#[cfg(unix)]
#[test]
fn a_slow_send_leaves_its_exec_s_wait_only_what_is_left_of_the_slice() {
    let mut fake = Fake::new(vec![exec_out(&format!("{SENT}{STARTED}{ENDED}"))]);
    let Outcome::Done(_) = send_to(&mut fake, &existing(true), "vm-1", "sess-1") else {
        panic!("{:?}", fake.ran)
    };
    let sent = script(&fake.ran[0]).to_owned();

    let (log, stdout) = run_send_exec(&sent, 4);
    assert!(log.contains("acp wait sess-1 --timeout 16 --until running"), "{log}{stdout}");
    assert!(log.contains("acp wait sess-1 --timeout 16\n"), "{log}");
    assert!(stdout.contains("@@wait 0"), "{stdout}");

    let (log, stdout) = run_send_exec(&sent, 25);
    assert!(log.contains("acp send --no-wait sess-1 -"), "{log}");
    assert!(!log.contains("acp wait"), "no wait once the slice is spent: {log}");
    assert!(stdout.contains("@@exit 0") && !stdout.contains("@@wait"), "{stdout}");
}

/// A send's exec that skipped its wait (no time left of its slice) answers no wait sections: the turn is read by the
/// later waits, and the prompt is sent once.
#[test]
fn a_send_whose_exec_skipped_its_wait_reads_the_turn_after_it() {
    let mut fake = Fake::new(vec![exec_out(SENT), exec_out(&format!("{STARTED}{ENDED}"))]);
    let Outcome::Done(answer) = send_to(&mut fake, &existing(true), "vm-1", "sess-1") else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "5", "{answer}");
    assert!(answer.get("wait_route").is_none(), "{answer}");
    assert_eq!(fake.ran.len(), 2, "{:?}", fake.ran);
    let next = script(&fake.ran[1]);
    assert!(next.contains("--until running"), "{next}");
    assert!(!next.contains("acp send"), "the prompt is sent once");
}

/// The race of a plain `acp wait` right after a `--no-wait` send: it resolves on `ready` before the sent turn
/// starts. A read that shows only the turn before the send never answers that turn's reply; with a machine that
/// blocked on `--until running`, the next read is asked at once, never after a fixed pause.
#[test]
fn the_turn_before_the_send_is_never_its_answer() {
    let mut fake = Fake::new(vec![
        exec_out(&format!("{SENT}@@startedexit 3\n@@started\n\n{BEFORE}")),
        exec_out(&format!("{STARTED}{ENDED}")),
    ]);
    let Outcome::Done(answer) = send_to(&mut fake, &existing(true), "vm-1", "sess-1") else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "5", "{answer}");
    assert_eq!(fake.ran.len(), 2, "{:?}", fake.ran);
    assert_eq!(fake.paused, Duration::ZERO);
    // The sent turn not seen yet: the next read waits for it to start again.
    assert!(script(&fake.ran[1]).contains("acp wait sess-1 --timeout 20 --until running"));
    assert!(!script(&fake.ran[1]).contains("acp send"), "the prompt is sent once");
}

/// A machine's older CLI refuses `--until running` (a usage error: exit 2, nothing printed), so its wait returned
/// on `ready` at once: the next read comes after the pause, as before.
#[test]
fn a_machine_cli_without_until_running_reads_again_after_a_pause() {
    let mut fake = Fake::new(vec![
        exec_out(&format!("{SENT}@@startedexit 2\n@@started\n\n{BEFORE}")),
        exec_out(&format!("@@startedexit 2\n@@started\n\n{ENDED}")),
    ]);
    let Outcome::Done(answer) = send_to(&mut fake, &existing(true), "vm-1", "sess-1") else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "5");
    assert_eq!(fake.ran.len(), 2, "{:?}", fake.ran);
    assert_eq!(fake.paused, NOT_STARTED_PAUSE);
}

/// Once a read showed the sent turn running, the next waits for its end only: `--until running` would block on a
/// turn that ended between the two reads.
#[test]
fn once_the_sent_turn_is_seen_the_next_read_waits_for_its_end_only() {
    let running = "@@wait 3\n@@history\n{\"turns\":[{\"seq\":4,\"status\":\"running\"}]}\n";
    let mut fake = Fake::new(vec![exec_out(&format!("{SENT}{STARTED}{running}")), exec_out(ENDED)]);
    let Outcome::Done(answer) = send_to(&mut fake, &existing(true), "vm-1", "sess-1") else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["reply"], "5");
    assert_eq!(fake.paused, Duration::ZERO);
    let next = script(&fake.ran[1]);
    assert!(!next.contains("--until running"), "{next}");
    assert!(next.contains("acp wait sess-1 --timeout 20 >/dev/null"), "{next}");
}

/// A send that does not wait runs no wait on the machine, and its baseline is the plain `@@history`.
#[test]
fn a_send_without_wait_runs_no_wait() {
    let mut fake = Fake::new(vec![exec_out("@@history\n{\"turns\":[]}\n@@send\nd-2\n@@exit 0\n")]);
    let Outcome::Done(answer) = send_to(&mut fake, &existing(false), "vm-1", "sess-1") else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["sent"], true);
    let sent = script(&fake.ran[0]);
    assert!(!sent.contains("acp wait"), "{sent}");
    assert!(sent.contains("echo @@history;"), "{sent}");
}

#[test]
fn a_wait_for_the_start_is_known_by_what_it_printed_or_its_timeout() {
    let polled = |text: &str| sections(text);
    assert!(waited_for_start(&polled("@@startedexit 0\n@@started\nsess-1 running\n")));
    assert!(waited_for_start(&polled(
        "@@startedexit 2\n@@started\nsess-1 waiting for permission (1)\n"
    )));
    assert!(waited_for_start(&polled("@@startedexit 3\n@@started\n\n")));
    assert!(
        !waited_for_start(&polled("@@startedexit 2\n@@started\n\n")),
        "an older CLI's usage error"
    );
    assert!(!waited_for_start(&polled("@@wait 0\n")), "a read without the step");
}
