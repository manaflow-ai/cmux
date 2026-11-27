use super::with_unread;

#[test]
fn the_continuation_quotes_each_unread_steer_once() {
    assert_eq!(with_unread("go on".into(), &[]), "go on");
    let text = with_unread("go on".into(), &["one".into(), "two".into()]);
    assert!(text.starts_with("go on\n\n"), "{text}");
    assert_eq!(text.matches("<message>\none\n</message>").count(), 1, "{text}");
    assert_eq!(text.matches("<message>\ntwo\n</message>").count(), 1, "{text}");
    assert!(text.find("one").unwrap() < text.find("two").unwrap(), "{text}");
}
