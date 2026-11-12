//! Part of `Hub`; see `hub/mod.rs`. The pull requests a session opened: the URL each of its
//! `gh pr create` tool calls printed, kept once each in its meta (`SessionMeta::pull_requests`)
//! so the sidebar's session tree counts every pull request a session opened, not only the one
//! of the branch its folder has checked out now.
//!
//! Only a shell call (`kind` `execute`) whose last command is `gh pr create ...` counts, after
//! `cd DIR` steps, steps joined to it by `&&` (`git push && gh pr create`) and `VAR=value` / `env`
//! prefixes: a grep or an echo that mentions it, or a `gh pr create && gh pr view 9`, does not. Of its output only the last line that is nothing but
//! a pull request URL is kept, which is what gh prints on success; a failed call (gh exits 1 when
//! the branch already has one, printing its URL) records nothing. Harnesses report the command on the tool call and its output on later updates
//! (Claude Code, codex-acp), so such a call and the URL it printed are remembered until it ends
//! (`Session::pr_creates`); the URL counts only when the call completes.

use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;

use super::*;

static PULL_URL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$").unwrap() // crash-allow: constant pattern
});

/// A session keeps at most this many; a runaway loop stops growing its meta here.
pub(super) const MAX_PULL_REQUESTS: usize = 200;

/// The shell script a tool call runs: `rawInput.command` as a string, or an argv (the script of
/// `bash -lc SCRIPT`, else the words joined); for a call without one, its title.
fn script(update: &Value) -> Option<String> {
    match update.pointer("/rawInput/command").or_else(|| update.pointer("/rawInput/cmd")) {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Array(argv)) => {
            let words: Vec<&str> = argv.iter().filter_map(Value::as_str).collect();
            let shell = words.first().map(|w| w.rsplit('/').next().unwrap_or(w));
            let dash_c = words.get(1).is_some_and(|f| f.starts_with('-') && f.ends_with('c'));
            if matches!(shell, Some("bash" | "sh" | "zsh")) && dash_c && words.len() == 3 {
                Some(words[2].to_owned())
            } else {
                Some(words.join(" "))
            }
        }
        _ => update.get("title").and_then(Value::as_str).map(str::to_owned),
    }
}

/// `script`'s top-level commands, each with the separator after it (`&&`, `||`, `;`, `|`, `&` or
/// a newline; empty for the last), split outside quotes, `$( )`, backticks and heredoc bodies. An
/// `&` in a redirect (`2>&1`, `>&2`, `&>file`) separates nothing.
fn commands(script: &str) -> Vec<(String, String)> {
    let chars: Vec<char> = script.chars().collect();
    let mut out = vec![String::new()];
    let mut seps: Vec<String> = vec![];
    // Open quotes (`'`, `"`, `` ` ``) and parentheses (`(`, also `$(`), innermost last.
    let mut open: Vec<char> = vec![];
    // Heredoc words whose bodies start at the next newline.
    let mut heredocs: Vec<String> = vec![];
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        let cur = out.last_mut().unwrap(); // crash-allow: out is never empty
        match open.last() {
            Some('\'') => {
                if c == '\'' {
                    open.pop();
                }
                cur.push(c);
                i += 1;
                continue;
            }
            Some(&q @ ('"' | '`')) => {
                cur.push(c);
                if c == '\\' {
                    cur.extend(next);
                    i += 2;
                    continue;
                }
                if c == q {
                    open.pop();
                } else if q == '"' && c == '$' && next == Some('(') {
                    cur.push('(');
                    open.push('(');
                    i += 2;
                    continue;
                }
                i += 1;
                continue;
            }
            _ => {}
        }
        match c {
            '\\' => {
                cur.push(c);
                cur.extend(next);
                i += 2;
                continue;
            }
            '\'' | '"' | '`' | '(' => open.push(c),
            ')' if open.last() == Some(&'(') => {
                open.pop();
            }
            '<' if next == Some('<') && chars.get(i + 2) != Some(&'<') => {
                // `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`: its body is skipped below.
                let mut j = i + 2;
                if chars.get(j) == Some(&'-') {
                    j += 1;
                }
                while chars.get(j) == Some(&' ') {
                    j += 1;
                }
                let word: String = chars[j..]
                    .iter()
                    .take_while(|c| !c.is_whitespace() && !matches!(c, ';' | '&' | '|' | ')'))
                    .filter(|c| !matches!(c, '\'' | '"'))
                    .collect();
                if !word.is_empty() {
                    heredocs.push(word);
                }
            }
            '\n' if !heredocs.is_empty() => {
                // Skip each pending heredoc's body through its closing line.
                let mut j = i + 1;
                for word in std::mem::take(&mut heredocs) {
                    while j <= chars.len() {
                        let end = chars[j..]
                            .iter()
                            .position(|&c| c == '\n')
                            .map_or(chars.len(), |p| j + p);
                        let line: String = chars[j..end].iter().collect();
                        j = end + 1;
                        if line.trim() == word {
                            break;
                        }
                    }
                }
                cur.push(' ');
                i = j;
                continue;
            }
            '&' if i > 0 && matches!(chars[i - 1], '>' | '<') || next == Some('>') => {}
            '&' | '|' | ';' | '\n' if open.is_empty() => {
                // `&&` or `||` is one separator.
                let doubled = next == Some(c) && c != ';' && c != '\n';
                seps.push(if doubled { format!("{c}{c}") } else { c.to_string() });
                if doubled {
                    i += 1;
                }
                out.push(String::new());
                i += 1;
                continue;
            }
            _ => {}
        }
        cur.push(c);
        i += 1;
    }
    seps.push(String::new());
    out.into_iter()
        .zip(seps)
        .map(|(c, sep)| (c.trim().to_owned(), sep))
        .filter(|(c, _)| !c.is_empty())
        .collect()
}

