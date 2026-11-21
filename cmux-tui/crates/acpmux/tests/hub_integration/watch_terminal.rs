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
    /// Starts the terminal's Claude Code. `hand_off`: the daemon's unix socket and the chat it asks
    /// to take over first, from its own process, as `acpmux resume-here` does. `env`: more of the
    /// fake's settings (`FAKE_NO_INBOX`, `FAKE_NAMED_PID`).
    async fn start(
        root: &std::path::Path,
        asid: &str,
        transcript: &std::path::Path,
        turn_ms: u64,
        hand_off: Option<(&std::path::Path, &str)>,
        env: &[(&str, String)],
    ) -> Self {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude_terminal.py");
        let log = root.join(format!("terminal-{}.log", uuid::Uuid::now_v7()));
        let mut cmd = std::process::Command::new("python3");
        cmd.arg(fake)
            .env("FAKE_CONFIG", root.join("claude"))
            .env("FAKE_SESSION", asid)
            .env("FAKE_TRANSCRIPT", transcript)
            .env("FAKE_LOG", &log)
            .env("FAKE_TURN_MS", turn_ms.to_string())
            .current_dir(root.join("project"))
            .stdin(std::process::Stdio::piped());
        if let Some((sock, chat)) = hand_off {
            cmd.env("FAKE_DAEMON_SOCK", sock).env("FAKE_CHAT", chat);
        }
        for (k, v) in env {
            cmd.env(k, v);
        }
        let child = cmd.spawn().unwrap();
        let t = Terminal { child, log };
        for _ in 0..1000 {
            if t.lines("READY").len() == 1 {
                return t;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("the fake terminal Claude Code did not start");
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

/// `hub` on a unix socket of its own under `root`, as the daemon listens; its path.
async fn listen(hub: &Arc<Hub>, root: &std::path::Path) -> std::path::PathBuf {
    let path = root.join("d.sock");
    let listener = acpmux::server::bind_unix(&path).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    path
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
    handed_to_terminal_as(turn_ms, true).await
}

/// [`handed_to_terminal`], with Write to a chat a terminal runs (`agents.chats.terminalChatWritable`)
/// `writable` or off (its default).
async fn handed_to_terminal_as(
    turn_ms: u64,
    writable: bool,
) -> (Arc<Hub>, String, std::path::PathBuf, Terminal, std::path::PathBuf, String) {
    let (hub, sid, file, gate, turn, text, root) = chat_mid_turn().await;
    hub.set_terminal_chat_writable(writable).await;
    std::fs::write(&gate, "go").unwrap();
    turn.await.unwrap().unwrap();
    let project = root.join("project");
    let asid = file.file_stem().unwrap().to_string_lossy().into_owned();
    append(&file, &[claude_answer(&project, &asid, "before-gate after-gate")]);
    // `resume-here` asks for the hand-off over the daemon's unix socket as the process that then
    // becomes Claude Code: the daemon binds the pid the kernel gives it.
    let sock = listen(&hub, &root).await;
    let terminal = Terminal::start(&root, &asid, &file, turn_ms, Some((&sock, &sid)), &[]).await;
    let released = terminal.texts("RELEASED");
    assert_eq!(released.len(), 1, "refused: {:?}", terminal.texts("REFUSED"));
    let released: Value = serde_json::from_str(&released[0]).unwrap();
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
    hub.set_terminal_chat_writable(true).await;
    std::fs::write(&gate, "go").unwrap();
    turn.await.unwrap().unwrap();
    let asid = file.file_stem().unwrap().to_string_lossy().into_owned();
    let sock = listen(&hub, &root).await;
    let no_inbox = [("FAKE_NO_INBOX", "1".to_owned())];
    let terminal = Terminal::start(&root, &asid, &file, 300, Some((&sock, &sid)), &no_inbox).await;
    assert_eq!(terminal.texts("RELEASED").len(), 1, "{:?}", terminal.texts("REFUSED"));
    let mut c = connect(&hub).await;
    let refused = c.request(method::SESSION_PROMPT, prompt(&sid, "hello", None)).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("bridge.no_inbox")), "{refused:?}");
    // The terminal ended: the chat is a watch as any other at once (Take Over runs it here),
    // its terminal tags gone, so a client shows Take Over and Continue in New Chat again.
    drop(terminal);
    let mut tags = Value::Null;
    for _ in 0..500 {
        tags = hub.session_summary(&hub.resolve(&sid).unwrap())["tags"].clone();
        if tags.get("via").is_none() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(tags.get("via").is_none() && tags.get("bridge").is_none(), "{tags}");
    let after = c.request(method::SESSION_PROMPT, prompt(&sid, "hello", None)).await;
    assert!(after.as_ref().is_err_and(|e| e.contains("watch.read_only")), "{after:?}");
    let _ = std::fs::remove_file(&gate);
    let _ = std::fs::remove_dir_all(&root);
}

/// A `terminalPid` the kernel did not give for its caller binds nothing and releases nothing
/// (review P2-F1): not over a connection with no peer pid (a Windows pipe, a credential read that
/// failed, an in-process caller), not one naming another process. The chat keeps running here.
#[tokio::test]
async fn a_terminal_pid_the_kernel_did_not_give_releases_nothing() {
    let (hub, sid, file, gate, turn, _, root) = chat_mid_turn().await;
    hub.set_terminal_chat_writable(true).await;
    std::fs::write(&gate, "go").unwrap();
    turn.await.unwrap().unwrap();
    let not_watching = |hub: &Arc<Hub>| hub.resolve(&sid).unwrap().meta().watching.is_none();
    // No peer pid: an in-process connection.
    let mut c = connect(&hub).await;
    let named = std::process::id();
    let refused = c
        .request("_acpmux/release_to_watch", json!({"sessionId": sid, "terminalPid": named}))
        .await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("terminal")), "{refused:?}");
    assert!(not_watching(&hub), "released on a pid nobody proved");
    // Over the unix socket, naming another process than itself.
    let asid = file.file_stem().unwrap().to_string_lossy().into_owned();
    let sock = listen(&hub, &root).await;
    let other = [("FAKE_NAMED_PID", std::process::id().to_string())];
    let terminal = Terminal::start(&root, &asid, &file, 300, Some((&sock, &sid)), &other).await;
    assert!(terminal.texts("RELEASED").is_empty());
    let why = terminal.texts("REFUSED");
    assert!(why.len() == 1 && why[0].contains("watch.terminal_unverified"), "{why:?}");
    assert!(not_watching(&hub), "released on another process's pid");
    drop(terminal);
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

/// A prompt typed in the terminal whose text contains or repeats a pending chat send's still shows,
/// once, as typed; the chat's shows once under its id (review P1-F1, P2-F3: text matching used to
/// hide both terminal prompts).
#[tokio::test]
async fn terminal_prompts_overlapping_a_chat_send_each_show_once() {
    let (hub, sid, _file, mut terminal, root, first) = handed_to_terminal(1500).await;
    terminal.type_line("first");
    assert_eq!(terminal.until("RUN", 1).await, ["first"]);
    let chat = send(&hub, &sid, "test", "chat-test");
    assert_eq!(terminal.until("RECV", 2).await[1], "test");
    terminal.type_line("please test the migration");
    terminal.type_line("test");
    assert_eq!(terminal.until("RECV", 4).await.len(), 4);
    let chat = tokio::time::timeout(Duration::from_secs(20), chat).await.unwrap().unwrap();
    assert_eq!(chat.unwrap()["_meta"]["acpmux"]["answered"], true);
    tokio::time::sleep(Duration::from_millis(300)).await;
    let shown: Vec<(String, String)> = hub
        .events(&sid, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "user_message")
        .map(|e| {
            let id = e.msg["promptId"].as_str().unwrap_or_default();
            let who = if id == "chat-test" { "chat" } else { "typed" };
            (e.msg["text"].as_str().unwrap_or_default().to_owned(), who.to_owned())
        })
        .collect();
    let mut rest = shown[1..].to_vec();
    rest.sort();
    assert_eq!(shown[0].0, first);
    let want = [
        ("first", "typed"),
        ("please test the migration", "typed"),
        ("test", "chat"),
        ("test", "typed"),
    ]
    .map(|(t, w)| (t.to_owned(), w.to_owned()));
    assert_eq!(rest, want, "{shown:?}");
    drop(terminal);
    let _ = std::fs::remove_dir_all(&root);
}

/// More prompts typed mid-turn than the chat keeps as queued each show once (review P2-F4: the
/// oldest past the cap used to be forgotten as shown and shown again when the turn took it).
#[tokio::test]
async fn many_prompts_typed_mid_turn_each_show_once() {
    let (hub, sid, _file, mut terminal, root, first) = handed_to_terminal(2500).await;
    terminal.type_line("start");
    assert_eq!(terminal.until("RUN", 1).await, ["start"]);
    let typed: Vec<String> = (0..70).map(|i| format!("typed {i}")).collect();
    for t in &typed {
        terminal.type_line(t);
    }
    assert_eq!(terminal.until("RECV", 71).await.len(), 71);
    assert_eq!(terminal.until("END", 71).await.len(), 71);
    tokio::time::sleep(Duration::from_millis(400)).await;
    let mut want = vec![first.clone(), "start".to_owned()];
    want.extend(typed);
    assert_eq!(prompts(&hub, &sid), want, "each once, in order");
    drop(terminal);
    let _ = std::fs::remove_dir_all(&root);
}

/// The chat's terminal tags, as a client reads them (`via`, `bridge`).
fn terminal_tags(hub: &Arc<Hub>, sid: &str) -> (Value, Value) {
    let tags = hub.session_summary(&hub.resolve(sid).unwrap())["tags"].clone();
    (
        tags.get("via").cloned().unwrap_or(Value::Null),
        tags.get("bridge").cloned().unwrap_or(Value::Null),
    )
}

/// Write to a chat a terminal runs is off by default (Leo, 2026-11-15: "these are opt-in
/// settings"): a chat handed to a terminal is a View Only watch, as before. Nothing is bound, no
/// tag says otherwise, a send is refused as `watch.read_only` and never reaches the terminal's
/// harness, and what the person types in the terminal still shows in the chat.
#[tokio::test]
async fn with_the_setting_off_a_chat_handed_to_a_terminal_is_view_only() {
    let (hub, sid, _file, mut terminal, root, first) = handed_to_terminal_as(300, false).await;
    assert!(hub.resolve(&sid).unwrap().meta().watching.unwrap().terminal.is_none(), "bound");
    assert_eq!(terminal_tags(&hub, &sid), (Value::Null, Value::Null));
    let mut c = connect(&hub).await;
    let refused = c.request(method::SESSION_PROMPT, prompt(&sid, "from the chat", None)).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("watch.read_only")), "{refused:?}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(terminal.texts("RECV").is_empty(), "the harness got a prompt with the setting off");
    terminal.type_line("typed in the terminal");
    assert_eq!(until_prompts(&hub, &sid, 2).await, [first.as_str(), "typed in the terminal"]);
    drop(terminal);
    let _ = std::fs::remove_dir_all(&root);
}

