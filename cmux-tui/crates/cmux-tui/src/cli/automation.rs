//! `cmux automation …`: scheduled prompts and commands on this machine
//! (docs/automations-platonic-ideal.md, slice 1).
//!
//! The store and the schedule rules are the `cmux-automations` crate; this
//! file is the grammar, the output and the runner process. A run never runs
//! inside the CLI process that started it: `run` and the runner start
//! `cmux automation _exec AUTOMATION RUN` in its own process group, so a run
//! outlives the command (and a runner restart).

use std::io::Write as _;
use std::path::PathBuf;
use std::time::Duration;

use cmux_automations::exec::{ProcessExecutor, run_job};
use cmux_automations::{
    Automation, AutomationSpec, Body, CatchUp, Run, RunState, RunnerLock, Store, StoreError,
    Trigger, Zone, recover_orphans, start_manual, tick,
};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::OutputMode;
use crate::localization::AutomationMessages;

mod teleport;

/// The runner never sleeps longer than this, so a new automation, a clock
/// change or a wake from sleep is seen within a minute.
const MAX_SLEEP: Duration = Duration::from_secs(60);
/// The launchd label of `runner install`.
const LAUNCHD_LABEL: &str = "com.cmuxterm.automations";

fn messages() -> &'static AutomationMessages {
    &crate::localization::catalog().automation
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// `Some(exit code)` when `args` is `automation …` (or `automations …`).
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "automation" && first != "automations" {
        return None;
    }
    // `automation show-page` is the app's `automations.show` (it opens the Automations page): the
    // app action fallback runs it.
    if rest.first().is_some_and(|verb| verb == "show-page") {
        return None;
    }
    let output = global.output;
    Some(match dispatch(rest, &global, &Out::printing(output)) {
        Ok(code) => code,
        Err(failure) => {
            let (code, message, exit) = failure.parts();
            super::app::failure(code, &format!("cmux: {message}"), output, exit)
        }
    })
}

/// `cmux automation WORDS…` in this process, its JSON answer returned
/// instead of printed: the MCP `automation_*` tools run the CLI's own verbs
/// through it. `Err((error, outcome_unknown))`: `outcome_unknown` when a
/// mutation may have applied (a transport failure after sending).
pub(super) fn run_json(
    global: &super::GlobalArgs,
    words: &[String],
) -> Result<Value, (Value, bool)> {
    let out = Out::capturing();
    let result = dispatch(words, global, &out);
    let captured = out.take();
    match (result, captured) {
        (Err(failure), _) => {
            let (code, message, _) = failure.parts();
            Err((
                json!({"code": code, "message": message, "details": {}, "retryable": false}),
                false,
            ))
        }
        (Ok(_), Some(answer)) => answer,
        (Ok(0), None) => Ok(json!({})),
        (Ok(exit), None) => Err((
            json!({"code": "automation.failed", "message": format!("exit {exit}"), "details": {}, "retryable": false}),
            false,
        )),
    }
}

/// Where a verb's answer goes: printed (the CLI), or kept for
/// [`run_json`] (MCP). A capturing sink is JSON mode, so no verb prints
/// human text into the MCP server's stdout.
pub(super) struct Out {
    pub(super) mode: OutputMode,
    captured: Option<std::cell::RefCell<Option<CapturedResult>>>,
}

/// What `Out` holds while captured: the result, or the error value and whether
/// it is a usage error.
type CapturedResult = Result<Value, (Value, bool)>;

impl Out {
    pub(super) fn printing(mode: OutputMode) -> Out {
        Out { mode, captured: None }
    }

    fn capturing() -> Out {
        Out { mode: OutputMode::Json, captured: Some(std::cell::RefCell::new(None)) }
    }

    fn take(&self) -> Option<Result<Value, (Value, bool)>> {
        self.captured.as_ref().and_then(|c| c.borrow_mut().take())
    }

    /// A verb's JSON answer.
    pub(super) fn value(&self, v: &Value) {
        match &self.captured {
            Some(c) => *c.borrow_mut() = Some(Ok(v.clone())),
            None => print_json(v),
        }
    }

    /// A Cloud (or destination) refusal; the exit code.
    pub(super) fn refusal(&self, error: &Value) -> i32 {
        match &self.captured {
            Some(c) => {
                *c.borrow_mut() = Some(Err((error.clone(), false)));
                cloud::refusal_exit(error)
            }
            None => cloud::print_refusal(error, self.mode),
        }
    }

    /// A local or transport error; `unknown`: a mutation may have applied.
    pub(super) fn error(&self, error: &Value, exit: i32, unknown: bool) -> i32 {
        match &self.captured {
            Some(c) => {
                *c.borrow_mut() = Some(Err((error.clone(), unknown)));
                exit
            }
            None => super::wire::print_local_error(error, self.mode, exit),
        }
    }
}

enum Failure {
    Usage(String),
    Store(StoreError),
}

impl Failure {
    /// The error code, message and exit code.
    fn parts(&self) -> (&'static str, String, i32) {
        match self {
            Failure::Usage(message) => ("usage.invalid", message.clone(), 2),
            Failure::Store(e @ StoreError::NotFound(_)) => {
                ("automation.not_found", e.to_string(), 1)
            }
            Failure::Store(e) => ("automation.failed", e.to_string(), 1),
        }
    }
}

impl From<StoreError> for Failure {
    fn from(e: StoreError) -> Self {
        Failure::Store(e)
    }
}

type Outcome = Result<i32, Failure>;

fn usage<T>(message: impl Into<String>) -> Result<T, Failure> {
    Err(Failure::Usage(message.into()))
}

fn open_store() -> Result<Store, Failure> {
    let root = Store::default_root().ok_or_else(|| Failure::Usage(messages().no_home.into()))?;
    Ok(Store::open(&root)?.with_home(machine_home()))
}

