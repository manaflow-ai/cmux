use super::*;

fn ask(tool: Value) -> Value {
    json!({"sessionId": "s", "toolCall": tool, "options": [
        {"optionId": "yes", "name": "Yes", "kind": "allow_once"},
        {"optionId": "no", "name": "No", "kind": "reject_once"},
    ]})
}

#[test]
fn the_plan_is_read_as_the_card_reads_it() {
    let exit_plan = ask(json!({"kind": "switch_mode", "rawInput": {"plan": "  Step one  "},
        "_meta": {"claude": {"tool": "ExitPlanMode"}}}));
    assert_eq!(plan_of(&exit_plan).as_deref(), Some("Step one"));
    let attached =
        ask(json!({"kind": "other", "_meta": {"acpmux": {"plan": {"markdown": "From file"}}}}));
    assert_eq!(plan_of(&attached).as_deref(), Some("From file"));
    let from_text = ask(json!({"kind": "switch_mode", "content": [
        {"type": "content", "content": {"type": "text", "text": "A"}},
        {"type": "diff", "path": "x"},
        {"type": "content", "content": {"type": "text", "text": " B "}},
    ]}));
    assert_eq!(plan_of(&from_text).as_deref(), Some("A\n\nB"));
    let command = ask(json!({"kind": "execute", "rawInput": {"plan": "not a plan ask"}}));
    assert_eq!(plan_of(&command), None);
    let empty = ask(json!({"kind": "switch_mode", "rawInput": {"plan": "  "}}));
    assert_eq!(plan_of(&empty), None);
}

#[test]
fn options_and_harnesses() {
    let a = ask(json!({}));
    assert_eq!(option_of(&a, "allow_once").as_deref(), Some("yes"));
    assert_eq!(option_of(&a, "reject_once").as_deref(), Some("no"));
    assert_eq!(option_of(&a, "allow_always"), None);
    assert_eq!(compare_harnesses("claude"), ["claude", "codex"]);
    assert_eq!(compare_harnesses("claude-work"), ["claude-work", "codex"]);
    assert_eq!(compare_harnesses("codex"), ["codex", "claude"]);
    assert_eq!(Target::parse("compare"), Some(Target::Compare));
    assert_eq!(Target::parse("cloud"), None);
}

#[test]
fn the_build_prompt_carries_the_plan() {
    let one = build_prompt("1. Do it", "shop", Target::Worktree);
    assert!(one.ends_with("\n\n1. Do it") && one.contains("\"shop\""), "{one}");
    assert!(!one.contains("Another agent"));
    assert!(build_prompt("p", "shop", Target::Compare).contains("Another agent"));
}

#[test]
fn a_build_is_done_only_once_a_turn_ended_and_none_waits() {
    assert_eq!(build_status(SessionStatus::Ready, None, false), "working");
    assert_eq!(build_status(SessionStatus::Idle, Some("completed"), true), "working");
    assert_eq!(build_status(SessionStatus::Idle, Some("completed"), false), "done");
    assert_eq!(build_status(SessionStatus::Running, Some("completed"), false), "working");
    assert_eq!(build_status(SessionStatus::Closed, None, false), "closed");
    // A build whose turn failed or was stopped, its agent ready again, is not done.
    assert_eq!(build_status(SessionStatus::Ready, Some("failed"), false), "failed");
    assert_eq!(build_status(SessionStatus::Ready, Some(""), false), "failed");
    assert_eq!(build_status(SessionStatus::Idle, Some("cancelled"), false), "closed");
}

#[test]
fn numstat_counts_and_caps_the_list() {
    let mut change = Change::default();
    parse_numstat("3\t1\tsrc/a.rs\n-\t-\tlogo.png\nbroken line\n", &mut change);
    assert_eq!((change.added, change.removed), (3, 1));
    assert_eq!(change.files, vec![("src/a.rs".into(), 3, 1), ("logo.png".into(), 0, 0)]);
    let mut many = Change::default();
    for i in 0..(MAX_FILES + 5) {
        many.push(format!("f{i}"), 1, 0);
    }
    assert_eq!((many.files.len(), many.more, many.added), (MAX_FILES, 5, (MAX_FILES + 5) as u64));
}

#[test]
fn a_prompt_run_is_sent_as_typed_and_named_by_its_variant() {
    assert_eq!(build_prompt("Fix the login", "shop", Target::Prompt), "Fix the login");
    assert_eq!(Target::parse("prompt"), Some(Target::Prompt));
    let opus = Variant {
        harness: "claude".into(),
        model: Some("opus".into()),
        effort: Some("high".into()),
    };
    assert_eq!(opus.chat_name(Target::Prompt), "run-claude-opus");
    assert_eq!(Variant::harness("codex").chat_name(Target::Prompt), "run-codex");
    assert_eq!(Variant::harness("codex").chat_name(Target::Compare), "build-codex");
    assert_eq!(Variant::harness("codex").chat_name(Target::Worktree), "build-plan");
}

