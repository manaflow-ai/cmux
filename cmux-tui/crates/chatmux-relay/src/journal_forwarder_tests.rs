use super::*;

#[cfg(unix)]
static NEXT_CURSOR_TEST_ID: AtomicU64 = AtomicU64::new(1);

#[cfg(unix)]
async fn cursor_test_path(label: &str) -> (PathBuf, PathBuf) {
    let id = NEXT_CURSOR_TEST_ID.fetch_add(1, Ordering::Relaxed);
    let root = std::env::temp_dir()
        .join(format!("chatmux-relay-cursor-{label}-{}-{id}", std::process::id()));
    tokio::fs::create_dir(&root).await.expect("create cursor test directory");
    (root.clone(), root.join("cursors.json"))
}

#[cfg(unix)]
async fn remove_cursor_test_path(root: &Path) {
    tokio::fs::remove_dir_all(root).await.expect("remove cursor test directory");
}

fn cursor(generation: &str, revision: &str) -> JournalCursor {
    JournalCursor { generation: generation.to_owned(), revision: revision.to_owned() }
}

fn record(generation: &str, revision: &str) -> Value {
    json!({
        "type": "stream_item",
        "sequence": revision,
        "cursor": {"generation": generation, "revision": revision},
    })
}

#[cfg(unix)]
#[tokio::test]
async fn hashed_socket_stem_is_opaque_and_session_name_is_omitted() {
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;

    let root = PathBuf::from("/tmp/cmh");
    let _ = tokio::fs::remove_dir_all(&root).await;
    let hashed = root.join("cmux-tui-hashed-501");
    tokio::fs::create_dir_all(&hashed).await.expect("hashed directory");
    tokio::fs::set_permissions(&hashed, std::fs::Permissions::from_mode(0o700))
        .await
        .expect("hashed directory permissions");
    let stem = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    let listener =
        UnixListener::bind(hashed.join(format!("{stem}.sock"))).expect("hashed socket entry");

    let candidates = discover_session_candidates(std::slice::from_ref(&hashed)).await;
    assert_eq!(candidates.len(), 1);
    let candidate = &candidates[0];
    assert!(candidate.session_name.is_none());
    assert_eq!(candidate.key, opaque_session_key(stem));
    assert!(candidate.socket_paths.iter().all(|path| path.starts_with(&hashed)));

    let batches = batch_records(&[PendingSession {
        session_name: candidate.key.clone(),
        cursor_key: "legacy name".to_owned(),
        generation: Some("generation".to_owned()),
        records: vec![record("generation", "1")],
    }]);
    assert_eq!(batches.len(), 1);
    assert_eq!(batches[0].cursor_key, "legacy name");
    let body = serde_json::to_value(json!({"sessions": batches})).expect("batch JSON");
    assert!(body["sessions"][0].get("sessionName").is_none());
    let cursors = advance_cursors(
        &HashMap::new(),
        &batch_records(&[PendingSession {
            session_name: candidate.key.clone(),
            cursor_key: "legacy name".to_owned(),
            generation: Some("generation".to_owned()),
            records: vec![record("generation", "1")],
        }]),
        &HashMap::from([(String::from("generation"), cursor("generation", "1"))]),
    );
    assert_eq!(cursors.get("legacy name"), Some(&cursor("generation", "1")));
    assert!(!cursors.contains_key(&candidate.key));

    drop(listener);
    tokio::fs::remove_dir_all(root).await.expect("remove hashed fixture");
}

#[cfg(unix)]
#[tokio::test]
async fn discovery_rejects_insecure_roots_and_symlink_entries() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::os::unix::net::UnixListener;

    let root = PathBuf::from(format!("/tmp/cms-{}", std::process::id()));
    let _ = tokio::fs::remove_dir_all(&root).await;
    let insecure = root.join("insecure");
    tokio::fs::create_dir_all(&insecure).await.expect("insecure directory");
    tokio::fs::set_permissions(&insecure, std::fs::Permissions::from_mode(0o755))
        .await
        .expect("insecure permissions");
    let listener = UnixListener::bind(insecure.join("main.sock")).expect("socket");
    assert!(discover_session_candidates(std::slice::from_ref(&insecure)).await.is_empty());
    drop(listener);
    let _ = tokio::fs::remove_file(insecure.join("main.sock")).await;

    tokio::fs::set_permissions(&insecure, std::fs::Permissions::from_mode(0o700))
        .await
        .expect("private permissions");
    let target = insecure.join("target.sock");
    let target_listener = UnixListener::bind(&target).expect("target socket");
    symlink(&target, insecure.join("alias.sock")).expect("socket symlink");
    let candidates = discover_session_candidates(std::slice::from_ref(&insecure)).await;
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].key, "target");

    drop(target_listener);
    tokio::fs::remove_dir_all(root).await.expect("remove insecure fixture");
}