/// `mac:<machine id>` from the state root's `machine-id` (read only, never
/// made here), else `mac:local`.
fn machine_home() -> String {
    crate::feature_flags::state_root()
        .and_then(|root| std::fs::read_to_string(root.join("machine-id")).ok())
        .map(|text| text.trim().to_string())
        .filter(|id| {
            !id.is_empty()
                && id.len() <= 128
                && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        })
        .map(|id| format!("mac:{id}"))
        .unwrap_or_else(|| cmux_automations::LOCAL_HOME.to_string())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// `--name value` / `--name=value` options and boolean flags, in any order
/// around the positional words.
struct Args {
    words: Vec<String>,
    values: Vec<(String, String)>,
    flags: Vec<String>,
}

impl Args {
    fn parse(args: &[String], valued: &[&str], flags: &[&str]) -> Result<Args, Failure> {
        let mut out = Args { words: Vec::new(), values: Vec::new(), flags: Vec::new() };
        let mut rest = args.iter();
        while let Some(arg) = rest.next() {
            if let Some(name) = arg.strip_prefix("--") {
                let (name, inline) = match name.split_once('=') {
                    Some((n, v)) => (n, Some(v.to_string())),
                    None => (name, None),
                };
                if valued.contains(&name) {
                    let value = match inline {
                        Some(v) => v,
                        None => rest.next().cloned().ok_or_else(|| {
                            Failure::Usage(messages().missing_value.replace("{flag}", name))
                        })?,
                    };
                    out.values.push((name.to_string(), value));
                } else if flags.contains(&name) && inline.is_none() {
                    out.flags.push(name.to_string());
                } else {
                    return usage(messages().unknown_flag.replace("{flag}", arg));
                }
            } else {
                out.words.push(arg.clone());
            }
        }
        Ok(out)
    }

    fn value(&self, name: &str) -> Option<&str> {
        self.values.iter().rev().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
    }

    /// Every value of a repeatable option, in order.
    fn values_of(&self, name: &str) -> Vec<&str> {
        self.values.iter().filter(|(n, _)| n == name).map(|(_, v)| v.as_str()).collect()
    }

    fn flag(&self, name: &str) -> bool {
        self.flags.iter().any(|f| f == name)
    }

    fn one_word(&self, what: &str) -> Result<&str, Failure> {
        match self.words.as_slice() {
            [one] => Ok(one),
            [] => usage(messages().missing_word.replace("{what}", what)),
            [_, extra, ..] => usage(messages().unexpected_argument.replace("{value}", extra)),
        }
    }
}

const SCHEDULE_FLAGS: &[&str] = &["daily", "weekdays", "weekly", "every", "at", "in", "cron"];
const SPEC_VALUED: &[&str] = &[
    "prompt", "command", "daily", "weekdays", "weekly", "every", "at", "in", "cron", "tz",
    "folder", "model", "timeout", "catch-up", "name",
];
const SPEC_FLAGS: &[&str] = &["hourly", "manual", "paused"];

/// `--target local|cloud` anywhere in the words; `true` for cloud, and the words without it.
fn take_target(args: &[String]) -> Result<(bool, Vec<String>), Failure> {
    let mut out = Vec::with_capacity(args.len());
    let mut target = None;
    let mut words = args.iter();
    while let Some(arg) = words.next() {
        if let Some(v) = arg.strip_prefix("--target=") {
            target = Some(v.to_string());
        } else if arg == "--target" {
            target = Some(words.next().cloned().ok_or_else(|| {
                Failure::Usage(messages().missing_value.replace("{flag}", "target"))
            })?);
        } else {
            out.push(arg.clone());
        }
    }
    match target.as_deref() {
        None | Some("local" | "this-mac") => Ok((false, out)),
        Some("cloud") => Ok((true, out)),
        Some(other) => usage(messages().bad_target.replace("{value}", other)),
    }
}

fn dispatch(args: &[String], global: &super::GlobalArgs, out: &Out) -> Outcome {
    let (cloud, args) = take_target(args)?;
    if cloud {
        return cloud_dispatch(&args, global, out);
    }
    let Some((verb, rest)) = args.split_first() else {
        print!("{}", messages().usage);
        return Ok(0);
    };
    match verb.as_str() {
        "help" | "-h" | "--help" => {
            print!("{}", messages().usage);
            Ok(0)
        }
        "create" | "new" | "add" => create(rest, out),
        "list" | "ls" => list(rest, out),
        "show" | "get" => show(rest, out),
        "run" => run_now(rest, out),
        "pause" => set_enabled(rest, false, out),
        "resume" => set_enabled(rest, true, out),
        "edit" | "update" => edit(rest, out),
        "history" | "runs" => history(rest, out),
        "logs" | "log" => logs(rest, out),
        "delete" | "rm" => delete(rest, out),
        "teleport" | "move" => teleport::run(rest, global, out, false),
        "import" => teleport::import(rest, out),
        "runner" => runner(rest, out),
        "_exec" => exec(rest),
        other => usage(messages().unknown_verb.replace("{verb}", other)),
    }
}

// ------------------------------------------------------------- parsing helpers

/// `90s`, `30m`, `2h`, `1d`, or plain seconds.
fn parse_duration(text: &str) -> Result<u64, Failure> {
    let text = text.trim();
    let (digits, unit) =
        text.split_at(text.find(|c: char| !c.is_ascii_digit()).unwrap_or(text.len()));
    let n: u64 = digits
        .parse()
        .map_err(|_| Failure::Usage(messages().bad_duration.replace("{value}", text)))?;
    let scale = match unit {
        "" | "s" => 1,
        "m" | "min" => 60,
        "h" => 3_600,
        "d" => 86_400,
        _ => return usage(messages().bad_duration.replace("{value}", text)),
    };
    Ok(n * scale)
}

/// `HH:MM` (24 h).
fn parse_clock(text: &str) -> Result<(u32, u32), Failure> {
    let bad = || Failure::Usage(messages().bad_time.replace("{value}", text));
    let (h, m) = text.trim().split_once(':').ok_or_else(bad)?;
    let (h, m): (u32, u32) = (h.parse().map_err(|_| bad())?, m.parse().map_err(|_| bad())?);
    if h > 23 || m > 59 {
        return Err(bad());
    }
    Ok((h, m))
}

fn parse_weekday(text: &str) -> Result<u32, Failure> {
    const NAMES: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
    let lower = text.trim().to_ascii_lowercase();
    if let Ok(n) = lower.parse::<u32>() {
        return if n <= 7 {
            Ok(n % 7)
        } else {
            usage(messages().bad_weekday.replace("{value}", text))
        };
    }
    NAMES
        .iter()
        .position(|n| lower.starts_with(n))
        .map(|i| i as u32)
        .ok_or_else(|| Failure::Usage(messages().bad_weekday.replace("{value}", text)))
}

/// `YYYY-MM-DD HH:MM`, `YYYY-MM-DDTHH:MM`, or `HH:MM` (the next one), in `zone`.
fn parse_at(text: &str, zone: Zone, now: i64) -> Result<i64, Failure> {
    let bad = || Failure::Usage(messages().bad_at.replace("{value}", text));
    let text = text.trim();
    if let Some((date, clock)) = text.split_once([' ', 'T']) {
        let parts: Vec<&str> = date.split('-').collect();
        let [y, mo, d] = parts.as_slice() else { return Err(bad()) };
        let (y, mo, d): (i32, i64, i64) = (
            y.parse().map_err(|_| bad())?,
            mo.parse().map_err(|_| bad())?,
            d.parse().map_err(|_| bad())?,
        );
        let (h, m) = parse_clock(clock)?;
        return Ok(zone.timestamp(y, mo, d, h as i64, m as i64));
    }
    let (h, m) = parse_clock(text)?;
    let today = zone.civil(now);
    let mut t =
        zone.timestamp(today.year, today.month as i64, today.day as i64, h as i64, m as i64);
    if t <= now {
        t = zone.timestamp(
            today.year,
            today.month as i64,
            today.day as i64 + 1,
            h as i64,
            m as i64,
        );
    }
    Ok(t)
}

fn parse_trigger(a: &Args, now: i64) -> Result<Option<Trigger>, Failure> {
    let zone = Zone::parse(a.value("tz").unwrap_or("local")).map_err(Failure::Usage)?;
    let chosen: Vec<&str> = SCHEDULE_FLAGS
        .iter()
        .copied()
        .filter(|f| a.value(f).is_some())
        .chain(["hourly", "manual"].into_iter().filter(|f| a.flag(f)))
        .collect();
    if chosen.len() > 1 {
        return usage(messages().one_schedule.replace("{flags}", &chosen.join(", --")));
    }
    let Some(kind) = chosen.first() else { return Ok(None) };
    let value = a.value(kind).unwrap_or_default();
    let trigger = match *kind {
        "hourly" => Trigger::preset_hourly(zone),
        "manual" => Trigger::Manual,
        "daily" => {
            let (h, m) = parse_clock(value)?;
            Trigger::preset_daily(h, m, zone)
        }
        "weekdays" => {
            let (h, m) = parse_clock(value)?;
            Trigger::preset_weekdays(h, m, zone)
        }
        "weekly" => {
            let (day, clock) = value
                .split_once([' ', '@'])
                .ok_or_else(|| Failure::Usage(messages().bad_weekly.replace("{value}", value)))?;
            let (h, m) = parse_clock(clock)?;
            Trigger::preset_weekly(parse_weekday(day)?, h, m, zone)
        }
        "every" => Trigger::Every { seconds: parse_duration(value)?, anchor: now },
        "at" => Trigger::At { at: parse_at(value, zone, now)? },
        "in" => Trigger::At { at: now + parse_duration(value)? as i64 },
        "cron" => Trigger::Cron { expr: value.to_string(), tz: zone.name().to_string() },
        _ => return Ok(None),
    };
    trigger.validate().map_err(|e| Failure::Usage(e.0))?;
    Ok(Some(trigger))
}

fn parse_catch_up(text: &str) -> Result<CatchUp, Failure> {
    match text {
        "latest" => Ok(CatchUp::default()),
        "all" => Ok(CatchUp::All { max: 10 }),
        "none" => Ok(CatchUp::None),
        other => usage(messages().bad_catch_up.replace("{value}", other)),
    }
}

fn folder_arg(a: &Args) -> Result<Option<String>, Failure> {
    let Some(folder) = a.value("folder") else { return Ok(None) };
    let path = PathBuf::from(folder);
    let absolute = if path.is_absolute() || folder.starts_with("~/") {
        path
    } else {
        std::env::current_dir().map_err(|e| Failure::Store(e.into()))?.join(path)
    };
    Ok(Some(absolute.to_string_lossy().into_owned()))
}

// ------------------------------------------------------------- output helpers

fn when(t: i64) -> String {
    let c = Zone::Local.civil(t);
    format!("{:04}-{:02}-{:02} {:02}:{:02}", c.year, c.month, c.day, c.hour, c.minute)
}

fn describe_trigger(t: &Trigger) -> String {
    match t {
        Trigger::At { at } => messages().once_at.replace("{time}", &when(*at)),
        Trigger::Manual => messages().manual_only.into(),
        other => other.describe(),
    }
}

fn automation_json(store: &Store, a: &Automation) -> Value {
    let next = if a.enabled {
        a.trigger
            .next_after(now().max(store.state(&a.id).map(|s| s.handled_through).unwrap_or(0)))
            .ok()
            .flatten()
    } else {
        None
    };
    let last = store
        .runs(&a.id)
        .ok()
        .and_then(|r| r.into_iter().rev().find(|r| r.state != RunState::Skipped));
    let mut v = serde_json::to_value(a).unwrap_or(Value::Null);
    if let Value::Object(map) = &mut v {
        map.insert("next_run_at".into(), json!(next));
        map.insert("last_run".into(), serde_json::to_value(last).unwrap_or(Value::Null));
    }
    v
}

fn print_json(v: &Value) {
    println!("{}", serde_json::to_string_pretty(v).unwrap_or_default());
}

fn state_label(r: &Run) -> String {
    match &r.reason {
        Some(reason) => format!("{} ({reason})", r.state.name()),
        None => r.state.name().to_string(),
    }
}

fn runner_running(store: &Store) -> bool {
    matches!(RunnerLock::acquire(store), Ok(None))
}

// ------------------------------------------------------------- verbs

fn create(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, SPEC_VALUED, SPEC_FLAGS)?;
    let name = match (a.value("name"), a.words.as_slice()) {
        (Some(n), []) => n.to_string(),
        (None, [n]) => n.clone(),
        (None, []) => return usage(messages().missing_word.replace("{what}", "NAME")),
        (_, [_, extra, ..]) | (Some(_), [extra]) => {
            return usage(messages().unexpected_argument.replace("{value}", extra));
        }
    };
    let now = now();
    let trigger =
        parse_trigger(&a, now)?.ok_or_else(|| Failure::Usage(messages().need_schedule.into()))?;
    let folder = folder_arg(&a)?;
    let body = match (a.value("prompt"), a.value("command")) {
        (Some(prompt), None) => Body::Prompt {
            prompt: prompt.into(),
            folder,
            model: a.value("model").map(str::to_string),
        },
        (None, Some(command)) => Body::Command { command: command.into(), folder },
        _ => return usage(messages().need_body),
    };
    let spec = AutomationSpec {
        name,
        trigger,
        body,
        catch_up: a.value("catch-up").map(parse_catch_up).transpose()?.unwrap_or_default(),
        timeout_seconds: a.value("timeout").map(parse_duration).transpose()?.unwrap_or(30 * 60),
        enabled: !a.flag("paused"),
    };
    let store = open_store()?;
    let created = store.create(spec, now)?;
    let runner = runner_running(&store);
    if output == OutputMode::Json {
        let mut v = automation_json(&store, &created);
        if let Value::Object(map) = &mut v {
            map.insert("runner_running".into(), json!(runner));
        }
        out.value(&v);
    } else if output != OutputMode::Quiet {
        println!(
            "{}",
            messages()
                .created
                .replace("{name}", &created.name)
                .replace("{id}", &created.id)
                .replace("{when}", &describe_trigger(&created.trigger))
        );
        if let Some(next) = created.trigger.next_after(now).ok().flatten() {
            println!("{}", messages().next_run.replace("{time}", &when(next)));
        }
        if !runner && !matches!(created.trigger, Trigger::Manual) {
            println!("{}", messages().runner_hint);
        }
    }
    Ok(0)
}

