use super::*;

#[test]
fn only_a_command_that_is_gh_pr_create_counts() {
    for yes in [
        "gh pr create --fill",
        "cd /src/app && gh pr create -B main",
        "cd a; cd b && GH_HOST=github.com env gh pr create --draft",
        "gh pr create --title x --body \"$(cat <<'EOF'\nSummary | with; a pipe && more\n\"quoted\"\nEOF\n)\"",
        "gh pr create --title 'a && b' --body 'x; y | z'",
        "gh pr create --body \"$(printf 'a)b')\" --title \"x && y\"",
        "gh pr create --fill 2>&1",
        "gh pr create --fill &>/tmp/pr.log",
        "git push && gh pr create --fill",
        "git add -A && git commit -m 'x; y' && git push -u origin HEAD && gh pr create --fill 2>&1",
    ] {
        assert!(is_gh_pr_create(yes), "{yes}");
    }
    for no in [
        "grep -rn 'gh pr create' .",
        "echo gh pr create",
        "gh pr create --fill && gh pr view 9",
        "gh pr create --fill | tee out",
        "gh pr create --body \"$(cat body.md)\" && gh pr view 9",
        "git push; gh pr create --fill",
        "git push || gh pr create --fill",
        "git push | gh pr create --fill",
        "sleep 9 & gh pr create --fill",
        "gh pr view 9",
        "",
    ] {
        assert!(!is_gh_pr_create(no), "{no}");
    }
}

#[test]
fn script_reads_a_string_a_shell_argv_and_falls_back_to_the_title() {
    assert_eq!(script(&json!({"rawInput": {"command": "gh pr create"}})).unwrap(), "gh pr create");
    let argv = json!({"rawInput": {"command": ["/bin/bash", "-lc", "cd x && gh pr create"]}});
    assert_eq!(script(&argv).unwrap(), "cd x && gh pr create");
    let words = json!({"rawInput": {"command": ["gh", "pr", "create"]}});
    assert_eq!(script(&words).unwrap(), "gh pr create");
    assert_eq!(script(&json!({"title": "gh pr create"})).unwrap(), "gh pr create");
}

#[test]
fn a_url_counts_only_when_its_call_completes() {
    let mut calls = std::collections::HashMap::new();
    let start = json!({"toolCallId": "t1", "kind": "execute", "rawInput": {"command": "gh pr create --fill"}});
    let printed = json!({"toolCallId": "t1", "status": "in_progress",
            "rawOutput": {"stdout": "https://github.com/o/r/pull/5\n"}});
    assert_eq!(track(&mut calls, &start), None);
    // gh's "already exists: URL" streamed before the call fails records nothing.
    assert_eq!(track(&mut calls, &printed), None);
    assert_eq!(track(&mut calls, &json!({"toolCallId": "t1", "status": "failed"})), None);
    assert!(calls.is_empty());
    // The URL printed earlier counts once the call completes, though the last update has no output.
    assert_eq!(track(&mut calls, &start), None);
    assert_eq!(track(&mut calls, &printed), None);
    assert_eq!(
        track(&mut calls, &json!({"toolCallId": "t1", "status": "completed"})).as_deref(),
        Some("https://github.com/o/r/pull/5")
    );
    assert!(calls.is_empty());
    // Another call's updates are not a gh pr create.
    assert_eq!(
        track(
            &mut calls,
            &json!({"toolCallId": "t2", "status": "completed",
            "rawOutput": {"stdout": "https://github.com/o/r/pull/6\n"}})
        ),
        None
    );
}

