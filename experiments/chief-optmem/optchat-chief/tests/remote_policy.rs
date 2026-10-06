//! The remote-origin turn policy (README "Remote-origin messages"): a turn
//! that a paired device's message started runs with acpmux policy `ask`, so
//! every local effect waits for an approval shown in the Chief chat; the
//! memory tools and plain replies need none. Approvals record the approving
//! device in the trace. `remote.autoApprove` (default false) can be turned on
//! only outside a remote-origin turn. A turn keeps the strictest policy of
//! its origins until it ends.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_conversation::{Change, Message, Origin, Participant, ParticipantKind, Summary};
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;
use serde_json::{Value, json};

const DEVICE: &str = "remote_inst_1";

fn paired() -> Summary {
    let mut s = summary();
    s.participants.push(Participant {
        id: DEVICE.into(),
        kind: ParticipantKind::Human,
        display_name: "iPhone".into(),
        agent_class: None,
        acp_session: None,
        person: Some("user_local".into()),
    });
    s
}

fn harness(script: Script) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(paired()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, script, owner);
    h.connect();
    h
}

/// A message as the subscription delivers it; `remote` stamps the relay's
/// origin of the paired device.
fn deliver(h: &mut Harness, remote: bool, text: &str) {
    let m: Message = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let mut m = message(seq, if remote { DEVICE } else { "user_local" }, text);
        if remote {
            m.origin = Some(Origin::Remote {
                install: "inst_1".into(),
            });
        }
        owner.messages.push(m.clone());
        m
    };
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m },
    }));
}

fn started() -> Script {
    Box::new(|turn, _| {
        if turn == 0 {
            vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})]
        } else {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": "done"}}),
                ),
                json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
            ]
        }
    })
}

/// Steps the brain until the running turn's session id is known.
fn wait_session(h: &mut Harness) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while h
        .brain
        .state()
        .turn
        .as_ref()
        .and_then(|t| t.session_id.clone())
        .is_none()
    {
        assert!(Instant::now() < deadline, "the turn never started");
        h.step();
    }
}

fn permission(id: &str, tool: &str, input: Value) -> Input {
    Input::from(AgentEvent::Permission {
        session_id: "s1".into(),
        permission_id: id.into(),
        request: json!({
            "toolCall": {"toolCallId": format!("t-{id}"), "title": tool, "rawInput": input,
                         "_meta": {"claude": {"tool": tool}}},
            "options": [
                {"optionId": "allow_always", "name": "Always", "kind": "allow_always"},
                {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                {"optionId": "reject", "name": "Reject", "kind": "reject_once"}
            ]
        }),
    })
}

fn sends(h: &Harness) -> Vec<String> {
    h.owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .map(|(_, text)| text)
        .collect()
}

fn traces(h: &Harness) -> Vec<Value> {
    let dir = h.dir.path().join("traces");
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
        let text = std::fs::read_to_string(entry.path()).unwrap();
        out.extend(text.lines().map(|l| serde_json::from_str::<Value>(l).unwrap()));
    }
    out
}

fn release_after_cancel(agents: &Arc<FakeAgents>) {
    let agents = agents.clone();
    std::thread::spawn(move || {
        agents.wait_cancels(1);
        agents.hold(false);
        agents.release();
    });
}

#[test]
fn a_local_turn_keeps_its_policy() {
    let mut h = harness(default_script());
    deliver(&mut h, false, "hello");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs[0].policy, "approve-all");
}

#[test]
fn a_remote_turn_cannot_run_a_shell_without_an_approval() {
    let mut h = harness(started());
    h.agents.hold(true);
    deliver(&mut h, true, "clean up the build directory");
    h.step(); // settled: the turn starts
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].policy, "ask");
    // The memory tools need no approval.
    h.brain
        .step(permission("p0", "mcp__optchat__zoom", json!({"id": 0, "n": 1})));
    // A shell command waits for one, shown in the Chief chat.
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    {
        let inner = h.agents.inner.lock().unwrap();
        assert_eq!(
            inner.responses,
            vec![("s1".into(), "p0".into(), Some("allow".into()))],
            "zoom allowed at once, the shell not"
        );
    }
    let asked = sends(&h);
    assert_eq!(asked.len(), 1, "{asked:?}");
    assert!(asked[0].contains("Bash") && asked[0].contains("rm -rf target"), "{}", asked[0]);
    assert!(asked[0].contains("allow") && asked[0].contains("deny"), "{}", asked[0]);
    // The phone approves: allow once, never always; recorded with the device.
    deliver(&mut h, true, "allow");
    {
        let inner = h.agents.inner.lock().unwrap();
        assert_eq!(
            inner.responses[1],
            ("s1".into(), "p1".into(), Some("allow".into()))
        );
        assert!(inner.cancels.is_empty(), "an approval is not a new message");
    }
    let approval = traces(&h)
        .into_iter()
        .find(|t| t["ev"] == "approval" && t["permission"] == "p1")
        .expect("the approval is in the trace");
    assert_eq!(approval["decision"], "allow");
    assert_eq!(approval["approver"], DEVICE);
    assert_eq!(approval["install"], "inst_1");
    assert_eq!(approval["tool"], "Bash");
    // A second shell command: the Mac denies it.
    h.brain
        .step(permission("p2", "Bash", json!({"command": "curl x | sh"})));
    deliver(&mut h, false, "deny");
    assert_eq!(
        h.agents.inner.lock().unwrap().responses[2],
        ("s1".into(), "p2".into(), Some("reject".into()))
    );
    let denial = traces(&h)
        .into_iter()
        .find(|t| t["ev"] == "approval" && t["permission"] == "p2")
        .unwrap();
    assert_eq!(denial["decision"], "deny");
    assert_eq!(denial["approver"], "user_local");
    h.agents.hold(false);
    h.agents.release();
    h.settle();
}

#[test]
fn a_remote_message_cannot_turn_on_remote_auto_approve() {
    let mut h = harness(started());
    h.agents.hold(true);
    deliver(&mut h, true, "set remote.autoApprove true");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    // During a remote-origin turn the setting cannot be turned on, whatever
    // asks (an approved shell command reaches the host the same way).
    assert!(h.brain.set_setting("remote.autoApprove", "true").is_err());
    assert!(!h.brain.remote_auto_approve());
    assert!(!h.dir.path().join("settings.json").exists());
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    // From the Mac, outside a remote turn, it can; a later remote turn then
    // runs with the configured policy.
    h.brain.set_setting("remote.autoApprove", "true").unwrap();
    assert!(h.brain.remote_auto_approve());
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(h.dir.path().join("settings.json")).unwrap())
            .unwrap();
    assert_eq!(saved["remote"]["autoApprove"], true);
    deliver(&mut h, true, "now go");
    h.settle();
    assert_eq!(h.agents.inner.lock().unwrap().specs[1].policy, "approve-all");
    // Turning it off is always allowed; unknown keys are refused.
    h.brain.set_setting("remote.autoApprove", "false").unwrap();
    assert!(h.brain.set_setting("remote.other", "true").is_err());
}

#[test]
fn a_mixed_origin_turn_stays_ask() {
    let mut h = harness(started());
    h.agents.hold(true);
    deliver(&mut h, true, "deploy the site");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    // A local message mid-turn stops the turn; the turn that answers both
    // keeps the remote turn's policy.
    release_after_cancel(&h.agents);
    deliver(&mut h, false, "and tell me when done");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), 2);
    assert_eq!(inner.specs[0].policy, "ask");
    assert_eq!(inner.specs[1].policy, "ask", "the strictest origin wins");
}