fn list(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, &[], &[])?;
    if let Some(extra) = a.words.first() {
        return usage(messages().unexpected_argument.replace("{value}", extra));
    }
    let store = open_store()?;
    let all = store.list()?;
    let moved = store.moved(now_ms())?;
    if output == OutputMode::Json {
        out.value(
            &json!({ "automations": all.iter().map(|x| automation_json(&store, x)).collect::<Vec<_>>(), "moved": moved, "runner_running": runner_running(&store) }),
        );
        return Ok(0);
    }
    for t in &moved {
        println!(
            "{}  {:<28} {}",
            t.id,
            t.name,
            messages().moved_row.replace("{to}", &t.moved_to).replace("{id}", &t.moved_id)
        );
    }
    if all.is_empty() && moved.is_empty() {
        println!("{}", messages().none_yet);
        return Ok(0);
    }
    for x in &all {
        let v = automation_json(&store, x);
        let next =
            v.get("next_run_at").and_then(Value::as_i64).map(when).unwrap_or_else(|| "-".into());
        let last = v
            .get("last_run")
            .and_then(|r| r.get("state"))
            .and_then(Value::as_str)
            .unwrap_or("-")
            .to_string();
        let status = if x.enabled { messages().active } else { messages().paused };
        println!(
            "{}  {:<28} {:<10} {:<34} {} {:<17} {} {}",
            x.id,
            x.name,
            status,
            describe_trigger(&x.trigger),
            messages().next_label,
            next,
            messages().last_label,
            last
        );
    }
    if !runner_running(&store) {
        println!("{}", messages().runner_hint);
    }
    Ok(0)
}

