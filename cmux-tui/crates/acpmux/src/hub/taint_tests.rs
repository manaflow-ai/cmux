use serde_json::json;

use super::*;

fn call(command: &str) -> Value {
    json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "execute",
           "title": command, "rawInput": {"command": command}})
}

#[test]
fn a_guard_override_taints_o() {
    for script in [
        "GUARD_OVERRIDE='why' git push -u origin HEAD:lane/x",
        "LAND_JUDGE_OVERRIDE=\"stuck\" LAND_JUDGE_OVERRIDE_RECEIPT=1 gh pr merge 5 --squash",
        "cd /tmp && env GUARD_OVERRIDE=x tools/now status",
        "export GUARD_OVERRIDE=x; git push",
    ] {
        assert_eq!(of_script(script), vec!['O'], "{script}");
    }
}

#[test]
fn a_forced_rerun_and_an_admin_merge_taint_r_and_a() {
    assert_eq!(of_script("gh run rerun 123 --failed --force"), vec!['R']);
    assert_eq!(of_script("gh pr merge 9 -R o/r --squash --admin 2>&1 | tail -3"), vec!['A']);
    assert_eq!(
        of_script("GUARD_OVERRIDE=x gh pr merge 9 --admin && gh run rerun 4 --force"),
        vec!['A', 'O', 'R']
    );
}

#[test]
fn a_mention_taints_nothing() {
    for script in [
        "grep -rn GUARD_OVERRIDE tools/",
        "echo 'GUARD_OVERRIDE=x git push'",
        "git commit -m \"gh pr merge 5 --admin is refused\"",
        "gh run rerun 123 --failed",
        "gh pr merge 5 --squash --match-head-commit abc",
        "GUARD_OVERRIDE_HELP=1 tools/now",
        "cat <<'EOF'\nGUARD_OVERRIDE=x git push\nEOF",
    ] {
        assert_eq!(of_script(script), Vec::<char>::new(), "{script}");
    }
}

#[test]
fn only_a_declared_command_counts_not_a_title() {
    let titled = json!({"sessionUpdate": "tool_call", "toolCallId": "t1",
                        "title": "GUARD_OVERRIDE=x git push"});
    assert!(of_call(&titled).is_empty());
    assert_eq!(of_call(&call("GUARD_OVERRIDE=x git push")), vec!['O']);
    let argv = json!({"sessionUpdate": "tool_call", "toolCallId": "t1",
                      "rawInput": {"command": ["bash", "-lc", "gh run rerun 1 --force"]}});
    assert_eq!(of_call(&argv), vec!['R']);
}

#[test]
fn each_letter_keeps_when_it_was_first_seen() {
    let mut m: SessionMeta = serde_json::from_value(json!({
        "id": "s1", "name": "s1", "harness": "claude", "cwd": "/tmp",
        "status": "idle", "createdAt": 0, "updatedAt": 0
    }))
    .expect("a minimal meta");
    absorb(&call("GUARD_OVERRIDE=x git push"), &mut m, 10);
    absorb(&call("GUARD_OVERRIDE=y git push && gh run rerun 2 --force"), &mut m, 20);
    absorb(&call("ls"), &mut m, 30);
    assert_eq!(m.taint, BTreeMap::from([("O".to_owned(), 10), ("R".to_owned(), 20)]));
    assert_eq!(letters(&m.taint), "OR");
    assert_eq!(letters(&BTreeMap::new()), "");
}
