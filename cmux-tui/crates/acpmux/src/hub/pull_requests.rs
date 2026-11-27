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

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use regex::Regex;

use super::*;

static PULL_URL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$").unwrap() // crash-allow: constant pattern
});
static API_PULL_URL: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"^https://api\.github\.com/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pulls/([0-9]+)$",
    )
    .ok()
});

/// The `"number": N` of a `lane-gh call land|close` call's JSON arguments. `None` only if the
/// constant pattern failed to build, which its tests rule out.
static LANE_GH_NUMBER: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r#""number"\s*:\s*([0-9]+)"#).ok());

/// A session keeps at most this many; a runaway loop stops growing its meta here.
/// Measured: the meta is saved whole on every change, about 130 bytes a pull request (its URL
/// and time): 26 KB per save at 200.
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

/// The script ends in `gh pr create` (or a lane VM's broker form, `lane-gh call pr_create`): each
/// command before it is a `cd` or must succeed for gh to run (`git push && gh pr create`), none
/// come after but output filters it pipes into (`2>&1 | tail -3`), and only `VAR=value` words,
/// `env` or `timeout [-k N] N` precede `gh`. gh's URL is the last bare pull request URL printed,
/// so earlier steps' output can't stand in for it (`git push` prints `/pull/new/BRANCH`, which is
/// not one); a filter hides gh's exit status, so its "already exists" URL is ruled out by the
/// line before it (`bare_urls`).
fn is_gh_pr_create(script: &str) -> bool {
    let commands = commands(script);
    let mut end = commands.len();
    while end > 1 && commands[end - 2].1 == "|" && is_filter(&commands[end - 1].0) {
        end -= 1;
    }
    let Some(((last, _), before)) = commands[..end].split_last() else {
        return false;
    };
    if !before.iter().all(|(c, sep)| c == "cd" || c.starts_with("cd ") || sep == "&&") {
        return false;
    }
    let mut words = last.split_whitespace().peekable();
    loop {
        match words.peek() {
            Some(&w)
                if w == "env"
                    || w.split_once('=')
                        .is_some_and(|(k, _)| !k.is_empty() && !k.starts_with('-')) =>
            {
                words.next();
            }
            Some(&"timeout") => {
                words.next();
                // Its flags (`-k 5`, `--signal=KILL`, `-s KILL`), then the duration.
                while let Some(&w) = words.peek() {
                    words.next();
                    if matches!(w, "-k" | "-s" | "--kill-after" | "--signal") {
                        words.next();
                    } else if !w.starts_with('-') {
                        break;
                    }
                }
            }
            _ => break,
        }
    }
    let first: Vec<&str> = words.take(3).collect();
    matches!(first[..], ["gh", "pr", "create"] | ["lane-gh", "call", "pr_create"])
}

/// A command that only passes on or keeps what it reads: `tail -3`, `head`, `tee FILE`, `cat`.
fn is_filter(command: &str) -> bool {
    matches!(command.split_whitespace().next(), Some("tail" | "head" | "tee" | "cat"))
}

/// A tool that opens a pull request through a broker or repository helper. GitHub's
/// `pr_create` names and repo MCP's `repo_publish` both return the created URL in their
/// structured result, so they can be joined to the session without scraping chat text.
fn is_pr_create_tool(name: &str) -> bool {
    name == "pr_create"
        || name.ends_with("__pr_create")
        || name.ends_with(".pr_create")
        || name == "repo_publish"
        || name.ends_with("__repo_publish")
        || name.ends_with(".repo_publish")
}

/// A tool that starts a background command (acpmux's `bg_start`), whose output arrives later.
fn is_bg_start_tool(name: &str) -> bool {
    name == "bg_start" || name.ends_with("__bg_start") || name.ends_with(".bg_start")
}

