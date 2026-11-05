//! Tests of the agent message hooks (inbox.rs).

use super::*;
use std::ffi::OsString;

fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> + use<> {
    let pairs: Vec<(String, OsString)> =
        pairs.iter().map(|(name, value)| ((*name).to_owned(), OsString::from(value))).collect();
    move |name| pairs.iter().find(|(key, _)| key == name).map(|(_, value)| value.clone())
}

/// A `claude -p` run shares the terminal; it never takes the interactive
/// session's messages.
#[test]
fn a_headless_claude_does_not_own_the_terminal() {
    assert!(!claude_owns_terminal(env(&[(CLAUDE_HEADLESS_ENV, "1")])));
}

/// A Claude the wrapper did not start keeps the old prompt-hook delivery.
#[test]
fn a_claude_without_the_wrappers_identity_keeps_prompt_delivery() {
    assert!(claude_owns_terminal(env(&[])));
}

/// Review P2 (nested launch, launchers, second installs): a hook takes the
/// terminal's messages under the wrapper only when its command names the
/// wrapper's launch. Which process runs it (the Claude the wrapper execs, or
/// a child of a launcher it execs) does not matter; a Claude started inside
/// it runs other settings, whose hooks name no launch.
#[test]
fn a_claude_hook_owns_the_terminal_only_when_it_names_the_launch() {
    assert!(claude_owns_terminal(env(&[(CLAUDE_PID_ENV, "100"), (LAUNCH_ENV, "100")])));
    // A nested Claude's or a second install's hooks: the inherited pid, no launch.
    assert!(!claude_owns_terminal(env(&[(CLAUDE_PID_ENV, "100")])));
    // Another launch's hooks (a wrapper run inside this one).
    assert!(!claude_owns_terminal(env(&[(CLAUDE_PID_ENV, "100"), (LAUNCH_ENV, "200")])));
    // Headless never owns it, even with the launch named.
    assert!(!claude_owns_terminal(env(&[
        (CLAUDE_PID_ENV, "100"),
        (LAUNCH_ENV, "100"),
        (CLAUDE_HEADLESS_ENV, "1"),
    ])));
}

/// The real commands on real processes. The launch's own hook commands name
/// the launch whether the hook shell is the wrapped Claude's child or that of
/// a Claude a non-exec launcher started; the shared prompt hook (the one an
/// installed settings file, a second install or a nested Claude runs) names
/// none, even run with everything a nested Claude inherits.
#[cfg(unix)]
#[test]
fn real_hook_commands_name_the_launch_only_from_its_own_settings() {
    use std::os::unix::fs::PermissionsExt as _;
    use std::process::Command;
    let dir = tempfile::tempdir().unwrap();
    let helper = dir.path().join("hook");
    std::fs::write(&helper, "#!/bin/sh\nprintf '%s' \"$CMUX_TUI_HOOK_LAUNCH\"\n").unwrap();
    std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o700)).unwrap();
    const LAUNCH: u32 = 4242;
    let shared = cmux_tui_hooks::claude_session_hook_settings(None).unwrap();
    let mut own = shared.clone();
    let hooks = own.get_mut("hooks").and_then(Value::as_object_mut).unwrap();
    cmux_tui_hooks::message_hooks::add_claude_launch_hooks(hooks, LAUNCH, None).unwrap();
    let command = |settings: &serde_json::Map<String, Value>, event: &str, needle: &str| {
        settings["hooks"][event]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|group| group["hooks"].as_array().unwrap().iter())
            .filter_map(|hook| hook["command"].as_str())
            .find(|command| command.contains(needle))
            .unwrap()
            .to_owned()
    };
    let named = |script: &str, hook: &str| -> String {
        let run = Command::new("/bin/sh")
            .args(["-c", script])
            .env("HOOK", hook)
            .env("CMUX_TUI_HOOK", &helper)
            .env(CLAUDE_PID_ENV, LAUNCH.to_string())
            .env_remove(LAUNCH_ENV)
            .output()
            .unwrap();
        String::from_utf8(run.stdout).unwrap()
    };
    let owns = |named: &str| {
        let pid = LAUNCH.to_string();
        claude_owns_terminal(env(&[(CLAUDE_PID_ENV, pid.as_str()), (LAUNCH_ENV, named)]))
    };
    for hook in [
        command(&own, "UserPromptSubmit", "inbox-drain"),
        command(&own, "Stop", "inbox-wait"),
        command(&own, "SessionStart", "inbox-wait"),
    ] {
        // The wrapped Claude runs its hook shell.
        assert!(owns(&named("/bin/sh -c \"$HOOK\"", &hook)), "{hook}");
        // A launcher that does not exec Claude: its child runs the hook shell.
        assert!(owns(&named("/bin/sh -c '/bin/sh -c \"$HOOK\"; :'; :", &hook)), "{hook}");
    }
    // The shared prompt hook: what a nested Claude or a second install runs.
    let installed = command(&shared, "UserPromptSubmit", "UserPromptSubmit");
    assert!(!installed.contains(LAUNCH_ENV), "{installed}");
    let nested = named("/bin/sh -c '/bin/sh -c \"$HOOK\"; :'; :", &installed);
    assert!(!owns(&nested), "the shared prompt hook named a launch: {nested:?}");
}

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";