#[test]
fn delivery_status_boundaries_preserve_retry_and_stop_policy() {
    assert_eq!(delivery_disposition(200, 100), DeliveryDisposition::Ack);
    assert_eq!(delivery_disposition(204, 1), DeliveryDisposition::Ack);
    assert_eq!(delivery_disposition(413, 100), DeliveryDisposition::Split);
    // A single record cannot be split. The caller drops it after the
    // backend rejects it, matching the Node forwarder boundary.
    assert_eq!(delivery_disposition(413, 1), DeliveryDisposition::Drop);
    assert_eq!(delivery_disposition(410, 1), DeliveryDisposition::Stop);
    assert_eq!(delivery_disposition(401, 1), DeliveryDisposition::Retry);
    assert_eq!(delivery_disposition(503, 1), DeliveryDisposition::Retry);
}

#[cfg(unix)]
#[tokio::test]
async fn stalled_http_request_respects_the_configured_timeout() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let listener =
        tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.expect("bind local test endpoint");
    let address = listener.local_addr().expect("read local test endpoint address");
    let server = tokio::spawn(async move {
        let Ok((mut stream, _)) = listener.accept().await else { return };
        let mut request = [0_u8; 1024];
        let _ = tokio::io::AsyncReadExt::read(&mut stream, &mut request).await;
        tokio::time::sleep(Duration::from_secs(1)).await;
    });
    let client = build_http_client(Duration::from_millis(50)).expect("build test client");
    let started = std::time::Instant::now();
    let result = client.get(format!("http://{address}")).send().await;
    assert!(result.is_err(), "a stalled endpoint must time out");
    assert!(started.elapsed() < Duration::from_millis(500));
    server.abort();
}

#[cfg(unix)]
fn test_shared(url: String, cursor_path: PathBuf) -> (Shared, Arc<tokio::sync::Notify>) {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let flush_wake = Arc::new(tokio::sync::Notify::new());
    let wake = Arc::clone(&flush_wake);
    let shared = Shared {
        events: ManagedEvents { url, token: String::from("test-token") },
        client: build_http_client(Duration::from_secs(5)).expect("build test client"),
        cursors: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
        cursor_path: Some(cursor_path),
        cancellation: CancellationToken::new(),
        claims: Arc::new(Mutex::new(HashSet::new())),
        pool: Arc::new(Mutex::new(PoolState::default())),
        flush_wake,
    };
    (shared, wake)
}

#[cfg(unix)]
fn http_request_body(buffer: &[u8]) -> Option<Vec<u8>> {
    let header_end = buffer.windows(4).position(|window| window == b"\r\n\r\n")? + 4;
    let headers = std::str::from_utf8(&buffer[..header_end]).ok()?;
    let length = headers.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        if !name.eq_ignore_ascii_case("content-length") {
            return None;
        }
        value.trim().parse().ok()
    })?;
    Some(buffer.get(header_end..header_end.checked_add(length)?)?.to_vec())
}