/// The script ends in `gh pr create`: each command before it is a `cd` or must succeed for gh to
/// run (`git push && gh pr create`), none come after, and only `VAR=value` words or `env` precede
/// `gh`. gh's URL is the last bare pull request URL printed, so earlier steps' output can't stand
/// in for it (`git push` prints `/pull/new/BRANCH`, which is not one).
fn is_gh_pr_create(script: &str) -> bool {
    let commands = commands(script);
    let Some(((last, _), before)) = commands.split_last() else {
        return false;
    };
    if !before.iter().all(|(c, sep)| c == "cd" || c.starts_with("cd ") || sep == "&&") {
        return false;
    }
    let mut words = last.split_whitespace().skip_while(|w| {
        *w == "env" || w.split_once('=').is_some_and(|(k, _)| !k.is_empty() && !k.starts_with('-'))
    });
    matches!((words.next(), words.next(), words.next()), (Some("gh"), Some("pr"), Some("create")))
}

/// One of the script's top-level commands is `gh pr merge` or `gh pr close` (after `VAR=value`
/// words or `env`), wherever it stands: what gh printed says which pull request it settled, so
/// a pipe after it (`2>&1 | tail -3`) or a step before it changes nothing.
fn is_gh_pr_close(script: &str) -> bool {
    commands(script).iter().any(|(command, _)| {
        let mut words = command.split_whitespace().skip_while(|w| {
            *w == "env"
                || w.split_once('=').is_some_and(|(k, _)| !k.is_empty() && !k.starts_with('-'))
        });
        matches!(
            (words.next(), words.next(), words.next()),
            (Some("gh"), Some("pr"), Some("merge" | "close"))
        )
    })
}

/// The lines gh prints once a pull request is settled: `✓ Squashed and merged pull request
/// o/r#5 (title)` (also `Merged`, `Rebased and merged`, `Closed`), `! Pull request o/r#5 was
/// already merged` (or `closed`), and a merge wrapper's `merged o/r#5 at SHA`. `--auto`'s "will be
/// automatically merged" is none of them: nothing is merged yet.
/// `None` only if the constant pattern failed to build, which its tests rule out.
static SETTLED: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?m)(?:(?:Squashed and merged|Rebased and merged|Merged|Closed) pull request |Pull request |^merged )([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)(?: was already (?:merged|closed)| at [0-9a-f]{7,}|[ ]\(|$)",
    )
    .ok()
});

