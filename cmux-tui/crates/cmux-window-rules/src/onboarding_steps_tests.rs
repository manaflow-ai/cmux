//! Parity with the Swift step models these rules came from: the cases of
//! ComputerUseSetupWindowTests, ComputerUseSetupParityTests and
//! OnboardingAgentsStepTests, replayed as events.

use super::*;

fn window() -> ComputerUse {
    ComputerUse { source: true, helper: true, ..ComputerUse::default() }
}

fn grants(accessibility: bool, screen_recording: bool) -> Event {
    Event::Grants { grants: Grants { accessibility, screen_recording, ..Grants::default() } }
}

fn read(state: &ComputerUse, event: Event) -> (ComputerUse, Outcome) {
    let outcome = computer_use(state, event);
    (outcome.state.clone(), outcome)
}

#[test]
fn only_the_next_missing_row_is_primary() {
    let (state, outcome) = read(&window(), grants(false, false));
    assert_eq!(outcome.view.next_pane, Some(Pane::Accessibility));
    assert_eq!(outcome.view.primary, Some(Pane::Accessibility));
    assert_eq!(state.control(Pane::ScreenRecording), Control::Allow);

    let (state, outcome) = read(&state, grants(true, false));
    assert_eq!(outcome.view.next_pane, Some(Pane::ScreenRecording));
    assert_eq!(outcome.view.primary, Some(Pane::ScreenRecording));
    assert_eq!(state.control(Pane::Accessibility), Control::Done);
    assert_eq!(state.control(Pane::ScreenRecording), Control::AllowPrimary);
    assert!(!outcome.view.all_granted);
}

#[test]
fn allow_opens_the_list_and_the_row_waits_gray() {
    let (state, _) = read(&window(), grants(false, false));
    let (state, outcome) = read(&state, Event::Allow { pane: Pane::Accessibility });
    assert_eq!(outcome.open_settings, Some(Pane::Accessibility));
    assert_eq!(state.helping, Some(Pane::Accessibility));
    assert!(
        !state.is_primary(Pane::Accessibility),
        "the row's Allow goes gray while the panel shows"
    );
    assert_eq!(outcome.view.primary, None);
    assert_eq!(state.control(Pane::Accessibility), Control::Allow);
    assert!(!outcome.enable, "Computer Use was on");
}

#[test]
fn the_grant_landing_closes_the_panel_and_brings_the_window_back() {
    let (state, _) = read(&window(), grants(false, false));
    let (state, _) = read(&state, Event::Allow { pane: Pane::Accessibility });
    let (state, outcome) = read(&state, grants(true, false));
    assert_eq!(state.helping, None);
    assert!(outcome.comeback);
    assert!(state.is_primary(Pane::ScreenRecording));

    let (state, _) = read(&state, Event::Allow { pane: Pane::ScreenRecording });
    let (state, outcome) = read(&state, grants(true, true));
    assert!(outcome.comeback);
    assert!(outcome.view.all_granted);
    assert_eq!(outcome.view.next_pane, None);
    assert_eq!(outcome.view.note, None);
    assert_eq!(state.note(), None);
}

#[test]
fn a_grant_without_the_panel_does_not_pull_the_window_forward() {
    let (state, _) = read(&window(), grants(false, false));
    let (_, outcome) = read(&state, grants(true, false));
    assert!(!outcome.comeback);
}

#[test]
fn return_allows_the_next_row_and_waits_while_it_shows() {
    let (state, _) = read(&window(), grants(false, false));
    let (state, outcome) = read(&state, Event::AllowNext);
    assert!(outcome.accepted);
    assert_eq!(outcome.open_settings, Some(Pane::Accessibility));
    let (_, outcome) = read(&state, Event::AllowNext);
    assert!(!outcome.accepted, "Return does nothing while the row waits for its grant");
    assert_eq!(outcome.open_settings, None);
}

#[test]
fn a_failed_helper_has_no_primary_row_and_restart_restarts() {
    let failed = Event::Grants { grants: Grants { helper_failed: true, ..Grants::default() } };
    let (state, outcome) = read(&window(), failed);
    assert_eq!(outcome.view.next_pane, None);
    assert_eq!(state.control(Pane::Accessibility), Control::Hidden);
    assert_eq!(outcome.view.note, Some(Note::HelperFailed));
    let (_, outcome) = read(&state, Event::AllowNext);
    assert!(!outcome.accepted, "no primary row: OnboardingModel's Return restarts instead");
    let (_, outcome) = read(&state, Event::Restart);
    assert!(outcome.restart);
    assert_eq!(outcome.open_settings, None);
}

