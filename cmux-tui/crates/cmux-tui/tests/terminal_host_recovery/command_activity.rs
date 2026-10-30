//! cx-ag5.6.5: a running shell command is never work in progress. The
//! daemon publishes it on the terminal record as quiet `running` (a plain
//! command) or `in_use` (the command took the terminal for interaction:
//! htop, vim, less, a REPL), and only a program's own OSC 7501 report says
//! `working`. Each script plays the shell's OSC 133 marks itself and waits
//! for a line on the terminal between steps, so every state is read while
//! it holds.

use super::*;

/// `extra` of the harness's only terminal record.
fn terminal_extra(harness: &RecoveryHarness) -> serde_json::Value {
    let terminals = resource_request(
        &harness.socket,
        "command-activity-list",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let terminals = terminals.as_array().unwrap();
    assert_eq!(terminals.len(), 1, "expected one terminal: {terminals:?}");
    terminals[0]["extra"].clone()
}

/// Waits until `extra.activity.state` is `state` (`None`: no activity).
fn wait_for_activity(harness: &RecoveryHarness, state: Option<&str>) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let extra = terminal_extra(harness);
        if extra["activity"]["state"].as_str() == state {
            return extra;
        }
        assert!(Instant::now() < deadline, "activity never became {state:?}: {extra}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Starts `script` (sh) in a new workspace and waits for `marker`.
fn run_script(harness: &RecoveryHarness, name: &str, script: &str, marker: &str) -> (u64, String) {
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", script],
            "new_workspace": true,
            "name": name,
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker));
    (surface, terminal_id)
}

/// Sends one line to the script's next `read`.
fn step(harness: &RecoveryHarness, surface: u64) {
    request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": "\n"}),
    );
}

#[test]
fn a_full_screen_program_is_in_use_never_running() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-alt-screen");
    let (surface, _) = run_script(
        &harness,
        "command-activity-alt-screen",
        concat!(
            // The shell starts a command, which takes the alternate screen
            // like htop does.
            "printf '\\033]133;C\\007started\\r\\n'; read step; ",
            "printf '\\033[?1049hfullscreen'; read step; ",
            // It leaves the alternate screen for a moment (vim `:!ls`).
            "printf '\\033[?1049lback\\r\\n'; read step; ",
            "printf '\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "started",
    );
    let extra = wait_for_activity(&harness, Some("running"));
    assert!(extra["busy"]["since_ms"].is_string(), "a plain command keeps busy: {extra}");
    let since = extra["activity"]["since_ms"].clone();

    step(&harness, surface);
    let extra = wait_for_activity(&harness, Some("in_use"));
    assert!(extra.get("busy").is_none(), "an in-use command is not busy: {extra}");
    assert_eq!(extra["activity"]["since_ms"], since, "the same command: {extra}");

    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "back").contains("back"));
    let extra = terminal_extra(&harness);
    assert_eq!(extra["activity"]["state"], "in_use", "in use for the whole command: {extra}");
    assert!(extra.get("busy").is_none(), "{extra}");

    step(&harness, surface);
    let extra = wait_for_activity(&harness, None);
    assert!(extra.get("busy").is_none(), "the prompt ends the command: {extra}");
}

#[test]
fn a_repl_that_reads_lines_is_in_use() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-repl");
    let (surface, _) = run_script(
        &harness,
        "command-activity-repl",
        concat!(
            "printf '\\033]133;C\\007started\\r\\n'; read step; ",
            // A line-editing REPL (python, psql, ssh's remote shell) turns
            // on bracketed paste to read the user's lines.
            "printf '\\033[?2004h>>> '; read step; ",
            "printf '\\033[?2004l\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "started",
    );
    wait_for_activity(&harness, Some("running"));
    step(&harness, surface);
    let extra = wait_for_activity(&harness, Some("in_use"));
    assert!(extra.get("busy").is_none(), "{extra}");
    step(&harness, surface);
    wait_for_activity(&harness, None);
}

#[test]
fn a_shell_that_turns_bracketed_paste_off_after_the_command_starts_keeps_it_running() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-late-paste-off");
    let (surface, _) = run_script(
        &harness,
        "command-activity-late-paste-off",
        concat!(
            // fish prints `C` while its line editor still has bracketed
            // paste and focus reporting on, and turns them off in a later
            // write: the command did not turn them on.
            "printf '\\033[?2004h\\033[?1004h\\033]133;C\\007started\\r\\n'; read step; ",
            "printf '\\033[?2004l\\033[?1004loff\\r\\n'; read step; ",
            "printf '\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "started",
    );
    let extra = wait_for_activity(&harness, Some("running"));
    assert!(extra["busy"]["since_ms"].is_string(), "{extra}");
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "off").contains("off"));
    let extra = terminal_extra(&harness);
    assert_eq!(
        extra["activity"]["state"], "running",
        "the shell's modes are not the command's: {extra}"
    );
    step(&harness, surface);
    wait_for_activity(&harness, None);
}

