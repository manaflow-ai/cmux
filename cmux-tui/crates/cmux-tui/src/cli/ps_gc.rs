//! `cmux ps [--json] [--state-dir DIR]` and
//! `cmux gc [--apply] [--json] [--state-dir DIR]`.
//!
//! Both answer from the product's own records, never from a process's
//! arguments: a terminal host's `--owner <bundle>:<tag>@<pid>` names the
//! daemon that launched it, which may be dead while a later daemon adopted
//! the host. `ps` asks the session daemon (`process-census`, cmux-tui-core
//! mux/process_census.rs); with no daemon it reads the records from disk
//! with the same liveness checks. `gc` lists only proven orphans, the hosts
//! the unowned-host reaper would end, and ends them only with `--apply`.

use std::path::PathBuf;

use cmux_tui_core::process_census;
use serde_json::{Value, json};

use super::safe_mode::{Answer, ask};
use super::{GlobalArgs, OutputMode};

const PS_USAGE: &str = "usage: cmux ps [--json] [--state-dir DIR]\n\n  The terminal hosts and state cmux keeps, read from its own records: each host's\n  pid and process group, the workspace and pane it serves, whether a live daemon\n  holds its stream, and a state (in-use, idle, orphaned, unknown) with the reason.\n  Then each record root and the live daemon that owns it, stale records, exit\n  records and sockets no record names. With no cmux running it reads the records\n  in the state folder (--state-dir, else CMUX_TUI_STATE_DIR, else the default).\n  ps changes nothing; a host cmux gc has not seen yet reads first seen unowned now.";

const GC_USAGE: &str = "usage: cmux gc [--apply] [--json] [--state-dir DIR]\n\n  Lists the terminal hosts no live cmux owns: hosts whose session has no running\n  daemon, seen that way for the whole grace (24 hours, 10 minutes once the shell\n  ended), counted from the first time cmux gc or a running cmux saw it unowned.\n  A host a live daemon holds or shows, one a saved workspace of its session\n  still references, or one whose lease or registry cannot be read, is refused\n  with the reason. Without --apply no host is ended; gc only saves when it first\n  saw each host, which starts its grace.\n  --apply ends each listed host, writes its intent and then its outcome to\n  terminal-host-gc.jsonl in the state folder and prints a receipt. Stale records\n  are reported, not removed.";

#[derive(Debug, Clone, PartialEq, Eq)]
enum Verb {
    Ps,
    Gc { apply: bool },
}

/// What the words after `ps` or `gc` ask for.
#[derive(Debug)]
enum Request {
    Help(&'static str),
    Usage(&'static str),
    Run { global: GlobalArgs, verb: Verb, state_dir: Option<PathBuf> },
}

/// `None` when `args` is not `ps` or `gc`.
fn parse(args: &[String]) -> Option<Request> {
    let (mut global, command_args) = super::parse_globals(args).ok()?;
    let (verb, rest) = command_args.split_first()?;
    let usage = match verb.as_str() {
        "ps" => PS_USAGE,
        "gc" => GC_USAGE,
        _ => return None,
    };
    let mut apply = false;
    let mut state_dir = None;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "-h" | "--help" => return Some(Request::Help(usage)),
            "--json" => global.output = OutputMode::Json,
            "--quiet" => global.output = OutputMode::Quiet,
            "--apply" if verb == "gc" => apply = true,
            "--state-dir" => match words.next() {
                Some(dir) => state_dir = Some(PathBuf::from(dir)),
                None => return Some(Request::Usage(usage)),
            },
            _ => return Some(Request::Usage(usage)),
        }
    }
    let verb = if verb == "ps" { Verb::Ps } else { Verb::Gc { apply } };
    Some(Request::Run { global, verb, state_dir })
}

/// `cmux [global options] ps|gc ...`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    Some(match parse(args)? {
        Request::Help(usage) => {
            println!("{usage}");
            0
        }
        Request::Usage(usage) => {
            eprintln!("{usage}");
            2
        }
        Request::Run { global, verb, state_dir } => run(&global, &verb, state_dir),
    })
}

