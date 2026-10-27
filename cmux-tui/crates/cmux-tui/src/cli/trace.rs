//! `cmux trace record|start|stop|status|export`: a Release trace from the command line
//! (plans/cmux-next/chrome-parity/p09-observability.md, task 021).
//!
//! `start`, `stop` and `status` are one app method each (task 020): `trace.start {categories?,
//! keys, chromium, seconds_cap?}`, `trace.stop` and `trace.status`. The app forwards them to its
//! daemon (`trace-start`, task 015), which reaches the holder, the terminal hosts and acpmux. No
//! parameter names a file: each process records into its own directory.
//!
//! `record` is Perfetto's command line (`src/perfetto_cmd/perfetto_cmd.cc`): start a session,
//! wait for its duration or Ctrl-C, stop, then read every buffer into one place. It copies each
//! recording ring the stop reply names and the Chromium JSON into `--out`, writes
//! `manifest.json`, and runs the Perfetto exporter (task 022) on that bundle ([`bundle`] reads
//! the stop reply). `export` runs the exporter again on a recorded directory.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};
use crate::localization::TraceMessages;

mod bundle;

use bundle::{Bundle, PerfettoExport, TraceExporter, chromium_entry, collect, process_entries};

/// `trace.start`'s largest `seconds_cap` (task 020).
const MAX_SECONDS_CAP: u32 = 600;
/// `record` asks for a cap this much past its own wait, so its stop comes before the cap.
const STOP_SLACK_SECONDS: u32 = 10;
const MAX_RECORD_SECONDS: u32 = MAX_SECONDS_CAP - STOP_SLACK_SECONDS;
/// The daemon waits up to 3 s for its children; the app adds Chromium's start.
const START_TIMEOUT: Duration = Duration::from_secs(15);
/// A stop also flushes Chromium's trace to its JSON file.
const STOP_TIMEOUT: Duration = Duration::from_secs(30);
const STATUS_TIMEOUT: Duration = Duration::from_secs(10);
/// A status reply lists every terminal host; this bounds one reply line.
const MAX_REPLY_BYTES: u64 = 8 * 1024 * 1024;

pub(super) const MANIFEST_FILE: &str = "manifest.json";
pub(super) const RINGS_DIR: &str = "rings";
/// The name `scripts/cmux-next/trace.py` reads Chromium's trace under.
pub(super) const CHROMIUM_FILE: &str = "chromium-trace.json";
pub(super) const PERFETTO_FILE: &str = "trace.perfetto-trace";

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    Help,
    Verb(Verb),
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Verb {
    Record(RecordPlan),
    Start(StartPlan),
    Stop,
    Status,
    Export(ExportPlan),
}

/// `trace export --in DIR [--out FILE]`.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct ExportPlan {
    pub dir: PathBuf,
    /// `None`: `DIR/trace.perfetto-trace`.
    pub to: Option<PathBuf>,
}

/// What `trace.start` is asked for.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct StartPlan {
    /// `None`: every recording category (the daemon's default).
    pub categories: Option<Vec<String>>,
    pub keys: bool,
    pub chromium: bool,
    pub seconds_cap: Option<u32>,
}

