use super::*;
use std::sync::Mutex;

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-hosted-{tag}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn script(dir: &std::path::Path, body: &str) -> std::ffi::OsString {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join("cmux");
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.into_os_string()
}

/// A `cmux` that mints `tok-1`, `tok-2`, ... (one per run) for the development API, and
/// refuses any other command line.
fn minting_cmux(dir: &std::path::Path) -> std::ffi::OsString {
    let count = dir.join("mints");
    script(
        dir,
        &format!(
            r#"[ "$*" = "--json auth token" ] || exit 9
n=$(cat '{c}' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '{c}'
printf '{{"access_token":"tok-%s","token_type":"Bearer","team":"team_x","expires_in":540,"api_origin":"https://cmux-api-development.debussy.workers.dev"}}\n' "$n""#,
            c = count.display()
        ),
    )
}

fn mints(dir: &std::path::Path) -> u32 {
    std::fs::read_to_string(dir.join("mints")).map_or(0, |n| n.trim().parse().unwrap())
}

/// A loopback hosted MCP server that takes only `Bearer tok-2` (so the first token gets a 401),
/// answers `tools/list` as JSON and `tools/call` as an event stream, and records each request's
/// `authorization` header and method.
async fn hosted_server() -> (String, Arc<Mutex<Vec<(String, String)>>>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let log = Arc::clone(&seen);
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            let log = Arc::clone(&log);
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                loop {
                    let text = String::from_utf8_lossy(&buf).into_owned();
                    if let Some(end) = text.find("\r\n\r\n") {
                        let head = text[..end].to_ascii_lowercase();
                        let len = head
                            .lines()
                            .find_map(|l| {
                                l.strip_prefix("content-length:")
                                    .map(|v| v.trim().parse().unwrap_or(0))
                            })
                            .unwrap_or(0usize);
                        if buf.len() >= end + 4 + len {
                            let body: Value = serde_json::from_slice(&buf[end + 4..end + 4 + len])
                                .unwrap_or(Value::Null);
                            buf.drain(..end + 4 + len);
                            let auth = head
                                .lines()
                                .find_map(|l| l.strip_prefix("authorization:"))
                                .unwrap_or("")
                                .trim()
                                .to_owned();
                            let method = body["method"].as_str().unwrap_or("").to_owned();
                            log.lock().unwrap().push((auth.clone(), method.clone()));
                            let out = if auth != "bearer tok-2" {
                                "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n".to_owned()
                            } else if body.get("id").is_none() {
                                "HTTP/1.1 202 Accepted\r\ncontent-length: 0\r\n\r\n".to_owned()
                            } else if method == "tools/call" {
                                let reply = json!({"jsonrpc": "2.0", "id": body["id"], "result": {"content": [{"type": "text", "text": "2 open pull requests"}]}});
                                let b = format!(
                                    "event: message\ndata: {}\n\n",
                                    json!({"jsonrpc": "2.0", "method": "notifications/progress"})
                                ) + &format!("event: message\ndata: {reply}\n\n");
                                format!(
                                    "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {}\r\n\r\n{b}",
                                    b.len()
                                )
                            } else {
                                let result = if method == "initialize" {
                                    json!({"protocolVersion": "2025-06-18", "serverInfo": {"name": "cmux-platform"}})
                                } else {
                                    json!({"tools": [{"name": "list_repos", "inputSchema": {"type": "object"}}]})
                                };
                                let b =
                                    json!({"jsonrpc": "2.0", "id": body["id"], "result": result})
                                        .to_string();
                                format!(
                                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{b}",
                                    b.len()
                                )
                            };
                            if sock.write_all(out.as_bytes()).await.is_err() {
                                return;
                            }
                            continue;
                        }
                    }
                    match sock.read(&mut chunk).await {
                        Ok(0) | Err(_) => return,
                        Ok(n) => buf.extend_from_slice(&chunk[..n]),
                    }
                }
            });
        }
    });
    (origin, seen)
}

