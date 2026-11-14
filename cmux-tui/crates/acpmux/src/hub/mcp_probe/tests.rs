use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// A loopback server that answers 401 unless the request carries `x-test-key: k-secret`, and
/// otherwise answers each request by its id.
async fn keyed_server() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://127.0.0.1:{}/mcp", listener.local_addr().unwrap().port());
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
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
                            let out = if !head.contains("x-test-key: k-secret") {
                                "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n".to_owned()
                            } else if body.get("id").is_none() {
                                "HTTP/1.1 202 Accepted\r\ncontent-length: 0\r\n\r\n".to_owned()
                            } else {
                                let result = if body["method"] == "initialize" {
                                    serde_json::json!({"serverInfo": {"name": "keyed"}})
                                } else {
                                    serde_json::json!({"tools": [{"name": "query_docs"}]})
                                };
                                let b = serde_json::json!({"jsonrpc": "2.0", "id": body["id"], "result": result}).to_string();
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
    url
}

#[tokio::test]
async fn mcp_connect_key_goes_only_in_its_header_and_never_in_the_result() {
    let url = keyed_server().await;
    match probe(&url, None).await {
        Probe::SignIn { .. } => {}
        other => panic!("without the key the server refuses: {other:?}"),
    }
    let got = probe(&url, Some(KeyHeader { name: "x-test-key", value: "k-secret" })).await;
    assert!(!format!("{got:?}").contains("k-secret"), "the key leaked into the result");
    match got {
        Probe::Tools { tools, server } => {
            assert_eq!(tools[0]["name"], "query_docs");
            assert_eq!(server["name"], "keyed");
        }
        other => panic!("with the key the tools list: {other:?}"),
    }
}

#[tokio::test]
async fn mcp_connect_probe_refuses_unsafe_urls_before_any_request() {
    for url in
        ["http://169.254.169.254/mcp", "https://user@example.com/mcp", "http://example.com/mcp"]
    {
        assert!(matches!(probe(url, None).await, Probe::Failed(_)), "{url}");
    }
}
