//! An idle harness ends only when nothing but its MCP servers runs under it (`hub/idle_census.rs`).
use super::*;

/// Ends the test harness's children, whatever the test left running.
struct Children(std::path::PathBuf);
impl Children {
    fn pids(&self) -> BTreeMap<String, i32> {
        serde_json::from_str(&std::fs::read_to_string(&self.0).unwrap()).unwrap()
    }
    fn end(&self, name: &str) {
        // These pids were started by this test's fake harness and are still its children.
        unsafe { libc::kill(self.pids()[name], libc::SIGKILL) };
    }
}
impl Drop for Children {
    fn drop(&mut self) {
        if let Ok(text) = std::fs::read_to_string(&self.0) {
            for pid in serde_json::from_str::<BTreeMap<String, i32>>(&text).unwrap().values() {
                unsafe { libc::kill(*pid, libc::SIGKILL) };
            }
        }
    }
}

fn running(pid: i32) -> bool {
    // A zombie still answers kill(0): ask ps for its state.
    let out =
        std::process::Command::new("ps").args(["-o", "stat=", "-p", &pid.to_string()]).output();
    out.is_ok_and(|o| {
        o.status.success() && !String::from_utf8_lossy(&o.stdout).trim().starts_with('Z')
    })
}

async fn wait_idle(hub: &Hub, session: &acpmux::hub::Session) {
    let mut events = hub.subscribe();
    tokio::time::timeout(Duration::from_secs(15), async {
        while session.meta().status != acpmux::store::SessionStatus::Idle {
            events.recv().await.unwrap();
        }
    })
    .await
    .expect("the idle harness ended");
}

#[tokio::test]
async fn an_idle_harness_ends_only_once_nothing_but_its_mcp_servers_runs_under_it() {
    let root = std::env::temp_dir().join(format!("idle-census-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    // The folder's `.mcp.json` names the harness's MCP server (`sleep 3599`).
    let mcp = json!({"mcpServers": {"side": {"command": "sleep", "args": ["3599"]}}});
    std::fs::write(root.join(".mcp.json"), mcp.to_string()).unwrap();
    let children = Children(root.join("children.json"));
    let (hub, mut c) = stop::claude_setup_env(BTreeMap::from([(
        "FAKE_CLAUDE_IDLE_CHILDREN".into(),
        children.0.to_string_lossy().into_owned(),
    )]))
    .await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(2)));
    let cwd = root.to_string_lossy().into_owned();
    let made = c.request(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap();
    let prompt = |text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    c.request(method::SESSION_PROMPT, prompt("before")).await.unwrap();
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    let session = hub.resolve(id).unwrap();
    let pids = children.pids();
    // A config edited after the harness started: its new server is not one the harness runs.
    let edited = json!({"mcpServers": {"side": {"command": "sleep", "args": ["3599"]},
                                       "new": {"command": "sleep", "args": ["3601"]}}});
    std::fs::write(root.join(".mcp.json"), edited.to_string()).unwrap();
    // A worker in its group and one that left the group keep it up; then the escaped one alone.
    for kept in ["worker", "escaped"] {
        clock.advance(Duration::from_secs(3));
        tokio::time::sleep(Duration::from_millis(1500)).await;
        assert_ne!(session.meta().status, acpmux::store::SessionStatus::Idle, "{kept} running");
        let left = if kept == "worker" { ["worker", "escaped"] } else { ["escaped", "sidecar"] };
        assert!(left.iter().all(|n| running(pids[*n])), "an idle pass ended a child");
        assert!(running(pids["sidecar"]), "an idle pass ended the MCP server");
        children.end(kept);
    }
    // Only its MCP server is left: the harness ends, and the server with it.
    clock.advance(Duration::from_secs(3));
    wait_idle(&hub, &session).await;
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while running(pids["sidecar"]) {
        assert!(std::time::Instant::now() < deadline, "the MCP server outlived its harness");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    c.request(method::SESSION_PROMPT, prompt("after")).await.unwrap();
    assert!(hub.events(id, 0, 1000).unwrap().iter().any(|e| e.kind == "resumed"));
    hub.shutdown_all().await;
    drop(children);
    let _ = std::fs::remove_dir_all(root);
}

#[tokio::test]
async fn an_idle_pass_never_ends_a_harness_under_a_mode_change() {
    let (hub, mut c) = stop::claude_setup_env(BTreeMap::from([(
        "FAKE_CLAUDE_MODE_DELAY_MS".into(),
        "1500".into(),
    )]))
    .await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(2)));
    let made =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap();
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    let session = hub.resolve(id).unwrap();
    let mut events = hub.subscribe();
    let changing = {
        let hub = hub.clone();
        let session = session.clone();
        tokio::spawn(async move {
            hub.forward(&session, method::SESSION_SET_MODE, json!({"modeId": "plan"})).await
        })
    };
    tokio::time::timeout(Duration::from_secs(10), async {
        let sent = |hub: &Hub| {
            hub.events(id, 0, 1000)
                .unwrap()
                .iter()
                .any(|e| e.dir == "out" && e.kind == method::SESSION_SET_MODE)
        };
        while !sent(&hub) {
            events.recv().await.unwrap();
        }
    })
    .await
    .unwrap();
    clock.advance(Duration::from_secs(3));
    assert!(changing.await.unwrap().is_ok(), "an idle pass ended an in-flight mode change");
    hub.shutdown_all().await;
}
