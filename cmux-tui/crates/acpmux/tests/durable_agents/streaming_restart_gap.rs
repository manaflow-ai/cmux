//! A turn that keeps streaming across a restart with a gap, as an update relaunch makes one (the
//! old daemon stops when its app's bundle is replaced, the next starts when the app relaunches a
//! few seconds later): the next daemon logs the agent's new output within seconds of its start.
//! The relaunch-reconnect bench (scripts/cmux-next/bench_relaunch_reconnect.py) read the shown
//! chat's first live event 120 s after such a relaunch (manaflow-ai/cmuxterm-hq#6338).

use super::*;

fn ticks(daemon: &Daemon, session: &str) -> usize {
    let tick = |e: &Value| {
        e["msg"]["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
            && e["msg"]["params"]["update"]["content"]["text"]
                .as_str()
                .is_some_and(|t| t.starts_with("tick"))
    };
    daemon.events(session).iter().filter(|e| tick(e)).count()
}

#[tokio::test]
async fn a_streaming_turn_logs_new_output_within_seconds_after_a_restart_with_a_gap() {
    let mut daemon = Daemon::new("stgap", "approve-all");
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    // A word every 100 ms for 5 minutes: a reply still streaming through the restart.
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "ticking:3000:100"}]}),
        )
        .await;
    daemon.wait_event(&session, "tick5", |e| chunk(e, "tick5 "));
    let host = daemon.host_record(&session);
    let harness_pid = host["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(client);
    // The relaunch's gap: the agent streams on with no daemon (about 30 words).
    std::thread::sleep(Duration::from_secs(3));
    let before = ticks(&daemon, &session);
    let started = Instant::now();
    daemon.start();
    // Live again: the gap's backlog and then words the agent writes after the start, so at least
    // 30 (the backlog) plus 20 more (2 s of new output) past what the old daemon logged.
    let want = before + 50;
    let deadline = started + Duration::from_secs(60);
    while ticks(&daemon, &session) < want && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    let took = started.elapsed();
    let got = ticks(&daemon, &session);
    assert!(alive(harness_pid), "the agent died across the restart");
    eprintln!(
        "streaming restart gap: {got} ticks logged ({before} before), {:.1} s after the start",
        took.as_secs_f64()
    );
    assert!(
        got >= want && took < Duration::from_secs(10),
        "the next daemon logged {} new words in {:.1} s (want {} within 10 s): the adopted turn's live output waited",
        got.saturating_sub(before),
        took.as_secs_f64(),
        want - before
    );
    daemon.rpc().await.send("session/cancel", json!({"sessionId": session})).await;
}

/// The words a line from the daemon carries live: an `agent_message_chunk` notification (no id)
/// whose text starts with "tick".
fn live_tick(line: &str) -> bool {
    let Ok(v) = serde_json::from_str::<Value>(line) else { return false };
    if v.get("id").is_some() {
        return false;
    }
    let text = v.to_string();
    text.contains("agent_message_chunk") && text.contains("\"tick")
}

/// What the app's chat pane does after a relaunch (webviews direct.ts `sendAttach`): attach the
/// streaming chat with `waitLogs:false` and `eventStream:true` about a second after the daemon
/// starts, then wait for the agent's words live. The relaunch-reconnect bench saw none for 120 s
/// after an update or cold relaunch (manaflow-ai/cmuxterm-hq#6338).
#[tokio::test]
async fn a_chat_attached_right_after_a_restart_with_a_gap_gets_the_streaming_turn_live() {
    attached_after_a_gap_gets_the_turn_live("stgapa", false).await;
}

/// As the relaunch after an app update: the bundle that held the daemon's binary is replaced (the
/// old file renamed aside, a copy put back, the old one deleted, `replace_bundle` in the bench)
/// while the agent streams, the old daemon stops, and the next starts from the new file.
#[tokio::test]
async fn a_chat_attached_after_an_update_replaced_the_binary_gets_the_streaming_turn_live() {
    attached_after_a_gap_gets_the_turn_live("stgapu", true).await;
}

