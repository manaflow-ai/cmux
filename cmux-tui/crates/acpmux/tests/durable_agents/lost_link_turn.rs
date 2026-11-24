//! A turn that runs while the daemon loses its link to the agent's host (another owner takes the
//! host over and leaves; a socket that breaks is the same) ends as its agent ends it, once. Before,
//! the reader of the lost link failed every open request of the live agent with "agent process
//! closed", so the turn was logged failed (agent.exited) while the agent worked on and answered
//! after the reattach. The opposite case stays as it was: a host that really died fails the turn at
//! once.

use super::*;

/// The turns `session`'s log settled.
fn turn_results(daemon: &Daemon, session: &str) -> Vec<Value> {
    daemon.events(session).into_iter().filter(|e| e["kind"] == "turn_result").collect()
}

#[tokio::test]
async fn a_turn_open_while_the_host_link_is_lost_ends_as_its_agent_ends_it() {
    let daemon = Daemon::new("lostturn", "approve-all");
    let (session, host, mut client) = gated_turn(&daemon).await;
    let record: acpmux::agent_host::HostRecord = serde_json::from_value(host.clone()).unwrap();
    match acpmux::agent_host::link::connect(record, 0).await.expect("take over") {
        acpmux::agent_host::link::Connect::Ready(link, _) => drop(link),
        _ => panic!("the host refused a same-build owner"),
    }
    // The agent goes on and ends its turn while (or after) the daemon reaches it again.
    std::fs::write(daemon.home.join(format!("gate-{session}")), b"go").unwrap();
    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    assert_eq!(
        result["msg"]["status"], "completed",
        "the turn did not end as its agent ended it: {result}"
    );
    // The prompt's own answer: the agent's, once.
    let mut answers = Vec::new();
    while let Ok(Ok(Some(line))) =
        tokio::time::timeout(Duration::from_secs(3), client.lines.next_line()).await
    {
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            answers.push(v);
        }
    }
    assert_eq!(answers.len(), 1, "the prompt was answered {} times: {answers:?}", answers.len());
    assert_eq!(answers[0]["result"]["stopReason"], "end_turn", "{}", answers[0]);
    assert_eq!(turn_results(&daemon, &session).len(), 1, "{:#}", json!(daemon.events(&session)));
    assert!(
        daemon.events(&session).iter().any(|e| chunk(e, "after-gate")),
        "the agent's output was lost"
    );
    // SAFETY: the host's own pid from its record; ends this test's agent.
    unsafe { libc::kill(host["host_pid"].as_i64().unwrap() as i32, libc::SIGTERM) };
}

/// The opposite case: a host that really died fails its open turn at once, as before, never holds it.
#[tokio::test]
async fn a_turn_whose_host_died_fails_at_once() {
    let daemon = Daemon::new("deadturn", "approve-all");
    let (session, host, client) = gated_turn(&daemon).await;
    let started = Instant::now();
    // SAFETY: the host's own pid from its record; ends this test's agent.
    unsafe { libc::kill(host["host_pid"].as_i64().unwrap() as i32, libc::SIGKILL) };
    let harness = host["harness_pid"].as_i64().unwrap();
    // SAFETY: as above; the host's harness, so nothing of this test outlives it.
    unsafe { libc::killpg(harness as i32, libc::SIGKILL) };
    let result = daemon.wait_event(&session, "turn_result", |e| e["kind"] == "turn_result");
    let took = started.elapsed();
    assert_eq!(result["msg"]["status"], "failed", "{result}");
    assert_eq!(result["msg"]["errorKind"], "agent.exited", "{result}");
    assert!(took < Duration::from_secs(10), "a dead host held its turn {took:?}");
    drop(client);
}
