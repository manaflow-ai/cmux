//! An agent offers the person a parallel chat (cx-807da, `hub/offers.rs`):
//! its `offer_session` tool records the offer and returns at once, the chat
//! shows it as a chip, and only the person accepts it (naming the chat it
//! started, which takes the offering chat as its parent) or dismisses it.

use super::*;
use acpmux::server::{Origin, serve_connection_with};

/// The agent's tool on the unix socket: a connection that never proved the
/// person key.
async fn agent(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "agent"}}))
        .await
        .unwrap();
    client
}

async fn new_chat(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

fn offer(id: &str, title: &str) -> Value {
    json!({
        "sessionId": id,
        "title": title,
        "prompt": "The upload test fails one run in five: find why and fix it.",
        "worktree": true,
        "harness": "codex",
    })
}

#[tokio::test]
async fn an_offered_chat_is_a_chip_only_the_person_starts_and_it_reports_its_parent() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = new_chat(&mut person).await;
    let mut agent = agent(&hub).await;
    let session = hub.resolve(&id).unwrap();
    let before = hub.session_summary(&session)["status"].clone();
    // A chat that was there before the offer is not the one it started.
    let older = new_chat(&mut person).await;
    tokio::time::sleep(Duration::from_millis(5)).await;

    // The tool returns at once; the chat records the chip with what the agent
    // gave and this chat's folder, and keeps its status.
    let offered = agent
        .request("_acpmux/offer_session", offer(&id, "Fix the flaky upload test"))
        .await
        .unwrap();
    assert_eq!(offered["outcome"], "offered", "{offered}");
    let offer_id = offered["offerId"].as_str().unwrap().to_owned();
    let chip = person.wait_for(method::MUX_EVENT, |p| p["kind"] == "session_offer").await;
    assert_eq!(chip["msg"]["offerId"], offer_id.as_str());
    assert_eq!(chip["msg"]["title"], "Fix the flaky upload test");
    assert_eq!(chip["msg"]["worktree"], true);
    assert_eq!(chip["msg"]["harness"], "codex");
    assert_eq!(chip["msg"]["cwd"], json!(session.meta().cwd));
    assert_eq!(hub.session_summary(&session)["status"], before);

    // A page reading the chat's history gets the chip with the transcript.
    let page = person
        .request("_acpmux/events", json!({"sessionId": id, "kinds": "transcript"}))
        .await
        .unwrap();
    assert!(
        page.to_string().contains("session_offer"),
        "the chip is not in the transcript: {page}"
    );

    // The agent cannot accept its own offer.
    let child = new_chat(&mut person).await;
    let accept = json!({"sessionId": id, "offerId": offer_id, "outcome": "accepted", "childSessionId": child});
    let forged = agent.request("_acpmux/offer_respond", accept.clone()).await;
    assert!(forged.is_err(), "the agent accepted its own offer: {forged:?}");

    let stale = json!({"sessionId": id, "offerId": offer_id, "outcome": "accepted", "childSessionId": older});
    let adopted = person.request("_acpmux/offer_respond", stale).await;
    assert!(adopted.is_err(), "an older chat took the offer: {adopted:?}");

    // The person accepts it with the chat they started: that chat's parent is
    // this one, and it is not a fork.
    let decided = person.request("_acpmux/offer_respond", accept.clone()).await.unwrap();
    assert_eq!(decided["childSessionId"], child.as_str(), "{decided}");
    let started = hub.resolve(&child).unwrap();
    let summary = hub.session_summary(&started);
    assert_eq!(summary["parentId"], id.as_str(), "{summary}");
    assert!(summary["forkSeq"].is_null(), "an offered chat is not a fork: {summary}");
    // It is this chat's sub-session too: the agent that offered it lists,
    // reads and waits on it with its cmux-subsessions tools.
    assert_eq!(summary["startedBy"], id.as_str(), "{summary}");
    assert_eq!(summary["depth"], 1, "{summary}");
    assert_eq!(summary["shortName"], "fix-the-flaky-upload-test", "{summary}");
    assert_eq!(hub.session_summary(&session)["children"], 1);
    let family = hub.subsession_list(&session, false);
    assert_eq!(family["sessions"][0]["sessionId"], child.as_str(), "{family}");
    // The person started it in a mode they chose, which may allow more than
    // the offering agent's own: that agent reads it, but neither prompts it
    // nor stops or closes it.
    assert!(hub.subsession_target(&session, &child, true).is_ok());
    for parent_ok in [true, false] {
        let Err(e) = hub.subsession_write_target(&session, &child, parent_ok) else {
            panic!("the offering agent may write to the chat the person started");
        };
        let data = e.data.clone().unwrap_or_default();
        assert_eq!(data["reason"], "subsessions.person_started", "{e:?}");
    }
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(
        events.iter().any(|e| e.kind == "session_offer_decision" && e.msg["outcome"] == "accepted")
    );

    // An answered offer takes no second answer.
    let again = person.request("_acpmux/offer_respond", accept).await;
    assert!(again.is_err(), "an offer was answered twice: {again:?}");

    // Another offer is dismissed: no chat starts.
    let second = agent
        .request("_acpmux/offer_session", offer(&id, "Rename the cache module"))
        .await
        .unwrap();
    let dismiss = json!({"sessionId": id, "offerId": second["offerId"], "outcome": "dismissed"});
    let dismissed = person.request("_acpmux/offer_respond", dismiss).await.unwrap();
    assert_eq!(dismissed["outcome"], "dismissed");
    assert!(dismissed.get("childSessionId").is_none(), "{dismissed}");
}

