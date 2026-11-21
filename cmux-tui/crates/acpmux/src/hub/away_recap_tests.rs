use super::*;

#[test]
fn a_recap_is_trimmed_and_capped_and_an_empty_one_is_none() {
    assert_eq!(clean("  Goal: x. Next: y.\n"), Some("Goal: x. Next: y.".to_owned()));
    assert_eq!(clean(" \n "), None);
    let long = "word ".repeat(200);
    let capped = clean(&long).unwrap();
    assert!(capped.ends_with('…'));
    assert!(capped.chars().count() <= MAX_CHARS + 1);
}

#[test]
fn an_older_settings_file_keeps_the_recap_on() {
    let old: crate::chats::ChatSettings =
        serde_json::from_str(r#"{"enabled": true, "discovery": false, "roots": []}"#).unwrap();
    assert!(old.session_recap);
    let off = crate::chats::ChatSettings::from_params(&json!({"sessionRecap": false})).unwrap();
    assert!(!off.session_recap);
    assert!(crate::chats::ChatSettings::from_params(&json!({})).unwrap().session_recap);
}

#[test]
fn the_same_facts_in_other_words_are_nothing_new() {
    let first = facts(
        "The Chief CSS batch is merged (cmux#34338, #34349, leo-workspace#2996). The leo1024rd \
         resume can't start because `/tmp/cx-lanes/leo1024rd` doesn't exist on this VM.",
    );
    assert_eq!(first, ["#2996", "#34338", "#34349", "/tmp/cx-lanes/leo1024rd", "leo1024rd"]);
    let kept =
        crate::store::AwayRecap { digest: digest_of(&first), facts: first, ..Default::default() };
    let again = facts(
        "Chief CSS batch 8 is landed: cmux#34338 and #34349 are merged; leo1024rd isn't here.",
    );
    assert!(nothing_new(Some(&kept), &again), "{again:?}");
    let news = facts("Restored leo1024rd; #41622 is open, see notes.md.");
    assert!(news.contains(&"notes.md".to_owned()), "{news:?}");
    assert!(!nothing_new(Some(&kept), &news));
    assert!(!nothing_new(None, &again), "the first recap is always new");
}

#[test]
fn a_recap_with_no_named_fact_is_its_words() {
    let a = facts("Goal: tidy the parser. Next: write the tests.");
    assert_eq!(a.len(), 1);
    assert!(a[0].starts_with("text:"));
    assert_eq!(a, facts("goal:  tidy the parser -- next: write the tests"));
    assert_ne!(a, facts("Goal: tidy the lexer. Next: write the tests."));
    assert_eq!(digest_of(&a), digest_of(&a.clone()), "stable");
}
