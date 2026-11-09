#![cfg(unix)]
//! How many WireGuard keys and UDP sockets one Mac runs: the cmux link (the
//! real `cmux link serve`, as the app starts it with `--key-lock-dir` set to
//! its acpmux home) and acpmux's Labs WireGuard transport, on one machine
//! that joined (its acpmux home has `node.wg.key`) and set up its link.
//!
//! The same test runs on the base and on the change; it prints one line per
//! case, then checks the one-key target.

use std::io::{BufRead as _, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::key_holder::KeyFile;

struct Serving(Child);

impl Drop for Serving {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn cmux(root: &Path, args: &[&str]) -> Command {
    use std::os::unix::process::CommandExt as _;
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .arg0("cmux")
        .args(args)
        .env_clear()
        .env("HOME", root)
        .env("TMPDIR", root)
        .env("CMUX_TUI_STATE_DIR", root.join("state"))
        .stdin(Stdio::null())
        .current_dir(root);
    command
}

/// The distinct WireGuard private keys on disk in the acpmux home and the link's state dir.
fn keys_on_disk(home: &Path, link: &Path) -> usize {
    let mut publics = std::collections::BTreeSet::new();
    if let Ok(node) = std::fs::read(KeyFile::Node.path_in(home)) {
        publics.insert(node);
    }
    if let Ok(text) = std::fs::read_to_string(KeyFile::Link.path_in(link)) {
        publics.insert(STANDARD.decode(text.trim()).unwrap());
    }
    publics.len()
}

#[tokio::test]
async fn one_mac_runs_one_wireguard_key_and_one_udp_socket() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("acpmux");
    let link = root.path().join("state/link");
    // A joined Mac: acpmux made its node key (the platform knows its public half).
    acpmux::cli::mesh_node_key::load_or_create_at(&home).unwrap();
    let init = cmux(
        root.path(),
        &[
            "link",
            "init",
            "--state-dir",
            link.to_str().unwrap(),
            "--install",
            "inst_a",
            "--port",
            "0",
        ],
    )
    .output()
    .unwrap();
    assert!(init.status.success(), "{}", String::from_utf8_lossy(&init.stderr));

    let mut serve = cmux(
        root.path(),
        &[
            "link",
            "serve",
            "--state-dir",
            link.to_str().unwrap(),
            "--key-lock-dir",
            home.to_str().unwrap(),
        ],
    );
    serve.stdout(Stdio::piped()).stderr(Stdio::null());
    let mut serving = Serving(serve.spawn().unwrap());
    let stdout = serving.0.stdout.take().unwrap();
    let ready = tokio::time::timeout(
        std::time::Duration::from_secs(60),
        tokio::task::spawn_blocking(move || {
            BufReader::new(stdout)
                .lines()
                .map_while(Result::ok)
                .find(|line| line.contains("\"link-ready\""))
        }),
    )
    .await
    .expect("the link was not ready in 60 s")
    .unwrap()
    .expect("the link exited before it was ready");
    let ready: serde_json::Value = serde_json::from_str(&ready).unwrap();
    let link_sockets = usize::from(ready["udp"].is_string());

    let mut counted = Vec::new();
    for labs in [false, true] {
        let mut config = acpmux::config::Config::default();
        config.transport.wireguard = labs;
        config.transport.wireguard_static = Some(acpmux::wireguard::StaticConfig {
            listen: "127.0.0.1:0".parse().unwrap(),
            address: "10.77.0.1:4100".parse().unwrap(),
        });
        let transport = acpmux::wireguard::Transport::start_with_link(
            &config,
            &home,
            Some(&link),
            "127.0.0.1:1".parse().unwrap(),
        )
        .await
        .unwrap();
        let keys = keys_on_disk(&home, &link);
        let sockets = link_sockets + usize::from(transport.is_some());
        println!("wg-keys-per-mac labs_wireguard={labs} keys={keys} udp_sockets={sockets}");
        if let Some(transport) = transport {
            transport.shutdown(tokio::time::Instant::now()).await;
        }
        counted.push((labs, keys, sockets));
    }
    // Both cases print before any check, so the same test gives the base's numbers too.
    for (labs, keys, sockets) in counted {
        assert_eq!((keys, sockets), (1, 1), "labs_wireguard={labs}");
    }
}
