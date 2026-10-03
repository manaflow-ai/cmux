//! `cmux task …` verbs. The `cmux` binary mounts `run` for the `task` noun;
//! the standalone `cmux-tasks` binary calls it too. Every verb except the
//! few below comes from the catalog (`cmux_tasks_core::catalog`):
//! - `serve`: run the local owner (socket server).
//! - `catalog [--format json|ts|mcp]`: print the catalog export.
//! - `mine`: `list --mine --open`.
//! - `start KEY [--no-branch]`: assign to me, move to the started status,
//!   create or switch to the git branch `<key>-<slug>`.
//!
//! `KEY` may be `current`: `$CMUX_TASK`, then the task key in the git branch
//! name (`cmx-12-…`). `task watch` takes `--count N` and `--timeout SECONDS`
//! so agents and MCP get a bounded wait.
//!
//! Exit codes of the `task` noun: 0 ok, 1 internal, 2 usage, 3 not found,
//! 4 rejected by the owner (invalid, conflict, forbidden), 5 owner
//! unreachable, 6 idempotency conflict. A failed mutation prints its
//! idempotency key so the caller can retry it safely.

mod args;
mod render;

use std::io::Write;
use std::process::ExitCode;

use cmux_tasks_core::catalog::{self, Class};
use serde_json::{Value, json};

use crate::client::Conn;
use crate::owner::{self, LocalOwner, Owner};
use crate::protocol::{ErrorBody, ErrorCode, ServerLine};

/// The default task key prefix (`CMX-12`).
pub const DEFAULT_PREFIX: &str = "CMX";

fn fail(code: u8, message: &str) -> u8 {
    let _ = writeln!(std::io::stderr(), "cmux task: {message}");
    code
}

fn fail_body(err: &ErrorBody) -> u8 {
    fail(err.code.exit_code(), &err.message)
}

fn help() -> String {
    let mut out =
        String::from("cmux task: the team's tasks\n\n  serve | catalog | mine | start KEY\n");
    for entry in catalog::all() {
        out.push_str(&format!("  {:24} {}\n", entry.cli.trim_start_matches("task "), entry.docs));
    }
    out.push_str("\nGlobal flags: --json --team T --data DIR --idempotency-key K\n");
    out
}

/// Entry point. `args` excludes the program name and may start with `task`.
pub fn run(args: &[String]) -> ExitCode {
    ExitCode::from(run_code(args))
}

/// `run` as a process exit status (the `cmux` binary mounts `cmux task`
/// through this; plans/cmux-next/tasks.md section 14 item 3).
pub fn run_code(args: &[String]) -> u8 {
    let (global, mut words) = match args::split_global(args) {
        Ok(split) => split,
        Err(e) => return fail(2, &e),
    };
    if words.first().map(String::as_str) == Some("task") {
        words.remove(0);
    }
    if words.is_empty() {
        print!("{}", help());
        return if global.help { 0 } else { 2 };
    }
    let owner = match owner::resolve(global.team.as_deref(), global.data.clone()) {
        Ok(Owner::Local(local)) => local,
        Ok(Owner::TeamVm { team }) => {
            return fail(
                5,
                &format!("team {team} lives in its team VM; not reachable from this build"),
            );
        }
        Err(e) => return fail(2, &e),
    };
    let prefix = global.key_prefix.clone().unwrap_or_else(|| DEFAULT_PREFIX.to_owned());
    match words[0].as_str() {
        "serve" => return serve(&owner, &prefix),
        "catalog" => return print_catalog(&words[1..]),
        "mine" => {
            words = [
                vec!["list".to_owned(), "--mine".to_owned(), "--open".to_owned()],
                words[1..].to_vec(),
            ]
            .concat();
        }
        "start" => return start(&owner, &prefix, &global, &words[1..]),
        _ => {}
    }
    let mut path: Vec<&str> = vec!["task"];
    path.extend(words.iter().map(String::as_str));
    let Some((entry, used)) = catalog::find_cli(&path) else {
        return fail(
            2,
            &format!("unknown command `task {}`; see `cmux task --help`", words.join(" ")),
        );
    };
    if global.help {
        print!("{}", args::usage(entry));
        return 0;
    }
    let params = match args::params(entry, &words[used - 1..]) {
        Ok(p) => p,
        Err(e) => return fail(2, &format!("{e}\n\n{}", args::usage(entry))),
    };
    let credential = launch_credential();
    let mut conn = match Conn::open(&owner, credential.as_deref(), &prefix) {
        Ok(conn) => conn,
        Err(e) => return fail_body(&e),
    };
    if entry.class == Class::Stream {
        return watch(&mut conn, params, global.json, global.count, global.timeout);
    }
    let key = (entry.class == Class::Mutation)
        .then(|| global.key.clone().unwrap_or_else(|| owner::mint("idem_")));
    let params = match resolve_current(params) {
        Ok(p) => p,
        Err(e) => return fail(2, &e),
    };
    match conn.call(entry.name, params, key.clone()) {
        Ok((reply, _)) => {
            let text = if global.json {
                format!("{}\n", serde_json::to_string_pretty(&reply).unwrap_or_default())
            } else {
                match entry.name {
                    "task.list" => render::task_list(&reply),
                    "task.get" => render::task_detail(&reply),
                    _ if entry.class == Class::Mutation => render::mutation(entry.name, &reply),
                    _ => format!("{}\n", serde_json::to_string_pretty(&reply).unwrap_or_default()),
                }
            };
            print!("{text}");
            0
        }
        Err(e) => {
            if let Some(key) = key {
                let _ = writeln!(std::io::stderr(), "idempotency key: {key}");
            }
            fail_body(&e)
        }
    }
}

