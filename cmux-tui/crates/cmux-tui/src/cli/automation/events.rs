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
//!   in every state from a creation-time cursor, and a line for each pull
//!   request created since the source started.

use std::collections::{HashMap, HashSet};
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
    let mut own = OwnSessions::new(Box::new(acpmux_session_name));
    super::super::agents::follow_events(global, kinds, &mut |event| match line_for(
        kind, event, keep, &mut own,
    ) {
        Some(line) => emit(&line),
        None => true,
    })
}

/// The line `event` makes, or none when `keep` drops it or it is an
/// automation run's own session.
fn line_for(
    kind: &EventKind,
    event: &Value,
    keep: &dyn Fn(&Value) -> bool,
    own: &mut OwnSessions,
) -> Option<Value> {
    (keep(event) && !own.is_own(event)).then(|| tagged(kind, event))
}

/// The fields of an event that name its session (`auto-...` for a run's own).
const SESSION_NAME_FIELDS: [&str; 3] = ["session", "name", "session_name"];
/// The fields that carry its acpmux session id: a chat's or a dialog's event
/// carries the id, not the `auto-...` name, so the id is looked up.
const SESSION_ID_FIELDS: [&str; 2] = ["agent_session", "session_id"];

/// Names an acpmux session id, when one is known.
type SessionLookup = Box<dyn FnMut(&str) -> Option<String>>;

/// Which sessions are automation runs' own (`auto-<id>-<run>`), each id
/// looked up once.
struct OwnSessions {
    lookup: SessionLookup,
    known: HashMap<String, bool>,
}

impl OwnSessions {
    fn new(lookup: SessionLookup) -> OwnSessions {
        OwnSessions { lookup, known: HashMap::new() }
    }

    fn is_own(&mut self, event: &Value) -> bool {
        let own_name = |name: &str| name.starts_with(OWN_SESSION_PREFIX);
        if SESSION_NAME_FIELDS
            .iter()
            .chain(&SESSION_ID_FIELDS)
            .filter_map(|f| event[*f].as_str())
            .any(own_name)
        {
            return true;
        }
        SESSION_ID_FIELDS.iter().filter_map(|f| event[*f].as_str()).any(|id| {
            if let Some(own) = self.known.get(id) {
                return *own;
            }
            let own = (self.lookup)(id).is_some_and(|name| own_name(&name));
            self.known.insert(id.to_string(), own);
            own
        })
    }
}

/// The name of acpmux session `id` (`acpmux info ID --json`), when acpmux
/// knows it.
fn acpmux_session_name(id: &str) -> Option<String> {
    let output = cmux_process::Command::new(cmux_automations::exec::acpmux())
        .args(["info", id, "--json"])
        .stdin(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let info: Value = serde_json::from_slice(&output.stdout).ok()?;
    info["name"].as_str().map(str::to_owned)
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

/// The person's pull requests created at or after `since` (`YYYY-MM-DDTHH:MM:SSZ`),
/// in every state: one opened and closed or merged between two reads is still
/// an opening. Oldest first.
fn read_pull_requests(since: &str) -> Result<Vec<Value>, Value> {
    let created = format!("--created=>={since}");
    let output = cmux_process::Command::new("gh")
        .args([
            "search",
            "prs",
            "--author=@me",
            created.as_str(),
            "--sort=created",
            "--order=asc",
            "--limit=100",
            "--json=url,title,number,repository,isDraft,state,createdAt",
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
        "state": pr["state"].as_str().map(str::to_lowercase),
        "created_at": pr["createdAt"],
    })
}

/// Where `pr-opened` has read up to: the newest creation time seen (the next
/// read's `--created` cursor), and the pull requests created at that time,
/// so one is never an event twice.
pub(super) struct PullRequestCursor {
    pub(super) since: String,
    at_since: HashSet<String>,
}

impl PullRequestCursor {
    /// A cursor at `since`: pull requests created before it are not new.
    pub(super) fn at(since: String) -> PullRequestCursor {
        PullRequestCursor { since, at_since: HashSet::new() }
    }

    /// The pull requests in `now` that are new (and moves the cursor past
    /// them), oldest first.
    pub(super) fn advance(&mut self, now: &[Value]) -> Vec<Value> {
        let mut fresh: Vec<&Value> = now
            .iter()
            .filter(|pr| {
                // RFC 3339 times in UTC (`gh` writes `...Z`) order as text.
                let created = pr["createdAt"].as_str().unwrap_or("");
                let url = pr["url"].as_str().unwrap_or("");
                created >= self.since.as_str()
                    && !url.is_empty()
                    && !(created == self.since && self.at_since.contains(url))
            })
            .collect();
        fresh.sort_by(|a, b| a["createdAt"].as_str().cmp(&b["createdAt"].as_str()));
        for pr in &fresh {
            let (created, url) =
                (pr["createdAt"].as_str().unwrap_or(""), pr["url"].as_str().unwrap_or(""));
            if created > self.since.as_str() {
                self.since = created.to_string();
                self.at_since.clear();
            }
            self.at_since.insert(url.to_string());
        }
        fresh.into_iter().map(pull_request_line).collect()
    }
}

/// Now in UTC to the second, as `gh` and GitHub search write times.
fn utc_now() -> String {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX));
    let c = cmux_automations::Zone::Utc.civil(t);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        c.year,
        c.month,
        c.day,
        c.hour,
        c.minute,
        t.rem_euclid(60)
    )
}