fn state_root(explicit: Option<PathBuf>) -> Option<PathBuf> {
    explicit.or_else(cmux_tui_platform::platform::workspace_state_dir)
}

fn run(global: &GlobalArgs, verb: &Verb, state_dir: Option<PathBuf>) -> i32 {
    let json_out = matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let print = |text: String| {
        if global.output != OutputMode::Quiet {
            println!("{}", text.trim_end());
        }
    };
    match verb {
        Verb::Ps => {
            let census = match ask(global, json!({"id": "cmux-ps-1", "cmd": "process-census"})) {
                Answer::Ok(data) => data,
                answer => {
                    if let Answer::Refused { code, message } = &answer {
                        eprintln!(
                            "cmux: the daemon did not answer process-census ({code}: {message}); reading the records"
                        );
                    }
                    let Some(root) = state_root(state_dir) else {
                        eprintln!("cmux: no state folder to read; pass --state-dir");
                        return 1;
                    };
                    serde_json::to_value(process_census::census(&root, None)).unwrap_or(Value::Null)
                }
            };
            print(if json_out { census.to_string() } else { human_ps(&census) });
            0
        }
        Verb::Gc { apply } => {
            let Some(root) = state_root(state_dir) else {
                eprintln!("cmux: no state folder to read; pass --state-dir");
                return 1;
            };
            let report = process_census::gc(&root, *apply);
            let failed = report.failed;
            let value = serde_json::to_value(&report).unwrap_or(Value::Null);
            print(if json_out { value.to_string() } else { human_gc(&value) });
            i32::from(failed > 0)
        }
    }
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("")
}

fn number(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_u64).map(|n| n.to_string()).unwrap_or_else(|| "-".into())
}

fn list<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value.get(key).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

fn place(host: &Value) -> String {
    let places: Vec<String> = list(host, "placements")
        .iter()
        .map(|place| {
            let workspace = place
                .get("workspace_name")
                .and_then(Value::as_str)
                .or_else(|| place.get("workspace").and_then(Value::as_str))
                .unwrap_or("?");
            let pane = place
                .get("pane_name")
                .and_then(Value::as_str)
                .unwrap_or_else(|| text(place, "pane"));
            format!("{workspace}/{pane}")
        })
        .collect();
    if places.is_empty() { "-".into() } else { places.join(",") }
}

