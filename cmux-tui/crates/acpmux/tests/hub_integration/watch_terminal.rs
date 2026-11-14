//! A chat handed to a cmux terminal stays writable (Leo, 2026-11-14, on keeping the chat as a View
//! Only watch, answering "chat writable in both directions": "this is obviously what we need").
//! Two live views of one session: a prompt sent from the chat goes into the terminal's own
//! Claude Code (its inbox), mid-turn queued for the turn's end as the terminal takes it, exactly
//! once and in order; a prompt typed in the terminal shows in the chat at once, mid-turn too.
//! The terminal's Claude Code is `tests/fake_claude_terminal.py`.
use super::*;
use std::io::Write as _;

/// The terminal's Claude Code, its typed input and its log of what it got.
struct Terminal {
    child: std::process::Child,
    log: std::path::PathBuf,
}

impl Terminal {
    fn start(
        root: &std::path::Path,
        asid: &str,
        transcript: &std::path::Path,
        turn_ms: u64,
    ) -> Self {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude_terminal.py");
        let log = root.join(format!("terminal-{}.log", uuid::Uuid::now_v7()));
        let child = std::process::Command::new("python3")
            .arg(fake)
            .env("FAKE_CONFIG", root.join("claude"))
            .env("FAKE_SESSION", asid)
            .env("FAKE_TRANSCRIPT", transcript)
            .env("FAKE_LOG", &log)
            .env("FAKE_TURN_MS", turn_ms.to_string())
            .current_dir(root.join("project"))
            .stdin(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let t = Terminal { child, log };
        for _ in 0..400 {
            if t.lines("READY").len() == 1 {
                return t;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the fake terminal Claude Code did not start");
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }

    /// The person types `text` and presses Enter in the terminal.
    fn type_line(&mut self, text: &str) {
        let stdin = self.child.stdin.as_mut().unwrap();
        writeln!(stdin, "{text}").unwrap();
        stdin.flush().unwrap();
    }

    /// The `kind` lines of the log: (monotonic ns, text).
    fn lines(&self, kind: &str) -> Vec<(u64, String)> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| {
                let mut parts = l.splitn(3, ' ');
                (parts.next()? == kind).then_some(())?;
                let at = parts.next()?.parse().ok()?;
                let text: String = serde_json::from_str(parts.next()?).ok()?;
                Some((at, text))
            })
            .collect()
    }

    fn texts(&self, kind: &str) -> Vec<String> {
        self.lines(kind).into_iter().map(|(_, t)| t).collect()
    }

    /// Waits (up to 15 s) until the log holds `n` `kind` lines.
    async fn until(&self, kind: &str, n: usize) -> Vec<String> {
        for _ in 0..1500 {
            if self.lines(kind).len() >= n {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        self.texts(kind)
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        // Our own child, by its handle.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The monotonic clock the fake's log uses, in ns.
fn mono_ns() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime writes the timespec it is given.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    u64::try_from(ts.tv_sec).unwrap() * 1_000_000_000 + u64::try_from(ts.tv_nsec).unwrap()
}

/// A chat acpmux ran, handed to a terminal as Toggle Terminal and Chat hands it
/// (`acpmux resume-here`): the terminal's Claude Code runs the conversation and the chat watches
/// it. (hub, chat, transcript, terminal, root, the chat's first prompt).
async fn handed_to_terminal(
    turn_ms: u64,
) -> (Arc<Hub>, String, std::path::PathBuf, Terminal, std::path::PathBuf, String) {
    let (hub, sid, file, gate, turn, text, root) = chat_mid_turn().await;
    std::fs::write(&gate, "go").unwrap();
    turn.await.unwrap().unwrap();
    let project = root.join("project");
    let asid = file.file_stem().unwrap().to_string_lossy().into_owned();
    append(&file, &[claude_answer(&project, &asid, "before-gate after-gate")]);
    let terminal = Terminal::start(&root, &asid, &file, turn_ms);
    // `resume-here` asks for the hand-off as the process that then becomes Claude Code.
    let mut c = connect(&hub).await;
    let released = c
        .request(
            "_acpmux/release_to_watch",
            json!({"sessionId": sid, "terminalPid": terminal.pid()}),
        )
        .await
        .unwrap();
    assert_eq!(released["session"]["watching"], "claude", "{released}");
    let _ = std::fs::remove_file(&gate);
    (hub, sid, file, terminal, root, text)
}

/// Sends `text` from the chat as prompt `id`; the call answers when the turn it ran ended.
fn send(
    hub: &Arc<Hub>,
    sid: &str,
    text: &str,
    id: &str,
) -> tokio::task::JoinHandle<Result<Value, String>> {
    let hub = hub.clone();
    let p = prompt(sid, text, Some(id));
    tokio::spawn(async move {
        let mut c = connect(&hub).await;
        c.request(method::SESSION_PROMPT, p).await
    })
}

/// Test 1. While the terminal drives the session, the chat stays writable: what it sends reaches
/// the terminal's live Claude Code, mid-turn included, queued and run after the turn, exactly
/// once and in order, and the chat shows each prompt once, as sent.
#[tokio::test]
async fn a_chat_send_reaches_the_terminals_harness_mid_turn_once_and_in_order() {
    let (hub, sid, _file, mut terminal, root, first) = handed_to_terminal(700).await;
    // The person works in the terminal: a turn runs there.
    terminal.type_line("typed in the terminal");
    assert_eq!(terminal.until("RUN", 1).await, ["typed in the terminal"]);
    // Mid-turn, two prompts from the chat, then a resend of the first under its id.
    let one = send(&hub, &sid, "from the chat 1", "chat-1");
    assert_eq!(terminal.until("RECV", 2).await[1], "from the chat 1");
    let two = send(&hub, &sid, "from the chat 2", "chat-2");
    assert_eq!(terminal.until("RECV", 3).await[2], "from the chat 2");
    let again = send(&hub, &sid, "from the chat 1", "chat-1");
    // Run after the running turn, in order.
    let one = tokio::time::timeout(Duration::from_secs(20), one).await.unwrap().unwrap();
    let two = tokio::time::timeout(Duration::from_secs(20), two).await.unwrap().unwrap();
    let again = tokio::time::timeout(Duration::from_secs(20), again).await.unwrap().unwrap();
    let one = one.unwrap();
    assert_eq!(one["_meta"]["acpmux"]["answered"], true, "{one}");
    assert_eq!(two.unwrap()["_meta"]["acpmux"]["answered"], true);
    assert_eq!(again.unwrap()["_meta"]["acpmux"]["duplicate"], true, "a resend is not sent again");
    let ran = terminal.lines("RUN");
    let ended = terminal.lines("END");
    assert_eq!(
        ran.iter().map(|(_, t)| t.as_str()).collect::<Vec<_>>(),
        ["typed in the terminal", "from the chat 1", "from the chat 2"],
        "each once, in order"
    );
    assert!(ran[1].0 > ended[0].0, "the chat's prompt waited for the running turn to end");
    assert_eq!(terminal.texts("RECV").len(), 3, "the harness got each prompt exactly once");
    // The chat shows each prompt once, the chat's under their ids.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        prompts(&hub, &sid),
        [first.as_str(), "typed in the terminal", "from the chat 1", "from the chat 2"]
    );
    let shown: Vec<_> = hub
        .events(&sid, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "user_message")
        .map(|e| e.msg["promptId"].as_str().unwrap_or_default().to_owned())
        .collect();
    assert_eq!(&shown[2..], ["chat-1", "chat-2"]);
    assert!(answers(&hub, &sid).iter().any(|a| a == "ANSWER from the chat 2"));
    // The chat is not View Only: a client keeps its composer (webviews `terminalWatch`).
    let summary = hub.session_summary(&hub.resolve(&sid).unwrap());
    assert_eq!(summary["tags"]["via"], "terminal", "{summary}");
    assert_eq!(summary["tags"]["bridge"], "claude", "{summary}");
    drop(terminal);
    let _ = std::fs::remove_dir_all(&root);
}

/// Test 2. A prompt typed in the terminal shows in the chat at once: while idle by its prompt
/// line, mid-turn by the line Claude Code writes when it queues it, long before the turn takes
/// it. Each shows once, and its answer after it.
#[tokio::test]
async fn a_prompt_typed_in_the_terminal_shows_in_the_chat_at_once() {
    let (hub, sid, _file, mut terminal, root, first) = handed_to_terminal(1500).await;
    terminal.type_line("typed while idle");
    let shown = until_prompts(&hub, &sid, 2).await;
    assert_eq!(shown, [first.as_str(), "typed while idle"]);
    assert_eq!(terminal.until("RUN", 1).await, ["typed while idle"]);
    // Mid-turn: the turn runs for 1.5 s; the typed prompt must show well before it ends.
    terminal.type_line("typed mid-turn");
    let shown = until_prompts(&hub, &sid, 3).await;
    assert_eq!(shown, [first.as_str(), "typed while idle", "typed mid-turn"]);
    assert!(terminal.texts("END").is_empty(), "shown while the turn still ran");
    // The turn takes it at its tool boundary and answers both: still once each.
    assert_eq!(terminal.until("END", 2).await.len(), 2);
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(prompts(&hub, &sid), [first.as_str(), "typed while idle", "typed mid-turn"]);
    assert_eq!(
        answers(&hub, &sid).last().map(String::as_str),
        Some("ANSWER typed while idle + typed mid-turn")
    );
    // The chat's turns are settled: none is left open.
    let k = kinds(&hub, &sid);
    let started = k.iter().filter(|k| *k == "turn_started").count();
    let ended = k.iter().filter(|k| *k == "turn_end").count();
    assert_eq!(started, ended, "{k:?}");
    drop(terminal);
    let _ = std::fs::remove_dir_all(&root);
}

/// The terminal's Claude Code with no inbox (cross-session messaging off): a chat send is refused
/// with why and that it can be tried again, never as View Only and never lost silently.
#[tokio::test]
async fn a_terminal_harness_with_no_inbox_refuses_with_why() {
    let (hub, sid, file, gate, turn, _, root) = chat_mid_turn().await;
    std::fs::write(&gate, "go").unwrap();
    turn.await.unwrap().unwrap();
    let asid = file.file_stem().unwrap().to_string_lossy().into_owned();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude_terminal.py");
    let log = root.join("noinbox.log");
    let mut child = std::process::Command::new("python3")
        .arg(fake)
        .env("FAKE_CONFIG", root.join("claude"))
        .env("FAKE_SESSION", &asid)
        .env("FAKE_TRANSCRIPT", &file)
        .env("FAKE_LOG", &log)
        .env("FAKE_NO_INBOX", "1")
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    for _ in 0..400 {
        if std::fs::read_to_string(&log).is_ok_and(|l| l.contains("READY")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let mut c = connect(&hub).await;
    c.request("_acpmux/release_to_watch", json!({"sessionId": sid, "terminalPid": child.id()}))
        .await
        .unwrap();
    let refused = c.request(method::SESSION_PROMPT, prompt(&sid, "hello", None)).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("bridge.no_inbox")), "{refused:?}");
    // The terminal ended: the chat is a watch as any other (Take Over runs it here).
    let _ = child.kill();
    let _ = child.wait();
    let after = c.request(method::SESSION_PROMPT, prompt(&sid, "hello", None)).await;
    assert!(after.as_ref().is_err_and(|e| e.contains("watch.read_only")), "{after:?}");
    let _ = std::fs::remove_file(&gate);
    let _ = std::fs::remove_dir_all(&root);
}

/// Latencies over 20 runs with the fake harness: chat send -> the terminal's harness received it,
/// and terminal typed -> the chat shows the prompt.
#[tokio::test]
async fn terminal_and_chat_latencies() {
    let (hub, sid, _file, mut terminal, root, _) = handed_to_terminal(20).await;
    let (mut sent, mut typed) = (Vec::new(), Vec::new());
    for i in 0..20 {
        let text = format!("typed {i}");
        let n = prompts(&hub, &sid).len();
        let at = std::time::Instant::now();
        terminal.type_line(&text);
        for _ in 0..2000 {
            if prompts(&hub, &sid).len() > n {
                break;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        typed.push(at.elapsed());
        assert_eq!(prompts(&hub, &sid).last(), Some(&text));
        terminal.until("END", 2 * i + 1).await;
        let text = format!("sent {i}");
        let before = mono_ns();
        let reply = send(&hub, &sid, &text, &format!("lat-{i}"));
        let got = terminal.until("RECV", 2 * i + 2).await;
        assert_eq!(got.last(), Some(&text));
        let at = terminal.lines("RECV").last().unwrap().0;
        sent.push(Duration::from_nanos(at.saturating_sub(before)));
        tokio::time::timeout(Duration::from_secs(10), reply).await.unwrap().unwrap().unwrap();
    }
    let stats = |mut v: Vec<Duration>| {
        v.sort();
        (v[v.len() / 2], v[v.len() * 95 / 100])
    };
    let (s50, s95) = stats(sent);
    let (t50, t95) = stats(typed);
    eprintln!("terminal chat: chat send -> harness received p50 {s50:?} p95 {s95:?} over 20 runs");
    eprintln!("terminal chat: terminal typed -> chat row p50 {t50:?} p95 {t95:?} over 20 runs");
    assert!(s95 < Duration::from_millis(500), "send p95 {s95:?}");
    assert!(t95 < Duration::from_millis(500), "typed p95 {t95:?}");
    drop(terminal);
    let _ = std::fs::remove_dir_all(&root);
}
