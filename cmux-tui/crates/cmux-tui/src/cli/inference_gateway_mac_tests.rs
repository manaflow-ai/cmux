use super::*;

fn logins(dir: &Path) -> MacLogins {
    MacLogins {
        claude_home: dir.to_owned(),
        codex_auth: dir.join("auth.json"),
        keychain: false,
        claude_base: "http://127.0.0.1:1".into(),
    }
}

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-gw-mac-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn routes_messages_to_claude_and_responses_to_codex() {
    let base = "https://api.anthropic.com";
    assert_eq!(
        login_for(base, "/v1/messages"),
        Some(Login::Claude("https://api.anthropic.com/v1/messages".into()))
    );
    assert_eq!(
        login_for(base, "/v1/messages/count_tokens?beta=true"),
        Some(Login::Claude("https://api.anthropic.com/v1/messages/count_tokens?beta=true".into()))
    );
    assert_eq!(login_for(base, "/v1/responses"), Some(Login::Codex));
    assert_eq!(login_for(base, "/v1/models?client_version=1"), Some(Login::Codex));
    assert_eq!(login_for(base, "/v1/chat/completions"), None);
    assert_eq!(login_for(base, "@evil.example/v1/messages"), None);
}

#[test]
fn the_oauth_beta_joins_the_callers_betas_once() {
    let h = |v: &str| vec![("anthropic-beta".to_owned(), v.to_owned())];
    assert_eq!(oauth_beta(&[]), "oauth-2025-04-20");
    assert_eq!(oauth_beta(&h("a, b")), "a,b,oauth-2025-04-20");
    assert_eq!(oauth_beta(&h("oauth-2025-04-20,a")), "oauth-2025-04-20,a");
}

#[test]
fn the_default_places_follow_the_agents_own_variables() {
    let env = |k: &str| match k {
        "HOME" => Some("/Users/p".to_owned()),
        "CODEX_HOME" => Some("/Users/p/cx".to_owned()),
        _ => None,
    };
    let found = MacLogins::from_env(&env).unwrap();
    assert_eq!(found.claude_home, PathBuf::from("/Users/p/.claude"));
    assert_eq!(found.codex_auth, PathBuf::from("/Users/p/cx/auth.json"));
    assert_eq!(found.claude_base, CLAUDE_BACKEND);
}

#[tokio::test]
async fn a_borrowed_claude_token_is_read_again_and_never_refreshed() {
    let dir = temp("borrow");
    let write = |token: &str, exp: u64| {
        std::fs::write(
            dir.join(".credentials.json"),
            json!({"claudeAiOauth": {"accessToken": token, "refreshToken": "r", "expiresAt": exp}})
                .to_string(),
        )
        .unwrap();
    };
    let borrow = ClaudeBorrow::new(logins(&dir));
    write("t1", now_ms() + 3_600_000);
    assert_eq!(borrow.token(None).await.unwrap(), "t1");
    // Claude Code refreshed the file: a 401 on t1 reads again and takes t2.
    write("t2", now_ms() + 3_600_000);
    assert_eq!(borrow.token(None).await.unwrap(), "t1", "a fresh cached token is reused");
    assert_eq!(borrow.token(Some("t1")).await.unwrap(), "t2");
    // A 401 on the only token there is fails the call: nothing here refreshes it.
    let refused = borrow.token(Some("t2")).await.unwrap_err();
    assert_eq!(refused.0, "inference.gateway_login");
    // Expired on disk: the call fails with the login code, and the file is left as it was.
    write("t3", now_ms().saturating_sub(1));
    let expired = borrow.token(None).await.unwrap_err();
    assert_eq!(expired.0, "inference.gateway_login");
    let left = std::fs::read_to_string(dir.join(".credentials.json")).unwrap();
    assert!(left.contains("\"refreshToken\":\"r\"") && left.contains("t3"), "{left}");
}

#[tokio::test]
async fn no_claude_sign_in_is_a_login_error_not_a_crash() {
    let dir = temp("none");
    let borrow = ClaudeBorrow::new(logins(&dir));
    assert!(!borrow.present().await);
    assert_eq!(borrow.token(None).await.unwrap_err().0, "inference.gateway_login");
}

#[test]
fn the_freshest_sign_in_wins_and_a_refused_one_never_does() {
    let file = ("old".to_owned(), Some(1_000));
    let keychain = ("live".to_owned(), Some(9_000));
    assert_eq!(best(vec![file.clone(), keychain.clone()], None), Some(keychain.clone()));
    assert_eq!(best(vec![keychain.clone(), file.clone()], Some("live")), Some(file));
    assert_eq!(best(vec![keychain], Some("live")), None);
}

#[test]
fn parses_the_credentials_document() {
    let (t, exp) = parse_claude_credentials(
        r#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":1700000000000}}"#,
    )
    .unwrap();
    assert_eq!((t.as_str(), exp), ("sk-ant-oat01-x", Some(1_700_000_000_000)));
    assert!(parse_claude_credentials(r#"{"claudeAiOauth":{}}"#).is_err());
    assert!(parse_claude_credentials("not json").is_err());
}

#[tokio::test]
async fn enable_once_does_nothing_when_its_marker_is_there() {
    let dir = temp("once");
    let marker = dir.join("personal-mode-on");
    std::fs::write(&marker, "on\n").unwrap();
    // No API call is made: the API origin is unroutable and the token source fails if read.
    let token = TokenSource::File(dir.join("missing-token"));
    assert_eq!(enable_once("https://127.0.0.1:1", &token, &marker).await, Ok(false));
}
