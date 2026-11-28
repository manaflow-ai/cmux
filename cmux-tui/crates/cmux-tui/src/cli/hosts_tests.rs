use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn verbs_parse() {
    assert_eq!(parse(&[]), Ok(Request::List));
    assert_eq!(parse(&words("list --json")), Ok(Request::List));
    assert_eq!(
        parse(&words("check studio --timeout 1.5 --json")),
        Ok(Request::Check { labels: vec!["studio".into()], timeout: Duration::from_millis(1500) })
    );
    assert_eq!(
        parse(&words("check")),
        Ok(Request::Check { labels: vec![], timeout: DEFAULT_TIMEOUT })
    );
    assert!(parse(&words("check --timeout 99")).is_err());
    assert!(parse(&words("check --bogus")).is_err());
    assert!(parse(&words("frobnicate")).is_err());
    assert_eq!(parse(&words("check --help")), Ok(Request::Help));
    assert_eq!(parse(&words("--help")), Ok(Request::Help));
    assert_eq!(parse(&words("rename --help")), Ok(Request::Help));
    assert_eq!(
        parse(&words("remove studio --json")),
        Ok(Request::Edit(HostEdit::Remove { label: "studio".into() }))
    );
}