fn show(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, &[], &[])?;
    let store = open_store()?;
    let x = store.find(a.one_word("AUTOMATION")?)?;
    let v = automation_json(&store, &x);
    if output == OutputMode::Json {
        out.value(&v);
        return Ok(0);
    }
    println!("{} ({})", x.name, x.id);
    println!("  {}: {}", messages().schedule_label, describe_trigger(&x.trigger));
    println!(
        "  {}: {}",
        messages().status_label,
        if x.enabled { messages().active } else { messages().paused }
    );
    match &x.body {
        Body::Prompt { prompt, model, .. } => {
            println!("  {}: {}", messages().prompt_label, prompt);
            if let Some(m) = model {
                println!("  {}: {m}", messages().model_label);
            }
        }
        Body::Command { command, .. } => println!("  {}: {command}", messages().command_label),
    }
    if let Some(f) = x.body.folder() {
        println!("  {}: {f}", messages().folder_label);
    }
    if let Some(next) = v.get("next_run_at").and_then(Value::as_i64) {
        println!("  {}: {}", messages().next_label, when(next));
    }
    for r in store.runs(&x.id)?.iter().rev().take(5) {
        println!(
            "  {}  {}  {}",
            r.id,
            when(r.started_at.or(r.scheduled_at).unwrap_or(r.created_at)),
            state_label(r)
        );
    }
    Ok(0)
}

fn run_now(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, &["key"], &["wait"])?;
    let store = open_store()?;
    let x = store.find(a.one_word("AUTOMATION")?)?;
    let key = a
        .value("key")
        .map(str::to_string)
        .unwrap_or_else(|| format!("cli-{}-{}", now(), std::process::id()));
    let mut exec = executor(&store)?;
    let run = start_manual(&store, &x.id, &key, now(), &mut exec)?;
    if a.flag("wait") {
        let pid = store.run(&x.id, &run)?.and_then(|r| r.pid);
        if let Some(pid) = pid {
            exec.wait(pid);
        }
    }
    let record = store.run(&x.id, &run)?;
    if output == OutputMode::Json {
        out.value(&serde_json::to_value(&record).unwrap_or(Value::Null));
    } else if output != OutputMode::Quiet {
        let state = record.as_ref().map(state_label).unwrap_or_default();
        println!(
            "{}",
            messages()
                .run_started
                .replace("{name}", &x.name)
                .replace("{run}", &run)
                .replace("{state}", &state)
        );
        println!("{}", messages().logs_hint.replace("{run}", &run));
    }
    let failed = record.is_some_and(|r| r.state == RunState::Failed);
    Ok(if failed { 1 } else { 0 })
}

fn set_enabled(args: &[String], enabled: bool, out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, &[], &[])?;
    let store = open_store()?;
    let x = store.find(a.one_word("AUTOMATION")?)?;
    let x = store.set_enabled(&x.id, enabled, now())?;
    if output == OutputMode::Json {
        out.value(&automation_json(&store, &x));
    } else if output != OutputMode::Quiet {
        let line = if enabled { messages().resumed } else { messages().paused_done };
        println!("{}", line.replace("{name}", &x.name));
    }
    Ok(0)
}

fn edit(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, SPEC_VALUED, SPEC_FLAGS)?;
    let store = open_store()?;
    let x = store.find(a.one_word("AUTOMATION")?)?;
    let now = now();
    let mut spec = x.spec();
    if let Some(name) = a.value("name") {
        spec.name = name.into();
    }
    if let Some(trigger) = parse_trigger(&a, now)? {
        spec.trigger = trigger;
    }
    let folder = match a.value("folder") {
        Some(_) => folder_arg(&a)?,
        None => x.body.folder().map(str::to_string),
    };
    spec.body = match (&x.body, a.value("prompt"), a.value("command")) {
        (_, Some(_), Some(_)) => return usage(messages().need_body),
        (_, Some(p), None) => Body::Prompt {
            prompt: p.into(),
            folder,
            model: a.value("model").map(str::to_string).or(match &x.body {
                Body::Prompt { model, .. } => model.clone(),
                Body::Command { .. } => None,
            }),
        },
        (_, None, Some(c)) => Body::Command { command: c.into(), folder },
        (Body::Prompt { prompt, model, .. }, None, None) => Body::Prompt {
            prompt: prompt.clone(),
            folder,
            model: a.value("model").map(str::to_string).or(model.clone()),
        },
        (Body::Command { command, .. }, None, None) => {
            Body::Command { command: command.clone(), folder }
        }
    };
    if let Some(c) = a.value("catch-up") {
        spec.catch_up = parse_catch_up(c)?;
    }
    if let Some(t) = a.value("timeout") {
        spec.timeout_seconds = parse_duration(t)?;
    }
    if a.flag("paused") {
        spec.enabled = false;
    }
    let x = store.update(&x.id, spec, now)?;
    if output == OutputMode::Json {
        out.value(&automation_json(&store, &x));
    } else if output != OutputMode::Quiet {
        println!(
            "{}",
            messages()
                .updated
                .replace("{name}", &x.name)
                .replace("{version}", &x.version.to_string())
        );
    }
    Ok(0)
}