#[test]
fn a_short_command_runs_quietly_then_ends() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-sleep");
    let (surface, _) = run_script(
        &harness,
        "command-activity-sleep",
        concat!(
            // `sleep 5` from the prompt, ended on cue.
            "printf '\\033]133;C\\007sleeping\\r\\n'; read step; ",
            "printf '\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "sleeping",
    );
    let extra = wait_for_activity(&harness, Some("running"));
    assert!(extra.get("program_status").is_none(), "a command reports no work: {extra}");
    step(&harness, surface);
    let extra = wait_for_activity(&harness, None);
    assert!(extra.get("busy").is_none(), "{extra}");
}

#[test]
fn only_the_programs_own_report_says_working_then_done() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-osc7501");
    let (surface, _) = run_script(
        &harness,
        "command-activity-osc7501",
        concat!(
            "printf '\\033]133;C\\007\\033]7501;state=working:progress=40:app=make\\033\\\\building\\r\\n'; read step; ",
            "printf '\\033]7501;state=done:app=make\\033\\\\'; ",
            "printf '\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "building",
    );
    let extra = wait_for_activity(&harness, Some("running"));
    let status = extra["program_status"].as_array().cloned().unwrap_or_default();
    assert_eq!(status.len(), 1, "{extra}");
    assert_eq!(status[0]["state"], "working", "{extra}");
    assert_eq!(status[0]["progress"], 40, "{extra}");

    step(&harness, surface);
    let extra = wait_for_activity(&harness, None);
    let status = extra["program_status"].as_array().cloned().unwrap_or_default();
    assert_eq!(status.len(), 1, "done survives the prompt: {extra}");
    assert_eq!(status[0]["state"], "done", "{extra}");
}

/// Waits until the daemon's agent record is in `state`.
fn wait_for_agent_state(harness: &RecoveryHarness, state: &str) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let agents = request(&harness.socket, serde_json::json!({"id": 3, "cmd": "list-agents"}));
        if agents["agents"].as_array().into_iter().flatten().any(|agent| agent["state"] == state) {
            return agents;
        }
        assert!(Instant::now() < deadline, "the agent never became {state}: {agents}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn an_agent_hook_turn_is_working_then_waiting_then_idle() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-agent");
    let helper = env!("CARGO_BIN_EXE_cmux-tui");
    // Claude Code runs its hooks in the terminal it works in, with the
    // event's JSON on stdin.
    let hook = |event: &str, extra: &str| {
        format!(
            "printf '%s' '{{\"session_id\":\"activity-1\",\"hook_event_name\":\"{event}\",\
             \"cwd\":\"/tmp\"{extra}}}' | '{helper}' __agent-hook claude {event}; "
        )
    };
    let script = format!(
        "[ -n \"$CMUX_TUI_TERMINAL_ID\" ] && printf 'agent\\r\\n'; read step; {}\
         printf 'turn\\r\\n'; read step; {}printf 'asked\\r\\n'; read step; {}\
         printf 'done\\r\\n'; sleep 600",
        hook("UserPromptSubmit", ",\"prompt\":\"hi\""),
        hook("PermissionRequest", ",\"tool_name\":\"Bash\""),
        hook("Stop", ""),
    );
    let (surface, _) = run_script(&harness, "command-activity-agent", &script, "agent");

    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "turn").contains("turn"));
    wait_for_agent_state(&harness, "working");
    let extra = terminal_extra(&harness);
    assert!(extra.get("activity").is_none(), "the agent's state, not a command: {extra}");

    step(&harness, surface);
    wait_for_agent_state(&harness, "blocked");

    step(&harness, surface);
    wait_for_agent_state(&harness, "idle");
}

/// The one OSC 7501 record of the harness's terminal once `ready` holds for it.
fn wait_for_program_status(
    harness: &RecoveryHarness,
    ready: impl Fn(&serde_json::Value) -> bool,
) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let extra = terminal_extra(harness);
        if let Some(record) = extra["program_status"].as_array().and_then(|records| records.first())
            && ready(record)
        {
            return record.clone();
        }
        assert!(Instant::now() < deadline, "the program status never got there: {extra}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn ms(value: &serde_json::Value) -> u64 {
    value.as_u64().or_else(|| value.as_str()?.parse().ok()).expect("a Unix ms value")
}

