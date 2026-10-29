use super::*;

#[test]
fn the_first_output_publishes_and_a_burst_publishes_at_most_once_per_interval() {
    let mut activity = ShellActivity::default();
    assert_eq!(activity.last_output(), None);
    assert!(!activity.take_change());

    activity.note_output(10_000);
    assert_eq!(activity.last_output(), Some(10_000));
    assert!(activity.take_change(), "the first output publishes");

    // More output inside the interval is read on demand, not pushed.
    activity.note_output(10_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1);
    assert_eq!(activity.last_output(), Some(10_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1));
    assert!(!activity.take_change());

    activity.note_output(10_000 + OUTPUT_PUBLISH_INTERVAL_MS);
    assert!(activity.take_change(), "output a whole interval later publishes");
    assert!(!activity.take_change());
}

#[test]
fn a_prompt_publish_carries_the_latest_output_and_restarts_the_interval() {
    let mut activity = ShellActivity::default();
    activity.note_output(1_000);
    assert!(activity.take_change());
    activity.note_output(2_000);
    assert!(!activity.take_change());

    // The command ends at a new prompt: that publish names 2_000, so
    // output just after it waits a whole interval from there.
    activity.observe(ShellMark::PromptStart, 2_000);
    assert!(activity.take_change());
    activity.note_output(2_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1);
    assert!(!activity.take_change());
}

#[test]
fn restoring_a_host_state_keeps_the_last_output() {
    let mut previous = ShellActivity::default();
    previous.note_output(7_000);
    assert!(previous.take_change());

    let mut restored = ShellActivity::default();
    restored.restore(previous.snapshot());
    restored.keep_output_of(&previous);
    assert_eq!(restored.last_output(), Some(7_000));
    // The output was already published: no push now, and the next one
    // still waits a whole interval from 7_000.
    assert!(!restored.take_change());
    restored.note_output(7_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1);
    assert!(!restored.take_change());
    restored.note_output(7_000 + OUTPUT_PUBLISH_INTERVAL_MS);
    assert!(restored.take_change());
}

#[test]
fn a_clock_that_steps_back_still_records_the_output() {
    let mut activity = ShellActivity::default();
    activity.note_output(50_000);
    assert!(activity.take_change());
    activity.note_output(40_000);
    assert_eq!(activity.last_output(), Some(40_000));
    assert!(activity.take_change(), "a time before the published one publishes");
}

/// A shell at its prompt, its foreground checked as its own.
fn idle_at(since_ms: u64) -> ShellActivity {
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::PromptStart, since_ms);
    activity.observe(ShellMark::InputStart, since_ms);
    let epoch = activity.foreground_check_due().expect("a prompt asks for a check");
    activity.record_foreground(epoch, true);
    activity
}

#[test]
fn shell_idle_a_prompt_is_idle_only_after_its_foreground_check() {
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::PromptStart, 1_000);
    assert_eq!(activity.prompt_since(), Some(1_000));
    assert_eq!(activity.idle_since(), None, "unchecked is not idle");
    assert!(activity.has_change(), "the due check asks for a publication");
    let epoch = activity.foreground_check_due().unwrap();
    activity.record_foreground(epoch, false);
    assert_eq!(activity.idle_since(), None, "another group holds the terminal");
    assert_eq!(activity.foreground_check_due(), None, "checked once per mark");
    // The next mark asks again.
    activity.observe(ShellMark::InputStart, 1_001);
    let epoch = activity.foreground_check_due().unwrap();
    activity.record_foreground(epoch, true);
    assert_eq!(activity.idle_since(), Some(1_000));
}

#[test]
fn shell_idle_input_ends_idle_until_the_next_prompt() {
    let mut activity = idle_at(1_000);
    assert!(activity.take_change());
    assert!(activity.note_input(b"ls"), "published idle: the input asks for a publication");
    assert_eq!(activity.idle_since(), None);
    assert_eq!(activity.prompt_since(), Some(1_000), "the prompt fact stands");
    assert_eq!(activity.foreground_check_due(), None, "no check while input is pending");
    assert!(activity.take_change());
    assert!(!activity.note_input(b"\r"), "already published not idle");
    // A nested prompt's mark (or the shell's own) clears the input, and
    // its check decides.
    activity.observe(ShellMark::PromptStart, 2_000);
    let epoch = activity.foreground_check_due().unwrap();
    activity.record_foreground(epoch, false);
    assert_eq!(activity.idle_since(), None);
}

