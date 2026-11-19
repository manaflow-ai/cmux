use super::*;

const PROJECT: &str = "prod-project";
const DEV: &str = "com.cmuxterm.app.debug.feature1";

fn client(bundle_id: &str) -> ClientFacts {
    ClientFacts {
        bundle_id: Some(bundle_id.to_owned()),
        is_production_auth: true,
        ..ClientFacts::default()
    }
}

fn facts(identifier: &str, team: Option<&str>) -> RequestFacts {
    RequestFacts {
        peer_uid_matches: true,
        signer: Some(Signer {
            identifier: identifier.to_owned(),
            team_id: team.map(str::to_owned),
            path: Some("/Users/me/builds/cmux DEV feature1.app".to_owned()),
        }),
        params: RequestParams {
            bundle_id: Some(identifier.to_owned()),
            tag: Some("feature1".to_owned()),
            stack_project_id: Some(PROJECT.to_owned()),
            api_origin: Some("https://cloud-api.cmux.dev".to_owned()),
        },
        nightly: NightlyFacts {
            stack_project_id: PROJECT.to_owned(),
            api_origin: "https://cloud-api.cmux.dev".to_owned(),
            signed_in: true,
            account_email: Some("person@example.com".to_owned()),
        },
        consent_pending: false,
    }
}

fn refusal(answer: &Answer) -> (&str, &str) {
    match answer {
        Answer::Refuse { code, message } => (code, message),
        Answer::AskConsent { title, .. } => panic!("asked consent: {title}"),
    }
}

#[test]
fn the_client_waits_out_the_consent_and_the_mint() {
    assert!(CLIENT_TIMEOUT > CONSENT_TIMEOUT);
    assert_eq!(CONSENT_TIMEOUT.as_secs(), 120);
    assert_eq!(CLIENT_TIMEOUT.as_secs(), 150);
}

#[test]
fn cmux_apps_are_the_main_apps_only() {
    for id in [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.nightly.cmux-next",
        "com.cmuxterm.app.debug",
        "com.cmuxterm.app.debug.next",
        "com.cmuxterm.app.debug.tag2.part",
        "com.cmuxterm.app.staging.x1",
    ] {
        assert!(is_cmux_app(id), "{id}");
    }
    for id in [
        "cmux",
        "cmux-app-host",
        "com.cmuxterm.cua",
        "com.cmuxterm.app.computer-use",
        "com.cmuxterm.app.debug.",
        "com.cmuxterm.app.debug.My",
        "com.cmuxterm.app.debug.my-tag",
        "com.cmuxterm.app.debug.cua",
        "com.cmuxterm.app.debugx",
        "com.example.app",
    ] {
        assert!(!is_cmux_app(id), "{id}");
    }
}

#[test]
fn a_signed_out_production_dev_build_asks() {
    assert!(client_asks(&client(DEV)));
    assert!(client_asks(&client("com.cmuxterm.app")));
}

#[test]
fn every_other_launch_does_not_ask() {
    type Change = fn(&mut ClientFacts);
    let cases: [(&str, Change); 9] = [
        ("nightly", |f| f.bundle_id = Some(NIGHTLY_BUNDLE_ID.to_owned())),
        ("not a cmux app", |f| f.bundle_id = Some("com.example.app".to_owned())),
        ("no bundle id", |f| f.bundle_id = None),
        ("dev backend", |f| f.is_production_auth = false),
        ("signed in", |f| f.signed_in = true),
        ("store unreadable", |f| f.store_read_failed = true),
        ("memory only", |f| f.memory_only = true),
        ("capture fixture", |f| f.capture_fixture = true),
        ("signed NEXT DEV", |f| f.adopts_nightly_session = true),
    ];
    for (name, change) in cases {
        let mut f = client(DEV);
        change(&mut f);
        assert!(!client_asks(&f), "{name}");
    }
    let mut auto = client(DEV);
    auto.auto_login = true;
    assert!(!client_asks(&auto));
}