impl StartPlan {
    fn params(&self) -> Value {
        let mut params = Map::new();
        if let Some(categories) = &self.categories {
            params.insert("categories".into(), json!(categories));
        }
        params.insert("keys".into(), json!(self.keys));
        params.insert("chromium".into(), json!(self.chromium));
        if let Some(cap) = self.seconds_cap {
            params.insert("seconds_cap".into(), json!(cap));
        }
        Value::Object(params)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct RecordPlan {
    pub seconds: u32,
    pub out: PathBuf,
    /// Its `seconds_cap` is `seconds` plus [`STOP_SLACK_SECONDS`].
    pub start: StartPlan,
}

/// `cmux trace …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "trace" {
        return None;
    }
    Some(match parse(rest) {
        Ok(invocation) => run(&global, invocation),
        Err(error) => {
            super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

pub(super) fn parse(rest: &[String]) -> Result<Invocation, UsageError> {
    let messages = &crate::localization::catalog().trace;
    if rest.iter().any(|arg| arg == "--help" || arg == "-h") {
        return Ok(Invocation::Help);
    }
    let Some((verb, tail)) = rest.split_first() else { return Ok(Invocation::Help) };
    let options = Options::parse(verb, tail)?;
    let verb = match verb.as_str() {
        "help" => return Ok(Invocation::Help),
        "record" => {
            options.allow(verb, &["seconds", "out", "categories", "keys", "chromium"])?;
            let seconds = options.seconds("seconds", MAX_RECORD_SECONDS, messages.seconds_range)?;
            let seconds = seconds.ok_or_else(|| UsageError::new(messages.seconds_required))?;
            let out = options.path("out").ok_or_else(|| UsageError::new(messages.out_required))?;
            let mut start = options.start_plan()?;
            start.seconds_cap = Some(seconds + STOP_SLACK_SECONDS);
            Verb::Record(RecordPlan { seconds, out: PathBuf::from(out), start })
        }
        "start" => {
            options.allow(verb, &["categories", "keys", "chromium", "seconds-cap"])?;
            let mut start = options.start_plan()?;
            start.seconds_cap =
                options.seconds("seconds-cap", MAX_SECONDS_CAP, messages.seconds_cap_range)?;
            Verb::Start(start)
        }
        "export" => {
            options.allow(verb, &["in", "out"])?;
            let dir = options.path("in").ok_or_else(|| UsageError::new(messages.in_required))?;
            if options.value("out").is_some() && options.path("out").is_none() {
                return Err(UsageError::new(messages.export_out_empty));
            }
            let to = options.path("out").map(PathBuf::from);
            Verb::Export(ExportPlan { dir: PathBuf::from(dir), to })
        }
        "stop" | "status" => {
            options.allow(verb, &[])?;
            if verb == "stop" { Verb::Stop } else { Verb::Status }
        }
        other => return Err(UsageError::new(messages.unknown_verb.replace("{verb}", other))),
    };
    Ok(Invocation::Verb(verb))
}

/// `--name value`, `--name=value` and the flags `--keys` and `--chromium`.
struct Options {
    values: Vec<(String, String)>,
    flags: Vec<String>,
}

const FLAGS: [&str; 2] = ["keys", "chromium"];
const VALUED: [&str; 5] = ["seconds", "out", "categories", "seconds-cap", "in"];

impl Options {
    fn parse(verb: &str, args: &[String]) -> Result<Self, UsageError> {
        let messages = &crate::localization::catalog().trace;
        let unexpected = |value: &str| {
            UsageError::new(
                messages.unexpected_argument.replace("{verb}", verb).replace("{value}", value),
            )
        };
        let mut options = Options { values: Vec::new(), flags: Vec::new() };
        let mut index = 0;
        while index < args.len() {
            let arg = args[index].as_str();
            index += 1;
            let Some(flag) = arg.strip_prefix("--") else { return Err(unexpected(arg)) };
            let (name, inline) = match flag.split_once('=') {
                Some((name, value)) => (name, Some(value.to_owned())),
                None => (flag, None),
            };
            if FLAGS.contains(&name) && inline.is_none() {
                options.flags.push(name.to_owned());
                continue;
            }
            if !VALUED.contains(&name) {
                return Err(unexpected(arg));
            }
            let value = match inline {
                Some(value) => value,
                None => {
                    let value = args.get(index).ok_or_else(|| {
                        UsageError::new(messages.missing_value.replace("{flag}", arg))
                    })?;
                    index += 1;
                    value.clone()
                }
            };
            options.values.push((name.to_owned(), value));
        }
        Ok(options)
    }

    /// Refuses an option `verb` does not take.
    fn allow(&self, verb: &str, allowed: &[&str]) -> Result<(), UsageError> {
        let messages = &crate::localization::catalog().trace;
        let names = self.values.iter().map(|(name, _)| name).chain(&self.flags);
        match names.into_iter().find(|name| !allowed.contains(&name.as_str())) {
            Some(name) => Err(UsageError::new(
                messages
                    .unexpected_argument
                    .replace("{verb}", verb)
                    .replace("{value}", &format!("--{name}")),
            )),
            None => Ok(()),
        }
    }

    fn value(&self, key: &str) -> Option<&str> {
        self.values.iter().rev().find(|(name, _)| name == key).map(|(_, value)| value.as_str())
    }

    /// A path value; an empty one is none (`--out=` must not mean the current directory).
    fn path(&self, key: &str) -> Option<&str> {
        self.value(key).filter(|value| !value.trim().is_empty())
    }

    fn flag(&self, key: &str) -> bool {
        self.flags.iter().any(|flag| flag == key)
    }

    /// `--key N` with N in 1..=max; `range` is the message when it is not.
    fn seconds(&self, key: &str, max: u32, range: &str) -> Result<Option<u32>, UsageError> {
        let Some(value) = self.value(key) else { return Ok(None) };
        let messages = &crate::localization::catalog().trace;
        let flag = format!("--{key}");
        let seconds = value.trim().parse::<u32>().map_err(|_| {
            UsageError::new(messages.bad_number.replace("{flag}", &flag).replace("{value}", value))
        })?;
        if !(1..=max).contains(&seconds) {
            return Err(UsageError::new(range.replace("{max}", &max.to_string())));
        }
        Ok(Some(seconds))
    }

    /// `--categories` (comma-separated, repeatable), checked against the shared catalog so a
    /// typo fails before anything starts, `--keys` and `--chromium`.
    fn start_plan(&self) -> Result<StartPlan, UsageError> {
        let messages = &crate::localization::catalog().trace;
        let known = cmux_trace::category::NAMES;
        let mut categories: Option<Vec<String>> = None;
        for (_, list) in self.values.iter().filter(|(name, _)| name == "categories") {
            for name in list.split(',').map(str::trim).filter(|name| !name.is_empty()) {
                if !known.contains(&name) {
                    return Err(UsageError::new(
                        messages
                            .unknown_category
                            .replace("{name}", name)
                            .replace("{known}", &known.join(", ")),
                    ));
                }
                let chosen = categories.get_or_insert_with(Vec::new);
                if !chosen.iter().any(|existing| existing == name) {
                    chosen.push(name.to_owned());
                }
            }
        }
        let keys = self.flag("keys");
        if !keys && categories.as_ref().is_some_and(|names| names.iter().any(|name| name == "key"))
        {
            return Err(UsageError::new(messages.key_needs_keys));
        }
        Ok(StartPlan { categories, keys, chromium: self.flag("chromium"), seconds_cap: None })
    }
}

/// One app reply: the outer error is transport, the inner one the app's refusal.
pub(super) type AppReply = Result<Result<Value, Value>, Value>;

/// The app's trace methods; [`AppTrace`] in the CLI, a scripted fake in tests.
pub(super) trait TraceApp {
    /// One request.
    fn call(&mut self, method: &str, params: Value, timeout: Duration) -> AppReply;
}

/// The app socket `global` names. Each call opens its own connection: a recording's stop comes
/// minutes after its start, and no connection is held idle that long.
pub(super) struct AppTrace<'a> {
    pub global: &'a GlobalArgs,
}

impl TraceApp for AppTrace<'_> {
    fn call(&mut self, method: &str, params: Value, timeout: Duration) -> AppReply {
        let mut stream = super::app::connect_command(self.global)?;
        exchange(&mut stream, method, params, timeout).map_err(transport_error)
    }
}

/// One line out and one line back. No read barrier (`after`): a trace call reads no session
/// state, and a busy daemon must not delay a stop.
fn exchange(
    stream: &mut UnixStream,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Result<Value, Value>, String> {
    let line = json!({ "id": 1, "method": method, "params": params });
    super::app::send_line(stream, &line)?;
    // wakeup-allow: cli-only `cmux trace`'s one bound on the reply; the reply ends the read first
    stream.set_read_timeout(Some(timeout)).map_err(|error| error.to_string())?;
    let reader = stream.try_clone().map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(reader.take(MAX_REPLY_BYTES));
    let mut reply = String::new();
    reader.read_line(&mut reply).map_err(|error| error.to_string())?;
    super::app::parse_response(&reply)
}

fn transport_error(message: String) -> Value {
    json!({ "code": "app.transport", "message": message, "details": {}, "retryable": false })
}

/// How `record` waits, and its clock; [`SignalWait`] in the CLI.
pub(super) trait RecordWait {
    fn wait(&self, duration: Duration) -> Waited;
    fn now(&self) -> Instant;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Waited {
    Elapsed,
    /// SIGINT, SIGTERM or SIGHUP came first: the recording stops now.
    Interrupted,
}

/// Waits for the duration or the first termination signal (`main`'s handlers), whichever
/// comes first, as `perfetto --time` stops early on Ctrl-C and still reads its buffers.
pub(super) struct SignalWait;

impl RecordWait for SignalWait {
    fn wait(&self, duration: Duration) -> Waited {
        let deadline = Instant::now() + duration;
        let (signalled, signal) = mpsc::channel();
        // The watcher only peeks at the wake byte, so it never takes a signal from anyone else.
        std::thread::Builder::new()
            .name("cmux-trace-wait".into())
            .spawn(move || {
                crate::wait_for_shutdown_signal_peek();
                let _ = signalled.send(());
            })
            .ok();
        // wakeup-allow: cli-only `cmux trace`'s recording window, once; a shutdown signal ends it first
        match crate::blocking::sync::recv_timeout(&signal, duration) {
            Ok(()) if crate::shutdown_requested() => Waited::Interrupted,
            // No handler is installed (the watcher returned at once): only the clock ends it.
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                // wakeup-allow: cli-only `cmux trace`'s rest of the recording window, once, when no signal watcher runs
                cmux_blocking::thread::sleep(deadline.saturating_duration_since(Instant::now()));
                Waited::Elapsed
            }
            Err(mpsc::RecvTimeoutError::Timeout) => Waited::Elapsed,
        }
    }

    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// A failed verb: the error object to print and the exit code.
#[derive(Debug)]
pub(super) struct Failure {
    pub error: Value,
    pub exit_code: i32,
}

impl Failure {
    fn local(code: &str, message: String, exit_code: i32) -> Self {
        let error = json!({ "code": code, "message": message, "details": {}, "retryable": false });
        Self { error, exit_code }
    }

    /// The app refused: 5 when it has no trace methods (an app from before task 020), else 1.
    fn refused(error: Value) -> Self {
        let exit_code = match error.get("code").and_then(Value::as_str) {
            Some("method_not_found") => 5,
            _ => 1,
        };
        Self { error, exit_code }
    }

    fn transport(error: Value) -> Self {
        Self { error, exit_code: 3 }
    }

    /// A `record` whose stop failed: the recording still ends at its cap, `left` from now.
    fn stop_failed(self, left: Duration, messages: &TraceMessages) -> Self {
        let message = Self::filled(messages.stop_failed, &self.error, left);
        let error = json!({
            "code": "trace.stop_failed",
            "message": message,
            "details": { "error": self.error },
            "retryable": false,
        });
        Self { error, exit_code: self.exit_code }
    }

    /// `template` with `{error}` (the error's message) and `{seconds}` (`left`, rounded up).
    fn filled(template: &str, error: &Value, left: Duration) -> String {
        let reason = error.get("message").and_then(Value::as_str).unwrap_or_default();
        let seconds = left.as_secs() + u64::from(left.subsec_nanos() > 0);
        template.replace("{error}", reason).replace("{seconds}", &seconds.to_string())
    }
}

/// `trace.start` for `record`. When the request went out but no reply came (`app.transport`: a
/// read timeout, a dropped connection), the app may have started: a best-effort `trace.stop`
/// ends that recording, or the message says when its cap does.
fn start_recording(
    app: &mut dyn TraceApp,
    plan: &StartPlan,
    messages: &TraceMessages,
) -> Result<Value, Failure> {
    let lost = match app.call("trace.start", plan.params(), START_TIMEOUT) {
        Ok(Ok(started)) => return Ok(started),
        Ok(Err(refusal)) => return Err(Failure::refused(refusal)),
        Err(error) if code_of(&error) == Some("app.transport") => error,
        Err(error) => return Err(Failure::transport(error)),
    };
    let (template, stop) = match app.call("trace.stop", json!({}), STOP_TIMEOUT) {
        Ok(Ok(reply)) => (messages.start_unanswered_stopped, json!({ "ok": reply })),
        // Nothing started.
        Ok(Err(refusal)) if code_of(&refusal) == Some("not_recording") => {
            return Err(Failure::transport(lost));
        }
        Ok(Err(error)) | Err(error) => {
            (messages.start_unanswered_running, json!({ "error": error }))
        }
    };
    let cap = Duration::from_secs(u64::from(plan.seconds_cap.unwrap_or(MAX_SECONDS_CAP)));
    let error = json!({
        "code": "trace.start_unanswered",
        "message": Failure::filled(template, &lost, cap),
        "details": { "error": lost, "stop": stop },
        "retryable": false,
    });
    Err(Failure { error, exit_code: 3 })
}

fn code_of(error: &Value) -> Option<&str> {
    error.get("code").and_then(Value::as_str)
}

fn call(
    app: &mut dyn TraceApp,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Value, Failure> {
    match app.call(method, params, timeout) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(Failure::refused(error)),
        Err(error) => Err(Failure::transport(error)),
    }
}

pub(super) fn run(global: &GlobalArgs, invocation: Invocation) -> i32 {
    let messages = &crate::localization::catalog().trace;
    let Invocation::Verb(verb) = invocation else {
        let mut stdout = std::io::stdout().lock();
        let _ = stdout.write_all(messages.usage.as_bytes());
        let _ = stdout.flush();
        return 0;
    };
    let human = global.output == OutputMode::Human;
    let mut notes = |note: String| {
        if human {
            eprintln!("{note}");
        }
    };
    let mut app = AppTrace { global };
    let result = execute(verb, &mut app, &SignalWait, &PerfettoExport, &mut notes);
    match result {
        Ok((_, text)) if human => super::wire::print_local_success(&json!(text), global.output),
        Ok((value, _)) => super::wire::print_local_success(&value, global.output),
        Err(failure) => {
            super::wire::print_local_error(&failure.error, global.output, failure.exit_code)
        }
    }
}

/// Runs `verb` against `app`: the result and its text form.
pub(super) fn execute(
    verb: Verb,
    app: &mut dyn TraceApp,
    wait: &dyn RecordWait,
    exporter: &dyn TraceExporter,
    notes: &mut dyn FnMut(String),
) -> Result<(Value, String), Failure> {
    let messages = &crate::localization::catalog().trace;
    let value = match verb {
        Verb::Record(plan) => {
            let value = record(&plan, app, wait, exporter, notes)?;
            let text = record_text(&value, messages);
            return Ok((value, text));
        }
        Verb::Start(plan) => call(app, "trace.start", plan.params(), START_TIMEOUT)?,
        Verb::Stop => call(app, "trace.stop", json!({}), STOP_TIMEOUT)?,
        Verb::Status => call(app, "trace.status", json!({}), STATUS_TIMEOUT)?,
        Verb::Export(plan) => {
            let value = export(&plan, exporter)?;
            let path = value["perfetto"].as_str().unwrap_or_default();
            let text = messages.perfetto_written.replace("{path}", path);
            return Ok((value, text));
        }
    };
    let text = status_text(&value, messages);
    Ok((value, text))
}

/// `trace record`: start, wait, stop, collect, export. The result is the manifest plus where
/// the Perfetto trace went (or why it did not).
pub(super) fn record(
    plan: &RecordPlan,
    app: &mut dyn TraceApp,
    wait: &dyn RecordWait,
    exporter: &dyn TraceExporter,
    notes: &mut dyn FnMut(String),
) -> Result<Value, Failure> {
    let messages = &crate::localization::catalog().trace;
    check_out(&plan.out)?;
    let start = start_recording(app, &plan.start, messages)?;
    let started = wait.now();
    notes(messages.recording.replace("{seconds}", &plan.seconds.to_string()));
    let waited = wait.wait(Duration::from_secs(u64::from(plan.seconds)));
    if waited == Waited::Interrupted {
        notes(messages.interrupted.to_owned());
    }
    let cap = Duration::from_secs(u64::from(plan.start.seconds_cap.unwrap_or(MAX_SECONDS_CAP)));
    let stop = call(app, "trace.stop", json!({}), STOP_TIMEOUT).map_err(|failure| {
        let left = cap.saturating_sub(wait.now().saturating_duration_since(started));
        failure.stop_failed(left, messages)
    })?;
    let collected = collect(&stop, &plan.out, plan.start.chromium)?;
    let mut manifest = json!({
        "seconds": plan.seconds,
        "interrupted": waited == Waited::Interrupted,
        "start": start,
        "stop": stop,
        "not_copied": collected.not_copied,
    });
    for (key, value) in collected.bundle.manifest_fields() {
        manifest[key] = value;
    }
    write_file(&plan.out.join(MANIFEST_FILE), &manifest_bytes(&manifest))?;
    let perfetto = plan.out.join(PERFETTO_FILE);
    if !exporter.available() {
        manifest["export"] = json!("unavailable");
    } else if let Err(error) = exporter.export(&collected.bundle, &perfetto) {
        manifest["export_error"] = json!(error);
    } else {
        manifest["perfetto"] = json!(perfetto.display().to_string());
    }
    manifest["out"] = json!(plan.out.display().to_string());
    Ok(manifest)
}

fn manifest_bytes(manifest: &Value) -> Vec<u8> {
    let mut bytes = serde_json::to_vec_pretty(manifest).unwrap_or_default();
    bytes.push(b'\n');
    bytes
}

/// `trace export`: the exporter over the bundle `plan.dir`'s manifest names.
pub(super) fn export(plan: &ExportPlan, exporter: &dyn TraceExporter) -> Result<Value, Failure> {
    let messages = &crate::localization::catalog().trace;
    let shown = plan.dir.display().to_string();
    let bundle = Bundle::read(&plan.dir).map_err(|error| {
        let message = messages.not_a_bundle.replace("{path}", &shown).replace("{error}", &error);
        Failure::local("trace.not_a_bundle", message, 1)
    })?;
    if !exporter.available() {
        let rings = plan.dir.join(RINGS_DIR).display().to_string();
        let message = messages.export_unavailable.replace("{path}", &rings);
        return Err(Failure::local("trace.export_unavailable", message, 1));
    }
    let to = plan.to.clone().unwrap_or_else(|| plan.dir.join(PERFETTO_FILE));
    exporter.export(&bundle, &to).map_err(|error| {
        let message = messages.export_failed.replace("{error}", &error);
        Failure::local("trace.export_failed", message, 1)
    })?;
    Ok(json!({ "out": shown, "perfetto": to.display().to_string() }))
}

/// `--out` must be new or empty, so a record never mixes with an older one. Checked before
/// anything starts, and nothing is created before the stop: a failed start leaves `--out` as it
/// was.
fn check_out(out: &Path) -> Result<(), Failure> {
    let messages = &crate::localization::catalog().trace;
    let shown = out.display().to_string();
    let not_empty =
        || Failure::local("usage.invalid", messages.out_not_empty.replace("{path}", &shown), 2);
    match cmux_blocking::fs::read_dir(out).map(|mut entries| entries.next().is_none()) {
        Ok(true) => {}
        Ok(false) => return Err(not_empty()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        // A file, not a directory.
        Err(_) if cmux_blocking::fs::metadata(out).is_ok() => return Err(not_empty()),
        Err(error) => return Err(write_failure(out, &error)),
    }
    Ok(())
}

fn write_failure(path: &Path, error: &std::io::Error) -> Failure {
    let messages = &crate::localization::catalog().trace;
    let message = messages
        .write_failed
        .replace("{path}", &path.display().to_string())
        .replace("{error}", &error.to_string());
    Failure::local("trace.write_failed", message, 1)
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<(), Failure> {
    cmux_blocking::fs::write(path, bytes).map_err(|error| write_failure(path, &error))
}

fn record_text(value: &Value, messages: &TraceMessages) -> String {
    let out = value.get("out").and_then(Value::as_str).unwrap_or_default();
    let rings = value.get("rings").and_then(Value::as_array).map_or(0, Vec::len);
    let mut lines =
        vec![messages.recorded.replace("{rings}", &rings.to_string()).replace("{path}", out)];
    if let Some(chromium) = value.pointer("/chromium/file").and_then(Value::as_str) {
        lines.push(messages.chromium_copied.replace("{path}", chromium));
    }
    for skipped in value.get("not_copied").and_then(Value::as_array).into_iter().flatten() {
        lines.push(
            messages
                .not_copied
                .replace("{role}", skipped["role"].as_str().unwrap_or_default())
                .replace("{pid}", &pid_text(&skipped["pid"]))
                .replace("{reason}", skipped["reason"].as_str().unwrap_or_default()),
        );
    }
    if let Some(path) = value.get("perfetto").and_then(Value::as_str) {
        lines.push(messages.perfetto_written.replace("{path}", path));
    } else if let Some(error) = value.get("export_error").and_then(Value::as_str) {
        lines.push(messages.export_failed.replace("{error}", error));
    } else {
        let rings_dir = Path::new(out).join(RINGS_DIR).display().to_string();
        lines.push(messages.export_unavailable.replace("{path}", &rings_dir));
    }
    lines.join("\n")
}

/// A start, stop or status reply: the recording state, then one line per process.
pub(super) fn status_text(value: &Value, messages: &TraceMessages) -> String {
    let daemon = value.get("daemon").unwrap_or(value);
    let recording = value.get("recording").or_else(|| daemon.get("recording"));
    let number = |key: &str| daemon.get(key).and_then(Value::as_u64).unwrap_or(0).to_string();
    let mut lines = vec![if recording.and_then(Value::as_bool) == Some(true) {
        messages
            .summary_recording
            .replace("{total}", &number("total_bytes"))
            .replace("{cap}", &number("total_cap_bytes"))
    } else {
        messages.summary_idle.to_owned()
    }];
    for entry in process_entries(value).into_iter().chain(chromium_entry(value)) {
        let line = messages
            .process_line
            .replace("{role}", entry.role)
            .replace("{pid}", &pid_text(&json!(entry.pid)))
            .replace("{state}", entry.state.unwrap_or("unknown"))
            .replace("{detail}", entry.ring.or(entry.reason).unwrap_or_default());
        lines.push(line.trim_end().to_owned());
    }
    lines.join("\n")
}

fn pid_text(pid: &Value) -> String {
    pid.as_u64().map_or_else(|| "-".to_owned(), |pid| pid.to_string())
}

#[cfg(test)]
mod tests;