#[test]
fn a_program_status_keeps_when_its_state_began_across_progress_reports() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-since");
    let (surface, _) = run_script(
        &harness,
        "command-activity-since",
        concat!(
            "printf '\\033]133;C\\007\\033]7501;state=working:progress=20:app=make\\033\\\\building\\r\\n'; read step; ",
            "printf '\\033]7501;state=working:progress=60:app=make\\033\\\\more\\r\\n'; read step; ",
            "printf '\\033]7501;state=blocked:kind=question:app=make\\033\\\\asked\\r\\n'; sleep 600",
        ),
        "building",
    );
    let first = wait_for_program_status(&harness, |record| record["progress"] == 20);
    let since = ms(&first["since_ms"]);
    assert_eq!(since, ms(&first["updated_at_ms"]), "a new state starts at its report: {first}");

    step(&harness, surface);
    let progressed = wait_for_program_status(&harness, |record| record["progress"] == 60);
    assert_eq!(
        ms(&progressed["since_ms"]),
        since,
        "a progress report keeps the start: {progressed}"
    );
    assert!(ms(&progressed["updated_at_ms"]) >= ms(&first["updated_at_ms"]), "{progressed}");

    step(&harness, surface);
    let blocked = wait_for_program_status(&harness, |record| record["state"] == "blocked");
    assert_eq!(
        ms(&blocked["since_ms"]),
        ms(&blocked["updated_at_ms"]),
        "a new state starts again: {blocked}"
    );
    assert!(ms(&blocked["since_ms"]) >= ms(&progressed["updated_at_ms"]), "{blocked}");
}

#[test]
fn an_agent_keeps_when_its_state_began_until_the_state_changes() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-agent-since");
    let helper = env!("CARGO_BIN_EXE_cmux-tui");
    let hook = |event: &str, extra: &str| {
        format!(
            "printf '%s' '{{\"session_id\":\"since-1\",\"hook_event_name\":\"{event}\",\
             \"cwd\":\"/tmp\"{extra}}}' | '{helper}' __agent-hook claude {event}; "
        )
    };
    let script = format!(
        "[ -n \"$CMUX_TUI_TERMINAL_ID\" ] && printf 'agent\\r\\n'; read step; {}\
         printf 'turn\\r\\n'; read step; {}printf 'again\\r\\n'; read step; {}\
         printf 'asked\\r\\n'; sleep 600",
        hook("UserPromptSubmit", ",\"prompt\":\"one\""),
        hook("UserPromptSubmit", ",\"prompt\":\"two\""),
        hook("PermissionRequest", ",\"tool_name\":\"Bash\""),
    );
    let (surface, _) = run_script(&harness, "command-activity-agent-since", &script, "agent");
    let agent = |agents: &serde_json::Value| agents["agents"][0].clone();

    step(&harness, surface);
    let first = agent(&wait_for_agent_state(&harness, "working"));
    let since = ms(&first["since_ms"]);
    let updated = ms(&first["updated_at_ms"]);

    step(&harness, surface);
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let again = loop {
        let current = agent(&wait_for_agent_state(&harness, "working"));
        if ms(&current["updated_at_ms"]) > updated {
            break current;
        }
        assert!(Instant::now() < deadline, "the second report never landed: {current}");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(
        ms(&again["since_ms"]),
        since,
        "a report in the same state keeps the start: {again}"
    );

    step(&harness, surface);
    let blocked = agent(&wait_for_agent_state(&harness, "blocked"));
    assert_ne!(ms(&blocked["since_ms"]), since, "a new state starts over: {blocked}");
    assert!(
        ms(&blocked["since_ms"]) >= ms(&again["updated_at_ms"]),
        "a new state starts after the last working report: {blocked} {again}"
    );
}

/// Every file under `dir` whose bytes contain `needle` (the daemon's state: journal, database,
/// checkpoints, logs).
fn files_containing(dir: &Path, needle: &[u8]) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let Ok(entries) = fs::read_dir(dir) else { return found };
    for entry in entries.flatten() {
        let path = entry.path();
        // No symlinks or FIFOs: only real folders and regular files.
        let Ok(meta) = fs::symlink_metadata(&path) else { continue };
        if meta.is_dir() {
            found.extend(files_containing(&path, needle));
        } else if meta.is_file()
            && fs::read(&path).is_ok_and(|bytes| bytes.windows(needle.len()).any(|w| w == needle))
        {
            found.push(path);
        }
    }
    found
}

