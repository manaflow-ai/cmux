//! A Claude stream-json translator panic in an `__agent-host` (cmuxterm-hq
//! `docs/handbook/durable-state-beside-crash-prone-code.md`): the host keeps the harness's pipes,
//! so a panic on one stdout line drops that line, and the agent and its turn go on.
//!
//! Before, the panic ended the host. A translated harness gets no custody (`custody.rs`), so the
//! harness died on its next write, the turn failed with `agent.exited`, and the hub started a
//! fresh agent with the "interrupted" auto-resume prompt.

use super::*;

/// Words the stand-in Claude streams (`panic-line: N`, `tests/fake_claude.py`), with the line
/// the translator panics on halfway.
const WORDS: usize = 40;

fn word(e: &Value) -> Option<usize> {
    if e["msg"]["params"]["update"]["sessionUpdate"] != "agent_message_chunk" {
        return None;
    }
    let text = e["msg"]["params"]["update"]["content"]["text"].as_str()?;
    text.strip_prefix("word")?.trim_end().parse().ok()
}

/// CPU milliseconds and RSS KB of `pid` (Linux `/proc`), for what a crash costs.
fn cost(pid: i64) -> Option<(u64, u64)> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let fields: Vec<&str> = stat.rsplit_once(") ")?.1.split(' ').collect();
    let ticks: u64 = fields.get(11)?.parse::<u64>().ok()? + fields.get(12)?.parse::<u64>().ok()?;
    // SAFETY: sysconf reads a constant.
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as u64;
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    let rss = status
        .lines()
        .find_map(|l| l.strip_prefix("VmRSS:"))?
        .trim()
        .trim_end_matches(" kB")
        .parse()
        .ok()?;
    Some((ticks * 1000 / hz, rss))
}

/// The answer to request `id` on `rpc`, read off the stream (its notifications are skipped).
async fn answer(rpc: &mut Rpc, id: i64, within: Duration) -> Option<Value> {
    let deadline = Instant::now() + within;
    loop {
        let left = deadline.checked_duration_since(Instant::now())?;
        let line = tokio::time::timeout(left, rpc.lines.next_line()).await.ok()?.ok()??;
        let v: Value = serde_json::from_str(&line).ok()?;
        if v.get("id") == Some(&json!(id)) {
            return Some(v);
        }
    }
}

#[tokio::test]
async fn a_translator_panic_mid_turn_keeps_the_host_and_the_turn() {
    let daemon = Daemon::claude_router("trpanic", &[("ACPMUX_TEST_TRANSLATOR_PANIC", "1")]);
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    let warm = client
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]}),
        )
        .await;
    assert_eq!(warm["stopReason"], "end_turn", "{warm}");
    let host = daemon.host_record(&session);
    let host_pid = host["host_pid"].as_i64().unwrap();
    let harness_pid = host["harness_pid"].as_i64().unwrap();

    let started = Instant::now();
    let id = client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("panic-line: {WORDS}")}]}),
        )
        .await;
    let reply = answer(&mut client, id, Duration::from_secs(60)).await.unwrap_or(Value::Null);
    let turn_ms = started.elapsed().as_millis();

    let events = daemon.events(&session);
    let seen: Vec<usize> = events.iter().filter_map(word).collect();
    let distinct: std::collections::BTreeSet<usize> = seen.iter().copied().collect();
    let lost = (0..WORDS).filter(|i| !distinct.contains(i)).count();
    let resumed = events
        .iter()
        .filter(|e| {
            e["kind"].as_str().is_some_and(|k| k.starts_with("auto_resume"))
                || e["msg"]["params"]["_meta"]["provenance"]["kind"] == "auto_resume"
                || e["msg"]["_meta"]["provenance"]["kind"] == "auto_resume"
        })
        .count();
    let completed = reply["result"]["stopReason"] == "end_turn";
    let now = daemon.host_record(&session);
    let host_now = now["host_pid"].as_i64();
    let harness_now = now["harness_pid"].as_i64();
    let restarted =
        usize::from(host_now != Some(host_pid)) + usize::from(harness_now != Some(harness_pid));
    // What the crash cost: the processes it started and their CPU and memory (0 when none).
    let (cpu_ms, rss_kb) = [host_now, harness_now]
        .into_iter()
        .zip([host_pid, harness_pid])
        .filter(|(now, was)| *now != Some(*was))
        .filter_map(|(now, _)| now.and_then(cost))
        .fold((0, 0), |(c, r), (pc, pr)| (c + pc, r + pr));
    println!(
        "TRANSLATOR-PANIC turns_cut={} words_lost={lost} processes_restarted={restarted} restart_cpu_ms={cpu_ms} restart_rss_kb={rss_kb} turn_ms={turn_ms}",
        usize::from(!completed || resumed > 0),
    );

    assert!(alive(host_pid), "the host died with its translator");
    assert!(alive(harness_pid), "the harness died with its host's translator");
    assert!(completed, "the turn was cut: {reply}");
    assert_eq!(resumed, 0, "an auto-resume prompt was sent");
    assert_eq!(lost, 0, "words lost: {seen:?}");
    assert_eq!(restarted, 0, "a process was started again");
    // The dropped line is in the log, named.
    assert!(
        events.iter().any(|e| e.to_string().contains("translator panicked")),
        "no entry names the panic"
    );

    // The session takes a next prompt, on the same host and harness.
    let reply = client
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello again"}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert_eq!(daemon.host_record(&session)["host_pid"].as_i64(), Some(host_pid));
}
