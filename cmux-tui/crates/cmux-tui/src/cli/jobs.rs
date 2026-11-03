//! `cmux jobs [--json]`: the daemon's long jobs (`jobs-list`, capability
//! `long_jobs`): output cleanup, registry open, terminal host adoption,
//! journal maintenance, with their progress and what they block.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

const USAGE: &str = "usage: cmux jobs [--json]\n\n  The session daemon's long jobs: what runs, how far it is, and what it blocks.";

/// `cmux [global options] jobs [--json]` when `args` names it.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = command_args.strip_prefix(&["jobs".to_string()][..])?;
    let mut global = global;
    for word in rest {
        match word.as_str() {
            "--json" => global.output = OutputMode::Json,
            "--quiet" => global.output = OutputMode::Quiet,
            "-h" | "--help" => {
                println!("{USAGE}");
                return Some(0);
            }
            _ => {
                eprintln!("{USAGE}");
                return Some(2);
            }
        }
    }
    Some(run(&global))
}

fn run(global: &GlobalArgs) -> i32 {
    let socket = match super::wire::resolve_socket_or_report(global) {
        Ok((socket, _)) => socket,
        Err(code) => return code,
    };
    match list(&socket) {
        Ok(data) => {
            let jobs = data.get("jobs").and_then(Value::as_array).cloned().unwrap_or_default();
            match global.output {
                OutputMode::Quiet => {}
                OutputMode::Json | OutputMode::JsonLines => println!("{}", json!({"jobs": jobs})),
                OutputMode::Human => print!("{}", table(&jobs)),
            }
            0
        }
        Err(message) => {
            eprintln!("cmux: {message}");
            1
        }
    }
}

fn list(socket: &std::path::Path) -> Result<Value, String> {
    let stream = UnixStream::connect(socket).map_err(|error| {
        format!("cannot connect to the session socket {}: {error}", socket.display())
    })?;
    stream.set_read_timeout(Some(Duration::from_secs(15))).map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(stream);
    writeln!(reader.get_mut(), "{}", json!({"id": "jobs-1", "cmd": "jobs-list"}))
        .map_err(|e| e.to_string())?;
    loop {
        let mut reply = String::new();
        if reader.read_line(&mut reply).map_err(|e| e.to_string())? == 0 {
            return Err("the daemon closed the connection".into());
        }
        let Ok(value) = serde_json::from_str::<Value>(&reply) else { continue };
        if value.get("id").and_then(Value::as_str) != Some("jobs-1") {
            continue;
        }
        if value.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(value.get("data").cloned().unwrap_or(Value::Null));
        }
        return Err(value.get("error").and_then(Value::as_str).unwrap_or("error").to_string());
    }
}

/// One line per job: title, progress, what it blocks.
fn table(jobs: &[Value]) -> String {
    if jobs.is_empty() {
        return "no long jobs\n".into();
    }
    let mut out = String::new();
    for job in jobs {
        let text = |key: &str| job.get(key).and_then(Value::as_str).unwrap_or("");
        let progress = match (
            job.get("done").and_then(Value::as_u64),
            job.get("total").and_then(Value::as_u64),
        ) {
            (Some(done), Some(total)) if total > 0 => {
                format!(" {done}/{total} {} ({}%)", text("unit"), done * 100 / total)
            }
            (Some(done), _) => format!(" {done} {}", text("unit")),
            _ => String::new(),
        };
        let detail =
            if text("detail").is_empty() { String::new() } else { format!(": {}", text("detail")) };
        let blocks = job
            .get("blocks")
            .and_then(Value::as_array)
            .map(|blocks| blocks.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(","))
            .unwrap_or_default();
        out.push_str(&format!(
            "{}{progress}{detail} [{}; blocks {blocks}]\n",
            text("title"),
            text("kind")
        ));
    }
    out
}
