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

/// A one-shot fake subscription proxy: records the request it got and answers `reply` (raw HTTP).
async fn fake_upstream(reply: &'static str) -> (String, tokio::task::JoinHandle<String>) {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut sock, _) = listener.accept().await.unwrap();
        let mut got = Vec::new();
        let mut buf = [0u8; 4096];
        // Headers, then the declared body.
        loop {
            let n = sock.read(&mut buf).await.unwrap();
            got.extend_from_slice(&buf[..n]);
            let text = String::from_utf8_lossy(&got).to_string();
            if let Some((head, body)) = text.split_once("\r\n\r\n") {
                let len = head
                    .lines()
                    .find_map(|l| {
                        l.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .map(|v| v.trim().parse::<usize>().unwrap())
                    })
                    .unwrap_or(0);
                if body.len() >= len {
                    break;
                }
            }
            if n == 0 {
                break;
            }
        }
        sock.write_all(reply.as_bytes()).await.unwrap();
        sock.shutdown().await.unwrap();
        String::from_utf8_lossy(&got).to_string()
    });
    (base, task)
}

fn test_client() -> reqwest::Client {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::new()
}

fn pending(path: &str, body: &str) -> Pending {
    Pending {
        method: "POST".into(),
        path: path.into(),
        headers: vec![
            ("content-type".into(), "application/json".into()),
            ("x-cmux-machine".into(), "vm_abcdefghij0123456789".into()),
            ("anthropic-version".into(), "2023-06-01".into()),
        ],
        body: body.as_bytes().to_vec(),
    }
}

async fn frames(rx: &mut mpsc::Receiver<String>) -> Vec<Value> {
    let mut out = Vec::new();
    while let Some(f) = rx.recv().await {
        let v: Value = serde_json::from_str(&f).unwrap();
        let last = matches!(v["t"].as_str(), Some("end" | "error"));
        out.push(v);
        if last {
            break;
        }
    }
    out
}

