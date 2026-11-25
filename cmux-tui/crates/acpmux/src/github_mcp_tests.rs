use super::*;
use std::sync::Mutex;

const TOKEN: &str = "ghs_fake_installation_token_for_tests_00";

/// A fake GitHub MCP server on loopback that takes only `Bearer TOKEN`, lists one read-only and
/// one write tool, answers a call, and records each request's authorization and method.
async fn github_server() -> (String, Arc<Mutex<Vec<(String, String)>>>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let log = Arc::clone(&seen);
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            let log = Arc::clone(&log);
            tokio::spawn(async move {
                use tokio::io::AsyncReadExt;
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
                            let out = if auth != format!("bearer {}", TOKEN.to_ascii_lowercase()) {
                                "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n".to_owned()
                            } else if body.get("id").is_none() {
                                "HTTP/1.1 202 Accepted\r\ncontent-length: 0\r\n\r\n".to_owned()
                            } else {
                                let result = match method.as_str() {
                                    "tools/list" => json!({"tools": [
                                        {"name": "list_pull_requests", "annotations": {"readOnlyHint": true}},
                                        {"name": "create_issue", "annotations": {"readOnlyHint": false}},
                                    ]}),
                                    "tools/call" => json!({"content": [{"type": "text",
                                        "text": format!("ok, echoed {TOKEN}")}]}),
                                    _ => {
                                        json!({"protocolVersion": "2025-06-18", "capabilities": {}})
                                    }
                                };
                                let b =
                                    json!({"jsonrpc": "2.0", "id": body["id"], "result": result})
                                        .to_string();
                                format!(
                                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nmcp-session-id: s1\r\ncontent-length: {}\r\n\r\n{b}",
                                    b.len()
                                )
                            };
                            if tokio::io::AsyncWriteExt::write_all(&mut sock, out.as_bytes())
                                .await
                                .is_err()
                            {
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

fn recording_mint(
    answer: Result<&'static str, (&'static str, &'static str)>,
) -> (Mint, Arc<Mutex<Vec<TokenAsk>>>) {
    let asks = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&asks);
    let mint: Mint = Arc::new(move |ask: &TokenAsk| {
        log.lock().unwrap().push(ask.clone());
        match answer {
            Ok(t) => Ok(t.to_owned()),
            Err((code, msg)) => Err(github_cli::refused(code, msg)),
        }
    });
    (mint, asks)
}

fn call(id: u64, tool: &str, args: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": tool, "arguments": args}})
}

#[test]
fn only_a_bare_loopback_origin_replaces_github() {
    assert_eq!(loopback_url("http://127.0.0.1:9").unwrap(), "http://127.0.0.1:9/mcp/");
    for bad in ["https://evil.example", "http://127.0.0.1:9/x", "http://u@127.0.0.1:9", "nope"] {
        assert!(loopback_url(bad).is_err(), "{bad}");
    }
}

#[test]
fn a_call_names_its_repo_and_read_only_hints_pick_the_token() {
    assert_eq!(call_repo(&json!({"owner": "o", "repo": "r"})).as_deref(), Some("o/r"));
    assert_eq!(call_repo(&json!({"owner": "o/../x", "repo": "r"})), None);
    assert_eq!(call_repo(&json!({"repo": "r"})), None);
    let hints = read_only_hints(&json!({"tools": [
        {"name": "a", "annotations": {"readOnlyHint": true}}, {"name": "b"}]}));
    assert!(read_only(&hints, "a"));
    assert!(!read_only(&hints, "b"), "no hint: the write set");
    assert!(!read_only(&hints, "unknown"), "an unknown tool: the write set");
}

/// Leo, 2026-11-10: when the user isn't connected, the error says exactly how to connect (a GUI
/// action plus the CLI command), and is marked retryable once connected.
#[test]
fn not_connected_says_how_to_connect_and_is_retryable() {
    let r = refusal_result(Some("o/r"), &github_cli::refused("integration.not_found", "x"));
    assert_eq!(r["isError"], true);
    let text = r["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("Connect GitHub"), "{text}");
    assert!(text.contains("`cmux accounts github-connect`"), "{text}");
    let e = &r["structuredContent"]["error"];
    assert_eq!(e["code"], "github.not_connected");
    assert_eq!(e["retryable"], true);
    assert_eq!(e["connect"]["action"], "accounts.githubConnect");
    assert_eq!(e["connect"]["cli"], "cmux accounts github-connect");
    let r = refusal_result(Some("o/r"), &github_cli::refused("needs_reauth", ""));
    assert_eq!(r["structuredContent"]["error"]["code"], "github.not_connected");
    let r = refusal_result(None, &github_cli::refused("integration.unavailable", ""));
    assert_eq!(r["structuredContent"]["error"]["retryable"], true);
    assert!(r["structuredContent"]["error"].get("connect").is_none());
}

#[tokio::test]
async fn calls_reach_github_with_a_one_repo_token_and_none_comes_back() {
    let (origin, seen) = github_server().await;
    let (mint, asks) = recording_mint(Ok(TOKEN));
    let mut bridge =
        Bridge::new(loopback_url(&origin).unwrap(), mint, Some("acme/app".into())).unwrap();
    let list =
        bridge.handle(&json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})).await.unwrap();
    assert_eq!(list["id"], 1);
    assert_eq!(list["result"]["tools"].as_array().unwrap().len(), 2);
    let read = bridge
        .handle(&call(2, "list_pull_requests", json!({"owner": "acme", "repo": "other"})))
        .await
        .unwrap();
    assert_eq!(read["id"], 2);
    let text = read["result"]["content"][0]["text"].as_str().unwrap();
    assert!(!text.contains(TOKEN), "a token GitHub echoes is cut out: {text}");
    bridge.handle(&call(3, "create_issue", json!({"title": "t"}))).await.unwrap();
    let asks = asks.lock().unwrap().clone();
    let shape: Vec<(String, String)> = asks
        .iter()
        .map(|a| (a.repo.clone(), a.permissions["contents"].as_str().unwrap().to_owned()))
        .collect();
    assert_eq!(
        shape,
        [
            ("acme/app".into(), "read".into()),
            ("acme/other".into(), "read".into()),
            ("acme/app".into(), "write".into()),
        ],
        "the list and a read-only tool get the read set; a write tool the write set for the chat's repo"
    );
    let seen = seen.lock().unwrap();
    assert!(seen.iter().all(|(auth, _)| auth.ends_with(&TOKEN.to_ascii_lowercase())));
}

#[tokio::test]
async fn a_call_with_no_connection_is_a_tool_error_with_the_next_step() {
    let (origin, seen) = github_server().await;
    let (mint, _) =
        recording_mint(Err(("integration.not_found", "this team has no GitHub connection")));
    let mut bridge = Bridge::new(loopback_url(&origin).unwrap(), mint, None).unwrap();
    let reply = bridge
        .handle(&call(7, "list_pull_requests", json!({"owner": "acme", "repo": "app"})))
        .await
        .unwrap();
    assert_eq!(reply["result"]["isError"], true);
    assert_eq!(reply["result"]["structuredContent"]["error"]["retryable"], true);
    assert!(seen.lock().unwrap().is_empty(), "nothing goes to GitHub without a token");
    let no_repo = bridge.handle(&call(8, "list_pull_requests", json!({}))).await.unwrap();
    assert!(no_repo["result"]["content"][0]["text"].as_str().unwrap().contains("owner and repo"));
    let list =
        bridge.handle(&json!({"jsonrpc": "2.0", "id": 9, "method": "tools/list"})).await.unwrap();
    assert_eq!(
        list["error"]["code"], -32002,
        "no chat repo: the list fails and is asked again later"
    );
}
