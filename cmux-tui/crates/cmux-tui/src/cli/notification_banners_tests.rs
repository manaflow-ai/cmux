use super::*;

fn words(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn banners_and_open_parse_to_their_app_methods() {
    assert_eq!(parse("banners", &[]), Ok(Plan::Banners));
    assert_eq!(request(&Plan::Banners), (BANNERS_METHOD, json!({})));
    let open = parse("open", &words(&["turn-1"])).unwrap();
    assert_eq!(open, Plan::Open("turn-1".into()));
    assert_eq!(request(&open), (OPEN_METHOD, json!({"id": "turn-1"})));
}

#[test]
fn a_word_too_many_or_a_missing_id_is_a_usage_error() {
    assert!(parse("banners", &words(&["extra"])).unwrap_err().contains("extra"));
    assert!(parse("open", &[]).is_err());
    assert!(parse("open", &words(&["a", "b"])).is_err());
    assert!(parse("open", &words(&["--surface"])).is_err());
}

#[test]
fn other_notification_verbs_stay_with_the_daemon_grammar() {
    for verb in ["list", "create", "clear", "ack"] {
        assert_eq!(run_if_requested(&words(&["notification", verb])), None, "{verb}");
    }
    assert_eq!(run_if_requested(&words(&["notification", "banners", "--help"])), None);
}
