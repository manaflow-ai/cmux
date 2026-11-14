use super::*;

fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}
fn no_env(_: &str) -> Option<String> {
    None
}
fn jwt(exp: u64) -> String {
    let payload =
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!("{{\"exp\":{exp}}}"));
    format!("e30.{payload}.sig")
}

#[test]
fn splits_only_inference_gateway() {
    assert_eq!(
        split(&args(&["inference", "gateway", "--api", "x"])),
        Some(&args(&["--api", "x"])[..])
    );
    assert_eq!(split(&args(&["inference"])), None);
    assert_eq!(split(&args(&["cloud", "gateway"])), None);
}

#[test]
fn parses_a_codex_gateway_and_a_proxy_gateway() {
    let env = |k: &str| (k == "HOME").then(|| "/home/p".to_owned());
    // No proxy is picked for the person: one of the two is required, even with a ~/.codex login on the host.
    assert!(parse(&args(&["--api", "https://api.cmux.dev"]), &env).is_err());
    let o = parse(
        &args(&[
            "--api",
            "https://api.cmux.dev",
            "--team",
            "team_1",
            "--codex-auth",
            "/g/auth.json",
        ]),
        &env,
    )
    .unwrap();
    assert_eq!(o.api, "https://api.cmux.dev");
    assert_eq!(o.team.as_deref(), Some("team_1"));
    assert_eq!(o.upstream, Upstream::Codex { auth: PathBuf::from("/g/auth.json") });
    assert_eq!(o.token, TokenSource::App);
    let o = parse(
        &args(&[
            "--api=https://api.cmux.dev",
            "--upstream",
            "http://127.0.0.1:8317/",
            "--token-file",
            "/t",
        ]),
        &no_env,
    )
    .unwrap();
    assert_eq!(
        o.upstream,
        Upstream::Proxy { base: "http://127.0.0.1:8317".into(), key_file: None }
    );
    assert_eq!(o.token, TokenSource::File(PathBuf::from("/t")));
}

#[test]
fn refuses_plain_http_to_the_api_and_two_upstreams() {
    assert!(parse(&args(&["--api", "http://api.cmux.dev"]), &no_env).is_err());
    assert!(
        parse(
            &args(&["--api", "https://a.dev", "--codex-auth", "/a", "--upstream", "http://b"]),
            &no_env
        )
        .is_err()
    );
    assert!(
        parse(
            &args(&["--api", "https://a.dev", "--token-file", "/a", "--token-command", "x"]),
            &no_env
        )
        .is_err()
    );
    assert!(parse(&args(&["--codex-auth", "/a"]), &no_env).is_err());
    // A credential in the URL would be logged with it.
    assert!(
        parse(&args(&["--api", "https://a.dev", "--upstream", "https://u:secret@b.dev"]), &no_env)
            .is_err()
    );
    assert!(
        parse(&args(&["--api", "https://a.dev", "--upstream", "https://u@b.dev"]), &no_env)
            .is_err()
    );
    assert!(
        parse(
            &args(&["--api", "https://a.dev", "--upstream-key-file", "/k", "--codex-auth", "/a"]),
            &no_env
        )
        .is_err()
    );
}

#[test]
fn plain_http_stays_on_this_computer_or_a_private_network() {
    let parse_up = |up: &str, key: bool| {
        let mut a = vec!["--api", "https://a.dev", "--upstream", up];
        if key {
            a.extend(["--upstream-key-file", "/k"]);
        }
        parse(&args(&a), &no_env).map(|_| ())
    };
    assert!(parse_up("http://127.0.0.1:8317", true).is_ok());
    assert!(parse_up("http://localhost:8317/v1", true).is_ok());
    assert!(parse_up("http://100.89.225.106:31415/v1", false).is_ok());
    assert!(parse_up("http://192.168.1.4:8317", false).is_ok());
    assert!(parse_up("http://sr.tail1234.ts.net:31415", false).is_ok());
    assert!(parse_up("http://100.89.225.106:31415/v1", true).is_err());
    assert!(parse_up("http://proxy.example.com", false).is_err());
    assert!(parse_up("http://8.8.8.8", false).is_err());
    assert!(parse_up("https://proxy.example.com/v1", true).is_ok());
}

