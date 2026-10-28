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
        assert!(remote.resolve(id).is_ok(), "the session belongs to the remote hub");
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