/// `prompts` prompt marks, then the check each asks for, with the shell
/// holding the foreground.
fn checked_after(mut activity: ShellActivity, prompts: &[u64]) -> ShellActivity {
    for at in prompts {
        activity.observe(ShellMark::PromptStart, *at);
        if let Some(epoch) = activity.foreground_check_due() {
            activity.record_foreground(epoch, true);
        }
    }
    activity
}

/// Review 3, finding 2: a line typed ahead (written before the shell's
/// `A` for the line before it was parsed) waits unread for the line
/// editor, so that prompt is not idle; the prompt after it is.
#[test]
fn shell_idle_a_line_typed_ahead_keeps_the_next_prompt_not_idle() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"true\r");
    activity.note_input(b"sleep 600\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_101);
    let mut activity = checked_after(activity, &[2_000]);
    assert_eq!(activity.idle_since(), None, "sleep 600 is still unread");
    activity.observe(ShellMark::CommandStart, 2_100);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 2_101);
    let activity = checked_after(activity, &[3_000]);
    assert!(activity.idle_since().is_some(), "both lines answered");
}

/// One write with two lines (a paste without bracketed paste, `send`).
#[test]
fn shell_idle_two_lines_in_one_write_owe_two_prompts() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"true\rsleep 600\r");
    assert_eq!(checked_after(activity, &[2_000]).idle_since(), None);
}

#[test]
fn shell_idle_a_line_typed_before_the_first_prompt_is_owed() {
    let mut activity = ShellActivity::default();
    activity.note_input(b"sleep 600\r");
    let mut activity = checked_after(activity, &[1_000]);
    assert_eq!(activity.idle_since(), None, "the first prompt answers the spawn");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_101);
    assert!(checked_after(activity, &[2_000]).idle_since().is_some());
}

#[test]
fn shell_idle_a_line_typed_while_a_command_runs_is_typed_ahead() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"make\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.note_input(b"sleep 600\r");
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
    let mut activity = checked_after(activity, &[1_300]);
    assert_eq!(activity.idle_since(), None, "sleep 600 waits for the shell");
    activity.observe(ShellMark::CommandStart, 1_310);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_320);
    assert!(checked_after(activity, &[1_400]).idle_since().is_some());
}

/// Review 4, should-fix 2: the daemon cannot tell keys an interactive
/// command read from keys typed after it quit (`:q` then `sleep 600`), so
/// a Return typed into it is owed a prompt for good (fails safe: no kernel
/// fact can pay it, review 6).
#[test]
fn shell_idle_keys_typed_into_an_interactive_command_stay_owed() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"vim\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.note_modes(TerminalModes { exclusive: true, line: false });
    activity.note_input(b"ihello\x1b:wq\r");
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
    let activity = checked_after(activity, &[1_300]);
    assert_eq!(activity.idle_since(), None, "maybe typed after vim quit");
}

#[test]
fn shell_idle_a_partial_line_typed_as_an_interactive_command_quits_blocks_the_check() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"vim\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.note_modes(TerminalModes { exclusive: true, line: false });
    activity.note_input(b":q\rsleep 600");
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
    let activity = checked_after(activity, &[1_300]);
    assert_eq!(activity.foreground_check_due(), None, "`sleep 600` may wait in the editor");
    assert_eq!(activity.idle_since(), None);
}

#[test]
fn shell_idle_ctrl_c_to_a_command_drops_what_was_typed_ahead() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"make\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.note_input(b"sleep 600\r");
    activity.note_input(b"\x03");
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
    let activity = checked_after(activity, &[1_300]);
    assert!(activity.idle_since().is_some(), "the interrupt flushed the input");
}

/// The stopped-job integration test's shell has no `C`: Ctrl-Z is no line.
#[test]
fn shell_idle_ctrl_z_is_not_a_line() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"sleep 600\r");
    activity.note_input(b"\x1a");
    assert!(checked_after(activity, &[2_000]).idle_since().is_some());
}

#[test]
fn shell_idle_a_partial_line_keeps_the_prompt_not_idle() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"ls\rech");
    let activity = checked_after(activity, &[2_000]);
    assert_eq!(activity.idle_since(), None, "`ech` waits in the line editor");
}

#[test]
fn shell_idle_line_breaks_in_a_bracketed_paste_are_not_lines() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"\x1b[200~echo a\necho b\n\x1b[201~");
    activity.note_input(b"\r");
    let activity = checked_after(activity, &[2_000]);
    assert!(activity.idle_since().is_some(), "one Return, one prompt");
}

