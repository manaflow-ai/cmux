//! `cmux chat cd SESSION (DIR | --repo OWNER/NAME [--ref REF])`: point a Cloud chat that already
//! runs at another folder or repository on its machine, the chat's `/cd` from a terminal (Leo,
//! 2026-11-09: "how can he point its folder at a different thing?"). Before this only a new chat
//! got a folder (`cmux chat --cwd`, `cmux cloud start-chat --cwd`, or an Environment).
//!
//! It runs on the chat's machine through the app's own `cloud exec`, as `cmux chat send` does
//! (cloud_start_chat.rs), and reuses what the machine already has:
//!
//! 1. The folder. `DIR` must be a folder there (`~` is the machine user's home). `--repo` is the
//!    chat's Add repository (`cmux cloud repo add` against the machine's own daemon, session
//!    `cloud`; cmux-tui-core `cloud_repos`): the machine clones it into `~/chats/SESSION/NAME`
//!    with the GitHub access it already has, and says
//!    `repo.needs_github` when it has none. A clone outlasts one `cloud exec`, so it runs in the
//!    background on the machine and each later exec asks whether it ended.
//! 2. The chat. `acp session fork SESSION --cwd FOLDER` on the machine: a new session with the
//!    chat's conversation so far, its agent started in the folder with that folder's own
//!    instructions (acpmux `hub/fork.rs`). The old chat stays as it was.
//!
//! The answer names the new `session_id` (its next prompt: `cmux chat send NEW ...`) and the
//! command that starts a new chat in the same folder. The chat is found as `cmux chat send` finds
//! it: `--on vm:ID|NAME`, else the app's workspace that shows its tab.

#[cfg(test)]
mod tests;

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::chat_send::{self, Place};
use super::cloud_start_chat::{self, GUEST_PRELUDE, Runner, sections, shell_quote};
use super::{OutputMode, UsageError};

pub(super) const USAGE: &str = "\
usage: cmux chat cd SESSION DIR [--on vm:ID|NAME] [--json]
       cmux chat cd SESSION --repo OWNER/NAME [--ref REF] [--on vm:ID|NAME] [--timeout SECONDS] [--json]

Points the Cloud chat SESSION at another folder or repository on its machine. The chat goes on
there as a new session with the conversation so far (the old one stays as it was); its next
prompt goes to the session_id this answers.

  DIR                A folder on the machine: absolute, or ~/PATH
  --repo REPO        Clone REPO (OWNER/NAME, or a name your GitHub access lists) into
                     ~/chats/SESSION/NAME on the machine, with the access it already has
  --ref REF          The branch, tag or commit to check out (with --repo)
  --on vm:ID|NAME    The chat's machine, when the app does not show the chat
  --timeout SECONDS  How long the clone may take (default 600)

  cmux chat cd s-1 ~/work/api
  cmux chat cd s-1 --repo acme/api --ref main --json
";

/// This command's flags that take the next word as their value.
const TAKES_VALUE: &[&str] = &["--on", "--repo", "--ref", "--timeout"];

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(600);
const MAX_TIMEOUT: Duration = Duration::from_secs(60 * 60);
/// The pause between two asks whether the machine's clone ended.
// timeout: not a deadline, the pause between two polls; the clone itself is bounded by --timeout.
const POLL_PAUSE: Duration = Duration::from_secs(3);

/// Where the chat goes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Folder {
    /// A folder on the machine, as typed (`/abs`, `~` or `~/path`).
    Dir(String),
    /// A repository the machine clones for the chat.
    Repo { repo: String, reference: Option<String> },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Cd {
    pub session: String,
    pub folder: Folder,
    pub on: Option<String>,
    pub timeout: Duration,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Parsed {
    Help,
    Run(Cd),
}

/// `Some(exit code)` when `args` is `chat cd …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command) = super::parse_globals(args).ok()?;
    let [scope, verb, rest @ ..] = command.as_slice() else { return None };
    if scope != "chat" || verb != "cd" {
        return None;
    }
    let words = cloud_start_chat::lift_output_of(rest, &mut global.output, TAKES_VALUE);
    let cd = match parse(&words) {
        Ok(Parsed::Help) => {
            print!("{USAGE}");
            return Some(0);
        }
        Ok(Parsed::Run(cd)) => cd,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}\n{USAGE}", error.0),
                global.output,
                2,
            ));
        }
    };
    let place = chat_send::locate(
        &cd.session,
        cd.on.as_deref(),
        || chat_send::topology(&global),
        || cloud_start_chat::app_machines(&global),
    );
    let outcome = match place {
        Ok(Place::Vm(machine)) => run(&mut cloud_start_chat::self_runner(&global), &cd, &machine),
        Ok(Place::Here) => Err(refusal(
            "chat_cd.not_cloud",
            format!("the app shows no Cloud VM for chat {}", cd.session),
            &format!(
                "give --on vm:ID|NAME for a Cloud chat; a chat on this machine forks into a folder with `cmux acp session fork {} --cwd DIR`",
                cd.session
            ),
        )),
        Err(error) => Err(error),
    };
    Some(report(&outcome, global.output))
}

