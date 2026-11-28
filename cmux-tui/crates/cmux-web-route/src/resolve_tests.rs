use super::*;
use crate::route::parse;

fn chat(machine: &str, session_id: &str, harness: &str, agent: &str) -> Candidate {
    Candidate {
        machine_id: Some(format!("machine_{}", machine.repeat(32 / machine.len()))),
        machine_name: Some(format!("host-{machine}")),
        session_id: session_id.into(),
        harness: harness.into(),
        agent_session_id: Some(agent.into()),
        refusal: None,
    }
}

fn listing() -> Vec<Candidate> {
    vec![
        chat("a", "acp-1", "claude", "c-1"),
        chat("a", "acp-2", "codex", "x-1"),
        chat("b", "acp-3", "claude", "c-1"),
        Candidate {
            refusal: Some("listed through the relay only".into()),
            ..chat("b", "acp-4", "claude", "c-9")
        },
    ]
}

fn go(address: &str) -> Result<Resolved, ResolveError> {
    resolve(&parse(address).unwrap(), &listing(), &[])
}

#[test]
fn a_route_opens_its_one_chat_on_its_machine() {
    assert_eq!(
        go("/m/host-a/agent/claude/c-1?message=m7"),
        Ok(Resolved::Chat { session_id: "acp-1".into(), message: Some("m7".into()) })
    );
    let id = format!("machine_{}", "b".repeat(32));
    assert_eq!(
        go(&format!("/m/{id}/agent/claude/c-1")),
        Ok(Resolved::Chat { session_id: "acp-3".into(), message: None })
    );
    // acpmux's own id addresses the chat too.
    assert_eq!(
        go("/m/host-a/agent/codex/acp-2"),
        Ok(Resolved::Chat { session_id: "acp-2".into(), message: None })
    );
}

#[test]
fn an_unknown_or_refused_chat_is_a_refusal_never_another_chat() {
    assert_eq!(go("/m/host-a/agent/claude/nope"), Err(ResolveError::UnknownSession));
    // The right session on the wrong harness is not it.
    assert_eq!(go("/m/host-a/agent/codex/c-1"), Err(ResolveError::UnknownSession));
    assert_eq!(go("/m/host-z/agent/claude/c-1"), Err(ResolveError::UnknownMachine));
    assert_eq!(
        go("/m/host-b/agent/claude/c-9"),
        Err(ResolveError::Unattachable("listed through the relay only".into()))
    );
    // A link with no machine that two machines answer opens neither.
    assert_eq!(go("cmux://agent/claude/c-1"), Err(ResolveError::Ambiguous(2)));
    assert_eq!(
        go("https://cmux.com/deeplink/agent?harness=codex&session=x-1"),
        Ok(Resolved::Chat { session_id: "acp-2".into(), message: None })
    );
    // An empty listing refuses too.
    assert_eq!(
        resolve(&parse("/m/host-a/agent/claude/c-1").unwrap(), &[], &[]),
        Err(ResolveError::UnknownMachine)
    );
    assert_eq!(ResolveError::Ambiguous(2).code(), "ambiguous");
}

#[test]
fn a_workspace_route_opens_its_workspace_or_refuses() {
    let ws = format!("ws_{}", "1".repeat(32));
    let other = format!("ws_{}", "2".repeat(32));
    let workspaces = vec![
        WorkspaceCandidate {
            machine_id: None,
            machine_name: Some("host-a".into()),
            workspace_id: ws.clone(),
            refusal: None,
        },
        WorkspaceCandidate {
            machine_id: None,
            machine_name: Some("host-a".into()),
            workspace_id: other.clone(),
            refusal: Some("not shared with this device".into()),
        },
    ];
    let at = |address: String| resolve(&parse(&address).unwrap(), &[], &workspaces);
    assert_eq!(
        at(format!("/m/host-a/ws/{ws}")),
        Ok(Resolved::Workspace { workspace_id: ws.clone() })
    );
    assert_eq!(at(format!("/m/host-b/ws/{ws}")), Err(ResolveError::UnknownMachine));
    assert_eq!(
        at(format!("/m/host-a/ws/ws_{}", "3".repeat(32))),
        Err(ResolveError::UnknownWorkspace)
    );
    assert_eq!(
        at(format!("/m/host-a/ws/{other}")),
        Err(ResolveError::Unattachable("not shared with this device".into()))
    );
}
