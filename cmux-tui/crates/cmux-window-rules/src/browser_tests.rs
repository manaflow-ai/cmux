use super::*;

#[test]
fn a_fixed_fit_toggles_off_when_the_tab_has_it() {
    assert_eq!(
        fit(Some("16:9"), None, None),
        Fit::Set { fit: Some("16:9".to_owned()), capability: FitCapability::BrowserFit }
    );
    assert_eq!(
        fit(Some("16:9"), None, Some("16:9")),
        Fit::Set { fit: None, capability: FitCapability::BrowserFit }
    );
    assert_eq!(
        fit(Some("1280"), None, Some("16:9")),
        Fit::Set { fit: Some("1280".to_owned()), capability: FitCapability::BrowserFitWidth }
    );
}

#[test]
fn the_fit_argument_sets_a_fit_and_off_clears_it() {
    assert_eq!(
        fit(None, Some(" 1440 "), Some("1440")),
        Fit::Set { fit: Some("1440".to_owned()), capability: FitCapability::BrowserFitWidth }
    );
    assert_eq!(
        fit(None, Some("OFF"), Some("16:9")),
        Fit::Set { fit: None, capability: FitCapability::BrowserFit }
    );
    assert_eq!(fit(None, Some("  "), None), Fit::NoBrowser);
    assert_eq!(fit(None, None, None), Fit::NoBrowser);
}

#[test]
fn the_menu_offers_the_fits_the_daemon_supports() {
    let fits = |fit, width| {
        menu_fits(fit, width).into_iter().filter_map(|action| action.fit).collect::<Vec<_>>()
    };
    assert_eq!(fits(true, true), vec!["16:9", "1280"]);
    assert_eq!(fits(true, false), vec!["16:9"]);
    assert_eq!(fits(false, true), vec!["1280"]);
}

#[test]
fn device_arguments_emulate_and_none_clears() {
    assert_eq!(device(None, None), Device::Menu);
    assert_eq!(
        device(Some(" iPhone 15 "), Some("landscape")),
        Device::Emulate {
            device: Some("iPhone 15".to_owned()),
            orientation: Some("landscape".to_owned())
        }
    );
    assert_eq!(device(Some("None"), None), Device::Emulate { device: None, orientation: None });
    assert_eq!(
        device(None, Some("portrait")),
        Device::Emulate { device: Some(String::new()), orientation: Some("portrait".to_owned()) }
    );
}

#[test]
fn a_named_tab_needs_a_page() {
    let named = PipFacts { named: true, shown_video: true, ..PipFacts::default() };
    assert_eq!(pip_page(named), PipPage::NeedsPage);
    assert_eq!(pip_page(PipFacts { named_page: true, ..named }), PipPage::Named);
}

#[test]
fn the_card_menu_acts_on_the_shown_video_only() {
    let card = PipFacts { card: true, focused: true, focused_video: true, ..PipFacts::default() };
    assert_eq!(pip_page(card), PipPage::NoVideo);
    assert_eq!(pip_page(PipFacts { shown_video: true, ..card }), PipPage::Shown);
}

#[test]
fn a_focused_video_comes_before_the_shown_one_then_any_focused_page() {
    let both =
        PipFacts { focused: true, focused_video: true, shown_video: true, ..PipFacts::default() };
    assert_eq!(pip_page(both), PipPage::Focused);
    assert_eq!(pip_page(PipFacts { focused_video: false, ..both }), PipPage::Shown);
    assert_eq!(pip_page(PipFacts { focused: true, ..PipFacts::default() }), PipPage::Focused);
    assert_eq!(pip_page(PipFacts::default()), PipPage::NoVideo);
}

#[test]
fn the_row_shows_on_a_video_while_enabled_and_reads_exit_when_floating() {
    let tab = PipRowFacts { enabled: true, target: PipTarget::Tab, video: true, floating: false };
    assert_eq!(pip_row(tab), PipRow { hidden: false, exit: false });
    assert_eq!(
        pip_row(PipRowFacts { floating: true, ..tab }),
        PipRow { hidden: false, exit: true }
    );
    assert!(pip_row(PipRowFacts { enabled: false, ..tab }).hidden);
    assert!(pip_row(PipRowFacts { video: false, ..tab }).hidden);
    assert_eq!(
        pip_row(PipRowFacts { target: PipTarget::Other, floating: true, ..tab }),
        PipRow { hidden: false, exit: false }
    );
    assert!(!pip_row(PipRowFacts { target: PipTarget::Card, ..tab }).hidden);
    assert!(pip_row(PipRowFacts { enabled: false, target: PipTarget::Other, ..tab }).hidden);
}