/// The words after `chat cd`.
pub(super) fn parse(words: &[String]) -> Result<Parsed, UsageError> {
    let mut session = None;
    let mut dir = None;
    let mut repo = None;
    let mut reference = None;
    let mut on = None;
    let mut timeout = DEFAULT_TIMEOUT;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, inline)) if flag.starts_with("--") => (flag, Some(inline)),
            _ => (word.as_str(), None),
        };
        let mut take = || match inline {
            Some(inline) => Ok(inline.to_owned()),
            None => words
                .next()
                .cloned()
                .ok_or_else(|| UsageError::new(format!("{flag} needs a value"))),
        };
        match flag {
            "-h" | "--help" => return Ok(Parsed::Help),
            "--on" => on = Some(take()?),
            "--repo" => repo = Some(take()?),
            "--ref" => reference = Some(take()?),
            "--timeout" => {
                let text = take()?;
                let seconds = text.parse::<u64>().ok().filter(|seconds| *seconds > 0);
                let seconds = seconds.ok_or_else(|| {
                    UsageError::new(format!("--timeout takes seconds, not {text}"))
                })?;
                timeout = Duration::from_secs(seconds).min(MAX_TIMEOUT);
            }
            _ if word.starts_with('-') => {
                return Err(UsageError::new(format!("unknown flag {word}")));
            }
            _ if session.is_none() => session = Some(word.clone()),
            _ if dir.is_none() => dir = Some(word.clone()),
            _ => return Err(UsageError::new(format!("unexpected argument {word:?}"))),
        }
    }
    let session = session.ok_or_else(|| UsageError::new("name the chat: its SESSION id"))?;
    if !plain(&session) || session.contains('/') {
        return Err(UsageError::new(format!("{session:?} is no session id")));
    }
    let folder = match (dir, repo) {
        (Some(_), Some(_)) => return Err(UsageError::new("give DIR or --repo, not both")),
        (None, None) => return Err(UsageError::new("give the folder: DIR, or --repo OWNER/NAME")),
        (Some(_), None) if reference.is_some() => {
            return Err(UsageError::new("--ref goes with --repo"));
        }
        (Some(dir), None) => {
            if !(dir.starts_with('/') || dir == "~" || dir.starts_with("~/"))
                || dir.chars().any(char::is_control)
            {
                return Err(UsageError::new(format!(
                    "{dir}: a folder on the machine, absolute or ~/PATH"
                )));
            }
            Folder::Dir(dir)
        }
        (None, Some(repo)) => {
            if !plain(&repo) {
                return Err(UsageError::new(format!("--repo {repo:?}: OWNER/NAME")));
            }
            if let Some(reference) = &reference
                && !plain(reference)
            {
                return Err(UsageError::new(format!(
                    "--ref {reference:?}: a branch, tag or commit"
                )));
            }
            Folder::Repo { repo, reference }
        }
    };
    Ok(Parsed::Run(Cd { session, folder, on, timeout }))
}

/// One word for the machine: not empty, no flag, no space or control character.
fn plain(word: &str) -> bool {
    !word.is_empty()
        && word.len() <= 1024
        && !word.starts_with('-')
        && !word.chars().any(|ch| ch.is_whitespace() || ch.is_control())
}

/// The move on `machine`: the folder, then the fork. The answer, or the error object.
pub(super) fn run(runner: &mut dyn Runner, cd: &Cd, machine: &str) -> Result<Value, Value> {
    let began = runner.now();
    let (folder, repo) = match &cd.folder {
        Folder::Dir(dir) => (folder_of(runner, machine, dir)?, None),
        Folder::Repo { repo, reference } => {
            let attached =
                clone(runner, machine, &cd.session, repo, reference.as_deref(), began, cd.timeout)?;
            let folder = attached.get("folder").and_then(Value::as_str).map(str::to_owned);
            let folder = folder.ok_or_else(|| {
                failure(
                    "chat_cd.repo_failed",
                    "the machine's Add repository answered no folder".to_owned(),
                    json!({"answer": attached}),
                )
            })?;
            (folder, Some(attached))
        }
    };
    let session = fork(runner, machine, &cd.session, &folder)?;
    let mut follow_up = cloud_start_chat::follow_ups(machine, &session);
    if let Some(map) = follow_up.as_object_mut() {
        map.insert(
            "new_chat".to_owned(),
            json!(format!(
                "cmux cloud start-chat --target machine:{machine} --cwd {} --prompt 'PROMPT'",
                shell_quote(&folder)
            )),
        );
    }
    let mut answer = json!({
        "machine_id": machine,
        "target": format!("machine:{machine}"),
        "session_id": session,
        "forked_from": cd.session,
        "cwd": folder,
        "follow_up": follow_up,
    });
    if let (Some(repo), Some(map)) = (repo, answer.as_object_mut()) {
        map.insert("repo".to_owned(), repo);
    }
    Ok(answer)
}