/// Review 6: a Return no prompt answers (`read`, a password, a continuation
/// line) stays owed for good; a check, whatever it reads, never pays it.
#[test]
fn shell_idle_a_return_no_prompt_answers_stays_owed() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"read x\r");
    activity.note_input(b"hello\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
    let activity = checked_after(activity, &[2_000, 3_000]);
    assert_eq!(activity.idle_since(), None, "`hello` went to read; no prompt answered it");
    assert_eq!(activity.foreground_check(), None, "no check while a line is owed");
}

/// Review 3, finding 3: a record built before any `take_change` (a cwd
/// upsert) can carry the idle fact; input after it still sends its end.
#[test]
fn shell_idle_input_retracts_an_idle_fact_a_record_carried() {
    let mut activity = idle_at(1_000);
    assert!(activity.expose_idle().is_some(), "a record built now says idle");
    assert!(activity.note_input(b"x"), "the input asks for a publication");
    assert!(activity.take_change(), "the publication sends the end of idle");
    let mut activity = idle_at(1_000);
    activity.expose_idle();
    assert!(activity.note_unseen_input());
    assert!(activity.take_change());
    let mut quiet = idle_at(1_000);
    assert!(!quiet.note_input(b"x"), "no record carried idle: nothing to retract");
}

/// Review 4, should-fix 3: a mark that ends idle between a record that
/// carried it (the cwd upsert) and the pass's `take_change`, when no
/// `take_change` had marked that idle fact published.
#[test]
fn shell_idle_a_mark_after_a_record_carried_idle_publishes_its_end() {
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::PromptStart, 1_000);
    let epoch = activity.foreground_check_due().unwrap();
    activity.record_foreground(epoch, false);
    assert!(activity.take_change(), "the prompt goes out, not idle");
    activity.observe(ShellMark::InputStart, 1_001);
    let epoch = activity.foreground_check_due().unwrap();
    activity.record_foreground(epoch, true);
    assert!(activity.expose_idle().is_some(), "the cwd upsert carried idle");
    activity.observe(ShellMark::InputStart, 1_002);
    assert_eq!(activity.idle_since(), None, "a redraw's mark ends it");
    assert!(activity.has_change(), "a publication is due");
    let epoch = activity.foreground_check_due().unwrap();
    activity.record_foreground(epoch, false);
    assert!(activity.take_change(), "its end goes out");
    assert!(!activity.take_change(), "once");
}

/// Review 5, item 1: input written after the prompt's mark and before the
/// check's answer drops that answer; the terminal is not idle until the
/// prompt that answers the line.
#[test]
fn shell_idle_input_between_the_mark_and_the_check_is_never_idle() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"true\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_101);
    activity.observe(ShellMark::PromptStart, 2_000);
    let epoch = activity.foreground_check_due().expect("the prompt asks for a check");
    activity.note_input(b"sleep 600\r");
    activity.record_foreground(epoch, true);
    assert_eq!(activity.idle_since(), None, "the check from before the input is dropped");
    assert_eq!(activity.foreground_check_due(), None, "no check while that line is owed");
    activity.observe(ShellMark::CommandStart, 2_100);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 2_101);
    activity.observe(ShellMark::PromptStart, 3_000);
    let epoch = activity.foreground_check_due().unwrap();
    activity.record_foreground(epoch, true);
    // `C` cleared the prompt fact; the `A` that answered the line set it.
    assert_eq!(activity.idle_since(), Some(3_000), "the prompt after it answered it");
}

/// Review 5, nit: a raw program (ISIG off) reads Ctrl-C as a byte; the
/// kernel flushes nothing typed ahead of it.
#[test]
fn shell_idle_ctrl_c_to_a_raw_program_keeps_what_was_typed_ahead() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"vim\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.note_modes(TerminalModes { exclusive: true, line: false });
    activity.note_input(b":q\rsleep 600\r");
    activity.note_input(b"\x03");
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
    let activity = checked_after(activity, &[1_300]);
    assert_eq!(activity.idle_since(), None, "`sleep 600` may wait for the shell");
}

