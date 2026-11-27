//! Parity with the Swift `OnboardingModel` footer and `ImportStepModel` rules
//! these came from (CmuxNextOnboardingTests' footer and import cases).

use super::*;

fn import(phase: ImportPhase) -> Window {
    Window {
        step: Step::ImportData,
        import: ImportFacts { phase, ..ImportFacts::default() },
        computer_use: ComputerUseFacts::default(),
    }
}

fn step(step: Step) -> Window {
    Window { step, import: ImportFacts::default(), computer_use: ComputerUseFacts::default() }
}

#[test]
fn the_import_footer_walks_find_explain_consent_import_done() {
    let cases = [
        (ImportPhase::Idle, PrimaryTitle::FindBrowsers, PrimaryAction::Detect),
        (ImportPhase::Detecting, PrimaryTitle::Detecting, PrimaryAction::None),
        (ImportPhase::ExplainingAccess, PrimaryTitle::Continue, PrimaryAction::ContinueAccess),
        (
            ImportPhase::ConfirmingPasswords,
            PrimaryTitle::BeginImporting,
            PrimaryAction::StartImport,
        ),
        (ImportPhase::Ready, PrimaryTitle::Done, PrimaryAction::Finish),
        (ImportPhase::Importing, PrimaryTitle::Done, PrimaryAction::Finish),
        (ImportPhase::Finished, PrimaryTitle::Done, PrimaryAction::Finish),
    ];
    for (phase, title, action) in cases {
        let footer = footer(&import(phase));
        assert_eq!((footer.primary_title, footer.primary), (title, action), "{phase:?}");
    }
}

#[test]
fn a_checked_plan_imports_and_a_repeated_click_waits() {
    let mut window = import(ImportPhase::Ready);
    window.import.has_plan = true;
    let ready = footer(&window);
    assert_eq!(
        (ready.primary_title, ready.primary),
        (PrimaryTitle::Import, PrimaryAction::StartImport)
    );
    window.import.phase = ImportPhase::Importing;
    window.import.just_started = true;
    assert_eq!(footer(&window).primary, PrimaryAction::None);
    window.import.phase = ImportPhase::Cancelled;
    window.import.just_started = false;
    assert_eq!(
        footer(&window).primary,
        PrimaryAction::StartImport,
        "a cancelled import may run again"
    );
}

#[test]
fn touch_id_up_waits_on_the_consent_screen() {
    let mut window = import(ImportPhase::ConfirmingPasswords);
    window.import.authorizing = true;
    let footer = footer(&window);
    assert_eq!(footer.primary, PrimaryAction::None);
    assert_eq!(footer.primary_title, PrimaryTitle::BeginImporting);
    assert_eq!(footer.back, None, "Back is off while Touch ID is up");
    assert!(footer.skip_importing && footer.skip_leaves_consent);
    assert_eq!(footer.flow_progress, Some(0.75));
}

#[test]
fn back_leaves_either_explainer_unless_its_sheet_is_up() {
    let mut explaining = import(ImportPhase::ExplainingAccess);
    assert_eq!(footer(&explaining).back, Some(BackAction::CancelAccess));
    assert_eq!(footer(&explaining).flow_progress, Some(0.5));
    explaining.import.requesting_access = true;
    assert_eq!(footer(&explaining).back, None);
    assert_eq!(
        footer(&import(ImportPhase::ConfirmingPasswords)).back,
        Some(BackAction::BackFromConsent)
    );
    assert_eq!(footer(&import(ImportPhase::Ready)).back, None);
    assert_eq!(footer(&step(Step::Agents)).back, None);
}

#[test]
fn detection_holds_the_primary_button() {
    assert!(!footer(&import(ImportPhase::Detecting)).can_advance);
    assert!(footer(&import(ImportPhase::Idle)).can_advance);
    assert!(footer(&step(Step::ComputerUse)).can_advance);
}