/// `dir` on the machine, resolved: it must be a folder there.
fn folder_of(runner: &mut dyn Runner, machine: &str, dir: &str) -> Result<String, Value> {
    let script = format!(
        "{GUEST_PRELUDE}d={}; case \"$d\" in \"~\") d=\"$HOME\" ;; \"~/\"*) d=\"$HOME/${{d#\"~/\"}}\" ;; esac; \
         if [ -d \"$d\" ]; then echo @@folder; cd \"$d\" && pwd -P; else echo @@missing; fi",
        shell_quote(dir)
    );
    let stdout = cloud_start_chat::exec(runner, machine, &script)?;
    match sections(&stdout).get("folder").map(|folder| folder.trim()) {
        Some(folder) if folder.starts_with('/') => Ok(folder.to_owned()),
        _ => Err(failure(
            "chat_cd.not_a_folder",
            format!("{dir} is no folder on machine:{machine}"),
            json!({"dir": dir, "next": format!("cmux cloud files-list --target machine:{machine} --path /")}),
        )),
    }
}

/// The machine's Add repository for chat `session`, run in the background there, asked after
/// until it ends or `timeout` from `began` passes. Its answer: the attached repository.
fn clone(
    runner: &mut dyn Runner,
    machine: &str,
    session: &str,
    repo: &str,
    reference: Option<&str>,
    began: Instant,
    timeout: Duration,
) -> Result<Value, Value> {
    let job = job_file(session, repo, reference);
    let words = guest_repo_add(session, repo, reference);
    let add = std::iter::once("\"$1\"".to_owned())
        .chain(words.iter().map(|word| shell_quote(word)))
        .collect::<Vec<_>>()
        .join(" ");
    let body = format!("{add} > \"$2.tmp\" 2>&1; mv -f \"$2.tmp\" \"$2\"; rm -f \"$2.pid\"");
    // One clone at a time for this chat and repository: a run again while it clones asks after it.
    let start = format!(
        "{GUEST_PRELUDE}umask 077; r=\"$HOME/.cmux/chat-cd\"; mkdir -p \"$r\" && o=\"$r/\"{job}; \
         if [ -f \"$o\" ]; then :; elif [ -f \"$o.pid\" ] && kill -0 \"$(cat \"$o.pid\")\" 2>/dev/null; then :; \
         else printf '%s\\n' {body} > \"$o.sh\" && s=; command -v setsid >/dev/null 2>&1 && s=setsid; \
         $s nohup sh \"$o.sh\" \"$c\" \"$o\" </dev/null >/dev/null 2>&1 & echo $! > \"$o.pid\"; fi; echo @@started",
        job = shell_quote(&job),
        body = shell_quote(&body),
    );
    let stdout = cloud_start_chat::exec(runner, machine, &start)?;
    if !sections(&stdout).contains_key("started") {
        return Err(failure(
            "chat_cd.repo_failed",
            "the machine did not start the clone".to_owned(),
            json!({"stdout": stdout}),
        ));
    }
    let ask = format!(
        "{GUEST_PRELUDE}o=\"$HOME/.cmux/chat-cd/\"{job}; \
         if [ -f \"$o\" ]; then echo @@done; cat \"$o\"; echo; rm -f \"$o\" \"$o.sh\"; \
         elif [ -f \"$o.pid\" ] && kill -0 \"$(cat \"$o.pid\")\" 2>/dev/null; then echo @@running; else echo @@lost; fi",
        job = shell_quote(&job),
    );
    loop {
        let stdout = cloud_start_chat::exec(runner, machine, &ask)?;
        let found = sections(&stdout);
        if let Some(done) = found.get("done") {
            return attached(done);
        }
        if found.contains_key("lost") {
            return Err(failure(
                "chat_cd.repo_lost",
                "the clone on the machine stopped without an answer".to_owned(),
                json!({"next": "run the same command again"}),
            ));
        }
        if runner.now().saturating_duration_since(began) >= timeout {
            return Err(failure(
                "chat_cd.repo_pending",
                format!("the clone still runs after {} s", timeout.as_secs()),
                json!({"next": "run the same command again: it asks after the same clone"}),
            ));
        }
        runner.pause(POLL_PAUSE);
    }
}

