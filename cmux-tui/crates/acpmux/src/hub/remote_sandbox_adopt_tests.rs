//! cx-44j.19 follow-up: an agent host adopted after a daemon restart keeps
//! running the process it started. A remote chain's Claude Code host with no
//! record in its log that it started inside the sandbox (it started before
//! the sandbox existed) must not be Web-controlled until it restarts.

use super::*;
use crate::store::MemoryStore;

fn hub() -> Arc<Hub> {
    let cfg: Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"argv": ["claude"], "kind": "claude-stdio"}},
        "defaultHarness": "claude",
        "permissionPolicy": "ask",
    }))
    .unwrap();
    Hub::new(cfg, Box::new(MemoryStore::default()))
}

fn remote_claude(hub: &Arc<Hub>, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "cwd": "/tmp",
        "status": "idle", "createdAt": 1, "updatedAt": 1, "remoteOrigin": true,
    }))
    .expect("session meta");
    let s = hub.make_session(meta);
    hub.save_meta(&s);
    s
}

fn adopt(hub: &Arc<Hub>, s: &Session) {
    let work = hub.open_work(s, "inc-1");
    Hub::recover_floor(s, &work);
}

fn reason(r: &Result<(), RpcError>) -> Option<String> {
    r.as_ref()
        .err()
        .and_then(|e| e.data.as_ref())
        .and_then(|d| d["reason"].as_str().map(str::to_owned))
}

#[test]
fn an_adopted_remote_chain_host_without_a_sandbox_record_refuses_web_control() {
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let _guard = rt.enter();
    let hub = hub();
    let old = remote_claude(&hub, "old");
    hub.append(&old, "mux", "host_started", json!({"incarnation": "inc-1"}));
    adopt(&hub, &old);
    let r = hub.web_control_check(&old, Control::Web);
    assert_eq!(reason(&r).as_deref(), Some("remote.unsandboxed_agent"), "{r:?}");
    let message = r.err().map(|e| e.message).unwrap_or_default();
    assert!(message.contains("Restart this chat to control it remotely"), "{message}");
    // A host an older profile started (another profile identity) is too.
    let older = remote_claude(&hub, "older");
    hub.append(&older, "mux", "remote_sandbox", json!({"canary": "passed", "profile": "old"}));
    hub.append(&older, "mux", "host_started", json!({"incarnation": "inc-1"}));
    adopt(&hub, &older);
    let r = hub.web_control_check(&older, Control::Web);
    assert_eq!(reason(&r).as_deref(), Some("remote.unsandboxed_agent"), "{r:?}");
    // A host whose own start is missing from the log (fail closed) too.
    let lost = remote_claude(&hub, "lost");
    let canary = json!({"canary": "passed", "profile": super::remote_sandbox::profile_id()});
    hub.append(&lost, "mux", "remote_sandbox", canary.clone());
    hub.append(&lost, "mux", "host_started", json!({"incarnation": "inc-0"}));
    adopt(&hub, &lost);
    let r = hub.web_control_check(&lost, Control::Web);
    assert_eq!(reason(&r).as_deref(), Some("remote.unsandboxed_agent"), "{r:?}");
    // A host the current sandbox started (its canary passed just before) is not.
    let new = remote_claude(&hub, "new");
    hub.append(&new, "mux", "remote_sandbox", canary);
    hub.append(&new, "mux", "host_started", json!({"incarnation": "inc-1"}));
    adopt(&hub, &new);
    let r = hub.web_control_check(&new, Control::Web);
    assert_ne!(reason(&r).as_deref(), Some("remote.unsandboxed_agent"));
}
