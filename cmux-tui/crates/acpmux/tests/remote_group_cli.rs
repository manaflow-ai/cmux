//! A remote CLI launch opens its mirrored ID in a group on the invoking machine.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::method;
use acpmux::server::{WsAuth, bind_unix, bind_ws, peer_auth::PeerAuth, serve_unix, serve_ws_with};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

fn hub(root: &Path) -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
        "webRoots": [root],
        "webAskingModes": {"fake": ["normal", "strict"]},
    })).unwrap();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, root).unwrap();
    Hub::new(config, store)
}

#[tokio::test]
async fn remote_group_cli_opens_the_remote_id_locally_and_reuses_its_row() {
    let root = std::env::temp_dir().join(format!("amx-grp-{}", std::process::id()));
    std::fs::create_dir_all(root.join("bin")).unwrap();
    let root = std::fs::canonicalize(root).unwrap();
    let local = hub(&root);
    let mut remotes = Vec::new();
    let mut remote_servers = Vec::new();
    for peer in ["remote", "other"] {
        let remote = hub(&root);
        let auth = PeerAuth::create(&root.join(peer)).unwrap();
        let token =
            std::fs::read_to_string(acpmux::server::peer_auth::token_path(&root.join(peer)))
                .unwrap();
        let listener = bind_ws("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let remote_server = tokio::spawn(serve_ws_with(
            remote.clone(),
            listener,
            "test-token".into(),
            WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
        ));
        local
            .add_peer(
                peer,
                &format!("ws://127.0.0.1:{port}"),
                Some("test-token".into()),
                Some(token),
                true,
            )
            .await
            .unwrap();
        remotes.push(remote);
        remote_servers.push(remote_server);
    }
    let socket = root.join("a.sock");
    let listener = bind_unix(&socket).await.unwrap();
    let local_server = tokio::spawn(serve_unix(local.clone(), listener));

    // Stand in only for the Mac app's CLI; daemon, peer, launcher and harness are real paths.
    let cmux = root.join("bin/cmux");
    std::fs::write(&cmux, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$GROUP_CAPTURE\"\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut previous = None;
    let mut unnamed = None;
    for (attempt, (peer, named)) in
        [("remote", false), ("other", false), ("remote", true), ("remote", true)]
            .into_iter()
            .enumerate()
    {
        let capture = root.join(format!("opened-{attempt}"));
        let mut command = daemon_env::tokio_command(&root, daemon_env::Agents::StandIn);
        command
            .env("ACPMUX_SOCKET", &socket)
            .env("PATH", root.join("bin"))
            .env("GROUP_CAPTURE", &capture)
            .current_dir(&root)
            .args(["new", "--host", peer, "-m", "fake", "--group", "Remote demo", "-d"]);
        if named {
            command.args(["--name", "demo", "--reuse"]);
        }
        let output =
            tokio::time::timeout(Duration::from_secs(20), command.kill_on_drop(true).output())
                .await
                .unwrap()
                .unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let opened = std::fs::read_to_string(&capture).expect("cmux ran on the controller");
        let args: Vec<_> = opened.lines().collect();
        assert_eq!(&args[..2], &["agent", "open"]);
        let key_index = if named {
            assert_eq!(args.len(), 9, "{opened}");
            assert_eq!(&args[3..5], &["--name", "demo"]);
            5
        } else {
            // A generated name can be identical on two peers. Omitting --name
            // bypasses the app's title-based predecessor-row reuse.
            assert_eq!(args.len(), 7, "{opened}");
            assert!(!args.contains(&"--name"), "{opened}");
            3
        };
        assert_eq!(&args[key_index + 2..], &["--group", "Remote demo"]);
        assert_eq!(args[key_index], "--key");
        assert!(uuid::Uuid::parse_str(args[key_index + 1]).is_ok());
        let id = args[2];
        let remote = &remotes[usize::from(peer == "other")];
        let raw_id = id.strip_prefix(&format!("{peer}/")).expect("the group keeps its peer route");
        assert!(remote.resolve(raw_id).is_ok(), "the session belongs to the remote hub");
        assert!(local.resolve(id).is_err(), "no local agent was created");
        // The ID handed to cmux is usable through the controller daemon, without --host.
        let client = acpmux::client::Client::connect(&socket).await.unwrap();
        let info: Value = client.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
        assert_eq!(info["peer"], peer);
        if !named {
            if let Some((prior_id, prior_name, prior_key)) = &unnamed {
                assert_ne!(id, prior_id);
                assert_eq!(&info["name"], prior_name);
                assert_ne!(args[key_index + 1], prior_key);
            }
            unnamed = Some((id.to_owned(), info["name"].clone(), args[key_index + 1].to_owned()));
        }
        if named {
            if let Some(ref prior) = previous {
                assert_eq!(&opened, prior);
            }
            previous = Some(opened);
        }
    }
    for remote in remotes {
        remote.end_agents_at_shutdown(Default::default()).unwrap();
        remote.shutdown_all().await;
    }
    local_server.abort();
    for server in remote_servers {
        server.abort();
    }
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn grouped_open_failure_reports_retry_and_keeps_first_prompt() {
    let root = std::env::temp_dir().join(format!("amx-grp-fail-{}", std::process::id()));
    std::fs::create_dir_all(root.join("empty")).unwrap();
    let root = std::fs::canonicalize(root).unwrap();
    let local = hub(&root);
    let socket = root.join("a.sock");
    let listener = bind_unix(&socket).await.unwrap();
    let local_server = tokio::spawn(serve_unix(local.clone(), listener));

    let cmux = root.join("empty/cmux");
    for (name, flags) in [
        ("missing", vec!["-d"]),
        ("failed-stream", vec![]),
        ("failed-quiet", vec!["--quiet"]),
        ("failed-ephemeral", vec!["--ephemeral"]),
    ] {
        if name != "missing" {
            std::fs::write(&cmux, "#!/bin/sh\necho 'no reachable app' >&2\nexit 7\n").unwrap();
            std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let mut command = daemon_env::tokio_command(&root, daemon_env::Agents::StandIn);
        command
            .env("ACPMUX_SOCKET", &socket)
            .env("PATH", root.join("empty"))
            .current_dir(&root)
            .args(["new", "-m", "fake", "--name", name, "--group", "remote-audit"])
            .args(flags)
            .arg("do it");
        let output =
            tokio::time::timeout(Duration::from_secs(20), command.kill_on_drop(true).output())
                .await
                .unwrap()
                .unwrap();
        assert!(!output.status.success(), "group open must fail without the app: {name}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(&format!("session {name} was created")), "{stderr}");
        assert!(stderr.contains("cmux agent open"), "{stderr}");
        assert!(stderr.contains("--group remote-audit"), "{stderr}");
        if name != "missing" {
            assert!(stderr.contains("no reachable app"), "{stderr}");
        }
        assert!(!stderr.contains("first prompt was not confirmed"), "{stderr}");
        let session = local.resolve(name).expect("failed open keeps session");
        assert!(stderr.contains(&session.id), "retry names the exact session: {stderr}");
        let summary = local.session_summary(&session);
        assert!(
            summary["queued"].as_u64().unwrap_or(0) >= 1
                || summary["turnCount"].as_u64().unwrap_or(0) >= 1,
            "first prompt was not accepted: {summary}"
        );
    }

    // A successful grouped ephemeral run still follows the normal cleanup
    // path after its reply; only the failed app-open path is retained.
    let cmux = root.join("empty/cmux");
    std::fs::write(&cmux, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut ephemeral = daemon_env::tokio_command(&root, daemon_env::Agents::StandIn);
    ephemeral
        .env("ACPMUX_SOCKET", &socket)
        .env("PATH", root.join("empty"))
        .current_dir(&root)
        .args([
            "new",
            "-m",
            "fake",
            "--name",
            "ephemeral-group",
            "--group",
            "remote-audit",
            "--ephemeral",
            "--quiet",
            "do it",
        ]);
    let success =
        tokio::time::timeout(Duration::from_secs(20), ephemeral.kill_on_drop(true).output())
            .await
            .unwrap()
            .unwrap();
    assert!(success.status.success(), "{}", String::from_utf8_lossy(&success.stderr));
    assert!(local.resolve("ephemeral-group").is_err(), "successful ephemeral run was retained");

    local.end_agents_at_shutdown(Default::default()).unwrap();
    local.shutdown_all().await;
    local_server.abort();
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn detached_group_open_interruption_still_queues_first_prompt() {
    let root = std::env::temp_dir().join(format!("amx-grp-interrupt-{}", std::process::id()));
    std::fs::create_dir_all(root.join("bin")).unwrap();
    let root = std::fs::canonicalize(root).unwrap();
    let local = hub(&root);
    let socket = root.join("a.sock");
    let listener = bind_unix(&socket).await.unwrap();
    let server = tokio::spawn(serve_unix(local.clone(), listener));

    // The app hop kills its parent CLI before it can return. The CLI must
    // queue the first prompt before attempting the synchronous app open.
    let cmux = root.join("bin/cmux");
    std::fs::write(&cmux, "#!/bin/sh\nkill -TERM \"$PPID\"\nexit 0\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut command = daemon_env::tokio_command(&root, daemon_env::Agents::StandIn);
    command
        .env("ACPMUX_SOCKET", &socket)
        .env("PATH", root.join("bin"))
        .current_dir(&root)
        .args([
            "new",
            "-m",
            "fake",
            "--name",
            "detached-interruption",
            "--group",
            "remote-audit",
            "-d",
            "do it",
        ])
        .kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(5), command.output())
        .await
        .expect("interrupted grouped launch hung")
        .expect("interrupted grouped launch could not run");
    assert!(!output.status.success(), "the app hop terminated the CLI");

    let session = local
        .resolve("detached-interruption")
        .expect("session survives an interrupted grouped launch");
    let summary = local.session_summary(&session);
    assert!(
        summary["queued"].as_u64().unwrap_or(0) >= 1
            || summary["turnCount"].as_u64().unwrap_or(0) >= 1,
        "first prompt was lost when the app open was interrupted: {summary}"
    );
    local.end_agents_at_shutdown(Default::default()).unwrap();
    local.shutdown_all().await;
    server.abort();
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn grouped_detached_prompt_flags_submit_once() {
    let root = std::env::temp_dir().join(format!("amx-grp-once-{}", std::process::id()));
    std::fs::create_dir_all(root.join("bin")).unwrap();
    let root = std::fs::canonicalize(root).unwrap();
    let local = hub(&root);
    let socket = root.join("a.sock");
    let listener = bind_unix(&socket).await.unwrap();
    let server = tokio::spawn(serve_unix(local.clone(), listener));
    let cmux = root.join("bin/cmux");
    std::fs::write(&cmux, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o700)).unwrap();
    let path = format!("{}:{}", root.join("bin").display(), daemon_env::bare_path(&[]));

    for (name, flags, json_output, ephemeral) in [
        ("grouped-quiet", vec!["--quiet"], false, false),
        ("grouped-json", vec![], true, false),
        ("grouped-ephemeral", vec!["--ephemeral"], false, true),
        ("grouped-ephemeral-quiet", vec!["--ephemeral", "--quiet"], false, true),
    ] {
        let mut events = local.subscribe();
        let mut command = daemon_env::tokio_command(&root, daemon_env::Agents::StandIn);
        command.env("ACPMUX_SOCKET", &socket).env("PATH", &path).current_dir(&root);
        if json_output {
            command.arg("--json");
        }
        command.args(["new", "-m", "fake", "--name", name, "--group", "remote-audit", "-d"]);
        command.args(flags);
        command.arg("do it");
        let output =
            tokio::time::timeout(Duration::from_secs(20), command.kill_on_drop(true).output())
                .await
                .expect("grouped prompt launch hung")
                .expect("grouped prompt launch could not run");
        assert!(output.status.success(), "{name}: {}", String::from_utf8_lossy(&output.stderr));

        let mut records = Vec::new();
        while let Ok(event) = events.try_recv() {
            records.push(event);
        }
        let session_id = records
            .iter()
            .find(|event| event.record.kind == "created" && event.record.msg["harness"] == "fake")
            .map(|event| event.session_id.clone())
            .or_else(|| local.resolve(name).ok().map(|session| session.id.clone()))
            .expect("grouped launch created no session");
        let prompts = records
            .iter()
            .filter(|event| event.session_id == session_id && event.record.kind == "user_message")
            .count();
        assert_eq!(prompts, 1, "{name}: expected one user_message, got {prompts}");
        if ephemeral {
            assert!(local.resolve(&session_id).is_err(), "{name}: ephemeral session remained");
        } else {
            assert!(local.resolve(&session_id).is_ok(), "{name}: durable session disappeared");
        }
    }

    local.end_agents_at_shutdown(Default::default()).unwrap();
    local.shutdown_all().await;
    server.abort();
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn ephemeral_keep_is_limited_to_the_creating_client() {
    let root = std::env::temp_dir().join(format!("amx-keep-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let root = std::fs::canonicalize(root).unwrap();
    let local = hub(&root);
    let socket = root.join("a.sock");
    let listener = bind_unix(&socket).await.unwrap();
    let server = tokio::spawn(serve_unix(local.clone(), listener));
    let owner = acpmux::client::Client::connect(&socket).await.unwrap();
    let other = acpmux::client::Client::connect(&socket).await.unwrap();
    let created = owner
        .request(
            method::SESSION_NEW,
            json!({"cwd": root, "mcpServers": [], "_meta": {"acpmux": {"ephemeral": true, "harness": "fake"}}}),
        )
        .await
        .unwrap();
    let id = created["sessionId"].as_str().unwrap().to_owned();
    let refused = other.request("_acpmux/keep", json!({"sessionId": id})).await;
    assert!(refused.is_err(), "a different client cannot retain an ephemeral session");
    let retained = owner.request("_acpmux/keep", json!({"sessionId": id})).await.unwrap();
    assert_eq!(retained["ephemeral"], false);
    assert!(local.resolve(&id).is_ok(), "the retained session remains available");
    local.end_agents_at_shutdown(Default::default()).unwrap();
    local.shutdown_all().await;
    server.abort();
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn interrupted_grouped_ephemeral_is_purged_after_successful_open() {
    let root = std::env::temp_dir().join(format!("amx-interrupt-{}", std::process::id()));
    std::fs::create_dir_all(root.join("bin")).unwrap();
    let root = std::fs::canonicalize(root).unwrap();
    let local = hub(&root);
    let socket = root.join("a.sock");
    let listener = bind_unix(&socket).await.unwrap();
    let server = tokio::spawn(serve_unix(local.clone(), listener));
    let cmux = root.join("bin/cmux");
    std::fs::write(&cmux, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut child = daemon_env::tokio_command(&root, daemon_env::Agents::StandIn);
    child
        .env("ACPMUX_SOCKET", &socket)
        .env("PATH", root.join("bin"))
        .current_dir(&root)
        .args(["new", "-m", "fake", "--group", "g", "--ephemeral", "until-cancel"])
        .kill_on_drop(true);
    let mut events = local.subscribe();
    let mut process = child.spawn().unwrap();
    let created = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.kind == "turn_started" {
                break event.session_id;
            }
        }
    })
    .await
    .expect("grouped ephemeral turn did not start after opening the app");
    let _ = process.kill().await;
    let _ = process.wait().await;
    let purged = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.kind == "purged" && event.session_id == created {
                break event.session_id;
            }
        }
    })
    .await
    .expect("interrupted grouped ephemeral was not purged");
    assert!(local.resolve(&purged).is_err());
    local.end_agents_at_shutdown(Default::default()).unwrap();
    local.shutdown_all().await;
    server.abort();
    std::fs::remove_dir_all(root).unwrap();
}