/// A daemon on a Unix socket that logs each request and answers it with
/// `answer` (`None`: close without answering).
#[cfg(unix)]
struct FakeDaemon {
    _dir: tempfile::TempDir,
    socket: PathBuf,
    log: std::sync::Arc<std::sync::Mutex<Vec<Value>>>,
}

#[cfg(unix)]
impl FakeDaemon {
    fn start(answer: impl Fn(&Value) -> Option<Value> + Send + 'static) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("daemon.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let log = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen = log.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let mut line = String::new();
                if BufReader::new(&stream).read_line(&mut line).is_err() {
                    continue;
                }
                let Ok(request) = serde_json::from_str::<Value>(&line) else { continue };
                seen.lock().unwrap().push(request.clone());
                if let Some(mut reply) = answer(&request) {
                    reply["id"] = request["id"].clone();
                    let _ = writeln!(stream, "{reply}");
                }
            }
        });
        Self { _dir: dir, socket, log }
    }

    fn operations(&self) -> Vec<String> {
        let log = self.log.lock().unwrap();
        log.iter().map(|request| request["operation"].as_str().unwrap().to_owned()).collect()
    }

    fn requests(&self) -> Vec<Value> {
        self.log.lock().unwrap().clone()
    }
}

fn ok(result: Value) -> Option<Value> {
    Some(json!({"protocol": "cmux.protocol/2", "type": "response", "ok": true, "result": result}))
}

fn refused(code: &str, message: &str) -> Option<Value> {
    Some(json!({
        "protocol": "cmux.protocol/2", "type": "response", "ok": false,
        "error": {"code": code, "message": message, "details": {}, "retryable": false},
    }))
}

fn queued_message() -> Value {
    json!({"id": "msg_1", "thread_id": "msg_1", "sender": "cli", "body": "rebase when free"})
}

/// Review P2: only a daemon that does not know the claim lets Claude's
/// prompt hook list the queue; a refusal, a busy daemon or a dropped
/// connection takes nothing, so a message a wake hook leased is not
/// handed over beside it.
#[cfg(unix)]
#[test]
fn the_prompt_hook_lists_the_queue_only_when_the_daemon_does_not_know_the_claim() {
    let old = FakeDaemon::start(|request| match request["operation"].as_str() {
        Some("agent.message.wait") => refused("validation.invalid", "invalid request envelope"),
        Some("agent.message.list") => ok(json!([queued_message()])),
        _ => ok(json!({"value": []})),
    });
    let claude = Delivery::for_event("claude", "UserPromptSubmit").unwrap();
    let mut out = Vec::new();
    deliver_to(&mut out, claude, &old.socket, Some(TERMINAL), true);
    assert_eq!(
        old.operations(),
        ["agent.message.wait", "agent.message.list", "agent.message.mark"]
    );
    assert!(String::from_utf8(out).unwrap().contains("rebase when free"));

    for failure in [
        refused("operation.failed", "agent message wait capacity exceeded"),
        refused("validation.invalid", "agent.message.wait claims for a terminal agent"),
        None,
    ] {
        let daemon = FakeDaemon::start(move |request| match request["operation"].as_str() {
            Some("agent.message.wait") => failure.clone(),
            _ => ok(json!([queued_message()])),
        });
        let mut out = Vec::new();
        deliver_to(&mut out, claude, &daemon.socket, Some(TERMINAL), true);
        assert_eq!(daemon.operations(), ["agent.message.wait"], "listed beside a lease");
        assert_eq!(String::from_utf8(out).unwrap().trim(), "{}");
    }
}