fn pull_requests() -> Result<(), Value> {
    // Pull requests created before the source started are not new.
    let mut cursor = PullRequestCursor::at(utc_now());
    loop {
        std::thread::sleep(Duration::from_secs(PR_POLL_SECONDS));
        match read_pull_requests(&cursor.since) {
            Ok(now) => {
                for line in cursor.advance(&now) {
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
    fn a_pull_request_opened_after_the_start_is_an_event_once_in_any_state() {
        let pr = |n: u64, state: &str| {
            json!({"url": format!("https://github.com/o/r/pull/{n}"), "number": n, "title": format!("t{n}"),
                   "repository": {"nameWithOwner": "o/r"}, "isDraft": false, "state": state,
                   "createdAt": format!("2026-11-10T00:00:{n:02}Z")})
        };
        let mut cursor = PullRequestCursor::at("2026-11-10T00:00:03Z".into());
        // #2 is older than the start; #3 opened in the start's second.
        let fresh = cursor.advance(&[pr(2, "OPEN"), pr(3, "OPEN")]);
        assert_eq!(fresh.iter().map(|l| l["number"].as_u64().unwrap()).collect::<Vec<_>>(), [3]);
        assert!(cursor.advance(&[pr(3, "OPEN")]).is_empty(), "never twice");
        // #4 opened and merged between two reads, #5 still open: both, oldest first.
        let fresh = cursor.advance(&[pr(5, "OPEN"), pr(4, "MERGED"), pr(3, "CLOSED")]);
        let numbers: Vec<_> = fresh.iter().map(|l| l["number"].as_u64().unwrap()).collect();
        assert_eq!(numbers, [4, 5]);
        assert_eq!(fresh[0]["state"], "merged");
        assert_eq!(fresh[0]["event"], "pr-opened");
        assert_eq!(fresh[0]["repo"], "o/r");
        assert_eq!(cursor.since, "2026-11-10T00:00:05Z", "the next read starts at the newest");
        assert!(cursor.advance(&[pr(5, "CLOSED")]).is_empty());
    }

    #[test]
    fn the_cursor_is_a_utc_time_to_the_second() {
        let now = utc_now();
        assert_eq!(now.len(), "2026-11-10T00:00:00Z".len(), "{now}");
        assert!(now.ends_with('Z') && now.as_bytes()[10] == b'T', "{now}");
    }

    fn own_sessions(
        names: &[(&'static str, &'static str)],
    ) -> (OwnSessions, std::rc::Rc<std::cell::Cell<u32>>) {
        let names = names.to_vec();
        let lookups = std::rc::Rc::new(std::cell::Cell::new(0));
        let counter = lookups.clone();
        let lookup = move |id: &str| {
            counter.set(counter.get() + 1);
            names.iter().find(|(known, _)| *known == id).map(|(_, name)| (*name).to_string())
        };
        (OwnSessions::new(Box::new(lookup)), lookups)
    }

    #[test]
    fn an_automation_runs_own_session_starts_nothing() {
        let (mut own, _) = own_sessions(&[]);
        assert!(own.is_own(&json!({"agent_session": "auto-auto_abc-run_x", "state": "idle"})));
        assert!(own.is_own(&json!({"session_name": "auto-auto_abc-run_x"})));
        assert!(!own.is_own(&json!({"agent_session": "fix-login", "state": "idle"})));
        assert!(!own.is_own(&json!({"state": "idle"})));
    }

    #[test]
    fn an_automations_own_chat_finishing_fires_nothing() {
        // A run is `acpmux run -n auto-...`; its chat's event carries the
        // session's id, which acpmux names.
        let (mut own, lookups) =
            own_sessions(&[("5f0c-run", "auto-auto_abc-run_x"), ("77aa-person", "fix-login")]);
        let idle = find("agent-idle").unwrap();
        let keep = |e: &Value| matches!(e["state"].as_str(), Some("idle" | "done"));
        let chat = |id: &str| json!({"kind": "agent", "change": "state", "source": "chat", "state": "idle", "agent_session": id});
        assert_eq!(
            line_for(idle, &chat("5f0c-run"), &keep, &mut own),
            None,
            "the run's own completion"
        );
        assert_eq!(line_for(idle, &chat("5f0c-run"), &keep, &mut own), None);
        assert_eq!(lookups.get(), 1, "each id is looked up once");
        let line =
            line_for(idle, &chat("77aa-person"), &keep, &mut own).expect("a person's chat fires");
        assert_eq!(line["event"], "agent-idle");
        // A permission prompt in the run's own chat (`agent-needs-input`).
        let dialog = json!({"kind": "dialog", "change": "opened", "agent_session": "5f0c-run"});
        assert!(own.is_own(&dialog));
        // An id acpmux does not know is someone else's.
        assert!(!own.is_own(&chat("unknown-id")));
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
