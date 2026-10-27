//! A panic in an agent host, which outlives daemon restarts, reaches its
//! daemon's panic log (`SpawnSpec::state_home`), with `"role": "agent-host"`,
//! and the host keeps serving its harness (p10-stability-150). The cmux-next
//! app sends new lines to Sentry.
#![cfg(all(unix, debug_assertions))]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs a stand-in agent, and the host it starts gets the panic-log test
// trigger (`agent_host::link` forwards it in debug builds).
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().with_env(&[("ACPMUX_TEST_PANIC", "thread")]);

use acpmux::agent_host::link::{self, Connect, HostLauncher};
use acpmux::agent_host::{self, Entry, SpawnSpec};
use serde_json::json;
use std::path::Path;
use std::time::{Duration, Instant};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn spec(dir: &Path, session: &str) -> SpawnSpec {
    let hosts = dir.join("hosts");
    SpawnSpec {
        session_id: session.into(),
        program: "python3".into(),
        args: vec![FAKE.into()],
        env: daemon_env::vars(dir, daemon_env::Agents::StandIn, &[]),
        cwd: dir.to_path_buf(),
        translator: None,
        codex_bridge: false,
        socket: agent_host::socket_path(&hosts, session),
        hosts_dir: hosts,
        buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
        router_owner_fifo: None,
        state_home: Some(dir.to_path_buf()),
    }
}

#[tokio::test]
async fn an_agent_host_panic_is_logged_in_its_daemons_home_and_the_host_keeps_serving() {
    // Short: socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amh-pl-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let launcher = HostLauncher { exe: daemon_env::bin().into(), prefix: Vec::new() };
    let record = link::spawn(&launcher, &spec(&dir, "s-panic")).await.expect("spawn host");

    let log = dir.join("panics.jsonl");
    let deadline = Instant::now() + Duration::from_secs(20);
    let line = loop {
        if let Some(line) = std::fs::read_to_string(&log)
            .ok()
            .and_then(|text| text.lines().next().map(String::from))
        {
            break line;
        }
        assert!(Instant::now() < deadline, "nothing in {}", log.display());
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let record_line: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(record_line["process"], "acpmux", "{record_line}");
    assert_eq!(record_line["role"], "agent-host", "{record_line}");
    assert_eq!(record_line["message"], "acpmux test panic", "{record_line}");
    assert_eq!(record_line["test"], true, "{record_line}");
    assert_eq!(record_line["pid"].as_u64(), Some(u64::from(record.host_pid)), "{record_line}");

    // The panic ended only its own thread: the host still answers its harness's requests.
    let Connect::Ready(owner, _) = link::connect(record.clone(), 0).await.expect("connect") else {
        panic!("host refused a same-build controller");
    };
    owner
        .line(json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}))
        .await
        .unwrap();
    let mut rx = owner.entries.lock().await;
    let answered = tokio::time::timeout(Duration::from_secs(20), async {
        while let Some((h, entry)) = rx.recv().await {
            owner.ack(h).await.unwrap();
            if matches!(&entry, Entry::In { msg } if msg.get("id") == Some(&json!(1))) {
                return true;
            }
        }
        false
    })
    .await
    .unwrap_or(false);
    drop(rx);
    owner.terminate(Duration::from_millis(500)).await.unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(answered, "the host keeps serving after the panic");
}