/// The tool's name: Claude Code's `_meta.claude.tool`, else its title.
fn tool_name(update: &Value) -> Option<&str> {
    update
        .pointer("/_meta/claude/tool")
        .and_then(Value::as_str)
        .or_else(|| update.get("title").and_then(Value::as_str))
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
        if let Some(t) =
            block.pointer("/content/text").or_else(|| block.get("text")).and_then(Value::as_str)
        {
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

/// Every output line that is nothing but a pull request URL, in order, once each, but one gh printed
/// because it already exists (`a pull request for branch "b" into branch "main" already exists:`
/// on the line before, or on its own line).
fn bare_urls(output: &str) -> Vec<String> {
    let mut urls: Vec<String> = vec![];
    let mut previous = "";
    for line in output.lines().map(str::trim) {
        if let Some(url) = normalize_pull_url(line).filter(|_| !previous.contains("already exists"))
            && !urls.iter().any(|u| u == &url)
        {
            urls.push(url);
        }
        if !line.is_empty() {
            previous = line;
        }
    }
    urls
}

/// The pull request `gh pr create` printed: the last output line that is nothing but its URL.
fn printed_url(output: &str) -> Option<String> {
    bare_urls(output).pop()
}

/// Normalizes GitHub's API pull URL to the browser URL stored in session metadata.
fn normalize_pull_url(value: &str) -> Option<String> {
    if PULL_URL.is_match(value) {
        return Some(value.to_owned());
    }
    let captures = API_PULL_URL.as_ref()?.captures(value)?;
    Some(format!("https://github.com/{}/{}/pull/{}", &captures[1], &captures[2], &captures[3]))
}

/// The pull request a broker create answered with: `{"ok": true, "status": 201, "data":
/// {"html_url": URL, ...}}` (the MCP tool and `lane-gh call pr_create`), or the bare URL `gh pr
/// create` prints. A refusal (`"ok": false`, a cooldown, a 409) names none.
fn created_url(output: &str) -> Option<String> {
    let trimmed = output.trim();
    let answer: Option<Value> = serde_json::from_str(trimmed)
        .ok()
        .or_else(|| trimmed.find('{').and_then(|i| serde_json::from_str(&trimmed[i..]).ok()));
    if let Some(answer) = answer.filter(Value::is_object) {
        if answer.get("ok").and_then(Value::as_bool) == Some(false) {
            return None;
        }
        for pointer in ["/data/url", "/data/html_url", "/url", "/html_url"] {
            if let Some(url) =
                answer.pointer(pointer).and_then(Value::as_str).and_then(normalize_pull_url)
            {
                return Some(url);
            }
        }
    }
    printed_url(output)
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
    let mut creates = session.pr_creates.lock().unwrap_or_else(|e| e.into_inner());
    let mut joined = None;
    for url in follow(&mut creates, update) {
        if m.pull_requests.len() < MAX_PULL_REQUESTS && !m.pull_requests.contains(&url) {
            m.pull_requests.push(url.clone());
            m.pull_request_times.insert(url.clone(), at);
            joined.get_or_insert(url);
        }
    }
    joined
}

/// The pull request creates a session has running (`Session::pr_creates`; the scorecard keeps
/// its own while it reads a log).
#[derive(Debug, Default)]
pub(crate) struct Creates {
    /// A `gh pr create` call's (or a broker `pr_create`'s) id, and the URL it printed so far.
    calls: HashMap<String, Option<String>>,
    /// `bg_start` calls whose command opens a pull request, by tool call id.
    launches: HashSet<String>,
    /// Their background tasks (`bg-…`), whose output is read when a tool reads it (`bg_output`,
    /// `run_wait`) or the task's end notice arrives (`follow_notice`).
    tasks: HashSet<String>,
}

impl Creates {
    pub(crate) fn clear(&mut self) {
        self.calls.clear();
        self.launches.clear();
        self.tasks.clear();
    }
}

/// Follows one tool update into `creates`: the pull request URLs it settled as opened. A
/// `gh pr create` or broker `pr_create` call counts once it completes (`track`). A `bg_start`
/// whose command opens one is remembered by its task id, and every bare pull request URL that
/// task printed counts when a tool result shows its output.
pub(crate) fn follow(creates: &mut Creates, update: &Value) -> Vec<String> {
    let mut urls: Vec<String> = track(&mut creates.calls, update).into_iter().collect();
    let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return urls };
    let opens = |s: &str| s.contains("gh pr create") || s.contains("pr_create");
    if tool_name(update).is_some_and(is_bg_start_tool) && script(update).is_some_and(|s| opens(&s))
    {
        creates.launches.insert(id.to_owned());
    }
    let completed = update.get("status").and_then(Value::as_str) == Some("completed");
    let output = || output_text(update);
    if completed && creates.launches.remove(id) {
        if let Some(task) = serde_json::from_str::<Value>(output().trim())
            .ok()
            .and_then(|v| v.get("id").and_then(Value::as_str).map(str::to_owned))
        {
            creates.tasks.insert(task);
        }
    } else if completed && !creates.tasks.is_empty() {
        // A `bg_output` or `run_wait` answer: `{"id": "bg-…", "text": OUTPUT, ...}`.
        if let Ok(answer) = serde_json::from_str::<Value>(output().trim())
            && answer.get("id").and_then(Value::as_str).is_some_and(|t| creates.tasks.contains(t))
            && let Some(text) = answer.get("text").and_then(Value::as_str)
        {
            for url in bare_urls(text) {
                if !urls.contains(&url) {
                    urls.push(url);
                }
            }
        }
    }
    urls
}

/// A background task's end notice (a `user_message` whose `_meta.provenance.bgTaskId` names a task
/// `follow` remembered): the bare pull request URLs in the output lines it quotes.
pub(crate) fn follow_notice(creates: &mut Creates, message: &Value) -> Vec<String> {
    let Some(task) = message.pointer("/_meta/provenance/bgTaskId").and_then(Value::as_str) else {
        return vec![];
    };
    if !creates.tasks.contains(task) {
        return vec![];
    }
    message.get("text").and_then(Value::as_str).map(bare_urls).unwrap_or_default()
}

/// Follows one update of a `gh pr create` call in `calls` (its id, and the URL it printed so far):
/// the URL to record once the call completes. A failed call records none, though it printed one
/// before failing ("a pull request for branch ... already exists: URL"). A broker `pr_create`
/// tool call (`is_pr_create_tool`) counts the same way, with the URL its JSON answer names.
fn track(calls: &mut HashMap<String, Option<String>>, update: &Value) -> Option<String> {
    let id = update.get("toolCallId").and_then(Value::as_str)?;
    let execute = update.get("kind").and_then(Value::as_str) == Some("execute");
    if execute && script(update).is_some_and(|s| is_gh_pr_create(&s))
        || tool_name(update).is_some_and(is_pr_create_tool)
    {
        calls.entry(id.to_owned()).or_default();
    }
    let printed = calls.get_mut(id)?;
    if let Some(url) = created_url(&output_text(update)) {
        *printed = Some(url);
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
#[path = "pull_requests_tests.rs"]
mod tests;