#[tokio::test]
async fn forwards_a_call_to_the_proxy_and_streams_its_answer_as_frames() {
    let (base, upstream) = fake_upstream(
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nset-cookie: s=1\r\nretry-after: 3\r\nconnection: close\r\n\r\nevent: a\ndata: 1\n\nevent: b\ndata: 2\n\n",
    )
    .await;
    let dir = std::env::temp_dir().join(format!("cmux-gw-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let key = dir.join("key");
    std::fs::write(&key, "proxy-key\n").unwrap();
    let provider = Provider::new(
        Upstream::Proxy { base: format!("{base}/v1"), key_file: Some(key) },
        test_client(),
    );
    let (tx, mut rx) = mpsc::channel(32);
    answer(&provider, "c1", pending("/v1/messages", r#"{"model":"m"}"#), &tx).await;
    let got = frames(&mut rx).await;
    assert_eq!(got[0]["t"], "head");
    assert_eq!(got[0]["status"], 200);
    assert_eq!(got[0]["headers"]["content-type"], "text/event-stream");
    assert_eq!(got[0]["headers"]["retry-after"], "3");
    assert!(got[0]["headers"].get("set-cookie").is_none());
    let body: Vec<u8> = got[1..got.len() - 1]
        .iter()
        .flat_map(|f| {
            base64::engine::general_purpose::STANDARD.decode(f["data"].as_str().unwrap()).unwrap()
        })
        .collect();
    assert_eq!(String::from_utf8(body).unwrap(), "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n");
    assert_eq!(got.last().unwrap()["t"], "end");
    let request = upstream.await.unwrap();
    let lower = request.to_ascii_lowercase();
    // `--upstream http://host/v1` and the call's `/v1/messages` reach `/v1/messages` once.
    assert!(request.starts_with("POST /v1/messages HTTP/1.1"), "{request}");
    assert!(lower.contains("authorization: bearer proxy-key"));
    assert!(lower.contains("anthropic-version: 2023-06-01"));
    // The backend's routing header stays here.
    assert!(!lower.contains("x-cmux-machine"));
    assert!(request.ends_with(r#"{"model":"m"}"#));
}

/// Claude Code's own session header reaches the proxy, as Codex's `session_id` does: the proxy keeps one chat
/// on one account with it, so its prompt cache keeps hitting. Without it sr2 keyed every call of the Freestyle
/// machines behind one team gateway on a hash of the conversation's opening (`fallback:`), which a compaction
/// changes (sr2 audit, 2026-11-22: 430 of 528 calls from gcp-agent-lane-13 in 90 minutes).
#[tokio::test]
async fn claude_codes_session_header_reaches_the_proxy() {
    let (base, upstream) =
        fake_upstream("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}").await;
    let provider = Provider::new(
        Upstream::Proxy { base: format!("{base}/v1"), key_file: None },
        test_client(),
    );
    let mut call = pending("/v1/messages", r#"{"model":"m"}"#);
    call.headers
        .push(("x-claude-code-session-id".into(), "01a20179-9d24-7071-82aa-7b1b4f55d76f".into()));
    let (tx, mut rx) = mpsc::channel(32);
    answer(&provider, "c1", call, &tx).await;
    let got = frames(&mut rx).await;
    assert_eq!(got[0]["status"], 200, "{got:?}");
    let request = upstream.await.unwrap().to_ascii_lowercase();
    assert!(
        request.contains("x-claude-code-session-id: 01a20179-9d24-7071-82aa-7b1b4f55d76f"),
        "{request}"
    );
}

#[tokio::test]
async fn an_unreachable_proxy_ends_the_call_with_a_typed_error() {
    // A port nothing listens on: bind, then drop it.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let provider = Provider::new(
        Upstream::Proxy { base: format!("http://127.0.0.1:{port}"), key_file: None },
        test_client(),
    );
    let (tx, mut rx) = mpsc::channel(4);
    answer(&provider, "c2", pending("/v1/responses", "{}"), &tx).await;
    let got = frames(&mut rx).await;
    assert_eq!(got.len(), 1);
    assert_eq!(got[0]["t"], "error");
    assert_eq!(got[0]["code"], "inference.upstream_unreachable");
}

#[test]
fn personal_selects_the_owner_gateway() {
    let base = ["--api", "https://api.cmux.dev", "--upstream", "http://127.0.0.1:8317"];
    let team = parse(&args(&base), &no_env).unwrap();
    assert!(!team.personal);
    let mut with = base.to_vec();
    with.push("--personal");
    assert!(parse(&args(&with), &no_env).unwrap().personal);
    assert_eq!(PERSONAL_CONNECT_PATH, "/v1/cloud/inference-gateway/personal/connect");
    assert!(help().contains("cmux inference gateway status [--personal] [--token-stdin] [--json]"));
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
fn parses_the_apps_mac_logins_gateway() {
    let env = |k: &str| (k == "HOME").then(|| "/Users/p".to_owned());
    let o = parse(
        &args(&[
            "--api",
            "https://api.cmux.dev",
            "--personal",
            "--mac-logins",
            "--supervised",
            "--enable-once",
            "/s/on",
        ]),
        &env,
    )
    .unwrap();
    let Upstream::MacLogins(logins) = &o.upstream else { panic!("{:?}", o.upstream) };
    assert_eq!(logins.codex_auth, PathBuf::from("/Users/p/.codex/auth.json"));
    assert_eq!(logins.claude_home, PathBuf::from("/Users/p/.claude"));
    assert!(o.supervised);
    assert_eq!(o.enable_once, Some(PathBuf::from("/s/on")));
    // The app's default token source stays: `cmux auth token`.
    assert_eq!(o.token, TokenSource::App);
    // --mac-logins is its own upstream, and --enable-once is only for the person's own gateway.
    let api = ["--api", "https://api.cmux.dev", "--personal", "--mac-logins"];
    let mut two = api.to_vec();
    two.extend(["--upstream", "http://127.0.0.1:8317"]);
    assert!(parse(&args(&two), &env).is_err());
    let team = ["--api", "https://api.cmux.dev", "--mac-logins", "--enable-once", "/s/on"];
    assert!(parse(&args(&team), &env).is_err());
}

#[tokio::test]
async fn a_messages_call_goes_out_with_claude_codes_borrowed_sign_in() {
    let (base, upstream) = fake_upstream(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n{}",
    )
    .await;
    let dir = std::env::temp_dir().join(format!("cmux-gw-claude-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let far = (now_s() + 3600) * 1000;
    std::fs::write(
        dir.join(".credentials.json"),
        format!(r#"{{"claudeAiOauth":{{"accessToken":"oat-1","refreshToken":"keep","expiresAt":{far}}}}}"#),
    )
    .unwrap();
    let logins = MacLogins {
        claude_home: dir.clone(),
        codex_auth: dir.join("auth.json"),
        keychain: false,
        claude_base: base,
    };
    let provider = Provider::new(Upstream::MacLogins(logins), test_client());
    let mut call = pending("/v1/messages?beta=true", r#"{"model":"m"}"#);
    call.headers.push(("anthropic-beta".into(), "claude-code-20250219".into()));
    let (tx, mut rx) = mpsc::channel(32);
    answer(&provider, "c3", call, &tx).await;
    let got = frames(&mut rx).await;
    assert_eq!(got[0]["status"], 200);
    let request = upstream.await.unwrap();
    let lower = request.to_ascii_lowercase();
    assert!(request.starts_with("POST /v1/messages?beta=true HTTP/1.1"), "{request}");
    assert!(lower.contains("authorization: bearer oat-1"));
    assert!(lower.contains("anthropic-beta: claude-code-20250219,oauth-2025-04-20"), "{request}");
    assert_eq!(lower.matches("anthropic-beta:").count(), 1, "{request}");
    assert!(!lower.contains("x-cmux-machine"));
    // Never refreshed: the refresh token is not sent anywhere.
    assert!(!request.contains("keep"));
}

#[tokio::test]
async fn the_mac_logins_gateway_serves_no_other_path() {
    let dir = std::env::temp_dir().join(format!("cmux-gw-claude-np-{}", std::process::id()));
    let logins = MacLogins {
        claude_home: dir.clone(),
        codex_auth: dir.join("auth.json"),
        keychain: false,
        claude_base: "http://127.0.0.1:1".into(),
    };
    let provider = Provider::new(Upstream::MacLogins(logins), test_client());
    let (tx, mut rx) = mpsc::channel(4);
    answer(&provider, "c4", pending("/v1/chat/completions", "{}"), &tx).await;
    let got = frames(&mut rx).await;
    assert_eq!(got[0]["code"], "inference.not_found");
    // No Claude sign-in on this Mac: a typed login error, not a crash or a hang.
    let (tx, mut rx) = mpsc::channel(4);
    answer(&provider, "c5", pending("/v1/messages", "{}"), &tx).await;
    assert_eq!(frames(&mut rx).await[0]["code"], "inference.gateway_login");
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

/// The Worker serves Gemini (`/v1beta/...`) and Grok (`/xai/v1/...`) itself, with the team's
/// key; the person-run relay never carries them, so its key never reaches those providers
/// (hq#11225).
#[test]
fn the_relay_never_carries_gemini_or_grok_paths() {
    for path in PROXY_PATHS {
        assert!(!path.starts_with("/xai/") && !path.starts_with("/v1beta/"), "{path}");
    }
    for path in [
        "/xai/v1/chat/completions",
        "/xai/v1/responses",
        "/xai/v1/models",
        "/v1beta/models/gemini-2.5-pro:generateContent",
        "/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse",
        "/v1beta/models/gemini-2.5-pro:countTokens",
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

#[test]
fn interactive_calls_pass_when_background_used_the_unreserved_share() {
    let interactive = vec![(PRIORITY_HEADER.to_owned(), "interactive".to_owned())];
    let background = vec![(PRIORITY_HEADER.to_owned(), "background".to_owned())];
    let unreserved = MAX_CALLS - INTERACTIVE_RESERVE;
    // Background traffic fills every slot it may take; the next background call is refused.
    assert!(admits(unreserved - 1, &background));
    assert!(!admits(unreserved, &background));
    assert!(!admits(unreserved, &[]), "a call naming no priority counts as background");
    // An interactive call still passes, up to the whole limit.
    assert!(admits(unreserved, &interactive));
    assert!(admits(MAX_CALLS - 1, &interactive));
    assert!(!admits(MAX_CALLS, &interactive));
    assert!(PASS_HEADERS.contains(&PRIORITY_HEADER), "the priority goes upstream too");
}

/// The 11-23 and 11-24 "at its call limit" bursts: the API's Worker never fires `request.signal` (its
/// compatibility date predates request-signal-by-default), so a machine that walks away from a call (a timeout, an
/// interrupt, a retry) never sends `cancel`, and the gateway still runs that call. Calls nobody cancels fill the
/// background share while the API sees far fewer live ones; the next background call must wait for a freed slot,
/// not fail at once, and a `cancel` (the task's abort) must give the slot back.
#[tokio::test(start_paused = true)]
async fn calls_nobody_cancels_fill_the_share_and_the_next_call_waits_for_a_freed_slot() {
    let slots = Arc::new(Slots::default());
    let unreserved = MAX_CALLS - INTERACTIVE_RESERVE;
    // Ghost calls: tasks whose provider call never ends and that no `cancel` reaches.
    let ghosts: Vec<_> = (0..unreserved)
        .map(|_| {
            let slot = slots.try_take(false).expect("a permit under the share");
            tokio::spawn(async move {
                std::future::pending::<()>().await;
                drop(slot);
            })
        })
        .collect();
    tokio::task::yield_now().await;
    assert_eq!(slots.in_flight(), unreserved);
    assert!(slots.try_take(false).is_none(), "the background share is full");

    let waiter = {
        let slots = slots.clone();
        tokio::spawn(async move { slots.take(false, BACKGROUND_WAIT).await })
    };
    tokio::time::sleep(Duration::from_secs(4)).await;
    assert!(!waiter.is_finished(), "a call past the cap waits instead of failing at once");
    // A `cancel` aborts the call's task: dropping it frees the slot (RAII), and the waiter takes it.
    ghosts[0].abort();
    let taken = waiter.await.unwrap();
    assert!(taken.is_some(), "the freed permit goes to the waiting call");
    assert_eq!(slots.in_flight(), unreserved);
    for ghost in &ghosts {
        ghost.abort();
    }
    for _ in 0..4 {
        tokio::task::yield_now().await;
    }
    assert_eq!(
        slots.in_flight(),
        1,
        "every aborted call gave its permit back; the waiter's is the one left"
    );
}

#[tokio::test(start_paused = true)]
async fn a_full_gateway_holds_background_10_s_and_interactive_30_s() {
    let slots = Arc::new(Slots::default());
    let background: Vec<_> =
        (0..MAX_CALLS - INTERACTIVE_RESERVE).map(|_| slots.try_take(false).unwrap()).collect();
    // The reserve: an interactive call still gets a slot at once.
    let mut reserve =
        vec![slots.take(true, INTERACTIVE_WAIT).await.expect("the interactive reserve")];
    while let Some(slot) = slots.try_take(true) {
        reserve.push(slot);
    }
    assert_eq!(slots.in_flight(), MAX_CALLS);

    let started = tokio::time::Instant::now();
    assert!(slots.take(false, BACKGROUND_WAIT).await.is_none());
    assert_eq!(started.elapsed(), BACKGROUND_WAIT);
    let started = tokio::time::Instant::now();
    assert!(slots.take(true, INTERACTIVE_WAIT).await.is_none());
    assert_eq!(started.elapsed(), INTERACTIVE_WAIT);

    // A slot freed past the background share goes to an interactive call, never to a background one.
    drop(reserve.pop());
    assert!(slots.try_take(false).is_none());
    assert!(slots.take(true, INTERACTIVE_WAIT).await.is_some());
    drop(background);
    drop(reserve);
    assert_eq!(slots.in_flight(), 0);
}

#[tokio::test(start_paused = true)]
async fn a_call_past_the_wait_gets_a_529_overloaded_error_with_a_jittered_retry_after() {
    let slots = Arc::new(Slots::default());
    let held: Vec<_> = (0..MAX_CALLS).map(|_| slots.try_take(true).unwrap()).collect();
    let upstream = Provider::new(
        Upstream::Proxy { base: "http://127.0.0.1:9".into(), key_file: None },
        test_client(),
    );
    let (tx, mut rx) = mpsc::channel(OUT_FRAMES);
    admitted(&slots, &upstream, "call-1", pending("/v1/messages", "{}"), &tx).await;
    let frames = frames(&mut rx).await;
    assert_eq!(frames.len(), 3, "{frames:?}");
    assert_eq!(frames[0]["t"], "head");
    assert_eq!(frames[0]["status"], 529);
    let retry: u64 = frames[0]["headers"]["retry-after"].as_str().unwrap().parse().unwrap();
    assert!((1..=BUSY_RETRY_AFTER_MAX_S).contains(&retry));
    let body = base64::engine::general_purpose::STANDARD
        .decode(frames[1]["data"].as_str().unwrap())
        .unwrap();
    let body: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(body["type"], "error");
    assert_eq!(body["error"]["type"], "overloaded_error");
    assert_eq!(body["error"]["code"], "inference.gateway_busy");
    assert_eq!(frames[2]["t"], "end");
    assert_eq!(slots.in_flight(), MAX_CALLS, "a busy call takes no permit");
    drop(held);
}

#[test]
fn busy_retry_after_is_full_jitter_within_its_bound() {
    let samples: Vec<u64> = (0..500).map(|_| jitter_s(BUSY_RETRY_AFTER_MAX_S)).collect();
    assert!(samples.iter().all(|s| (1..=BUSY_RETRY_AFTER_MAX_S).contains(s)));
    let distinct: std::collections::HashSet<_> = samples.iter().collect();
    assert!(distinct.len() > 5, "spread out, not one value: {distinct:?}");
}

/// Seeded secrets on the wire (cmux_egress::capture), both of this site's clients: a proxied call
/// sends the upstream key only in `Authorization` to the upstream (the prompt only in its body), and
/// the backend socket's upgrade sends the gateway's bearer only in `Authorization` and the team only
/// in `x-cmux-team`. Neither secret reaches the other host.
/// tests/egress_seeded.json names this test for `cmux_tui::cli::inference_gateway`.
#[tokio::test]
async fn seeded_secrets_ride_only_where_the_gateway_needs_them() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let key = "SEEDgwUpstreamKey-77e1";
    let token = "SEEDgwBackendBearer-0b5a";
    let team = "SEEDgwTeam-e3c9";
    let prompt = "SEEDgwPrompt-41fd";
    let dir = tempfile::tempdir().unwrap();
    let key_file = dir.path().join("key");
    std::fs::write(&key_file, format!("{key}\n")).unwrap();
    let upstream =
        Upstream::Proxy { base: "https://api.anthropic.com/v1".into(), key_file: Some(key_file) };
    let provider = Arc::new(Provider::new(upstream.clone(), upstream_client().unwrap()));
    let (tx, mut rx) = mpsc::channel(32);
    let body = format!(r#"{{"model":"m","messages":[{{"role":"user","content":"{prompt}"}}]}}"#);
    answer(&provider, "c1", pending("/v1/messages", &body), &tx).await;
    let _ = frames(&mut rx).await;
    let options = Options {
        api: "https://cloud-api.cmux.dev".into(),
        team: Some(team.to_owned()),
        personal: false,
        token: TokenSource::App,
        upstream,
        supervised: false,
        enable_once: None,
    };
    let (_stop, stop) = watch::channel(false);
    let ended = session(&options, token, provider, Arc::new(Slots::default()), stop).await;
    assert!(!matches!(ended, Ended::Shutdown), "{ended:?}");

    let upstream_sent = cmux_egress::capture::requests_to("api.anthropic.com");
    assert!(upstream_sent.iter().any(|r| r.target == "/v1/messages"), "{upstream_sent:?}");
    let backend_sent = cmux_egress::capture::requests_to("cloud-api.cmux.dev");
    assert!(backend_sent.iter().any(|r| r.target.starts_with(CONNECT_PATH)), "{backend_sent:?}");
    let places = cmux_egress::capture::leaks(key);
    assert!(!places.is_empty(), "{upstream_sent:?}");
    assert!(
        places
            .iter()
            .all(|p| p.starts_with("api.anthropic.com ") && p.ends_with(": header authorization")),
        "{places:?}"
    );
    let places = cmux_egress::capture::leaks(prompt);
    assert!(
        places.iter().all(|p| p.starts_with("api.anthropic.com ") && p.ends_with(": body")),
        "{places:?}"
    );
    let places = cmux_egress::capture::leaks(token);
    assert!(!places.is_empty(), "{backend_sent:?}");
    assert!(
        places
            .iter()
            .all(|p| p.starts_with("cloud-api.cmux.dev ") && p.ends_with(": header authorization")),
        "{places:?}"
    );
    let places = cmux_egress::capture::leaks(team);
    assert!(!places.is_empty(), "{backend_sent:?}");
    assert!(places.iter().all(|p| p.ends_with(": header x-cmux-team")), "{places:?}");
}

/// The call line splits the provider's wait before its head (time to first token on a pool that holds its head) from
/// the stream after it, under the 200 characters the Cloud probe keeps, starting `-> STATUS (TOTAL ms` as it reads.
#[test]
fn call_line_splits_head_from_stream() {
    let line = call_line("m-1", "POST", "/v1/messages", 200, 2057, 1900, Some(1902));
    assert_eq!(line, "m-1 POST /v1/messages -> 200 (2057 ms, head 1900 ms, first data 1902 ms)");
    let empty = call_line("m-1", "POST", "/v1/messages", 204, 30, 29, None);
    assert!(empty.ends_with("-> 204 (30 ms, head 29 ms, first data none)"), "{empty}");
    let longest =
        call_line(&"m".repeat(64), "POST", "/v1/messages", 200, 600_000, 600_000, Some(600_000));
    assert!(format!("cmux inference gateway: {longest}").len() <= 200, "{}", longest.len());
}
