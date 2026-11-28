use super::*;

fn w(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_every_place_and_refuses_the_rest() {
    for on in ["local", "cloud", "auto", "AutoCloud", "here"] {
        let parsed = parse(&w(&format!("s-1 --on {on}"))).unwrap();
        assert_eq!(parsed, Parsed::Run { session: "s-1".into(), on: on.into(), reason: None });
    }
    assert!(parse(&w("s-1 --on mars")).is_err());
    assert!(parse(&w("s-1")).is_err());
    assert!(parse(&w("--on cloud")).is_err());
    assert_eq!(parse(&w("--help")).unwrap(), Parsed::Help);
    assert_eq!(
        parse(&w("s-1 --to cloud --reason why")).unwrap(),
        Parsed::Run { session: "s-1".into(), on: "cloud".into(), reason: Some("why".into()) }
    );
}
