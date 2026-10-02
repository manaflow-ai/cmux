//! `cmux task …` verbs. The `cmux` binary mounts `run` for the `task` noun;
//! the standalone `cmux-tasks` binary calls it too. Every verb except the
//! few below comes from the catalog (`cmux_tasks_core::catalog`):
//! - `serve`: run the local owner (socket server).
//! - `catalog [--format json|ts|mcp]`: print the catalog export.
//! - `mine`: `list --mine --open`.
//! - `start KEY [--no-branch]`: assign to me, move to the started status,
//!   create or switch to the git branch `<key>-<slug>`.
//!
//! `KEY` may be `current`: the task key in the git branch name (`cmx-12-…`),
//! then `$CMUX_TASK`. `task watch` takes `--count N` and `--timeout SECONDS`
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

const DEFAULT_PREFIX: &str = "CMX";

fn fail(code: u8, message: &str) -> ExitCode {
    let _ = writeln!(std::io::stderr(), "cmux task: {message}");
    ExitCode::from(code)
}

fn fail_body(err: &ErrorBody) -> ExitCode {
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
    let (global, mut words) = match args::split_global(args) {
        Ok(split) => split,
        Err(e) => return fail(2, &e),
    };
    if words.first().map(String::as_str) == Some("task") {
        words.remove(0);
    }
    if words.is_empty() {
        print!("{}", help());
        return if global.help { ExitCode::SUCCESS } else { ExitCode::from(2) };
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
        return ExitCode::SUCCESS;
    }
    let params = match args::params(entry, &words[used - 1..]) {
        Ok(p) => p,
        Err(e) => return fail(2, &format!("{e}\n\n{}", args::usage(entry))),
    };
    let actor = owner::local_actor();
    let mut conn = match Conn::open(&owner, &actor, &prefix) {
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
            ExitCode::SUCCESS
        }
        Err(e) => {
            if let Some(key) = key {
                let _ = writeln!(std::io::stderr(), "idempotency key: {key}");
            }
            fail_body(&e)
        }
    }
}

/// The task key in the current git branch (`cmx-12-fix-drag` -> `CMX-12`), then `$CMUX_TASK`.
fn current_task() -> Option<String> {
    let branch = std::process::Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned());
    let from_branch = branch.and_then(|b| {
        let name = b.rsplit('/').next()?.to_owned();
        let mut parts = name.splitn(3, '-');
        let prefix = parts.next()?;
        let number = parts.next()?;
        (prefix.chars().all(|c| c.is_ascii_alphabetic())
            && !prefix.is_empty()
            && number.chars().all(|c| c.is_ascii_digit())
            && !number.is_empty())
        .then(|| format!("{}-{number}", prefix.to_ascii_uppercase()))
    });
    from_branch.or_else(|| std::env::var("CMUX_TASK").ok().filter(|t| !t.is_empty()))
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

fn print_catalog(words: &[String]) -> ExitCode {
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
    ExitCode::SUCCESS
}

#[cfg(unix)]
fn serve(owner: &LocalOwner, prefix: &str) -> ExitCode {
    let engine = match crate::engine::Engine::open(
        &owner.dir,
        &owner.team,
        prefix,
        crate::engine::system_clock(),
    ) {
        Ok(engine) => engine,
        Err(crate::store::OpenError::Locked) => {
            return fail(5, "another Tasks owner already serves this team");
        }
        Err(e) => return fail(1, &e.to_string()),
    };
    let socket = owner.socket.display().to_string();
    match crate::server::serve(owner, engine, || {
        let _ = writeln!(std::io::stderr(), "cmux task: serving {socket}");
    }) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => fail(1, &e.to_string()),
    }
}

#[cfg(not(unix))]
fn serve(_owner: &LocalOwner, _prefix: &str) -> ExitCode {
    fail(2, "serve needs a Unix socket")
}

fn watch(
    conn: &mut Conn,
    params: Value,
    json_out: bool,
    count: Option<u64>,
    timeout: Option<u64>,
) -> ExitCode {
    if conn.is_in_process() {
        return fail(5, "watch needs a running owner (`cmux task serve`)");
    }
    if let Some(seconds) = timeout {
        conn.set_deadline(std::time::Duration::from_secs(seconds));
    }
    let mut seen = 0u64;
    if let Err(e) = conn.call("task.subscribe", params, None) {
        return fail_body(&e);
    }
    let mut stdout = std::io::stdout();
    loop {
        match conn.read_line() {
            Ok(ServerLine::Event { event }) => {
                let text = if json_out {
                    serde_json::to_string(&event).unwrap_or_default()
                } else {
                    format!("{} {} {}", event.seq, event.body.kind, event.actor.id())
                };
                if writeln!(stdout, "{text}").and_then(|()| stdout.flush()).is_err() {
                    return ExitCode::SUCCESS;
                }
                seen += 1;
                if count.is_some_and(|n| seen >= n) {
                    return ExitCode::SUCCESS;
                }
            }
            Ok(ServerLine::Snapshot { snapshot }) if json_out => {
                let _ = writeln!(stdout, "{}", json!({"snapshot": snapshot}));
            }
            Ok(_) => {}
            // The deadline ends a bounded watch normally.
            Err(e) if e.code == ErrorCode::Timeout => return ExitCode::SUCCESS,
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

fn start(owner: &LocalOwner, prefix: &str, global: &args::Global, words: &[String]) -> ExitCode {
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
    let actor = owner::local_actor();
    let mut conn = match Conn::open(owner, &actor, prefix) {
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
    ExitCode::SUCCESS
}
