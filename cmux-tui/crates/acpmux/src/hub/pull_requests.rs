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

/// The `"number": N` of a `lane-gh call land|close` call's JSON arguments. `None` only if the
/// constant pattern failed to build, which its tests rule out.
static LANE_GH_NUMBER: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r#""number"\s*:\s*([0-9]+)"#).ok());

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

/// A pull request a `gh pr merge` or `gh pr close` call settled.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Target {
    Url(String),
    /// A bare number with no `--repo`: the repository is the one gh found in the call's folder,
    /// which acpmux does not know, so the review index names it (`Index::pr_by_number`).
    Number(u64),
}

/// A `gh pr merge` or `gh pr close` call while it runs (`Session::pr_closes`).
#[derive(Clone, Debug, Default)]
pub(super) struct Closing {
    /// What its arguments name, counted once the call completes.
    named: Vec<Target>,
    /// What gh printed it settled, counted however the call ends.
    printed: Vec<Target>,
    /// gh said it only queued or refused the merge.
    unsettled: bool,
}

/// gh's flags for `pr merge` and `pr close` that take the next word as their value.
const VALUE_FLAGS: [&str; 13] = [
    "-R",
    "--repo",
    "-b",
    "--body",
    "-F",
    "--body-file",
    "-t",
    "--subject",
    "-c",
    "--comment",
    "-A",
    "--author-email",
    "--match-head-commit",
];

/// The `gh pr merge` and `gh pr close` commands among the script's top-level commands (after
/// `VAR=value` words or `env`), wherever they stand, so a pipe after one (`2>&1 | tail -3`) or a
/// step before it changes nothing; `None` when it runs neither. Each names the pull request its
/// first argument is: a URL, or a number (`5`, `#5`) with `--repo OWNER/REPO` or without. A
/// branch name, or `--auto` (nothing is merged yet), names none. A lane VM's direct form,
/// `lane-gh call land|close OWNER/REPO JSON`, names the `"number"` its JSON holds.
fn gh_pr_closes(script: &str) -> Option<Vec<Target>> {
    let mut found = None;
    for (command, _) in commands(script) {
        let words: Vec<&str> = command
            .split_whitespace()
            .skip_while(|w| {
                *w == "env"
                    || w.split_once('=').is_some_and(|(k, _)| !k.is_empty() && !k.starts_with('-'))
            })
            .collect();
        if let ["lane-gh", "call", "land" | "close", repo, ..] = words[..] {
            // A lane VM's broker call, `lane-gh call land OWNER/REPO '{"number": 5, ...}'`.
            let targets: &mut Vec<Target> = found.get_or_insert_with(Vec::new);
            if let Some(n) = LANE_GH_NUMBER
                .as_ref()
                .and_then(|number| number.captures(&command))
                .and_then(|c| c[1].parse::<u64>().ok())
                && repo.split('/').count() == 2
            {
                targets.push(Target::Url(format!("https://github.com/{repo}/pull/{n}")));
            }
            continue;
        }
        if !matches!(words.get(..3), Some(["gh", "pr", "merge" | "close"])) {
            continue;
        }
        let targets: &mut Vec<Target> = found.get_or_insert_with(Vec::new);
        let (mut repo, mut first, mut auto) = (None, None, false);
        let mut rest = words[3..].iter().map(|w| w.trim_matches(|c| c == '\'' || c == '"'));
        while let Some(word) = rest.next() {
            if word == "--auto" {
                auto = true;
            } else if let Some(value) = word.strip_prefix("--repo=") {
                repo = Some(value.to_owned());
            } else if VALUE_FLAGS.contains(&word) {
                let value = rest.next();
                if matches!(word, "-R" | "--repo") {
                    repo = value.map(str::to_owned);
                }
            } else if !word.starts_with('-') && first.is_none() {
                first = Some(word.to_owned());
            }
        }
        let Some(first) = first.filter(|_| !auto) else { continue };
        if PULL_URL.is_match(&first) {
            targets.push(Target::Url(first));
        } else if let Ok(n) = first.trim_start_matches('#').parse::<u64>() {
            let repo = repo.map(|r| r.trim_start_matches("https://github.com/").to_owned());
            targets.push(match repo.filter(|r| r.split('/').count() == 2) {
                Some(repo) => Target::Url(format!("https://github.com/{repo}/pull/{n}")),
                None => Target::Number(n),
            });
        }
    }
    found
}

/// What gh prints when a merge is only queued or refused: none of the call's pull requests is
/// settled by it. On a lane VM, `gh pr merge` and `lane-gh call land` say `handed to` (`handed_to`)
/// when the broker queued the merge behind a hold, and `"ok": false` or `refused` when it did not
/// merge.
const UNSETTLED: [&str; 8] = [
    "will be automatically merged",
    "merge queue",
    "is not mergeable",
    "X Pull request",
    " handed to ",
    "\"handed_to\"",
    "\"ok\": false",
    "refused",
];

