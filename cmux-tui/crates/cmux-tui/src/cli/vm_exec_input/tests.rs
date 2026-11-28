use super::*;
use std::process::{Command, Stdio};

fn words(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

/// The machine's side, here: each staging step, then the command, in `sh -c`, as the Cloud
/// API's exec runs them. The command's stdout.
fn run_plan(plan: &InputPlan) -> Vec<u8> {
    for step in &plan.stage {
        let status = Command::new("sh").arg("-c").arg(step).status().expect("sh");
        assert!(status.success(), "staging step failed: {step}");
    }
    let out =
        Command::new("sh").arg("-c").arg(&plan.command).stdin(Stdio::null()).output().expect("sh");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    out.stdout
}

#[test]
fn several_words_keep_their_argv_one_word_is_a_shell_line() {
    assert_eq!(join_command(&words(&["uname", "-a"])), "uname -a");
    assert_eq!(join_command(&words(&["sh", "-c", "cat > f"])), "sh -c 'cat > f'");
    assert_eq!(join_command(&words(&["echo", "it's", "$HOME"])), r#"echo 'it'\''s' '$HOME'"#);
    assert_eq!(join_command(&words(&["printf", "%s\n", ""])), "printf '%s\n' ''");
    assert_eq!(join_command(&words(&["ls | wc -l"])), "ls | wc -l");
    // The machine's shell gets back the words as typed.
    let typed = words(&["printf", "[%s]", "a b", "it's", "$HOME", "", "*"]);
    let out = Command::new("sh").arg("-c").arg(join_command(&typed)).output().unwrap();
    assert_eq!(String::from_utf8(out.stdout).unwrap(), "[a b][it's][$HOME][][*]");
}

#[test]
fn small_stdin_rides_in_the_command() {
    let input = b"line one\n'quoted' \"double\" $HOME `tick`\n\0binary\xff";
    let plan = plan("cat", input, "/unused", CHUNK_BASE64);
    assert!(plan.stage.is_empty() && plan.cleanup.is_none(), "{plan:?}");
    assert_eq!(run_plan(&plan), input);
    // A trailing comment in the command does not eat the closing paren.
    let commented = super::plan("cat # the rest", b"ok", "/unused", CHUNK_BASE64);
    assert_eq!(run_plan(&commented), b"ok");
}

#[test]
fn large_stdin_is_staged_in_chunks_and_removed() {
    let dir = std::env::temp_dir().join(format!("vm-exec-input-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let scratch = dir.join("stage file").display().to_string();
    let input: Vec<u8> = (0..10_000u32).map(|n| (n * 7 % 256) as u8).collect();
    // A tiny chunk (not a multiple of 4 either), so the input takes many steps.
    let plan = plan("wc -c; exit 3", &input, &scratch, 1001);
    assert!(plan.stage.len() > 10, "{}", plan.stage.len());
    for step in &plan.stage {
        Command::new("sh").arg("-c").arg(step).status().unwrap();
    }
    let out = Command::new("sh").arg("-c").arg(&plan.command).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "10000");
    assert_eq!(out.status.code(), Some(3), "the command's own exit code");
    assert!(!std::path::Path::new(&scratch).exists(), "the scratch file is removed");

    let copy = dir.join("copy").display().to_string();
    let cat = super::plan(
        &join_command(&words(&["sh", "-c", &format!("cat > '{copy}'")])),
        &input,
        &scratch,
        1001,
    );
    run_plan(&cat);
    assert_eq!(std::fs::read(&copy).unwrap(), input, "the bytes arrive as sent");
    assert_eq!(cat.cleanup, Some(format!("rm -f {}", shell_quote(&scratch))));
    std::fs::remove_dir_all(&dir).unwrap();
}
