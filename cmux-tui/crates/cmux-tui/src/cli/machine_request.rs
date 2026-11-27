//! `cmux machine request --vcpu N [--mem M] [--fanout K] [--kind linux|mac|gpu] --for WHY
//! [--until DONE|DURATION] [--json]`: the agent on a cmux Cloud machine asks for more capacity.
//!
//! Leo, 2026-11-25: "but what if we want even more than the 32vcpu machines? how can an agent
//! know/ask for more capacity?" and "when they're on the vm that is". cmuxterm-hq RFD draft
//! `docs/rfd/drafts/agent-work-placement.md`, sections 9 and 13.
//!
//! The ask goes over this machine's agent socket (`cmux-host` `cloud/machine_request.rs`), which
//! sends `cloud.vm.machine.request` as the machine's own `vm` install: no person's token, and
//! the machine is always this one. The answer is at once, never a wait: the machine already fits,
//! it grows now within the plan, the ask is past the plan (the largest size it takes and the plan
//! that lifts it), it takes a fan-out past one machine, or the kind is not offered.

use std::io::Write;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::OutputMode;

/// The agent's answer comes from one platform op; the agent's own bound is 60 s queued.
const ASK_BOUND: Duration = Duration::from_secs(90);

pub(super) const USAGE: &str = "usage: cmux machine request --vcpu N [--mem GIB] [--fanout K] [--kind linux|mac|gpu] --for \"why\" [--until DONE|30m|2h|1d] [--json]\n\n\
Ask for more capacity for the work this cmux Cloud machine runs. Answers at once: the machine\n\
already has it, it grows now (within your plan), what your plan allows instead, or a fan-out of\n\
several machines made now past the largest one (32 vCPU / 64 GiB), with each machine's id. Run it on the Cloud machine itself:\n\
it speaks as the machine, with no sign-in.";

#[derive(Debug, PartialEq)]
pub(super) struct Ask(pub Map<String, Value>);

fn whole(name: &str, raw: &str) -> Result<u64, String> {
    let digits = raw.trim().trim_end_matches(|c: char| c.is_ascii_alphabetic());
    digits
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| format!("--{name} takes a whole number above 0 (got `{raw}`)"))
}

/// The words after `machine request`.
pub(super) fn parse(rest: &[String]) -> Result<Ask, String> {
    let mut ask = Map::new();
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut value = |name: &str| {
            inline
                .clone()
                .or_else(|| words.next().cloned())
                .ok_or_else(|| format!("--{name} needs a value"))
        };
        match flag {
            "--vcpu" | "--cpu" | "--cores" => {
                ask.insert("vcpu".into(), json!(whole("vcpu", &value("vcpu")?)?));
            }
            "--mem" | "--memory" => {
                ask.insert("mem_gib".into(), json!(whole("mem", &value("mem")?)?));
            }
            "--fanout" => {
                ask.insert("fanout".into(), json!(whole("fanout", &value("fanout")?)?));
            }
            "--kind" => {
                let kind = value("kind")?.to_ascii_lowercase();
                if !["linux", "mac", "gpu"].contains(&kind.as_str()) {
                    return Err("--kind is linux, mac or gpu".to_owned());
                }
                ask.insert("kind".into(), json!(kind));
            }
            "--for" => {
                ask.insert("for".into(), json!(value("for")?));
            }
            "--until" => {
                ask.insert("until".into(), json!(value("until")?));
            }
            other => return Err(format!("unknown option `{other}`\n\n{USAGE}")),
        }
    }
    if !ask.contains_key("vcpu") {
        return Err(format!("--vcpu is required\n\n{USAGE}"));
    }
    if !ask.contains_key("for") {
        return Err(format!("--for is required: say what the capacity is for\n\n{USAGE}"));
    }
    Ok(Ask(ask))
}

/// The human line for an answer.
pub(super) fn human(reply: &Value) -> String {
    let message = reply.get("message").and_then(Value::as_str).unwrap_or("");
    let outcome = reply.get("outcome").and_then(Value::as_str).unwrap_or("");
    match outcome {
        "" => message.to_owned(),
        _ => format!("{outcome}: {message}"),
    }
}

/// The exit code for an answer: 0 when the machine has or gets the capacity, 3 otherwise (the
/// agent reads the message for what to do).
pub(super) fn exit_code(reply: &Value) -> i32 {
    match reply.get("outcome").and_then(Value::as_str) {
        Some("fits" | "grow") => 0,
        _ => 3,
    }
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [scope, verb, rest @ ..] = command_args.as_slice() else { return None };
    if !matches!(scope.as_str(), "machine" | "vm") || verb != "request" {
        return None;
    }
    if rest.iter().any(|w| w == "--help" || w == "-h") {
        println!("{USAGE}");
        return Some(0);
    }
    let fail = |code: &str, message: &str, exit: i32| {
        super::app::failure(code, &format!("cmux: {message}"), global.output, exit)
    };
    let ask = match parse(rest) {
        Ok(ask) => ask,
        Err(message) => return Some(fail("usage", &message, 2)),
    };
    Some(send(&ask, global.output, &mut std::io::stdout(), &fail))
}

#[cfg(unix)]
fn send(
    ask: &Ask,
    output: OutputMode,
    out: &mut dyn Write,
    fail: &dyn Fn(&str, &str, i32) -> i32,
) -> i32 {
    let line = json!({ "machine_request": Value::Object(ask.0.clone()) });
    let agent = cmux_apps::system::AgentSocket::default();
    match agent.ask(&line, ASK_BOUND) {
        Ok(reply) => print(&reply, output, out),
        Err(refused) => fail(&refused.code, &refused.message, 1),
    }
}

#[cfg(not(unix))]
fn send(_: &Ask, _: OutputMode, _: &mut dyn Write, fail: &dyn Fn(&str, &str, i32) -> i32) -> i32 {
    fail("machine.unavailable", "run `cmux machine request` on a cmux Cloud machine", 1)
}

pub(super) fn print(reply: &Value, output: OutputMode, out: &mut dyn Write) -> i32 {
    let written = match output {
        OutputMode::Human => writeln!(out, "{}", human(reply)),
        OutputMode::Json | OutputMode::JsonLines => {
            let mut value = reply.clone();
            if let Some(map) = value.as_object_mut() {
                map.remove("ok");
            }
            writeln!(out, "{value}")
        }
        OutputMode::Quiet => Ok(()),
    };
    if written.is_err() {
        return 1;
    }
    exit_code(reply)
}

#[cfg(test)]
#[path = "machine_request_tests.rs"]
mod tests;
