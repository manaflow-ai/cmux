//! `cmux automation events [NAME]`: the named events `--when` takes
//! (`cmux_automations::events`), and each one's live source.
//!
//! With no name it lists them. With a name it prints one JSON line per
//! event as it happens, until stopped: the runner keeps exactly this command
//! alive for an automation made with `--when NAME`, so a person can run it to
//! see what an automation would see.
//!
//! - `agent-idle`, `agent-needs-input`: `cmux agents events` read in a loop
//!   ([`super::super::agents::follow_events`]): terminal agents are pushed by
//!   the daemon; agent chats and permission prompts come from the app's state.
//! - `pr-opened`: nothing pushes GitHub changes to cmux, so `gh search prs`
//!   every [`PR_POLL_SECONDS`] (the GitHub pull requests signal's own pace),
//!   and a line for each pull request not in the first read.

use std::collections::HashSet;
use std::io::Write as _;
use std::time::Duration;

use cmux_automations::events::{EVENTS, EventKind, find, names};
use serde_json::{Value, json};

use super::super::OutputMode;
use super::{Args, Out, Outcome, messages, usage};

/// How often `pr-opened` reads GitHub: the `github.pulls` signal's default
/// pace (cmux-app-host signals.json), never faster.
const PR_POLL_SECONDS: u64 = 300;

/// The automation runs' own sessions (`auto-<id>-<run>`): an event they make
/// never starts another run, so a run cannot fire itself.
const OWN_SESSION_PREFIX: &str = "auto-";

pub(super) fn run(args: &[String], global: &super::super::GlobalArgs, out: &Out) -> Outcome {
    let a = Args::parse(args, &[], &[])?;
    match a.words.as_slice() {
        [] => list(out),
        [name] => {
            let Some(kind) = find(name) else {
                return usage(
                    messages().unknown_event.replace("{value}", name).replace("{names}", &names()),
                );
            };
            // A stream never ends, so it has no MCP answer: `automation_events` lists only.
            if out.captured.is_some() {
                return usage(messages().events_stream_shell_only);
            }
            follow(kind, global)
        }
        [_, extra, ..] => usage(messages().unexpected_argument.replace("{value}", extra)),
    }
}

fn row_json(e: &EventKind) -> Value {
    json!({
        "name": e.name,
        "label": e.label,
        "summary": e.summary,
        "source": e.source,
        "debounce_seconds": e.debounce_seconds,
        "cooldown_seconds": e.cooldown_seconds,
        "max_runs_per_day": e.max_runs_per_day,
        "sample": serde_json::from_str::<Value>(e.sample).unwrap_or(Value::Null),
    })
}

fn list(out: &Out) -> Outcome {
    if out.mode == OutputMode::Json {
        out.value(&json!({ "events": EVENTS.iter().map(row_json).collect::<Vec<_>>() }));
        return Ok(0);
    }
    if out.mode == OutputMode::Quiet {
        return Ok(0);
    }
    for e in EVENTS {
        println!("  {:<19} {}", e.name, e.summary);
    }
    println!("\n{}", messages().events_hint);
    Ok(0)
}

/// One event line on stdout, flushed so the runner sees it at once. Answers
/// whether stdout is still open.
fn emit(line: &Value) -> bool {
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{line}").and_then(|()| stdout.flush()).is_ok()
}

fn follow(kind: &EventKind, global: &super::super::GlobalArgs) -> Outcome {
    let result = match kind.name {
        "agent-idle" => agent_events(kind, global, "agent", &|e| {
            matches!(e["state"].as_str(), Some("idle" | "done"))
        }),
        "agent-needs-input" => {
            agent_events(kind, global, "agent,dialog", &|e| match e["kind"].as_str() {
                Some("dialog") => e["change"] == "opened",
                Some("agent") => matches!(e["state"].as_str(), Some("blocked" | "input")),
                _ => false,
            })
        }
        "pr-opened" => pull_requests(),
        _ => Err(json!({"code": "automation.failed", "message": "no source for this event"})),
    };
    match result {
        Ok(()) => Ok(0),
        Err(error) => {
            let message =
                error.get("message").and_then(Value::as_str).unwrap_or("the event source failed");
            eprintln!("cmux: {}: {message}", kind.name);
            Ok(1)
        }
    }
}

/// `cmux agents events --kind KINDS`, one line per event `keep` takes, the
/// automation runs' own sessions left out.
fn agent_events(
    kind: &EventKind,
    global: &super::super::GlobalArgs,
    kinds: &str,
    keep: &dyn Fn(&Value) -> bool,
) -> Result<(), Value> {
    super::super::agents::follow_events(global, kinds, &mut |event| {
        if !keep(event) || own_run(event) {
            return true;
        }
        emit(&tagged(kind, event))
    })
}

/// Whether `event` is an automation run's own session.
fn own_run(event: &Value) -> bool {
    ["agent_session", "session", "name"]
        .iter()
        .filter_map(|field| event[*field].as_str())
        .any(|name| name.starts_with(OWN_SESSION_PREFIX))
}

/// `event` with `"event": NAME`, so a condition script can tell sources apart.
fn tagged(kind: &EventKind, event: &Value) -> Value {
    let mut line = serde_json::Map::new();
    line.insert("event".into(), json!(kind.name));
    if let Value::Object(fields) = event {
        for (k, v) in fields {
            if k != "event" {
                line.insert(k.clone(), v.clone());
            }
        }
    }
    Value::Object(line)
}