#[test]
fn an_ad_hoc_same_user_dev_build_gets_a_consent_ask() {
    let answer = request_answer(&facts(DEV, None));
    let Answer::AskConsent { title, message, allow, deny, timeout_seconds, declined, recipient } =
        answer
    else {
        panic!("refused: {answer:?}");
    };
    assert_eq!(title, "Sign in cmux DEV feature1?");
    assert!(message.contains("/Users/me/builds/cmux DEV feature1.app"), "{message}");
    assert!(message.contains("ad hoc"), "{message}");
    assert!(message.contains("cloud-api.cmux.dev"), "{message}");
    assert!(message.contains("person@example.com"), "{message}");
    assert!(message.contains(DEV), "{message}");
    assert_eq!((allow.as_str(), deny.as_str()), ("Sign In", "Don't Allow"));
    assert_eq!(timeout_seconds, 120);
    assert_eq!(declined, Refusal { code: "forbidden".into(), message: "declined".into() });
    assert_eq!(recipient, Recipient { bundle_id: DEV.into(), tag: Some("feature1".into()) });
}

#[test]
fn a_team_signed_build_names_its_team() {
    let Answer::AskConsent { message, .. } = request_answer(&facts(DEV, Some(CMUX_TEAM_ID))) else {
        panic!("refused");
    };
    assert!(message.contains("Team cmux (7WLXT3NR37)"), "{message}");
    let Answer::AskConsent { message, .. } = request_answer(&facts(DEV, Some("OTHERTEAM1"))) else {
        panic!("refused");
    };
    assert!(message.contains("Team OTHERTEAM1"), "{message}");
}

#[test]
fn another_user_is_refused() {
    let mut f = facts(DEV, None);
    f.peer_uid_matches = false;
    let answer = request_answer(&f);
    let (code, message) = refusal(&answer);
    assert_eq!(code, "forbidden");
    assert!(message.contains("another user"), "{message}");
}

#[test]
fn unsigned_code_is_refused() {
    let mut f = facts(DEV, None);
    f.signer = None;
    assert_eq!(refusal(&request_answer(&f)).0, "forbidden");
    f.signer = Some(Signer::default());
    assert_eq!(refusal(&request_answer(&f)).0, "forbidden");
}

#[test]
fn a_signature_other_than_the_asked_bundle_is_refused() {
    let mut f = facts(DEV, None);
    f.params.bundle_id = Some("com.cmuxterm.app.debug.other".to_owned());
    let answer = request_answer(&f);
    let (code, message) = refusal(&answer);
    assert_eq!(code, "forbidden");
    assert!(message.contains(DEV) && message.contains("com.cmuxterm.app.debug.other"), "{message}");
}

#[test]
fn a_helper_or_nightly_itself_is_refused() {
    for id in ["com.cmuxterm.cua", "cmux", "com.example.app", NIGHTLY_BUNDLE_ID] {
        assert_eq!(refusal(&request_answer(&facts(id, Some(CMUX_TEAM_ID)))).0, "forbidden", "{id}");
    }
}

#[test]
fn a_bad_tag_is_refused() {
    let mut f = facts(DEV, None);
    f.params.tag = Some("evil\ntag?".to_owned());
    assert_eq!(refusal(&request_answer(&f)).0, "invalid_params");
    f.params.tag = Some("x".repeat(MAX_TAG_LEN + 1));
    assert_eq!(refusal(&request_answer(&f)).0, "invalid_params");
    // No tag: the bundle id's suffix names it.
    f.params.tag = None;
    let Answer::AskConsent { title, recipient, .. } = request_answer(&f) else { panic!("refused") };
    assert_eq!(title, "Sign in cmux DEV feature1?");
    assert_eq!(recipient.tag, None);
}

#[test]
fn another_backend_is_refused_naming_both() {
    let mut f = facts(DEV, None);
    f.params.stack_project_id = Some("dev-project".to_owned());
    f.params.api_origin = Some("https://cmux-api-development.debussy.workers.dev/".to_owned());
    let answer = request_answer(&f);
    let (code, message) = refusal(&answer);
    assert_eq!(code, "backend_mismatch");
    for part in
        ["cloud-api.cmux.dev", PROJECT, "cmux-api-development.debussy.workers.dev", "dev-project"]
    {
        assert!(message.contains(part), "{part}: {message}");
    }
    f.params.stack_project_id = None;
    assert_eq!(refusal(&request_answer(&f)).0, "backend_mismatch");
}