#[test]
fn a_gh_pr_merge_or_close_anywhere_in_the_script_names_its_pull_request() {
    let url = |n: u64| Target::Url(format!("https://github.com/o/r/pull/{n}"));
    for (script, want) in [
        ("gh pr merge 5 --squash", vec![Target::Number(5)]),
        ("gh pr merge 5 --squash --match-head-commit abc 2>&1 | tail -3", vec![Target::Number(5)]),
        ("cd /src && GH_HOST=github.com gh pr close '#6' -c 'done now'", vec![Target::Number(6)]),
        ("git fetch; gh pr merge https://github.com/o/r/pull/7", vec![url(7)]),
        ("gh pr merge -R o/r 8 --squash; gh pr close --repo=o/r 9", vec![url(8), url(9)]),
        ("gh pr merge --repo https://github.com/o/r 10 -t subject", vec![url(10)]),
        // Nothing merged yet, or a branch acpmux cannot map to a pull request.
        ("gh pr merge 11 --auto --squash", vec![]),
        ("gh pr merge my-branch --squash", vec![]),
        (
            r#"lane-gh call land o/r '{"repo": "o/r", "number": 12, "sha": "abc"}' 2>&1 | tail -3"#,
            vec![url(12)],
        ),
        (r#"lane-gh call close o/r '{"number":13,"body":"done"}'"#, vec![url(13)]),
        (r#"lane-gh call land '{"number": 14}'"#, vec![]),
    ] {
        assert_eq!(gh_pr_closes(script), Some(want), "{script}");
    }
    for no in [
        "grep 'gh pr merge' log",
        "echo gh pr close 5",
        "gh pr view 5",
        "cat merges.log",
        r#"lane-gh call get o/r '{"number": 5}'"#,
        "",
    ] {
        assert_eq!(gh_pr_closes(no), None, "{no}");
    }
}

#[test]
fn settled_urls_are_what_gh_says_it_merged_or_closed() {
    let out = "✓ Squashed and merged pull request o/r#5 (Fix it)\n\
            ✓ Rebased and merged pull request o/r#6 (x)\n\
            ✓ Merged pull request a-b/c.d#7 (x)\n\
            ✓ Closed pull request o/r#8 (x)\n\
            ! Pull request o/r#9 was already merged\n\
            ! Pull request o/r#10 was already closed\n\
            merged o/r#11 at 0123456789ab (head fedcba9876)\n\
            ✓ Squashed and merged o/r#12\n\
            ✓ Closed o/r#13\n\
            ✓ Squashed and merged pull request o/r#5 (Fix it)\n";
    let urls: Vec<String> = (5..=13).map(|n| format!("https://github.com/o/r/pull/{n}")).collect();
    let mut want = urls.clone();
    want[2] = "https://github.com/a-b/c.d/pull/7".into();
    assert_eq!(settled_urls(out), want);
    for none in [
        "✓ Pull request o/r#5 will be automatically merged via squash when all requirements are met",
        "! Pull request o/r#5 is not mergeable: the merge commit cannot be cleanly created",
        "X Pull request o/r#5 is not mergeable",
        "the branch was merged o/r#5 earlier",
    ] {
        assert!(settled_urls(none).is_empty(), "{none}");
    }
}

#[test]
fn a_closed_pull_request_counts_once_its_call_ends() {
    let call = |id: &str, command: &str| json!({"toolCallId": id, "kind": "execute", "rawInput": {"command": command}});
    let end = |id: &str, status: &str, stdout: &str| json!({"toolCallId": id, "status": status, "rawOutput": {"stdout": stdout}});
    let five = Target::Url("https://github.com/o/r/pull/5".into());
    let mut calls = std::collections::HashMap::new();
    // Off a terminal gh prints nothing when it merges: a completed call counts its argument.
    assert!(track_closed(&mut calls, &call("t1", "gh pr merge -R o/r 5 --squash")).is_empty());
    assert_eq!(track_closed(&mut calls, &end("t1", "completed", "")), vec![five.clone()]);
    // A failed call counts only what gh printed it settled, whatever the pipe exited with.
    track_closed(&mut calls, &call("t2", "gh pr merge 5 2>&1 | tail -2"));
    let printed = end("t2", "in_progress", "! Pull request o/r#5 was already merged\n");
    assert!(track_closed(&mut calls, &printed).is_empty());
    assert_eq!(
        track_closed(&mut calls, &json!({"toolCallId": "t2", "status": "failed"})),
        vec![five]
    );
    track_closed(&mut calls, &call("t3", "gh pr merge -R o/r 6"));
    assert!(track_closed(&mut calls, &end("t3", "failed", "")).is_empty());
    // A merge gh only queued or refused settles nothing, though the call completed.
    for said in [
        "✓ Pull request o/r#7 will be added to the merge queue for main when ready",
        "X Pull request o/r#7 is not mergeable: the base branch policy prohibits the merge.",
        "✓ o/r#7 at 0123456789ab handed to merge_hold (it waits on: review)",
        "{\n \"ok\": true,\n \"handed_to\": \"merge_hold\"\n}",
        "{\n \"ok\": false,\n \"error\": \"checks are red\"\n}",
    ] {
        track_closed(&mut calls, &call("t4", "gh pr merge -R o/r 7"));
        assert!(track_closed(&mut calls, &end("t4", "completed", said)).is_empty(), "{said}");
    }
    assert!(calls.is_empty());
    // Another call's output says nothing.
    let other = end("t5", "completed", "✓ Closed pull request o/r#6 (x)\n");
    assert!(track_closed(&mut calls, &other).is_empty());
}

#[test]
fn printed_url_is_the_last_line_that_is_only_a_pull_url() {
    let out = "Creating pull request for b into main in o/r\n\nhttps://github.com/o/r/pull/12\n";
    assert_eq!(printed_url(out), Some("https://github.com/o/r/pull/12"));
    assert_eq!(printed_url("see https://github.com/o/r/pull/3 for more"), None);
    assert_eq!(printed_url("https://github.com/o/r/pull/3/files"), None);
    let stdout =
        json!({"rawOutput": {"stdout": "https://github.com/o/r/pull/4\n", "stderr": "warning"}});
    assert_eq!(printed_url(&output_text(&stdout)), Some("https://github.com/o/r/pull/4"));
}
