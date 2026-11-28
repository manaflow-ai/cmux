//! A chat moved while its agent waits on the person's answer to a permission prompt (RFD 0074,
//! one session, many views: "open prompts carried and re-asked"). The move withdraws the prompt
//! where the chat was; the turn's continuation where it lands names the tool call that never
//! ran, the agent asks again there, and the person's answer there reaches the turn.
//!
//! Both daemons are real, with the permission policy "ask"; the agent is the fake sample harness
//! (`FAKE_ASK_MODE`): a prompt naming `hostname` announces that tool call and asks before it runs.
use super::session_move::prompt;
use super::session_move_live::{Side, events, move_to_the_other};
use super::*;

/// The first record of the chat's log that `matches`, waited for up to 30 s.
async fn first_record(
    rpc: &mut Rpc,
    id: &str,
    what: &str,
    matches: impl Fn(&Value) -> bool,
) -> Value {
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        let log = events(rpc, id).await;
        if let Some(found) = log.iter().find(|event| matches(event)) {
            return found.clone();
        }
        assert!(std::time::Instant::now() < deadline, "no {what} in {}", json!(log));
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// How many prompts the session's summary says wait on the person.
async fn pending(rpc: &mut Rpc, id: &str) -> u64 {
    let info = rpc.call("_acpmux/info", json!({"sessionId": id})).await;
    info["pendingPermissions"].as_u64().unwrap_or(0)
}

#[tokio::test]
async fn an_open_permission_prompt_is_asked_again_where_the_chat_lands_and_answered_there() {
    let env = json!({"FAKE_ASK_MODE": "1"});
    let target = Daemon::with_env("aska-t", None, env.clone(), &[], "ask").await;
    let source = Daemon::with_env("aska-s", Some(&target), env, &[], "ask").await;
    let [from, to] = [source, target].map(|daemon| {
        let folder = daemon.home.join("project");
        std::fs::create_dir(&folder).unwrap();
        Side { daemon, folder }
    });
    let mut here = Rpc::connect(&from.daemon.socket).await;
    let made = here.call("session/new", json!({"cwd": from.folder, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();

    // The agent announces `hostname` and waits on the person's answer.
    here.send_prompt(&id, "p-ask", "run hostname").await;
    let asked =
        first_record(&mut here, &id, "permission_request", |e| e["kind"] == "permission_request")
            .await;
    let before = asked["msg"]["permissionId"].as_str().unwrap().to_owned();
    assert_eq!(asked["msg"]["request"]["toolCall"]["title"], "hostname", "{asked}");
    assert_eq!(pending(&mut here, &id).await, 1, "the prompt is open before the move");

    move_to_the_other(&from, &to, &id, &[]).await;

    // Where it lands: the same prompt (the same tool call, the same options) is open again, a
    // new prompt of this daemon's; the one the move withdrew is settled, never left open.
    let mut there = Rpc::connect(&to.daemon.socket).await;
    let again = first_record(&mut there, &id, "the prompt asked again on the target", |e| {
        e["kind"] == "permission_request" && e["msg"]["permissionId"] != before.as_str()
    })
    .await;
    let after = again["msg"]["permissionId"].as_str().unwrap().to_owned();
    for field in ["title", "kind", "rawInput"] {
        assert_eq!(
            again["msg"]["request"]["toolCall"][field], asked["msg"]["request"]["toolCall"][field],
            "the same tool call is asked about: {field}"
        );
    }
    assert_eq!(again["msg"]["request"]["options"], asked["msg"]["request"]["options"]);
    assert_eq!(pending(&mut there, &id).await, 1, "the target lists the open prompt");
    let log = events(&mut there, &id).await;
    assert!(
        log.iter()
            .any(|e| e["kind"] == "permission_decision"
                && e["msg"]["permissionId"] == before.as_str()),
        "the prompt left behind is settled in the moved log: {}",
        json!(log)
    );

    // The person answers there (a deny: an allow needs the app's person key, `person_allow.rs`;
    // either answer travels the same way) and the answer reaches the agent's turn: the tool
    // call settles with it and the turn ends.
    there
        .call(
            "_acpmux/permission_respond",
            json!({"sessionId": id, "permissionId": after, "optionId": "reject"}),
        )
        .await;
    let decided = first_record(&mut there, &id, "the target's decision", |e| {
        e["kind"] == "permission_decision" && e["msg"]["permissionId"] == after.as_str()
    })
    .await;
    assert_eq!(decided["msg"]["outcome"]["optionId"], "reject", "{decided}");
    let at = decided["seq"].as_u64().unwrap();
    let settled = first_record(&mut there, &id, "the tool call settled by the answer", |e| {
        e["seq"].as_u64().is_some_and(|seq| seq > at)
            && e["kind"] == "tool_call_update"
            && e["msg"]["params"]["update"]["toolCallId"] == "hostname-1"
    })
    .await;
    assert_eq!(settled["msg"]["params"]["update"]["status"], "failed", "{settled}");
    first_record(&mut there, &id, "the turn's end after the answer", |e| {
        e["seq"].as_u64().is_some_and(|seq| seq > at) && e["kind"] == "turn_result"
    })
    .await;
    assert_eq!(pending(&mut there, &id).await, 0, "nothing is left open on the target");
}
