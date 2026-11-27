use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn approve_takes_a_role_and_defaults_to_the_daemons() {
    assert_eq!(
        parse("approve", &words(&["s1", "a@b.c", "--role", "talk"])),
        Ok(Ask::Approve { share: "s1".into(), account: "a@b.c".into(), role: Some("talk".into()) })
    );
    assert_eq!(
        parse("approve", &words(&["s1", "a@b.c"])),
        Ok(Ask::Approve { share: "s1".into(), account: "a@b.c".into(), role: None })
    );
}

#[test]
fn bad_words_are_refused_with_a_sentence() {
    assert!(parse("approve", &words(&["s1"])).is_err());
    assert!(parse("approve", &words(&["s1", "a", "--role", "owner"])).is_err());
    assert!(parse("decline", &words(&["s1", "a", "--role", "view"])).is_err());
    assert!(parse("requests", &words(&["a", "b"])).is_err());
}

#[test]
fn the_list_flattens_pending_requests_with_their_share() {
    let list = json!({"shares":[
        {"share_id":"s1","session":"x","requests":[{"account":"a@b.c","name":"Sam","state":"pending"}]},
        {"share_id":"s2","requests":[]}]});
    let rows = pending_requests(&list, None);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["share_id"], "s1");
    assert!(pending_requests(&list, Some("s2")).is_empty());
    assert!(requests_text(&rows).contains("cmux share approve s1 a@b.c"));
}

#[test]
fn a_refusal_says_what_to_do_next() {
    assert!(refusal_sentence("share.unknown", "no request").contains("cmux share requests"));
    assert_eq!(refusal_sentence("share.other", "plain"), "plain");
}

#[test]
fn help_lists_every_access_request_command() {
    assert!(HELP.contains("cmux share requests [SHARE_ID]"));
    assert!(HELP.contains("cmux share approve SHARE_ID ACCOUNT [--role view|talk]"));
    assert!(HELP.contains("cmux share decline SHARE_ID ACCOUNT"));
}
