use super::*;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

/// A daemon whose list is past one reply answers its first page and a `nextCursor`: about
/// 530 of 553 rows on a home with several hundred chats. `cmux agent list` and the platform's
/// shares (`deliver::sessions`) read only that page, so a chat on the next one, live or not,
/// was not in the list.
#[tokio::test]
async fn the_session_list_reads_every_page() {
    let dir = cmux_unix_socket::short_test_dir("deliver-pages");
    let socket = dir.path().join("s");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    // The fake daemon is this test's task: the scope ends it when the test is done.
    let scope = cmux_scope::Scope::new("deliver-pages test");
    scope.spawn_until_cancelled("fake-daemon", async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        while let Some(line) = lines.next_line().await.unwrap() {
            let msg: Value = serde_json::from_str(&line).unwrap();
            let Some(id) = msg.get("id") else { continue };
            let result = match (msg["method"].as_str(), msg["params"]["cursor"].as_str()) {
                (Some(method::MUX_SESSIONS), None) => json!({"nextCursor": "page-2",
                        "sessions": [{"sessionId": "first", "name": "a", "updatedAt": 2}]}),
                (Some(method::MUX_SESSIONS), Some("page-2")) => json!({"nextCursor": null,
                        "sessions": [{"sessionId": "second", "name": "b", "updatedAt": 1}]}),
                _ => json!({}),
            };
            let response = json!({"jsonrpc": "2.0", "id": id, "result": result});
            write.write_all(format!("{response}\n").as_bytes()).await.unwrap();
        }
    });
    let client = Client::connect(&socket).await.unwrap();
    let listed = sessions(&client).await.unwrap();
    let ids: Vec<&str> = listed.iter().filter_map(|s| s["sessionId"].as_str()).collect();
    assert_eq!(ids, ["first", "second"], "a chat on the list's second page was left out");
    let closed = scope.close(std::time::Duration::from_secs(5)).await;
    assert!(closed.joined(), "the fake daemon ignored the end: {closed:?}");
}
