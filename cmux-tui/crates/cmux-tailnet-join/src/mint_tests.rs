use super::*;

fn s(text: &str) -> Secret {
    Secret::new(text)
}

#[test]
fn client_id_is_the_third_part() {
    assert_eq!(oauth_client_id(&s("tskey-client-kAbc123CNTRL-SeCrEt")).unwrap(), "kAbc123CNTRL");
    assert!(oauth_client_id(&s("tskey-auth-k-x")).is_err());
    assert!(oauth_client_id(&s("tskey-client-")).is_err());
}

#[test]
fn token_call_sends_the_secret_only_in_the_form() {
    let call = tailscale_token_call(&s("tskey-client-kID-SECRETPART")).unwrap();
    assert_eq!(call.url, "https://api.tailscale.com/api/v2/oauth/token");
    assert!(call.bearer.is_none());
    let fields: Vec<(&str, &str)> = call.form.iter().map(|(k, v)| (*k, v.expose())).collect();
    assert_eq!(
        fields,
        [
            ("client_id", "kID"),
            ("client_secret", "tskey-client-kID-SECRETPART"),
            ("grant_type", "client_credentials")
        ]
    );
    assert!(!format!("{call:?}").contains("SECRETPART"), "Debug redacts");
}

#[test]
fn tailscale_key_is_single_use_preauthorized_and_short() {
    let spec = MintSpec { ephemeral: true, tags: vec!["tag:cmux".into()] };
    let call = tailscale_key_call(&s("tok"), &spec);
    assert_eq!(call.url, "https://api.tailscale.com/api/v2/tailnet/-/keys");
    let body = call.json.unwrap();
    let create = &body["capabilities"]["devices"]["create"];
    assert_eq!(create["reusable"], false);
    assert_eq!(create["preauthorized"], true);
    assert_eq!(create["ephemeral"], true);
    assert_eq!(create["tags"], json!(["tag:cmux"]));
    assert_eq!(body["expirySeconds"], 600);
}

#[test]
fn answers_parse_and_tolerate_unknown_fields() {
    assert_eq!(
        parse_token(r#"{"access_token":"tok","token_type":"Bearer","expires_in":3600,"new":1}"#)
            .unwrap()
            .expose(),
        "tok"
    );
    assert_eq!(
        parse_tailscale_key(r#"{"id":"k1","key":"tskey-auth-k1-abc","created":"x","extra":{}}"#)
            .unwrap()
            .expose(),
        "tskey-auth-k1-abc"
    );
    assert!(parse_tailscale_key(r#"{"key":"tskey-client-x"}"#).is_err());
    assert_eq!(
        parse_headscale_key(
            r#"{"preAuthKey":{"user":{"id":"1"},"id":"3","key":"hskey","used":false,"later":true}}"#
        )
        .unwrap()
        .expose(),
        "hskey"
    );
    assert!(parse_headscale_key(r#"{"preAuthKey":{}}"#).is_err());
    assert!(parse_token("<html>").is_err());
}

#[test]
fn headscale_call_expires_ten_minutes_out() {
    let spec = MintSpec { ephemeral: false, tags: vec![] };
    let call = headscale_key_call("http://127.0.0.1:8080/", &s("hsapi"), "1", &spec, 1_764_108_000);
    assert_eq!(call.url, "http://127.0.0.1:8080/api/v1/preauthkey");
    assert_eq!(call.bearer.as_ref().unwrap().expose(), "hsapi");
    let body = call.json.unwrap();
    assert_eq!(body["user"], "1");
    assert_eq!(body["reusable"], false);
    assert_eq!(body["ephemeral"], false);
    assert_eq!(body["expiration"], "2025-11-25T22:10:00Z");
}

#[test]
fn rfc3339_known_points() {
    assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
    assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
    assert_eq!(rfc3339(1_798_761_599), "2026-12-31T23:59:59Z");
}

#[test]
fn sources_are_checked_before_any_call() {
    let ts = MintSource::TailscaleOauth { client_secret: s("tskey-client-kID-x") };
    assert!(check_source(&ts, &MintSpec::default(), false).is_err(), "Tailscale needs tags");
    let spec =
        check_source(&ts, &MintSpec { ephemeral: true, tags: vec!["cmux".into()] }, false).unwrap();
    assert_eq!(spec.tags, ["tag:cmux"]);
    let hs = |server: &str, user: &str| MintSource::Headscale {
        server: server.into(),
        api_key: s("k"),
        user: user.into(),
    };
    assert!(check_source(&hs("http://h:8080", "1"), &MintSpec::default(), false).is_err());
    assert!(check_source(&hs("http://h:8080", "1"), &MintSpec::default(), true).is_ok());
    assert!(check_source(&hs("https://h", "cmux"), &MintSpec::default(), false).is_err());
}

#[test]
fn source_serde_is_redacted_and_round_trips_from_old_and_new() {
    let hs =
        MintSource::Headscale { server: "https://h".into(), api_key: s("KEY"), user: "1".into() };
    let out = serde_json::to_string(&hs).unwrap();
    assert!(!out.contains("KEY"));
    let read: MintSource = serde_json::from_str(
        r#"{"kind":"headscale","server":"https://h","api_key":"KEY","user":"1","future":"x"}"#,
    )
    .unwrap();
    assert_eq!(read, hs);
    let spec: MintSpec = serde_json::from_str("{}").unwrap();
    assert_eq!(spec, MintSpec::default());
}
