use super::*;
use serde_json::json;

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const C: &str = "cccccccccccccccccccccccccccccccccccccccc";

fn call(key: &str, id: &str, kind: &str, command: Option<&str>) {
    let mut update =
        json!({"sessionUpdate": "tool_call", "toolCallId": id, "kind": kind, "title": kind});
    if let Some(c) = command {
        update["rawInput"] = json!({"command": c});
    }
    note_tool(key, &update);
}

fn reads(key: &str, n: usize) {
    for i in 0..n {
        call(key, &format!("r{i}"), "read", None);
    }
}

fn end(key: &str, head: &str, draft: &str, pushed: Option<bool>) -> (Vec<Fired>, Value) {
    let mut msg = json!({});
    let e = End {
        completed: true,
        head: Some(head),
        branch: Some("lane/x"),
        initial_head: Some(A),
        head_pushed: pushed,
        draft,
    };
    let fired = end_with(key, &e, &mut msg);
    (fired, msg)
}

fn rules(fired: &[Fired]) -> Vec<&'static str> {
    fired.iter().map(|f| f.rule).collect()
}

#[test]
fn three_read_only_turns_spin_once_until_a_change() {
    let k = "sc-spin";
    for turn in 1..=SPIN_TURNS {
        reads(k, SPIN_MIN_TOOLS as usize);
        let (fired, msg) = end(k, A, "looking", None);
        assert_eq!(msg["harnessMagic"]["sidecars"]["observed"], 1);
        assert_eq!(rules(&fired), if turn == SPIN_TURNS { vec!["spin"] } else { vec![] });
    }
    // Said once, at the next prompt, and counted on that turn's result.
    let said = start_with(k).unwrap();
    assert!(said.starts_with("[sidecar spin] Your last 3 turns ran 12 tool calls"), "{said}");
    assert_eq!(start_with(k), None);
    // A fourth spinning turn says nothing again.
    reads(k, SPIN_MIN_TOOLS as usize);
    let (fired, msg) = end(k, A, "", None);
    assert!(fired.is_empty());
    assert_eq!(msg["harnessMagic"]["sidecars"]["said"], 1);
    // An edit resets it: three more read-only turns fire again.
    call(k, "e", "edit", None);
    assert!(end(k, A, "", None).0.is_empty());
    for _ in 1..SPIN_TURNS {
        reads(k, SPIN_MIN_TOOLS as usize);
        assert!(end(k, A, "", None).0.is_empty());
    }
    reads(k, SPIN_MIN_TOOLS as usize);
    assert_eq!(rules(&end(k, A, "", None).0), vec!["spin"]);
}

#[test]
fn a_moved_head_a_writing_command_or_a_short_turn_is_no_spin() {
    let k = "sc-nospin";
    // A commit between turns is a change.
    for head in [A, B, C] {
        reads(k, 5);
        assert!(end(k, head, "", None).0.is_empty());
    }
    // A command the allowlist does not pass may write.
    for _ in 0..SPIN_TURNS {
        reads(k, 4);
        call(k, "w", "execute", Some("cargo test -p acpmux"));
        assert!(end(k, C, "", None).0.is_empty());
    }
    // Short turns neither count nor break: two long turns, a short one, then a third long one.
    let k = "sc-short";
    for (n, fires) in [(5, false), (5, false), (1, false), (5, true)] {
        reads(k, n);
        assert_eq!(!end(k, A, "", None).0.is_empty(), fires, "{n}");
    }
}

#[test]
fn a_read_only_command_reads_and_a_command_that_arrives_late_is_classified() {
    let k = "sc-late";
    let mut last = Vec::new();
    for _ in 0..SPIN_TURNS {
        call(k, "g", "execute", Some("git status"));
        call(k, "rg", "execute", Some("rg foo src"));
        note_tool(
            k,
            &json!({"sessionUpdate": "tool_call", "toolCallId": "late", "kind": "execute"}),
        );
        note_tool(
            k,
            &json!({"sessionUpdate": "tool_call_update", "toolCallId": "late",
                "rawInput": {"command": "ls -la"}}),
        );
        call(k, "s", "search", None);
        last = end(k, A, "", None).0;
    }
    assert_eq!(rules(&last), vec!["spin"]);
}