/// Review 6 of cp/daemon-foreground-state, finding 5: a prompt mark the
/// shell prints again for the same prompt (Ghostty's zsh integration puts
/// `A;redraw=1` in PS1, so `zle reset-prompt`, a resize or a transient
/// prompt at accept print it again) answers no line. After a Return and
/// before the command's `C`, such a redraw must not pay the line.
#[test]
fn shell_idle_a_redrawn_prompt_answers_no_line() {
    // Ghostty's zsh integration: a `D` before each new prompt, `A` in PS1.
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 900);
    activity.observe(ShellMark::PromptStart, 1_000);
    check_at_b(&mut activity, 1_001);
    assert!(activity.idle_since().is_some(), "the first prompt");
    activity.note_input(b"sleep 600\r");
    // reset-prompt (or a transient prompt) prints PS1, so `A`, again.
    activity.observe(ShellMark::PromptStart, 1_100);
    check_at_b(&mut activity, 1_101);
    assert_eq!(activity.foreground_check_due(), None, "`sleep 600` is not answered");
    assert_eq!(activity.idle_since(), None);
    // The new prompt after it comes after its `C` and `D`, and pays.
    activity.observe(ShellMark::CommandStart, 1_200);
    activity.observe(ShellMark::CommandEnd { exit_code: Some(0) }, 1_300);
    activity.observe(ShellMark::PromptStart, 1_400);
    check_at_b(&mut activity, 1_401);
    assert_eq!(activity.idle_since(), Some(1_400));
}

/// A shell that sends only `A` and `B` (no `C` or `D`): its new prompt
/// after a Return is the only mark, and it pays the line.
#[test]
fn shell_idle_an_a_b_only_shell_pays_a_line_at_its_next_prompt() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"true\r");
    activity.observe(ShellMark::PromptStart, 1_100);
    check_at_b(&mut activity, 1_101);
    assert!(activity.idle_since().is_some());
}

/// A reconnect keeps what this daemon saw: a shell that sent `C` or `D`
/// keeps the rule that only an `A` after one pays, so a redraw after a
/// Return still pays nothing.
#[test]
fn shell_idle_a_reconnect_keeps_the_command_mark_rule() {
    let mut previous = ShellActivity::default();
    previous.observe(ShellMark::CommandEnd { exit_code: None }, 900);
    previous.observe(ShellMark::PromptStart, 1_000);
    check_at_b(&mut previous, 1_001);
    previous.note_input(b"sleep 600\r");
    let mut activity = ShellActivity::default();
    activity.restore(previous.snapshot());
    activity.keep_output_of(&previous);
    activity.observe(ShellMark::PromptStart, 2_000);
    check_at_b(&mut activity, 2_001);
    assert_eq!(activity.idle_since(), None, "a redraw: `sleep 600` is not answered");
}

/// Review of cp/fix-tip-continuation-prompt-idle-2, finding 1: several
/// Returns typed while one command runs are several lines typed ahead.
/// Counted as one, the prompt after the first of them reads idle while
/// the next waits unread.
#[test]
fn shell_idle_each_line_typed_while_a_command_runs_is_owed() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"make\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.note_input(b"true\rsleep 600\r");
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
    activity.observe(ShellMark::PromptStart, 1_300);
    assert_eq!(activity.idle_since(), None, "two lines wait");
    activity.observe(ShellMark::CommandStart, 1_400);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_500);
    activity.observe(ShellMark::PromptStart, 1_600);
    assert_eq!(activity.foreground_check_due(), None, "`sleep 600` still waits");
    assert_eq!(activity.idle_since(), None);
}

/// Green 65963f6d at ffc304c871b: a hosted terminal takes its host's
/// state when it is created (`restore` of the host's first snapshot, no
/// marks yet). An `A`/`B`-only shell there: a line typed at the prompt,
/// then its next prompt, must read idle.
#[test]
fn shell_idle_a_fresh_hosted_shell_with_only_a_and_b_pays_its_lines() {
    let mut activity = ShellActivity::default();
    activity.restore(ShellActivitySnapshot::default());
    activity.observe(ShellMark::PromptStart, 1_000);
    check_at_b(&mut activity, 1_001);
    assert!(activity.idle_since().is_some(), "the first prompt");
    activity.note_input(b"echo typed");
    activity.note_input(b"\x15\r");
    activity.observe(ShellMark::PromptStart, 1_100);
    check_at_b(&mut activity, 1_101);
    assert!(activity.idle_since().is_some(), "the prompt after the line");
}

