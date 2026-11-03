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