fn history(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, &["limit", "state"], &[])?;
    let store = open_store()?;
    let limit: usize = match a.value("limit") {
        Some(n) => {
            n.parse().map_err(|_| Failure::Usage(messages().bad_limit.replace("{value}", n)))?
        }
        None => 20,
    };
    let targets = match a.words.as_slice() {
        [] => store.list()?,
        [one] => vec![store.find(one)?],
        [_, extra, ..] => return usage(messages().unexpected_argument.replace("{value}", extra)),
    };
    let mut rows: Vec<(String, Run)> = Vec::new();
    for t in &targets {
        for r in store.runs(&t.id)? {
            if a.value("state").is_none_or(|s| s == r.state.name()) {
                rows.push((t.name.clone(), r));
            }
        }
    }
    rows.sort_by_key(|(_, r)| {
        std::cmp::Reverse(r.started_at.or(r.scheduled_at).unwrap_or(r.created_at))
    });
    rows.truncate(limit);
    if output == OutputMode::Json {
        out.value(&json!({ "runs": rows.iter().map(|(_, r)| r).collect::<Vec<_>>() }));
        return Ok(0);
    }
    if rows.is_empty() {
        println!("{}", messages().no_runs);
    }
    for (name, r) in &rows {
        let at = when(r.started_at.or(r.scheduled_at).unwrap_or(r.created_at));
        let late = if r.late_seconds > 120 && r.state != RunState::Skipped {
            messages().late.replace("{minutes}", &(r.late_seconds / 60).to_string())
        } else {
            String::new()
        };
        println!("{}  {at}  {:<24} {}{late}", r.id, name, state_label(r));
    }
    Ok(0)
}

fn logs(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, &[], &[])?;
    let word = a.one_word("RUN")?;
    let store = open_store()?;
    // A run id, or an automation (its newest run that started).
    let (automation, run) = if word.starts_with("run_") {
        let found = store.list()?.into_iter().find_map(|x| {
            store.runs(&x.id).ok()?.into_iter().find(|r| r.id == word).map(|r| (x.id, r))
        });
        found.ok_or_else(|| Failure::Store(StoreError::NotFound(word.into())))?
    } else {
        let x = store.find(word)?;
        let r = store
            .runs(&x.id)?
            .into_iter()
            .rev()
            .find(|r| r.started_at.is_some())
            .ok_or_else(|| Failure::Usage(messages().no_runs.into()))?;
        (x.id, r)
    };
    let path = store.log_path(&automation, &run.id);
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    if output == OutputMode::Json {
        out.value(&json!({ "run": run, "log_path": path, "log": text }));
    } else {
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(text.as_bytes());
    }
    Ok(0)
}

fn delete(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    // `--yes`: scripts confirm up front; the CLI does not ask.
    let a = Args::parse(args, &[], &["yes"])?;
    let store = open_store()?;
    let x = store.find(a.one_word("AUTOMATION")?)?;
    store.delete(&x.id)?;
    if output == OutputMode::Json {
        out.value(&json!({ "deleted": x.id }));
    } else if output != OutputMode::Quiet {
        println!("{}", messages().deleted.replace("{name}", &x.name));
    }
    Ok(0)
}

fn executor(store: &Store) -> Result<ProcessExecutor, Failure> {
    let exe = std::env::current_exe().map_err(|e| Failure::Store(e.into()))?;
    Ok(ProcessExecutor::new(exe, vec!["automation".into(), "_exec".into()], store))
}

/// `_exec AUTOMATION RUN`: the process one run is.
fn exec(args: &[String]) -> Outcome {
    let [automation, run] = args else { return usage("_exec AUTOMATION RUN") };
    let store = open_store()?;
    run_job(&store, automation, run)?;
    Ok(0)
}

fn runner(args: &[String], out: &Out) -> Outcome {
    let output = out.mode;
    let a = Args::parse(args, &[], &["once"])?;
    match a.words.first().map(String::as_str) {
        None => serve(a.flag("once"), out),
        Some("install") => install(out),
        Some("uninstall") => uninstall(out),
        Some("status") => {
            let store = open_store()?;
            let running = runner_running(&store);
            if output == OutputMode::Json {
                out.value(
                    &json!({ "running": running, "launchd_label": LAUNCHD_LABEL, "plist": plist_path() }),
                );
            } else {
                println!(
                    "{}",
                    if running { messages().runner_running } else { messages().runner_stopped }
                );
            }
            Ok(if running { 0 } else { 1 })
        }
        Some(other) => usage(messages().unknown_verb.replace("{verb}", other)),
    }
}

/// The runner loop: one tick, then sleep until the next due time (at most a
/// minute). `--once` ticks once and exits.
fn serve(once: bool, out: &Out) -> Outcome {
    let output = out.mode;
    let store = open_store()?;
    let Some(_lock) = RunnerLock::acquire(&store)? else {
        if output != OutputMode::Quiet {
            println!("{}", messages().runner_running);
        }
        return Ok(0);
    };
    let mut exec = executor(&store)?;
    recover_orphans(&store, now(), &mut exec)?;
    loop {
        let _ = store.prune_moved(now_ms());
        let report = tick(&store, now(), &mut exec)?;
        exec.reap();
        if output == OutputMode::Json {
            println!(
                "{}",
                json!({ "at": now(), "started": report.started, "skipped": report.skipped, "errors": report.errors })
            );
        } else if output != OutputMode::Quiet
            && (!report.started.is_empty() || !report.errors.is_empty())
        {
            for id in &report.started {
                println!("{} {id}", when(now()));
            }
            for (id, e) in &report.errors {
                eprintln!("{id}: {e}");
            }
        }
        if once {
            return Ok(0);
        }
        let t = now();
        let next = store
            .list()?
            .iter()
            .filter(|x| x.enabled && !x.fenced())
            .filter_map(|x| x.trigger.next_after(t).ok().flatten())
            .min()
            .unwrap_or(t + MAX_SLEEP.as_secs() as i64);
        let wait = Duration::from_secs((next - t).clamp(1, MAX_SLEEP.as_secs() as i64) as u64);
        std::thread::sleep(wait);
    }
}