#[cfg(unix)]
#[tokio::test]
async fn pooled_threshold_drains_an_exact_batch_and_defers_while_posting() {
    let (root, path) = cursor_test_path("pool-threshold").await;
    let (shared, wake) = test_shared(String::from("http://127.0.0.1:9"), path);
    let gen_a = Some(String::from("gen_a"));
    let gen_b = Some(String::from("gen_b"));
    for seq in 1..MAX_BATCH_RECORDS {
        enqueue_pending(&shared, "alpha", "alpha", &gen_a, record("gen_a", &seq.to_string()));
    }
    enqueue_pending(&shared, "beta", "beta", &gen_b, record("gen_b", "1"));
    tokio::time::timeout(Duration::from_millis(100), wake.notified())
        .await
        .expect("threshold records must wake the flusher");
    let sessions = {
        let pool = shared.pool.lock().expect("lock pool");
        pool.ready.clone().expect("threshold batch")
    };
    assert_eq!(sessions.len(), 2, "both sessions share the threshold POST");
    assert_eq!(sessions[0].session_name, "alpha");
    assert_eq!(sessions[0].records.len(), MAX_BATCH_RECORDS - 1);
    assert_eq!(sessions[1].session_name, "beta");
    assert_eq!(sessions[1].records.len(), 1);
    {
        let pool = shared.pool.lock().expect("lock pool");
        assert!(pool.pending.is_empty(), "the threshold snapshot is synchronous");
        assert!(pool.flushing);
    }
    // While the POST is in flight, another threshold hit only defers.
    for seq in 2..=(MAX_BATCH_RECORDS + 1) {
        enqueue_pending(&shared, "beta", "beta", &gen_b, record("gen_b", &seq.to_string()));
    }
    assert!(
        tokio::time::timeout(Duration::from_millis(10), wake.notified()).await.is_err(),
        "an in-flight POST defers the next flush without another wake"
    );
    // Block scope, not drop(): clippy's await_holding_lock reasons
    // about lexical scope, so an explicit drop before the await still
    // trips it (rust-clippy#6446).
    {
        let pool = shared.pool.lock().expect("lock pool");
        assert!(pool.flush_again);
        let total = pool.pending.iter().map(|entry| entry.records.len()).sum::<usize>();
        assert_eq!(total, MAX_BATCH_RECORDS);
    }
    remove_cursor_test_path(&root).await;
}

#[cfg(unix)]
#[tokio::test]
async fn pooled_flush_posts_two_sessions_in_one_body_and_acks_each_cursor() {
    let listener =
        tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.expect("bind pooled ack endpoint");
    let address = listener.local_addr().expect("read pooled ack endpoint address");
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.expect("accept pooled POST");
        let mut buffer = Vec::new();
        let body = loop {
            let mut chunk = [0_u8; 4096];
            let read = tokio::io::AsyncReadExt::read(&mut stream, &mut chunk)
                .await
                .expect("read pooled POST");
            assert!(read > 0, "connection closed before one full POST");
            buffer.extend_from_slice(&chunk[..read]);
            if let Some(body) = http_request_body(&buffer) {
                break body;
            }
        };
        let ack = json!({
            "cursors": {
                "gen_a": {"generation": "gen_a", "revision": "2"},
                "gen_b": {"generation": "gen_b", "revision": "3"},
            },
        })
        .to_string();
        let response = format!(
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{ack}",
            ack.len()
        );
        tokio::io::AsyncWriteExt::write_all(&mut stream, response.as_bytes())
            .await
            .expect("write pooled ack");
        let _ = tokio::io::AsyncWriteExt::shutdown(&mut stream).await;
        body
    });

    let (root, path) = cursor_test_path("pooled").await;
    let (shared, _cues) = test_shared(format!("http://{address}"), path);
    let gen_a = Some(String::from("gen_a"));
    let gen_b = Some(String::from("gen_b"));
    enqueue_pending(&shared, "alpha", "alpha", &gen_a, record("gen_a", "1"));
    enqueue_pending(&shared, "alpha", "alpha", &gen_a, record("gen_a", "2"));
    enqueue_pending(&shared, "beta", "beta", &gen_b, record("gen_b", "3"));
    let mut armed = false;
    let mut timer = Box::pin(tokio::time::sleep(Duration::from_secs(60)));
    assert!(flush_cycle(&shared, None, &mut armed, &mut timer).await);

    let body = server.await.expect("pooled ack server");
    let posted = serde_json::from_slice::<Value>(&body).expect("posted JSON body");
    let sessions = posted["sessions"].as_array().expect("sessions array");
    assert_eq!(sessions.len(), 2, "two sessions must share one POST");
    assert_eq!(sessions[0]["sessionName"], "alpha");
    assert_eq!(sessions[0]["sessionId"], "gen_a");
    assert_eq!(sessions[0]["records"].as_array().map(|records| records.len()), Some(2));
    assert_eq!(sessions[1]["sessionName"], "beta");
    assert_eq!(sessions[1]["records"].as_array().map(|records| records.len()), Some(1));
    let cursors = shared.cursors.lock().await;
    assert_eq!(cursors.get("alpha"), Some(&cursor("gen_a", "2")));
    assert_eq!(cursors.get("beta"), Some(&cursor("gen_b", "3")));
    drop(cursors);
    // Block scope, not drop(): see the await_holding_lock note above.
    {
        let pool = shared.pool.lock().expect("lock pool");
        assert!(pool.pending.is_empty());
        assert!(!pool.flushing);
    }
    remove_cursor_test_path(&root).await;
}
