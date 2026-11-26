use super::*;

fn look(status: Power) -> SettleLook {
    SettleLook { status, waited_ms: 0, resumes: 0, limit_ms: None, killed: false }
}

#[test]
fn transient_states_wait_or_resume_never_refuse() {
    assert_eq!(settle(look(Power::Running)), Settle::Proceed);
    assert_eq!(settle(look(Power::Pausing)), Settle::WaitPausing);
    assert_eq!(settle(look(Power::Starting)), Settle::WaitStarting);
    assert_eq!(settle(look(Power::Paused)), Settle::Resume);
    assert_eq!(settle(look(Power::Deleting)), Settle::Refuse { reason: Refusal::Deleting });
    assert_eq!(settle(look(Power::Failed)), Settle::Refuse { reason: Refusal::Failed });
}

#[test]
fn deadline_and_resume_bound() {
    let late = SettleLook { waited_ms: SETTLE_LIMIT_MS, ..look(Power::Pausing) };
    assert_eq!(settle(late), Settle::Refuse { reason: Refusal::Deadline });
    let bounded = SettleLook { waited_ms: 30_000, limit_ms: Some(30_000), ..look(Power::Starting) };
    assert_eq!(settle(bounded), Settle::Refuse { reason: Refusal::Deadline });
    assert_eq!(settle(look(Power::Destroyed)), Settle::Refuse { reason: Refusal::Deleting });
    let resumed = SettleLook { resumes: RESUMES, ..look(Power::Paused) };
    assert_eq!(settle(resumed), Settle::Refuse { reason: Refusal::Deadline });
    // A running machine goes on even past the deadline.
    let running = SettleLook { waited_ms: SETTLE_LIMIT_MS * 2, ..look(Power::Running) };
    assert_eq!(settle(running), Settle::Proceed);
}

#[test]
fn kill_switch_restores_the_immediate_refusal() {
    let killed = |status| SettleLook { killed: true, ..look(status) };
    assert_eq!(settle(killed(Power::Pausing)), Settle::Refuse { reason: Refusal::Transient });
    assert_eq!(settle(killed(Power::Starting)), Settle::Refuse { reason: Refusal::Transient });
    assert_eq!(settle(killed(Power::Running)), Settle::Proceed);
    assert!(super::killed(Some("0")));
    assert!(super::killed(Some(" off ")));
    assert!(!super::killed(Some("1")));
    assert!(!super::killed(None));
}

