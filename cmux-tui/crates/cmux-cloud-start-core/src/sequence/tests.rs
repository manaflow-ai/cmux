//! The Cloud start's one sequencer: which steps run together, when the guest is checked again,
//! when the keyed approvals restart begins, and the step times (cmuxterm-hq#8060's probe reads
//! them as `cloud start step: NAME MS ms`).

use super::*;

/// Feeds `event` at `now` and returns the answer's effects; `state` becomes the next state.
fn feed(state: &mut State, event: Event, now: u64) -> Vec<Effect> {
    let answer = step(std::mem::take(state), event, now);
    *state = answer.state;
    answer.effects
}

fn begin(path: Path, facts: Facts, now: u64) -> (State, Vec<Effect>) {
    let mut state = State::default();
    let effects = feed(&mut state, Event::Begin { path, facts }, now);
    (state, effects)
}

fn done(state: &mut State, step: Step, now: u64) -> Vec<Effect> {
    feed(state, Event::Done { step, idle: None }, now)
}

fn runs(effects: &[Effect]) -> Vec<Step> {
    effects
        .iter()
        .filter_map(|effect| if let Effect::Run { step } = effect { Some(*step) } else { None })
        .collect()
}

fn lines(effects: &[Effect]) -> Vec<String> {
    effects
        .iter()
        .filter_map(
            |effect| if let Effect::Log { line } = effect { Some(line.clone()) } else { None },
        )
        .collect()
}

fn finished(effects: &[Effect]) -> Option<bool> {
    effects.iter().find_map(|effect| {
        if let Effect::Finish { failed } = effect { Some(*failed) } else { None }
    })
}

/// The milliseconds of a `cloud start step: NAME MS ms` line, by name.
fn ms(line: &str) -> (String, u64) {
    let rest = line.strip_prefix(PREFIX).expect("a step line");
    let rest = rest.strip_suffix(" ms").expect("ends in ms");
    let (name, ms) = rest.rsplit_once(' ').expect("NAME MS");
    (name.to_owned(), ms.parse().expect("whole milliseconds"))
}

/// An idle machine with no key: the approvals read the daemon's status first.
fn keyless() -> Facts {
    Facts::default()
}

// MARK: Which steps run together

#[test]
fn a_session_start_runs_its_login_and_approvals_together_once_connected() {
    let (mut state, effects) = begin(Path::Session, keyless(), 1_000);
    assert_eq!(runs(&effects), [Step::Connect]);
    let effects = done(&mut state, Step::Connect, 3_000);
    // The keyed restart's status read starts with the login, not after it (the chat's first start carries the key).
    assert_eq!(runs(&effects), [Step::Login, Step::DaemonStatus]);
    assert_eq!(lines(&effects), ["cloud start step: connect 2000 ms"]);
}

#[test]
fn the_anchor_waits_for_both_the_login_and_the_approvals() {
    let (mut state, _) = begin(Path::Session, keyless(), 0);
    done(&mut state, Step::Connect, 10);
    assert!(runs(&done(&mut state, Step::Login, 20)).is_empty(), "approvals still running");
    let effects = feed(&mut state, Event::Done { step: Step::DaemonStatus, idle: Some(false) }, 30);
    assert_eq!(runs(&effects), [Step::Anchor]);
    assert_eq!(runs(&done(&mut state, Step::Anchor, 40)), [Step::Tab]);
    assert_eq!(runs(&done(&mut state, Step::Tab, 50)), [Step::Start]);
    let effects = done(&mut state, Step::Start, 60);
    assert_eq!(finished(&effects), Some(false));
    assert!(runs(&effects).is_empty());
}

#[test]
fn a_composer_start_copies_logs_in_and_turns_approvals_on_at_once_then_opens() {
    let (mut state, effects) = begin(Path::Composer, keyless(), 0);
    assert_eq!(runs(&effects), [Step::Copy, Step::Login, Step::DaemonStatus]);
    assert!(runs(&done(&mut state, Step::Copy, 5)).is_empty());
    assert!(
        runs(&feed(&mut state, Event::Done { step: Step::DaemonStatus, idle: Some(false) }, 6))
            .is_empty()
    );
    assert_eq!(runs(&done(&mut state, Step::Login, 7)), [Step::Open]);
    assert_eq!(finished(&done(&mut state, Step::Open, 9)), Some(false));
}

#[test]
fn a_home_start_logs_in_beside_the_approvals_then_opens() {
    let (mut state, effects) = begin(Path::Home, Facts { holds_key: true, ..keyless() }, 0);
    // The run already holds this app's key: nothing to restart, so only the login runs.
    assert_eq!(runs(&effects), [Step::Login]);
    assert_eq!(runs(&done(&mut state, Step::Login, 4)), [Step::Open]);
}