/// A daemon whose answer to the claim is malformed: a claim without its
/// messages, an ok without a result, a refusal without an error object, or
/// no boolean ok. Claude's prompt hook takes nothing for any of them. It does
/// not read a missing field as an empty claim, never falls back to listing
/// the queue (only the unknown-operation refusal does that), marks nothing
/// delivered, and answers the empty object; the messages stay queued.
#[cfg(unix)]
#[test]
fn a_malformed_claim_answer_takes_nothing_and_never_lists_the_queue() {
    let base = || json!({"protocol": "cmux.protocol/2", "type": "response"});
    let with = |mut reply: Value, fields: Value| {
        for (key, value) in fields.as_object().unwrap() {
            reply[key] = value.clone();
        }
        Some(reply)
    };
    let replies = [
        with(base(), json!({"ok": true, "result": {"status": "claimed", "lease_id": "lease_0"}})),
        with(base(), json!({"ok": true, "result": {"status": "claimed", "messages": "msg_1"}})),
        with(base(), json!({"ok": true, "result": {"messages": [queued_message()]}})),
        with(base(), json!({"ok": true})),
        with(base(), json!({"ok": false})),
        with(base(), json!({"ok": false, "error": "invalid request envelope"})),
        with(base(), json!({"ok": "true", "result": {"status": "claimed"}})),
    ];
    let claude = Delivery::for_event("claude", "UserPromptSubmit").unwrap();
    for reply in replies {
        let answer = reply.clone();
        let daemon = FakeDaemon::start(move |request| match request["operation"].as_str() {
            Some("agent.message.wait") => answer.clone(),
            _ => ok(json!([queued_message()])),
        });
        let mut out = Vec::new();
        deliver_to(&mut out, claude, &daemon.socket, Some(TERMINAL), true);
        assert_eq!(daemon.operations(), ["agent.message.wait"], "{reply:?}");
        assert_eq!(String::from_utf8(out).unwrap().trim(), "{}", "{reply:?}");
    }
}

/// The wake hook given a malformed answer hands nothing to Claude and marks
/// nothing: a `claimed` answer without messages, or one with no status.
#[cfg(unix)]
#[test]
fn a_malformed_wait_answer_wakes_nothing() {
    for result in [json!({"status": "claimed"}), json!({"lease_id": "lease_0"})] {
        let daemon = FakeDaemon::start(move |_| ok(result.clone()));
        let parent = std::os::unix::process::parent_id().to_string();
        let socket = daemon.socket.to_str().unwrap().to_owned();
        let getenv = env(&[
            ("CMUX_TUI_SOCKET", socket.as_str()),
            ("CMUX_TUI_TERMINAL_ID", TERMINAL),
            (CLAUDE_PID_ENV, parent.as_str()),
            (LAUNCH_ENV, parent.as_str()),
        ]);
        let payload = json!({"hook_event_name": "Stop", "session_id": "s1"});
        let mut err = Vec::new();
        assert_eq!(wake_with(&getenv, &payload, &mut err), 0);
        assert!(err.is_empty());
        assert_eq!(daemon.operations(), ["agent.message.wait"]);
    }
}

struct FailingWriter;

impl Write for FailingWriter {
    fn write(&mut self, _: &[u8]) -> io::Result<usize> {
        Err(io::Error::new(io::ErrorKind::BrokenPipe, "the agent closed its end"))
    }

    fn flush(&mut self) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::BrokenPipe, "the agent closed its end"))
    }
}

/// Review P2: a hook output the agent cannot have read (stdout write or
/// flush failed) marks nothing delivered; the messages stay queued.
#[cfg(unix)]
#[test]
fn a_prompt_hook_whose_output_failed_marks_nothing_delivered() {
    let daemon = FakeDaemon::start(|request| match request["operation"].as_str() {
        Some("agent.message.wait") => {
            ok(json!({"status": "claimed", "lease_id": "lease_0", "messages": [queued_message()]}))
        }
        Some("agent.message.list") => ok(json!([queued_message()])),
        _ => ok(json!({"value": []})),
    });
    for event in ["UserPromptSubmit", "Stop"] {
        let source = if event == "Stop" { "codex" } else { "claude" };
        let delivery = Delivery::for_event(source, event).unwrap();
        deliver_to(&mut FailingWriter, delivery, &daemon.socket, Some(TERMINAL), true);
    }
    let marks: Vec<Value> = daemon
        .requests()
        .into_iter()
        .filter(|request| request["operation"] == "agent.message.mark")
        .filter(|request| request["params"]["state"] == "delivered")
        .collect();
    assert!(marks.is_empty(), "{marks:?}");
}