#[test]
fn restart_does_nothing_while_the_helper_answers() {
    let (state, _) = read(&window(), grants(false, false));
    let (_, outcome) = read(&state, Event::Restart);
    assert!(!outcome.restart);
}

#[test]
fn a_helper_failure_takes_the_panel_down() {
    let (state, _) = read(&window(), grants(false, false));
    let (state, _) = read(&state, Event::Allow { pane: Pane::Accessibility });
    let failed = Event::Grants { grants: Grants { helper_failed: true, ..Grants::default() } };
    let (state, outcome) = read(&state, failed);
    assert_eq!(state.helping, None);
    assert!(!outcome.comeback, "a failure is not a grant landing");
}

#[test]
fn a_version_mismatch_hides_the_rows_and_says_so() {
    let mismatch =
        Event::Grants { grants: Grants { helper_version_mismatch: true, ..Grants::default() } };
    let (state, outcome) = read(&window(), mismatch);
    assert_eq!(outcome.view.next_pane, None);
    assert!(outcome.view.rows.iter().all(|row| row.control == Control::Hidden));
    assert_eq!(state.note(), Some(Note::HelperVersionMismatch));
}

#[test]
fn no_signed_helper_says_unavailable_and_opens_nothing() {
    let state = ComputerUse { helper: false, ..window() };
    let (state, _) = read(&state, grants(false, false));
    let (state, outcome) = read(&state, Event::Allow { pane: Pane::Accessibility });
    assert!(state.unavailable);
    assert_eq!(outcome.open_settings, None);
    assert!(!state.is_primary(Pane::Accessibility));
    assert_eq!(outcome.view.note, Some(Note::Unavailable));
}

#[test]
fn no_source_allows_nothing() {
    let state = ComputerUse { source: false, helper: false, ..ComputerUse::default() };
    let (state, outcome) = read(&state, Event::Allow { pane: Pane::Accessibility });
    assert!(!state.unavailable);
    assert_eq!(outcome.open_settings, None);
}

#[test]
fn an_allow_while_off_turns_computer_use_on_first() {
    let off = Event::Grants { grants: Grants { is_off: true, ..Grants::default() } };
    let (state, outcome) = read(&window(), off);
    assert_eq!(outcome.view.note, Some(Note::Off));
    assert!(!outcome.view.all_granted);
    let (_, outcome) = read(&state, Event::Allow { pane: Pane::Accessibility });
    assert!(outcome.enable);
    assert_eq!(outcome.open_settings, Some(Pane::Accessibility));
}

#[test]
fn a_granted_row_allows_nothing() {
    let (state, _) = read(&window(), grants(true, false));
    let (state, outcome) = read(&state, Event::Allow { pane: Pane::Accessibility });
    assert_eq!(outcome.open_settings, None);
    assert!(state.allowed_here.is_empty());
}

#[test]
fn the_last_grant_after_the_persons_allow_shows_the_done_view_and_schedules_the_close() {
    let (state, _) = read(&window(), grants(true, false));
    let (state, outcome) = read(&state, Event::Allow { pane: Pane::ScreenRecording });
    assert!(!outcome.view.finished);
    let (_, outcome) = read(&state, grants(true, true));
    assert!(outcome.view.finished, "the done view showed");
    assert_eq!(outcome.timer, Some(Timer::Schedule));
}

#[test]
fn a_window_opened_ready_keeps_its_rows_and_stays_open() {
    let (_, outcome) = read(&window(), grants(true, true));
    assert!(!outcome.view.finished);
    assert!(outcome.view.all_granted, "the ready line and Done, as before");
    assert_eq!(outcome.timer, Some(Timer::Cancel));
}

#[test]
fn a_revoked_grant_during_the_done_view_cancels_the_close() {
    let (state, _) = read(&window(), grants(true, false));
    let (state, _) = read(&state, Event::Allow { pane: Pane::ScreenRecording });
    let (state, outcome) = read(&state, grants(true, true));
    assert_eq!(outcome.timer, Some(Timer::Schedule));
    let (_, outcome) = read(&state, grants(false, true));
    assert!(!outcome.view.finished);
    assert_eq!(outcome.timer, Some(Timer::Cancel));
}

