//! Cmd-K (`history clear`) with OSC 133 prompts that sit on adjacent rows.
//!
//! Deterministic on purpose: a program prints the marks zsh's Ghostty
//! integration sends (133;A before a prompt, 133;B after it, 133;C and 133;D
//! around a command, 133;P;k=s before a later prompt line) and then waits in
//! `cat`, so no shell rc file or prompt theme takes part.

use super::*;

/// A headless server with one terminal that runs a clean bash (no rc files,
/// no prompt marks of its own).
struct MarkedPrompts {
    server: HeadlessServer,
    terminal: String,
}

impl MarkedPrompts {
    fn start(name: &str) -> Self {
        let server = HeadlessServer::start_without_shell_integration(name);
        let created = json_cli(&server, &["workspace", "create", "--name", name]);
        assert_success(&created);
        let terminal = json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_string();
        let prompts = Self { server, terminal };
        // Replace the login shell (any user rc and prompt) with a clean bash.
        prompts.write("exec env PS1='$ ' PROMPT_COMMAND= bash --norc --noprofile -i\r");
        prompts.write("clear\r");
        prompts.wait_until("the clean prompt", &|text| text.trim() == "$");
        prompts
    }

    fn write(&self, text: &str) {
        let sent =
            cli(&self.server, &["--quiet", "terminal", &self.terminal, "write", "--text", text]);
        assert_success(&sent);
    }

    fn screen(&self) -> String {
        let read = json_cli(&self.server, &["terminal", &self.terminal, "screen", "read"]);
        assert_success(&read);
        json_output(&read)["text"].as_str().unwrap().to_string()
    }

    fn history(&self) -> String {
        let read = json_cli(
            &self.server,
            &["terminal", &self.terminal, "history", "read", "--limit", "200"],
        );
        assert_success(&read);
        String::from_utf8_lossy(&read.stdout).into_owned()
    }

