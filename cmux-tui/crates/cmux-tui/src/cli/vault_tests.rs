use super::*;

/// The vault transport sends the cmux token only as the bearer and the team only as `x-cmux-team`; a call's
/// body (sealed by the vault client before it gets here) goes as given and carries neither.
#[test]
fn seeded_token_and_team_ride_only_in_their_headers() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let bearer = "SEEDvaultBearer-1f8d";
    let team = "SEEDvaultTeam-a6c3";
    let http = Transport::new(
        cmux_cloud_environment::PRODUCTION_API.to_owned(),
        Zeroizing::new(bearer.to_owned()),
        Some(team.to_owned()),
    )
    .unwrap();
    let _ = http.send("POST", "/v1/vault/seeded", &[], Some(&json!({"sealed": "b64"})));
    let sent = cmux_egress::capture::requests_to("cloud-api.cmux.dev");
    assert!(sent.iter().any(|r| r.target == "/v1/vault/seeded"), "{sent:?}");
    for (secret, place) in [(bearer, ": header authorization"), (team, ": header x-cmux-team")] {
        let places = cmux_egress::capture::leaks(secret);
        assert!(!places.is_empty(), "{secret}: {sent:?}");
        assert!(places.iter().all(|p| p.ends_with(place)), "{secret}: {places:?}");
    }
}

fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_every_verb() {
    assert_eq!(parse(&words("status")).unwrap().0, Verb::Status);
    assert_eq!(parse(&words("approve 1234 5678")).unwrap().0, Verb::Approve("1234 5678".into()));
    assert!(parse(&words("approve 123")).is_err());
    assert_eq!(
        parse(&words("set OPENAI_API_KEY --repo Manaflow-AI/cmux")).unwrap().0,
        Verb::Set { name: "OPENAI_API_KEY".into(), scope: Scope::Repo("manaflow-ai/cmux".into()) }
    );
    assert!(parse(&words("set PATH")).is_err());
    assert!(parse(&words("set A --repo a/b --machine vm_abcdefghij0123456789")).is_err());
    assert_eq!(
        parse(&words("import .env --only A,B")).unwrap().0,
        Verb::Import {
            file: ".env".into(),
            only: Some(vec!["A".into(), "B".into()]),
            all: false,
            scope: Scope::All
        }
    );
    let (verb, opts) = parse(&words("ls --team team_abc")).unwrap();
    assert_eq!((verb, opts.team.as_deref()), (Verb::Ls, Some("team_abc")));
    assert!(parse(&words("ls --team nope")).is_err());
    assert_eq!(parse(&[]).unwrap().0, Verb::Help);
}