/// Claude Code queues lines that are no prompt of the person's the way it queues a typed one: a
/// finished background task's `<task-notification>` (an `enqueue` with no origin, then a
/// `queued_command` attachment of `commandMode: task-notification` and an `absorbed_mid_turn`
/// remove), an inbox message (no enqueue text, no origin), another session's (`peer`), a slash
/// command typed mid-turn (it runs as command echoes) and a scheduled wakeup (its enqueue text
/// runs as a meta line): the shapes real 2.1 transcripts hold. None shows as a typed prompt but the
/// wakeup's with the setting on (it runs a turn), and every turn ends: with the setting off the
/// watch is base's; on, nothing it queued is left waiting to hold a turn end.
#[tokio::test]
async fn queue_lines_that_are_no_typed_prompt_never_show_as_one_nor_hold_a_turn_open() {
    for writable in [false, true] {
        queue_lines_that_are_no_typed_prompt(writable).await;
    }
}

async fn queue_lines_that_are_no_typed_prompt(writable: bool) {
    let (hub, sid, file, mut terminal, root, first) = handed_to_terminal_as(1500, writable).await;
    terminal.type_line("start");
    assert_eq!(terminal.until("RUN", 1).await, ["start"]);
    assert_eq!(until_prompts(&hub, &sid, 2).await, [first.as_str(), "start"]);
    let note = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n\
                <summary>Background command \"build\" completed (exit code 0)</summary>\n\
                </task-notification>";
    let wakeup = "Fallback: check the build";
    let source = uuid::Uuid::now_v7().to_string();
    append(
        &file,
        &[
            json!({"type": "queue-operation", "operation": "enqueue", "content": note}),
            json!({"type": "attachment", "uuid": uuid::Uuid::now_v7().to_string(), "attachment": {
                "type": "queued_command", "prompt": note, "source_uuid": source,
                "commandMode": "task-notification"}}),
            json!({"type": "queue-operation", "operation": "remove", "content": note,
                   "reason": "absorbed_mid_turn", "commandUuid": source}),
            json!({"type": "queue-operation", "operation": "enqueue"}),
            json!({"type": "attachment", "uuid": uuid::Uuid::now_v7().to_string(), "attachment": {
                "type": "queued_command", "commandMode": "prompt",
                "source_uuid": uuid::Uuid::now_v7().to_string(),
                "prompt": [{"type": "text", "text": "From another agent (acpmux), not the person:"},
                           {"type": "text", "text": "a build finished"}]}}),
            json!({"type": "attachment", "uuid": uuid::Uuid::now_v7().to_string(), "attachment": {
                "type": "queued_command", "commandMode": "prompt",
                "source_uuid": uuid::Uuid::now_v7().to_string(),
                "prompt": "<agent-message from=\"a1\">done</agent-message>",
                "origin": {"kind": "peer", "from": "a1"}}}),
            json!({"type": "queue-operation", "operation": "enqueue", "content": "/rename build"}),
            json!({"type": "queue-operation", "operation": "dequeue"}),
            json!({"type": "user", "uuid": uuid::Uuid::now_v7().to_string(), "message": {
                "role": "user", "content": "<command-name>/rename</command-name>"}}),
            json!({"type": "queue-operation", "operation": "enqueue", "content": wakeup}),
        ],
    );
    assert_eq!(terminal.until("END", 1).await, ["start"]);
    // The wakeup runs after the turn: a meta line with its text, then its own turn.
    append(
        &file,
        &[
            json!({"type": "queue-operation", "operation": "dequeue"}),
            json!({"type": "user", "uuid": uuid::Uuid::now_v7().to_string(), "isMeta": true,
                   "promptSource": "system", "wakeupSource": "loop_wakeup",
                   "message": {"role": "user", "content": wakeup}}),
            json!({"type": "assistant", "message": {"role": "assistant", "stop_reason": "end_turn",
                   "content": [{"type": "text", "text": "checked"}]}}),
        ],
    );
    tokio::time::sleep(Duration::from_millis(400)).await;
    let want: Vec<&str> = if writable {
        vec![first.as_str(), "start", wakeup]
    } else {
        vec![first.as_str(), "start"]
    };
    assert_eq!(prompts(&hub, &sid), want, "writable {writable}: a queue line showed as typed");
    let k = kinds(&hub, &sid);
    let started = k.iter().filter(|k| *k == "turn_started").count();
    let ended = k.iter().filter(|k| *k == "turn_end").count();
    assert_eq!(started, ended, "writable {writable}: a turn was left open: {k:?}");
    assert!(hub.resolve(&sid).unwrap().meta().watching.unwrap().queued.is_empty(), "left queued");
    drop(terminal);
    let _ = std::fs::remove_dir_all(&root);
}

