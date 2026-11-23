//! `--if`, `--watch` and the guardrails on the CLI, and `cmux automation test`
//! (cmuxterm-hq docs/automation-triggers.md).
//!
//! `test` is the dry run a person or an agent takes before saying an
//! automation works: it runs the condition with a sample event, reads the
//! guardrails' verdict and prints the exact prompt a run would send. It starts
//! no run and writes nothing.

use std::io::Read as _;
use std::process::Stdio;
use std::time::Duration;

use cmux_automations::exec::{Condition, context_text, pid_alive, prompt_text, run_condition};
use cmux_automations::{Automation, Body, CONDITION_TIMEOUT_SECONDS, Gate, Trigger, Verdict};
use serde_json::{Value, json};

use super::super::OutputMode;
use super::{Args, Failure, Out, Outcome, messages, now, open_store, parse_duration, usage, when};

/// A new watch's guardrails when none are given: at most one run per 10 min
/// and 24 a day, so a log that keeps failing cannot start runs without end.
const WATCH_COOLDOWN_SECONDS: u64 = 600;
const WATCH_MAX_RUNS: u32 = 24;

/// The guardrails a new automation on `trigger` starts with: a watch's, or
/// its event's row ([`cmux_automations::events`]); none for a schedule.
pub(super) fn guard_defaults(trigger: &Trigger) -> Option<(u64, Option<u32>)> {
    match trigger {
        Trigger::Watch { .. } => Some((WATCH_COOLDOWN_SECONDS, Some(WATCH_MAX_RUNS))),
        Trigger::Event { event, .. } => cmux_automations::events::find(event)
            .map(|kind| (kind.cooldown_seconds, kind.max_runs_per_day)),
        _ => None,
    }
}

/// `base` with `--if`, `--cooldown` and `--max-runs` applied. `--if ""`,
/// `--cooldown 0` and `--max-runs 0` turn one off. `defaults` (a new watch's
/// or event's) fill what no flag set.
pub(super) fn gate(
    a: &Args,
    base: Gate,
    defaults: Option<(u64, Option<u32>)>,
) -> Result<Gate, Failure> {
    let mut gate = base;
    if let Some((cooldown, max_runs)) = defaults {
        gate.cooldown_seconds = cooldown;
        gate.max_runs_per_day = max_runs;
    }
    if let Some(cmd) = a.value("if") {
        gate.condition = (!cmd.trim().is_empty()).then(|| cmd.to_string());
    }
    if let Some(d) = a.value("cooldown") {
        gate.cooldown_seconds = parse_duration(d)?;
    }
    if let Some(n) = a.value("max-runs") {
        let n: u32 = n
            .trim()
            .parse()
            .map_err(|_| Failure::Usage(messages().bad_max_runs.replace("{value}", n)))?;
        gate.max_runs_per_day = (n > 0).then_some(n);
    }
    Ok(gate)
}

/// The watch trigger `--watch CMD [--debounce 5s]` names.
pub(super) fn watch_trigger(a: &Args, command: &str) -> Result<Trigger, Failure> {
    let debounce_seconds = match a.value("debounce") {
        Some(d) => parse_duration(d)?,
        None => cmux_automations::DEFAULT_DEBOUNCE_SECONDS,
    };
    Ok(Trigger::Watch { command: command.to_string(), debounce_seconds })
}

/// The trigger `--when NAME [--debounce 5s]` names; the debounce defaults to the event's.
pub(super) fn event_trigger(a: &Args, name: &str) -> Result<Trigger, Failure> {
    let name = name.trim();
    let Some(kind) = cmux_automations::events::find(name) else {
        return usage(
            messages()
                .unknown_event
                .replace("{value}", name)
                .replace("{names}", &cmux_automations::events::names()),
        );
    };
    let debounce_seconds = match a.value("debounce") {
        Some(d) => parse_duration(d)?,
        None => kind.debounce_seconds,
    };
    Ok(Trigger::Event { event: kind.name.to_string(), debounce_seconds })
}

/// After `create`, for an event trigger: where its events come from and how late.
pub(super) fn print_event_source(trigger: &Trigger) {
    if let Trigger::Event { event, .. } = trigger
        && let Some(kind) = cmux_automations::events::find(event)
    {
        println!("  {}", kind.source);
    }
}

/// `600` as `10m`, `7200` as `2h`, `90` as `90s`.
fn duration_words(seconds: u64) -> String {
    match seconds {
        s if s % 3_600 == 0 => format!("{}h", s / 3_600),
        s if s % 60 == 0 => format!("{}m", s / 60),
        s => format!("{s}s"),
    }
}

/// The `show` lines of the condition and the guardrails.
pub(super) fn show_lines(x: &Automation, dropped: u64) {
    let m = messages();
    if let Trigger::Event { event, .. } = &x.trigger
        && let Some(kind) = cmux_automations::events::find(event)
    {
        println!("  {}: {}", m.event_source_label, kind.source);
    }
    if let Some(c) = &x.gate.condition {
        println!("  {}: {c}", m.condition_label);
    }
    let mut guards = Vec::new();
    if x.gate.cooldown_seconds > 0 {
        guards.push(format!("cooldown {}", duration_words(x.gate.cooldown_seconds)));
    }
    if let Some(n) = x.gate.max_runs_per_day {
        guards.push(format!("max {n} runs/24h"));
    }
    if !guards.is_empty() {
        println!("  {}: {}", m.guard_label, guards.join(", "));
    }
    if dropped > 0 {
        println!("  {}: {dropped}", m.dropped_label);
    }
}

