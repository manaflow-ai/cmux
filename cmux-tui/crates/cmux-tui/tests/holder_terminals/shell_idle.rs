//! `extra.shell_idle` on the holder (the default terminal model): a Return
//! the shell does not answer with a prompt of its own must not keep the
//! terminal not idle for good (review 4 of cp/daemon-foreground-state,
//! should-fix 1). A password prompt, `read`, a line continued over two
//! lines and fish's Ctrl-C each take a Return that no new prompt answers;
//! the shell's next prompt after the next command still reads idle. A line
//! really typed ahead (still unread when the prompt comes) stays not idle.
//! The shell is an interactive bash whose prompt is the only integration:
//! `A` and `B` around `idle> `, no `C` or `D`.

use super::*;

/// The screen marker of a drawn prompt (PS1 is `idle> `; the screen text
/// drops the trailing blank).
const PROMPT: &str = "idle>";

/// `extra` of the daemon's only terminal record.
fn terminal_extra(socket: &Path) -> Value {
    let stream = UnixStream::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
    let body = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "idle-list",
        "operation": "terminal.list", "params": {"machine": "current", "session": "current"}});
    (&stream).write_all(format!("{body}\n").as_bytes()).unwrap();
    let mut line = String::new();
    BufReader::new(&stream).read_line(&mut line).unwrap();
    let reply: Value = serde_json::from_str(&line).unwrap();
    let terminals = reply["result"].as_array().cloned().unwrap_or_default();
    assert_eq!(terminals.len(), 1, "expected one terminal: {reply}");
    terminals[0]["extra"].clone()
}

/// A daemon on the holder running one interactive bash (`rc_prefix` first in
/// its rc file), at its first prompt and idle there. `None` when bash is not
/// installed.
fn start_bash(name: &str) -> Option<(Daemon, u64)> {
    let bash = ["/bin/bash", "/usr/bin/bash", "/opt/homebrew/bin/bash"]
        .into_iter()
        .find(|path| Path::new(path).is_file())?;
    let mut daemon = Daemon::start_with_env(&[("CMUX_TUI_SHELL_INTEGRATION", Path::new("none"))]);
    let rc = daemon.dir.join("bashrc");
    fs::write(
        &rc,
        "PS1='\\[\\033]133;A\\007\\]idle> \\[\\033]133;B\\007\\]'\n\
         unset PROMPT_COMMAND\nHISTFILE=/dev/null\n",
    )
    .unwrap();
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": [bash, "--noprofile", "--rcfile", rc, "-i"],
            "new_workspace": true, "name": name, "cols": 100, "rows": 12}),
    );
    let surface = created["surface"].as_u64().unwrap();
    daemon.track(surface);
    screen_contains(&daemon.socket, surface, PROMPT);
    wait_for_idle(&daemon.socket, "the first prompt");
    Some((daemon, surface))
}

/// Waits until the daemon says the shell sits idle at its prompt.
fn wait_for_idle(socket: &Path, what: &str) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let extra = terminal_extra(socket);
        if extra["shell_idle"]["since_ms"].is_string() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{what}: the shell at its prompt never read idle: {extra}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Types `text` into the terminal.
fn type_text(socket: &Path, surface: u64, text: &str) {
    request(socket, json!({"cmd": "send", "surface": surface, "text": text}));
}

/// Waits for the prompt drawn after the `n`th prompt on the screen, the
/// shell's answer to the last line.
fn wait_for_prompts(socket: &Path, surface: u64, n: usize) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let text = request(socket, json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        if text.matches(PROMPT).count() >= n {
            return;
        }
        assert!(Instant::now() < deadline, "no {n} prompts on the screen:\n{text}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn shell_idle_holder_a_plain_prompt_is_idle() {
    let Some((daemon, _surface)) = start_bash("idle-plain") else { return };
    let extra = terminal_extra(&daemon.socket);
    assert_eq!(extra["foreground_check"]["own"], true, "{extra}");
}

#[test]
fn shell_idle_holder_the_prompt_after_read_is_idle() {
    let Some((daemon, surface)) = start_bash("idle-read") else { return };
    type_text(&daemon.socket, surface, "read x\r");
    // `read` takes this Return: no prompt answers it.
    type_text(&daemon.socket, surface, "hello\r");
    wait_for_prompts(&daemon.socket, surface, 2);
    wait_for_idle(&daemon.socket, "after read");
}

#[test]
fn shell_idle_holder_the_prompt_after_a_password_prompt_is_idle() {
    let Some((daemon, surface)) = start_bash("idle-password") else { return };
    type_text(&daemon.socket, surface, "read -s secret\r");
    type_text(&daemon.socket, surface, "hunter2\r");
    wait_for_prompts(&daemon.socket, surface, 2);
    wait_for_idle(&daemon.socket, "after a password prompt");
}

#[test]
fn shell_idle_holder_the_prompt_after_a_line_continued_over_two_lines_is_idle() {
    let Some((daemon, surface)) = start_bash("idle-loop") else { return };
    // The first Return draws PS2, not a prompt.
    type_text(&daemon.socket, surface, "for i in 1 2; do\r");
    type_text(&daemon.socket, surface, "echo i$i; done\r");
    wait_for_prompts(&daemon.socket, surface, 2);
    wait_for_idle(&daemon.socket, "after a two-line for loop");
}

/// fish 4's Ctrl-C clears the line and draws no new prompt: the prompt after
/// the next command reads idle.
#[test]
fn shell_idle_holder_the_prompt_after_fishs_ctrl_c_is_idle() {
    let Some(fish) = ["/usr/bin/fish", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
        .into_iter()
        .find(|path| Path::new(path).is_file())
    else {
        eprintln!("skipped: fish is not installed");
        return;
    };
    let mut daemon = Daemon::start_with_env(&[("CMUX_TUI_SHELL_INTEGRATION", Path::new("none"))]);
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": [fish, "--no-config",
            "--init-command=function fish_prompt; printf '\\e]133;A\\aidle> \\e]133;B\\a'; end"],
            "new_workspace": true, "name": "idle-fish", "cols": 100, "rows": 12}),
    );
    let surface = created["surface"].as_u64().unwrap();
    daemon.track(surface);
    screen_contains(&daemon.socket, surface, PROMPT);
    wait_for_idle(&daemon.socket, "fish's first prompt");
    type_text(&daemon.socket, surface, "echo abc");
    type_text(&daemon.socket, surface, "\u{3}");
    type_text(&daemon.socket, surface, "true\r");
    std::thread::sleep(Duration::from_millis(500)); // test harness: let fish draw the prompt after `true`
    wait_for_idle(&daemon.socket, "after fish's Ctrl-C");
}

/// Guard: a line typed while a command runs waits unread for the shell; the
/// prompt the command ends with is not idle while it waits, and the line then
/// runs (`sleep 600`): never idle.
#[test]
fn shell_idle_holder_a_line_typed_ahead_is_never_idle() {
    let Some((daemon, surface)) = start_bash("idle-typed-ahead") else { return };
    // `ran''-one` keeps the marker out of the echoed command line.
    type_text(&daemon.socket, surface, "sleep 1; echo ran''-one\r");
    type_text(&daemon.socket, surface, "sleep 600\r");
    screen_contains(&daemon.socket, surface, "ran-one");
    let until = Instant::now() + Duration::from_millis(1_500);
    while Instant::now() < until {
        let extra = terminal_extra(&daemon.socket);
        assert!(extra.get("shell_idle").is_none(), "a line typed ahead read idle: {extra}");
        std::thread::sleep(Duration::from_millis(20));
    }
}
