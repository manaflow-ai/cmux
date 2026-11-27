use super::*;

fn words(words: &[&str]) -> Vec<String> {
    words.iter().map(|s| s.to_string()).collect()
}

#[test]
fn cloud_repo_chat_session_is_not_daemon_routing() {
    let (global, args) = super::super::parse_globals(&words(&[
        "--socket",
        "/tmp/repo-test.sock",
        "cloud",
        "repo",
        "add",
        "--session",
        "chat-1",
        "--repo",
        "cmux-platform",
        "--ref",
        "main",
    ]))
    .unwrap();
    assert_eq!(global.socket.unwrap().to_str(), Some("/tmp/repo-test.sock"));
    assert_eq!(global.session, None);
    assert_eq!(
        parse(&args[2..]).unwrap(),
        ("cloud.repo.add", json!({"session":"chat-1","repo":"cmux-platform","ref":"main"}))
    );
}

#[test]
fn cloud_repo_rejects_mixed_verbs_and_unbounded_waits() {
    assert!(parse(&words(&["list", "--session", "chat", "--repo", "owner/name"])).is_err());
    assert!(parse(&words(&["add", "--repo", "name"])).is_err());
    assert!(parse(&words(&["wait-github", "--session", "chat", "--timeout-ms", "60001"])).is_err());
    assert_eq!(
        parse(&words(&["list", "--session=chat", "--query=name"])).unwrap().1,
        json!({"session":"chat","query":"name"})
    );
}
#[test]
fn cloud_repo_socket_sends_shared_action_and_preserves_recovery() {
    use std::os::unix::net::UnixListener;
    let scratch = tempfile::tempdir().unwrap();
    let socket = scratch.path().join("repo.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let result = json!({"code":"repo.needs_github", "message":"Connect GitHub; this add continues on its own once connected.",
        "install_url":"https://github.com/apps/cmux/installations/new",
        "retry":{"action":"cloud.repo.add","args":{"session":"chat","repo":"project"},"wait_action":"cloud.repo.wait_github"}});
    let response = result.clone();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(
            request,
            json!({"id":"cloud-repo","cmd":"cloud.repo.add","session":"chat","repo":"project"})
        );
        writeln!(reader.get_mut(), "{}", json!({"id":"cloud-repo","ok":true,"data":response}))
            .unwrap();
    });
    let global = GlobalArgs { socket: Some(socket), ..GlobalArgs::default() };
    assert_eq!(
        call(&global, "cloud.repo.add", json!({"session":"chat","repo":"project"})).unwrap(),
        result
    );
    server.join().unwrap();
}
#[test]
fn cloud_repo_catalog_and_attachment_commands_use_the_shared_contract() {
    assert_eq!(parse(&words(&["local"])).unwrap(), ("cloud.repo.local", json!({})));
    assert_eq!(
        parse(&words(&["attached", "--session", "chat"])).unwrap(),
        ("cloud.repo.attached", json!({"session":"chat"}))
    );
    assert_eq!(
        parse(&words(&[
            "sync",
            "--repos-json",
            "[]",
            "--complete",
            "false",
            "--install-url",
            "https://github.com/apps/cmux"
        ]))
        .unwrap(),
        (
            "cloud.repo.sync",
            json!({"repos":[],"complete":false,"install_url":"https://github.com/apps/cmux"})
        )
    );
    for args in [
        words(&["local", "--session", "chat"]),
        words(&["sync", "--repos-json", "{}"]),
        words(&["sync", "--repos-json", "[]", "--complete", "yes"]),
    ] {
        assert!(parse(&args).is_err());
    }
}
#[test]
fn cloud_repo_sync_accepts_recent_array_and_rejects_other_json() {
    assert_eq!(
        parse(&words(&[
            "sync",
            "--repos-json",
            "[]",
            "--recent-json",
            r#"[{"fullName":"o/r","private":true,"source":"recent"}]"#
        ]))
        .unwrap(),
        (
            "cloud.repo.sync",
            json!({"repos":[],"recent":[{"fullName":"o/r","private":true,"source":"recent"}]})
        )
    );
    assert!(parse(&words(&["sync", "--repos-json", "[]", "--recent-json", "{}"])).is_err());
}

#[test]
fn cloud_repo_read_is_sent_again_after_a_broken_connection_but_an_add_is_not() {
    use std::os::unix::net::UnixListener;
    let scratch = tempfile::tempdir().unwrap();
    let socket = scratch.path().join("repo.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut seen = Vec::new();
        // The list's first connection and the add's only one close with no reply.
        for answer in [false, true, false] {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            seen.push(request["cmd"].as_str().unwrap().to_owned());
            if answer {
                let reply = json!({"id":"cloud-repo","ok":true,"data":{"repos":[]}});
                writeln!(reader.get_mut(), "{reply}").unwrap();
            }
        }
        listener.set_nonblocking(true).unwrap();
        assert!(listener.accept().is_err(), "the add was sent once");
        seen
    });
    let global = GlobalArgs { socket: Some(socket), ..GlobalArgs::default() };
    assert_eq!(
        call(&global, "cloud.repo.list", json!({"session":"chat"})).unwrap(),
        json!({"repos":[]})
    );
    let failure =
        call(&global, "cloud.repo.add", json!({"session":"chat","repo":"project"})).unwrap_err();
    assert!(matches!(failure.kind, FailureKind::InProgress));
    let message = failure.error["message"].as_str().unwrap();
    assert!(message.contains("resumes that clone"), "{message}");
    assert!(!message.to_ascii_lowercase().contains("retry"), "{message}");
    assert_eq!(server.join().unwrap(), ["cloud.repo.list", "cloud.repo.list", "cloud.repo.add"]);
}
