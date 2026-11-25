use super::parse;

fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|arg| (*arg).to_string()).collect()
}

#[test]
fn parses_plan_flags() {
    let (local, bundle, base) =
        parse(&args(&["plan", "--local", "/a", "--bundle", "/b", "--base", "abc"])).unwrap();
    assert_eq!(local.to_str(), Some("/a"));
    assert_eq!(bundle.to_str(), Some("/b"));
    assert_eq!(base.as_deref(), Some("abc"));
    assert!(parse(&args(&["plan", "--local", "/a"])).is_none());
    assert!(parse(&args(&["plan", "--local", "/a", "--bundle"])).is_none());
    assert!(parse(&args(&["push", "--local", "/a", "--bundle", "/b"])).is_none());
    assert!(parse(&args(&["plan", "--local", "/a", "--bundle", "/b", "--x", "y"])).is_none());
}