#[test]
fn a_manual_close_cancels_the_timed_close() {
    let (state, _) = read(&window(), grants(true, false));
    let (state, _) = read(&state, Event::Allow { pane: Pane::ScreenRecording });
    let (state, _) = read(&state, Event::AllowOnceKnown { pane: Pane::ScreenRecording });
    let (state, outcome) = read(&state, Event::Stop);
    assert_eq!(outcome.timer, Some(Timer::Cancel));
    assert_eq!(state.helping, None);
    assert_eq!(state.pending_allow, None);
}

#[test]
fn screenshots_allowed_here_shows_the_capture_note_once_its_grant_lands() {
    let (state, _) = read(&window(), grants(false, false));
    let (state, outcome) = read(&state, Event::Allow { pane: Pane::ScreenRecording });
    assert!(!outcome.view.confirms_capture, "not before the grant");
    let (_, outcome) = read(&state, grants(false, true));
    assert!(outcome.view.confirms_capture);
    assert!(!outcome.view.finished, "Accessibility still waits");
}

#[test]
fn screen_recording_granted_elsewhere_shows_no_capture_note() {
    let (_, outcome) = read(&window(), grants(false, true));
    assert!(!outcome.view.confirms_capture);
}

#[test]
fn a_grant_entry_starts_its_allow_once_the_grants_are_read() {
    let (state, outcome) = read(&window(), Event::AllowOnceKnown { pane: Pane::ScreenRecording });
    assert_eq!(outcome.open_settings, None, "no read yet");
    let reading = Event::Grants { grants: Grants { is_reading: true, ..Grants::default() } };
    let (state, outcome) = read(&state, reading);
    assert_eq!(outcome.open_settings, None, "grants still being read start nothing");
    assert_eq!(state.pending_allow, Some(Pane::ScreenRecording));
    let (state, outcome) = read(&state, grants(false, false));
    assert_eq!(outcome.open_settings, Some(Pane::ScreenRecording));
    assert_eq!(state.helping, Some(Pane::ScreenRecording), "the drag panel shows");
    assert_eq!(state.pending_allow, None);
}

#[test]
fn a_grant_entry_for_a_grant_already_on_opens_nothing() {
    let (state, _) = read(&window(), grants(true, false));
    let (state, outcome) = read(&state, Event::AllowOnceKnown { pane: Pane::Accessibility });
    assert_eq!(outcome.open_settings, None);
    let (_, outcome) = read(&state, Event::AllowOnceKnown { pane: Pane::ScreenRecording });
    assert_eq!(
        outcome.open_settings,
        Some(Pane::ScreenRecording),
        "an open window starts the grant's Allow at once"
    );
}

#[test]
fn a_grant_entry_with_a_failed_helper_opens_nothing() {
    let (state, _) = read(&window(), Event::AllowOnceKnown { pane: Pane::Accessibility });
    let failed = Event::Grants { grants: Grants { helper_failed: true, ..Grants::default() } };
    let (state, outcome) = read(&state, failed);
    assert_eq!(outcome.open_settings, None);
    assert_eq!(state.helping, None);
    assert_eq!(state.pending_allow, None, "the entry's Allow is spent");
}

#[test]
fn a_grant_entry_for_the_row_whose_panel_shows_waits() {
    let (state, _) = read(&window(), grants(false, false));
    let (state, _) = read(&state, Event::Allow { pane: Pane::Accessibility });
    let (_, outcome) = read(&state, Event::AllowOnceKnown { pane: Pane::Accessibility });
    assert_eq!(outcome.open_settings, None);
}

#[test]
fn the_back_button_closes_the_panel_and_brings_the_window_back() {
    let (state, _) = read(&window(), grants(false, false));
    let (_, outcome) = read(&state, Event::DismissHelper);
    assert!(!outcome.comeback, "no panel, nothing to close");
    let (state, _) = read(&state, Event::Allow { pane: Pane::Accessibility });
    let (state, outcome) = read(&state, Event::DismissHelper);
    assert!(outcome.comeback);
    assert_eq!(state.helping, None);
    assert!(state.is_primary(Pane::Accessibility), "its row is primary again");
}