#[cfg(unix)]
#[test]
fn a_worktree_is_still_made_only_with_its_folder_and_branch() {
    let dir = std::env::temp_dir().join(format!("acpmux-still-made-{}", uuid::Uuid::now_v7()));
    let (root, admin) = (dir.join("wt"), dir.join("repo/.git/worktrees/wt"));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&admin).unwrap();
    std::fs::write(root.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
    std::fs::write(admin.join("HEAD"), "ref: refs/heads/cmux/run-1\n").unwrap();
    std::fs::write(admin.join(crate::subsession_worktree::MADE_STAMP), "0f1e2d").unwrap();
    let made = crate::store::MadeWorktree {
        root: root.clone(),
        pin: crate::cwd_pin::CwdPin::of(&root),
        born: crate::store::MadeWorktree::born_of(&std::fs::File::open(&root).unwrap()),
        branch: "cmux/run-1".to_owned(),
        base: None,
        stamp: Some("0f1e2d".to_owned()),
    };
    assert_eq!(still_made(&made), Ok(()));
    // Another stamp in its registration: not the worktree made.
    let other = crate::store::MadeWorktree { stamp: Some("abcdef".to_owned()), ..made.clone() };
    assert!(still_made(&other).is_err());
    // Where the file system records no creation time, the stamp alone decides.
    let no_time = crate::store::MadeWorktree { born: None, ..made.clone() };
    assert_eq!(still_made(&no_time), Ok(()));
    assert!(still_made(&crate::store::MadeWorktree { born: None, ..other.clone() }).is_err());
    // With neither, nothing tells it from a worktree made again at its path: it stays.
    let neither = crate::store::MadeWorktree { stamp: None, ..no_time.clone() };
    assert!(still_made(&neither).unwrap_err().contains("nothing recorded"));
    // An agent's FIFO in the stamp's place never hangs the check, and is no stamp.
    let stamp_file = admin.join(crate::subsession_worktree::MADE_STAMP);
    std::fs::remove_file(&stamp_file).unwrap();
    let c = std::ffi::CString::new(stamp_file.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    let started = std::time::Instant::now();
    assert!(still_made(&made).is_err());
    assert!(started.elapsed() < std::time::Duration::from_secs(2), "a FIFO blocked the check");
    std::fs::remove_file(&stamp_file).unwrap();
    std::fs::write(&stamp_file, "0f1e2d").unwrap();
    // Its agent moved it to another branch: no longer the worktree made for the run.
    std::fs::write(admin.join("HEAD"), "ref: refs/heads/main\n").unwrap();
    assert!(still_made(&made).is_err());
    std::fs::write(admin.join("HEAD"), "ref: refs/heads/cmux/run-1\n").unwrap();
    // No identity recorded: nothing proves the folder is the one made.
    assert!(still_made(&crate::store::MadeWorktree { pin: None, ..made.clone() }).is_err());
    // Another folder at its path, with the same git files: not the one made.
    std::fs::rename(&root, dir.join("away")).unwrap();
    std::fs::create_dir_all(&root).unwrap();
    std::fs::copy(dir.join("away/.git"), root.join(".git")).unwrap();
    assert!(still_made(&made).is_err());
    // Removed and made again at its path, registered again under the same name, where the file
    // system gives the new folder the same inode and records no creation time (Linux CI's): its
    // registration has no stamp, so it is not the one made either.
    std::fs::remove_dir_all(&root).unwrap();
    std::fs::remove_dir_all(dir.join("away")).unwrap();
    std::fs::remove_dir_all(&admin).unwrap();
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&admin).unwrap();
    std::fs::write(root.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
    std::fs::write(admin.join("HEAD"), "ref: refs/heads/cmux/run-1\n").unwrap();
    let same_inode = crate::store::MadeWorktree {
        pin: crate::cwd_pin::CwdPin::of(&root),
        born: None,
        ..made.clone()
    };
    assert!(still_made(&same_inode).is_err());
    // A record from before stamps were written, with no creation time either, is refused too.
    let unstamped = crate::store::MadeWorktree { stamp: None, ..same_inode.clone() };
    assert!(still_made(&unstamped).is_err());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_plan_only_in_the_acp_subject_is_read_too() {
    let ask = json!({"sessionId": "s", "subject": {"type": "tool_call", "toolCall": {
        "kind": "switch_mode", "rawInput": {"plan": "Step one"}}}});
    assert_eq!(plan_of(&ask).as_deref(), Some("Step one"));
    let command = json!({"sessionId": "s", "subject": {"type": "command", "toolCall": {
        "kind": "switch_mode", "rawInput": {"plan": "Step one"}}}});
    assert_eq!(plan_of(&command), None, "only a tool call subject");
}

#[test]
fn one_build_call_holds_an_approval_at_a_time() {
    let first = claim("s-claim", "p1").expect("the first call holds it");
    let second = claim("s-claim", "p1").expect_err("a second call is refused");
    assert_eq!(
        second.data.as_ref().and_then(|d| d.get("reason")),
        Some(&json!("plan_build.in_progress"))
    );
    assert!(claim("s-claim", "p2").is_ok(), "another approval is free");
    drop(first);
    assert!(claim("s-claim", "p1").is_ok(), "released when the call ends");
}