/// Review 7 of cp/daemon-foreground-state, finding 2: a fresh host's first
/// snapshot has no prompt yet, so its shell's first `A` answers the spawn,
/// not a line typed before it.
#[test]
fn shell_idle_a_line_typed_before_a_fresh_hosts_first_prompt_is_owed() {
    let mut activity = ShellActivity::default();
    activity.restore(ShellActivitySnapshot::default());
    activity.note_input(b"sleep 600\r");
    activity.observe(ShellMark::PromptStart, 1_000);
    check_at_b(&mut activity, 1_001);
    assert_eq!(activity.idle_since(), None, "`sleep 600` is not answered");
}

/// Review 2, finding 6: a reconnect without host state checks again.
#[test]
fn shell_idle_a_forgotten_check_is_not_idle_until_checked_again() {
    let mut activity = idle_at(1_000);
    let stale = activity.foreground_check_epoch().unwrap();
    activity.forget_foreground_check();
    assert_eq!(activity.idle_since(), None);
    activity.record_foreground(stale, true);
    assert_eq!(activity.idle_since(), None, "a check from before the reconnect");
    let epoch = activity.foreground_check_due().expect("a new check is due");
    activity.record_foreground(epoch, true);
    assert_eq!(activity.idle_since(), Some(1_000));
}

/// A continuation prompt keeps an unfinished heredoc not idle; the
/// Returns it answered stay owed (no prompt paid them), so the primary
/// prompt after it is not idle either: the accepted cost, the close asks.
#[test]
fn shell_idle_a_secondary_prompt_is_never_idle_and_its_lines_stay_owed() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"cat <<EOF\r");
    activity.observe(ShellMark::SecondaryPromptStart, 1_100);
    assert_eq!(activity.foreground_check_due(), None, "the heredoc is unfinished");
    activity.observe(ShellMark::InputStart, 1_101);
    assert_eq!(activity.foreground_check_due(), None);
    activity.note_input(b"a line\r");
    activity.observe(ShellMark::SecondaryPromptStart, 1_200);
    assert_eq!(activity.idle_since(), None);
    activity.note_input(b"EOF\r");
    activity.observe(ShellMark::PromptStart, 1_300);
    assert_eq!(activity.foreground_check_due(), None, "two Returns no prompt paid");
}

/// kitty marks the second line of a multi-line PS1 `A;k=s`, the same mark
/// as a continuation prompt: such a prompt never reads idle (fails safe;
/// review 4 of cp/fix-tip-continuation-prompt-idle-2 showed no mark tells
/// the two apart for sure).
#[test]
fn shell_idle_a_multi_line_prompt_with_secondary_marks_is_not_idle() {
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::PromptStart, 1_000);
    activity.observe(ShellMark::SecondaryPromptStart, 1_001);
    activity.observe(ShellMark::InputStart, 1_002);
    assert_eq!(activity.foreground_check_due(), None);
    assert_eq!(activity.idle_since(), None);
}

/// The same prompt after a line typed ahead into an open quote: the
/// primary `A` came before the shell read the line, and the `A;k=s` that
/// answers it must keep the unfinished command not idle.
#[test]
fn shell_idle_an_open_quote_typed_ahead_of_its_prompt_is_not_idle() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"true\recho \"x\r");
    activity.observe(ShellMark::PromptStart, 2_000);
    assert_eq!(activity.idle_since(), None, "a line is owed");
    activity.observe(ShellMark::SecondaryPromptStart, 2_001);
    assert_eq!(activity.foreground_check_due(), None, "the quote is open");
    assert_eq!(activity.idle_since(), None);
    // A secondary prompt pays no line (a multi-line PS1's `A;k=s` would
    // otherwise pay one per prompt): after two of three typed-ahead lines
    // ran, the third is still owed.
    let mut activity = idle_at(1_000);
    activity.note_input(b"true\rsleep 1\rsleep 600\r");
    for at in [2_000, 3_000] {
        activity.observe(ShellMark::CommandStart, at - 50);
        activity.observe(ShellMark::CommandEnd { exit_code: None }, at - 40);
        activity.observe(ShellMark::PromptStart, at);
        activity.observe(ShellMark::SecondaryPromptStart, at + 1);
        check_at_b(&mut activity, at + 2);
    }
    assert_eq!(activity.owed_prompts, 1, "`sleep 600` still waits");
    assert_eq!(activity.idle_since(), None);
}

/// The check a `B` asks for, with the shell holding the foreground.
fn check_at_b(activity: &mut ShellActivity, at: u64) {
    activity.observe(ShellMark::InputStart, at);
    if let Some(epoch) = activity.foreground_check_due() {
        activity.record_foreground(epoch, true);
    }
}