#[test]
fn the_other_tools() {
    for tool in [Step::Agents, Step::MakeItYours] {
        let footer = footer(&step(tool));
        assert_eq!(
            (footer.primary_title, footer.primary),
            (PrimaryTitle::Continue, PrimaryAction::Finish)
        );
        assert!(!footer.skip_importing && footer.flow_progress.is_none());
    }
    assert!(footer(&step(Step::MakeItYours)).skip_reverts_choices);
    assert!(!footer(&step(Step::Agents)).skip_reverts_choices);
    let mut computer = step(Step::ComputerUse);
    assert_eq!(footer(&computer).primary, PrimaryAction::AllowNext);
    assert_eq!(footer(&computer).primary_title, PrimaryTitle::Done);
    computer.computer_use.helper_failed = true;
    assert_eq!(footer(&computer).primary, PrimaryAction::RestartHelper);
    computer.computer_use.all_granted = true;
    assert_eq!(footer(&computer).primary, PrimaryAction::Finish);
}

#[test]
fn edits_and_start_follow_the_phase() {
    for phase in [ImportPhase::Ready, ImportPhase::Cancelled, ImportPhase::Failed] {
        assert!(phase.can_edit_selection(), "{phase:?}");
    }
    for phase in
        [ImportPhase::Idle, ImportPhase::Detecting, ImportPhase::Importing, ImportPhase::Finished]
    {
        assert!(!phase.can_edit_selection(), "{phase:?}");
    }
    let empty = ImportFacts { phase: ImportPhase::Ready, ..ImportFacts::default() };
    assert!(!empty.can_start());
    assert!(ImportFacts { has_plan: true, ..empty }.can_start());
    let finished = ImportFacts { phase: ImportPhase::Finished, has_plan: true, ..empty };
    assert!(!finished.can_start(), "a finished import starts again only from an editable phase");
}

#[test]
fn import_passwords_from_csv_shows_when_the_keychain_cannot_help() {
    let facts = |phase, export_only, denied, error| ImportFacts {
        phase,
        export_only_passwords: export_only,
        authorization_denied: denied,
        password_error: error,
        ..ImportFacts::default()
    };
    assert!(!facts(ImportPhase::Importing, true, true, true).offers_password_csv());
    assert!(!facts(ImportPhase::ExplainingAccess, true, false, false).offers_password_csv());
    assert!(facts(ImportPhase::ConfirmingPasswords, false, true, false).offers_password_csv());
    assert!(!facts(ImportPhase::ConfirmingPasswords, true, false, false).offers_password_csv());
    assert!(facts(ImportPhase::Finished, false, false, true).offers_password_csv());
    assert!(facts(ImportPhase::Ready, true, false, false).offers_password_csv());
    assert!(!facts(ImportPhase::Ready, false, true, true).offers_password_csv());
}

#[test]
fn kinds_offered_checked_and_preset() {
    assert_eq!(kind_choices(false), OFFERED.to_vec());
    assert_eq!(kind_choices(true).last(), Some(&ImportKind::Passwords));
    assert_eq!(
        default_kinds(),
        vec![ImportKind::Bookmarks, ImportKind::History, ImportKind::Cookies]
    );
    let preset = [ImportKind::Passwords, ImportKind::Cookies, ImportKind::Cookies];
    assert_eq!(preset_kinds(&preset, false), vec![ImportKind::Cookies]);
    assert_eq!(preset_kinds(&preset, true), vec![ImportKind::Cookies, ImportKind::Passwords]);
}

#[test]
fn edge_leads_stable_first_and_the_rest_keep_their_order() {
    let browsers: Vec<String> =
        ["chrome", "edgeDev", "safari", "edge", "arc", "edgeBeta"].map(String::from).to_vec();
    assert_eq!(edge_first(&browsers), vec![3, 5, 1, 0, 2, 4]);
    assert_eq!(edge_first(&[]), Vec::<usize>::new());
}

#[test]
fn the_wire_names_match_the_app() {
    let window: Window = serde_json::from_value(serde_json::json!({
        "step": "importData", "import": {"phase": "confirmingPasswords"}
    }))
    .unwrap();
    assert_eq!(
        serde_json::to_value(footer(&window)).unwrap(),
        serde_json::json!({
            "primaryTitle": "beginImporting", "primary": "startImport", "skipImporting": true,
            "back": "backFromConsent", "canAdvance": true, "flowProgress": 0.75,
            "skipLeavesConsent": true, "skipRevertsChoices": false
        })
    );
}
