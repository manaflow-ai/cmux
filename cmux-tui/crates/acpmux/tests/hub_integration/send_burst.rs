//! Bursts of other sessions' messages into one chat (`hub/inbox.rs`, `hub/queue.rs`): many
//! sessions send at once, each sends the same text twice, and each resends one prompt id. Every
//! message is delivered exactly once and kept in the receiver's log under its text, every waiting
//! sender is answered, and the receiver ends idle with nothing queued. Claude's desktop app fixed a
//! chat stuck busy after another session sent it the same message twice or many at once, messages
//! from other sessions dropped or gone from the transcript, and a sender left thinking for minutes.

use super::*;
use std::collections::BTreeSet;

/// Sessions that send at once.
const SENDERS: usize = 24;
/// Bursts one chat takes, one after another.
const ROUNDS: usize = 3;
/// How long a sender may wait for its answer.
const SENDER_WAIT: Duration = Duration::from_secs(90);

/// Session `caller`'s send of `text` to `target`, as its agent's `acpmux send` makes it.
fn message(target: &str, prompt_id: &str, text: &str, resend: bool) -> Value {
    json!({
        "sessionId": target,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id, "class": "blocker", "resend": resend}},
    })
}

/// Sends `params` on a connection of its own that proved it runs in session `caller` (the CLI
/// opens one per send), once `go` lets every sender go; the prompt's answer.
async fn send_as(
    hub: Arc<Hub>,
    caller: String,
    params: Value,
    go: Arc<tokio::sync::Barrier>,
) -> Result<Value, String> {
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub, in_rx, out_tx));
    let token = acpmux::hub::person::caller_token(&caller);
    let hello = json!({"protocolVersion": 1,
                       "_meta": {"acpmux": {"callerSession": {"sessionId": caller, "token": token}}}});
    tx.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    answer(&mut rx, 1).await?;
    go.wait().await;
    tx.send(Message::request(2, method::SESSION_PROMPT, params).to_line()).await.unwrap();
    match tokio::time::timeout(SENDER_WAIT, answer(&mut rx, 2)).await {
        Ok(answer) => answer,
        Err(_) => Err(format!("no answer within {SENDER_WAIT:?}")),
    }
}

/// The answer to request `want` on `rx`.
async fn answer(rx: &mut mpsc::Receiver<String>, want: i64) -> Result<Value, String> {
    loop {
        let line = rx.recv().await.ok_or_else(|| "connection closed".to_owned())?;
        if let Ok(Message::Response { id, result, error }) = Message::parse(&line)
            && id.as_i64() == Some(want)
        {
            return match error {
                Some(e) => Err(e.message),
                None => Ok(result.unwrap_or(Value::Null)),
            };
        }
    }
}

