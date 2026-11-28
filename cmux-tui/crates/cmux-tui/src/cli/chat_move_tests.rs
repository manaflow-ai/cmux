use super::*;

fn w(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_every_place_and_refuses_the_rest() {
    for on in ["local", "cloud", "auto", "AutoCloud", "here"] {
        let parsed = parse_in(&w(&format!("s-1 --on {on}")), None).unwrap();
        assert_eq!(parsed, Parsed::Run { session: "s-1".into(), on: on.into(), reason: None });
    }
    assert!(parse_in(&w("s-1 --on mars"), None).is_err());
    assert!(parse_in(&w("s-1"), None).is_err());
    assert!(parse_in(&w("--on cloud"), None).is_err());
    assert_eq!(parse_in(&w("--help"), None).unwrap(), Parsed::Help);
    assert_eq!(
        parse_in(&w("s-1 --to cloud --reason why"), None).unwrap(),
        Parsed::Run { session: "s-1".into(), on: "cloud".into(), reason: Some("why".into()) }
    );
}

#[test]
fn an_agents_shell_moves_its_own_chat_with_no_session() {
    let own = || Some("@".to_owned());
    assert_eq!(
        parse_in(&w("--on auto"), own()).unwrap(),
        Parsed::Run { session: "@".into(), on: "auto".into(), reason: None }
    );
    // A named chat is that chat, in a chat too.
    assert_eq!(
        parse_in(&w("s-2 --on local"), own()).unwrap(),
        Parsed::Run { session: "s-2".into(), on: "local".into(), reason: None }
    );
    assert!(parse_in(&w("--on cloud"), None).is_err(), "outside a chat SESSION is required");
}