#[test]
fn a_signed_out_nightly_is_not_found() {
    let mut f = facts(DEV, None);
    f.nightly.signed_in = false;
    assert_eq!(refusal(&request_answer(&f)), ("not_found", "cmux NIGHTLY is not signed in"));
}

#[test]
fn one_alert_at_a_time() {
    let mut f = facts(DEV, None);
    f.consent_pending = true;
    assert_eq!(refusal(&request_answer(&f)).0, "busy");
}

#[test]
fn labels_are_one_bounded_line() {
    let mut f = facts(DEV, None);
    f.signer.as_mut().unwrap().path = Some(format!("/tmp/a\nb{}", "p".repeat(500)));
    let Answer::AskConsent { message, .. } = request_answer(&f) else { panic!("refused") };
    assert!(message.contains("/tmp/ab"));
    assert!(!message.contains(&"p".repeat(MAX_LABEL_LEN)));
}

#[test]
fn app_names_follow_the_channel() {
    assert_eq!(app_name("com.cmuxterm.app", None), "cmux");
    assert_eq!(app_name("com.cmuxterm.app.rc", None), "cmux RC");
    assert_eq!(app_name("com.cmuxterm.app.debug", None), "cmux DEV");
    assert_eq!(app_name("com.cmuxterm.app.debug.next", None), "cmux DEV next");
    assert_eq!(app_name("com.cmuxterm.app.staging.x1", Some("my-tag")), "cmux STAGING my-tag");
    assert_eq!(app_name("com.cmuxterm.app.nightly.cmux-next", Some("x")), "cmux NEXT NIGHTLY");
}

#[test]
fn the_mint_posts_the_recipient_to_the_web_route() {
    let request = mint_request(
        "https://cmux.com/",
        &Recipient { bundle_id: DEV.into(), tag: Some("feature1".into()) },
    );
    assert_eq!(request.url, "https://cmux.com/api/auth/session-handoff");
    assert_eq!(request.method, "POST");
    assert_eq!(
        request.body,
        serde_json::json!({"recipient": {"bundleId": DEV, "tag": "feature1"}})
    );
    let untagged =
        mint_request("https://cmux.com", &Recipient { bundle_id: DEV.into(), tag: None });
    assert_eq!(untagged.body, serde_json::json!({"recipient": {"bundleId": DEV, "tag": null}}));
}

#[test]
fn the_mint_answer_becomes_the_socket_result() {
    let body = br#"{"accessToken":"a-secret","refreshToken":"r-secret","expiresAt":"2026-11-26T00:00:00.000Z"}"#;
    assert_eq!(
        mint_answer(200, body),
        MintAnswer::Result(serde_json::json!({
            "access_token": "a-secret", "refresh_token": "r-secret", "expires_at": "2026-11-26T00:00:00.000Z"
        }))
    );
}

#[test]
fn a_failed_mint_never_echoes_the_body() {
    let secret = br#"{"accessToken":"a-secret","refreshToken":""}"#;
    for (status, body, code) in [
        (200, &secret[..], "mint_failed"),
        (200, &b"not json"[..], "mint_failed"),
        (401, &secret[..], "unauthorized"),
        (500, &secret[..], "mint_failed"),
        (0, &b""[..], "mint_failed"),
    ] {
        let MintAnswer::Refusal(refusal) = mint_answer(status, body) else {
            panic!("{status} gave a result");
        };
        assert_eq!(refusal.code, code, "{status}");
        assert!(!refusal.message.contains("secret"), "{}", refusal.message);
    }
}

#[test]
fn answers_serialize_as_the_ffi_sends_them() {
    let refused = serde_json::to_value(Answer::from(declined())).unwrap();
    assert_eq!(
        refused,
        serde_json::json!({"kind": "refuse", "code": "forbidden", "message": "declined"})
    );
    let asked = serde_json::to_value(request_answer(&facts(DEV, None))).unwrap();
    assert_eq!(asked["kind"], "askConsent");
    assert_eq!(asked["timeoutSeconds"], 120);
    assert_eq!(asked["recipient"]["bundleId"], DEV);
    assert_eq!(asked["declined"]["code"], "forbidden");
}
