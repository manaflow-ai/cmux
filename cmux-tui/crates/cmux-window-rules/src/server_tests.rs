use super::*;

const CODE: &str = "K7QX2M9P";
const WORDS: [&str; 4] = ["copper", "lantern", "meadow", "violet"];

fn candidate() -> Candidate {
    Candidate {
        code: CODE.into(),
        name: "build-01".into(),
        words: WORDS.iter().map(|word| (*word).to_owned()).collect(),
        teams: vec!["team_personal".into(), "team_other".into()],
        is_chief_brain: false,
    }
}

/// Runs a whole approval as the mock source answers it: the candidate, then
/// the lookup's settle, then the approve's.
fn run(
    code: &str,
    typed: Option<&str>,
    name: Option<&str>,
    run_chief: Option<bool>,
    found: Option<Candidate>,
) -> (Vec<ApprovalEffect>, ApprovalEffect) {
    let start = ApprovalEvent::Start {
        code: code.into(),
        words: typed.map(str::to_owned),
        name: name.map(str::to_owned),
        run_chief,
    };
    let (mut state, mut effect) = approval_step(Approval::default(), start);
    let mut sent = Vec::new();
    for event in [
        ApprovalEvent::Candidate { found },
        ApprovalEvent::LookupSettled { reject: None },
        ApprovalEvent::ApproveSettled { reject: None },
    ] {
        match effect {
            ApprovalEffect::Finish { .. } => break,
            ApprovalEffect::Wait => {}
            other => sent.push(other),
        }
        (state, effect) = approval_step(state, event);
    }
    if let ApprovalEffect::Approve { .. } = effect {
        sent.push(effect.clone());
        (_, effect) = approval_step(state, ApprovalEvent::ApproveSettled { reject: None });
    }
    (sent, effect)
}

fn approvals(sent: &[ApprovalEffect]) -> Vec<&ApprovalEffect> {
    sent.iter().filter(|effect| matches!(effect, ApprovalEffect::Approve { .. })).collect()
}

fn approved() -> ApprovalEffect {
    ApprovalEffect::Finish { refusal: None, reject: None }
}

/// ServerHeadlessApprovalTests.approvesWhenCodeAndWordsMatch.
#[test]
fn approves_when_code_and_words_match() {
    let (sent, end) =
        run(CODE, Some("copper lantern meadow violet"), None, Some(false), Some(candidate()));
    assert_eq!(end, approved());
    assert_eq!(
        sent,
        vec![
            ApprovalEffect::Lookup { code: CODE.into() },
            ApprovalEffect::Approve {
                code: CODE.into(),
                team: "team_personal".into(),
                name: "build-01".into(),
                place_chief: false
            },
        ]
    );
}

/// ServerHeadlessApprovalTests.wordsMatchIgnoringCaseAndSeparators.
#[test]
fn words_match_ignoring_case_and_separators() {
    for typed in [
        "COPPER lantern Meadow violet",
        "copper, lantern, meadow, violet",
        "copper-lantern-meadow-violet",
        "  copper\tlantern  meadow violet ",
    ] {
        let (sent, end) = run(CODE, Some(typed), None, Some(false), Some(candidate()));
        assert_eq!(end, approved(), "{typed}");
        assert_eq!(approvals(&sent).len(), 1, "{typed}");
    }
}

/// ServerHeadlessApprovalTests.refusesWithoutWords: nothing is even looked up.
#[test]
fn refuses_without_words() {
    for typed in [None, Some(""), Some("   "), Some("1234 -- ,")] {
        let (sent, end) = run(CODE, typed, None, None, Some(candidate()));
        assert_eq!(end, ApprovalEffect::refuse(Refusal::WordsMissing), "{typed:?}");
        assert!(sent.is_empty());
    }
}

/// ServerHeadlessApprovalTests.refusesWhenWordsDiffer.
#[test]
fn refuses_when_words_differ() {
    for typed in [
        "copper lantern meadow orange",
        "lantern copper meadow violet",
        "copper lantern meadow",
        "copper lantern meadow violet extra",
    ] {
        let (sent, end) = run(CODE, Some(typed), None, None, Some(candidate()));
        assert_eq!(end, ApprovalEffect::refuse(Refusal::WordsDiffer), "{typed}");
        assert!(approvals(&sent).is_empty());
    }
}

