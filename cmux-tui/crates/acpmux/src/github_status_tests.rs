//! `github_status` against a fake Cloud agent socket, a fake cmux-platform HTTP server and a
//! stub `gh`: what each source answers, in which order, and that no token ever comes back.

use super::*;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};

const TOKEN: &str = "ghu_16C7e42F292c6912E7710c838347Ae178B4a";
const BEARER: &str = "cmux-signin-bearer-not-for-github";

/// A stub `gh` that answers `gh api user` with `body`, and fails for anything else or when a
/// GitHub token reached its env, or when it was not asked for the own gh login only.
fn stub_gh(dir: &std::path::Path, body: &Value) -> OsString {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join("gh");
    let script = format!(
        "#!/bin/sh\n\
         [ -n \"$GH_TOKEN$GITHUB_TOKEN\" ] && exit 3\n\
         [ \"$CMUX_GITHUB_GH_OWN_LOGIN_ONLY\" = 1 ] || exit 4\n\
         [ \"$1 $2\" = \"api user\" ] || exit 2\n\
         cat <<'JSON'\n{body}\nJSON\n"
    );
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.into_os_string()
}

/// A fake Cloud agent: answers one `github_status` line with `reply`, and hands back the line.
fn fake_agent(dir: &std::path::Path, reply: Value) -> (PathBuf, tokio::task::JoinHandle<String>) {
    let path = dir.join("agent.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut line = String::new();
        tokio::io::BufReader::new(read).read_line(&mut line).await.unwrap();
        write.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
        line
    });
    (path, task)
}

/// A fake cmux-platform: answers one request with `status` and `body`, and hands back the
/// request head.
async fn fake_platform(status: u16, body: Value) -> (String, tokio::task::JoinHandle<String>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut head = Vec::new();
        let mut buf = [0u8; 1024];
        while !head.windows(4).any(|w| w == b"\r\n\r\n") {
            let n = stream.read(&mut buf).await.unwrap();
            if n == 0 {
                break;
            }
            head.extend_from_slice(&buf[..n]);
        }
        let body = body.to_string();
        let reply = format!(
            "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(reply.as_bytes()).await.unwrap();
        String::from_utf8_lossy(&head).into_owned()
    });
    (origin, task)
}

fn platform(origin: String) -> Platform {
    Platform { origin, bearer: Bearer::Fixed(BEARER.to_owned()) }
}

fn no_token(value: &Value) {
    let text = value.to_string();
    for secret in [TOKEN, "ghu_", "gho_", BEARER] {
        assert!(!text.contains(secret), "{secret} leaked: {text}");
    }
}