#[test]
fn events_and_states_read_from_the_apps_json() {
    let event: Event =
        serde_json::from_str(r#"{"kind":"allowOnceKnown","pane":"screenRecording"}"#).unwrap();
    assert_eq!(event, Event::AllowOnceKnown { pane: Pane::ScreenRecording });
    let state: ComputerUse = serde_json::from_str(r#"{"source":true,"helper":true}"#).unwrap();
    assert_eq!(state, window());
}

fn agent(id: &str, auth: Auth, installed: bool) -> Agent {
    Agent { id: id.to_owned(), auth, installed }
}

#[test]
fn the_step_lists_the_installed_agents_and_offers_the_missing_ones_cmux_installs() {
    let facts = AgentsFacts {
        agents: vec![
            agent("claude", Auth::Unknown, false),
            agent("codex", Auth::SignedIn, true),
            agent("gemini", Auth::Unknown, false),
            agent("mine", Auth::Expired, true),
        ],
        ..AgentsFacts::default()
    };
    let view = agents(&facts);
    assert_eq!(view.listed, vec![1, 3]);
    assert_eq!(view.installable, vec![0], "only Claude Code and Codex install");
    let offers: Vec<bool> = view.marks.iter().map(|marks| marks.offers_sign_in).collect();
    assert_eq!(offers, vec![false, false, false, true], "no Sign In for a CLI that is not here");
    assert!(view.marks[0].can_install);
    assert!(!view.marks[2].can_install);
    assert_eq!(
        install_page("claude").unwrap(),
        "https://docs.anthropic.com/en/docs/claude-code/setup"
    );
    assert_eq!(install_page("gemini"), None);
}

#[test]
fn a_second_install_while_one_runs_starts_nothing() {
    let facts = AgentsFacts {
        agents: vec![agent("claude", Auth::Unknown, false), agent("codex", Auth::Unknown, false)],
        installing: true,
        ..AgentsFacts::default()
    };
    assert!(agents(&facts).marks.iter().all(|marks| !marks.can_install));
}

#[test]
fn an_installs_read_ends_it_with_sign_in_or_says_it_is_not_found_yet() {
    let mut facts = AgentsFacts {
        agents: vec![agent("claude", Auth::SignedOut, true), agent("codex", Auth::SignedIn, true)],
        install_awaiting_read: Some("claude".to_owned()),
        ..AgentsFacts::default()
    };
    assert_eq!(agents(&facts).finish_install, Some(FinishInstall::SignIn));
    facts.agents[0].installed = false;
    assert_eq!(
        agents(&facts).finish_install,
        Some(FinishInstall::Failed { message: INSTALLED_NOT_FOUND.to_owned() })
    );
    facts.install_awaiting_read = None;
    assert_eq!(agents(&facts).finish_install, None);
}

#[test]
fn a_read_that_shows_the_signing_in_agent_signed_in_stops_asking() {
    let mut facts = AgentsFacts {
        agents: vec![agent("claude", Auth::SignedOut, true)],
        signing_in: Some("claude".to_owned()),
        ..AgentsFacts::default()
    };
    assert!(!agents(&facts).signed_in_now);
    facts.agents[0].auth = Auth::SignedIn;
    assert!(agents(&facts).signed_in_now, "signed in now: the step stops asking");
    facts.signing_in = Some("codex".to_owned());
    assert!(!agents(&facts).signed_in_now);
}

#[test]
fn an_unknown_login_counts_once_the_person_confirms_it() {
    let mut facts = AgentsFacts {
        agents: vec![agent("claude", Auth::Unknown, true), agent("codex", Auth::SignedOut, true)],
        ..AgentsFacts::default()
    };
    let marks = agents(&facts).marks;
    assert!(!marks[0].counts_as_signed_in);
    assert!(!marks[0].awaits_confirmation, "no login opened here");

    facts.logins_opened = vec!["claude".to_owned(), "codex".to_owned()];
    let marks = agents(&facts).marks;
    assert!(marks[0].awaits_confirmation);
    assert!(!marks[1].awaits_confirmation, "a known signed-out agent stays signed out");

    facts.confirmed_logins = vec!["claude".to_owned()];
    let marks = agents(&facts).marks;
    assert!(marks[0].counts_as_signed_in);
    assert!(!marks[0].awaits_confirmation);
    assert!(marks[0].offers_sign_in, "Sign In still shows for an unknown sign-in");
}

#[test]
fn a_signed_in_agent_counts_and_offers_no_sign_in() {
    let facts = AgentsFacts {
        agents: vec![agent("codex", Auth::SignedIn, true)],
        ..AgentsFacts::default()
    };
    let marks = agents(&facts).marks[0];
    assert!(marks.counts_as_signed_in);
    assert!(!marks.offers_sign_in);
}