fn plist_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| {
        PathBuf::from(h).join("Library/LaunchAgents").join(format!("{LAUNCHD_LABEL}.plist"))
    })
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn launchctl(args: &[&str]) -> bool {
    cmux_process::Command::new("/bin/launchctl")
        .args(args)
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// A launchd agent that keeps `cmux automation runner` running for this user.
fn install(out: &Out) -> Outcome {
    let output = out.mode;
    let store = open_store()?;
    let exe = std::env::current_exe().map_err(|e| Failure::Store(e.into()))?;
    let plist = plist_path().ok_or_else(|| Failure::Usage(messages().no_home.into()))?;
    let log = store.root().join("runner.log");
    let body = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\n<key>Label</key><string>{LAUNCHD_LABEL}</string>\n<key>ProgramArguments</key><array><string>{}</string><string>automation</string><string>runner</string></array>\n<key>EnvironmentVariables</key><dict><key>CMUX_AUTOMATIONS_DIR</key><string>{}</string></dict>\n<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><true/>\n<key>ProcessType</key><string>Background</string>\n<key>StandardOutPath</key><string>{}</string>\n<key>StandardErrorPath</key><string>{}</string>\n</dict></plist>\n",
        xml_escape(&exe.to_string_lossy()),
        xml_escape(&store.root().to_string_lossy()),
        xml_escape(&log.to_string_lossy()),
        xml_escape(&log.to_string_lossy()),
    );
    if let Some(dir) = plist.parent() {
        std::fs::create_dir_all(dir).map_err(|e| Failure::Store(e.into()))?;
    }
    std::fs::write(&plist, body).map_err(|e| Failure::Store(e.into()))?;
    // SAFETY: getuid has no failure mode.
    let domain = format!("gui/{}", unsafe { libc::getuid() });
    let _ = launchctl(&["bootout", &format!("{domain}/{LAUNCHD_LABEL}")]);
    let ok = launchctl(&["bootstrap", &domain, &plist.to_string_lossy()]);
    if output == OutputMode::Json {
        out.value(&json!({ "installed": ok, "plist": plist }));
    } else if output != OutputMode::Quiet {
        println!("{}", if ok { messages().installed } else { messages().install_failed });
    }
    Ok(if ok { 0 } else { 1 })
}

fn uninstall(out: &Out) -> Outcome {
    let output = out.mode;
    let plist = plist_path().ok_or_else(|| Failure::Usage(messages().no_home.into()))?;
    // SAFETY: as above.
    let domain = format!("gui/{}", unsafe { libc::getuid() });
    let _ = launchctl(&["bootout", &format!("{domain}/{LAUNCHD_LABEL}")]);
    let _ = std::fs::remove_file(&plist);
    if output == OutputMode::Json {
        out.value(&json!({ "uninstalled": true }));
    } else if output != OutputMode::Quiet {
        println!("{}", messages().uninstalled);
    }
    Ok(0)
}

// ------------------------------------------------------------- cmux Cloud (--target cloud)

use super::automation_cloud::{self as cloud, Answer, CloudSchedule};

/// The Cloud schedule of `a`: cron presets in an IANA zone (default this
/// Mac's), `--webhook`, or `--manual`. Intervals and one-shots run on this Mac only.
fn cloud_schedule(a: &Args) -> Result<Option<CloudSchedule>, Failure> {
    let tz = a.value("tz").map(str::to_string).unwrap_or_else(cloud::local_zone_name);
    let cron = |expr: String| -> Result<Option<CloudSchedule>, Failure> {
        cmux_automations::CronExpr::parse(&expr).map_err(Failure::Usage)?;
        Ok(Some(CloudSchedule::Cron { expr, tz: tz.clone() }))
    };
    for local_only in ["every", "at", "in"] {
        if a.value(local_only).is_some() {
            return usage(messages().cloud_local_only.replace("{flag}", local_only));
        }
    }
    let chosen =
        ["daily", "weekdays", "weekly", "cron"].iter().filter(|f| a.value(f).is_some()).count()
            + ["hourly", "manual", "webhook"].iter().filter(|f| a.flag(f)).count();
    if chosen > 1 {
        return usage(messages().one_schedule.replace("{flags}", "…"));
    }
    if a.flag("manual") {
        return Ok(Some(CloudSchedule::Manual));
    }
    if a.flag("webhook") {
        return Ok(Some(CloudSchedule::Webhook));
    }
    if a.flag("hourly") {
        return cron("0 * * * *".into());
    }
    if let Some(v) = a.value("daily") {
        let (h, m) = parse_clock(v)?;
        return cron(format!("{m} {h} * * *"));
    }
    if let Some(v) = a.value("weekdays") {
        let (h, m) = parse_clock(v)?;
        return cron(format!("{m} {h} * * 1-5"));
    }
    if let Some(v) = a.value("weekly") {
        let (day, clock) = v
            .split_once([' ', '@'])
            .ok_or_else(|| Failure::Usage(messages().bad_weekly.replace("{value}", v)))?;
        let (h, m) = parse_clock(clock)?;
        return cron(format!("{m} {h} * * {}", parse_weekday(day)?));
    }
    if let Some(v) = a.value("cron") {
        return cron(v.to_string());
    }
    Ok(None)
}

/// Prints a Cloud answer; refusals go through `print_refusal`.
fn cloud_out(answer: Result<Answer, Value>, out: &Out, human: impl FnOnce(&Value)) -> Outcome {
    let output = out.mode;
    match answer {
        Ok(Answer::Value(v)) => {
            if output == OutputMode::Json {
                out.value(&v);
            } else if output != OutputMode::Quiet {
                human(&v);
            }
            Ok(0)
        }
        Ok(Answer::Refused(error)) => Ok(out.refusal(&error)),
        Err(error) => Ok(out.error(&error, 3, true)),
    }
}

fn cloud_row(v: &Value) -> String {
    let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("-").to_string();
    let schedule = v
        .get("triggers")
        .and_then(Value::as_array)
        .and_then(|t| {
            t.iter().find_map(|t| {
                let spec = t.get("spec").unwrap_or(t);
                match spec.get("type").and_then(Value::as_str) {
                    Some("cron") => Some(format!(
                        "cron {} ({})",
                        spec.get("expr").and_then(Value::as_str).unwrap_or(""),
                        spec.get("tz").and_then(Value::as_str).unwrap_or("")
                    )),
                    Some("webhook") => Some("webhook".to_string()),
                    _ => None,
                }
            })
        })
        .unwrap_or_else(|| messages().manual_only.to_string());
    let status = if v.get("enabled").and_then(Value::as_bool) == Some(true) {
        messages().active
    } else {
        messages().paused
    };
    let next = v
        .get("next_run_at")
        .and_then(Value::as_i64)
        .map(|ms| when(ms / 1000))
        .unwrap_or_else(|| "-".into());
    format!(
        "{}  {:<28} {:<10} {:<34} {} {}",
        s("id"),
        s("name"),
        status,
        schedule,
        messages().next_label,
        next
    )
}