#[test]
fn an_agent_keeps_its_last_prompt_in_memory_only() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-agent-prompt");
    let helper = env!("CARGO_BIN_EXE_cmux-tui");
    // A distinctive prompt longer than the 200 kept characters.
    let marker = "hovercard-prompt-marker";
    let prompt = format!("{marker} {}", "x".repeat(300));
    // The hook's stdin comes from a file outside the daemon's folders, so the prompt reaches the
    // daemon only through the hook (the run command's argv does not carry it).
    let payload_dir = std::env::temp_dir().join(format!("cmux-prompt-{}", std::process::id()));
    fs::create_dir_all(&payload_dir).unwrap();
    let payload = payload_dir.join("hook.json");
    fs::write(
        &payload,
        serde_json::json!({"session_id":"prompt-1","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":prompt})
            .to_string(),
    )
    .unwrap();
    let script = format!(
        "[ -n \"$CMUX_TUI_TERMINAL_ID\" ] && printf 'agent\\r\\n'; read step; \
         '{helper}' __agent-hook claude UserPromptSubmit < '{}'; printf 'turn\\r\\n'; sleep 600",
        payload.display()
    );
    let (surface, _) = run_script(&harness, "command-activity-agent-prompt", &script, "agent");
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "turn").contains("turn"));
    let agents = wait_for_agent_state(&harness, "working");
    let kept = agents["agents"][0]["last_prompt"].as_str().unwrap_or_default().to_owned();
    assert!(kept.starts_with(marker), "list-agents carries the prompt: {agents}");
    assert!(
        kept.chars().count() <= 200,
        "the prompt is cut to 200 characters: {}",
        kept.chars().count()
    );
    // Memory only: no daemon state file holds it (journal, database, checkpoints), also after
    // a checkpoint flushes the journal.
    resource_request(
        &harness.socket,
        "agent-prompt-checkpoint",
        "session.journal.checkpoint.create",
        serde_json::json!({"machine":"current","session":"current"}),
        Some("agent-prompt-checkpoint"),
    );
    let leaked = files_containing(&harness.dir, marker.as_bytes());
    let _ = fs::remove_dir_all(&payload_dir);
    assert!(leaked.is_empty(), "the prompt reached disk: {leaked:?}");
}

#[test]
fn a_finished_turn_banner_previews_the_last_message_in_memory_only() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-agent-reply");
    let helper = env!("CARGO_BIN_EXE_cmux-tui");
    // A distinctive reply longer than the 200 kept characters.
    let marker = "banner-reply-marker";
    let reply = format!("{marker} {}", "y".repeat(300));
    let payload_dir = std::env::temp_dir().join(format!("cmux-reply-{}", std::process::id()));
    fs::create_dir_all(&payload_dir).unwrap();
    let start = payload_dir.join("start.json");
    let stop = payload_dir.join("stop.json");
    fs::write(
        &start,
        serde_json::json!({"session_id":"reply-1","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"go"})
            .to_string(),
    )
    .unwrap();
    fs::write(
        &stop,
        serde_json::json!({"session_id":"reply-1","hook_event_name":"Stop","cwd":"/tmp","last_assistant_message":reply})
            .to_string(),
    )
    .unwrap();
    // The app's view: the daemon's event stream, read on a thread.
    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{}", serde_json::json!({"id": 1, "cmd": "subscribe"})).unwrap();
    let (events, received) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        while reader.read_line(&mut line).is_ok_and(|read| read > 0) {
            let _ = events.send(std::mem::take(&mut line));
        }
    });
    let script = format!(
        "[ -n \"$CMUX_TUI_TERMINAL_ID\" ] && printf 'agent\\r\\n'; read step; \
         '{helper}' __agent-hook claude UserPromptSubmit < '{}'; \
         '{helper}' __agent-hook claude Stop < '{}'; printf 'turn\\r\\n'; sleep 600",
        start.display(),
        stop.display()
    );
    let (surface, _) = run_script(&harness, "command-activity-agent-reply", &script, "agent");
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "turn").contains("turn"));
    let deadline = Instant::now() + Duration::from_secs(20);
    let banner = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let line =
            received.recv_timeout(left).expect("no notification event for the finished turn");
        let event: serde_json::Value = serde_json::from_str(&line).unwrap_or_default();
        if event["event"] == "notification" {
            break event;
        }
    };
    assert_eq!(banner["title"], "Claude finished", "{banner}");
    let preview = banner["preview"].as_str().unwrap_or_default();
    assert!(preview.starts_with(marker), "the banner carries the last message: {banner}");
    assert!(preview.chars().count() <= 200, "cut to 200 characters: {}", preview.chars().count());
    // The durable row keeps no copy: no daemon state file holds it, also after a checkpoint.
    resource_request(
        &harness.socket,
        "agent-reply-checkpoint",
        "session.journal.checkpoint.create",
        serde_json::json!({"machine":"current","session":"current"}),
        Some("agent-reply-checkpoint"),
    );
    let leaked = files_containing(&harness.dir, marker.as_bytes());
    let _ = fs::remove_dir_all(&payload_dir);
    assert!(leaked.is_empty(), "the last message reached disk: {leaked:?}");
}

