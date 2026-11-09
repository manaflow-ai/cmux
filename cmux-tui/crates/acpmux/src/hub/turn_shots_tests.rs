use super::*;
#[cfg(unix)]
use std::os::unix::net::UnixListener;

/// A 1x1 PNG of one colour: fixtures for a before and an after.
fn png(red: u8) -> Vec<u8> {
    let mut bytes = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut bytes, 1, 1);
        encoder.set_color(png::ColorType::Rgb);
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(&[red, 0, 0]).unwrap();
    }
    bytes
}

/// A browser host that answers one `browser.repl.eval`: it writes `picture` (when some) where the
/// cell says and prints the marker, as the REPL's `screenshot(page, {path})` does. Returns the
/// request it got.
#[cfg(unix)]
fn fake_host(socket: &Path, picture: Option<Vec<u8>>) -> std::thread::JoinHandle<Value> {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        let code = request["params"]["code"].as_str().unwrap();
        let output = match &picture {
            Some(bytes) => {
                let path = code.split("path: \"").nth(1).unwrap().split('"').next().unwrap();
                std::fs::write(path, bytes).unwrap();
                "TURN_SHOT {\"url\":\"http://127.0.0.1:5173/\"}\n"
            }
            None => "",
        };
        let reply = json!({"id": request["id"], "result": {"output": output, "error": null}});
        let mut out = stream;
        writeln!(out, "{reply}").unwrap();
        request
    })
}

#[test]
fn ids_are_one_path_segment() {
    assert_eq!(segment("ses_01-a_b"), Some("ses_01-a_b"));
    for bad in ["", "..", "a/b", "a b", "x\0"] {
        assert_eq!(segment(bad), None, "{bad:?}");
    }
    assert!(turn_dir(Path::new("/r"), "s", "../t").is_none());
}

#[test]
fn a_workspace_id_compares_as_uuid_or_public_id() {
    let uuid = "1A2B3C4D-0000-4000-8000-00000000ABCD";
    assert_eq!(workspace_key(uuid), workspace_key("ws_1a2b3c4d00004000800000000000abcd"));
    assert_ne!(workspace_key(uuid), workspace_key("ws_ffff"));
}

#[test]
fn the_cell_names_the_workspace_and_out_path_as_json_strings() {
    let code = capture_code("ws_\"x", Path::new("/tmp/a\"b/before.png"));
    assert!(code.contains(r#"=== "\"x""#), "{code}");
    assert!(code.contains(r#"path: "/tmp/a\"b/before.png""#), "{code}");
    // Only a selected live web page: a hibernated tab is never woken for a picture.
    assert!(code.contains(r#"t.state === "live""#) && code.contains("t.active"), "{code}");
    // Only tabs agents drive already: touching one the person alone used would rebuild its page.
    assert!(code.contains("tabs.list()") && !code.contains("all:"), "{code}");
}

#[cfg(unix)]
#[test]
fn a_capture_writes_the_page_through_the_hosts_repl() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("bh.sock");
    let host = fake_host(&socket, Some(png(1)));
    let out = dir.path().join("before.png");
    assert!(capture(&socket, dir.path(), "ws_ab", &out));
    let request = host.join().unwrap();
    assert_eq!(request["method"], "browser.repl.eval");
    // The app's tabs only: never a headless browser started for a picture.
    assert_eq!(request["params"]["engine"], "cef");
    assert_eq!(request["params"]["session"], REPL_SESSION);
    assert_eq!(std::fs::read(&out).unwrap(), png(1));
}

#[cfg(unix)]
#[test]
fn no_page_or_no_host_takes_no_picture() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("bh.sock");
    let out = dir.path().join("before.png");
    assert!(!capture(&socket, dir.path(), "ws_ab", &out), "no host listens");
    let host = fake_host(&socket, None);
    assert!(!capture(&socket, dir.path(), "ws_ab", &out), "the workspace shows no page");
    host.join().unwrap();
    assert!(!out.exists());
}

#[cfg(unix)]
#[test]
fn a_picture_over_the_cap_is_not_kept() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("bh.sock");
    let host = fake_host(&socket, Some(vec![1; MAX_SHOT_BYTES + 1]));
    let out = dir.path().join("after.png");
    assert!(!capture(&socket, dir.path(), "ws_ab", &out));
    host.join().unwrap();
    assert!(!out.exists(), "the disk cap holds");
}

#[test]
fn a_pair_is_kept_only_when_the_page_changed() {
    let base = tempfile::tempdir().unwrap();
    let chat = base.path().join("s1");
    let same = chat.join("t1");
    let changed = chat.join("t2");
    for (dir, after) in [(&same, png(1)), (&changed, png(2))] {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join(BEFORE), png(1)).unwrap();
        std::fs::write(dir.join(AFTER), after).unwrap();
    }
    settle(base.path(), &chat, &same);
    settle(base.path(), &chat, &changed);
    assert!(!same.exists());
    assert!(changed.join(BEFORE).exists() && changed.join(AFTER).exists());
    // A turn with no after (its capture failed) keeps nothing.
    let lone = chat.join("t3");
    std::fs::create_dir_all(&lone).unwrap();
    std::fs::write(lone.join(BEFORE), png(1)).unwrap();
    settle(base.path(), &chat, &lone);
    assert!(!lone.exists());
}

#[test]
fn a_chat_keeps_its_newest_turns_only() {
    let base = tempfile::tempdir().unwrap();
    let chat = base.path().join("s1");
    let start = std::time::SystemTime::now() - Duration::from_secs(3600);
    for n in 0..KEEP_TURNS + 3 {
        let dir = chat.join(format!("t{n}"));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(BEFORE), png(1)).unwrap();
        std::fs::write(dir.join(AFTER), png(2)).unwrap();
        let at = start + Duration::from_secs(n as u64);
        std::fs::File::open(&dir).unwrap().set_modified(at).unwrap();
    }
    prune(&chat, KEEP_TURNS);
    let mut left: Vec<String> = std::fs::read_dir(&chat)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    let mut newest: Vec<String> = (3..KEEP_TURNS + 3).map(|n| format!("t{n}")).collect();
    newest.sort();
    assert_eq!(left, newest);
}

#[tokio::test]
async fn a_read_waits_only_on_a_settled_turns_pair() {
    let key = ("turn-shots-test-unsettled".to_owned(), "t1".to_owned());
    let (phase, _) = watch::channel(Phase::Ready);
    PENDING
        .lock()
        .unwrap()
        .insert(key.clone(), Pending { workspace: "ws_ab".into(), phase, ended: false });
    // A turn that failed before its result never gets an after: the read answers at once.
    let read = tokio::time::timeout(Duration::from_secs(2), turn_shots(&key.0, &key.1)).await;
    assert!(read.is_ok_and(|reply| reply.get("after").is_none()));
    finish(&key);
}

#[tokio::test(start_paused = true)]
async fn a_pair_still_being_taken_reads_as_pending_not_as_none() {
    let key = ("turn-shots-test-pending".to_owned(), "t1".to_owned());
    let (phase, _) = watch::channel(Phase::Ready);
    PENDING
        .lock()
        .unwrap()
        .insert(key.clone(), Pending { workspace: "ws_ab".into(), phase, ended: true });
    let reply = turn_shots(&key.0, &key.1).await;
    assert_eq!(reply.get("pending"), Some(&json!(true)));
    assert!(reply.get("after").is_none());
    finish(&key);
}
