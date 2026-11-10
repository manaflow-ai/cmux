#![cfg(unix)]
//! Job exit hooks at the daemon boundary (bench round 6, task N3; W7-D): an
//! agent starts a job and is woken with its exact exit status, with no wait
//! loop. `cmux workspace|pane run --notify-on-exit --on-exit-send <agent>`,
//! `cmux terminal <id> exit-hook add` and `acpmux watch add --terminal <id>
//! --until exit` arm one durable daemon hook; the daemon fires it from the
//! terminal's exit receipt (a durable notice and an agent message), and
//! `cmux terminal exit-hook list` shows it. A signal is reported as a signal,
//! never as an exit code.

#[path = "agent_message_policy/harness.rs"]
mod harness;

/// One module, so `cargo test job_exit_hooks` selects these tests.
mod job_exit_hooks {
    use super::harness::Daemon;
    use serde_json::{Value, json};
    use std::process::Command;
    use std::time::{Duration, Instant};

    /// A daemon whose fake acpmux runs session `b` in workspace `alpha`, and
    /// that workspace's public id.
    fn daemon_with_b(name: &str) -> (Daemon, String) {
        let daemon = Daemon::start_owner_with_acpmux(name);
        let alpha = daemon.workspace("alpha");
        daemon.place_session("b", &alpha.1);
        (daemon, alpha.0)
    }

    /// Every JSON object in `value` (depth first).
    fn objects(value: &Value) -> Vec<&serde_json::Map<String, Value>> {
        let mut found = Vec::new();
        let mut pending = vec![value];
        while let Some(value) = pending.pop() {
            match value {
                Value::Object(object) => {
                    found.push(object);
                    pending.extend(object.values());
                }
                Value::Array(items) => pending.extend(items),
                _ => {}
            }
        }
        found
    }

    fn deadline() -> Instant {
        Instant::now() + Duration::from_secs(20)
    }