fn verdict_json(v: &Verdict) -> Value {
    match v {
        Verdict::Go => json!({"verdict": "go"}),
        Verdict::Busy { run } => json!({"verdict": v.reason(), "run": run}),
        Verdict::Cooldown { until } | Verdict::Cap { until, .. } => {
            json!({"verdict": v.reason(), "until": until})
        }
    }
}

fn verdict_words(v: &Verdict) -> String {
    match v {
        Verdict::Go => String::new(),
        Verdict::Busy { run } => format!("run {run} is still live"),
        Verdict::Cooldown { until } => format!("cooling down until {}", when(*until)),
        Verdict::Cap { max, until } => format!("{max} runs in 24 h, next at {}", when(*until)),
    }
}

/// `test AUTOMATION [--event TEXT | --event-file FILE|-]`: exit 0 when it
/// would run now, 1 when not.
pub(super) fn test(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, &["event", "event-file"], &[])?;
    let store = open_store()?;
    let x = store.find(a.one_word("AUTOMATION")?)?;
    let event = match (a.value("event"), a.value("event-file")) {
        (Some(_), Some(_)) => return usage(messages().one_event),
        (Some(text), None) => text.to_string(),
        (None, Some("-")) => {
            let mut text = String::new();
            std::io::stdin()
                .read_to_string(&mut text)
                .map_err(|e| Failure::Usage(e.to_string()))?;
            text
        }
        (None, Some(path)) => {
            std::fs::read_to_string(path).map_err(|e| Failure::Usage(format!("{path}: {e}")))?
        }
        // An event trigger with no --event: the sample line its source would print.
        (None, None) => match &x.trigger {
            Trigger::Event { event, .. } => cmux_automations::events::find(event)
                .map(|kind| kind.sample.to_string())
                .unwrap_or_default(),
            _ => String::new(),
        },
    };
    let event = cmux_automations::clip_event(&event);
    let now = now();
    let history = store.runs(&x.id)?;
    let verdict = cmux_automations::verdict(&x.gate, &history, now, &pid_alive);
    let condition = x.gate.condition.as_ref().map(|cmd| {
        let env = [
            ("CMUX_AUTOMATION_ID", x.id.clone()),
            ("CMUX_AUTOMATION_RUN_ID", "run_test".to_string()),
            ("CMUX_AUTOMATION_TRIGGER", "test".to_string()),
        ];
        // The script's stderr goes where `test` prints it: never into a JSON answer.
        let stderr = if output == OutputMode::Human { Stdio::inherit() } else { Stdio::null() };
        let decided = run_condition(
            cmd,
            x.body.folder(),
            &event,
            &env,
            stderr,
            Duration::from_secs(CONDITION_TIMEOUT_SECONDS),
        );
        (cmd.clone(), decided)
    });
    let (condition_go, condition_output, condition_json) = match &condition {
        None => (true, String::new(), Value::Null),
        Some((cmd, Condition::Go { output })) => {
            (true, output.clone(), json!({"command": cmd, "result": "go", "output": output}))
        }
        Some((cmd, Condition::No { output })) => (
            false,
            output.clone(),
            json!({"command": cmd, "result": "no", "reason": "condition_false", "output": output}),
        ),
        Some((cmd, Condition::Failed { reason, output })) => (
            false,
            output.clone(),
            json!({"command": cmd, "result": "failed", "reason": reason, "output": output}),
        ),
    };
    let would_run = x.enabled && verdict == Verdict::Go && condition_go;
    let context = context_text(Some(event.as_str()).filter(|e| !e.is_empty()), &condition_output);
    let dropped = store.state(&x.id)?.dropped;
    let (prompt, command) = match &x.body {
        Body::Prompt { prompt, .. } => {
            let header = format!("[cmux automation \"{}\" run run_test]", x.name);
            (Some(prompt_text(&header, "run_test", prompt, &context, dropped)), None)
        }
        Body::Command { command, .. } => (None, Some(command.clone())),
    };
    if output == OutputMode::Json {
        out.value(&json!({
            "automation": x.id,
            "name": x.name,
            "enabled": x.enabled,
            "would_run": would_run,
            "guard": verdict_json(&verdict),
            "condition": condition_json,
            "event": event,
            "prompt": prompt,
            "command": command,
        }));
    } else if output != OutputMode::Quiet {
        let m = messages();
        if let Some((cmd, decided)) = &condition {
            let result = match decided {
                Condition::Go { .. } => "go (exit 0)".to_string(),
                Condition::No { .. } => "no (exit 1)".to_string(),
                Condition::Failed { reason, .. } => format!("failed ({reason})"),
            };
            println!("{}: {cmd} -> {result}", m.condition_label);
            if !condition_output.trim().is_empty() {
                println!("{}", condition_output.trim_end());
            }
        }
        if would_run {
            println!("{}", m.test_would_run);
        } else {
            let why = if !x.enabled {
                m.paused.to_string()
            } else if verdict != Verdict::Go {
                verdict_words(&verdict)
            } else {
                "condition".to_string()
            };
            println!("{}", m.test_would_not_run.replace("{reason}", &why));
        }
        match (&prompt, &command) {
            (Some(p), _) => println!("{}\n\n{p}", m.test_prompt),
            (None, Some(c)) => println!("{}\n\n{c}", m.test_command),
            _ => {}
        }
    }
    Ok(if would_run { 0 } else { 1 })
}