/// The session of the machine's own daemon, which owns Add repository (cmux-tui-core
/// `cloud_repos`): the image starts `cmux-tui server start --session cloud`, and the guest's `cmux`
/// shim runs `cmux-tui --session cloud`. A bare `cmux-tui` reaches session `main`, which no Cloud
/// machine runs, and its `cloud repo add` answers `repo.unavailable`.
pub(super) const GUEST_DAEMON_SESSION: &str = "cloud";

/// The words after the machine's `cmux-tui` for Add repository of `repo` in chat `session`.
pub(super) fn guest_repo_add(session: &str, repo: &str, reference: Option<&str>) -> Vec<String> {
    let mut words =
        vec!["--session", GUEST_DAEMON_SESSION, "cloud", "repo", "add", "--session", session];
    words.extend(["--repo", repo]);
    if let Some(reference) = reference {
        words.extend(["--ref", reference]);
    }
    words.into_iter().map(str::to_owned).collect()
}

/// The machine's file for one clone: the chat, the repository and the ref, as one safe name.
fn job_file(session: &str, repo: &str, reference: Option<&str>) -> String {
    let raw = format!("{session}--{repo}--{}", reference.unwrap_or(""));
    raw.chars()
        .map(|ch| if ch.is_ascii_alphanumeric() || "-_.".contains(ch) { ch } else { '_' })
        .collect()
}

/// `cloud repo add`'s answer: the attached repository, or its refusal (`code`, `message`, and
/// for `repo.needs_github` the link that connects GitHub).
fn attached(text: &str) -> Result<Value, Value> {
    let value = text.lines().rev().find_map(|line| serde_json::from_str::<Value>(line.trim()).ok());
    match value {
        Some(value) if value.get("code").is_some() => {
            let code = value.get("code").and_then(Value::as_str).unwrap_or("chat_cd.repo_failed");
            let message =
                value.get("message").and_then(Value::as_str).unwrap_or("the clone failed");
            Err(failure(code, message.to_owned(), json!({"answer": value})))
        }
        Some(value) if value.is_object() => Ok(value),
        _ => Err(failure(
            "chat_cd.repo_failed",
            "the machine's Add repository failed".to_owned(),
            json!({"output": text.trim()}),
        )),
    }
}

/// `acp session fork SESSION --cwd FOLDER` on the machine: the new session's id.
fn fork(
    runner: &mut dyn Runner,
    machine: &str,
    session: &str,
    folder: &str,
) -> Result<String, Value> {
    let script = format!(
        "{GUEST_PRELUDE}echo @@fork; \"$c\" acp session fork {} --cwd {} --json 2>&1; echo \"@@exit $?\"",
        shell_quote(session),
        shell_quote(folder)
    );
    let stdout = cloud_start_chat::exec(runner, machine, &script)?;
    let found = sections(&stdout);
    let text = found.get("fork").map_or("", String::as_str);
    let new = text
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
        .and_then(|value| value.get("sessionId").and_then(Value::as_str).map(str::to_owned));
    match new {
        Some(new) if found.get("exit").map(|code| code.trim()) == Some("0") => Ok(new),
        _ => Err(failure(
            "chat_cd.fork_failed",
            format!(
                "chat {session} did not go on in {folder}: {}",
                super::wire::sanitize_remote_text(text.trim())
            ),
            json!({"folder": folder}),
        )),
    }
}

fn failure(code: &str, message: String, details: Value) -> Value {
    json!({"code": code, "message": message, "details": details, "retryable": false})
}

/// A refusal whose message and `details.next` say what to run next.
fn refusal(code: &str, message: String, next: &str) -> Value {
    json!({"code": code, "message": format!("{message}; {next}"), "details": {"next": next},
           "retryable": false})
}

fn report(outcome: &Result<Value, Value>, output: OutputMode) -> i32 {
    match outcome {
        Err(error) => super::wire::print_local_error(error, output, 1),
        Ok(answer) if output == OutputMode::Human => {
            let text = |key: &str| answer.get(key).and_then(Value::as_str).unwrap_or_default();
            println!(
                "{} goes on in {} as {} on machine:{}.",
                text("forked_from"),
                text("cwd"),
                text("session_id"),
                text("machine_id")
            );
            eprintln!("next prompt: cmux chat send {} 'PROMPT' --wait", text("session_id"));
            0
        }
        Ok(answer) => super::wire::print_local_success(answer, output),
    }
}