/// The pull requests `output` says gh merged or closed, as their URLs, once each.
fn settled_urls(output: &str) -> Vec<String> {
    let mut urls: Vec<String> = vec![];
    let Some(settled) = SETTLED.as_ref() else { return urls };
    for found in settled.captures_iter(output) {
        let url = format!("https://github.com/{}/pull/{}", &found[1], &found[2]);
        if !urls.contains(&url) {
            urls.push(url);
        }
    }
    urls
}

/// Notes a `tool_call` or `tool_call_update` into `m`: a shell call that runs `gh pr merge` or
/// `gh pr close` is remembered, and the pull requests its output says it merged or closed join
/// `m.closed_pull_requests` once it completes, whoever's session opened them. Returns the URLs
/// that joined it, for the review queue (`review_queue.rs`).
pub(super) fn absorb_closed(session: &Session, update: &Value, m: &mut SessionMeta) -> Vec<String> {
    let mut calls = session.pr_closes.lock().unwrap_or_else(|e| e.into_inner());
    let mut joined = vec![];
    for url in track_closed(&mut calls, update) {
        if m.closed_pull_requests.contains(&url) {
            continue;
        }
        if m.closed_pull_requests.len() >= MAX_PULL_REQUESTS {
            m.closed_pull_requests.remove(0);
        }
        m.closed_pull_requests.push(url.clone());
        joined.push(url);
    }
    joined
}

/// Follows one update of a `gh pr merge` or `gh pr close` call in `calls`: the pull requests to
/// record once the call completes. gh prints its line only on success, so a failed call's line
/// still counts (a `| tail` after gh makes the call's status the pipe's, not gh's).
fn track_closed(calls: &mut HashMap<String, Vec<String>>, update: &Value) -> Vec<String> {
    let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return vec![] };
    let execute = update.get("kind").and_then(Value::as_str) == Some("execute");
    if execute && script(update).is_some_and(|s| is_gh_pr_close(&s)) {
        calls.entry(id.to_owned()).or_default();
    }
    let Some(seen) = calls.get_mut(id) else { return vec![] };
    for url in settled_urls(&output_text(update)) {
        if !seen.contains(&url) {
            seen.push(url);
        }
    }
    match update.get("status").and_then(Value::as_str) {
        Some("completed" | "failed") => calls.remove(id).unwrap_or_default(),
        _ => vec![],
    }
}

/// The text a tool update reports as its output: `rawOutput.stdout` when the harness keeps stdout
/// apart, else its content's text and `rawOutput`.
fn output_text(update: &Value) -> String {
    if let Some(stdout) = update.pointer("/rawOutput/stdout").and_then(Value::as_str) {
        return stdout.to_owned();
    }
    let mut text = String::new();
    for block in update.get("content").and_then(Value::as_array).into_iter().flatten() {
        if let Some(t) = block.pointer("/content/text").and_then(Value::as_str) {
            text.push_str(t);
            text.push('\n');
        }
    }
    match update.get("rawOutput") {
        Some(Value::String(s)) => text.push_str(s),
        Some(raw) => {
            for key in ["output", "formatted_output", "aggregated_output"] {
                if let Some(s) = raw.get(key).and_then(Value::as_str) {
                    text.push_str(s);
                    text.push('\n');
                }
            }
        }
        None => {}
    }
    text
}

/// The pull request `gh pr create` printed: the last output line that is nothing but its URL.
fn printed_url(output: &str) -> Option<&str> {
    output.lines().rev().map(str::trim).find(|line| PULL_URL.is_match(line))
}

/// Notes a `tool_call` or `tool_call_update` into `m`: a shell call that runs `gh pr create` is
/// remembered, and the pull request URL its output prints joins `m.pull_requests`, opened `at`
/// (`m.pull_request_times`). Returns a URL that joined it, for the review queue
/// (`review_queue.rs`) and the cost ledger (`hub/ledger`).
pub(super) fn absorb(
    session: &Session,
    update: &Value,
    m: &mut SessionMeta,
    at: u64,
) -> Option<String> {
    let mut calls = session.pr_creates.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(url) = track(&mut calls, update)
        && m.pull_requests.len() < MAX_PULL_REQUESTS
        && !m.pull_requests.contains(&url)
    {
        m.pull_requests.push(url.clone());
        m.pull_request_times.insert(url.clone(), at);
        return Some(url);
    }
    None
}

