//! `cmux spill [ROUTE] [OPTIONS] [--here | --to MACHINE] [--timings] -- COMMAND [ARG]...`:
//! run a heavy command here, or on another machine when this one is over its
//! budget (cmuxterm-hq RFD 0032 "Place", "A spilled command").
//!
//! The decision is `cmux_host_budget::place::decide`, the one function Auto
//! for agent sessions will call too: this host's budget level (the shared
//! [`Meter`], its own thresholds), the place named by `ROUTE` and the connect
//! options `cmux remote exec` takes, and the overrides. The place's room is
//! read on the place itself, only when this host is over: one short process
//! (`place::LINUX_PROBE_SCRIPT`) on the connection the command then uses,
//! judged by the same formula. A place whose room cannot be read is never room.
//!
//! Spilled, it prints one line on stderr (where and why) and runs the command
//! through `remote exec`'s own streaming path ([`super::exec_cp::exec_on`]): the
//! output streams back live and the exit status is the command's. Kept here, it
//! runs the command as a child with this terminal's stdin, stdout and stderr.
//! `--timings` prints one JSON line on stderr when the command ends:
//! `spill_start_ms` (start of this CLI to the first byte of the spilled
//! command's output; `null` when it ran here or printed nothing), the
//! `placement`, the `reason`, `phases` in whole ms and `exit`.
//!
//! Nothing spills unless this verb is used: every other command, and Auto
//! (off by default), are unchanged.

use std::sync::{Arc, OnceLock};
use std::time::Instant;

use anyhow::anyhow;
use cmux_host_budget::place::{
    self, Asked, Decision, Headroom, HereBudget, Inputs, Override, Placement, Reason, Room,
    Setting, Work,
};
use cmux_host_budget::{Level, Meter, Reading, level_for};
use cmux_remote::client::WorkspaceClient;
use serde_json::{Map, Value, json};

use super::exec_cp::{
    EXIT_TRANSPORT, ExecArgs, ExitWith, exec_on, open_root, parse_exec_args, run_remote,
};
use super::{REMOTE_VALUE_OPTIONS, parse_connect_flags, start_connected, tokio_runtime};

/// The verb's name in its messages.
const VERB: &str = "cmux spill";

pub(super) const HELP: &str = r#"USAGE: cmux spill [ROUTE] [OPTIONS] [--here | --to MACHINE] [--timings] -- COMMAND [ARG]...

Run COMMAND here, or on another machine when this one is over its CPU/RAM
budget. Spilled, one line on stderr says where and why; the output streams
back live and the exit status is COMMAND's.

ROUTE and the connect options (--state-dir, --via-machine, --carrier, ...)
name the machine to spill to, as `cmux remote exec` takes them. Its room is
read there first: a machine over its own budget, or one whose room cannot be
read, is not used and COMMAND runs here.

OPTIONS:
  --here              Run here whatever the budget.
  --to MACHINE        Run on MACHINE (a ROUTE) whatever the budget.
  --timings           When COMMAND ends, print one JSON line on stderr:
                      spill_start_ms, placement, reason, phases, exit.
  --cwd PATH, --env KEY=VALUE, --tty, --timeout-seconds N
                      As `cmux remote exec` (on the other machine).
"#;

#[derive(Debug, PartialEq, Eq)]
pub(super) struct SpillArgs {
    pub(super) force: Override,
    pub(super) timings: bool,
    pub(super) exec: ExecArgs,
}

/// Takes the spill options out of the words before `--`; the rest is `remote exec`'s.
pub(super) fn parse_spill_args(args: &[String]) -> anyhow::Result<SpillArgs> {
    let split = args.iter().position(|a| a == "--").unwrap_or(args.len());
    let (options, command) = args.split_at(split);
    let mut force = Override::None;
    let mut timings = false;
    let mut rest = Vec::new();
    let mut words = options.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--here" | "--to" if force != Override::None => {
                return Err(anyhow!("{VERB}: give one of --here and --to"));
            }
            "--here" => force = Override::Here,
            "--to" => {
                let machine = words
                    .next()
                    .filter(|m| !m.starts_with('-'))
                    .ok_or_else(|| anyhow!("{VERB}: --to needs a MACHINE"))?;
                force = Override::To(machine.clone());
            }
            "--timings" => timings = true,
            option if REMOTE_VALUE_OPTIONS.contains(&option) => {
                rest.push(word.clone());
                rest.extend(words.next().cloned());
            }
            _ => rest.push(word.clone()),
        }
    }
    rest.extend(command.iter().cloned());
    let mut exec = parse_exec_args(&rest)?;
    if let Override::To(machine) = &force {
        if route_word(&exec.connect).is_some() {
            return Err(anyhow!("{VERB}: give the machine once, as ROUTE or as --to"));
        }
        exec.connect.insert(0, machine.clone());
    }
    Ok(SpillArgs { force, timings, exec })
}