/// Runs `hooks` (provider, event, payload) in one terminal, then returns the daemon's
/// `notification` event that follows, read on the app's event stream.
fn agent_notification(
    name: &str,
    hooks: &[(&str, serde_json::Value)],
) -> (RecoveryHarness, serde_json::Value, PathBuf) {
    let harness = RecoveryHarness::start(name);
    let helper = env!("CARGO_BIN_EXE_cmux-tui");
    let payload_dir = std::env::temp_dir().join(format!("cmux-{name}-{}", std::process::id()));
    fs::create_dir_all(&payload_dir).unwrap();
    let mut calls = String::new();
    for (index, (event, payload)) in hooks.iter().enumerate() {
        let path = payload_dir.join(format!("{index}.json"));
        fs::write(&path, payload.to_string()).unwrap();
        calls.push_str(&format!("'{helper}' __agent-hook claude {event} < '{}'; ", path.display()));
    }
    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{}", serde_json::json!({"id": 1, "cmd": "subscribe"})).unwrap();
    let (events, received) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        while reader.read_line(&mut line).is_ok_and(|read| read > 0) {
            let _ = events.send(std::mem::take(&mut line));
        }
    });
    let script = format!(
        "[ -n \"$CMUX_TUI_TERMINAL_ID\" ] && printf 'agent\\r\\n'; read step; {calls}printf 'turn\\r\\n'; sleep 600"
    );
    let (surface, _) = run_script(&harness, name, &script, "agent");
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "turn").contains("turn"));
    let deadline = Instant::now() + Duration::from_secs(20);
    let event = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let line = received.recv_timeout(left).expect("no notification event for the agent hook");
        let event: serde_json::Value = serde_json::from_str(&line).unwrap_or_default();
        if event["event"] == "notification" {
            break event;
        }
    };
    (harness, event, payload_dir)
}

/// The phone's Feed shows a terminal agent's turn as a GUI chat's: the prompt it answers and its
/// whole answer, markdown and line breaks kept, beside the ledger row's id (to join them). Memory
/// only, as the banner's preview: no daemon file holds either, also after a checkpoint.
#[test]
fn a_finished_turn_notification_carries_the_whole_prompt_and_answer_for_the_feed() {
    let _exclusive = exclusive_process_test();
    let marker = "feed-answer-marker";
    let prompt = format!("feed-prompt-marker: fix the build\n\n- step one\n- {}", "p".repeat(300));
    let reply = format!("{marker}\n\n## Done\n\n```swift\nlet x = 1\n```\n\n{}", "y".repeat(600));
    let (harness, event, payload_dir) = agent_notification(
        "command-activity-feed-answer",
        &[
            (
                "UserPromptSubmit",
                serde_json::json!({"session_id":"feed-1","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":prompt}),
            ),
            (
                "Stop",
                serde_json::json!({"session_id":"feed-1","hook_event_name":"Stop","cwd":"/tmp","last_assistant_message":reply}),
            ),
        ],
    );
    assert_eq!(event["title"], "Claude finished", "{event}");
    assert_eq!(event["message"].as_str(), Some(reply.as_str()), "the whole answer: {event}");
    assert_eq!(event["prompt"].as_str(), Some(prompt.as_str()), "the whole prompt: {event}");
    assert_eq!(event["session"], "feed-1", "the posting agent's session: {event}");
    // The banner keeps its folded 200-character cut.
    let preview = event["preview"].as_str().unwrap_or_default();
    assert!(preview.starts_with(marker) && !preview.contains('\n'), "{event}");
    assert!(preview.chars().count() <= 200, "{}", preview.chars().count());
    // The event names its ledger row.
    let ledger =
        request(&harness.socket, serde_json::json!({"id": 3, "cmd": "list-notifications"}));
    let rows = ledger["notifications"].as_array().cloned().unwrap_or_default();
    assert!(
        rows.iter().any(|row| row["id"] == event["id"] && row["title"] == "Claude finished"),
        "the event's id is the ledger row's: {event} {ledger}"
    );
    assert!(rows.iter().all(|row| row.get("message").is_none()), "{ledger}");
    resource_request(
        &harness.socket,
        "feed-answer-checkpoint",
        "session.journal.checkpoint.create",
        serde_json::json!({"machine":"current","session":"current"}),
        Some("feed-answer-checkpoint"),
    );
    let leaked = files_containing(&harness.dir, marker.as_bytes());
    let leaked_prompt = files_containing(&harness.dir, b"feed-prompt-marker");
    let _ = fs::remove_dir_all(&payload_dir);
    assert!(
        leaked.is_empty() && leaked_prompt.is_empty(),
        "the texts reached disk: {leaked:?} {leaked_prompt:?}"
    );
}