    fn wait_until(&self, what: &str, done: &dyn Fn(&str) -> bool) -> String {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let text = self.screen();
            if done(&text) {
                return text;
            }
            assert!(Instant::now() < deadline, "{what} never happened: {text:?}");
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    /// Runs `printf '<transcript>'; cat`: the transcript's last prompt stays
    /// the terminal's active prompt while `cat` waits.
    fn print(&self, transcript: &str) {
        self.write(&format!("printf '{transcript}'; cat\r"));
    }

    fn clear_history(&self) {
        let cleared =
            cli(&self.server, &["--quiet", "terminal", &self.terminal, "history", "clear"]);
        assert_success(&cleared);
    }
}

fn has_line(text: &str, line: &str) -> bool {
    text.lines().any(|row| row.trim_end() == line)
}

/// A one-line prompt with its marks, as printf text.
fn prompt(text: &str) -> String {
    format!("\\033]133;A\\007{text}\\033]133;B\\007")
}

/// A two-line prompt (the second line marked as a continuation) with pending
/// input, as printf text.
const TWO_LINE_PROMPT: &str =
    "\\033]133;A\\007four-top\\r\\n\\033]133;P;k=s\\007four> \\033]133;B\\007pending";

/// `history clear` (Cmd-K) at a prompt keeps that prompt only. Each OSC 133;A
/// starts a new prompt, so prompts on adjacent rows (Enter on an empty line,
/// or commands that print nothing, such as `cd`) are separate prompts: the
/// older ones go with the rest of the screen, as after Ghostty's
/// clear_screen. A prompt of more than one line stays whole. Before, every
/// adjacent prompt row counted as one multi-line prompt and all of them
/// stayed, so Cmd-K looked like it did nothing.
#[test]
fn history_clear_at_a_prompt_drops_the_older_adjacent_prompts() {
    let prompts = MarkedPrompts::start("history-clear-prompts");

    // Three one-line prompts on adjacent rows (an empty Enter, a command
    // without output, another empty Enter), then a two-line prompt with
    // pending input. The command line's own echo holds the escapes as text,
    // so no echoed row equals a printed prompt row.
    let transcript = [
        "old-output\\n".to_string(),
        prompt("one> "),
        "\\r\\n".to_string(),
        prompt("two> "),
        "true\\r\\n\\033]133;C\\007\\033]133;D;0\\007".to_string(),
        prompt("three> "),
        "\\r\\n".to_string(),
        TWO_LINE_PROMPT.to_string(),
    ]
    .concat();
    prompts.print(&transcript);
    let before = prompts.wait_until("the prompts", &|text| has_line(text, "four> pending"));
    for row in ["old-output", "one>", "two> true", "three>", "four-top"] {
        assert!(has_line(&before, row), "setup did not print {row:?}: {before:?}");
    }

    prompts.clear_history();
    // Wait for the result: a hosted terminal applies the clear on its own
    // reader, and the old screen must not pass by being read too early.
    let after = prompts.wait_until("the clear", &|text| {
        !text.contains("old-output") && has_line(text, "four> pending")
    });
    assert_eq!(
        after.trim_end(),
        "four-top\nfour> pending",
        "Cmd-K at a prompt kept more than that prompt: {after:?}"
    );
}

/// A prompt whose first line is the top row of the screen stays whole, also
/// when the newest history row is an older prompt (the state after Ctrl-L or
/// `clear`). Before, the older prompt's mark made the top row count as the
/// middle of one long prompt, and Cmd-K erased the prompt's first line.
#[test]
fn history_clear_keeps_a_prompt_that_starts_on_the_top_row() {
    let prompts = MarkedPrompts::start("history-clear-top-row");

    // Start from an empty screen and history; print old output, a one-line
    // prompt and the two-line prompt on rows 1 to 4; scroll two rows into
    // the history from the bottom row, so the two-line prompt starts on the
    // top row; put the cursor back after the pending input.
    let transcript = [
        "\\033[H\\033[2J\\033[3J".to_string(),
        "old-output\\r\\n".to_string(),
        prompt("one> "),
        "\\r\\n".to_string(),
        TWO_LINE_PROMPT.to_string(),
        "\\033[999;1H\\n\\n\\033[2;14H".to_string(),
    ]
    .concat();
    prompts.print(&transcript);
    prompts.wait_until("the prompt on the top row", &|text| {
        text.trim_end() == "four-top\nfour> pending"
    });
    let history = prompts.history();
    assert!(
        history.contains("old-output") && history.contains("one>"),
        "setup did not scroll the older rows into the history: {history:?}"
    );

    prompts.clear_history();
    let deadline = Instant::now() + Duration::from_secs(15);
    while prompts.history().contains("old-output") {
        assert!(Instant::now() < deadline, "the clear never reached the history");
        std::thread::sleep(Duration::from_millis(100));
    }
    let after = prompts.screen();
    assert_eq!(
        after.trim_end(),
        "four-top\nfour> pending",
        "Cmd-K erased part of the prompt on the top row: {after:?}"
    );
}

/// A prompt whose first line already scrolled into the history cannot stay
/// whole: Cmd-K then keeps the input line only, so the screen is clean and
/// no middle line of the prompt stays above it.
#[test]
fn history_clear_keeps_only_the_input_line_of_a_prompt_that_starts_in_history() {
    let prompts = MarkedPrompts::start("history-clear-in-history");

    // A three-line prompt on rows 1 to 3 of an empty screen (its second line
    // reached by a plain newline, its third marked as a continuation), then
    // one row scrolled into the history from the bottom row.
    let transcript = concat!(
        "\\033[H\\033[2J\\033[3J",
        "\\033]133;A\\007three-top\\r\\nthree-mid\\r\\n",
        "\\033]133;P;k=s\\007three> \\033]133;B\\007pending",
        "\\033[999;1H\\n\\033[2;15H",
    );
    prompts.print(transcript);
    prompts.wait_until("the prompt's second line on the top row", &|text| {
        text.trim_end() == "three-mid\nthree> pending"
    });
    assert!(prompts.history().contains("three-top"), "setup did not scroll the first line off");

    prompts.clear_history();
    let deadline = Instant::now() + Duration::from_secs(15);
    while prompts.history().contains("three-top") {
        assert!(Instant::now() < deadline, "the clear never reached the history");
        std::thread::sleep(Duration::from_millis(100));
    }
    let after = prompts.screen();
    assert_eq!(
        after.trim_end(),
        "three> pending",
        "Cmd-K left part of a prompt that starts in the history: {after:?}"
    );
}
