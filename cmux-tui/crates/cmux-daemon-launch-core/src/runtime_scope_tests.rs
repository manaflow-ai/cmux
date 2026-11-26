use super::*;

#[test]
fn the_account_home_has_no_scope() {
    assert_eq!(scope(Some("/Users/leo"), Some("/Users/leo")), None);
    assert_eq!(scope(Some("/Users/leo/"), Some("/Users/leo")), None);
}

#[test]
fn unknown_homes_have_no_scope() {
    assert_eq!(scope(None, Some("/Users/leo")), None);
    assert_eq!(scope(Some("/tmp/x"), None), None);
    assert_eq!(scope(Some(""), Some("/Users/leo")), None);
}

#[test]
fn another_home_has_its_own_stable_scope() {
    let a = scope(Some("/tmp/cmux-fresh-a/home"), Some("/Users/leo")).unwrap();
    let b = scope(Some("/tmp/cmux-fresh-b/home"), Some("/Users/leo")).unwrap();
    assert_ne!(a, b);
    assert_eq!(a.len(), 8);
    assert!(a.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    assert_eq!(Some(a), scope(Some("/tmp/cmux-fresh-a/home/"), Some("/Users/leo")));
}

#[test]
fn the_scope_of_an_environment_reads_its_home() {
    let mut env = Env::new();
    assert_eq!(scope_of(&env), None);
    env.insert("HOME".into(), "/nonexistent-home-for-scope-test".into());
    if account_home().is_some() {
        assert!(scope_of(&env).is_some());
    }
}