/// `--private`/`--shared`, `--editor USER` (repeatable) and `--catch-up` on
/// a Cloud create or update (docs/automations-teleport-teams.md, section 4).
fn team_fields(a: &Args, params: &mut Value) -> Result<(), Failure> {
    match (a.flag("private"), a.flag("shared")) {
        (true, true) => return usage(messages().one_sharing),
        (true, false) => params["sharing"] = json!("private"),
        (false, true) => params["sharing"] = json!("team"),
        (false, false) => {}
    }
    let editors = a.values_of("editor");
    if !editors.is_empty() {
        params["editors"] = json!(editors);
    }
    if let Some(c) = a.value("catch-up") {
        params["catch_up"] = json!(parse_catch_up(c)?.name());
    }
    Ok(())
}

/// The Cloud automation `word` names: an `auto_` id, or a name from `automation.list`.
fn cloud_find(
    global: &super::GlobalArgs,
    out: &Out,
    word: &str,
) -> Result<Result<String, Outcome>, Failure> {
    if word.starts_with("auto_") && word.len() == 25 {
        return Ok(Ok(word.to_string()));
    }
    match cloud::call(global, "automation.list", json!({"limit": 100}), None) {
        Ok(Answer::Value(v)) => {
            let found = v
                .get("automations")
                .and_then(Value::as_array)
                .and_then(|all| {
                    all.iter().find(|a| {
                        a.get("name")
                            .and_then(Value::as_str)
                            .is_some_and(|n| n.eq_ignore_ascii_case(word))
                    })
                })
                .and_then(|a| a.get("id").and_then(Value::as_str))
                .map(str::to_string);
            match found {
                Some(id) => Ok(Ok(id)),
                None => Err(Failure::Store(StoreError::NotFound(word.into()))),
            }
        }
        other => Ok(Err(cloud_out(other, out, |_| {}))),
    }
}