#[test]
fn done_on_an_unpushed_commit_steers_once_per_head() {
    let k = "sc-unpushed";
    call(k, "e", "edit", None);
    let (fired, msg) = end(k, B, "All done: the fix is in.", Some(false));
    assert_eq!(rules(&fired), vec!["unpushed"]);
    assert_eq!(msg["harnessMagic"]["sidecars"]["unpushedFired"], 1);
    assert!(fired[0].text.contains("commit bbbbbbbbbbbb"), "{}", fired[0].text);
    assert!(start_with(k).unwrap().starts_with("[sidecar unpushed] "));
    // The same HEAD again: said already.
    assert!(end(k, B, "Done.", Some(false)).0.is_empty());
    // A new commit, still unpushed: once more.
    assert_eq!(rules(&end(k, C, "Done.", Some(false)).0), vec!["unpushed"]);
}

#[test]
fn no_unpushed_steer_when_pushed_unclaimed_unchanged_or_unread() {
    let k = "sc-pushed";
    // HEAD is a remote tip.
    assert!(end(k, B, "Done.", Some(true)).0.is_empty());
    // The reply does not say done, or hedges it.
    assert!(end(k, C, "Still working on the tests.", Some(false)).0.is_empty());
    assert!(end(k, C, "It is not done yet.", Some(false)).0.is_empty());
    assert!(end(k, C, "I'll push once it's done.", Some(false)).0.is_empty());
    // The session's own starting HEAD.
    assert!(end(k, A, "Done.", Some(false)).0.is_empty());
    // Not read (feature off at the turn's end, or no git): fails open.
    assert!(end(k, C, "Done.", None).0.is_empty());
    // A push call ran at this HEAD (a broker push leaves no remote-tracking ref).
    let k = "sc-pushcall";
    call(k, "p", "execute", Some("git push -u origin HEAD:lane/x"));
    assert!(end(k, B, "Done, pushed.", Some(false)).0.is_empty());
}

#[test]
fn claims_done_reads_claims_not_plans() {
    for yes in
        ["Done.", "All set, PR #12 is open.", "Implemented and pushed.", "The task is complete"]
    {
        assert!(claims_done(yes), "{yes}");
    }
    for no in
        ["Not done yet.", "It isn't finished.", "I will be done soon", "Running the tests now."]
    {
        assert!(!claims_done(no), "{no}");
    }
}

#[test]
fn pushes_and_edits_classify() {
    let c = |v: Value| classify(&v);
    assert_eq!(
        c(json!({"kind": "execute", "rawInput": {"command": "git -C x push origin y"}})),
        Class::Push
    );
    assert_eq!(c(json!({"kind": "other", "title": "mcp__github__push"})), Class::Push);
    assert_eq!(
        c(
            json!({"kind": "execute", "rawInput": {"command": ["bash", "-lc", "gh pr create -t x"]}})
        ),
        Class::Push
    );
    assert_eq!(c(json!({"kind": "edit", "title": "Edit"})), Class::Change);
    assert_eq!(c(json!({"kind": "other", "title": "TodoWrite"})), Class::Change);
    assert_eq!(c(json!({"kind": "read", "title": "Read"})), Class::Read);
    assert_eq!(
        c(json!({"kind": "execute", "rawInput": {"command": ["bash", "-lc", "git log -3"]}})),
        Class::Read
    );
    assert_eq!(c(json!({"kind": "execute"})), Class::Pending);
}

#[test]
fn a_remote_tip_is_read_from_loose_and_packed_refs() {
    let dir = tempfile::tempdir().unwrap();
    let git = dir.path().join(".git");
    std::fs::create_dir_all(git.join("refs/remotes/origin/lane")).unwrap();
    std::fs::create_dir_all(git.join("refs/heads")).unwrap();
    std::fs::write(git.join("HEAD"), "ref: refs/heads/main\n").unwrap();
    std::fs::write(git.join("refs/remotes/origin/lane/x"), format!("{B}\n")).unwrap();
    std::fs::write(
        git.join("packed-refs"),
        format!("{C} refs/remotes/origin/main\n{A} refs/heads/main\n"),
    )
    .unwrap();
    let tip = |h: &str| crate::git_state::is_remote_tip(dir.path(), h);
    assert_eq!(tip(B), Some(true));
    assert_eq!(tip(C), Some(true));
    // A local branch's commit is not a remote tip.
    assert_eq!(tip(A), Some(false));
    assert_eq!(crate::git_state::is_remote_tip(&dir.path().join("nope"), B), None);
}

#[test]
fn the_feature_is_listed_with_its_switches() {
    assert!(super::super::harness_magic::FEATURES.iter().any(|f| f.name == FEATURE));
    assert_eq!(super::super::harness_magic::env_key(FEATURE), "ACPMUX_HM_SIDECARS");
}