/// The receiver `id` once it has settled: no turn, nothing queued, ready. Panics past 30 s.
async fn settled(hub: &Arc<Hub>, id: &str) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let session = hub.resolve(id).unwrap();
        let summary = hub.session_summary(&session);
        let idle = session.turn().is_none()
            && summary["status"] == "ready"
            && summary["queue"].as_array().is_none_or(|q| q.is_empty());
        if idle {
            return summary;
        }
        assert!(tokio::time::Instant::now() < deadline, "the receiver stays busy: {summary}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The prompt ids a notice's provenance carries.
fn carried(msg: &Value) -> Vec<String> {
    let threads = msg["_meta"]["provenance"]["threads"].as_array().cloned().unwrap_or_default();
    threads
        .iter()
        .flat_map(|t| t["promptIds"].as_array().cloned().unwrap_or_default())
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect()
}

/// The sending sessions, made before the receiver gets busy.
async fn senders(c: &mut TestClient) -> Vec<String> {
    let mut senders = Vec::new();
    for n in 0..SENDERS {
        senders.push(new_session(c, &format!("sender-{n}")).await);
    }
    senders
}

/// Every one of `senders` sends the same text twice under two prompt ids, plus a resend of the
/// first id, to `receiver`, all at once; asserts each id is delivered once and logged under its
/// text, every sender answered, and the receiver idle at the end. Each round's words differ: a
/// third near-identical message in a row pauses the pair (`agent_pairs.rs`), on purpose.
async fn burst(hub: &Arc<Hub>, receiver: &str, senders: &[String], inbox: bool, round: usize) {
    const SUBJECTS: [&str; ROUNDS] =
        ["blocked on the deploy", "question about schema migration", "flaky suite needs eyes"];
    let go = Arc::new(tokio::sync::Barrier::new(SENDERS * 3));
    let mut sends = tokio::task::JoinSet::new();
    let mut expected = BTreeMap::new();
    for (n, sender) in senders.iter().enumerate() {
        let text = format!("{} #{} from sender {n}", SUBJECTS[round], 1000 + n);
        for (copy, resend) in [("a", false), ("b", false), ("a", true)] {
            let pid = format!("burst-{round}-{n}-{copy}");
            expected.insert(pid.clone(), text.clone());
            let params = message(receiver, &pid, &text, resend);
            let (hub, sender, go) = (hub.clone(), sender.clone(), go.clone());
            sends.spawn(async move { (pid, resend, send_as(hub, sender, params, go).await) });
        }
    }
    let mut unanswered = Vec::new();
    while let Some(done) = sends.join_next().await {
        let (pid, resend, answer) = done.unwrap();
        if let Err(e) = answer {
            unanswered.push(format!("{pid} (resend: {resend}): {e}"));
        }
    }
    assert!(unanswered.is_empty(), "senders left waiting or failed: {unanswered:#?}");

    let summary = settled(hub, receiver).await;
    let events = hub.events(receiver, 0, 1_000_000).unwrap();
    let text_of = |e: &acpmux::store::EventRecord| e.msg["text"].as_str().unwrap_or("").to_owned();
    // Delivered: carried by an inbox notice, run as a turn's prompt, or joined into another
    // agent message's turn (`digest.rs`). Logged: the record that keeps the message's own text.
    let mut delivered: BTreeMap<String, usize> = BTreeMap::new();
    let mut logged: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut turn_text: BTreeMap<String, String> = BTreeMap::new();
    let mut joined: BTreeMap<String, String> = BTreeMap::new();
    for e in &events {
        let pid = e.msg["promptId"].as_str().unwrap_or("").to_owned();
        match e.kind.as_str() {
            "user_message" if e.msg["_meta"]["provenance"]["kind"] == "inbox_notice" => {
                for carried in carried(&e.msg) {
                    *delivered.entry(carried).or_default() += 1;
                }
            }
            "user_message" => {
                *delivered.entry(pid.clone()).or_default() += 1;
                turn_text.insert(pid, text_of(e));
            }
            "dequeued" => {
                if let Some(into) = e.msg["joinedPromptId"].as_str() {
                    *delivered.entry(pid.clone()).or_default() += 1;
                    joined.insert(pid, into.to_owned());
                }
            }
            "inbox" if inbox => logged.entry(pid).or_default().push(text_of(e)),
            "queued" if !inbox => logged.entry(pid).or_default().push(text_of(e)),
            _ => {}
        }
    }
    let mut wrong = Vec::new();
    for (pid, text) in &expected {
        let times = delivered.get(pid).copied().unwrap_or(0);
        if times != 1 {
            wrong.push(format!("{pid} delivered {times} times"));
        }
        match logged.get(pid).map(Vec::as_slice) {
            Some([t]) if t.contains(text.as_str()) => {}
            other => wrong.push(format!("{pid} logged as {other:?}, sent {text:?}")),
        }
        // Run as a turn: that turn's prompt in the transcript has its words.
        if !inbox {
            let turn = joined.get(pid).unwrap_or(pid);
            if !turn_text.get(turn).is_some_and(|t| t.contains(text.as_str())) {
                wrong.push(format!("{pid}: its turn {turn} reads {:?}", turn_text.get(turn)));
            }
        }
    }
    let ours: BTreeSet<&String> = expected.keys().collect();
    for pid in
        delivered.keys().filter(|p| p.starts_with(&format!("burst-{round}-")) && !ours.contains(p))
    {
        wrong.push(format!("{pid} was never sent"));
    }
    assert!(wrong.is_empty(), "{wrong:#?}\nreceiver: {summary}");
}

/// An idle chat that already ran a turn: each burst goes to its inbox and wakes it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_of_doubled_messages_to_an_idle_chat_delivers_each_once_and_settles() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "coord").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    let senders = senders(&mut c).await;
    for round in 0..ROUNDS {
        burst(&hub, &id, &senders, true, round).await;
    }
}

/// A chat whose agent steers as Claude Code does, busy with a turn as each burst comes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_of_doubled_messages_to_a_busy_steering_chat_delivers_each_once_and_settles() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    busy_rounds(&hub, &mut c, true).await;
}

/// With the inbox off, each burst queues behind a busy turn and runs as turns of their own.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_of_doubled_messages_queued_as_turns_delivers_each_once_and_settles() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    busy_rounds(&hub, &mut c, false).await;
}

/// `ROUNDS` bursts, each while the person's own turn runs.
async fn busy_rounds(hub: &Arc<Hub>, c: &mut TestClient, inbox: bool) {
    let id = new_session(c, "coord").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    let senders = senders(c).await;
    for round in 0..ROUNDS {
        let busy_id = format!("p-slow-{round}");
        let busy = c.send(method::SESSION_PROMPT, prompt(&id, "slow", Some(&busy_id))).await;
        c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == *busy_id).await;
        burst(hub, &id, &senders, inbox, round).await;
        assert!(c.response(busy).await.0.is_ok());
    }
}
