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
    feed(state, Event::Done { step, idle: None, still: None }, now)
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
    let effects = feed(
        &mut state,
        Event::Done { step: Step::DaemonStatus, idle: Some(false), still: Some(true) },
        30,
    );
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
        runs(&feed(
            &mut state,
            Event::Done { step: Step::DaemonStatus, idle: Some(false), still: Some(true) },
            6
        ))
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
    let effects = feed(
        &mut state,
        Event::Done { step: Step::DaemonStatus, idle: Some(true), still: Some(true) },
        3,
    );
    assert_eq!(runs(&effects), [Step::KeyedRestart]);
    done(&mut state, Step::Login, 4);
    assert_eq!(runs(&done(&mut state, Step::KeyedRestart, 6)), [Step::Open]);
}

#[test]
fn a_busy_or_unread_daemon_is_never_restarted() {
    for idle in [Some(false), None] {
        let (mut state, _) = begin(Path::Home, keyless(), 0);
        done(&mut state, Step::Login, 1);
        let effects =
            feed(&mut state, Event::Done { step: Step::DaemonStatus, idle, still: Some(true) }, 2);
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
        (Event::Done { step: Step::Connect, idle: None, still: None }, 2_700),
        (Event::Mark { step: Step::Login, name: "login.gate".to_owned() }, 2_900),
        (Event::Done { step: Step::DaemonStatus, idle: Some(true), still: Some(true) }, 3_100),
        (Event::Mark { step: Step::Login, name: "login.machine".to_owned() }, 4_000),
        (Event::Done { step: Step::Login, idle: None, still: None }, 6_200),
        (Event::Done { step: Step::KeyedRestart, idle: None, still: None }, 7_050),
        (Event::Done { step: Step::Anchor, idle: None, still: None }, 7_400),
        (Event::Done { step: Step::Tab, idle: None, still: None }, 7_900),
        (Event::Done { step: Step::Start, idle: None, still: None }, 9_000),
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
fn a_failed_step_cancels_the_steps_still_running_and_ends_once_they_ended() {
    let (mut state, _) = begin(Path::Composer, keyless(), 0);
    let effects = feed(&mut state, Event::Failed { step: Step::Copy }, 5);
    assert_eq!(
        effects,
        [Effect::Cancel { step: Step::Login }, Effect::Cancel { step: Step::DaemonStatus }]
    );
    // The start is not over while a step it began still runs: the app releases its gate only at the finish.
    assert!(done(&mut state, Step::Login, 9).is_empty());
    let effects = feed(
        &mut state,
        Event::Done { step: Step::DaemonStatus, idle: Some(true), still: Some(true) },
        11,
    );
    assert_eq!(effects, [Effect::Finish { failed: true }]);
}

/// #39069's review: an account change during the login threw before the approvals prep was awaited, so the start's gate
/// was released while the prep could still restart the daemon. The sequencer owns the prep through every exit.
#[test]
fn an_account_change_mid_login_ends_the_start_with_no_restart_after_it() {
    for path in [Path::Session, Path::Composer, Path::Home] {
        let (mut state, _) = begin(path, keyless(), 0);
        if path == Path::Session {
            done(&mut state, Step::Connect, 1);
        }
        // The login's account check throws: the start fails, and the approvals' status read is cancelled.
        let effects = feed(&mut state, Event::Failed { step: Step::Login }, 2);
        assert!(
            effects.contains(&Effect::Cancel { step: Step::DaemonStatus }),
            "{path:?}: {effects:?}"
        );
        assert!(finished(&effects).is_none(), "{path:?}: the prep still runs");
        // The other steps it cancelled end first (a composer start's copy).
        for cancelled in effects.iter().filter_map(|effect| match effect {
            Effect::Cancel { step } if *step != Step::DaemonStatus => Some(*step),
            _ => None,
        }) {
            assert!(done(&mut state, cancelled, 3).is_empty(), "{path:?}: the prep still runs");
        }
        // The status read answers idle anyway: nothing restarts, and the start ends only now.
        let effects = feed(
            &mut state,
            Event::Done { step: Step::DaemonStatus, idle: Some(true), still: Some(true) },
            3,
        );
        assert_eq!(effects, [Effect::Finish { failed: true }], "{path:?}");
        assert!(
            feed(&mut state, Event::Done { step: Step::KeyedRestart, idle: None, still: None }, 4)
                .is_empty()
        );
    }
}

#[test]
fn a_cancel_mid_login_cancels_the_prep_and_awaits_it_with_no_restart() {
    let (mut state, _) = begin(Path::Session, keyless(), 0);
    done(&mut state, Step::Connect, 1);
    let effects = feed(&mut state, Event::Stop, 2);
    assert_eq!(
        effects,
        [Effect::Cancel { step: Step::Login }, Effect::Cancel { step: Step::DaemonStatus }]
    );
    assert!(
        feed(
            &mut state,
            Event::Done { step: Step::DaemonStatus, idle: Some(true), still: Some(true) },
            3
        )
        .is_empty()
    );
    assert_eq!(done(&mut state, Step::Login, 4), [Effect::Finish { failed: true }]);
}

#[test]
fn a_cancel_while_the_restart_runs_awaits_it_before_the_end() {
    let (mut state, _) = begin(Path::Home, keyless(), 0);
    feed(
        &mut state,
        Event::Done { step: Step::DaemonStatus, idle: Some(true), still: Some(true) },
        1,
    );
    let effects = feed(&mut state, Event::Stop, 2);
    assert_eq!(
        effects,
        [Effect::Cancel { step: Step::Login }, Effect::Cancel { step: Step::KeyedRestart }]
    );
    assert!(done(&mut state, Step::Login, 3).is_empty());
    assert_eq!(done(&mut state, Step::KeyedRestart, 4), [Effect::Finish { failed: true }]);
}

#[test]
fn the_restart_begins_only_on_a_fresh_account_and_cancellation_check() {
    // The app checks the account that asked and the start's cancellation as it tells the status read's end.
    let (mut state, _) = begin(Path::Home, keyless(), 0);
    let effects = feed(
        &mut state,
        Event::Done { step: Step::DaemonStatus, idle: Some(true), still: None },
        1,
    );
    assert!(runs(&effects).is_empty(), "no check told: no restart");
    // A check that failed ends the start: the login is cancelled, and the end waits for it.
    let (mut state, _) = begin(Path::Home, keyless(), 0);
    let effects = feed(
        &mut state,
        Event::Done { step: Step::DaemonStatus, idle: Some(true), still: Some(false) },
        1,
    );
    assert_eq!(effects, [Effect::Cancel { step: Step::Login }]);
    assert_eq!(done(&mut state, Step::Login, 2), [Effect::Finish { failed: true }]);
    // A start stopped with nothing running ends at once.
    let (mut state, _) = begin(Path::MachineReads, Facts { reads_machine: true, ..keyless() }, 0);
    done(&mut state, Step::Guest, 1);
    assert!(feed(&mut state, Event::Stop, 2).is_empty(), "already ended");
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
        serde_json::from_str(r#"{"on":"done","step":"daemon-status","idle":true,"still":true}"#)
            .unwrap();
    assert_eq!(
        event,
        Event::Done { step: Step::DaemonStatus, idle: Some(true), still: Some(true) }
    );
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