    /// The notification whose body contains `needle`, once it is listed.
    fn notice(daemon: &Daemon, needle: &str) -> Value {
        let until = deadline();
        loop {
            let listed = daemon.cli_ok(&["notification", "list"]);
            let found = objects(&listed).into_iter().find(|object| {
                object.contains_key("title")
                    && object
                        .get("body")
                        .and_then(Value::as_str)
                        .is_some_and(|b| b.contains(needle))
            });
            if let Some(found) = found {
                return Value::Object(found.clone());
            }
            assert!(Instant::now() < until, "no notice with {needle:?}: {listed}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// The text of the first prompt the fake acpmux took for `session` that
    /// contains `needle`.
    fn prompt_to(daemon: &Daemon, session: &str, needle: &str) -> String {
        let until = deadline();
        loop {
            let prompts = daemon.prompts();
            let found = prompts
                .iter()
                .filter(|prompt| prompt["sessionId"] == session)
                .map(|prompt| prompt["prompt"].to_string())
                .find(|text| text.contains(needle));
            if let Some(text) = found {
                return text;
            }
            assert!(Instant::now() < until, "{session} got no prompt with {needle:?}: {prompts:?}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// The hooks `cmux terminal <terminal> exit-hook list` shows.
    fn hooks(daemon: &Daemon, terminal: &str) -> Vec<Value> {
        let listed = daemon.cli_ok(&["terminal", terminal, "exit-hook", "list"]);
        objects(&listed)
            .into_iter()
            .filter(|object| {
                object.get("id").and_then(Value::as_str).is_some_and(|id| id.starts_with("hook_"))
            })
            .map(|object| Value::Object(object.clone()))
            .collect()
    }

    /// The one hook of `terminal`, once it fired.
    fn fired_hook(daemon: &Daemon, terminal: &str) -> Value {
        let until = deadline();
        loop {
            let hooks = hooks(daemon, terminal);
            if let [hook] = hooks.as_slice()
                && hook["state"] == "fired"
            {
                return hook.clone();
            }
            assert!(Instant::now() < until, "the hook of {terminal} never fired: {hooks:?}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn terminal_id(run: &Value) -> String {
        run["value"]["terminal_id"].as_str().unwrap_or_else(|| panic!("no terminal: {run}")).into()
    }

    /// A job's exit code reaches the person (a notice) and the agent (a
    /// message) from one `run`, and the hook list shows the exact outcome.
    #[test]
    fn run_notifies_and_sends_the_exit_code() {
        let (daemon, workspace) = daemon_with_b("hook-run-code");
        let run = daemon.cli_ok(&[
            "workspace",
            &workspace,
            "run",
            "--notify-on-exit",
            "--on-exit-send",
            "acp:b",
            "--name",
            "build",
            "--",
            "/bin/sh",
            "-c",
            "exit 3",
        ]);
        let terminal = terminal_id(&run);
        let shown = notice(&daemon, "exit 3");
        assert!(shown["title"].as_str().unwrap_or_default().contains("build"), "{shown}");
        assert_eq!(shown["level"], "warning", "a failed job is a warning: {shown}");
        let prompt = prompt_to(&daemon, "b", "exit 3");
        assert!(prompt.contains(&terminal), "the message names the terminal: {prompt}");
        let hook = fired_hook(&daemon, &terminal);
        assert_eq!(hook["outcome"], json!({"kind": "exit", "code": 3}), "{hook}");
        assert_eq!(hook["status"], "exit 3", "{hook}");
        assert_eq!(hook["send_to"], "acp:b", "{hook}");
        assert!(hook["notification_id"].is_string() && hook["message_id"].is_string(), "{hook}");
    }

    /// A job a signal ends is reported as that signal, never as a code.
    #[test]
    fn a_signal_is_reported_as_a_signal() {
        let (daemon, workspace) = daemon_with_b("hook-run-signal");
        let run = daemon.cli_ok(&[
            "workspace",
            &workspace,
            "run",
            "--notify-on-exit",
            "--on-exit-send",
            "acp:b",
            "--",
            "/bin/sh",
            "-c",
            "kill -TERM $$",
        ]);
        let terminal = terminal_id(&run);
        let shown = notice(&daemon, "signal 15");
        assert!(!shown["body"].as_str().unwrap_or_default().contains("exit"), "{shown}");
        prompt_to(&daemon, "b", "signal 15 (SIGTERM)");
        let hook = fired_hook(&daemon, &terminal);
        assert_eq!(
            hook["outcome"],
            json!({"kind": "signal", "signal": 15, "core_dumped": false}),
            "{hook}"
        );
        assert_eq!(hook["status"], "signal 15 (SIGTERM)", "{hook}");
    }

    /// A hook added to a terminal whose job already ended fires at once: the
    /// exit receipt is durable, so a late hook misses nothing.
    #[test]
    fn a_hook_on_an_ended_job_fires_at_once() {
        let (daemon, workspace) = daemon_with_b("hook-late");
        let terminal = daemon.terminal(&workspace, "exit 0");
        daemon.cli_ok(&["terminal", &terminal, "process", "wait"]);
        let added = daemon.cli_ok(&[
            "terminal",
            &terminal,
            "exit-hook",
            "add",
            "--notify",
            "--send",
            "acp:b",
        ]);
        assert!(added.to_string().contains("hook_"), "no hook id: {added}");
        let shown = notice(&daemon, "exit 0");
        assert_eq!(shown["level"], "info", "a job that succeeded is info: {shown}");
        prompt_to(&daemon, "b", "exit 0");
        assert_eq!(fired_hook(&daemon, &terminal)["outcome"], json!({"kind": "exit", "code": 0}));
    }

    /// `acpmux watch add --terminal <id> --until exit` arms the same daemon
    /// hook: the job's end wakes the session with the exit code.
    #[test]
    fn acpmux_watch_until_exit_wakes_the_session() {
        let (daemon, workspace) = daemon_with_b("hook-watch");
        let go = daemon.dir.join("go");
        let script = format!("while [ ! -f '{}' ]; do sleep 0.05; done; exit 7", go.display());
        let terminal = daemon.terminal(&workspace, &script);
        let watch = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["acp", "--json", "watch", "add", "--terminal", &terminal, "--until", "exit"])
            .args(["--to", "b"])
            .env("LC_ALL", "C")
            .env("CMUX_TUI_SOCKET", &daemon.socket)
            .env("ACPMUX_SOCKET", daemon.dir.join("acpmux.sock"))
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_LAUNCH_CREDENTIAL")
            .env_remove("ACPMUX_SESSION_ID")
            .output()
            .unwrap();
        assert!(
            watch.status.success(),
            "the watch was refused: {}{}",
            String::from_utf8_lossy(&watch.stdout),
            String::from_utf8_lossy(&watch.stderr)
        );
        assert!(String::from_utf8_lossy(&watch.stdout).contains("hook_"), "no hook id");
        let armed = hooks(&daemon, &terminal);
        assert!(
            armed.len() == 1 && armed[0]["state"] == "armed",
            "the job runs, so the hook waits: {armed:?}"
        );
        std::fs::write(&go, "").unwrap();
        let prompt = prompt_to(&daemon, "b", "exit 7");
        assert!(prompt.contains(&terminal), "{prompt}");
        assert_eq!(fired_hook(&daemon, &terminal)["outcome"], json!({"kind": "exit", "code": 7}));
    }

    /// A recipient that does not exist is refused before the job starts, so
    /// no job runs whose end nobody hears.
    #[test]
    fn an_unknown_recipient_is_refused_before_the_job_starts() {
        let (daemon, workspace) = daemon_with_b("hook-unknown");
        let before = daemon.cli_ok(&["terminal", "list"]).to_string().matches("\"term_").count();
        let output = daemon.cli(&[
            "workspace",
            &workspace,
            "run",
            "--on-exit-send",
            "acp:nobody",
            "--",
            "/bin/sh",
            "-c",
            "exit 0",
        ]);
        assert!(!output.status.success(), "an unknown recipient was taken");
        let said = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(said.contains("nobody"), "the refusal names the recipient: {said}");
        let after = daemon.cli_ok(&["terminal", "list"]).to_string().matches("\"term_").count();
        assert_eq!(before, after, "a terminal started after its hook was refused");
    }
}