#[test]
fn the_machine_reads_run_at_once() {
    let facts = Facts { reads_machine: true, claude: true, ..keyless() };
    let (mut state, effects) = begin(Path::MachineReads, facts, 0);
    assert_eq!(runs(&effects), [Step::Guest, Step::MachineLogin]);
    assert!(
        finished(&done(&mut state, Step::MachineLogin, 3)).is_none(),
        "the guest read is still out"
    );
    assert_eq!(finished(&done(&mut state, Step::Guest, 5)), Some(false));
}

#[test]
fn a_start_racing_a_warm_copy_reads_the_login_only_after_it_but_the_guest_at_once() {
    let facts = Facts { reads_machine: true, claude: true, warm_copy_conflict: true, ..keyless() };
    let (mut state, effects) = begin(Path::MachineReads, facts, 0);
    assert_eq!(runs(&effects), [Step::Guest, Step::WarmCopy]);
    assert!(runs(&done(&mut state, Step::Guest, 2)).is_empty());
    assert_eq!(runs(&done(&mut state, Step::WarmCopy, 8)), [Step::MachineLogin]);
    assert_eq!(finished(&done(&mut state, Step::MachineLogin, 9)), Some(false));
}

#[test]
fn a_codex_start_reads_only_the_guest_and_never_waits_on_a_claude_warm() {
    // #38567 F2: the warm copies Claude's login, so a Codex start never waits on it, even when told of a conflict.
    let facts = Facts { reads_machine: true, claude: false, warm_copy_conflict: true, ..keyless() };
    let (mut state, effects) = begin(Path::MachineReads, facts, 0);
    assert_eq!(runs(&effects), [Step::Guest]);
    assert_eq!(finished(&done(&mut state, Step::Guest, 1)), Some(false));
}

#[test]
fn a_start_that_does_not_read_the_machine_reads_nothing() {
    let (_, effects) =
        begin(Path::MachineReads, Facts { claude: true, warm_copy_conflict: true, ..keyless() }, 0);
    assert!(runs(&effects).is_empty());
    assert_eq!(finished(&effects), Some(false));
}

// MARK: When the guest is checked again

#[test]
fn a_login_read_from_the_cache_at_once_is_delivered_on_the_guest_check_just_made() {
    assert!(!recheck_guest(true, 0));
    assert!(!recheck_guest(true, RECHECK_AFTER_MS));
}

#[test]
fn a_sign_in_or_a_slow_keychain_read_checks_the_guest_again() {
    // A browser sign-in: the login did not come from the cache, however fast.
    assert!(recheck_guest(false, 0));
    // A Keychain read slow enough for a prompt: the target may have changed meanwhile.
    assert!(recheck_guest(true, RECHECK_AFTER_MS + 1));
}

// MARK: When the keyed approvals restart begins

#[test]
fn the_approvals_restart_only_an_idle_daemon_that_lacks_the_key() {
    assert_eq!(approvals(false, false), Approvals::IfIdle);
    assert_eq!(approvals(false, true), Approvals::Held);
    // The daemon itself said a keyed restart is safe now: at once, with no status read.
    assert_eq!(approvals(true, false), Approvals::RestartNow);
    assert_eq!(approvals(true, true), Approvals::RestartNow);
}

#[test]
fn an_idle_daemon_without_the_key_restarts_with_it() {
    let (mut state, _) = begin(Path::Home, keyless(), 0);
    let effects = feed(&mut state, Event::Done { step: Step::DaemonStatus, idle: Some(true) }, 3);
    assert_eq!(runs(&effects), [Step::KeyedRestart]);
    done(&mut state, Step::Login, 4);
    assert_eq!(runs(&done(&mut state, Step::KeyedRestart, 6)), [Step::Open]);
}

#[test]
fn a_busy_or_unread_daemon_is_never_restarted() {
    for idle in [Some(false), None] {
        let (mut state, _) = begin(Path::Home, keyless(), 0);
        done(&mut state, Step::Login, 1);
        let effects = feed(&mut state, Event::Done { step: Step::DaemonStatus, idle }, 2);
        assert_eq!(runs(&effects), [Step::Open], "idle: {idle:?}");
    }
}

#[test]
fn a_machine_that_holds_the_key_is_not_restarted_and_a_safe_daemon_is_not_asked() {
    let (_, effects) = begin(Path::Composer, Facts { holds_key: true, ..keyless() }, 0);
    assert_eq!(runs(&effects), [Step::Copy, Step::Login]);
    let (_, effects) = begin(Path::Composer, Facts { daemon_said_safe: true, ..keyless() }, 0);
    assert_eq!(runs(&effects), [Step::Copy, Step::Login, Step::KeyedRestart]);
}

// MARK: Step times

#[test]
fn a_line_is_whole_milliseconds_and_names_only_the_step() {
    assert_eq!(line("connect", 1234), "cloud start step: connect 1234 ms");
    assert_eq!(line("login.transfer", 0), "cloud start step: login.transfer 0 ms");
}