/// Review of cp/fix-tip-continuation-prompt-idle-2, sequence A: two lines
/// typed while one command runs, the second an open quote; a single-line
/// PS1 and a kitty PS2 (`A;k=s`). The PS2 is a real continuation prompt
/// and must keep the unfinished command not idle.
#[test]
fn shell_idle_an_open_quote_typed_while_a_command_ran_is_not_idle_at_its_ps2() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"sleep 1\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.note_input(b"sleep 1\recho \"x\r");
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
    activity.observe(ShellMark::PromptStart, 1_300);
    check_at_b(&mut activity, 1_301);
    activity.observe(ShellMark::CommandStart, 1_400);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_500);
    activity.observe(ShellMark::PromptStart, 1_600);
    check_at_b(&mut activity, 1_601);
    activity.observe(ShellMark::SecondaryPromptStart, 1_700);
    check_at_b(&mut activity, 1_701);
    assert_eq!(activity.idle_since(), None, "the quote is open");
}

/// Sequence B: a two-line kitty PS1 (`A`, `A;k=s`, `B`) and three lines
/// in one write, the third an open quote.
#[test]
fn shell_idle_an_open_quote_typed_ahead_of_a_two_line_prompt_is_not_idle_at_its_ps2() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"true\rsleep 1\recho \"x\r");
    for at in [2_000, 3_000] {
        activity.observe(ShellMark::CommandStart, at - 50);
        activity.observe(ShellMark::CommandEnd { exit_code: None }, at - 40);
        activity.observe(ShellMark::PromptStart, at);
        activity.observe(ShellMark::SecondaryPromptStart, at + 1);
        check_at_b(&mut activity, at + 2);
    }
    activity.observe(ShellMark::SecondaryPromptStart, 3_100);
    check_at_b(&mut activity, 3_101);
    assert_eq!(activity.idle_since(), None, "the quote is open");
}

/// A real PS2 (after `B`, no primary `A` before it) with nothing owed
/// (the count can be low) still keeps the shell not idle.
#[test]
fn shell_idle_a_continuation_prompt_with_nothing_owed_is_not_idle() {
    let mut activity = idle_at(1_000);
    check_at_b(&mut activity, 1_001);
    activity.observe(ShellMark::SecondaryPromptStart, 1_100);
    check_at_b(&mut activity, 1_101);
    assert_eq!(activity.idle_since(), None);
}

/// A right prompt (`A;k=r`, after the primary prompt's `B`) pays no line.
#[test]
fn shell_idle_a_right_prompt_pays_no_line() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"true\rsleep 600\r");
    activity.observe(ShellMark::CommandStart, 1_050);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_060);
    activity.observe(ShellMark::PromptStart, 1_100);
    check_at_b(&mut activity, 1_101);
    activity.observe(ShellMark::parse(b"A;k=r").unwrap(), 1_102);
    check_at_b(&mut activity, 1_103);
    assert_eq!(activity.idle_since(), None, "`sleep 600` still waits");
}

/// A right prompt that paid a line would leave the count one low: with
/// three lines typed ahead, the prompt after the second would read idle
/// while the third (`sleep 600`) waits unread.
#[test]
fn shell_idle_a_right_prompt_leaves_the_count_whole() {
    let mut activity = idle_at(1_000);
    activity.note_input(b"true\rsleep 1\rsleep 600\r");
    activity.observe(ShellMark::CommandStart, 1_050);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_060);
    activity.observe(ShellMark::PromptStart, 1_100);
    check_at_b(&mut activity, 1_101);
    activity.observe(ShellMark::parse(b"A;k=r").unwrap(), 1_102);
    check_at_b(&mut activity, 1_103);
    activity.observe(ShellMark::CommandStart, 1_200);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_210);
    activity.observe(ShellMark::PromptStart, 1_300);
    check_at_b(&mut activity, 1_301);
    assert_eq!(activity.idle_since(), None, "`sleep 600` still waits");
}

/// Review 3 of cp/fix-tip-continuation-prompt-idle-2, finding 1: an
/// integration that sends no `B` (kitty-style `A`, `A;k=s`, `C`, `D`).
/// A transient prompt redraws PS1 (`A`) after the Return of an unfinished
/// heredoc, then the PS2 `A;k=s` comes. With no `B`, nothing tells a
/// later line of that PS1 from the PS2: the PS2 must keep it not idle.
#[test]
fn shell_idle_a_continuation_prompt_with_no_b_marks_is_not_idle() {
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::PromptStart, 1_000);
    if let Some(epoch) = activity.foreground_check_due() {
        activity.record_foreground(epoch, true);
    }
    activity.note_input(b"cat <<EOF\r");
    activity.observe(ShellMark::PromptStart, 1_100);
    activity.observe(ShellMark::SecondaryPromptStart, 1_101);
    if let Some(epoch) = activity.foreground_check_due() {
        activity.record_foreground(epoch, true);
    }
    assert_eq!(activity.idle_since(), None, "the heredoc is open");
}

