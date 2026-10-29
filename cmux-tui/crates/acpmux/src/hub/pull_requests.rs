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

#[allow(clippy::unwrap_used, reason = "a constant pattern that compiles")]
static PULL_URL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$").unwrap() // crash-allow: constant pattern
});

/// A session keeps at most this many; a runaway loop stops growing its meta here.
const MAX_PULL_REQUESTS: usize = 200;

/// The shell script a tool call runs: `rawInput.command` as a string, or an argv (the script of
/// `bash -lc SCRIPT`, else the words joined); for a call without one, its title.
fn script(update: &Value) -> Option<String> {
    match update.pointer("/rawInput/command").or_else(|| update.pointer("/rawInput/cmd")) {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Array(argv)) => {
            let words: Vec<&str> = argv.iter().filter_map(Value::as_str).collect();
            match words.as_slice() {
                [shell, flag, script]
                    if matches!(shell.rsplit('/').next(), Some("bash" | "sh" | "zsh"))
                        && flag.starts_with('-')
                        && flag.ends_with('c') =>
                {
                    Some((*script).to_owned())
                }
                _ => Some(words.join(" ")),
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
    // The finished commands, then the one being read.
    let mut out: Vec<String> = vec![];
    let mut cur = String::new();
    let mut seps: Vec<String> = vec![];
    // Open quotes (`'`, `"`, `` ` ``) and parentheses (`(`, also `$(`), innermost last.
    let mut open: Vec<char> = vec![];
    // Heredoc words whose bodies start at the next newline.
    let mut heredocs: Vec<String> = vec![];
    let mut i = 0;
    while let Some(&c) = chars.get(i) {
        let next = chars.get(i + 1).copied();
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
                let word: String = chars
                    .get(j..)
                    .unwrap_or_default()
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
                    while let Some(rest) = chars.get(j..) {
                        let len = rest.iter().position(|&c| c == '\n').unwrap_or(rest.len());
                        let line: String = rest.iter().take(len).collect();
                        j += len + 1;
                        if line.trim() == word {
                            break;
                        }
                    }
                }
                cur.push(' ');
                i = j;
                continue;
            }
            '&' if matches!(i.checked_sub(1).and_then(|p| chars.get(p)), Some('>' | '<'))
                || next == Some('>') => {}
            '&' | '|' | ';' | '\n' if open.is_empty() => {
                // `&&` or `||` is one separator.
                let doubled = next == Some(c) && c != ';' && c != '\n';
                seps.push(if doubled { format!("{c}{c}") } else { c.to_string() });
                if doubled {
                    i += 1;
                }
                out.push(std::mem::take(&mut cur));
                i += 1;
                continue;
            }
            _ => {}
        }
        cur.push(c);
        i += 1;
    }
    out.push(cur);
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
/// remembered, and the pull request URL its output prints joins `m.pull_requests`.
pub(super) fn absorb(session: &Session, update: &Value, m: &mut SessionMeta) {
    let mut calls = session.pr_creates.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(url) = track(&mut calls, update)
        && m.pull_requests.len() < MAX_PULL_REQUESTS
        && !m.pull_requests.contains(&url)
    {
        m.pull_requests.push(url);
    }
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