#[tokio::test]
async fn the_cloud_path_asks_the_machine_agent_and_keeps_only_profile_fields() {
    let dir = tempfile::tempdir().unwrap();
    let (socket, agent) = fake_agent(
        dir.path(),
        json!({"ok": true, "connected": true, "login": "teamleaderleo", "source": "github-app",
               "accountType": "user", "htmlUrl": "https://github.com/teamleaderleo",
               "token": TOKEN, "installationToken": TOKEN}),
    );
    let sources = Sources { cloud_socket: Some(socket), ..Default::default() };
    let status = resolve(&sources).await;
    assert_eq!(agent.await.unwrap().trim(), r#"{"github_status":{}}"#);
    assert_eq!(
        status,
        json!({"connected": true, "login": "teamleaderleo", "accountType": "user",
               "htmlUrl": "https://github.com/teamleaderleo", "source": "github-app",
               "via": "cmux",
               "accounts": [{"login": "teamleaderleo", "accountType": "user",
                             "htmlUrl": "https://github.com/teamleaderleo",
                             "source": "github-app"}]})
    );
    let mcp = result(&status);
    no_token(&mcp);
    let text = mcp["content"][0]["text"].as_str().unwrap();
    assert!(
        text.contains("teamleaderleo, connected to cmux through the cmux GitHub App"),
        "{text}"
    );
}

#[tokio::test]
async fn the_signed_in_path_reads_the_platform_route_with_the_cmux_bearer_only() {
    let (origin, server) = fake_platform(
        200,
        json!({"connected": true, "login": "manaflow-ai", "accountType": "organization",
               "htmlUrl": "https://github.com/manaflow-ai",
               "avatarUrl": "https://github.com/manaflow-ai.png", "token": TOKEN}),
    )
    .await;
    let sources = Sources { platform: Some(platform(origin)), ..Default::default() };
    let status = resolve(&sources).await;
    let head = server.await.unwrap();
    assert!(head.starts_with("GET /v1/me/github HTTP/1.1\r\n"), "{head}");
    assert!(head.to_ascii_lowercase().contains(&format!("authorization: bearer {BEARER}")));
    assert_eq!(status["login"], "manaflow-ai");
    assert_eq!(status["source"], "github-app");
    let mcp = result(&status);
    no_token(&mcp);
    let text = mcp["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("not the person's own account"), "{text}");
}

#[tokio::test]
async fn the_local_path_runs_gh_with_no_token_in_its_env_and_drops_secrets_it_prints() {
    let dir = tempfile::tempdir().unwrap();
    let gh = stub_gh(
        dir.path(),
        &json!({"login": "teamleaderleo", "name": "Leo", "html_url": "https://github.com/teamleaderleo",
                "token": TOKEN, "company": TOKEN}),
    );
    let sources = Sources { gh: Some(gh), ..Default::default() };
    let status = resolve(&sources).await;
    assert_eq!(
        status,
        json!({"connected": true, "login": "teamleaderleo", "name": "Leo",
               "htmlUrl": "https://github.com/teamleaderleo", "source": "gh-cli", "via": "cmux",
               "accounts": [{"login": "teamleaderleo", "name": "Leo",
                             "htmlUrl": "https://github.com/teamleaderleo", "source": "gh-cli"}]})
    );
    no_token(&result(&status));
    // A token printed where the name goes is dropped, not passed on.
    let gh = stub_gh(dir.path(), &json!({"login": "teamleaderleo", "name": TOKEN}));
    let status = resolve(&Sources { gh: Some(gh), ..Default::default() }).await;
    assert_eq!(status["login"], "teamleaderleo");
    assert!(status.get("name").is_none(), "{status}");
    no_token(&result(&status));
}

/// On a machine with both, the person's own `gh` login comes first and the cmux connection is
/// listed too, each labelled by its source.
#[tokio::test]
async fn both_sources_are_returned_labelled_with_the_local_login_first() {
    let dir = tempfile::tempdir().unwrap();
    let gh = stub_gh(dir.path(), &json!({"login": "teamleaderleo"}));
    let (origin, _server) = fake_platform(
        200,
        json!({"connected": true, "login": "manaflow-ai", "accountType": "organization"}),
    )
    .await;
    let sources = Sources { gh: Some(gh), platform: Some(platform(origin)), cloud_socket: None };
    let status = resolve(&sources).await;
    assert_eq!(status["login"], "teamleaderleo");
    assert_eq!(status["source"], "gh-cli");
    assert_eq!(
        status["accounts"],
        json!([{"login": "teamleaderleo", "source": "gh-cli"},
               {"login": "manaflow-ai", "accountType": "organization", "source": "github-app"}])
    );
    let text = result(&status)["content"][0]["text"].as_str().unwrap().to_owned();
    assert!(text.contains("teamleaderleo, the person's own GitHub CLI login"), "{text}");
    assert!(text.contains("manaflow-ai, a GitHub organization"), "{text}");
}

#[tokio::test]
async fn a_failed_check_is_not_reported_as_disconnected() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("b")).unwrap();
    let (socket, _agent) = fake_agent(
        dir.path(),
        json!({"ok": false, "error": {"code": "auth.refused", "message": TOKEN}}),
    );
    let (origin, _server) =
        fake_platform(401, json!({"_tag": "ConnectorNeedsAuth", "token": TOKEN})).await;
    let sources = Sources {
        cloud_socket: Some(socket),
        platform: Some(platform(origin)),
        gh: Some(dir.path().join("no-such-gh").into_os_string()),
    };
    let status = resolve(&sources).await;
    assert_eq!(
        status,
        json!({"connected": false, "source": "none", "via": "cmux", "accounts": [],
               "unavailable": true})
    );
    let mcp = result(&status);
    no_token(&mcp);
    let text = mcp["content"][0]["text"].as_str().unwrap();
    assert!(text.starts_with("cmux could not check the GitHub connection"), "{text}");
    // A cmux source that answers "not connected" is not a failed check.
    let (socket, _agent) =
        fake_agent(&dir.path().join("b"), json!({"ok": true, "connected": false}));
    let sources = Sources { cloud_socket: Some(socket), ..Default::default() };
    let status = resolve(&sources).await;
    assert_eq!(
        status,
        json!({"connected": false, "source": "none", "via": "cmux", "accounts": []})
    );
    let text = result(&status)["content"][0]["text"].as_str().unwrap().to_owned();
    assert!(text.starts_with("No GitHub account"), "{text}");
}

#[test]
fn the_tool_takes_no_arguments_and_its_instruction_names_it() {
    let tool = definition();
    assert_eq!(tool["name"], TOOL);
    assert_eq!(tool["inputSchema"], json!({"type": "object", "properties": {}}));
    assert!(STEER.contains("call github_status"));
    // Models ran `gh auth status` instead, which sees nothing on a Cloud machine with no repo.
    assert!(STEER.contains("instead of running gh"));
    assert!(STEER.contains("Cloud"));
}