#[tokio::test]
async fn an_offer_needs_a_title_and_a_prompt_and_a_chat_holds_a_few() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = new_chat(&mut person).await;
    let mut agent = agent(&hub).await;

    let untitled = agent.request("_acpmux/offer_session", offer(&id, "  ")).await;
    assert!(untitled.is_err(), "an untitled offer was recorded: {untitled:?}");
    let mut no_prompt = offer(&id, "Fix it");
    no_prompt["prompt"] = json!("");
    assert!(agent.request("_acpmux/offer_session", no_prompt).await.is_err());
    let mut elsewhere = offer(&id, "Fix it");
    elsewhere["cwd"] = json!("relative/folder");
    assert!(agent.request("_acpmux/offer_session", elsewhere).await.is_err());

    // Eight open offers at most: the ninth waits for an answer.
    for n in 0..8 {
        agent.request("_acpmux/offer_session", offer(&id, &format!("Task {n}"))).await.unwrap();
    }
    let ninth = agent.request("_acpmux/offer_session", offer(&id, "Task 8")).await;
    assert!(ninth.is_err(), "a ninth open offer was recorded: {ninth:?}");
}

/// The person's prompt to chat `id`; returns once its turn ends.
async fn ask(c: &mut TestClient, id: &str, text: &str) {
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
}

/// The prompts chat `id` got with a suggested task's result
/// (`_meta.provenance.kind == "offer_result"`).
fn offer_results(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    let events = hub.events(id, 0, 100_000).unwrap();
    events
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == "user_message")
        .filter(|e| e.msg.pointer("/_meta/provenance/kind") == Some(&json!("offer_result")))
        .map(|e| e.msg)
        .collect()
}

/// Waits until chat `id` got `n` results.
async fn wait_offer_results(hub: &Arc<Hub>, id: &str, n: usize) -> Vec<Value> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let results = offer_results(hub, id);
        if results.len() >= n {
            return results;
        }
        assert!(tokio::time::Instant::now() < deadline, "{n} results never came: {results:?}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn suggested_tasks_share_a_group_and_do_it_here_starts_no_chat() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = new_chat(&mut person).await;
    let mut agent = agent(&hub).await;

    // Suggested tasks name their group: the card shows them together.
    let mut grouped = offer(&id, "Write the docs");
    grouped["groupId"] = json!("g-7f3a");
    let offered = agent.request("_acpmux/offer_session", grouped.clone()).await.unwrap();
    let offer_id = offered["offerId"].as_str().unwrap().to_owned();
    let events = hub.events(&id, 0, 10_000).unwrap();
    let chip = events.iter().find(|e| e.kind == "session_offer").expect("no session_offer");
    assert_eq!(chip.msg["groupId"], "g-7f3a", "{}", chip.msg);
    for bad in [json!("two\nlines"), json!("g".repeat(65)), json!(""), json!(5)] {
        let mut wrong = grouped.clone();
        wrong["groupId"] = bad.clone();
        let refused = agent.request("_acpmux/offer_session", wrong).await;
        assert!(refused.is_err(), "groupId {bad} was recorded: {refused:?}");
    }

    // "Do it here": the offer closes with no chat, and only the person says so.
    let here = json!({"sessionId": id, "offerId": offer_id, "outcome": "here"});
    assert!(agent.request("_acpmux/offer_respond", here.clone()).await.is_err());
    let decided = person.request("_acpmux/offer_respond", here.clone()).await.unwrap();
    assert_eq!(decided, json!({"offerId": offer_id, "outcome": "here"}));
    let again = person.request("_acpmux/offer_respond", here).await;
    assert!(again.is_err(), "an offer done here was answered again: {again:?}");
    let events = hub.events(&id, 0, 10_000).unwrap();
    let decision = events.iter().find(|e| e.kind == "session_offer_decision").unwrap();
    assert_eq!(decision.msg, json!({"offerId": offer_id, "outcome": "here"}));

    // Done here names no chat.
    let second = agent.request("_acpmux/offer_session", grouped).await.unwrap();
    let other = new_chat(&mut person).await;
    let named = json!({"sessionId": id, "offerId": second["offerId"], "outcome": "here", "childSessionId": other});
    assert!(person.request("_acpmux/offer_respond", named).await.is_err());
    let dismiss = json!({"sessionId": id, "offerId": second["offerId"], "outcome": "dismissed"});
    person.request("_acpmux/offer_respond", dismiss).await.unwrap();

    // A chat started meanwhile is no offer's: its turn sends this chat nothing.
    ask(&mut person, &other, "Write the docs").await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(offer_results(&hub, &id).is_empty(), "{:?}", offer_results(&hub, &id));
}