#[test]
fn the_step_times_add_up_to_the_span_from_the_first_step_to_the_chats_start() {
    let (mut state, mut all) = begin(Path::Session, keyless(), 500);
    for (event, now) in [
        (Event::Done { step: Step::Connect, idle: None }, 2_700),
        (Event::Mark { step: Step::Login, name: "login.gate".to_owned() }, 2_900),
        (Event::Done { step: Step::DaemonStatus, idle: Some(true) }, 3_100),
        (Event::Mark { step: Step::Login, name: "login.machine".to_owned() }, 4_000),
        (Event::Done { step: Step::Login, idle: None }, 6_200),
        (Event::Done { step: Step::KeyedRestart, idle: None }, 7_050),
        (Event::Done { step: Step::Anchor, idle: None }, 7_400),
        (Event::Done { step: Step::Tab, idle: None }, 7_900),
        (Event::Done { step: Step::Start, idle: None }, 9_000),
    ] {
        all.extend(feed(&mut state, event, now));
    }
    assert_eq!(finished(&all), Some(false));
    let marks: Vec<(String, u64)> = lines(&all).iter().map(|line| ms(line)).collect();
    let top: Vec<&(String, u64)> = marks.iter().filter(|(name, _)| !name.contains('.')).collect();
    assert_eq!(
        top.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>(),
        ["connect", "login", "approvals", "anchor", "tab", "start"],
        "in the order they ended"
    );
    // Each top-level step runs from the end of the one before it: together they are the whole span.
    assert_eq!(top.iter().map(|(_, ms)| ms).sum::<u64>(), 9_000 - 500);
    // A step's own splits run from its start, each from the one before: they fit inside the step.
    let login: Vec<u64> =
        marks.iter().filter(|(name, _)| name.starts_with("login.")).map(|(_, ms)| *ms).collect();
    assert_eq!(login, [200, 1_100]);
    assert!(login.iter().sum::<u64>() <= 6_200 - 2_700);
    let approvals: Vec<&(String, u64)> =
        marks.iter().filter(|(name, _)| name.starts_with("approvals.")).collect();
    assert_eq!(
        approvals,
        [&("approvals.status".to_owned(), 400), &("approvals.restart".to_owned(), 3_950)]
    );
}

#[test]
fn the_machine_reads_log_nothing_of_their_own() {
    // Their time is the login's `login.machine` split; a second clock would double count it.
    let facts = Facts { reads_machine: true, claude: true, ..keyless() };
    let (mut state, mut all) = begin(Path::MachineReads, facts, 0);
    all.extend(done(&mut state, Step::Guest, 10));
    all.extend(done(&mut state, Step::MachineLogin, 20));
    assert!(lines(&all).is_empty());
}

// MARK: Failures and stray events

#[test]
fn a_failed_step_cancels_the_steps_still_running_and_starts_nothing_more() {
    let (mut state, _) = begin(Path::Composer, keyless(), 0);
    let effects = feed(&mut state, Event::Failed { step: Step::Copy }, 5);
    assert_eq!(
        effects,
        [
            Effect::Cancel { step: Step::Login },
            Effect::Cancel { step: Step::DaemonStatus },
            Effect::Finish { failed: true }
        ]
    );
    // A late end of a cancelled step changes nothing.
    assert!(done(&mut state, Step::Login, 9).is_empty());
}

#[test]
fn an_event_for_a_step_that_is_not_running_is_ignored() {
    let (mut state, _) = begin(Path::Session, keyless(), 0);
    let before = state.clone();
    assert!(done(&mut state, Step::Anchor, 5).is_empty());
    assert!(
        feed(&mut state, Event::Mark { step: Step::Login, name: "login.gate".to_owned() }, 6)
            .is_empty()
    );
    assert_eq!(state, before);
    // A second begin never restarts a sequence under way.
    assert!(feed(&mut state, Event::Begin { path: Path::Home, facts: keyless() }, 7).is_empty());
    assert_eq!(state, before);
}

#[test]
fn the_app_speaks_camel_case_json() {
    let event: Event = serde_json::from_str(r#"{"on":"begin","path":"machine-reads","facts":{"readsMachine":true,"claude":true,"warmCopyConflict":true}}"#).unwrap();
    assert_eq!(
        event,
        Event::Begin {
            path: Path::MachineReads,
            facts: Facts {
                reads_machine: true,
                claude: true,
                warm_copy_conflict: true,
                ..keyless()
            }
        }
    );
    let event: Event =
        serde_json::from_str(r#"{"on":"done","step":"daemon-status","idle":true}"#).unwrap();
    assert_eq!(event, Event::Done { step: Step::DaemonStatus, idle: Some(true) });
    let event: Event =
        serde_json::from_str(r#"{"on":"mark","step":"login","name":"transfer.guest"}"#).unwrap();
    assert_eq!(event, Event::Mark { step: Step::Login, name: "transfer.guest".to_owned() });
    assert_eq!(
        serde_json::to_value(Effect::Run { step: Step::KeyedRestart }).unwrap(),
        serde_json::json!({"do": "run", "step": "keyed-restart"})
    );
    assert_eq!(
        serde_json::to_value(Effect::Finish { failed: false }).unwrap(),
        serde_json::json!({"do": "finish", "failed": false})
    );
}
