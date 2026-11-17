//! An answer the daemon writes to a hosted agent while its link is down reaches the agent once
//! the link is back, and only once. Before, the write failed (or its queued line was cut with
//! the link) and nothing sent it again after the reattach: the agent waited for ever on an ask
//! the person had answered (a permission, most often), until a daemon restart.

use super::*;
use std::sync::Arc;

/// A harness that asks one thing (request 7), then reports each line it reads on stdin.
const ASKS_THEN_ECHOES: &str = "import json, sys\n\
print(json.dumps({'jsonrpc': '2.0', 'id': 7, 'method': 'session/request_permission', \
'params': {'sessionId': 's', 'options': [], 'toolCall': {}}}), flush=True)\n\
for line in sys.stdin:\n    print(json.dumps({'jsonrpc': '2.0', 'method': 'x/got', \
'params': {'line': line.strip()}}), flush=True)\n";

async fn next_inbound(
    rx: &mut tokio::sync::mpsc::Receiver<acpmux::agent::Inbound>,
    within: Duration,
) -> Option<acpmux::agent::Inbound> {
    tokio::time::timeout(within, rx.recv()).await.ok().flatten()
}

/// A hosted agent that runs [`ASKS_THEN_ECHOES`], once it asked: its scratch dir, host record and
/// live lock, the agent, and its inbound messages.
async fn asked_agent(
    name: &str,
) -> (
    std::path::PathBuf,
    HostRecord,
    std::fs::File,
    Arc<acpmux::agent::ChildAgent>,
    tokio::sync::mpsc::Receiver<acpmux::agent::Inbound>,
) {
    let dir = scratch(name);
    let mut launch = spec(&dir, &format!("s-{name}"));
    launch.program = "python3".into();
    launch.args = vec!["-c".into(), ASKS_THEN_ECHOES.into()];
    let record = link::spawn(&launcher(), &launch).await.expect("spawn host");
    let lock = live_lock(&dir, &record);
    let (inbound, mut rx) = tokio::sync::mpsc::channel(64);
    let tap: acpmux::agent::Tap = Arc::new(|_, _, _| true);
    let attached = acpmux::agent::ChildAgent::attach_hosted(
        "fake",
        record.clone(),
        0,
        Vec::new(),
        inbound,
        tap,
    )
    .await
    .unwrap();
    let acpmux::agent::Attached::Ready(agent, ..) = attached else {
        panic!("the host refused its controller")
    };
    loop {
        match next_inbound(&mut rx, Duration::from_secs(20)).await {
            Some(acpmux::agent::Inbound::Request { id, .. }) if id == json!(7) => break,
            Some(_) => {}
            None => panic!("the agent never asked"),
        }
    }
    (dir, record, lock, agent, rx)
}

/// Another owner takes the host over; returns its link once this agent's link is down.
async fn take_over(record: &HostRecord, agent: &acpmux::agent::ChildAgent) -> Box<Link> {
    let (taken, _) = connected(record, 0).await;
    let until = std::time::Instant::now() + Duration::from_secs(10);
    while agent.is_alive().await {
        assert!(std::time::Instant::now() < until, "the agent's link never closed");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    taken
}

/// Every line the harness reported reading, until none came for `quiet`.
async fn lines_read(
    rx: &mut tokio::sync::mpsc::Receiver<acpmux::agent::Inbound>,
    got: &mut Vec<String>,
    quiet: Duration,
) {
    while let Some(message) = next_inbound(rx, quiet).await {
        if let acpmux::agent::Inbound::Notification { method, params, .. } = message
            && method == "x/got"
        {
            got.push(params.unwrap_or_default()["line"].as_str().unwrap_or_default().to_owned());
        }
    }
}

fn answers_to_7(got: &[String]) -> usize {
    got.iter().filter(|line| line.contains("\"id\":7")).count()
}

const ANSWER: &str = r#"{"outcome": {"outcome": "selected", "optionId": "allow"}}"#;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_answer_written_while_the_link_is_down_reaches_the_agent_once_after_the_reattach() {
    let (dir, record, lock, agent, mut rx) = asked_agent("answer-down").await;
    let taken = take_over(&record, &agent).await;
    // The person's answer is written while the link is down.
    let answer: Value = serde_json::from_str(ANSWER).unwrap();
    let _ = agent.respond(json!(7), Ok(answer)).await;
    drop(taken);
    agent.reattach().await.expect("reattach");

    let mut got = Vec::new();
    lines_read(&mut rx, &mut got, Duration::from_secs(5)).await;
    // SAFETY: the host this test spawned; its live lock is held, so the pid is its own.
    unsafe { libc::kill(record.host_pid as i32, libc::SIGKILL) };
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
    let answers = answers_to_7(&got);
    assert_eq!(answers, 1, "the answer reached the agent {answers} times: {got:?}");
}

/// The other half of once: an answer the agent read before its link went down is not sent again by
/// the reattach.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_answer_the_agent_read_is_not_sent_again_after_a_reattach() {
    let (dir, record, lock, agent, mut rx) = asked_agent("answer-read").await;
    let answer: Value = serde_json::from_str(ANSWER).unwrap();
    agent.respond(json!(7), Ok(answer)).await.expect("the answer is written");
    let mut got = Vec::new();
    let until = std::time::Instant::now() + Duration::from_secs(20);
    while answers_to_7(&got) == 0 {
        assert!(std::time::Instant::now() < until, "the agent never read the answer: {got:?}");
        lines_read(&mut rx, &mut got, Duration::from_millis(200)).await;
    }
    let taken = take_over(&record, &agent).await;
    drop(taken);
    agent.reattach().await.expect("reattach");

    lines_read(&mut rx, &mut got, Duration::from_secs(5)).await;
    // SAFETY: the host this test spawned; its live lock is held, so the pid is its own.
    unsafe { libc::kill(record.host_pid as i32, libc::SIGKILL) };
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
    let answers = answers_to_7(&got);
    assert_eq!(answers, 1, "the answer reached the agent {answers} times: {got:?}");
}
