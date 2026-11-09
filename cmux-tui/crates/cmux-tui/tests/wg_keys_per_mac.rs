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

/// `cmux link init` of install `inst_a` in `link`.
fn init(root: &Path, link: &Path) {
    let init = cmux(
        root,
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
}

/// The real `cmux link serve` of `link` under the key lock in the acpmux `home`, as the app
/// starts it, and its ready line once it serves.
async fn serve_until_ready(root: &Path, link: &Path, home: &Path) -> (Serving, serde_json::Value) {
    let mut serve = cmux(
        root,
        &[
            "link",
            "serve",
            "--state-dir",
            link.to_str().unwrap(),
            "--key-lock-dir",
            home.to_str().unwrap(),
        ],
    );
    // The app's acpmux home, as the app resolves it: the link adopts only there.
    serve.env("ACPMUX_HOME", home).stdout(Stdio::piped()).stderr(Stdio::null());
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
    (serving, serde_json::from_str(&ready).unwrap())
}

#[tokio::test]
async fn one_mac_runs_one_wireguard_key_and_one_udp_socket() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("acpmux");
    let link = root.path().join("state/link");
    // A joined Mac: acpmux made its node key (the platform knows its public half).
    acpmux::cli::mesh_node_key::load_or_create_at(&home).unwrap();
    init(root.path(), &link);

    let (_serving, ready) = serve_until_ready(root.path(), &link, &home).await;
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

/// A link the test started through `cmux link ensure`, stopped through `cmux link stop` (by the
/// pid its registration names, after the link proved it serves this state dir).
struct Ensured<'a> {
    root: &'a Path,
    link: &'a Path,
}

impl Drop for Ensured<'_> {
    fn drop(&mut self) {
        let _ =
            cmux(self.root, &["link", "stop", "--state-dir", self.link.to_str().unwrap()]).output();
    }
}

/// Review F1 at c1898fca: a sign-out archives the adoption record with its install
/// (`key-adopted.inst_a.json`). With the link stopped, `machine leave` must still keep the
/// node key that record names: when the install signs in again, its link serves that key to
/// the peers that know it by it alone, never `key_adoption.node_key_missing`.
#[tokio::test]
async fn an_archived_adoption_keeps_its_node_key_through_a_leave_and_serves_it_restored() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("acpmux");
    let link = root.path().join("state/link");
    let node = acpmux::cli::mesh_node_key::load_or_create_at(&home).unwrap().public_key;
    let node_bytes = std::fs::read(KeyFile::Node.path_in(&home)).unwrap();
    init(root.path(), &link);
    // The link adopts the node key, then stops.
    drop(serve_until_ready(root.path(), &link, &home).await);
    assert!(link.join("key-adopted.json").is_file(), "the link did not adopt the node key");

    // Sign-out: the install's record goes into its archive.
    let archive = cmux(root.path(), &["link", "archive", "--state-dir", link.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(archive.status.success(), "{}", String::from_utf8_lossy(&archive.stderr));
    assert!(link.join("key-adopted.inst_a.json").is_file());
    assert!(!link.join("key-adopted.json").exists());

    // `machine leave`, with no link running: the archived adoption keeps the key.
    let leave = cmux(root.path(), &["acp", "machine", "leave", "--local-only", "--json"])
        .env("ACPMUX_HOME", &home)
        .output()
        .unwrap();
    assert!(leave.status.success(), "{}", String::from_utf8_lossy(&leave.stderr));
    let left: serde_json::Value = serde_json::from_slice(&leave.stdout).unwrap();
    let removed = left["removed"].as_array().cloned().unwrap_or_default();
    assert!(!removed.contains(&serde_json::json!("nodeKey")), "{left}");
    assert_eq!(std::fs::read(KeyFile::Node.path_in(&home)).unwrap(), node_bytes);

    // The install signs in again: its link comes back and serves the same node key.
    let ensure = cmux(
        root.path(),
        &[
            "link",
            "ensure",
            "--state-dir",
            link.to_str().unwrap(),
            "--install",
            "inst_a",
            "--port",
            "0",
        ],
    )
    .env("ACPMUX_HOME", &home)
    .output()
    .unwrap();
    let _ensured = Ensured { root: root.path(), link: &link };
    assert!(ensure.status.success(), "{}", String::from_utf8_lossy(&ensure.stderr));
    assert!(link.join("key-adopted.json").is_file(), "the restore did not bring the record back");
    let show = cmux(root.path(), &["link", "show", "--state-dir", link.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(show.status.success(), "{}", String::from_utf8_lossy(&show.stderr));
    let shown: serde_json::Value = serde_json::from_slice(&show.stdout).unwrap();
    assert_eq!(shown["public_key"], STANDARD.encode(node), "{shown}");
}