/// ServerHeadlessApprovalTests.unknownCodeIsRefusedBeforeWordsAreChecked: the
/// candidate for another code is ignored.
#[test]
fn unknown_code_is_refused_before_words() {
    let (sent, end) =
        run("ZZZZ9999", Some("copper lantern meadow violet"), None, None, Some(candidate()));
    assert_eq!(end, ApprovalEffect::refuse(Refusal::NotFound));
    assert!(approvals(&sent).is_empty());
    let (_, none) = run(CODE, Some("copper lantern meadow violet"), None, None, None);
    assert_eq!(none, ApprovalEffect::refuse(Refusal::NotFound));
}

#[test]
fn a_candidate_with_no_team_is_not_found() {
    let found = Candidate { teams: vec![], ..candidate() };
    let (_, end) = run(CODE, Some("copper lantern meadow violet"), None, None, Some(found));
    assert_eq!(end, ApprovalEffect::refuse(Refusal::NotFound));
}

#[test]
fn server_words_compare_lowercased() {
    let found =
        Candidate { words: WORDS.iter().map(|word| word.to_uppercase()).collect(), ..candidate() };
    let (_, end) = run(CODE, Some("copper lantern meadow violet"), None, None, Some(found));
    assert_eq!(end, approved());
}

#[test]
fn name_and_chief() {
    let typed = Some("copper lantern meadow violet");
    let chief = Candidate { is_chief_brain: true, ..candidate() };
    let name = |sent: &[ApprovalEffect]| match approvals(sent)[0] {
        ApprovalEffect::Approve { name, place_chief, .. } => (name.clone(), *place_chief),
        _ => unreachable!(),
    };
    // A trimmed name wins; a blank one falls back to the server's.
    assert_eq!(
        name(&run(CODE, typed, Some("  lab  "), None, Some(candidate())).0),
        ("lab".into(), false)
    );
    assert_eq!(
        name(&run(CODE, typed, Some("   "), None, Some(candidate())).0),
        ("build-01".into(), false)
    );
    // No runChief follows the server's capability; an explicit one wins.
    assert_eq!(name(&run(CODE, typed, None, None, Some(chief.clone())).0).1, true);
    assert_eq!(name(&run(CODE, typed, None, Some(false), Some(chief)).0).1, false);
    assert_eq!(name(&run(CODE, typed, None, Some(true), Some(candidate())).0).1, true);
}

#[test]
fn source_refusals_pass_through() {
    let (state, _) = approval_step(
        Approval::default(),
        ApprovalEvent::Start {
            code: CODE.into(),
            words: Some("copper lantern meadow violet".into()),
            name: None,
            run_chief: None,
        },
    );
    let (_, effect) = approval_step(
        state.clone(),
        ApprovalEvent::LookupSettled { reject: Some("offline".into()) },
    );
    assert_eq!(effect, ApprovalEffect::reject(Some("offline".into())));
    let (state, _) = approval_step(state, ApprovalEvent::Candidate { found: Some(candidate()) });
    let (state, effect) = approval_step(state, ApprovalEvent::LookupSettled { reject: None });
    assert!(matches!(effect, ApprovalEffect::Approve { .. }));
    let (_, effect) =
        approval_step(state, ApprovalEvent::ApproveSettled { reject: Some("expired".into()) });
    assert_eq!(effect, ApprovalEffect::reject(Some("expired".into())));
}

#[test]
fn an_approve_settle_before_approving_is_ignored_and_ended_is_not_found() {
    let (state, effect) = approval_step(
        Approval { code: CODE.into(), ..Approval::default() },
        ApprovalEvent::ApproveSettled { reject: None },
    );
    assert_eq!(effect, ApprovalEffect::Wait);
    let (_, effect) = approval_step(state, ApprovalEvent::Ended);
    assert_eq!(effect, ApprovalEffect::refuse(Refusal::NotFound));
}

#[test]
fn words_split_on_non_letters() {
    assert_eq!(words(Some("A1b,,C")), vec!["a", "b", "c"]);
    assert!(words(None).is_empty());
}

#[test]
fn fixes_follow_the_allowlist_per_check() {
    assert_eq!(
        fixes_for("sleep.enabled"),
        vec!["pmset.ac.sleep.0", "pmset.ac.disksleep.0", "pmset.ac.womp.1"]
    );
    assert_eq!(fixes_for("restart.noAutoRestart"), vec!["pmset.autorestart.1"]);
    assert!(fixes_for("disk.full").is_empty());
    assert_eq!(
        local_fix("sleep.enabled"),
        Some(LocalFix { title_key: "server.fix.sleep", needs_admin: true })
    );
    assert_eq!(
        local_fix("restart.noAutoRestart").map(|fix| fix.title_key),
        Some("server.fix.autoRestart")
    );
    assert_eq!(local_fix("disk.full"), None);
}