/// The lines gh prints once a pull request is settled: `✓ Squashed and merged pull request
/// o/r#5 (title)` (also `Merged`, `Rebased and merged`, `Closed`), `! Pull request o/r#5 was
/// already merged` (or `closed`), a merge wrapper's `merged o/r#5 at SHA`, and a lane VM's
/// `✓ Squashed and merged o/r#5` and `✓ Closed o/r#5`. `--auto`'s "will be
/// automatically merged" is none of them: nothing is merged yet.
/// `None` only if the constant pattern failed to build, which its tests rule out.
static SETTLED: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?m)(?:(?:Squashed and merged|Rebased and merged|Merged|Closed) (?:pull request )?|Pull request |^merged )([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)(?: was already (?:merged|closed)| at [0-9a-f]{7,}|[ ]\(|$)",
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

/// Follows a `tool_call` or `tool_call_update` of `session`: a shell call that runs `gh pr merge`
/// or `gh pr close` is remembered while it runs, and the pull requests it settled are returned
/// when it ends, for `m.closed_pull_requests` ([`record_closed`]) and the review queue
/// (`review_queue.rs`), whoever's session opened them.
pub(super) fn absorb_closed(session: &Session, update: &Value) -> Vec<Target> {
    let mut calls = session.pr_closes.lock().unwrap_or_else(|e| e.into_inner());
    track_closed(&mut calls, update)
}

/// Adds `url` to `m.closed_pull_requests` once, dropping the oldest past
/// [`MAX_PULL_REQUESTS`].
pub(super) fn record_closed(m: &mut SessionMeta, url: &str) {
    if m.closed_pull_requests.iter().any(|u| u == url) {
        return;
    }
    if m.closed_pull_requests.len() >= MAX_PULL_REQUESTS {
        m.closed_pull_requests.remove(0);
    }
    m.closed_pull_requests.push(url.to_owned());
}

/// Follows one update of a `gh pr merge` or `gh pr close` call in `calls`: what it settled, once
/// it ends. Off a terminal gh prints nothing when a merge or close succeeds, so a call that
/// completes counts the pull requests its arguments name, unless gh said it only queued or
/// refused the merge. What gh printed it settled (`was already merged`, a wrapper's `merged
/// o/r#5 at SHA`) counts however the call ends: a `| tail` after gh makes the call's status the
/// pipe's, not gh's.
fn track_closed(calls: &mut HashMap<String, Closing>, update: &Value) -> Vec<Target> {
    let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return vec![] };
    let execute = update.get("kind").and_then(Value::as_str) == Some("execute");
    if execute
        && !calls.contains_key(id)
        && let Some(named) = script(update).and_then(|s| gh_pr_closes(&s))
    {
        calls.insert(id.to_owned(), Closing { named, ..Default::default() });
    }
    let Some(closing) = calls.get_mut(id) else { return vec![] };
    let output = output_text(update);
    closing.unsettled |= UNSETTLED.iter().any(|line| output.contains(line));
    for url in settled_urls(&output) {
        let target = Target::Url(url);
        if !closing.printed.contains(&target) {
            closing.printed.push(target);
        }
    }
    let status = update.get("status").and_then(Value::as_str);
    if !matches!(status, Some("completed" | "failed")) {
        return vec![];
    }
    let Some(Closing { named, mut printed, unsettled }) = calls.remove(id) else { return vec![] };
    if status == Some("completed") && !unsettled {
        for target in named {
            if !printed.contains(&target) {
                printed.push(target);
            }
        }
    }
    printed
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
    fn a_gh_pr_merge_or_close_anywhere_in_the_script_names_its_pull_request() {
        let url = |n: u64| Target::Url(format!("https://github.com/o/r/pull/{n}"));
        for (script, want) in [
            ("gh pr merge 5 --squash", vec![Target::Number(5)]),
            (
                "gh pr merge 5 --squash --match-head-commit abc 2>&1 | tail -3",
                vec![Target::Number(5)],
            ),
            (
                "cd /src && GH_HOST=github.com gh pr close '#6' -c 'done now'",
                vec![Target::Number(6)],
            ),
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
        let urls: Vec<String> =
            (5..=13).map(|n| format!("https://github.com/o/r/pull/{n}")).collect();
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
        let out =
            "Creating pull request for b into main in o/r\n\nhttps://github.com/o/r/pull/12\n";
        assert_eq!(printed_url(out), Some("https://github.com/o/r/pull/12"));
        assert_eq!(printed_url("see https://github.com/o/r/pull/3 for more"), None);
        assert_eq!(printed_url("https://github.com/o/r/pull/3/files"), None);
        let stdout = json!({"rawOutput": {"stdout": "https://github.com/o/r/pull/4\n", "stderr": "warning"}});
        assert_eq!(printed_url(&output_text(&stdout)), Some("https://github.com/o/r/pull/4"));
    }
}