/// The positional ROUTE among connect options, if any.
fn route_word(connect: &[String]) -> Option<&str> {
    let mut words = connect.iter();
    while let Some(word) = words.next() {
        if REMOTE_VALUE_OPTIONS.contains(&word.as_str()) {
            words.next();
        } else if !word.starts_with('-') {
            return Some(word);
        }
    }
    None
}

/// The place's name in the stderr line and the decision: its ROUTE, else the
/// machine `--via-machine` names, else what is left.
fn place_name(connect: &[String]) -> String {
    if let Some(route) = route_word(connect) {
        return route.to_owned();
    }
    connect
        .windows(2)
        .find_map(|pair| match pair {
            [flag, name] if flag == "--via-machine" => Some(name.clone()),
            _ => None,
        })
        .unwrap_or_else(|| "the paired machine".into())
}

/// The connection to the place, kept from the room probe to the command.
struct Link {
    connected: super::ConnectedRuntime,
    client: Arc<WorkspaceClient>,
}

/// Connects to the place `connect` names.
fn connect(runtime: &tokio::runtime::Runtime, connect: &[String]) -> anyhow::Result<Link> {
    let connected = start_connected(parse_connect_flags(connect)?)?;
    let client =
        runtime.block_on(WorkspaceClient::connect(connected.runtime.multiplexer().clone()))?;
    Ok(Link { connected, client })
}

/// The place's room, read on it.
fn probe(runtime: &tokio::runtime::Runtime, client: &WorkspaceClient) -> Headroom {
    let mut out = Vec::new();
    let answer = runtime.block_on(async {
        let workspace = open_root(client).await?;
        let argv = vec!["sh".into(), "-c".into(), place::LINUX_PROBE_SCRIPT.into()];
        run_remote(client, &workspace, argv, Some(&mut out)).await
    });
    match answer {
        Ok((0, _)) => place::linux_headroom(&String::from_utf8_lossy(&out)),
        _ => Headroom::Unknown,
    }
}

/// This host's budget as the decision reads it: one sample of the shared meter.
fn here_budget() -> Option<HereBudget> {
    let verdict = Meter::shared().sample_at(Instant::now())?;
    let level = level_for(&Reading::from(&verdict), Level::Normal);
    Some(HereBudget { level, over: verdict.over })
}

/// Whole ms between two instants.
fn ms(from: Instant, to: Instant) -> u64 {
    u64::try_from(to.saturating_duration_since(from).as_millis()).unwrap_or(u64::MAX)
}