fn cloud_dispatch(args: &[String], global: &super::GlobalArgs, out: &Out) -> Outcome {
    let Some((verb, rest)) = args.split_first() else {
        print!("{}", messages().usage);
        return Ok(0);
    };
    if verb == "teleport" || verb == "move" {
        return teleport::run(rest, global, out, true);
    }
    let mut valued = SPEC_VALUED.to_vec();
    valued.extend(["limit", "key", "editor"]);
    let mut flags = SPEC_FLAGS.to_vec();
    flags.extend(["webhook", "private", "shared", "yes"]);
    let a = Args::parse(rest, &valued, &flags)?;
    let target = |a: &Args| -> Result<Result<String, Outcome>, Failure> {
        cloud_find(global, out, a.one_word("AUTOMATION")?)
    };
    match verb.as_str() {
        "create" | "new" | "add" => {
            let name = a
                .value("name")
                .map(str::to_string)
                .or_else(|| a.words.first().cloned())
                .ok_or_else(|| Failure::Usage(messages().missing_word.replace("{what}", "NAME")))?;
            if a.value("command").is_some() {
                return usage(messages().cloud_no_command);
            }
            let prompt =
                a.value("prompt").ok_or_else(|| Failure::Usage(messages().need_body.into()))?;
            let schedule = cloud_schedule(&a)?
                .ok_or_else(|| Failure::Usage(messages().need_schedule.into()))?;
            let chief = match cloud::call(global, "chief.list", json!({}), None) {
                Ok(Answer::Value(v)) => cloud::default_chief(&v)
                    .ok_or_else(|| Failure::Usage(messages().cloud_no_chief.into()))?,
                other => return cloud_out(other, out, |_| {}),
            };
            let mut params =
                cloud::create_params(&name, prompt, &schedule, &chief, a.flag("paused"));
            team_fields(&a, &mut params)?;
            cloud_out(
                cloud::call(
                    global,
                    "automation.create",
                    params,
                    Some(cloud::key(global, "create")),
                ),
                out,
                |v| {
                    println!(
                        "{}",
                        messages()
                            .cloud_created
                            .replace("{name}", &name)
                            .replace("{id}", v.get("id").and_then(Value::as_str).unwrap_or("?"))
                    );
                    println!("{}", cloud_row(v));
                },
            )
        }
        "list" | "ls" => cloud_out(
            cloud::call(global, "automation.list", json!({"limit": 100}), None),
            out,
            |v| {
                let all =
                    v.get("automations").and_then(Value::as_array).cloned().unwrap_or_default();
                if all.is_empty() {
                    println!("{}", messages().none_yet);
                }
                for x in &all {
                    println!("{}", cloud_row(x));
                }
            },
        ),
        "show" | "get" => match target(&a)? {
            Ok(id) => cloud_out(
                cloud::call(global, "automation.get", json!({"automation": id}), None),
                out,
                |v| println!("{}", cloud_row(v.get("automation").unwrap_or(v))),
            ),
            Err(done) => done,
        },
        "run" => match target(&a)? {
            Ok(id) => cloud_out(
                cloud::call(
                    global,
                    "automation.run",
                    json!({"automation": id}),
                    Some(
                        a.value("key")
                            .map(str::to_string)
                            .unwrap_or_else(|| cloud::key(global, "run")),
                    ),
                ),
                out,
                |v| {
                    let run = v
                        .get("id")
                        .or_else(|| v.get("run").and_then(|r| r.get("id")))
                        .and_then(Value::as_str)
                        .unwrap_or("?");
                    println!("{}", messages().cloud_run_started.replace("{run}", run));
                },
            ),
            Err(done) => done,
        },
        "pause" | "resume" => match target(&a)? {
            Ok(id) => {
                let enabled = verb == "resume";
                cloud_out(
                    cloud::call(
                        global,
                        "automation.update",
                        json!({"automation": id, "enabled": enabled}),
                        Some(cloud::key(global, verb)),
                    ),
                    out,
                    |v| {
                        let name = v.get("name").and_then(Value::as_str).unwrap_or(&id);
                        println!(
                            "{}",
                            (if enabled { messages().resumed } else { messages().paused_done })
                                .replace("{name}", name)
                        );
                    },
                )
            }
            Err(done) => done,
        },
        "edit" | "update" => {
            let unsupported = ["prompt", "command", "folder", "model", "timeout", "tz"]
                .iter()
                .chain(SCHEDULE_FLAGS)
                .any(|f| a.value(f).is_some())
                || ["hourly", "manual", "webhook"].iter().any(|f| a.flag(f));
            if unsupported {
                return usage(messages().cloud_edit_flags);
            }
            match target(&a)? {
                Ok(id) => {
                    let mut params = json!({"automation": id});
                    if let Some(name) = a.value("name") {
                        params.set("name", json!(name));
                    }
                    if a.flag("paused") {
                        params.set("enabled", json!(false));
                    }
                    team_fields(&a, &mut params)?;
                    cloud_out(
                        cloud::call(
                            global,
                            "automation.update",
                            params,
                            Some(cloud::key(global, "update")),
                        ),
                        out,
                        |v| {
                            let name = v.get("name").and_then(Value::as_str).unwrap_or(&id);
                            println!(
                                "{}",
                                messages().updated.replace("{name}", name).replace(
                                    "{version}",
                                    &v.get("version")
                                        .map(Value::to_string)
                                        .unwrap_or_else(|| "-".into())
                                )
                            );
                        },
                    )
                }
                Err(done) => done,
            }
        }
        "audit" => {
            let limit: u64 = match a.value("limit") {
                Some(n) => n
                    .parse()
                    .map_err(|_| Failure::Usage(messages().bad_limit.replace("{value}", n)))?,
                None => 50,
            };
            let mut params = json!({"limit": limit});
            match a.words.as_slice() {
                [] => {}
                [_] => match target(&a)? {
                    Ok(id) => {
                        params.set("automation", json!(id));
                    }
                    Err(done) => return done,
                },
                [_, extra, ..] => {
                    return usage(messages().unexpected_argument.replace("{value}", extra));
                }
            }
            cloud_out(cloud::call(global, "automation.audit.list", params, None), out, |v| {
                let entries =
                    v.get("entries").and_then(Value::as_array).cloned().unwrap_or_default();
                if entries.is_empty() {
                    println!("{}", messages().audit_none);
                }
                for e in &entries {
                    let s = |k: &str| e.get(k).and_then(Value::as_str).unwrap_or("-").to_string();
                    let at = e
                        .get("at")
                        .and_then(Value::as_i64)
                        .map(|ms| when(ms / 1000))
                        .unwrap_or_default();
                    println!(
                        "{at}  {:<20} {:<10} {:<26} {}",
                        s("actor"),
                        s("op"),
                        s("automation"),
                        s("summary")
                    );
                }
            })
        }
        "history" | "runs" => match target(&a)? {
            Ok(id) => cloud_out(
                cloud::call(
                    global,
                    "automation.runs.list",
                    json!({"automation": id, "limit": 50}),
                    None,
                ),
                out,
                |v| {
                    let runs = v.get("runs").and_then(Value::as_array).cloned().unwrap_or_default();
                    if runs.is_empty() {
                        println!("{}", messages().no_runs);
                    }
                    for r in &runs {
                        let s =
                            |k: &str| r.get(k).and_then(Value::as_str).unwrap_or("-").to_string();
                        let at = r
                            .get("created_at")
                            .and_then(Value::as_i64)
                            .map(|ms| when(ms / 1000))
                            .unwrap_or_default();
                        let reason = r
                            .get("error")
                            .and_then(|e| e.get("code"))
                            .and_then(Value::as_str)
                            .map(|c| format!(" ({c})"))
                            .unwrap_or_default();
                        println!("{}  {at}  {}{reason}", s("id"), s("state"));
                    }
                },
            ),
            Err(done) => done,
        },
        "delete" | "rm" => match target(&a)? {
            Ok(id) => cloud_out(
                cloud::call(
                    global,
                    "automation.delete",
                    json!({"automation": id}),
                    Some(cloud::key(global, "delete")),
                ),
                out,
                |_| {
                    println!("{}", messages().deleted_cloud.replace("{id}", &id));
                },
            ),
            Err(done) => done,
        },
        other => usage(messages().cloud_unknown_verb.replace("{verb}", other)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(words: &[&str]) -> Args {
        Args::parse(
            &words.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            SPEC_VALUED,
            SPEC_FLAGS,
        )
        .ok()
        .unwrap()
    }

    #[test]
    fn schedules_parse_to_triggers() {
        let now = 1_793_350_800;
        let t = |w: &[&str]| parse_trigger(&args(w), now).ok().flatten();
        assert_eq!(
            t(&["--daily", "09:30", "--tz", "UTC"]),
            Some(Trigger::Cron { expr: "30 9 * * *".into(), tz: "UTC".into() })
        );
        assert_eq!(
            t(&["--weekdays=8:05", "--tz", "UTC"]),
            Some(Trigger::Cron { expr: "5 8 * * 1-5".into(), tz: "UTC".into() })
        );
        assert_eq!(
            t(&["--weekly", "fri 17:00", "--tz", "UTC"]),
            Some(Trigger::Cron { expr: "0 17 * * 5".into(), tz: "UTC".into() })
        );
        assert_eq!(t(&["--every", "30m"]), Some(Trigger::Every { seconds: 1_800, anchor: now }));
        assert_eq!(t(&["--in", "2h"]), Some(Trigger::At { at: now + 7_200 }));
        assert_eq!(
            t(&["--at", "2026-10-30 10:00", "--tz", "UTC"]),
            Some(Trigger::At { at: now + 3_600 })
        );
        assert_eq!(
            t(&["--at", "08:00", "--tz", "UTC"]),
            Some(Trigger::At { at: now + 23 * 3_600 }),
            "a past clock time means tomorrow"
        );
        assert_eq!(t(&["--manual"]), Some(Trigger::Manual));
        assert_eq!(t(&["--hourly", "--tz", "UTC"]), Some(Trigger::preset_hourly(Zone::Utc)));
        assert_eq!(t(&[]), None);
    }

    #[test]
    fn bad_schedules_are_usage_errors() {
        let now = 0;
        for w in [
            &["--daily", "25:00"][..],
            &["--every", "30s"],
            &["--daily", "9:00", "--hourly"],
            &["--cron", "* * *"],
            &["--tz", "Europe/Paris", "--daily", "9:00"],
            &["--weekly", "someday 9:00"],
        ] {
            assert!(parse_trigger(&args(w), now).is_err(), "{w:?}");
        }
    }

    #[test]
    fn durations() {
        assert_eq!(parse_duration("90").ok(), Some(90));
        assert_eq!(parse_duration("45m").ok(), Some(2_700));
        assert_eq!(parse_duration("1d").ok(), Some(86_400));
        assert!(parse_duration("soon").is_err());
    }

    #[test]
    fn target_is_taken_out_of_the_words_in_both_forms() {
        let words = |w: &[&str]| w.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let taken = |w: &[&str]| take_target(&words(w)).ok();
        assert_eq!(taken(&["list"]), Some((false, words(&["list"]))));
        assert_eq!(
            taken(&["list", "--target", "cloud", "--json"]),
            Some((true, words(&["list", "--json"])))
        );
        assert_eq!(taken(&["--target=cloud", "list"]), Some((true, words(&["list"]))));
        assert_eq!(taken(&["list", "--target", "this-mac"]), Some((false, words(&["list"]))));
        assert!(matches!(take_target(&words(&["list", "--target"])), Err(Failure::Usage(_))));
        assert!(matches!(take_target(&words(&["--target", "mars"])), Err(Failure::Usage(_))));
    }
}