async fn attached_after_a_gap_gets_the_turn_live(tag: &str, update: bool) {
    let mut daemon = Daemon::new(tag, "approve-all");
    let copy = daemon.home.join("bin").join("acpmux");
    if update {
        daemon.sigterm();
        std::fs::create_dir_all(copy.parent().unwrap()).unwrap();
        std::fs::copy(daemon_env::bin(), &copy).unwrap();
        daemon.exe = copy.clone();
        daemon.start();
    }
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "ticking:3000:100"}]}),
        )
        .await;
    daemon.wait_event(&session, "tick5", |e| chunk(e, "tick5 "));
    if update {
        let aside = copy.with_extension("replaced");
        std::fs::rename(&copy, &aside).unwrap();
        std::fs::copy(&aside, &copy).unwrap();
        std::fs::remove_file(&aside).unwrap();
    }
    daemon.sigterm();
    drop(client);
    std::thread::sleep(Duration::from_secs(3));
    let started = Instant::now();
    daemon.start();
    std::thread::sleep(Duration::from_millis(500));
    let mut page = daemon.rpc().await;
    let attached = page
        .call(
            "_acpmux/attach",
            json!({"sessionId": session, "waitLogs": false, "limit": 400,
                   "kinds": ["transcript"], "eventStream": true, "visible": true}),
        )
        .await;
    let attached_after = started.elapsed();
    // 20 words (2 s of output) live within 10 s of the start.
    let deadline = started + Duration::from_secs(10);
    let mut live = 0;
    while live < 20 {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        match tokio::time::timeout(left, page.lines.next_line()).await {
            Ok(Ok(Some(line))) => live += usize::from(live_tick(&line)),
            _ => break,
        }
    }
    let took = started.elapsed();
    eprintln!(
        "attached {:.1} s after the start (page lastSeq {}); {live} live words by {:.1} s",
        attached_after.as_secs_f64(),
        attached["lastSeq"],
        took.as_secs_f64()
    );
    assert!(
        live >= 20,
        "the attached chat got {live} live words within 10 s of the restart (want 20): the adopted turn's output did not reach it"
    );
    daemon.rpc().await.send("session/cancel", json!({"sessionId": session})).await;
}

/// Whether a line from the daemon is a `background_turn` record's event, and which state it says.
fn background_state(line: &str) -> Option<&'static str> {
    if !line.contains("\"background_turn\"") {
        return None;
    }
    if line.contains("\"started\"") {
        Some("started")
    } else if line.contains("\"ended\"") {
        Some("ended")
    } else {
        None
    }
}

/// The person's own streaming turn, adopted after a restart with a gap, reaches the chat as that
/// turn's words within seconds, as the pane draws them. The pane folds every row inside a
/// running `background_turn` bracket into one muted line (webviews `foldsBackground`): a turn
/// the person did not start. The next daemon read the host's replay before it rebuilt the open
/// turn from the log (`hosts.rs` `adopt_held`: the replay, then `recover_work`), so the replayed
/// words came with no acpmux turn and opened such a bracket (`background_turn.rs`), which a
/// non-Claude agent never ends and Claude Code ends only at its result: after every restart the
/// reply streamed on, hidden in that line, until the turn ended (manaflow-ai/cmuxterm-hq#6338).
#[tokio::test]
async fn an_adopted_streaming_turn_is_shown_live_as_the_persons_own_turn() {
    let mut daemon = Daemon::new("stgaps", "approve-all");
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "ticking:3000:100"}]}),
        )
        .await;
    daemon.wait_event(&session, "tick5", |e| chunk(e, "tick5 "));
    daemon.sigterm();
    drop(client);
    std::thread::sleep(Duration::from_secs(3));
    let started = Instant::now();
    daemon.start();
    std::thread::sleep(Duration::from_millis(500));
    let mut page = daemon.rpc().await;
    let attached = page
        .call(
            "_acpmux/attach",
            json!({"sessionId": session, "waitLogs": false, "limit": 400,
                   "kinds": ["transcript"], "eventStream": true, "visible": true}),
        )
        .await;
    // A bracket the page's first records opened is still open for the live words after them.
    let mut bracket = false;
    for event in attached["events"].as_array().into_iter().flatten() {
        if let Some(state) = background_state(&event.to_string()) {
            bracket = state == "started";
        }
    }
    // 20 words drawn as the turn's own (not folded under a background turn) within 10 s.
    let deadline = started + Duration::from_secs(10);
    let (mut shown, mut folded) = (0, 0);
    while shown < 20 {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        match tokio::time::timeout(left, page.lines.next_line()).await {
            Ok(Ok(Some(line))) => match background_state(&line) {
                Some(state) => bracket = state == "started",
                None if live_tick(&line) && bracket => folded += 1,
                None if live_tick(&line) => shown += 1,
                None => {}
            },
            _ => break,
        }
    }
    let took = started.elapsed();
    let brackets = daemon
        .events(&session)
        .iter()
        .filter(|e| e["kind"] == "background_turn" && e["msg"]["state"] == "started")
        .count();
    eprintln!(
        "adopted turn: {shown} words shown and {folded} folded under a background turn by {:.1} s; {brackets} background_turn started record(s)",
        took.as_secs_f64()
    );
    assert!(
        shown >= 20 && brackets == 0,
        "after the restart the chat showed {shown} of the turn's words within 10 s and folded {folded} under {brackets} background turn(s): the adopted turn was taken for one the person did not start"
    );
    daemon.rpc().await.send("session/cancel", json!({"sessionId": session})).await;
}
