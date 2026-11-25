use super::*;

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

fn all() -> Vec<String> {
    SCOPES.map(str::to_owned).to_vec()
}

#[test]
fn create_defaults_to_every_scope_and_ninety_days() {
    let command = parse(&words("create ci")).unwrap();
    assert_eq!(
        command.verb,
        Verb::Create {
            name: "ci".into(),
            scopes: all(),
            expires: Expiry::Days(90),
            spend_cap: None,
            team_token: false
        }
    );
    let call = call_for(&command.verb, None).unwrap();
    assert_eq!((call.method, call.path.as_str()), ("POST", "/v1/tokens"));
    assert_eq!(
        call.body.unwrap(),
        json!({"name": "ci", "scopes": ["machines", "chats", "usage"], "expiresInDays": 90})
    );
}

#[test]
fn create_takes_scopes_expiry_spend_cap_team_and_team_token() {
    let command = parse(&words(
        "create deploy --scope usage,machines --expires=1y --spend-cap $25 --team team_0123 --team-token",
    ))
    .unwrap();
    assert_eq!(command.team.as_deref(), Some("team_0123"));
    let body = call_for(&command.verb, None).unwrap().body.unwrap();
    assert_eq!(
        body,
        json!({"name": "deploy", "scopes": ["machines", "usage"], "expiresInDays": 365, "spendCapUsd": 25.0, "owner": "team"})
    );
    let never = parse(&words("create forever --expires never")).unwrap();
    let body = call_for(&never.verb, None).unwrap().body.unwrap();
    assert_eq!(body["expiresInDays"], Value::Null);
    assert!(body.as_object().unwrap().contains_key("expiresInDays"), "null, not omitted");
}

#[test]
fn bad_create_arguments_are_usage_errors() {
    for line in [
        "create",
        "create a b",
        "create ci --scope vault",
        "create ci --scope ''",
        "create ci --expires 2y",
        "create ci --expires 400d",
        "create ci --expires soon",
        "create ci --spend-cap 0",
        "create ci --spend-cap -5",
        "create ci --ref main",
        "create ci --team a/b",
        "create ci --expires",
        "list extra",
        "list --scope usage",
        "frobnicate",
    ] {
        assert!(parse(&words(line)).is_err(), "{line}");
    }
    let long = "x".repeat(65);
    assert!(parse(&[String::from("create"), long]).is_err());
}

#[test]
fn expiry_forms() {
    assert_eq!(parse_expiry("30d"), Ok(Expiry::Days(30)));
    assert_eq!(parse_expiry("90"), Ok(Expiry::Days(90)));
    assert_eq!(parse_expiry("2w"), Ok(Expiry::Days(14)));
    assert_eq!(parse_expiry("6m"), Ok(Expiry::Days(180)));
    assert_eq!(parse_expiry("1Y"), Ok(Expiry::Days(365)));
    assert_eq!(parse_expiry("never"), Ok(Expiry::Never));
    assert!(parse_expiry("0d").is_err());
    assert!(parse_expiry("366").is_err());
    assert!(parse_expiry("13m").is_err());
    assert!(parse_expiry("99999999999y").is_err());
}

#[test]
fn scopes_accept_all_singulars_and_keep_one_order() {
    assert_eq!(parse_scopes("all").unwrap(), all());
    assert_eq!(parse_scopes("usage, chat,usage").unwrap(), ["chats", "usage"]);
    assert!(parse_scopes("machines,secrets").is_err());
    assert!(parse_scopes(" , ").is_err());
}

#[test]
fn list_revoke_uses_and_help() {
    assert_eq!(parse(&words("ls")).unwrap().verb, Verb::List);
    assert_eq!(call_for(&Verb::List, None).unwrap(), Call::get("/v1/tokens"));
    let revoke = parse(&words("revoke ci")).unwrap().verb;
    assert_eq!(revoke, Verb::Revoke { target: "ci".into() });
    assert_eq!(call_for(&revoke, Some("tok_1")).unwrap(), Call::delete("/v1/tokens/tok_1"));
    let uses = parse(&words("uses ci")).unwrap().verb;
    assert_eq!(call_for(&uses, Some("tok 1")).unwrap().path, "/v1/tokens/tok%201/uses");
    assert_eq!(parse(&[]).unwrap().verb, Verb::Help);
    assert_eq!(parse(&words("create ci --help")).unwrap().verb, Verb::Help);
    assert_eq!(parse(&words("github")).unwrap().verb, Verb::Help);
    assert!(call_for(&Verb::Help, None).is_none());
}