pub(super) fn run_spill(args: &[String]) -> anyhow::Result<()> {
    let started = Instant::now();
    if args.iter().take_while(|a| *a != "--").any(|a| a == "--help" || a == "-h") {
        print!("{HELP}");
        return Ok(());
    }
    let spill = parse_spill_args(args)?;
    let mut phases = Map::new();
    let here = here_budget();
    phases.insert("budget".into(), json!(ms(started, Instant::now())));
    let setting = Setting::default();
    let inputs = Inputs {
        work: Work::Command(&spill.exec.argv),
        asked: Asked::Spill,
        here,
        setting: &setting,
        force: spill.force.clone(),
    };
    let runtime = tokio_runtime()?;
    let mut link: Option<Link> = None;
    let mut place_error: Option<String> = None;
    let decision = place::decide(&inputs, || {
        if spill.exec.connect.is_empty() {
            return Vec::new();
        }
        let name = place_name(&spill.exec.connect);
        let at = Instant::now();
        let headroom = match connect(&runtime, &spill.exec.connect) {
            Ok(connected) => {
                phases.insert("connect".into(), json!(ms(at, Instant::now())));
                let probed = Instant::now();
                let headroom = probe(&runtime, &connected.client);
                phases.insert("probe".into(), json!(ms(probed, Instant::now())));
                link = Some(connected);
                headroom
            }
            Err(error) => {
                place_error = Some(format!("{error:#}"));
                Headroom::Unknown
            }
        };
        vec![Room { place: name, headroom }]
    });
    let first_output = OnceLock::new();
    let outcome = match &decision.placement {
        Placement::Here => {
            if matches!(decision.reason, Reason::NoRoom { .. }) {
                eprintln!("{VERB}: running here: {}", decision.reason);
            }
            if let Some(link) = link.take() {
                let _ = link.connected.runtime.shutdown();
            }
            run_here(&spill.exec)
        }
        Placement::There(place) => {
            eprintln!("{VERB}: running on {place}: {}", decision.reason);
            let link = match link.take() {
                Some(link) => Ok(link),
                None => {
                    let at = Instant::now();
                    let made = connect(&runtime, &spill.exec.connect);
                    phases.insert("connect".into(), json!(ms(at, Instant::now())));
                    made
                }
            };
            match link {
                Ok(link) => {
                    let spawned = Instant::now();
                    let exec = ExecArgs { connect: Vec::new(), ..clone_exec(&spill.exec) };
                    let status =
                        runtime.block_on(exec_on(link.client.clone(), exec, Some(&first_output)));
                    if let Some(first) = first_output.get() {
                        phases.insert("first_output".into(), json!(ms(spawned, *first)));
                    }
                    let _ = link.connected.runtime.shutdown();
                    status
                }
                Err(error) => Err(error),
            }
        }
    };
    if spill.timings {
        let exit = match &outcome {
            Ok(code) => json!(code),
            Err(_) => json!(EXIT_TRANSPORT),
        };
        eprintln!(
            "{}",
            timings_line(
                &decision,
                first_output.get().map(|f| ms(started, *f)),
                phases,
                exit,
                ms(started, Instant::now()),
                place_error.as_deref()
            )
        );
    }
    match outcome {
        Ok(0) => Ok(()),
        Ok(code) => Err(ExitWith { code, error: None }.into()),
        Err(error) => Err(ExitWith { code: EXIT_TRANSPORT, error: Some(error) }.into()),
    }
}

/// `--timings`' JSON line.
pub(super) fn timings_line(
    decision: &Decision,
    spill_start_ms: Option<u64>,
    phases: Map<String, Value>,
    exit: Value,
    total_ms: u64,
    place_error: Option<&str>,
) -> Value {
    let mut line = json!({
        "spill_start_ms": spill_start_ms,
        "placement": decision.placement,
        "reason": decision.reason,
        "reason_text": decision.reason.to_string(),
        "phases": phases,
        "exit": exit,
        "total_ms": total_ms,
    });
    if let (Some(error), Some(map)) = (place_error, line.as_object_mut()) {
        map.insert("place_error".into(), json!(error));
    }
    line
}

fn clone_exec(exec: &ExecArgs) -> ExecArgs {
    ExecArgs {
        connect: exec.connect.clone(),
        cwd: exec.cwd.clone(),
        env: exec.env.clone(),
        tty: exec.tty,
        timeout_seconds: exec.timeout_seconds,
        argv: exec.argv.clone(),
    }
}

/// Runs the command here with this terminal's stdio; its status as a shell gives it.
fn run_here(exec: &ExecArgs) -> anyhow::Result<i32> {
    use std::os::unix::process::ExitStatusExt as _;
    let (program, args) =
        exec.argv.split_first().ok_or_else(|| anyhow!("{VERB}: no command to run"))?;
    let mut command = cmux_process::Command::new(program);
    command.args(args).envs(&exec.env);
    if let Some(cwd) = &exec.cwd {
        command.current_dir(cwd);
    }
    let status = command.status().map_err(|e| anyhow!("{VERB}: {program}: {e}"))?;
    Ok(status.code().or_else(|| status.signal().map(|s| 128 + s)).unwrap_or(EXIT_TRANSPORT))
}

#[cfg(test)]
#[path = "spill_tests.rs"]
mod tests;
