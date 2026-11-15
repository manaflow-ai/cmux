use super::*;

fn read(screen: &str) -> Option<TerminalApproval> {
    terminal_approval(&ApprovalScreen { screen: screen.to_owned() })
}

fn labels(approval: &TerminalApproval) -> Vec<(u32, &str, &str, bool)> {
    approval.options.iter().map(|o| (o.key, o.label.as_str(), o.kind, o.selected)).collect()
}

/// Claude Code 2.x's Bash dialog under a rule, after the turn that asked (the shape the screen
/// detection manifest's `bash_permission_prompt` names, #2650): heading, command, description,
/// question, three options with the cursor on the first, the hint row.
const CLAUDE_BASH: &str = "\
⏺ I'll create the marker file.

⏺ Bash(touch /tmp/w4i-perm)
  ⎿  Running…

────────────────────────────────────────────────────────────────────────────────
 Bash command

   touch /tmp/w4i-perm
   Create an empty marker file

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for touch commands in /private/tmp
   3. No, and tell Claude what to do differently (esc)

 Esc to cancel · Tab to amend · ctrl+e to explain
";

/// Codex's command approval: the question first, its reason and `$ command`, options with key
/// hints, the confirm hint (`press enter to confirm or esc to cancel`, codex.toml).
const CODEX_EXEC: &str = "\
• I'll create the marker file outside the workspace.

  Would you like to run the following command?

  Reason: Create the marker file outside the workspace

  $ touch /tmp/w4i-perm

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for this command (a)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
";

#[test]
fn claude_codes_bash_dialog_reads_as_its_question_command_and_options() {
    let approval = read(CLAUDE_BASH).expect("a dialog");
    assert_eq!(approval.question, "Do you want to proceed?");
    assert_eq!(approval.header.as_deref(), Some("Bash command"));
    assert_eq!(approval.command.as_deref(), Some("touch /tmp/w4i-perm"));
    assert_eq!(approval.detail, ["Create an empty marker file"]);
    assert_eq!(
        labels(&approval),
        [
            (1, "Yes", "allow_once", true),
            (
                2,
                "Yes, and don't ask again for touch commands in /private/tmp",
                "allow_always",
                false
            ),
            (3, "No, and tell Claude what to do differently", "reject_once", false),
        ]
    );
    assert_eq!(approval.options[2].hint.as_deref(), Some("esc"));
}

#[test]
fn codexs_command_approval_reads_with_its_reason_and_command() {
    let approval = read(CODEX_EXEC).expect("a dialog");
    assert_eq!(approval.question, "Would you like to run the following command?");
    assert_eq!(approval.header, None);
    assert_eq!(approval.command.as_deref(), Some("touch /tmp/w4i-perm"));
    assert_eq!(approval.detail, ["Reason: Create the marker file outside the workspace"]);
    assert_eq!(
        labels(&approval),
        [
            (1, "Yes, proceed", "allow_once", true),
            (2, "Yes, and don't ask again for this command", "allow_always", false),
            (3, "No, and tell Codex what to do differently", "reject_once", false),
        ]
    );
    assert_eq!(approval.options[0].hint.as_deref(), Some("y"));
}

/// The two-option dialog the cmux CLI's `terminal send` tests stop at (terminal_talk/tests.rs
/// `DIALOG_SCREEN`): no rule, the prompt's echo above.
#[test]
fn a_two_option_dialog_without_a_rule_stops_at_the_transcript() {
    let screen = "⏺ OLD_ANSWER_ONE\n\n❯ Run the shell command touch /tmp/w4i-perm now.\n\n\
⏺ Bash(touch /tmp/w4i-perm)\n\n Bash command\n   touch /tmp/w4i-perm\n Do you want to proceed?\n \
❯ 1. Yes\n   2. No";
    let approval = read(screen).expect("a dialog");
    assert_eq!(approval.header.as_deref(), Some("Bash command"));
    assert_eq!(approval.command.as_deref(), Some("touch /tmp/w4i-perm"));
    assert!(approval.detail.is_empty(), "{:?}", approval.detail);
    assert_eq!(
        labels(&approval),
        [(1, "Yes", "allow_once", true), (2, "No", "reject_once", false)]
    );
}