/// Turning the setting off mid-turn (recovery): the chat is a View Only watch at once (binding
/// and tags gone, a new send refused as `watch.read_only`), and nothing is cut or lost. The
/// terminal's turn runs to its end and shows; a send the harness already took (its inbox) runs
/// after it, once, and its sender gets its answer; each prompt shows once. Turned on again, a new
/// hand-off is writable again.
#[tokio::test]
async fn turning_the_setting_off_mid_turn_makes_the_chat_view_only_and_loses_nothing() {
    let (hub, sid, _file, mut terminal, root, first) = handed_to_terminal(1200).await;
    terminal.type_line("typed in the terminal");
    assert_eq!(terminal.until("RUN", 1).await, ["typed in the terminal"]);
    let sent = send(&hub, &sid, "sent before off", "before-off");
    assert_eq!(terminal.until("RECV", 2).await[1], "sent before off");
    // Off, mid-turn.
    hub.set_terminal_chat_writable(false).await;
    assert!(terminal.texts("END").is_empty(), "the turn still runs");
    assert!(hub.resolve(&sid).unwrap().meta().watching.unwrap().terminal.is_none(), "still bound");
    assert_eq!(terminal_tags(&hub, &sid), (Value::Null, Value::Null), "still tagged writable");
    let mut c = connect(&hub).await;
    let refused = c.request(method::SESSION_PROMPT, prompt(&sid, "sent after off", None)).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("watch.read_only")), "{refused:?}");
    // The running turn ends as it would, then the send the harness already held runs, once.
    let sent = tokio::time::timeout(Duration::from_secs(20), sent).await.unwrap().unwrap().unwrap();
    assert_eq!(sent["_meta"]["acpmux"]["answered"], true, "{sent}");
    let ran = terminal.texts("RUN");
    assert_eq!(ran, ["typed in the terminal", "sent before off"], "each once, none cut");
    assert_eq!(terminal.texts("RECV").len(), 2, "nothing reached the harness after off");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        prompts(&hub, &sid),
        [first.as_str(), "typed in the terminal", "sent before off"],
        "each once"
    );
    let k = kinds(&hub, &sid);
    let started = k.iter().filter(|k| *k == "turn_started").count();
    let ended = k.iter().filter(|k| *k == "turn_end").count();
    assert_eq!(started, ended, "a turn left open: {k:?}");
    drop(terminal);
    let _ = std::fs::remove_dir_all(&root);
}