/// Review 4 of cp/fix-tip-continuation-prompt-idle-2, blocker 1: with no
/// `B`, a line typed ahead of an earlier command (`true`, then
/// `cat <<EOF`) is still unread when that command's `C` clears the "line
/// typed" flag; its PS2 after a transient PS1 redraw must not read idle.
#[test]
fn shell_idle_a_heredoc_typed_ahead_with_no_b_marks_is_not_idle() {
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::PromptStart, 1_000);
    activity.note_input(b"sleep 1\r");
    activity.observe(ShellMark::PromptStart, 1_050);
    activity.observe(ShellMark::CommandStart, 1_100);
    activity.note_input(b"true\rcat <<EOF\r");
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_200);
    activity.observe(ShellMark::PromptStart, 1_300);
    activity.observe(ShellMark::PromptStart, 1_310);
    activity.observe(ShellMark::CommandStart, 1_400);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 1_500);
    activity.observe(ShellMark::PromptStart, 1_600);
    activity.observe(ShellMark::PromptStart, 1_610);
    activity.observe(ShellMark::SecondaryPromptStart, 1_620);
    if let Some(epoch) = activity.foreground_check_due() {
        activity.record_foreground(epoch, true);
    }
    assert_eq!(activity.idle_since(), None, "the heredoc is open");
}

/// Blocker 2: a `B` from a nested shell (ssh to a host whose integration
/// sends `B`) must not make a local shell that sends no `B` read its PS2
/// as a line of its prompt.
#[test]
fn shell_idle_a_nested_shells_b_does_not_vouch_for_the_local_prompt() {
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::PromptStart, 1_000);
    activity.note_input(b"ssh host\r");
    activity.observe(ShellMark::CommandStart, 1_100);
    // The remote shell's prompt marks, then `exit`.
    activity.observe(ShellMark::PromptStart, 1_200);
    activity.observe(ShellMark::InputStart, 1_201);
    activity.observe(ShellMark::CommandEnd { exit_code: Some(0) }, 1_300);
    activity.observe(ShellMark::PromptStart, 1_400);
    activity.note_input(b"cat <<EOF\r");
    activity.observe(ShellMark::PromptStart, 1_500);
    activity.observe(ShellMark::SecondaryPromptStart, 1_510);
    if let Some(epoch) = activity.foreground_check_due() {
        activity.record_foreground(epoch, true);
    }
    assert_eq!(activity.idle_since(), None, "the heredoc is open");
}

#[test]
fn shell_idle_a_check_that_raced_a_mark_or_input_is_dropped() {
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::PromptStart, 1_000);
    let stale = activity.foreground_check_due().unwrap();
    activity.observe(ShellMark::InputStart, 1_001);
    activity.record_foreground(stale, true);
    assert_eq!(activity.idle_since(), None, "a check from before the mark");
    let stale = activity.foreground_check_due().unwrap();
    activity.note_input(b"x");
    activity.record_foreground(stale, true);
    assert_eq!(activity.idle_since(), None, "a check from before the input");
}

#[test]
fn shell_idle_each_publication_checks_a_published_idle_again() {
    let mut activity = idle_at(1_000);
    assert!(activity.take_change());
    assert_eq!(activity.foreground_check_due(), None, "the mark's check ran");
    // A later publication (output, a directory change) checks again: a
    // job took the terminal with no mark or input the daemon saw.
    let epoch = activity.foreground_check_epoch().expect("an idle fact is checked again");
    activity.record_foreground(epoch, false);
    assert_eq!(activity.idle_since(), None);
    assert!(activity.take_change(), "the publication drops the idle fact");
    assert_eq!(activity.foreground_check_epoch(), None, "nothing to check while not idle");
}