#[test]
fn github_rules() {
    let allow =
        parse(&words("github allow acme/web --ref main --environment prod --scope machines"))
            .unwrap();
    let call = call_for(&allow.verb, None).unwrap();
    assert_eq!((call.method, call.path.as_str()), ("POST", "/v1/tokens/github"));
    assert_eq!(
        call.body.unwrap(),
        json!({"repository": "acme/web", "ref": "refs/heads/main", "environment": "prod", "scopes": ["machines"]})
    );
    let star = parse(&words("github allow acme/web --ref refs/heads/release/*")).unwrap();
    assert_eq!(call_for(&star.verb, None).unwrap().body.unwrap()["ref"], "refs/heads/release/*");
    assert_eq!(call_for(&Verb::GithubList, None).unwrap(), Call::get("/v1/tokens/github"));
    let remove = parse(&words("github rm ghr_1")).unwrap().verb;
    assert_eq!(call_for(&remove, None).unwrap(), Call::delete("/v1/tokens/github/ghr_1"));
    assert!(parse(&words("github allow acme")).is_err());
    assert!(parse(&words("github allow acme/web/x")).is_err());
    assert!(parse(&words("github allow acme/web --expires 30d")).is_err());
}

#[test]
fn revoke_resolves_an_id_or_one_name() {
    let list = json!({"tokens": [
        {"id": "tok_a", "name": "ci"},
        {"id": "tok_b", "name": "laptop"},
        {"id": "tok_c", "name": "laptop"},
    ]});
    assert_eq!(resolve_target(&list, "tok_b").unwrap(), "tok_b");
    assert_eq!(resolve_target(&list, "ci").unwrap(), "tok_a");
    assert!(resolve_target(&list, "laptop").unwrap_err().contains("tok_b, tok_c"));
    assert!(resolve_target(&list, "nope").is_err());
}

#[test]
fn management_signs_in_as_the_person_never_with_an_api_token() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    };
    assert_eq!(signer(&env(&[("CMUX_CLOUD_ACCESS_TOKEN", " eyJ.person ")])), Signer::Env);
    assert_eq!(signer(&env(&[("CMUX_TOKEN", "cmux_pat_x")])), Signer::App);
    assert_eq!(signer(&env(&[("CMUX_CLOUD_ACCESS_TOKEN", "cmux_pat_x")])), Signer::App);
    assert_eq!(signer(&env(&[])), Signer::App);
}

#[test]
fn env_credential_takes_the_access_token_then_cmux_token() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    };
    assert_eq!(
        env_credential(env(&[("CMUX_TOKEN", " cmux_pat_abc\n")])).as_deref(),
        Some("cmux_pat_abc")
    );
    assert_eq!(
        env_credential(env(&[("CMUX_TOKEN", "cmux_pat_abc"), ("CMUX_CLOUD_ACCESS_TOKEN", "eyJ")]))
            .as_deref(),
        Some("eyJ")
    );
    assert_eq!(
        env_credential(env(&[("CMUX_TOKEN", "cmux_pat_abc"), ("CMUX_CLOUD_ACCESS_TOKEN", " ")]))
            .as_deref(),
        Some("cmux_pat_abc")
    );
    assert_eq!(env_credential(env(&[])), None);
}

#[test]
fn refusals_read_plainly() {
    let scope = refusal(403, &json!({"error": {"code": "token.scope", "message": "needs chats"}}));
    assert_eq!(scope.code, "token.scope");
    assert!(scope.message.contains("scopes") && scope.message.contains("needs chats"));
    let missing = refusal(404, &Value::Null);
    assert!(missing.message.contains("aren't available"));
    let busy = refusal(503, &json!({"code": "overloaded"}));
    assert!(busy.retryable && busy.message.contains("503 overloaded"));
    let pat = refusal(401, &json!({"error": {"code": "token.invalid"}}));
    assert!(pat.message.contains("your own sign-in"));
}

