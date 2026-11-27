use super::*;

fn prefs() -> Preferences {
    Preferences::default()
}

fn run(flow: &mut Flow, events: &[Event]) -> Vec<Effect> {
    events.iter().flat_map(|e| flow.handle(*e, prefs())).collect()
}

#[test]
fn scheduled_check_shows_nothing() {
    let mut flow = Flow::default();
    run(&mut flow, &[Event::Sparkle { next: Phase::Checking }]);
    assert_eq!(flow.card(true), None);
    run(&mut flow, &[Event::Sparkle { next: Phase::Downloading }]);
    assert_eq!(flow.card(true), None);
    let effects = run(&mut flow, &[Event::Sparkle { next: Phase::Ready }]);
    assert!(effects.is_empty());
    assert_eq!(flow.footer_pill(false), Some(Pill::Ready));
    assert_eq!(flow.footer_pill(true), None);
}

#[test]
fn user_check_shows_checking_and_its_note() {
    let mut flow = Flow::default();
    run(&mut flow, &[Event::CheckRequested, Event::Sparkle { next: Phase::Checking }]);
    assert_eq!(flow.card(true), Some(Card::Checking));
    run(&mut flow, &[Event::Sparkle { next: Phase::Note }]);
    assert_eq!(flow.card(true), Some(Card::Note));
    run(&mut flow, &[Event::NoteExpired]);
    assert_eq!(flow.phase, Phase::Hidden);
    assert_eq!(flow.card(true), None);
}

#[test]
fn a_check_after_the_person_asked_while_one_ran_is_theirs_only_once() {
    let mut flow = Flow::default();
    run(&mut flow, &[Event::Sparkle { next: Phase::Checking }, Event::CheckRequested]);
    assert!(!flow.ask_pending);
    assert_eq!(flow.card(true), Some(Card::Checking));
}

#[test]
fn install_click_held_until_staged() {
    let mut flow = Flow::default();
    run(&mut flow, &[Event::Sparkle { next: Phase::Downloading }, Event::InstallRequested]);
    assert_eq!(flow.card(true), Some(Card::Downloading));
    let effects = run(&mut flow, &[Event::Sparkle { next: Phase::Ready }]);
    assert_eq!(effects, vec![Effect::Install]);
    assert!(!flow.install_requested);
}

#[test]
fn install_on_available_downloads() {
    let mut flow = Flow { phase: Phase::Available, ..Flow::default() };
    assert_eq!(run(&mut flow, &[Event::InstallRequested]), vec![Effect::Download]);
    assert!(flow.install_requested && flow.user_asked && flow.download_asked);
}

#[test]
fn held_click_downloads_when_check_finds_one() {
    let mut flow = Flow::default();
    run(&mut flow, &[Event::Sparkle { next: Phase::Checking }, Event::InstallRequested]);
    assert_eq!(
        run(&mut flow, &[Event::Sparkle { next: Phase::Available }]),
        vec![Effect::Download]
    );
}

#[test]
fn download_requested_installs_with_one_click() {
    let mut flow = Flow { phase: Phase::Available, ..Flow::default() };
    let one_click = Preferences { one_click_install: true, ..prefs() };
    assert_eq!(flow.handle(Event::DownloadRequested, one_click), vec![Effect::Download]);
    assert!(flow.install_requested);
    let mut plain = Flow { phase: Phase::Available, ..Flow::default() };
    assert_eq!(plain.handle(Event::DownloadRequested, prefs()), vec![Effect::Download]);
    assert!(!plain.install_requested);
    let mut hidden = Flow::default();
    assert!(hidden.handle(Event::DownloadRequested, prefs()).is_empty());
}

#[test]
fn quit_cancels_a_staged_install_unless_install_on_quit() {
    let mut flow = Flow { phase: Phase::Ready, ..Flow::default() };
    assert_eq!(flow.handle(Event::QuitRequested, prefs()), vec![Effect::QuitCancelPendingInstall]);
    let on = Preferences { install_on_quit: true, ..prefs() };
    assert_eq!(flow.handle(Event::QuitRequested, on), vec![Effect::QuitProceed]);
    let mut idle = Flow::default();
    assert_eq!(idle.handle(Event::QuitRequested, prefs()), vec![Effect::QuitProceed]);
}

#[test]
fn found_update_shows_without_automatic_download() {
    let flow = Flow { phase: Phase::Available, ..Flow::default() };
    assert_eq!(flow.card(false), Some(Card::Available));
    assert_eq!(flow.card(true), None);
}

#[test]
fn cancelled_flow_drops_the_held_click() {
    let mut flow = Flow::default();
    run(&mut flow, &[Event::Sparkle { next: Phase::Downloading }, Event::InstallRequested]);
    run(&mut flow, &[Event::Sparkle { next: Phase::Hidden }]);
    assert!(!flow.install_requested && !flow.download_asked && !flow.user_asked);
    assert_eq!(flow.footer_pill(false), None);
}

#[test]
fn installing_pill_is_shown_even_when_silent() {
    let flow = Flow { phase: Phase::Installing, ..Flow::default() };
    assert_eq!(flow.footer_pill(true), Some(Pill::Installing));
}
