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
    assert_eq!(build_status(SessionStatus::Ready, false, false), "working");
    assert_eq!(build_status(SessionStatus::Idle, true, true), "working");
    assert_eq!(build_status(SessionStatus::Idle, true, false), "done");
    assert_eq!(build_status(SessionStatus::Running, true, false), "working");
    assert_eq!(build_status(SessionStatus::Closed, false, false), "closed");
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
    let made = crate::store::MadeWorktree {
        root: root.clone(),
        pin: crate::cwd_pin::CwdPin::of(&root),
        born: crate::store::MadeWorktree::born_of(&std::fs::File::open(&root).unwrap()),
        branch: "cmux/run-1".to_owned(),
        base: None,
    };
    assert_eq!(still_made(&made), Ok(()));
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
    // Made again after the first went, even where the file system gives it the same inode.
    std::fs::remove_dir_all(&root).unwrap();
    std::fs::remove_dir_all(dir.join("away")).unwrap();
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
    let same_inode =
        crate::store::MadeWorktree { pin: crate::cwd_pin::CwdPin::of(&root), ..made.clone() };
    assert!(still_made(&same_inode).is_err());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Compare reads by path off unix, where no folder identity is recorded, and refuses a folder that
/// is not the one made on unix. Keep's removal refuses it everywhere (`still_made`).
#[test]
fn compare_checks_the_folder_only_where_its_identity_is_recorded() {
    let made = crate::store::MadeWorktree {
        root: std::env::temp_dir().join(format!("acpmux-no-such-run-{}", uuid::Uuid::now_v7())),
        pin: None,
        born: None,
        branch: "cmux/run-1".to_owned(),
        base: None,
    };
    assert!(still_made(&made).is_err());
    assert_eq!(compare_identity(Some(&made)).is_ok(), !cfg!(unix));
    assert_eq!(compare_identity(None), Ok(()));
}