#[test]
fn shell_idle_unseen_input_ends_idle_for_good() {
    let mut activity = idle_at(1_000);
    assert!(activity.take_change());
    assert!(activity.note_unseen_input(), "published idle: asks for a publication");
    assert_eq!(activity.idle_since(), None);
    activity.observe(ShellMark::PromptStart, 2_000);
    assert_eq!(activity.foreground_check_due(), None, "no new prompt makes it idle again");
    assert_eq!(activity.idle_since(), None);
    // A reconnect inside this daemon keeps it.
    let mut reconnected = ShellActivity::default();
    reconnected.restore(activity.snapshot());
    reconnected.keep_output_of(&activity);
    reconnected.observe(ShellMark::PromptStart, 3_000);
    assert_eq!(reconnected.foreground_check_due(), None);
}

#[test]
fn shell_idle_a_replayed_prompt_is_not_idle_until_a_new_one() {
    let mut activity = ShellActivity::default();
    // A ring replay ends at an old prompt; input after it is unknown.
    activity.observe(ShellMark::PromptStart, 1_000);
    activity.note_replayed_output();
    assert_eq!(activity.prompt_since(), Some(1_000));
    assert_eq!(activity.foreground_check_due(), None);
    assert_eq!(activity.idle_since(), None);
    // The shell's next prompt, after the replay.
    activity.observe(ShellMark::PromptStart, 2_000);
    let epoch = activity.foreground_check_due().expect("a live prompt asks for a check");
    activity.record_foreground(epoch, true);
    assert!(activity.idle_since().is_some());
}

#[test]
fn shell_idle_spawned_shell_is_an_interactive_shell_only() {
    assert!(spawned_shell(&["/bin/zsh".into()]));
    assert!(spawned_shell(&["-bash".into()]));
    assert!(spawned_shell(&["bash".into(), "--posix".into()]), "the integrated bash");
    let rcfile = ["/bin/bash", "--noprofile", "--rcfile", "/tmp/rc", "-i"];
    assert!(spawned_shell(&rcfile.map(String::from)));
    assert!(!spawned_shell(&["ssh".into(), "host".into()]), "a terminal that runs ssh");
    let docker = ["docker", "exec", "-it", "c", "bash"];
    assert!(!spawned_shell(&docker.map(String::from)));
    assert!(!spawned_shell(&["bash".into(), "-c".into(), "a; b".into()]));
    assert!(!spawned_shell(&["bash".into(), "-lc".into(), "a".into()]));
    assert!(!spawned_shell(&["fish".into(), "--command".into(), "a".into()]));
    assert!(!spawned_shell(&["fish".into(), "--command=a".into()]), "review 3: --command=");
    assert!(!spawned_shell(&["elvish".into(), "--execute=a".into()]));
    assert!(!spawned_shell(&["bash".into(), "script.sh".into()]), "a script");
    assert!(!spawned_shell(&[]));
}

#[test]
fn shell_idle_a_running_command_is_never_idle() {
    let mut activity = idle_at(1_000);
    activity.observe(ShellMark::CommandStart, 1_500);
    assert_eq!(activity.idle_since(), None);
    assert_eq!(activity.foreground_check_due(), None);
}

#[test]
fn shell_idle_a_host_state_is_not_idle_until_its_next_prompt() {
    let previous = idle_at(1_000);
    let mut restored = ShellActivity::default();
    restored.restore(previous.snapshot());
    assert_eq!(restored.prompt_since(), Some(1_000));
    assert_eq!(restored.idle_since(), None, "input written before the adoption is unknown");
    assert_eq!(restored.foreground_check_due(), None);
    // A reconnect inside this daemon keeps what it knows about input.
    let mut reconnected = ShellActivity::default();
    reconnected.restore(previous.snapshot());
    reconnected.keep_output_of(&previous);
    assert!(reconnected.foreground_check_due().is_some(), "checked again, then idle");
}

#[test]
fn shell_idle_same_program_matches_the_spawned_file_name_only() {
    assert!(same_program("/bin/bash", "/bin/bash"));
    assert!(same_program("-bash", "/usr/bin/bash"));
    assert!(same_program("/bin/zsh", "zsh"));
    assert!(!same_program("bash --rcfile x", "/bin/bash"), "an argv, not an image: never trusted");
    assert!(!same_program("/bin/dash", "/bin/bash"), "an exec'd shell");
    assert!(!same_program("ssh", "/bin/zsh"));
    assert!(!same_program("/bin/bash", ""));
}

#[test]
fn last_output_json_names_the_time_as_a_decimal_string() {
    assert_eq!(last_output_json(1_792_000_000_123), json!({"at_ms": "1792000000123"}));
}