/// The person's open pull requests, newest first, as `gh` reads them.
fn read_pull_requests() -> Result<Vec<Value>, Value> {
    let output = cmux_process::Command::new("gh")
        .args([
            "search",
            "prs",
            "--author=@me",
            "--state=open",
            "--sort=created",
            "--order=desc",
            "--limit=30",
            "--json=url,title,number,repository,isDraft,createdAt",
        ])
        .stdin(cmux_process::Stdio::null())
        .output()
        .map_err(
            |e| json!({"message": format!("gh: {e}; install GitHub's gh and run `gh auth login`")}),
        )?;
    if !output.status.success() {
        let why = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(json!({"message": format!("gh search prs failed: {why}")}));
    }
    serde_json::from_slice::<Vec<Value>>(&output.stdout)
        .map_err(|e| json!({"message": format!("gh search prs: {e}")}))
}

/// The line for one pull request `gh` listed.
pub(super) fn pull_request_line(pr: &Value) -> Value {
    json!({
        "event": "pr-opened",
        "url": pr["url"],
        "repo": pr.pointer("/repository/nameWithOwner"),
        "number": pr["number"],
        "title": pr["title"],
        "draft": pr["isDraft"],
        "created_at": pr["createdAt"],
    })
}

/// What `pr-opened` has seen: each pull request's url, and the newest
/// creation time. Only one created at or after that time is new, so an old
/// pull request that moves into the 30 `gh` lists when a newer one closes
/// starts nothing.
#[derive(Default)]
pub(super) struct SeenPullRequests {
    urls: HashSet<String>,
    newest: String,
}

/// The pull requests in `now` that are new to `seen` (and marks them seen), oldest first.
pub(super) fn new_pull_requests(seen: &mut SeenPullRequests, now: &[Value]) -> Vec<Value> {
    let since = seen.newest.clone();
    let mut fresh: Vec<Value> = now
        .iter()
        .filter(|pr| {
            // RFC 3339 times in UTC (`gh` writes `...Z`) order as text.
            let created = pr["createdAt"].as_str().unwrap_or("");
            created >= since.as_str()
                && pr["url"].as_str().is_some_and(|url| seen.urls.insert(url.to_string()))
        })
        .map(pull_request_line)
        .collect();
    for pr in now {
        if let Some(created) = pr["createdAt"].as_str()
            && created > seen.newest.as_str()
        {
            seen.newest = created.to_string();
        }
    }
    fresh.reverse();
    fresh
}

fn pull_requests() -> Result<(), Value> {
    // The first read is what is already open: no event for it.
    let mut seen = SeenPullRequests::default();
    new_pull_requests(&mut seen, &read_pull_requests()?);
    loop {
        std::thread::sleep(Duration::from_secs(PR_POLL_SECONDS));
        match read_pull_requests() {
            Ok(now) => {
                for line in new_pull_requests(&mut seen, &now) {
                    if !emit(&line) {
                        return Ok(());
                    }
                }
            }
            // A failed read (offline, rate limited) waits for the next one.
            Err(error) => eprintln!(
                "cmux: pr-opened: {}",
                error.get("message").and_then(Value::as_str).unwrap_or("")
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pull_request_is_an_event_once_and_only_after_the_first_read() {
        let pr = |n: u64| {
            json!({"url": format!("https://github.com/o/r/pull/{n}"), "number": n, "title": format!("t{n}"),
                   "repository": {"nameWithOwner": "o/r"}, "isDraft": false,
                   "createdAt": format!("2026-11-10T00:00:0{n}Z")})
        };
        let mut seen = SeenPullRequests::default();
        assert_eq!(new_pull_requests(&mut seen, &[pr(3), pr(2)]).len(), 2, "the baseline read");
        assert!(new_pull_requests(&mut seen, &[pr(3), pr(2)]).is_empty());
        let fresh = new_pull_requests(&mut seen, &[pr(5), pr(4), pr(3)]);
        let numbers: Vec<_> = fresh.iter().map(|l| l["number"].as_u64().unwrap()).collect();
        assert_eq!(numbers, [4, 5], "oldest first");
        assert_eq!(fresh[0]["event"], "pr-opened");
        assert_eq!(fresh[0]["repo"], "o/r");
        // #5 closes and #1, older than anything seen, moves into the window.
        assert!(new_pull_requests(&mut seen, &[pr(4), pr(3), pr(1)]).is_empty());
    }

    #[test]
    fn an_automation_runs_own_session_starts_nothing() {
        assert!(own_run(&json!({"agent_session": "auto-auto_abc-run_x", "state": "idle"})));
        assert!(!own_run(&json!({"agent_session": "fix-login", "state": "idle"})));
        assert!(!own_run(&json!({"state": "idle"})));
    }

    #[test]
    fn an_event_line_names_its_event() {
        let kind = find("agent-idle").unwrap();
        let line = tagged(kind, &json!({"kind": "agent", "state": "idle"}));
        assert_eq!(line, json!({"event": "agent-idle", "kind": "agent", "state": "idle"}));
    }

    #[test]
    fn every_event_has_a_source_here() {
        // A row added to the vocabulary without a source here would print
        // "no source": this names the arms `follow` matches.
        for e in EVENTS {
            assert!(
                matches!(e.name, "agent-idle" | "agent-needs-input" | "pr-opened"),
                "{} has no source in cli/automation/events.rs",
                e.name
            );
        }
    }
}
