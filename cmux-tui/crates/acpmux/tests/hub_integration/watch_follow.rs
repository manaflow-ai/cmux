//! A watched chat follows its transcript as the other app writes it (Leo 2026-11-12: terminal and
//! chat are two live views of one session, a toggle under 100 ms, no lost or duplicated
//! messages). Each line the terminal's Claude Code appends reaches the chat's client as a
//! history update within 100 ms, mid-turn and after a quiet spell, each exactly once and in order.
use super::*;

/// One Claude transcript line with `text`: a prompt or an answer.
fn line(project: &std::path::Path, id: &str, text: &str, prompt: bool) -> Value {
    if prompt {
        json!({"type": "user", "cwd": project, "sessionId": id, "timestamp": "2026-11-14T09:00:00.000Z", "message": {"role": "user", "content": text}})
    } else {
        json!({"type": "assistant", "cwd": project, "sessionId": id, "timestamp": "2026-11-14T09:00:01.000Z", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}})
    }
}

/// A watched Claude chat (its client attached) over a transcript with one finished turn.
async fn watched_claude()
-> (Arc<Hub>, TestClient, std::path::PathBuf, std::path::PathBuf, String, String) {
    let (hub, mut c, root) = watch_setup().await;
    let id = uuid::Uuid::now_v7().to_string();
    let project = root.join("project");
    let file = root.join(format!("claude/projects/-tmp-watch/{id}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    append(
        &file,
        &[line(&project, &id, "first prompt", true), line(&project, &id, "first answer", false)],
    );
    backdate(&file);
    let s = c.request(method::SESSION_NEW, watch("fakeclaude", &id)).await.unwrap();
    let sid = s["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(until_prompts(&hub, &sid, 1).await, ["first prompt"]);
    (hub, c, root, file, id, sid)
}

/// Appends `text` as one line and returns how long until the client hears a notification that
/// carries it (the chat's history update).
async fn appended_to_shown(
    c: &mut TestClient,
    file: &std::path::Path,
    record: Value,
    text: &str,
) -> Duration {
    let at = std::time::Instant::now();
    append(file, &[record]);
    loop {
        let got = tokio::time::timeout(Duration::from_secs(10), c.rx.recv())
            .await
            .unwrap_or_else(|_| panic!("{text} never reached the chat"))
            .expect("connection closed");
        if got.contains(text) {
            return at.elapsed();
        }
    }
}

/// p50, p95 and max of `samples`, in ms.
fn summary(samples: &mut [Duration]) -> (f64, f64, f64) {
    samples.sort();
    let ms = |d: Duration| d.as_secs_f64() * 1000.0;
    let at = |q: f64| samples[((samples.len() as f64 - 1.0) * q).round() as usize];
    (ms(at(0.5)), ms(at(0.95)), ms(*samples.last().unwrap()))
}

/// `n` lines a turn writes, at mid-turn spacing (20 to 300 ms apart, a fixed sequence):
/// append-to-shown of each.
async fn mid_turn(
    c: &mut TestClient,
    file: &std::path::Path,
    project: &std::path::Path,
    id: &str,
    n: usize,
) -> Vec<Duration> {
    let mut samples = Vec::with_capacity(n);
    let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
    for i in 0..n {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        tokio::time::sleep(Duration::from_millis(20 + seed % 281)).await;
        let text = format!("mid-turn line {i:04}");
        samples.push(appended_to_shown(c, file, line(project, id, &text, i % 2 == 0), &text).await);
    }
    samples
}

/// Ignored: a wall-clock percentile bound depends on the load beside it (cmux-source-scan
/// `timing_ratio`). The default run's check is `hub::watch::idle_tests::
/// a_written_line_shows_from_its_file_event_before_any_timed_check`, on the paused clock.
/// `cargo test -p acpmux --test hub_integration mid_turn_lines -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn mid_turn_lines_reach_the_chat_within_100_ms_p95() {
    let (_hub, mut c, root, file, id, _sid) = watched_claude().await;
    let mut samples = mid_turn(&mut c, &file, &root.join("project"), &id, 100).await;
    let (p50, p95, max) = summary(&mut samples);
    eprintln!(
        "mid-turn append -> history update, 100 lines: p50 {p50:.1} ms, p95 {p95:.1} ms, max {max:.1} ms"
    );
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        p95 < 100.0,
        "mid-turn lines reach the chat at p95 {p95:.1} ms, over 100 ms (p50 {p50:.1}, max {max:.1})"
    );
}

/// The bench of the PR: 100 mid-turn lines, then `WATCH_FOLLOW_QUIET` (default 5) lines each
/// written after 31 s of quiet (past the check's 30 s fast window). Ignored: it takes minutes.
/// `cargo test -p acpmux --test hub_integration watch_follow_bench -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn watch_follow_bench() {
    let (_hub, mut c, root, file, id, _sid) = watched_claude().await;
    let project = root.join("project");
    let mut active = mid_turn(&mut c, &file, &project, &id, 100).await;
    let quiet_n: usize =
        std::env::var("WATCH_FOLLOW_QUIET").ok().and_then(|n| n.parse().ok()).unwrap_or(5);
    let mut quiet = Vec::new();
    for i in 0..quiet_n {
        tokio::time::sleep(Duration::from_secs(31)).await;
        let text = format!("after quiet {i:02}");
        quiet.push(appended_to_shown(&mut c, &file, line(&project, &id, &text, true), &text).await);
    }
    let _ = std::fs::remove_dir_all(&root);
    let (a50, a95, amax) = summary(&mut active);
    eprintln!("| case | n | p50 ms | p95 ms | max ms |");
    eprintln!("| mid-turn (20-300 ms apart) | 100 | {a50:.1} | {a95:.1} | {amax:.1} |");
    if !quiet.is_empty() {
        let (q50, q95, qmax) = summary(&mut quiet);
        eprintln!("| first line after 31 s quiet | {quiet_n} | {q50:.1} | {q95:.1} | {qmax:.1} |");
    }
}

/// Lines written in bursts, each line in two writes (the reader sees half lines), while events
/// fire: every line shows exactly once, in order, and nothing more comes after.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn bursts_of_half_written_lines_show_each_line_once_in_order() {
    use std::io::Write;
    let (hub, c, root, file, id, sid) = watched_claude().await;
    // The client stays connected; what it hears is drained.
    let TestClient { tx: _tx, mut rx, .. } = c;
    tokio::spawn(async move { while rx.recv().await.is_some() {} });
    let project = root.join("project");
    let mut expected = vec!["first prompt".to_owned()];
    let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
    for burst in 0..10 {
        for i in 0..20 {
            let text = format!("burst {burst:02} line {i:02}");
            let bytes = format!("{}\n", line(&project, &id, &text, true)).into_bytes();
            let (head, tail) = bytes.split_at(bytes.len() / 2);
            f.write_all(head).unwrap();
            f.flush().unwrap();
            if i % 5 == 0 {
                // Let a check see the half line.
                tokio::time::sleep(Duration::from_millis(3)).await;
            }
            f.write_all(tail).unwrap();
            f.flush().unwrap();
            expected.push(text);
        }
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    let shown = until_prompts(&hub, &sid, expected.len()).await;
    assert_eq!(shown, expected, "every line once, in order");
    // Late checks and events add nothing.
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(prompts(&hub, &sid), expected, "nothing shown twice after the bursts");
    let _ = std::fs::remove_dir_all(&root);
}