#[test]
fn ledger_contents() {
    assert_eq!(ledger(None), Ledger::Fixes { fixes: vec![] });
    assert_eq!(ledger(Some("not json")), Ledger::Unknown);
    assert_eq!(ledger(Some("{}")), Ledger::Unknown);
    assert_eq!(
        ledger(Some(r#"{"version":1,"fixes":{"pmset.ac.womp.1":2,"pmset.ac.sleep.0":1}}"#)),
        Ledger::Fixes { fixes: vec!["pmset.ac.sleep.0".into(), "pmset.ac.womp.1".into()] }
    );
    assert_eq!(
        ledger(Some(r#"{"version":1,"fixes":{"pmset.future":1,"pmset.ac.sleep.0":1}}"#)),
        Ledger::Foreign
    );
}

#[test]
fn to_revert_is_everything_when_unknown() {
    let all: Vec<String> = FIXES.iter().map(|(id, _)| (*id).to_owned()).collect();
    assert_eq!(Ledger::Unknown.to_revert(), all);
    assert_eq!(Ledger::Foreign.to_revert(), all);
    assert_eq!(
        Ledger::Fixes { fixes: vec!["pmset.autorestart.1".into()] }.to_revert(),
        vec!["pmset.autorestart.1"]
    );
    assert!(Ledger::Fixes { fixes: vec![] }.to_revert().is_empty());
}

#[test]
fn ledger_edits() {
    let fix = "pmset.ac.sleep.0";
    // Record into a missing file starts one; recording again keeps the first time.
    let first = ledger_edit(None, LedgerEdit::Record, fix, 10).unwrap();
    assert_eq!(first, r#"{"version":1,"fixes":{"pmset.ac.sleep.0":10}}"#);
    let again = ledger_edit(Some(&first), LedgerEdit::Record, fix, 99).unwrap();
    assert_eq!(again, first);
    // An unreadable ledger stays as it is.
    assert_eq!(ledger_edit(Some("garbage"), LedgerEdit::Record, fix, 1), None);
    assert_eq!(ledger_edit(Some("garbage"), LedgerEdit::Clear, fix, 1), None);
    // Foreign ids are kept.
    let foreign = r#"{"version":1,"fixes":{"pmset.future":5}}"#;
    let kept = ledger_edit(Some(foreign), LedgerEdit::Record, fix, 7).unwrap();
    assert_eq!(kept, r#"{"version":1,"fixes":{"pmset.ac.sleep.0":7,"pmset.future":5}}"#);
    // Clear removes; clearing a fix it lacks or a missing file writes nothing.
    assert_eq!(
        ledger_edit(Some(&first), LedgerEdit::Clear, fix, 0).unwrap(),
        r#"{"version":1,"fixes":{}}"#
    );
    assert_eq!(ledger_edit(Some(&first), LedgerEdit::Clear, "pmset.ac.womp.1", 0), None);
    assert_eq!(ledger_edit(None, LedgerEdit::Clear, fix, 0), None);
    // Reset empties anything, an unreadable file too.
    assert_eq!(
        ledger_edit(Some("garbage"), LedgerEdit::Reset, fix, 0).unwrap(),
        r#"{"version":1,"fixes":{}}"#
    );
}

#[test]
fn wire_shapes() {
    let event: ApprovalEvent = serde_json::from_value(serde_json::json!({
        "kind": "start", "code": CODE, "words": "a b", "runChief": true
    }))
    .unwrap();
    let (_, effect) = approval_step(Approval::default(), event);
    assert_eq!(
        serde_json::to_value(effect).unwrap(),
        serde_json::json!({ "kind": "lookup", "code": CODE })
    );
    let refused = serde_json::to_value(ApprovalEffect::refuse(Refusal::WordsDiffer)).unwrap();
    assert_eq!(
        refused,
        serde_json::json!({ "kind": "finish", "refusal": "wordsDiffer", "reject": null })
    );
    assert_eq!(
        serde_json::to_value(Ledger::Unknown).unwrap(),
        serde_json::json!({ "kind": "unknown" })
    );
}