/// Follows one update of a `gh pr create` call in `calls` (its id, and the URL it printed so far):
/// the URL to record once the call completes. A failed call records none, though it printed one
/// before failing ("a pull request for branch ... already exists: URL").
fn track(calls: &mut HashMap<String, Option<String>>, update: &Value) -> Option<String> {
    let id = update.get("toolCallId").and_then(Value::as_str)?;
    let execute = update.get("kind").and_then(Value::as_str) == Some("execute");
    if execute && script(update).is_some_and(|s| is_gh_pr_create(&s)) {
        calls.entry(id.to_owned()).or_default();
    }
    let printed = calls.get_mut(id)?;
    if let Some(url) = printed_url(&output_text(update)) {
        *printed = Some(url.to_owned());
    }
    match update.get("status").and_then(Value::as_str) {
        Some("completed") => calls.remove(id).flatten(),
        Some("failed") => {
            calls.remove(id);
            None
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
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
        assert_eq!(
            script(&json!({"rawInput": {"command": "gh pr create"}})).unwrap(),
            "gh pr create"
        );
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
    fn a_gh_pr_merge_or_close_anywhere_in_the_script_counts() {
        for yes in [
            "gh pr merge 5 --squash",
            "gh pr merge 5 --squash --match-head-commit abc 2>&1 | tail -3",
            "cd /src && GH_HOST=github.com gh pr close 5 -c done",
            "git fetch; gh pr merge https://github.com/o/r/pull/5",
        ] {
            assert!(is_gh_pr_close(yes), "{yes}");
        }
        for no in
            ["grep 'gh pr merge' log", "echo gh pr close 5", "gh pr view 5", "cat merges.log", ""]
        {
            assert!(!is_gh_pr_close(no), "{no}");
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
            ✓ Squashed and merged pull request o/r#5 (Fix it)\n";
        let urls: Vec<String> =
            (5..=11).map(|n| format!("https://github.com/o/r/pull/{n}")).collect();
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
        let mut calls = std::collections::HashMap::new();
        let start = json!({"toolCallId": "t1", "kind": "execute",
            "rawInput": {"command": "gh pr merge 5 --squash 2>&1 | tail -2"}});
        let printed = json!({"toolCallId": "t1", "status": "in_progress",
            "rawOutput": {"stdout": "✓ Squashed and merged pull request o/r#5 (x)\n"}});
        assert!(track_closed(&mut calls, &start).is_empty());
        assert!(track_closed(&mut calls, &printed).is_empty());
        // gh printed it, so it merged, whatever the pipe after it exited with.
        assert_eq!(
            track_closed(&mut calls, &json!({"toolCallId": "t1", "status": "failed"})),
            vec!["https://github.com/o/r/pull/5".to_owned()]
        );
        assert!(calls.is_empty());
        // Another call's output says nothing.
        let other = json!({"toolCallId": "t2", "status": "completed",
            "rawOutput": {"stdout": "✓ Closed pull request o/r#6 (x)\n"}});
        assert!(track_closed(&mut calls, &other).is_empty());
    }

    #[test]
    fn printed_url_is_the_last_line_that_is_only_a_pull_url() {
        let out =
            "Creating pull request for b into main in o/r\n\nhttps://github.com/o/r/pull/12\n";
        assert_eq!(printed_url(out), Some("https://github.com/o/r/pull/12"));
        assert_eq!(printed_url("see https://github.com/o/r/pull/3 for more"), None);
        assert_eq!(printed_url("https://github.com/o/r/pull/3/files"), None);
        let stdout = json!({"rawOutput": {"stdout": "https://github.com/o/r/pull/4\n", "stderr": "warning"}});
        assert_eq!(printed_url(&output_text(&stdout)), Some("https://github.com/o/r/pull/4"));
    }
}
