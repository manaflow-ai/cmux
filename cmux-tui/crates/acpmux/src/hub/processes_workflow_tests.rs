//! A workflow agent's shell lists under its workflow and agent (cmux#36269's Session Info and
//! Background tasks nest it there): the translator names them on its update, and an update
//! that names them only after the shell was announced still fills them in.
use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn shell(state: &str, agent: Option<&str>) -> Value {
    let mut update = json!({"sessionUpdate": "background_task_update", "toolCallId": "toolu_sh",
        "taskId": "b1", "state": state, "command": "cargo test"});
    if let Some(agent) = agent {
        update["workflowAgentId"] = json!(agent);
    }
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own",
        "_meta": {"acpmux": {"subagent": "own/toolu_wf"}}, "update": update}})
}

#[tokio::test]
async fn a_workflow_agents_shell_names_its_agent_even_when_found_late() {
    let (hub, session) = chat().await;
    let rec = hub.append(&session, "in", "background_task_update", shell("running", None));
    hub.note_process(&session, &rec, None);
    let listed = |hub: &Hub| {
        let table = hub.process_table(&session);
        let p = &table.processes[0];
        (p.subagent_session_id.clone(), p.workflow_agent_id.clone(), p.state)
    };
    assert_eq!(listed(&hub), (Some("own/toolu_wf".into()), None, ProcessState::Running));
    // The agent found on a later snapshot: a second `running` fills it in, and is logged.
    let rec = hub.append(&session, "in", "background_task_update", shell("running", Some("a5e1")));
    hub.note_process(&session, &rec, None);
    assert_eq!(
        listed(&hub),
        (Some("own/toolu_wf".into()), Some("a5e1".into()), ProcessState::Running)
    );
    let row = serde_json::to_value(&hub.process_table(&session).processes[0]).unwrap();
    assert_eq!(row["workflowAgentId"], "a5e1");
    assert_eq!(row["subagentSessionId"], "own/toolu_wf");
    // Its end keeps them, and a later update never names another agent.
    let rec = hub.append(&session, "in", "background_task_update", shell("completed", Some("zz")));
    hub.note_process(&session, &rec, None);
    assert_eq!(
        listed(&hub),
        (Some("own/toolu_wf".into()), Some("a5e1".into()), ProcessState::Exited)
    );
    hub.shutdown_all().await;
}

#[test]
fn a_shell_of_the_chat_itself_has_no_workflow_agent_field() {
    let process: Process = serde_json::from_value(json!({
        "id": "chat/task", "sessionId": "chat", "toolCallId": "call", "taskId": "task",
        "harness": "claude", "command": "true", "cwd": "/tmp", "startedAt": 1,
        "state": "running", "origin": "background",
    }))
    .unwrap();
    assert_eq!(process.workflow_agent_id, None);
    assert!(serde_json::to_value(&process).unwrap().get("workflowAgentId").is_none());
}