/// A failed tool's card says what went wrong (Claude's PostToolUseFailure `error`), not only the
/// tool's name.
#[test]
fn an_error_notification_carries_the_error_text_for_the_feed() {
    let _exclusive = exclusive_process_test();
    let error = "feed-error-marker: command not found: swiftlint";
    let (_harness, event, payload_dir) = agent_notification(
        "command-activity-feed-error",
        &[
            (
                "UserPromptSubmit",
                serde_json::json!({"session_id":"feed-2","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"lint"}),
            ),
            (
                "PostToolUseFailure",
                serde_json::json!({"session_id":"feed-2","hook_event_name":"PostToolUseFailure","cwd":"/tmp",
                    "tool_name":"Bash","tool_input":{"command":"swiftlint"},"error":error}),
            ),
        ],
    );
    let _ = fs::remove_dir_all(&payload_dir);
    assert_eq!(event["title"], "Claude reported an error", "{event}");
    assert_eq!(event["body"], "Bash", "{event}");
    assert_eq!(event["message"].as_str(), Some(error), "the error text: {event}");
}

/// A reply typed on the phone's Feed (where the screen is not in view) reaches only the agent
/// that waits at its prompt, in the session that posted, and is submitted with Return in the same
/// write (`send` `expect_agent`, `submit`): never a busy agent, one blocked on an approval, or a
/// new session in the same terminal.
#[test]
fn a_feed_reply_reaches_only_the_waiting_agent_session() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-feed-reply");
    let helper = env!("CARGO_BIN_EXE_cmux-tui");
    let payload_dir = std::env::temp_dir().join(format!("cmux-feed-reply-{}", std::process::id()));
    fs::create_dir_all(&payload_dir).unwrap();
    let start = payload_dir.join("start.json");
    let stop = payload_dir.join("stop.json");
    fs::write(&start, serde_json::json!({"session_id":"reply-s1","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"go"}).to_string()).unwrap();
    fs::write(&stop, serde_json::json!({"session_id":"reply-s1","hook_event_name":"Stop","cwd":"/tmp","last_assistant_message":"done"}).to_string()).unwrap();
    // `cat` stands in for the agent's prompt once its turn ended: it echoes what it reads.
    let script = format!(
        "[ -n \"$CMUX_TUI_TERMINAL_ID\" ] && printf 'agent\\r\\n'; read step; \
         '{helper}' __agent-hook claude UserPromptSubmit < '{}'; \
         '{helper}' __agent-hook claude Stop < '{}'; printf 'turn\\r\\n'; exec cat",
        start.display(),
        stop.display()
    );
    let (surface, _) = run_script(&harness, "command-activity-feed-reply", &script, "agent");
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "turn").contains("turn"));
    wait_for_agent_state(&harness, "idle");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let program = loop {
        let info = request(
            &harness.socket,
            serde_json::json!({"id": 4, "cmd": "process-info", "surface": surface}),
        );
        if let Some(name) =
            info["foreground_executable"].as_str().filter(|name| name.ends_with("cat"))
        {
            break name.to_string();
        }
        assert!(Instant::now() < deadline, "cat never became the foreground: {info}");
        std::thread::sleep(Duration::from_millis(50));
    };
    let reply = |id: u64, text: &str, session: &str| {
        request_response(
            &harness.socket,
            serde_json::json!({"id": id, "cmd": "send", "surface": surface, "text": text,
                "expect_foreground": program, "expect_agent": {"session": session}, "submit": true}),
        )
    };
    // Another session in the same terminal: refused, nothing typed.
    let other = reply(5, "wrong_session_reply", "reply-s2");
    assert_eq!(other["ok"], false, "{other}");
    assert!(other["error"].to_string().contains("agent not waiting"), "{other}");
    // The waiting session: typed and submitted (cat prints the line back after Return).
    // No session: refused (a restarted agent would otherwise pass).
    let unnamed = request_response(
        &harness.socket,
        serde_json::json!({"id": 11, "cmd": "send", "surface": surface, "text": "unnamed_reply",
            "expect_foreground": program, "expect_agent": {}, "submit": true}),
    );
    assert_eq!(unnamed["ok"], false, "{unnamed}");
    let sent = reply(6, "feed_reply_ok", "reply-s1");
    assert_eq!(sent["ok"], true, "{sent}");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let screen = loop {
        let screen = wait_for_screen(&harness.socket, surface, "feed_reply_ok");
        if screen.matches("feed_reply_ok").count() >= 2 {
            break screen;
        }
        assert!(Instant::now() < deadline, "the reply was typed but not submitted:\n{screen}");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(
        !screen.contains("wrong_session_reply") && !screen.contains("unnamed_reply"),
        "{screen}"
    );
    // The agent went back to work, then asks for approval (its own hooks, from another shell):
    // refused both times.
    // The terminal's public id, as the finished turn's ledger row names it.
    let terminal_id = request(
        &harness.socket,
        serde_json::json!({"id": 7, "cmd": "list-notifications"}),
    )["notifications"][0]["terminal_id"]
        .as_str()
        .expect("the agent's public terminal id")
        .to_string();
    let hook = |event: &str, payload: serde_json::Value| {
        let path = payload_dir.join(format!("{event}.json"));
        fs::write(&path, payload.to_string()).unwrap();
        let output = Command::new(helper)
            .args(["__agent-hook", "claude", event])
            .env("CMUX_TUI_SOCKET", &harness.socket)
            .env("CMUX_TUI_TERMINAL_ID", &terminal_id)
            .stdin(fs::File::open(&path).unwrap())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{event} hook failed ({terminal_id}): {}",
            String::from_utf8_lossy(&output.stderr)
        );
    };
    hook(
        "UserPromptSubmit",
        serde_json::json!({"session_id":"reply-s1","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"again"}),
    );
    wait_for_agent_state(&harness, "working");
    let busy = reply(8, "busy_reply", "reply-s1");
    assert_eq!(busy["ok"], false, "{busy}");
    hook(
        "PermissionRequest",
        serde_json::json!({"session_id":"reply-s1","hook_event_name":"PermissionRequest","cwd":"/tmp","tool_name":"Bash"}),
    );
    wait_for_agent_state(&harness, "blocked");
    let asking = reply(10, "asking_reply", "reply-s1");
    assert_eq!(asking["ok"], false, "{asking}");
    let _ = fs::remove_dir_all(&payload_dir);
    let screen = request(
        &harness.socket,
        serde_json::json!({"cmd": "read-screen", "surface": surface}),
    )["text"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(!screen.contains("busy_reply") && !screen.contains("asking_reply"), "{screen}");
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis().try_into().unwrap()
}

#[test]
fn a_shell_at_its_prompt_names_when_it_last_printed() {
    let _exclusive = exclusive_process_test();
    let before = now_ms();
    let harness = RecoveryHarness::start("command-activity-last-output");
    let (surface, _) = run_script(
        &harness,
        "command-activity-last-output",
        concat!(
            "printf '\\033]133;A\\007prompt\\r\\n'; read step; ",
            "printf 'later\\r\\n'; sleep 600",
        ),
        "prompt",
    );
    let extra = terminal_extra(&harness);
    assert!(extra.get("prompt").is_some(), "the shell sits at its prompt: {extra}");
    let first = ms(&extra["last_output"]["at_ms"]);
    assert!(first >= before && first <= now_ms(), "{first} outside {before}..now: {extra}");

    // Quiet output keeps its time.
    std::thread::sleep(Duration::from_millis(1_100));
    assert_eq!(ms(&terminal_extra(&harness)["last_output"]["at_ms"]), first);

    let stepped = now_ms();
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "later").contains("later"));
    let extra = terminal_extra(&harness);
    let later = ms(&extra["last_output"]["at_ms"]);
    assert!(later >= stepped && later <= now_ms(), "{later} outside {stepped}..now: {extra}");
}

/// A terminal agent's AskUserQuestion reaches the phone with its question and options
/// (cmux-next-ios `verify/rich-push.md`, "Terminal agents"): the notification event and the
/// ledger row carry it while the agent waits, it is gone once the agent works again, and no
/// daemon state file ever holds it.
#[test]
fn an_agent_question_reaches_the_notification_and_its_row_in_memory_only() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-agent-question");
    let helper = env!("CARGO_BIN_EXE_cmux-tui");
    let marker = "question-marker-text";
    let payload_dir = std::env::temp_dir().join(format!("cmux-question-{}", std::process::id()));
    fs::create_dir_all(&payload_dir).unwrap();
    let ask = payload_dir.join("ask.json");
    let resume = payload_dir.join("resume.json");
    fs::write(
        &ask,
        serde_json::json!({"session_id":"question-1","hook_event_name":"PreToolUse","cwd":"/tmp",
            "tool_name":"AskUserQuestion","tool_use_id":"toolu_q1","tool_input":{"questions":[
                {"question":format!("{marker} which branch?"),"header":"Branch","multiSelect":false,
                 "options":[{"label":"main","description":"the default"},{"label":"dev"},{"label":"release"}]},
                {"question":"Which checks?","header":"Checks","multiSelect":true,
                 "options":[{"label":"lint"},{"label":"tests"}]}]}})
        .to_string(),
    )
    .unwrap();
    fs::write(
        &resume,
        serde_json::json!({"session_id":"question-1","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"go on"})
            .to_string(),
    )
    .unwrap();
    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{}", serde_json::json!({"id": 1, "cmd": "subscribe"})).unwrap();
    let (events, received) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        while reader.read_line(&mut line).is_ok_and(|read| read > 0) {
            let _ = events.send(std::mem::take(&mut line));
        }
    });
    let script = format!(
        "[ -n \"$CMUX_TUI_TERMINAL_ID\" ] && printf 'agent\\r\\n'; read step; \
         '{helper}' __agent-hook claude PreToolUse < '{}'; printf 'asked\\r\\n'; read step; \
         '{helper}' __agent-hook claude UserPromptSubmit < '{}'; printf 'resumed\\r\\n'; sleep 600",
        ask.display(),
        resume.display()
    );
    let (surface, _) = run_script(&harness, "command-activity-agent-question", &script, "agent");
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "asked").contains("asked"));
    let deadline = Instant::now() + Duration::from_secs(20);
    let banner = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let line = received.recv_timeout(left).expect("no notification event for the question");
        let event: serde_json::Value = serde_json::from_str(&line).unwrap_or_default();
        if event["event"] == "notification" {
            break event;
        }
    };
    assert_eq!(banner["title"], "Claude asked a question", "{banner}");
    let question = &banner["question"];
    assert_eq!(question["harness"], "claude", "{banner}");
    assert_eq!(question["tool_use_id"], "toolu_q1", "{banner}");
    assert_eq!(question["questions"][0]["question"], format!("{marker} which branch?"));
    assert_eq!(question["questions"][0]["options"][0]["description"], "the default");
    assert_eq!(question["questions"][1]["multiSelect"], true);
    // The ledger row shows it while the agent waits.
    let rows = request(&harness.socket, serde_json::json!({"id": 4, "cmd": "list-notifications"}));
    let row = rows["notifications"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| row["title"] == "Claude asked a question")
        .cloned()
        .unwrap_or_default();
    assert_eq!(row["question"], *question, "{rows}");
    // No daemon state file holds it, also after a checkpoint.
    resource_request(
        &harness.socket,
        "agent-question-checkpoint",
        "session.journal.checkpoint.create",
        serde_json::json!({"machine":"current","session":"current"}),
        Some("agent-question-checkpoint"),
    );
    let leaked = files_containing(&harness.dir, marker.as_bytes());
    assert!(leaked.is_empty(), "the question reached disk: {leaked:?}");
    // Working again (answered in the terminal or from the phone): the row no longer asks.
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "resumed").contains("resumed"));
    wait_for_agent_state(&harness, "working");
    let rows = request(&harness.socket, serde_json::json!({"id": 5, "cmd": "list-notifications"}));
    let still = rows["notifications"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|row| row["title"] == "Claude asked a question" && !row["question"].is_null());
    let _ = fs::remove_dir_all(&payload_dir);
    assert!(!still, "an answered question is forgotten: {rows}");
}