fn human_ps(census: &Value) -> String {
    let mut out = String::new();
    let source = text(census, "source");
    match census.get("daemon") {
        Some(daemon) => out.push_str(&format!(
            "daemon pid {} pgid {} session {} (answered by the daemon)\n",
            number(daemon, "pid"),
            number(daemon, "pgid"),
            text(daemon, "session"),
        )),
        None => out.push_str(&format!(
            "no daemon answered; read from the records in {} ({source})\n",
            text(census, "state_root"),
        )),
    }
    let hosts = list(census, "hosts");
    out.push_str(&format!("\n{} terminal host(s)\n", hosts.len()));
    if !hosts.is_empty() {
        out.push_str(&format!(
            "{:<8} {:<8} {:<9} {:<6} {:<36} {:<24} {}\n",
            "PID", "PGID", "STATE", "STREAM", "TERMINAL", "PLACE", "REASON"
        ));
    }
    for host in hosts {
        let stream = if host.get("stream_held").and_then(Value::as_bool) == Some(true) {
            "held"
        } else {
            "-"
        };
        let gc = host.get("gc").cloned().unwrap_or(Value::Null);
        let gc_note = if gc.get("candidate").and_then(Value::as_bool) == Some(true) {
            " [gc candidate]".to_string()
        } else {
            String::new()
        };
        out.push_str(&format!(
            "{:<8} {:<8} {:<9} {:<6} {:<36} {:<24} {}{gc_note}\n",
            number(host, "host_pid"),
            number(host, "pgid"),
            text(host, "state"),
            stream,
            text(host, "terminal_id"),
            place(host),
            text(host, "reason"),
        ));
    }
    let helpers = list(census, "helpers");
    if !helpers.is_empty() {
        out.push_str(&format!("\n{} helper process(es)\n", helpers.len()));
        for helper in helpers {
            out.push_str(&format!("  {:<8} {}\n", number(helper, "pid"), text(helper, "name")));
        }
    }
    let state = census.get("state").cloned().unwrap_or(Value::Null);
    let roots = list(&state, "roots");
    out.push_str(&format!("\n{} record root(s)\n", roots.len()));
    for root in roots {
        out.push_str(&format!(
            "  {:<12} hosts {} stale {} exits {}  {}{}\n",
            text(root, "owner"),
            number(root, "hosts"),
            number(root, "stale_records"),
            number(root, "exit_records"),
            text(root, "record_root"),
            root.get("session")
                .and_then(Value::as_str)
                .map(|session| format!(" (session {session})"))
                .unwrap_or_default(),
        ));
    }
    for (key, label) in [
        ("stale_records", "stale record(s) (the host's lease is dead)"),
        ("exit_records", "exit record(s)"),
    ] {
        let rows = list(&state, key);
        if !rows.is_empty() {
            out.push_str(&format!("\n{} {label}\n", rows.len()));
            for row in rows {
                let path = row.get("record_path").or_else(|| row.get("path"));
                out.push_str(&format!("  {}\n", path.and_then(Value::as_str).unwrap_or("")));
            }
        }
    }
    let sockets = list(&state, "unnamed_sockets");
    if !sockets.is_empty() {
        out.push_str(&format!("\n{} socket(s) no record names\n", sockets.len()));
        for socket in sockets {
            out.push_str(&format!("  {}\n", socket.as_str().unwrap_or("")));
        }
    }
    push_errors(&mut out, census);
    out
}

fn human_gc(report: &Value) -> String {
    let mut out = String::new();
    let applied = report.get("applied").and_then(Value::as_bool) == Some(true);
    let candidates = list(report, "candidates");
    out.push_str(&format!(
        "{} orphaned terminal host(s) in {}{}\n",
        candidates.len(),
        text(report, "state_root"),
        if applied { "" } else { " (dry run; --apply ends them)" },
    ));
    for candidate in candidates {
        out.push_str(&format!(
            "  {:<8} {:<36} {}{}\n",
            number(candidate, "host_pid"),
            text(candidate, "terminal_id"),
            text(candidate, "reason"),
            candidate
                .get("outcome")
                .and_then(Value::as_str)
                .map(|outcome| format!(" -> {outcome}"))
                .unwrap_or_default(),
        ));
    }
    let refused = list(report, "refused");
    if !refused.is_empty() {
        out.push_str(&format!("\n{} host(s) refused\n", refused.len()));
        for host in refused {
            out.push_str(&format!(
                "  {:<8} {:<9} {:<36} {}\n",
                number(host, "host_pid"),
                text(host, "state"),
                text(host, "terminal_id"),
                text(host, "refusal"),
            ));
        }
    }
    if applied {
        out.push_str(&format!(
            "\nended {}, failed {}\n",
            number(report, "ended"),
            number(report, "failed")
        ));
        for log in list(report, "logs") {
            out.push_str(&format!("logged to {}\n", log.as_str().unwrap_or("")));
        }
    }
    let stale = report.get("stale_records").and_then(Value::as_u64).unwrap_or(0);
    if stale > 0 {
        out.push_str(&format!(
            "{stale} stale record(s) left for their session's next start (cmux ps lists them)\n"
        ));
    }
    push_errors(&mut out, report);
    out
}

fn push_errors(out: &mut String, report: &Value) {
    let errors = list(report, "errors");
    if !errors.is_empty() {
        out.push_str(&format!("\n{} error(s)\n", errors.len()));
        for error in errors {
            out.push_str(&format!("  {}\n", error.as_str().unwrap_or("")));
        }
    }
}

#[cfg(test)]
#[path = "ps_gc_tests.rs"]
mod tests;