/// Claude Code's boxed dialog (before 2.x) and its edit dialog with the diff in dashed rules.
#[test]
fn a_boxed_dialog_and_an_edit_dialog_read_too() {
    let boxed = "\
╭──────────────────────────────────────────────╮
│ Bash command                                 │
│                                              │
│   rm -rf build                               │
│   Remove the build folder                    │
│                                              │
│ Do you want to proceed?                      │
│ ❯ 1. Yes                                     │
│   2. No, and tell Claude what to do differently (esc) │
╰──────────────────────────────────────────────╯";
    let approval = read(boxed).expect("a boxed dialog");
    assert_eq!(approval.header.as_deref(), Some("Bash command"));
    assert_eq!(approval.command.as_deref(), Some("rm -rf build"));
    assert_eq!(approval.detail, ["Remove the build folder"]);
    assert_eq!(approval.options[1].label, "No, and tell Claude what to do differently");

    let edit = "\
──────────────────────────────────────────
 Edit file
 src/main.rs
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 1  fn main() {
 2 -    println!(\"hi\");
 2 +    println!(\"hello\");
 3  }
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to make this edit to main.rs?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No, and tell Claude what to do differently (esc)
";
    let approval = read(edit).expect("an edit dialog");
    assert_eq!(approval.question, "Do you want to make this edit to main.rs?");
    assert_eq!(approval.header.as_deref(), Some("Edit file"));
    assert_eq!(approval.command, None);
    assert_eq!(approval.detail[0], "src/main.rs");
    assert!(
        approval.detail.contains(&"2 +    println!(\"hello\");".to_owned()),
        "{:?}",
        approval.detail
    );
    assert_eq!(approval.options[1].kind, "allow_always");
    assert_eq!(approval.options[1].hint.as_deref(), Some("shift+tab"));
}

/// A numbered list in an answer is not a dialog: no cursor, the prompt box below it, or no
/// question above it.
#[test]
fn a_numbered_list_in_an_answer_is_no_dialog() {
    let answer = "⏺ Which would you like?\n  1. Rust\n  2. Swift\n\n╭────────╮\n│ >      │\n╰────────╯\n  ? for shortcuts";
    assert_eq!(read(answer), None);
    let idle = "⏺ Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n❯ \n";
    assert_eq!(read(idle), None, "the prompt box after the list");
    let no_question = " Pick one\n ❯ 1. Yes, proceed\n   2. No, exit\n\n Enter to confirm";
    assert_eq!(read(no_question), None, "a menu that asks nothing");
    assert_eq!(read(""), None);
}

/// A click answers with arrow keys from the cursor to the option, then Enter; only while the
/// terminal still shows the dialog the card showed (its id) with that option.
#[test]
fn a_click_types_the_moves_to_its_option_then_enter() {
    let answer = |screen: &str, key: u32, label: &str, id: &str| {
        answer_keys(&ApprovalAnswer {
            screen: screen.to_owned(),
            key,
            label: label.to_owned(),
            id: id.to_owned(),
        })
    };
    let asked = read(CLAUDE_BASH).expect("a dialog").id;
    assert_eq!(answer(CLAUDE_BASH, 1, "Yes", &asked), Some(vec!["enter"]));
    assert_eq!(
        answer(CLAUDE_BASH, 3, "No, and tell Claude what to do differently", &asked),
        Some(vec!["down", "down", "enter"])
    );
    // The person moved the cursor in the terminal: the same dialog, so the same id.
    let moved =
        CLAUDE_BASH.replace(" ❯ 1. Yes", "   1. Yes").replace("   3. No, and", " ❯ 3. No, and");
    assert_eq!(read(&moved).expect("a dialog").id, asked);
    assert_eq!(answer(&moved, 1, "Yes", &asked), Some(vec!["up", "up", "enter"]));
    // Another dialog, another label, or no dialog any more: nothing is typed.
    let edit = read(&CLAUDE_BASH.replace("Bash command", "Edit file")).expect("a dialog").id;
    assert_eq!(answer(CLAUDE_BASH, 1, "Yes", &edit), None);
    assert_eq!(answer(CLAUDE_BASH, 2, "Yes", &asked), None);
    assert_eq!(answer(CLAUDE_BASH, 1, "Yes", ""), None);
    assert_eq!(answer("⏺ Done.\n\n❯ \n", 1, "Yes", &asked), None);
    let codex = read(CODEX_EXEC).expect("a dialog").id;
    assert_eq!(
        answer(CODEX_EXEC, 3, "No, and tell Codex what to do differently", &codex),
        Some(vec!["down", "down", "enter"])
    );
}

/// The same question and options about another command is another dialog: a card that showed
/// `touch` never answers the `rm` that replaced it (queued tool calls, answered in the terminal).
#[test]
fn the_same_question_about_another_command_is_another_dialog() {
    let shown = read(CLAUDE_BASH).expect("a dialog");
    let next = CLAUDE_BASH
        .replace("touch /tmp/w4i-perm", "rm -rf ~/work")
        .replace("touch commands in /private/tmp", "rm commands in ~/work");
    let now = read(&next).expect("a dialog");
    assert_eq!(
        (now.question.as_str(), now.options[0].label.as_str()),
        ("Do you want to proceed?", "Yes")
    );
    assert_ne!(now.id, shown.id);
    let click = ApprovalAnswer { screen: next, key: 1, label: "Yes".to_owned(), id: shown.id };
    assert_eq!(answer_keys(&click), None);
    // A difference past the card's clip still counts.
    let long = |tail: &str| {
        CLAUDE_BASH
            .replace("touch /tmp/w4i-perm", &format!("echo {}{tail}", "x".repeat(DETAIL_CHARS)))
    };
    assert_ne!(read(&long("a")).expect("a dialog").id, read(&long("b")).expect("a dialog").id);
}