/// Review P2 (interleaving): a wake hook that starts at a Stop while an
/// earlier wake may still be handing messages over acknowledges nothing.
/// It claims, writes the messages, marks them delivered via claude.wake
/// and exits 2; no request ever marks a delivery acknowledged.
#[cfg(unix)]
#[test]
fn a_wake_hook_started_at_stop_acknowledges_nothing() {
    let daemon = FakeDaemon::start(|request| match request["operation"].as_str() {
        Some("agent.message.wait") => {
            ok(json!({"status": "claimed", "lease_id": "lease_0", "messages": [queued_message()]}))
        }
        Some("agent.message.list") => ok(json!([queued_message()])),
        _ => ok(json!({"value": []})),
    });
    let parent = std::os::unix::process::parent_id().to_string();
    let socket = daemon.socket.to_str().unwrap().to_owned();
    let getenv = env(&[
        ("CMUX_TUI_SOCKET", socket.as_str()),
        ("CMUX_TUI_TERMINAL_ID", TERMINAL),
        (CLAUDE_PID_ENV, parent.as_str()),
        (LAUNCH_ENV, parent.as_str()),
    ]);
    let payload = json!({"hook_event_name": "Stop", "session_id": "s1"});
    let mut err = Vec::new();
    assert_eq!(wake_with(&getenv, &payload, &mut err), 2);
    assert!(String::from_utf8(err).unwrap().contains("rebase when free"));
    let requests = daemon.requests();
    assert_eq!(daemon.operations(), ["agent.message.wait", "agent.message.mark"]);
    assert_eq!(requests[0]["params"]["agent_session_id"], "s1");
    assert_eq!(requests[1]["params"]["state"], "delivered");
    assert_eq!(requests[1]["params"]["via"], "claude.wake");
    assert!(requests.iter().all(|request| request["params"]["state"] != "acknowledged"));
}

/// A wake hook whose stderr is gone (Claude exited) marks nothing and
/// exits 0; its claim lapses and the messages are offered again.
#[cfg(unix)]
#[test]
fn a_wake_hook_that_cannot_write_marks_nothing() {
    let daemon = FakeDaemon::start(|request| match request["operation"].as_str() {
        Some("agent.message.wait") => {
            ok(json!({"status": "claimed", "lease_id": "lease_0", "messages": [queued_message()]}))
        }
        _ => ok(json!({"value": []})),
    });
    let parent = std::os::unix::process::parent_id().to_string();
    let socket = daemon.socket.to_str().unwrap().to_owned();
    let getenv = env(&[
        ("CMUX_TUI_SOCKET", socket.as_str()),
        ("CMUX_TUI_TERMINAL_ID", TERMINAL),
        (CLAUDE_PID_ENV, parent.as_str()),
        (LAUNCH_ENV, parent.as_str()),
    ]);
    let payload = json!({"hook_event_name": "SessionStart", "session_id": "s1"});
    assert_eq!(wake_with(&getenv, &payload, &mut FailingWriter), 0);
    assert_eq!(daemon.operations(), ["agent.message.wait"]);
}

/// A daemon that answers `disabled` (Settings > Agents > Agent Messages
/// is off, managed layers included) ends the wake hook: it hands nothing
/// over and asks for nothing more.
#[cfg(unix)]
#[test]
fn a_disabled_answer_ends_the_wake_hook() {
    let daemon = FakeDaemon::start(|_| ok(json!({"status": "disabled", "reason": "setting_off"})));
    let parent = std::os::unix::process::parent_id().to_string();
    let socket = daemon.socket.to_str().unwrap().to_owned();
    let getenv = env(&[
        ("CMUX_TUI_SOCKET", socket.as_str()),
        ("CMUX_TUI_TERMINAL_ID", TERMINAL),
        (CLAUDE_PID_ENV, parent.as_str()),
        (LAUNCH_ENV, parent.as_str()),
    ]);
    let payload = json!({"hook_event_name": "Stop", "session_id": "s1"});
    let mut err = Vec::new();
    assert_eq!(wake_with(&getenv, &payload, &mut err), 0);
    assert!(err.is_empty());
    assert_eq!(daemon.operations(), ["agent.message.wait"]);
}
