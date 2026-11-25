use super::*;

#[test]
fn api_compat_pointer_round_trips_rfc6901_escapes() {
    assert_eq!(parse("").unwrap(), Vec::<String>::new());
    assert_eq!(parse("/a~1b/c~0d/*").unwrap(), vec!["a/b", "c~d", "*"]);
    assert_eq!(join(&parse("/a~1b/c~0d").unwrap()), "/a~1b/c~0d");
    assert!(parse("a").is_err());
    assert!(parse("/a~2").is_err());
}