#[test]
fn logs_show_no_query_and_no_control_characters() {
    assert_eq!(log_path("/v1/responses?api_key=secret"), "/v1/responses");
    assert_eq!(log_path("/v1/models\nfake line"), "/v1/modelsfakeline");
    assert_eq!(printable("vm_abc\r\n x"), "vm_abcx");
}

#[test]
fn joins_a_proxy_base_with_or_without_v1() {
    assert_eq!(proxy_url("http://h:1", "/v1/responses").unwrap(), "http://h:1/v1/responses");
    assert_eq!(proxy_url("http://h:1/v1", "/v1/responses").unwrap(), "http://h:1/v1/responses");
    assert_eq!(
        proxy_url("http://h:1/api", "/v1/models?x=1").unwrap(),
        "http://h:1/api/v1/models?x=1"
    );
}

#[test]
fn a_proxy_serves_only_the_workers_model_paths() {
    for path in [
        "/v1/responses",
        "/v1/responses?x=1",
        "/v1/responses/compact",
        "/v1/models",
        "/v1/messages",
        "/v1/messages/count_tokens",
        "/v1/chat/completions",
    ] {
        assert!(proxy_url("https://h", path).is_some(), "{path}");
    }
    for path in [
        "@evil.example/x",
        "/admin",
        "",
        "/v1/responses/../admin",
        "/v1/responsesx",
        "/v1/models/x",
        "/v1/responses#x",
        "//evil.example/v1/responses",
    ] {
        assert!(proxy_url("https://h", path).is_none(), "{path}");
    }
}

#[test]
fn refuses_an_upstream_with_a_fragment() {
    let parse_up =
        |up: &str| parse(&args(&["--api", "https://a.dev", "--upstream", up]), &no_env).map(|_| ());
    assert!(parse_up("https://h#f").is_err());
    assert!(parse_up("https://h/v1#").is_err());
    assert!(parse_up("https://h/v1").is_ok());
}

#[test]
fn maps_codex_paths_to_the_chatgpt_backend() {
    assert_eq!(
        codex_url("/v1/responses").as_deref(),
        Some("https://chatgpt.com/backend-api/codex/responses")
    );
    assert_eq!(
        codex_url("/v1/models?client_version=0.99").as_deref(),
        Some("https://chatgpt.com/backend-api/codex/models?client_version=0.99")
    );
    assert_eq!(codex_url("/v1/messages"), None);
}

#[test]
fn reads_a_codex_login_and_applies_a_refresh_keeping_other_fields() {
    let text = json!({
            "OPENAI_API_KEY": null,
            "tokens": {"access_token": jwt(1000), "refresh_token": "r1", "id_token": "i1", "account_id": "acct"},
            "last_refresh": "old",
        })
        .to_string();
    let v = parse_codex_login(&text).unwrap();
    assert_eq!((v.refresh.as_str(), v.account.as_str(), v.expires), ("r1", "acct", 1000));
    let (updated, login) = apply_refresh(
        &text,
        &json!({"access_token": jwt(5000), "refresh_token": "r2"}),
        1_762_490_000,
    )
    .unwrap();
    assert_eq!((login.refresh.as_str(), login.expires), ("r2", 5000));
    let file: Value = serde_json::from_str(&updated).unwrap();
    assert_eq!(file["tokens"]["id_token"], "i1");
    assert_eq!(file["tokens"]["account_id"], "acct");
    assert_eq!(file["last_refresh"], "2025-11-07T04:33:20Z");
    assert!(file.get("OPENAI_API_KEY").is_some());
    assert!(apply_refresh(&text, &json!({}), 0).is_err());
}

#[test]
fn a_login_without_chatgpt_tokens_is_refused() {
    assert!(parse_codex_login(r#"{"OPENAI_API_KEY":"sk-x"}"#).is_err());
    assert!(parse_codex_login("nope").is_err());
}

#[test]
fn formats_utc_times() {
    assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
    assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
}
