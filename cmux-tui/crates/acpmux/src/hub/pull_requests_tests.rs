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
        "gh pr create --fill | tee out",
        "cd /w && GUARD_OVERRIDE=\"$5\" timeout 900 gh pr create -R o/r --fill 2>&1 | tail -2",
        "timeout -k 5 --signal=KILL 60 gh pr create --fill",
        "lane-gh call pr_create o/r '{\"head\": \"lane/x\", \"base\": \"main\"}'",
    ] {
        assert!(is_gh_pr_create(yes), "{yes}");
    }
    for no in [
        "grep -rn 'gh pr create' .",
        "echo gh pr create",
        "gh pr create --fill && gh pr view 9",
        "gh pr create --fill | xargs echo",
        "timeout 900 gh pr view 9",
        "lane-gh call pr_view o/r '{}'",
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
fn a_broker_pr_create_tool_counts_the_url_its_answer_names() {
    let mut calls = std::collections::HashMap::new();
    let start = json!({"toolCallId": "m1", "kind": "other", "title": "mcp__github__pr_create",
        "_meta": {"claude": {"tool": "mcp__github__pr_create"}},
        "rawInput": {"repo": "o/r", "head": "lane/x", "base": "main", "title": "t"}});
    let done = json!({"toolCallId": "m1", "status": "completed", "content": [{"type": "content",
        "content": {"type": "text", "text": "{\"ok\":true,\"status\":201,\"data\":{\"html_url\":\"https://github.com/o/r/pull/7\",\"number\":7,\"head\":{\"repo\":{\"html_url\":\"https://github.com/o/r\"}}}}"}}]});
    assert_eq!(track(&mut calls, &start), None);
    assert_eq!(track(&mut calls, &done).as_deref(), Some("https://github.com/o/r/pull/7"));
    // A refusal (a cooldown, a 409) names none, though the tool call "completed".
    for refused in [
        "{\"ok\":false,\"error\":\"shared content-creation cooldown\",\"retry_after\":898}",
        "{\"ok\":false,\"status\":409,\"error\":\"the accepted PR create changed\"}",
    ] {
        assert_eq!(track(&mut calls, &start), None);
        let answer = json!({"toolCallId": "m1", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": refused}}]});
        assert_eq!(track(&mut calls, &answer), None, "{refused}");
    }
    // Codex names it by its title.
    let codex = json!({"toolCallId": "c1", "title": "github.pr_create", "status": "completed",
        "rawOutput": {"output": "{\"ok\": true, \"data\": {\"html_url\": \"https://github.com/o/r/pull/8\"}}"}});
    assert_eq!(track(&mut calls, &codex).as_deref(), Some("https://github.com/o/r/pull/8"));
    assert!(calls.is_empty());

    // The repository MCP helper opens the PR itself and returns the same structured URL.
    let publish = json!({"toolCallId": "p1", "title": "mcp__repo__repo_publish",
        "rawInput": {"repo": "o/r", "branch": "lane/x"}});
    let published = json!({"toolCallId": "p1", "status": "completed",
        "content": [{"type": "text", "text": "o/r lane/x: abc123 pushed through broker\nhttps://api.github.com/repos/o/r/pulls/9"}]});
    assert_eq!(track(&mut calls, &publish), None);
    assert_eq!(track(&mut calls, &published).as_deref(), Some("https://github.com/o/r/pull/9"));

    let published_json = json!({"toolCallId": "p2", "title": "repo_publish", "status": "completed",
        "content": [{"type": "text", "text": "{\"data\":{\"url\":\"https://api.github.com/repos/o/r/pulls/10\"}}"}]});
    assert_eq!(
        track(&mut calls, &published_json).as_deref(),
        Some("https://github.com/o/r/pull/10")
    );

    let existing = json!({"toolCallId": "p3", "title": "repo_publish", "status": "completed",
        "content": [{"type": "text", "text": "a pull request already exists:\nhttps://api.github.com/repos/o/r/pulls/11"}]});
    assert_eq!(track(&mut calls, &existing), None);
}

#[test]
fn a_shell_create_behind_timeout_and_a_pipe_counts_but_not_one_that_already_exists() {
    let mut calls = std::collections::HashMap::new();
    let command = "GUARD_OVERRIDE=x timeout 900 gh pr create --fill 2>&1 | tail -3";
    let run = |stdout: &str| {
        json!({"toolCallId": "s1", "kind": "execute", "status": "completed",
            "rawInput": {"command": command}, "rawOutput": {"stdout": stdout}})
    };
    let printed = "https://github.com/o/r/pull/9\nsession-footer: added\n";
    assert_eq!(track(&mut calls, &run(printed)).as_deref(), Some("https://github.com/o/r/pull/9"));
    // The pipe hides gh's exit status: the line before its URL says it was not opened here.
    let exists = "a pull request for branch \"x\" into branch \"main\" already exists:\nhttps://github.com/o/r/pull/9\n";
    assert_eq!(track(&mut calls, &run(exists)), None);
    // `lane-gh call pr_create` answers with the broker's JSON.
    let lane = json!({"toolCallId": "s2", "kind": "execute", "status": "completed",
        "rawInput": {"command": "lane-gh call pr_create o/r '{}'"},
        "rawOutput": {"stdout": "{\"ok\": true, \"status\": 201, \"data\": {\"html_url\": \"https://github.com/o/r/pull/10\"}}\n"}});
    assert_eq!(track(&mut calls, &lane).as_deref(), Some("https://github.com/o/r/pull/10"));
    assert!(calls.is_empty());
}

#[test]
fn a_background_create_counts_what_its_task_printed() {
    let mut creates = Creates::default();
    let start = json!({"toolCallId": "b1", "kind": "other", "title": "mcp__acpmux__bg_start",
        "_meta": {"claude": {"tool": "mcp__acpmux__bg_start"}},
        "rawInput": {"command": "f(){ cd $1 && timeout 900 gh pr create --fill 2>&1 | tail -2; }; f a; f b"}});
    assert!(follow(&mut creates, &start).is_empty());
    let started = json!({"toolCallId": "b1", "status": "completed", "content": [{"type": "content",
        "content": {"type": "text", "text": "{\"id\":\"bg-1\",\"state\":\"running\"}"}}]});
    assert!(follow(&mut creates, &started).is_empty());
    // A `bg_output` answer for another task names none.
    let other = json!({"toolCallId": "b2", "status": "completed", "content": [{"type": "content",
        "content": {"type": "text", "text": "{\"id\":\"bg-2\",\"text\":\"https://github.com/o/r/pull/1\\n\"}"}}]});
    assert!(follow(&mut creates, &other).is_empty());
    let output = json!({"toolCallId": "b3", "status": "completed", "content": [{"type": "content",
        "content": {"type": "text", "text": "{\"id\":\"bg-1\",\"state\":\"exited\",\"text\":\"https://github.com/o/r/pull/11\\na pull request for branch already exists:\\nhttps://github.com/o/r/pull/3\\nhttps://github.com/o/r/pull/12\\n\"}"}}]});
    assert_eq!(
        follow(&mut creates, &output),
        ["https://github.com/o/r/pull/11", "https://github.com/o/r/pull/12"]
    );
    // Its end notice quotes its last lines.
    let notice = json!({"promptId": "bg-done-bg-1", "_meta": {"provenance": {"bgTaskId": "bg-1"}},
        "text": "[notice from acpmux] Background command finished: x (exit 0)\nTask bg-1: f...\nLast 2 lines of its output:\nhttps://github.com/o/r/pull/12\nsession-footer: added"});
    assert_eq!(follow_notice(&mut creates, &notice), ["https://github.com/o/r/pull/12"]);
    let unrelated = json!({"_meta": {"provenance": {"bgTaskId": "bg-9"}},
        "text": "https://github.com/o/r/pull/13"});
    assert!(follow_notice(&mut creates, &unrelated).is_empty());
    // A background command that opens none is not followed.
    let plain = json!({"toolCallId": "b4", "title": "mcp__acpmux__bg_start",
        "rawInput": {"command": "cargo test"}});
    follow(&mut creates, &plain);
    assert!(!creates.launches.contains("b4"));
}

#[test]
fn printed_url_is_the_last_line_that_is_only_a_pull_url() {
    let out = "Creating pull request for b into main in o/r\n\nhttps://github.com/o/r/pull/12\n";
    assert_eq!(printed_url(out).as_deref(), Some("https://github.com/o/r/pull/12"));
    assert_eq!(printed_url("see https://github.com/o/r/pull/3 for more"), None);
    assert_eq!(printed_url("https://github.com/o/r/pull/3/files"), None);
    let stdout =
        json!({"rawOutput": {"stdout": "https://github.com/o/r/pull/4\n", "stderr": "warning"}});
    assert_eq!(
        printed_url(&output_text(&stdout)).as_deref(),
        Some("https://github.com/o/r/pull/4")
    );
}