#[test]
fn look_and_act_round_trip_the_wire() {
    let look: SettleLook =
        serde_json::from_str(r#"{"status":"pausing","waitedMs":1200,"resumes":1}"#).unwrap();
    assert_eq!(look.status, Power::Pausing);
    assert_eq!(look.waited_ms, 1200);
    let unknown: SettleLook = serde_json::from_str(r#"{"status":"hibernating"}"#).unwrap();
    assert_eq!(unknown.status, Power::Unknown);
    assert_eq!(
        serde_json::to_value(Settle::WaitPausing).unwrap(),
        serde_json::json!({"act": "waitPausing"})
    );
    assert_eq!(
        serde_json::to_value(Settle::Refuse { reason: Refusal::Deadline }).unwrap(),
        serde_json::json!({"act": "refuse", "reason": "deadline"})
    );
}

/// A small deterministic generator: the crate takes no `rand`.
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

/// A simulated machine the platform owns: a spare just claimed (running), raced by an idle pause that may land at any
/// moment around the claim, a pause that takes a while to land, and a resume that takes a while to run. A second idle
/// pause may land after the first resume, as on 2026-11-25 when the composer's lease idled out before Send.
struct Machine {
    status: Power,
    /// When the next pause starts (ms), if one is coming.
    pause_at: Option<u64>,
    pause_ms: u64,
    resume_ms: u64,
    /// When the in-flight transition ends.
    settles_at: u64,
    second_pause: Option<u64>,
}

impl Machine {
    fn at(&mut self, now: u64) -> Power {
        loop {
            match self.status {
                Power::Running => match self.pause_at {
                    Some(at) if now >= at => {
                        self.status = Power::Pausing;
                        self.settles_at = at + self.pause_ms;
                        self.pause_at = self.second_pause.take();
                    }
                    _ => return self.status,
                },
                Power::Pausing if now >= self.settles_at => self.status = Power::Paused,
                Power::Starting if now >= self.settles_at => {
                    self.status = Power::Running;
                    // A pause scheduled before the resume ran lands after it, not inside it.
                    if let Some(at) = self.pause_at {
                        self.pause_at = Some(at.max(self.settles_at));
                    }
                }
                _ => return self.status,
            }
        }
    }

    fn resume(&mut self, now: u64) {
        if self.status == Power::Paused {
            self.status = Power::Starting;
            self.settles_at = now + self.resume_ms;
        }
    }
}

/// The caller's loop, as the app runs it: look, act, poll every `POLL_MS` while waiting.
fn drive(machine: &mut Machine, start: u64) -> Result<u64, Refusal> {
    const POLL_MS: u64 = 250;
    let mut now = start;
    let mut resumes = 0;
    loop {
        let status = machine.at(now);
        let waited_ms = now - start;
        match settle(SettleLook { status, waited_ms, resumes, limit_ms: None, killed: false }) {
            Settle::Proceed => return Ok(waited_ms),
            Settle::Refuse { reason } => return Err(reason),
            Settle::WaitPausing | Settle::WaitStarting => now += POLL_MS,
            Settle::Resume => {
                machine.resume(now);
                resumes += 1;
                now += POLL_MS;
            }
        }
    }
}

/// The claim-vs-pause race, 100 seeded interleavings: whatever moment the idle pause lands relative to the caller's
/// first look (before it, during it, a second one after the first resume), the caller ends on a running machine and
/// surfaces no error.
#[test]
fn fuzz_claim_against_pause_surfaces_no_error() {
    let mut rng = Lcg(0x25_9986_a6c4);
    let mut surfaced = Vec::new();
    let mut waited_max = 0;
    for iteration in 0..100 {
        let claim = 10_000;
        let pause_at = (rng.below(4) != 0).then(|| claim - 5_000 + rng.below(10_000));
        let second_pause = (rng.below(3) == 0).then(|| claim + rng.below(60_000));
        let mut machine = Machine {
            status: Power::Running,
            pause_at,
            pause_ms: 500 + rng.below(15_000),
            resume_ms: 1_000 + rng.below(45_000),
            settles_at: 0,
            second_pause,
        };
        let first_look = claim + rng.below(5_000);
        match drive(&mut machine, first_look) {
            Ok(waited) => {
                waited_max = waited_max.max(waited);
                assert_eq!(
                    machine.at(first_look + waited),
                    Power::Running,
                    "iteration {iteration}"
                );
            }
            Err(reason) => surfaced.push((iteration, reason)),
        }
    }
    assert!(surfaced.is_empty(), "errors surfaced: {surfaced:?}");
    assert!(waited_max < SETTLE_LIMIT_MS, "waited {waited_max} ms");
}

/// The same race with the kill switch off answers the pause at once, as before: the switch restores the old path.
#[test]
fn fuzz_with_kill_switch_refuses_a_pause_in_flight() {
    let mut machine = Machine {
        status: Power::Running,
        pause_at: Some(0),
        pause_ms: 5_000,
        resume_ms: 5_000,
        settles_at: 0,
        second_pause: None,
    };
    let status = machine.at(1_000);
    assert_eq!(status, Power::Pausing);
    assert_eq!(
        settle(SettleLook { status, waited_ms: 0, resumes: 0, limit_ms: None, killed: true }),
        Settle::Refuse { reason: Refusal::Transient }
    );
}

/// "Waking machine" shows only while a pause or a resume in flight is waited out: never for a running machine, a
/// paused one the attach resumes, a refusal, or the kill switch (ask-259986a6c4).
#[test]
fn waking_shows_only_while_a_change_is_waited_out() {
    let seen =
        |status, killed| SettleLook { status, waited_ms: 0, resumes: 0, limit_ms: None, killed };
    assert!(settle(seen(Power::Pausing, false)).waking());
    assert!(settle(seen(Power::Starting, false)).waking());
    for status in
        [Power::Running, Power::Paused, Power::Provisioning, Power::Deleting, Power::Failed]
    {
        assert!(!settle(seen(status, false)).waking(), "{status:?}");
    }
    assert!(!settle(seen(Power::Pausing, true)).waking());
    assert!(
        !settle(SettleLook { waited_ms: SETTLE_LIMIT_MS, ..seen(Power::Pausing, false) }).waking()
    );
}
