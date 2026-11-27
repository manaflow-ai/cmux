//! A process the host spawns must not inherit libtailscale's sockets. An inherited copy of
//! either end of a listener's or connection's socketpair outlives our close: libtailscale sees
//! no EOF and keeps the tailnet listener or connection alive for the child's whole life.
//!
//! Linux only: it reads socket identities from `/proc/<pid>/fd`.

#![cfg(target_os = "linux")]

use std::collections::HashSet;
use std::os::fd::AsRawFd;
use std::process::{Command, Stdio};

use cmux_tailnet::{Node, NodeConfig};

const NAME: &str = "spawned_processes_do_not_inherit_libtailscale_sockets";

/// The sockets `pid` holds: (fd, `socket:[inode]`), from `/proc/<pid>/fd`.
fn sockets(pid: &str) -> Vec<(i32, String)> {
    std::fs::read_dir(format!("/proc/{pid}/fd"))
        .unwrap()
        .filter_map(|entry| {
            let entry = entry.ok()?;
            let fd = entry.file_name().to_str()?.parse().ok()?;
            let target = std::fs::read_link(entry.path()).ok()?.to_string_lossy().into_owned();
            target.starts_with("socket:").then_some((fd, target))
        })
        .collect()
}

#[test]
fn spawned_processes_do_not_inherit_libtailscale_sockets() {
    // tsnet reads its environment when the process starts, so this test reruns alone in a
    // process where tsnet uploads no logs.
    if std::env::var_os("TS_NO_LOGS_NO_SUPPORT").is_none() {
        let status = Command::new(std::env::current_exe().unwrap())
            .args([NAME, "--exact", "--test-threads=1", "--nocapture"])
            .env("TS_NO_LOGS_NO_SUPPORT", "true")
            .status()
            .unwrap();
        assert!(status.success(), "{NAME} failed in its own process: {status}");
        return;
    }

    let dir = std::env::temp_dir().join(format!("cmux-tailnet-cloexec-{}", std::process::id()));
    let mut config = NodeConfig::new(&dir, "cloexec-test");
    // An unreachable control server: the node starts but never joins a tailnet.
    config.control_url = Some("http://127.0.0.1:1".into());
    config.ephemeral = true;
    let node = Node::new(&config).unwrap();
    node.start().unwrap();

    let before: HashSet<String> = sockets("self").into_iter().map(|(_, socket)| socket).collect();
    let listener = node.listen_tcp(7443).unwrap();
    // Both ends of the listener's socketpair: ours, and the one libtailscale reads for EOF.
    let new: HashSet<String> = sockets("self")
        .into_iter()
        .map(|(_, socket)| socket)
        .filter(|socket| !before.contains(socket))
        .collect();
    let ours = std::fs::read_link(format!("/proc/self/fd/{}", listener.as_raw_fd()))
        .unwrap()
        .to_string_lossy()
        .into_owned();

    let mut child =
        Command::new("sh").args(["-c", "read _"]).stdin(Stdio::piped()).spawn().unwrap();
    // spawn returns once the child has exec'd, so close-on-exec fds are already gone.
    let held: Vec<(i32, String)> = sockets(&child.id().to_string())
        .into_iter()
        .filter(|(_, socket)| new.contains(socket))
        .collect();
    drop(child.stdin.take());
    child.wait().unwrap();
    drop(listener);
    node.close().unwrap();
    drop(node);
    let _ = std::fs::remove_dir_all(&dir);

    assert!(new.contains(&ours), "the listener's socket {ours} is not among the new ones {new:?}");
    assert!(new.len() >= 2, "libtailscale's end of the listener was not found: {new:?}");
    assert!(
        held.is_empty(),
        "a spawned process inherited libtailscale sockets (fd, socket): {held:?}; listener {ours}"
    );
}