#[tokio::test]
async fn hosted_mcp_signs_each_request_with_the_persons_token_and_mints_again_after_a_401() {
    let dir = temp_dir("sign");
    let (origin, seen) = hosted_server().await;
    let mut bridge = Bridge::new(minting_cmux(&dir), Some(origin)).unwrap();

    // `initialize` is answered here: no token is minted for a chat that never lists.
    let init = json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}});
    let reply = bridge.handle(&init).await.unwrap();
    assert_eq!(reply["result"]["serverInfo"]["name"], SERVER_NAME);
    assert_eq!(mints(&dir), 0);
    assert_eq!(
        bridge.handle(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).await,
        None
    );

    let list = json!({"jsonrpc": "2.0", "id": "a-7", "method": "tools/list", "params": {}});
    let reply = bridge.handle(&list).await.unwrap();
    assert_eq!(reply["id"], "a-7", "{reply}");
    assert_eq!(reply["result"]["tools"][0]["name"], "list_repos", "{reply}");
    // tok-1 got a 401, so a second token was minted and the session started again with it.
    assert_eq!(mints(&dir), 2);
    let auths: Vec<String> = seen.lock().unwrap().iter().map(|(a, _)| a.clone()).collect();
    assert_eq!(auths.first().map(String::as_str), Some("bearer tok-1"));
    assert!(auths.iter().skip(1).all(|a| a == "bearer tok-2"), "{auths:?}");
    let methods: Vec<String> = seen.lock().unwrap().iter().map(|(_, m)| m.clone()).collect();
    assert_eq!(methods, ["initialize", "initialize", "notifications/initialized", "tools/list"]);

    let call = json!({"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "list_repos", "arguments": {}}});
    let reply = bridge.handle(&call).await.unwrap();
    assert_eq!(reply["id"], 9);
    assert_eq!(reply["result"]["content"][0]["text"], "2 open pull requests", "{reply}");
    // The held token serves the next call: no new mint, no new initialize.
    assert_eq!(mints(&dir), 2);
    assert_eq!(seen.lock().unwrap().len(), 5);
    for reply in [bridge.handle(&list).await.unwrap(), reply] {
        assert!(!reply.to_string().contains("tok-"), "a token reached the agent: {reply}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn hosted_mcp_lists_nothing_and_says_why_when_the_person_is_not_signed_in() {
    let dir = temp_dir("signed-out");
    let (origin, seen) = hosted_server().await;
    let cmux = script(
        &dir,
        r#"echo '{"code":"not_signed_in","message":"Sign in to cmux first"}' >&2; exit 3"#,
    );
    let mut bridge = Bridge::new(cmux, Some(origin)).unwrap();
    let list = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"});
    let reply = bridge.handle(&list).await.unwrap();
    assert_eq!(reply["error"]["code"], -32002, "{reply}");
    assert!(reply["error"]["message"].as_str().unwrap().contains("Not signed in"), "{reply}");
    let call = json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "x"}});
    let reply = bridge.handle(&call).await.unwrap();
    assert_eq!(reply["result"]["isError"], true, "{reply}");
    assert!(seen.lock().unwrap().is_empty(), "a request went out without a sign-in");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn hosted_mcp_token_goes_only_to_the_platform_of_its_issuer() {
    use cmux_cloud_client::backend::Backend;
    for b in [Backend::Development, Backend::Staging, Backend::Production] {
        assert_eq!(platform_for_issuer(b.owner_api()), Some(b.platform()));
        assert_eq!(platform_for_issuer(&format!("{}/", b.owner_api())), Some(b.platform()));
    }
    let production_api = Backend::Production.owner_api();
    for other in [
        "",
        "https://evil.example",
        "http://localhost:8787",
        "https://cmux-api-preview-3.debussy.workers.dev",
    ] {
        assert_eq!(platform_for_issuer(other), None, "{other}");
    }
    let now = Instant::now();
    let answer = |api: &str| {
        format!(r#"{{"access_token":"secret-tok","expires_in":540,"api_origin":"{api}"}}"#)
    };
    let minted = parse_minted(answer(production_api).as_bytes(), None, now).unwrap();
    assert_eq!(minted.mcp_url, format!("{}/mcp", Backend::Production.platform()));
    assert_eq!(minted.refresh_at, now + Duration::from_secs(480));
    assert!(!format!("{minted:?}").contains("secret-tok"));
    let refused = parse_minted(answer("https://evil.example").as_bytes(), None, now).unwrap_err();
    assert!(!refused.contains("secret-tok"));
    // The test override is loopback http only, so it can never send the token to a host.
    let local = parse_minted(answer("x").as_bytes(), Some("http://127.0.0.1:9"), now).unwrap();
    assert_eq!(local.mcp_url, "http://127.0.0.1:9/mcp");
    for origin in [
        "https://127.0.0.1:9",
        "http://example.com",
        "http://127.0.0.1:9/mcp",
        "http://user@127.0.0.1:9",
        "http://127.0.0.1.evil.example",
    ] {
        assert!(
            parse_minted(answer(production_api).as_bytes(), Some(origin), now).is_err(),
            "{origin}"
        );
    }
    for bad in [&b"{}"[..], &b"not json"[..], &br#"{"access_token":"a b"}"#[..]] {
        assert!(parse_minted(bad, None, now).is_err());
    }
}

#[test]
fn hosted_mcp_reads_a_reply_from_json_a_batch_or_an_event_stream() {
    let id = json!(3);
    let one = json!({"jsonrpc": "2.0", "id": 3, "result": {"ok": true}});
    assert_eq!(reply_for("application/json", &one.to_string(), &id), Some(one.clone()));
    let batch = json!([{"jsonrpc": "2.0", "id": 2, "result": {}}, one]).to_string();
    assert_eq!(
        reply_for("application/json; charset=utf-8", &batch, &id).unwrap()["result"]["ok"],
        true
    );
    let stream = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"x\"}\r\n\r\ndata: {\"jsonrpc\":\"2.0\",\n\
                  data: \"id\":3,\"error\":{\"code\":-1,\"message\":\"no\"}}\n\n";
    assert_eq!(reply_for("text/event-stream", stream, &id).unwrap()["error"]["message"], "no");
    assert_eq!(reply_for("application/json", "<html>", &id), None);
    assert_eq!(reply_for("application/json", &one.to_string(), &json!("3")), None);
}

#[test]
fn hosted_mcp_refusals_name_what_the_person_does() {
    assert!(refusal_text(Some("not_signed_in")).contains("sign in"));
    assert!(refusal_text(Some("app.unreachable")).contains("not reachable"));
    let odd = refusal_text(Some("x\n\u{1b}[31mBearer abc def"));
    assert_eq!(odd, "cmux could not get a sign-in token (x31mBearerabcdef).");
}