/// `$CMUX_TASK` when set, else the task key in the git branch
/// (`cmx-12-fix-drag` -> `CMX-12`). The owner rejects a key that names no
/// task, so `issue-123-x` fails loudly instead of matching something else.
fn current_task() -> Option<String> {
    if let Some(task) = std::env::var("CMUX_TASK").ok().filter(|t| !t.is_empty()) {
        return Some(task);
    }
    let branch = std::process::Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned());
    branch.and_then(|b| {
        let name = b.rsplit('/').next()?.to_owned();
        let mut parts = name.splitn(3, '-');
        let prefix = parts.next()?;
        let number = parts.next()?;
        (prefix.chars().all(|c| c.is_ascii_alphabetic())
            && !prefix.is_empty()
            && number.chars().all(|c| c.is_ascii_digit())
            && !number.is_empty())
        .then(|| format!("{}-{number}", prefix.to_ascii_uppercase()))
    })
}

fn resolve_current(mut params: Value) -> Result<Value, String> {
    if let Some(task) = params.get_mut("task")
        && task.as_str() == Some("current")
    {
        *task = json!(
            current_task()
                .ok_or("no current task: the branch has no task key and CMUX_TASK is unset")?
        );
    }
    Ok(params)
}

fn print_catalog(words: &[String]) -> u8 {
    let format = words
        .iter()
        .position(|w| w == "--format")
        .and_then(|i| words.get(i + 1))
        .map_or("json", String::as_str);
    let text = match format {
        "json" => serde_json::to_string_pretty(&catalog::export_json()).unwrap_or_default(),
        "mcp" => {
            serde_json::to_string_pretty(&catalog::mcp_tools(words.iter().any(|w| w == "--opt-in")))
                .unwrap_or_default()
        }
        "ts" => catalog::export_typescript(),
        other => return fail(2, &format!("unknown format {other}; use json, ts or mcp")),
    };
    println!("{text}");
    0
}

/// The caller's launch credential (P8): the owner stamps the actor from it.
fn launch_credential() -> Option<String> {
    std::env::var("CMUX_LAUNCH_CREDENTIAL").ok().filter(|c| !c.is_empty())
}

