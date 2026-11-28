use super::*;
use serde_json::json;

#[test]
fn it_is_off_unless_the_setting_is_true_and_the_kill_switch_wins() {
    let on = json!({"agents": {"harnessMagic": {"freshReview": {"enabled": true}}}});
    let off = json!({"agents": {"harnessMagic": {"freshReview": {"enabled": false}}}});
    assert!(!enabled_with(None, None));
    assert!(!enabled_with(Some(&json!({})), None));
    assert!(!enabled_with(Some(&off), None));
    assert!(enabled_with(Some(&on), None));
    assert!(enabled_with(Some(&on), Some("1")));
    assert!(!enabled_with(Some(&on), Some("0")));
    assert!(!enabled_with(Some(&on), Some(" OFF ")));
}

#[test]
fn the_reviewer_is_claude_print_unless_the_setting_names_an_argv() {
    assert_eq!(command_with(None)[..2], ["claude".to_owned(), "-p".to_owned()]);
    let named =
        json!({"agents": {"harnessMagic": {"freshReview": {"command": ["codex", "exec", "-"]}}}});
    assert_eq!(command_with(Some(&named)), ["codex", "exec", "-"]);
    let empty = json!({"agents": {"harnessMagic": {"freshReview": {"command": []}}}});
    assert_eq!(command_with(Some(&empty))[0], "claude");
    let blank = json!({"agents": {"harnessMagic": {"freshReview": {"command": [" "]}}}});
    assert_eq!(command_with(Some(&blank))[0], "claude");
}

#[test]
fn the_brief_carries_the_ask_and_the_diff_capped_and_nothing_else() {
    let b = brief("  fix the login bug  ", "+let x = 1;\n");
    assert!(b.contains("## What was asked\nfix the login bug\n"));
    assert!(b.contains("```diff\n+let x = 1;\n"));
    assert!(b.contains(CLEAN));
    let big = "x".repeat(MAX_DIFF_CHARS + 10);
    let b = brief("ask", &big);
    assert!(b.contains(&format!("[... cut at {MAX_DIFF_CHARS} characters]")));
    assert!(b.len() < MAX_DIFF_CHARS + 2_000);
}

#[test]
fn cap_cuts_on_a_character_boundary() {
    assert_eq!(cap("héllo", 10), "héllo");
    assert!(cap("ééééé", 2).starts_with("éé\n[... cut at 2"));
}

#[test]
fn blocking_lines_are_the_findings_and_a_clean_answer_is_none_found() {
    let out = "BLOCKING: src/a.rs:3 unwrap on user input panics\n\
               - **BLOCKING:** src/c.rs:5 bolded marker\n\
               **BLOCKING**: `src/d.rs:7 bold before the colon`\n\
               * blocking: src/b.rs:9 the ask's second half is not done\n\
               BLOCKINGLY: not a marker\n\
               some chatter\n";
    let f = findings(out).unwrap();
    assert_eq!(
        f,
        [
            "src/a.rs:3 unwrap on user input panics",
            "src/c.rs:5 bolded marker",
            "src/d.rs:7 bold before the colon",
            "src/b.rs:9 the ask's second half is not done",
        ]
    );
    assert_eq!(findings("NO BLOCKING FINDINGS\n"), Some(vec![]));
    assert_eq!(findings("`No blocking findings.`"), Some(vec![]));
    assert_eq!(findings("Looks good to me!"), None);
    assert_eq!(findings("BLOCKING:   \n"), None);
}

#[test]
fn findings_are_bounded_in_count_and_length() {
    let out: String = (0..20).map(|i| format!("BLOCKING: f{i} {}\n", "y".repeat(1_000))).collect();
    let f = findings(&out).unwrap();
    assert_eq!(f.len(), MAX_FINDINGS);
    assert!(f.iter().all(|x| x.chars().count() < 450));
}

#[test]
fn the_steer_lists_each_finding() {
    let t = steer_text(&["a.rs:1 bad".into(), "b.rs:2 worse".into()]);
    assert!(t.contains("- a.rs:1 bad\n- b.rs:2 worse\n"));
}

#[cfg(unix)]
#[test]
fn the_reviewer_reads_the_brief_on_stdin_and_a_slow_one_is_killed() {
    let dir = tempfile::tempdir().unwrap();
    let argv: Vec<String> = ["sh", "-c", "cat; echo; echo NO BLOCKING FINDINGS"]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    let ran = run_blocking(dir.path(), &argv, "the brief", Duration::from_secs(10)).unwrap();
    assert!(ran.ok && !ran.slow);
    assert!(ran.text.starts_with("the brief"));
    assert_eq!(findings(&ran.text), Some(vec![]));
    let slow: Vec<String> = ["sh", "-c", "sleep 30"].iter().map(|s| (*s).to_owned()).collect();
    let t = Instant::now();
    let ran = run_blocking(dir.path(), &slow, "", Duration::from_millis(300)).unwrap();
    assert!(ran.slow && !ran.ok);
    assert!(t.elapsed() < Duration::from_secs(10));
}

#[cfg(unix)]
#[test]
fn a_diff_against_the_base_takes_commits_and_uncommitted_edits() {
    let dir = tempfile::tempdir().unwrap();
    let sh = |script: &str| {
        let argv: Vec<String> = ["sh", "-c", script].iter().map(|s| (*s).to_owned()).collect();
        run_blocking(dir.path(), &argv, "", Duration::from_secs(20)).unwrap()
    };
    let init = sh(
        "git init -q . && git -c user.email=a@b -c user.name=a commit -q --allow-empty -m base && git rev-parse HEAD",
    );
    assert!(init.ok, "{}", init.text);
    let base = init.text.trim().to_owned();
    sh(
        "echo one > a.txt && git add a.txt && git -c user.email=a@b -c user.name=a commit -q -m one && echo two > b.txt && git add b.txt",
    );
    let diff =
        run_blocking(dir.path(), &git(&["diff", "--no-color", &base]), "", GIT_BOUND).unwrap();
    assert!(diff.ok);
    assert!(diff.text.contains("+one") && diff.text.contains("+two"), "{}", diff.text);
}
