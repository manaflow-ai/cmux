//! `cmux chat send SESSION --wait` to a chat on a Cloud VM: the send's own exec waits for the turn it started, and
//! no read answers the turn before the send. A child of `tests`, so its fakes and helpers are in scope.

use super::*;

/// `cmux chat send` to `sess-1` on `vm-1`, as `send_existing` asks it.
fn existing(wait: bool) -> Request {
    Request {
        prompt: Some("And 2+3?".into()),
        agent: String::new(),
        model: None,
        cwd: None,
        from_folder: None,
        environment: None,
        account: None,
        machine: Machine::Target("vm-1".into()),
        wait,
        timeout: Duration::from_secs(60),
        make_room: false,
        until: None,
        allow_large: false,
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
    // The baseline is read before the send, the folder after it (off the prompt's way), then the wait: first for
    // the sent turn to start, inside the exec's slice less the send's own share, then for its end.
    let at = |needle: &str| sent.find(needle).unwrap_or_else(|| panic!("{needle} in {sent}"));
    assert!(at("echo @@before") < at("acp send --no-wait sess-1 -"));
    assert!(at("acp send --no-wait sess-1 -") < at("acp ls --live"));
    assert!(at("acp ls --live") < at("acp wait sess-1 --timeout 15 --until running"));
    assert!(at("--until running") < at("acp wait sess-1 --timeout \"$s\" "));
    assert!(sent.contains("if [ \"$x\" = 0 ]; then"), "no wait after a refused send: {sent}");
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