#[test]
fn create_prints_the_token_alone_on_stdout() {
    let verb = parse(&words("create ci --expires never")).unwrap().verb;
    let answer =
        json!({"token": "cmux_pat_ABC", "tokenInfo": {"scopes": ["machines"], "expiresAt": null}});
    let (out, note) = human(&verb, &answer);
    assert_eq!(out, "cmux_pat_ABC\n");
    assert!(note.contains("not shown again"));
    assert!(note.contains("export CMUX_TOKEN=cmux_pat_ABC"));
    assert!(note.contains("never expires"));
    let list = human(
        &Verb::List,
        &json!({"tokens": [{"id": "tok_a", "name": "ci", "display": "cmux_pat_AbCd…wXyZ", "scopes": ["usage"], "owner": "me", "expiresAt": "2027-02-23T00:00:00Z", "lastUsedAt": null}]}),
    )
    .0;
    assert!(list.starts_with("ID"));
    assert!(
        list.contains("cmux_pat_AbCd…wXyZ") && list.contains("2027-02-23") && list.contains("you")
    );
}

#[test]
fn the_settings_forms_parse_like_the_short_ones() {
    let long = parse(&words(
        "create --name=deploy --scope=machines --scope=usage --expires-days=30 --spend-cap=12.5 --owner=team --team=team_0123",
    ))
    .unwrap();
    assert_eq!(
        long.verb,
        Verb::Create {
            name: "deploy".into(),
            scopes: vec!["machines".into(), "usage".into()],
            expires: Expiry::Days(30),
            spend_cap: Some(12.5),
            team_token: true
        }
    );
    assert_eq!(long.team.as_deref(), Some("team_0123"));
    let never = parse(&words("create --name=n --expires-days=never --owner=me")).unwrap();
    assert!(matches!(never.verb, Verb::Create { expires: Expiry::Never, team_token: false, .. }));
    assert!(parse(&words("create --name=n --owner=them")).is_err());
    let allow = parse(&words(
        "github allow --repository=acme/web --ref=refs/heads/main --environment=prod --scope=chats",
    ))
    .unwrap();
    assert_eq!(
        call_for(&allow.verb, None).unwrap().body.unwrap(),
        json!({"repository": "acme/web", "ref": "refs/heads/main", "environment": "prod", "scopes": ["chats"]})
    );
    let file = parse(&words("list --token-file=/tmp/t")).unwrap();
    assert_eq!(file.token, Some(TokenSource::File("/tmp/t".into())));
}

#[test]
fn management_resolves_its_credential_as_hub_does() {
    let none = |_: &str| None;
    let person = |k: &str| (k == "CMUX_CLOUD_ACCESS_TOKEN").then(|| "eyJ".to_owned());
    let pat = |k: &str| (k == "CMUX_CLOUD_ACCESS_TOKEN").then(|| "cmux_pat_x".to_owned());
    let list = parse(&words("list")).unwrap();
    assert_eq!(token_source(&list, &none), TokenSource::App);
    assert_eq!(token_source(&list, &person), TokenSource::Env);
    assert_eq!(token_source(&list, &pat), TokenSource::App);
    let command = parse(&words("list --token-command=cmux-auth")).unwrap();
    assert_eq!(token_source(&command, &person), TokenSource::Command("cmux-auth".into()));
}

#[test]
fn json_answers_are_one_object_with_ok() {
    let answer = |body: Value| Answer { body, platform: "https://p.test".into() };
    let list = json_answer(
        &Verb::List,
        &answer(json!({"tokens": [{"id": "tok_a"}], "canManageTeamTokens": true})),
        Some("team_1"),
    );
    assert_eq!(
        list,
        json!({"ok": true, "platform": "https://p.test", "team": "team_1", "tokens": [{"id": "tok_a"}], "canManageTeamTokens": true})
    );
    let bare = json_answer(&Verb::List, &answer(json!({})), None);
    assert_eq!(bare["tokens"], json!([]));
    assert!(bare.get("team").is_none());
    let create = parse(&words("create ci")).unwrap().verb;
    assert_eq!(
        json_answer(
            &create,
            &answer(json!({"token": "cmux_pat_x", "tokenInfo": {"id": "t"}})),
            None
        ),
        json!({"ok": true, "token": "cmux_pat_x", "tokenInfo": {"id": "t"}})
    );
    let allow = parse(&words("github allow acme/web")).unwrap().verb;
    assert_eq!(
        json_answer(&allow, &answer(json!({"id": "ghr_1"})), None),
        json!({"ok": true, "rule": {"id": "ghr_1"}})
    );
    assert_eq!(
        json_answer(&Verb::GithubRemove { id: "g".into() }, &answer(Value::Null), None),
        json!({"ok": true})
    );
    let failure = refusal(403, &json!({"error": {"code": "token.scope", "message": "no"}})).json();
    assert_eq!(failure["ok"], json!(false));
    assert_eq!(failure["error"]["code"], json!("token.scope"));
}
