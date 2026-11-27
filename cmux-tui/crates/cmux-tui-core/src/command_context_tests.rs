use super::*;

fn context(command: Option<&str>, exit_code: Option<i32>, output: &str) -> CommandContext {
    CommandContext::new(
        ghostty_vt::CommandOutput {
            command: command.map(str::to_owned),
            output: output.to_owned(),
            truncated: false,
        },
        exit_code,
        Some("/work/app".to_owned()),
    )
}

#[test]
fn fix_text_asks_for_a_fix_with_the_status_command_and_output() {
    let failed = context(Some("cargo test"), Some(101), "error: could not compile");
    assert_eq!(
        failed.chat_text(Intent::Fix),
        "This command failed (exit code 101). Find the cause and fix it.\n\n\
             ```console\n/work/app $ cargo test\nerror: could not compile\n```\n\n"
    );
}

#[test]
fn context_text_names_a_failure_and_is_only_the_transcript_on_success() {
    let ok = context(Some("ls"), Some(0), "a\nb");
    assert_eq!(ok.chat_text(Intent::Context), "```console\n/work/app $ ls\na\nb\n```\n\n");
    let failed = context(Some("make"), Some(2), "boom");
    assert!(
        failed.chat_text(Intent::Context).starts_with("This command exited (exit code 2).\n\n")
    );
}

#[test]
fn a_fence_outlasts_backticks_in_the_output() {
    let text =
        context(Some("cat x.md"), None, "```rust\nfn main() {}\n```").chat_text(Intent::Context);
    assert!(text.starts_with("````console\n"), "{text}");
    assert!(text.ends_with("\n````\n\n"), "{text}");
}

#[test]
fn long_output_keeps_the_newest_bytes_from_a_line_start() {
    let output: String = (0..5_000).map(|n| format!("line {n}\n")).collect();
    let kept = context(Some("seq"), Some(1), &output);
    assert!(kept.truncated);
    assert!(kept.output.len() <= MAX_OUTPUT_BYTES);
    assert!(kept.output.starts_with("line "), "{}", &kept.output[..20]);
    assert!(kept.output.ends_with("line 4999\n"));
    assert!(kept.chat_text(Intent::Fix).contains("/work/app $ seq\n…\nline "));
}

#[test]
fn a_command_line_is_stored_clean_and_a_hidden_one_is_dropped() {
    assert_eq!(context(Some("  secret"), Some(1), "").command, None);
    assert_eq!(context(Some("ls\u{7}"), Some(1), "").command.as_deref(), Some("ls"));
}