#[tokio::test]
async fn a_suggested_task_sends_its_first_reply_back_to_its_parent_once() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = new_chat(&mut person).await;
    let mut agent = agent(&hub).await;

    let offered = agent
        .request("_acpmux/offer_session", offer(&id, "Fix the flaky upload test"))
        .await
        .unwrap();
    let offer_id = offered["offerId"].as_str().unwrap().to_owned();
    let child = new_chat(&mut person).await;
    let accept = json!({"sessionId": id, "offerId": offer_id, "outcome": "accepted", "childSessionId": child});
    person.request("_acpmux/offer_respond", accept).await.unwrap();

    // The child's first turn ends: its reply comes back to the parent as one
    // prompt that names the task, not as the person's words.
    ask(&mut person, &child, "Fix the upload test").await;
    let results = wait_offer_results(&hub, &id, 1).await;
    assert_eq!(
        results[0]["text"],
        format!(
            "Result from the suggested task \"Fix the flaky upload test\" (chat {child}):\necho: Fix the upload test"
        ),
        "{}",
        results[0]
    );
    assert_eq!(
        results[0]["_meta"]["provenance"],
        json!({"kind": "offer_result", "offerId": offer_id, "childSessionId": child, "title": "Fix the flaky upload test"}),
    );

    // Its later turns, and the parent's own turn on the result, send nothing more.
    ask(&mut person, &child, "And the other one").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(offer_results(&hub, &id).len(), 1, "{:?}", offer_results(&hub, &id));
    assert!(offer_results(&hub, &child).is_empty());

    // A chat whose first turn ended before the person's answer reached the
    // daemon sends its result once the offer is accepted.
    let offered = agent
        .request("_acpmux/offer_session", offer(&id, "Rename the cache module"))
        .await
        .unwrap();
    let early = new_chat(&mut person).await;
    ask(&mut person, &early, "Rename it").await;
    let accept = json!({"sessionId": id, "offerId": offered["offerId"], "outcome": "accepted", "childSessionId": early});
    person.request("_acpmux/offer_respond", accept).await.unwrap();
    let results = wait_offer_results(&hub, &id, 2).await;
    assert_eq!(results[1]["_meta"]["provenance"]["offerId"], offered["offerId"]);
    assert!(
        results[1]["text"].as_str().unwrap().ends_with("):\necho: Rename it"),
        "{}",
        results[1]
    );
}

/// `hub` on a unix socket of its own, as the daemon listens; its path.
#[cfg(unix)]
async fn listen(hub: &Arc<Hub>) -> std::path::PathBuf {
    // `/tmp`, not the temp dir: a worker's can be too long for a socket path.
    let path =
        std::path::PathBuf::from("/tmp").join(format!("acpmux-offers-{}.sock", std::process::id()));
    let listener = acpmux::server::bind_unix(&path).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    path
}