/// The app supervisor's environment for a server app (server.md 7.3):
/// `CMUX_APP_DATA` (data directory), `CMUX_APP_SOCKET` (listener path),
/// `CMUX_APP_EPOCH` (lease epoch) and `CMUX_APP_HOST` (this host's id).
/// Returns the owner to serve and the durability settings.
fn supervised(
    owner: &LocalOwner,
    env: impl Fn(&str) -> Option<String>,
) -> Result<(LocalOwner, crate::store::Durability), String> {
    let mut owner = owner.clone();
    if let Some(data) = env("CMUX_APP_DATA").filter(|d| !d.is_empty()) {
        owner.dir = data.into();
        owner.socket = owner.dir.join("tasks.sock");
    }
    if let Some(socket) = env("CMUX_APP_SOCKET").filter(|s| !s.is_empty()) {
        owner.socket = socket.into();
    }
    let mut durability = crate::store::Durability::local();
    if let Some(epoch) = env("CMUX_APP_EPOCH").filter(|e| !e.is_empty()) {
        let epoch: u64 =
            epoch.parse().map_err(|_| format!("CMUX_APP_EPOCH must be a number, got {epoch:?}"))?;
        let host = env("CMUX_APP_HOST")
            .filter(|h| !h.is_empty() && h.len() <= 200)
            .ok_or("CMUX_APP_EPOCH needs CMUX_APP_HOST (this host's id)")?;
        durability.epoch = Some(crate::store::EpochClaim { epoch, host });
    }
    Ok((owner, durability))
}

#[cfg(unix)]
fn serve(owner: &LocalOwner, prefix: &str) -> u8 {
    let (owner, durability) = match supervised(owner, |name| std::env::var(name).ok()) {
        Ok(supervised) => supervised,
        Err(e) => return fail(2, &e),
    };
    let owner = &owner;
    let engine = match crate::engine::Engine::open_durable(
        &owner.dir,
        &owner.team,
        prefix,
        crate::engine::system_clock(),
        crate::store::Limits::default(),
        durability,
    ) {
        Ok(engine) => engine,
        Err(crate::store::OpenError::Locked) => {
            return fail(5, "another Tasks owner already serves this team");
        }
        Err(crate::store::OpenError::Fenced(m)) => return fail(5, &m),
        Err(e) => return fail(1, &e.to_string()),
    };
    let identity = std::sync::Arc::new(crate::identity::Identity::local(owner::local_person()));
    let socket = owner.socket.display().to_string();
    match crate::server::serve(owner, engine, identity, || {
        let _ = writeln!(std::io::stderr(), "cmux task: serving {socket}");
    }) {
        Ok(()) => 0,
        Err(e) => fail(1, &e.to_string()),
    }
}

#[cfg(not(unix))]
fn serve(_owner: &LocalOwner, _prefix: &str) -> u8 {
    fail(2, "serve needs a Unix socket")
}

fn watch(
    conn: &mut Conn,
    params: Value,
    json_out: bool,
    count: Option<u64>,
    timeout: Option<u64>,
) -> u8 {
    if conn.is_in_process() {
        return fail(5, "watch needs a running owner (`cmux task serve`)");
    }
    // `--timeout` bounds the whole watch, not the gap between events.
    let deadline = timeout.map(|s| std::time::Instant::now() + std::time::Duration::from_secs(s));
    let mut seen = 0u64;
    if let Err(e) = conn.call("task.subscribe", params, None) {
        return fail_body(&e);
    }
    let mut stdout = std::io::stdout();
    loop {
        match deadline {
            Some(deadline) => match deadline.checked_duration_since(std::time::Instant::now()) {
                Some(left) if !left.is_zero() => conn.set_deadline(left),
                _ => return 0,
            },
            None => conn.clear_deadline(),
        }
        match conn.read_line() {
            Ok(ServerLine::Event { event }) => {
                let text = if json_out {
                    serde_json::to_string(&event).unwrap_or_default()
                } else {
                    format!("{} {} {}", event.seq, event.body.kind, event.actor.id())
                };
                if writeln!(stdout, "{text}").and_then(|()| stdout.flush()).is_err() {
                    return 0;
                }
                seen += 1;
                if count.is_some_and(|n| seen >= n) {
                    return 0;
                }
            }
            Ok(ServerLine::Snapshot { snapshot }) if json_out => {
                let _ = writeln!(stdout, "{}", json!({"snapshot": snapshot}));
            }
            Ok(_) => {}
            // The deadline ends a bounded watch normally.
            Err(e) if e.code == ErrorCode::Timeout => return 0,
            Err(e) => return fail_body(&e),
        }
    }
}

fn slug(title: &str) -> String {
    let mut out = String::new();
    for c in title.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
        if out.len() >= 40 {
            break;
        }
    }
    out.trim_end_matches('-').to_owned()
}

