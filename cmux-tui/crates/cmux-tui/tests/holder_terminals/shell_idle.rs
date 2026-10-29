//! `extra.shell_idle` on the holder (the default terminal model). Only a
//! prompt the shell draws for a new line answers a typed line: a Return no
//! prompt answers (a `read`, a password, a line continued over two lines)
//! keeps the terminal not idle (the close asks), and a line the shell read but
//! has not run, or that a Return hook holds, is never idle. Review 6 of
//! cp/daemon-foreground-state refuted every kernel fact that could tell those
//! apart from a line editor waiting at its prompt. The shell is an interactive
//! bash whose prompt is the only integration: `A` and `B` around `idle> `, no
//! `C` or `D`.

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
    start_bash_with(name, "")
}

/// [`start_bash`] with `rc_prefix` first in its rc file.
fn start_bash_with(name: &str, rc_prefix: &str) -> Option<(Daemon, u64)> {
    let bash = ["/bin/bash", "/usr/bin/bash", "/opt/homebrew/bin/bash"]
        .into_iter()
        .find(|path| Path::new(path).is_file())?;
    let mut daemon = Daemon::start_with_env(&[("CMUX_TUI_SHELL_INTEGRATION", Path::new("none"))]);
    let rc = daemon.dir.join("bashrc");
    fs::write(
        &rc,
        format!(
            "{rc_prefix}PS1='\\[\\033]133;A\\007\\]idle> \\[\\033]133;B\\007\\]'\n\
             unset PROMPT_COMMAND\nHISTFILE=/dev/null\n"
        ),
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

/// Waits for `n` prompts, then asserts the terminal stays not idle for
/// `hold`: a Return the shell answered with no prompt (a `read`, a password,
/// a line continued over two lines) stays owed one, and only a prompt pays it
/// (review 6 of cp/daemon-foreground-state refuted every kernel fact that
/// could). The close asks: the cost the lead accepted.
fn assert_stays_not_idle(socket: &Path, surface: u64, n: usize, hold: Duration, what: &str) {
    wait_for_prompts(socket, surface, n);
    let until = Instant::now() + hold;
    while Instant::now() < until {
        let extra = terminal_extra(socket);
        assert!(extra.get("shell_idle").is_none(), "{what}: read idle: {extra}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn shell_idle_holder_a_return_read_took_stays_owed() {
    let Some((daemon, surface)) = start_bash("idle-read") else { return };
    type_text(&daemon.socket, surface, "read x\r");
    // `read` takes this Return: no prompt answers it.
    type_text(&daemon.socket, surface, "hello\r");
    assert_stays_not_idle(&daemon.socket, surface, 2, Duration::from_millis(1_000), "after read");
}

#[test]
fn shell_idle_holder_a_line_continued_over_two_lines_stays_owed() {
    let Some((daemon, surface)) = start_bash("idle-loop") else { return };
    // The first Return draws an unmarked PS2, not a prompt.
    type_text(&daemon.socket, surface, "for i in 1 2; do\r");
    type_text(&daemon.socket, surface, "echo i$i; done\r");
    assert_stays_not_idle(
        &daemon.socket,
        surface,
        2,
        Duration::from_millis(1_000),
        "after a two-line for loop",
    );
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

/// A line the line editor read but the shell has not run yet is never idle.
/// bash's DEBUG trap runs after readline returned the line and before the
/// command runs; here it blocks on a FIFO no one writes, so the shell sleeps
/// in that window with no child, no input and no output in flight. The line was typed
/// ahead (one write with the line before it), so the prompt after `true`
/// owes it. For as long as the shell sleeps there, the terminal is never
/// idle.
#[test]
fn shell_idle_holder_a_line_read_but_not_run_is_never_idle() {
    let fifo =
        std::env::temp_dir().join(format!("shell-idle-debug-{}-{}", std::process::id(), line!()));
    let _ = fs::remove_file(&fifo);
    let made = std::process::Command::new("mkfifo").arg(&fifo).status().unwrap();
    assert!(made.success(), "mkfifo failed");
    let rc = format!(
        "exec 9<>{}\ntrap '[[ $BASH_COMMAND == \"sleep 600\" ]] && read -t 4 -u 9 _' DEBUG\n",
        fifo.display()
    );
    let Some((daemon, surface)) = start_bash_with("idle-read-not-run", &rc) else {
        let _ = fs::remove_file(&fifo);
        return;
    };
    type_text(&daemon.socket, surface, "true\rsleep 600\r");
    wait_for_prompts(&daemon.socket, surface, 2);
    let until = Instant::now() + Duration::from_millis(3_000);
    while Instant::now() < until {
        let extra = terminal_extra(&daemon.socket);
        assert!(extra.get("shell_idle").is_none(), "a line read but not run read idle: {extra}");
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = fs::remove_file(&fifo);
}

/// Review 6 of cp/daemon-foreground-state: a Return hook can sleep after the
/// line editor read a line and before the shell runs it, while the terminal
/// still reads raw, with no child and nothing queued. bash's `bind -x` reached through a Return macro runs in
/// readline's prepped (raw) terminal. Here the hook prints a mark (so a
/// foreground check is due while it sleeps) and blocks 4 s on a FIFO for the
/// typed-ahead `sleep 600`. A kernel read that pays the prompt that line is
/// owed reads the terminal idle; it never may.
#[test]
fn shell_idle_holder_a_line_held_by_a_return_hook_is_never_idle() {
    let fifo =
        std::env::temp_dir().join(format!("shell-idle-bind-x-{}-{}", std::process::id(), line!()));
    let _ = fs::remove_file(&fifo);
    let made = std::process::Command::new("mkfifo").arg(&fifo).status().unwrap();
    assert!(made.success(), "mkfifo failed");
    let rc = format!(
        "exec 9<>{}\n\
         blk() {{ [[ $READLINE_LINE == \"sleep 600\" ]] || return; \
         printf '\\033]133;B\\007'; read -t 4 -u 9 _; }}\n\
         bind -x '\"\\C-x\\C-a\": blk'\n\
         bind '\"\\C-m\": \"\\C-x\\C-a\\C-j\"'\n",
        fifo.display()
    );
    let Some((daemon, surface)) = start_bash_with("idle-bind-x", &rc) else {
        let _ = fs::remove_file(&fifo);
        return;
    };
    type_text(&daemon.socket, surface, "true\rsleep 600\r");
    wait_for_prompts(&daemon.socket, surface, 2);
    let until = Instant::now() + Duration::from_millis(3_500);
    while Instant::now() < until {
        let extra = terminal_extra(&daemon.socket);
        assert!(
            extra.get("shell_idle").is_none(),
            "a line held by a Return hook read idle: {extra}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = fs::remove_file(&fifo);
}