/// The agent's `cmux-sessions` MCP server lists `suggest_tasks`, and one call
/// offers each task under one fresh group id.
#[cfg(unix)]
#[tokio::test]
async fn suggested_tasks_tool_offers_each_task_in_one_group() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = new_chat(&mut person).await;
    let socket = listen(&hub).await;
    let scratch = std::env::temp_dir().join(format!("amx-offer-{}", std::process::id()));
    let mut mcp = crate::daemon_env::tokio_command(&scratch, crate::daemon_env::Agents::Deny)
        .arg("offer-mcp")
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_OFFER_SESSION", &id)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = mcp.stdin.take().unwrap();
    let mut lines = BufReader::new(mcp.stdout.take().unwrap()).lines();
    let task =
        |title: &str| json!({"title": title, "prompt": format!("{title}, then run the tests.")});
    let call = |n: usize| {
        let tasks: Vec<Value> = (0..n).map(|i| task(&format!("Task {i}"))).collect();
        json!({"name": "suggest_tasks", "arguments": {"tasks": tasks}})
    };
    // A title over the limit in the second task: the first is not offered either.
    let long = json!({"name": "suggest_tasks", "arguments": {"tasks": [task("Fine"), task(&"a".repeat(81))]}});
    let requests = [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2099-01-01"}}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
        json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": call(3)}),
        json!({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": call(6)}),
        json!({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": call(0)}),
        json!({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": long}),
    ];
    for r in &requests {
        stdin.write_all(format!("{r}\n").as_bytes()).await.unwrap();
    }
    let mut replies = std::collections::HashMap::new();
    while replies.len() < requests.len() {
        let line = tokio::time::timeout(Duration::from_secs(30), lines.next_line())
            .await
            .expect("offer-mcp timed out")
            .unwrap()
            .expect("offer-mcp closed");
        let reply: Value = serde_json::from_str(&line).unwrap();
        replies.insert(reply["id"].as_i64().unwrap(), reply);
    }
    drop(stdin);
    let _ = std::fs::remove_file(&socket);

    let tools = replies[&2]["result"]["tools"].as_array().unwrap();
    let names: Vec<&str> = tools.iter().filter_map(|t| t["name"].as_str()).collect();
    assert_eq!(names, ["offer_session", "suggest_tasks"], "{tools:?}");
    assert_eq!(replies[&3]["result"]["isError"], false, "{}", replies[&3]);
    assert_eq!(replies[&4]["result"]["isError"], true, "six tasks: {}", replies[&4]);
    assert_eq!(replies[&5]["result"]["isError"], true, "no task: {}", replies[&5]);
    let refused = &replies[&6]["result"];
    assert_eq!(refused["isError"], true, "long title: {refused}");
    let text = refused["content"][0]["text"].as_str().unwrap();
    assert_eq!(text, "task 2 title must be 1 to 80 characters (none was offered)");
    // A version we do not speak is answered with our newest, not echoed.
    assert_eq!(replies[&1]["result"]["protocolVersion"], "2025-06-18");

    let events = hub.events(&id, 0, 10_000).unwrap();
    let offers: Vec<&Value> =
        events.iter().filter(|e| e.kind == "session_offer").map(|e| &e.msg).collect();
    assert_eq!(offers.len(), 3, "{offers:?}");
    let group = offers[0]["groupId"].as_str().unwrap();
    assert!(group.starts_with("g-") && group.len() <= 64, "{group}");
    let titles: Vec<&str> = offers.iter().filter_map(|o| o["title"].as_str()).collect();
    assert_eq!(titles, ["Task 0", "Task 1", "Task 2"]);
    assert!(offers.iter().all(|o| o["groupId"] == group), "{offers:?}");
}

/// The `instructions` an MCP server gives at `initialize`.
#[cfg(unix)]
async fn mcp_instructions(server: &str, session_env: &str) -> String {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let scratch = std::env::temp_dir().join(format!("amx-instr-{}-{server}", std::process::id()));
    let mut mcp = crate::daemon_env::tokio_command(&scratch, crate::daemon_env::Agents::Deny)
        .arg(server)
        .env(session_env, "s-instructions")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = mcp.stdin.take().unwrap();
    let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}});
    stdin.write_all(format!("{init}\n").as_bytes()).await.unwrap();
    let mut lines = BufReader::new(mcp.stdout.take().unwrap()).lines();
    let line = tokio::time::timeout(Duration::from_secs(30), lines.next_line())
        .await
        .expect("initialize timed out")
        .unwrap()
        .expect("the server closed");
    let reply: Value = serde_json::from_str(&line).unwrap();
    reply["result"]["instructions"].as_str().unwrap_or_default().to_owned()
}

/// The session servers tell the agent when to start a session and when to
/// suggest one, and point at the cmux tools for reaching the user.
#[cfg(unix)]
#[tokio::test]
async fn the_session_servers_say_when_to_start_and_when_to_suggest() {
    let sub = mcp_instructions("subsession-mcp", acpmux::subsession_mcp::SESSION_ENV).await;
    assert!(sub.contains("start_session only when the user asked"), "{sub}");
    for tool in [
        "workspace_open_url",
        "notification_create",
        "workspace_status_set",
        "app_agent_open",
        "app_agent_open_tab",
    ] {
        assert!(sub.contains(tool), "{tool}: {sub}");
    }
    let offers = mcp_instructions("offer-mcp", acpmux::offer_mcp::SESSION_ENV).await;
    assert!(offers.contains("offer_session") && offers.contains("suggest_tasks"), "{offers}");
}