fn start(owner: &LocalOwner, prefix: &str, global: &args::Global, words: &[String]) -> u8 {
    let Some(task) = words.iter().find(|w| !w.starts_with("--")) else {
        return fail(2, "`task start` needs KEY");
    };
    let task = &if task == "current" {
        match current_task() {
            Some(t) => t,
            None => {
                return fail(
                    2,
                    "no current task: the branch has no task key and CMUX_TASK is unset",
                );
            }
        }
    } else {
        task.clone()
    };
    let no_branch = words.iter().any(|w| w == "--no-branch");
    let credential = launch_credential();
    let mut conn = match Conn::open(owner, credential.as_deref(), prefix) {
        Ok(conn) => conn,
        Err(e) => return fail_body(&e),
    };
    let settings = match conn.call("task.settings.get", json!({}), None) {
        Ok((s, _)) => s,
        Err(e) => return fail_body(&e),
    };
    let started = settings.get("started_status").cloned().unwrap_or(Value::Null);
    let key = global.key.clone().unwrap_or_else(|| owner::mint("idem_"));
    if let Err(e) = conn.call(
        "task.update",
        json!({"task": task, "assignee": "me", "status": started}),
        Some(key),
    ) {
        return fail_body(&e);
    }
    let detail = match conn.call("task.get", json!({"task": task}), None) {
        Ok((d, _)) => d,
        Err(e) => return fail_body(&e),
    };
    let task_key = detail.get("key").and_then(Value::as_str).unwrap_or(task).to_lowercase();
    let title = detail.get("title").and_then(Value::as_str).unwrap_or("");
    let branch = format!("{task_key}-{}", slug(title));
    if !no_branch {
        let inside = std::process::Command::new("git")
            .args(["rev-parse", "--is-inside-work-tree"])
            .output()
            .is_ok_and(|o| o.status.success());
        if inside {
            let exists = std::process::Command::new("git")
                .args(["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")])
                .status()
                .is_ok_and(|s| s.success());
            let args: Vec<&str> =
                if exists { vec!["switch", &branch] } else { vec!["switch", "-c", &branch] };
            match std::process::Command::new("git").args(&args).status() {
                Ok(status) if status.success() => {}
                _ => return fail(4, &format!("git could not switch to {branch}")),
            }
        }
    }
    if global.json {
        println!("{}", json!({"task": detail, "branch": branch}));
    } else {
        println!(
            "{} started on {branch}",
            detail.get("key").and_then(Value::as_str).unwrap_or(task)
        );
    }
    0
}

#[cfg(test)]
mod supervised_tests {
    use super::*;

    fn owner() -> LocalOwner {
        LocalOwner { team: "t".into(), dir: "/a".into(), socket: "/a/tasks.sock".into() }
    }

    #[test]
    fn without_supervisor_env_the_owner_is_unchanged() {
        let (o, d) = supervised(&owner(), |_| None).unwrap();
        assert_eq!(o, owner());
        assert!(d.epoch.is_none());
    }

    #[test]
    fn supervisor_env_sets_data_socket_and_epoch() {
        let env = |name: &str| match name {
            "CMUX_APP_DATA" => Some("/srv/team/apps/cmux_tasks/data".to_owned()),
            "CMUX_APP_SOCKET" => Some("/run/cmux/apps/tasks.sock".to_owned()),
            "CMUX_APP_EPOCH" => Some("7".to_owned()),
            "CMUX_APP_HOST" => Some("team-vm".to_owned()),
            _ => None,
        };
        let (o, d) = supervised(&owner(), env).unwrap();
        assert_eq!(o.dir, std::path::PathBuf::from("/srv/team/apps/cmux_tasks/data"));
        assert_eq!(o.socket, std::path::PathBuf::from("/run/cmux/apps/tasks.sock"));
        let claim = d.epoch.unwrap();
        assert_eq!((claim.epoch, claim.host.as_str()), (7, "team-vm"));
    }

    #[test]
    fn an_epoch_needs_a_number_and_a_host() {
        let bad = |name: &str| (name == "CMUX_APP_EPOCH").then(|| "x".to_owned());
        assert!(supervised(&owner(), bad).is_err());
        let no_host = |name: &str| (name == "CMUX_APP_EPOCH").then(|| "3".to_owned());
        assert!(supervised(&owner(), no_host).is_err());
    }
}
