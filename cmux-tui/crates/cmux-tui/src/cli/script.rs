//! `cmux script run|repl|types`: JavaScript in a sandboxed script session of
//! the session daemon (`script-*` commands, cmux-tui-core server/scripts.rs;
//! plans/cmux-next/scripting-runtime.md phase 1).
//!
//! `run` sends one cell and prints the value of its last expression; console
//! output arrives as `script-log` events before the answer and is printed as
//! it comes (info and debug on stdout, warn and error on stderr; all on stderr
//! with `--json`). Ctrl-C sends `cancel-request` for the running cell and
//! waits at most [`CANCEL_WAIT`] for its `script.cancelled` answer (exit 130);
//! a second Ctrl-C exits at once. `repl` keeps one session across lines and
//! starts a new one when a cell ends its session (timeout, limit, cancel).
//! `types` prints the generated `cmux` declarations plus the script additions.

mod messages;

#[cfg(test)]
mod tests;

use std::future::Future;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader, Lines};

use self::messages::messages;
use super::{GlobalArgs, OutputMode};

/// The scope word.
pub(super) const SCOPE: &str = "script";

/// How long a cancelled cell may take to confirm.
pub(super) const CANCEL_WAIT: Duration = Duration::from_secs(3);

/// The exit code of a script the user cancelled (128 + SIGINT).
pub(super) const EXIT_CANCELLED: i32 = 130;

/// `cmux script types`: the generated app global, then the script additions.
pub(super) const TYPES: &str = concat!(
    include_str!("../../../cmux-app-host/generated/cmux-app.d.ts"),
    "\n",
    include_str!("../../../cmux-app-host/js/script-globals.d.ts"),
);

/// Codes after which the daemon has ended the cell's session.
const SESSION_ENDED: [&str; 5] =
    ["script.timeout", "script.memory", "script.cpu", "script.cancelled", "script.host"];

/// Ctrl-C presses, one per `next()`.
pub(super) trait Interrupts {
    fn next(&mut self) -> impl Future<Output = ()>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Source {
    File(PathBuf),
    Inline(String),
    Stdin,
}

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Action {
    Run { source: Source, args: Value, timeout_ms: Option<u64> },
    Repl { timeout_ms: Option<u64> },
    Types,
    Help,
}

/// How one request ended.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Outcome {
    /// The daemon's answer (`ok` true or false).
    Answer(Value),
    /// The user cancelled; `confirmed` when the cell answered `script.cancelled`.
    Cancelled { confirmed: bool },
    /// A second Ctrl-C ended the wait.
    Interrupted,
    /// The daemon closed the connection first.
    Closed,
}

fn timeout_value(value: Option<&String>) -> Result<u64, String> {
    let value = value.ok_or_else(|| messages().usage.to_string())?;
    value
        .parse::<u64>()
        .ok()
        .filter(|ms| *ms > 0)
        .ok_or_else(|| messages().bad_timeout.replace("{value}", value))
}

/// `run (FILE | -e CODE | -) [KEY=VALUE ...] [--args JSON] [--timeout MS]`,
/// `repl [--timeout MS]`, `types`.
pub(super) fn parse(args: &[String]) -> Result<Action, String> {
    let usage = || messages().usage.to_string();
    match args {
        [] => Err(usage()),
        [flag, ..] if matches!(flag.as_str(), "-h" | "--help" | "help") => Ok(Action::Help),
        [verb] if verb == "types" => Ok(Action::Types),
        [verb, rest @ ..] if verb == "repl" => match rest {
            [] => Ok(Action::Repl { timeout_ms: None }),
            [flag, value] if flag == "--timeout" => {
                Ok(Action::Repl { timeout_ms: Some(timeout_value(Some(value))?) })
            }
            [flag] if matches!(flag.as_str(), "-h" | "--help") => Ok(Action::Help),
            _ => Err(usage()),
        },
        [verb, rest @ ..] if verb == "run" => parse_run(rest),
        _ => Err(usage()),
    }
}

/// A word that names a script file even though it contains `=`.
fn looks_like_path(word: &str) -> bool {
    word.contains('/') || [".js", ".mjs", ".cjs"].iter().any(|ext| word.ends_with(ext))
}

fn parse_run(rest: &[String]) -> Result<Action, String> {
    let usage = || messages().usage.to_string();
    let mut source = None;
    let mut args = Map::new();
    let mut timeout_ms = None;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "-h" | "--help" => return Ok(Action::Help),
            "-e" if source.is_none() => {
                source = Some(Source::Inline(words.next().ok_or_else(usage)?.clone()));
            }
            "-" if source.is_none() => source = Some(Source::Stdin),
            "-e" | "-" => return Err(usage()),
            "--args" => {
                let text = words.next().ok_or_else(usage)?;
                let value: Value = serde_json::from_str(text)
                    .map_err(|error| messages().bad_args.replace("{error}", &error.to_string()))?;
                let Value::Object(fields) = value else {
                    return Err(messages().bad_args.replace("{error}", "not an object"));
                };
                args.extend(fields);
            }
            "--timeout" => timeout_ms = Some(timeout_value(words.next())?),
            _ if source.is_none()
                && !word.starts_with('-')
                && (!word.contains('=') || looks_like_path(word)) =>
            {
                source = Some(Source::File(PathBuf::from(word)));
            }
            _ => match word.split_once('=') {
                Some((key, value)) if !key.is_empty() && !key.starts_with('-') => {
                    args.insert(key.to_string(), Value::String(value.to_string()));
                }
                _ => return Err(messages().bad_pair.replace("{word}", word)),
            },
        }
    }
    let source = source.ok_or_else(usage)?;
    Ok(Action::Run { source, args: Value::Object(args), timeout_ms })
}

/// The script text of `source`. TypeScript files are refused until the type
/// strip lands.
pub(super) fn load(
    source: &Source,
    stdin: impl FnOnce() -> std::io::Result<String>,
) -> Result<String, String> {
    match source {
        Source::Inline(code) => Ok(code.clone()),
        Source::Stdin => stdin().map_err(|error| {
            messages().read_failed.replace("{path}", "-").replace("{error}", &error.to_string())
        }),
        Source::File(path) => {
            let typescript = path
                .extension()
                .and_then(|e| e.to_str())
                .is_some_and(|e| matches!(e, "ts" | "mts" | "cts" | "tsx"));
            if typescript {
                return Err(messages().typescript.replace("{path}", &path.display().to_string()));
            }
            std::fs::read_to_string(path).map_err(|error| {
                messages()
                    .read_failed
                    .replace("{path}", &path.display().to_string())
                    .replace("{error}", &error.to_string())
            })
        }
    }
}

async fn send<W: AsyncWrite + Unpin>(writer: &mut W, value: &Value) -> std::io::Result<()> {
    let mut line = value.to_string();
    line.push('\n');
    writer.write_all(line.as_bytes()).await?;
    writer.flush().await
}

/// The next line that answers request `id`; `script-log` events on the way
/// go to `on_log`. None when the stream ends.
async fn answer_to<R: AsyncBufRead + Unpin>(
    lines: &mut Lines<R>,
    id: &Value,
    on_log: &mut impl FnMut(&str, &str),
) -> Option<Value> {
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
        if value["event"] == "script-log" {
            on_log(
                value["level"].as_str().unwrap_or("info"),
                value["message"].as_str().unwrap_or(""),
            );
            continue;
        }
        if value["id"] == *id {
            return Some(value);
        }
    }
    None
}

/// Sends `request` and waits for its answer; on a Ctrl-C sends
/// `cancel-request` and waits at most `cancel_wait` for the cell to confirm.
pub(super) async fn exchange<R, W, I>(
    lines: &mut Lines<R>,
    writer: &mut W,
    request: &Value,
    interrupts: &mut I,
    on_log: &mut impl FnMut(&str, &str),
    cancel_wait: Duration,
) -> Outcome
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
    I: Interrupts,
{
    let id = request["id"].clone();
    if send(writer, request).await.is_err() {
        return Outcome::Closed;
    }
    tokio::select! {
        answer = answer_to(lines, &id, on_log) => return answer.map_or(Outcome::Closed, Outcome::Answer),
        () = interrupts.next() => {}
    }
    let cancel = json!({ "id": format!("{}-cancel", id.as_str().unwrap_or("script")), "cmd": "cancel-request", "target": id });
    if send(writer, &cancel).await.is_err() {
        return Outcome::Cancelled { confirmed: false };
    }
    tokio::select! {
        answer = tokio::time::timeout(cancel_wait, answer_to(lines, &id, on_log)) => match answer {
            Ok(Some(answer)) if answer["error_code"] == "script.cancelled" => Outcome::Cancelled { confirmed: true },
            Ok(Some(answer)) => Outcome::Answer(answer),
            Ok(None) | Err(_) => Outcome::Cancelled { confirmed: false },
        },
        () = interrupts.next() => Outcome::Interrupted,
    }
}

/// The text of a value: nothing for null, a string as is, else JSON (pretty
/// for people).
pub(super) fn render(value: &Value, output: OutputMode) -> Option<String> {
    match output {
        OutputMode::Quiet => None,
        OutputMode::Json | OutputMode::JsonLines => Some(value.to_string()),
        OutputMode::Human => match value {
            Value::Null => None,
            Value::String(text) => Some(text.clone()),
            other => {
                Some(serde_json::to_string_pretty(other).unwrap_or_else(|_| other.to_string()))
            }
        },
    }
}

/// `cmux: <code>: <message>` (and details), or the old-daemon hint.
pub(super) fn error_text(answer: &Value) -> String {
    let code = answer["error_code"].as_str().unwrap_or("error");
    let message = answer["error"].as_str().unwrap_or("");
    // A daemon without script support rejects the command line itself:
    // the generic bad-request answer, which has no error code.
    if answer.get("error_code").is_none_or(Value::is_null)
        && message.starts_with("bad request")
        && message.contains("script-")
    {
        return format!("cmux: {}", messages().unsupported_daemon);
    }
    let mut text = format!("cmux: {code}: {message}");
    if let Some(details) = answer.get("error_details").filter(|d| !d.is_null()) {
        text.push_str(&format!("\n{details}"));
    }
    text
}

/// The note for console lines the daemon dropped, if it dropped any.
pub(super) fn dropped_note(answer: &Value) -> Option<String> {
    let dropped = answer["data"]["dropped_log_lines"].as_u64().filter(|n| *n > 0)?;
    Some(format!("cmux: {}", messages().dropped_lines.replace("{count}", &dropped.to_string())))
}

/// What to print and the exit code for a `run` outcome.
pub(super) fn report(
    outcome: &Outcome,
    output: OutputMode,
) -> (Option<String>, Option<String>, i32) {
    match outcome {
        Outcome::Answer(answer) if answer["ok"] == true => {
            (render(&answer["data"]["value"], output), dropped_note(answer), 0)
        }
        Outcome::Answer(answer) => (None, Some(error_text(answer)), 1),
        Outcome::Cancelled { confirmed: true } | Outcome::Interrupted => {
            (None, Some(messages().cancelled.to_string()), EXIT_CANCELLED)
        }
        Outcome::Cancelled { confirmed: false } => {
            (None, Some(messages().cancel_unconfirmed.to_string()), EXIT_CANCELLED)
        }
        Outcome::Closed => (None, Some(format!("cmux: {}", messages().closed)), 3),
    }
}

/// One `script-run` request.
pub(super) fn run_request(code: &str, args: &Value, timeout_ms: Option<u64>) -> Value {
    let mut request =
        json!({ "id": "script-run-1", "cmd": "script-run", "code": code, "args": args });
    if let Some(ms) = timeout_ms {
        request["timeout_ms"] = json!(ms);
    }
    request
}

/// Where the REPL prints.
pub(super) trait ReplOutput {
    fn prompt(&mut self, text: &str);
    fn value(&mut self, value: &Value);
    fn error(&mut self, text: &str);
    fn log(&mut self, level: &str, message: &str);
}

/// The REPL over one daemon connection. Returns the exit code.
pub(super) async fn repl<R, W, In, I, O>(
    lines: &mut Lines<R>,
    writer: &mut W,
    input: &mut Lines<In>,
    interrupts: &mut I,
    out: &mut O,
    timeout_ms: Option<u64>,
    cancel_wait: Duration,
) -> i32
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
    In: AsyncBufRead + Unpin,
    I: Interrupts,
    O: ReplOutput,
{
    let mut serial = 0_u64;
    let mut next_id = |kind: &str| {
        serial += 1;
        json!(format!("script-repl-{kind}-{serial}"))
    };
    let mut session =
        match open_session(lines, writer, next_id("open"), interrupts, out, cancel_wait).await {
            Ok(session) => session,
            Err(code) => return code,
        };
    let mut buffer = String::new();
    loop {
        out.prompt(if buffer.is_empty() { "cmux> " } else { "...> " });
        let line = tokio::select! {
            line = input.next_line() => Some(line),
            () = interrupts.next() => None,
        };
        let Some(line) = line else {
            // Ctrl-C at the prompt drops the unfinished input.
            buffer.clear();
            continue;
        };
        let Ok(Some(line)) = line else { break };
        if buffer.is_empty() && line.trim() == ".exit" {
            break;
        }
        if let Some(head) = line.strip_suffix('\\') {
            buffer.push_str(head);
            buffer.push('\n');
            continue;
        }
        buffer.push_str(&line);
        let code = std::mem::take(&mut buffer);
        if code.trim().is_empty() {
            continue;
        }
        let mut request = json!({ "id": next_id("eval"), "cmd": "script-repl-eval", "session": session, "code": code });
        if let Some(ms) = timeout_ms {
            request["timeout_ms"] = json!(ms);
        }
        let outcome =
            exchange(lines, writer, &request, interrupts, &mut |l, m| out.log(l, m), cancel_wait)
                .await;
        let ended = match &outcome {
            Outcome::Answer(answer) if answer["ok"] == true => {
                let value = &answer["data"]["value"];
                if !value.is_null() {
                    out.value(value);
                }
                if let Some(note) = dropped_note(answer) {
                    out.error(&note);
                }
                false
            }
            Outcome::Answer(answer) => {
                out.error(&error_text(answer));
                answer["error_code"].as_str().is_some_and(|code| SESSION_ENDED.contains(&code))
            }
            Outcome::Cancelled { .. } | Outcome::Interrupted => {
                out.error(messages().cancelled);
                true
            }
            Outcome::Closed => {
                out.error(&format!("cmux: {}", messages().closed));
                return 3;
            }
        };
        if ended {
            // The daemon removes an ended session; closing it again is harmless
            // and covers a late cancel that left it running.
            let close =
                json!({ "id": next_id("close"), "cmd": "script-repl-close", "session": session });
            if send(writer, &close).await.is_err() {
                return 3;
            }
            session =
                match open_session(lines, writer, next_id("open"), interrupts, out, cancel_wait)
                    .await
                {
                    Ok(session) => session,
                    Err(code) => return code,
                };
            out.error(messages().restarted);
        }
    }
    let close = json!({ "id": next_id("close"), "cmd": "script-repl-close", "session": session });
    let _ = send(writer, &close).await;
    0
}

async fn open_session<R, W, I, O>(
    lines: &mut Lines<R>,
    writer: &mut W,
    id: Value,
    interrupts: &mut I,
    out: &mut O,
    cancel_wait: Duration,
) -> Result<String, i32>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
    I: Interrupts,
    O: ReplOutput,
{
    let request = json!({ "id": id, "cmd": "script-repl-open" });
    match exchange(lines, writer, &request, interrupts, &mut |l, m| out.log(l, m), cancel_wait)
        .await
    {
        Outcome::Answer(answer) if answer["ok"] == true => {
            answer["data"]["session"].as_str().map(str::to_string).ok_or(1)
        }
        Outcome::Answer(answer) => {
            out.error(&error_text(&answer));
            Err(1)
        }
        Outcome::Cancelled { .. } | Outcome::Interrupted => Err(EXIT_CANCELLED),
        Outcome::Closed => {
            out.error(&format!("cmux: {}", messages().closed));
            Err(3)
        }
    }
}

/// `cmux [global options] script ...` when `args` names it.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = command_args.strip_prefix(&[SCOPE.to_string()][..])?;
    Some(run(&global, rest))
}

/// Ctrl-C from the process's SIGINT.
struct SigInt(tokio::signal::unix::Signal);

impl Interrupts for SigInt {
    async fn next(&mut self) {
        if self.0.recv().await.is_none() {
            std::future::pending::<()>().await;
        }
    }
}

/// Prints the REPL to the terminal.
struct Terminal {
    output: OutputMode,
    interactive: bool,
}

impl ReplOutput for Terminal {
    fn prompt(&mut self, text: &str) {
        if self.interactive {
            use std::io::Write as _;
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(text.as_bytes());
            let _ = stdout.flush();
        }
    }

    fn value(&mut self, value: &Value) {
        if let Some(text) = render(value, self.output) {
            println!("{text}");
        }
    }

    fn error(&mut self, text: &str) {
        eprintln!("{text}");
    }

    fn log(&mut self, level: &str, message: &str) {
        print_log(self.output, level, message);
    }
}

fn print_log(output: OutputMode, level: &str, message: &str) {
    let to_stderr = matches!(level, "warn" | "error")
        || matches!(output, OutputMode::Json | OutputMode::JsonLines);
    if output == OutputMode::Quiet && !matches!(level, "warn" | "error") {
        return;
    }
    if to_stderr {
        eprintln!("{message}");
    } else {
        println!("{message}");
    }
}

async fn connect(socket: &std::path::Path) -> Result<tokio::net::UnixStream, String> {
    let connect_failed = |error: String| {
        messages()
            .connect_failed
            .replace("{path}", &socket.display().to_string())
            .replace("{error}", &error)
    };
    let stream = tokio::net::UnixStream::connect(socket)
        .await
        .map_err(|error| connect_failed(error.to_string()))?;
    // Only this user's daemon (as every CLI connection checks).
    // SAFETY: geteuid has no preconditions.
    let own = unsafe { libc::geteuid() };
    let peer = stream.peer_cred().map_err(|error| connect_failed(error.to_string()))?;
    if peer.uid() != own && peer.uid() != 0 {
        return Err(connect_failed(format!("the socket belongs to uid {}", peer.uid())));
    }
    Ok(stream)
}

fn read_stdin() -> std::io::Result<String> {
    use std::io::Read as _;
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text)?;
    Ok(text)
}

fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let action = match parse(args) {
        Ok(action) => action,
        Err(message) => {
            eprintln!("cmux: {message}");
            return 2;
        }
    };
    let (code, args, timeout_ms) = match action {
        Action::Help => {
            println!("{}", messages().usage);
            return 0;
        }
        Action::Types => {
            print!("{TYPES}");
            return 0;
        }
        Action::Run { source, args, timeout_ms } => match load(&source, read_stdin) {
            Ok(code) => (Some(code), args, timeout_ms),
            Err(message) => {
                eprintln!("cmux: {message}");
                return 2;
            }
        },
        Action::Repl { timeout_ms } => (None, Value::Null, timeout_ms),
    };
    let socket = match super::wire::resolve_socket_or_report(global) {
        Ok((socket, _)) => socket,
        Err(code) => return code,
    };
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
        return 3;
    };
    let output = global.output;
    let result = runtime.block_on(async {
        let stream = connect(&socket).await?;
        let mut interrupts = SigInt(
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())
                .map_err(|error| error.to_string())?,
        );
        let (reader, mut writer) = tokio::io::split(stream);
        let mut lines = BufReader::new(reader).lines();
        Ok::<_, String>(match code {
            Some(code) => {
                let request = run_request(&code, &args, timeout_ms);
                let outcome = exchange(
                    &mut lines,
                    &mut writer,
                    &request,
                    &mut interrupts,
                    &mut |level, message| print_log(output, level, message),
                    CANCEL_WAIT,
                )
                .await;
                let (stdout, stderr, code) = report(&outcome, output);
                if let Some(text) = stdout {
                    println!("{text}");
                }
                if let Some(text) = stderr {
                    eprintln!("{text}");
                }
                code
            }
            None => {
                use std::io::IsTerminal as _;
                let mut input = BufReader::new(tokio::io::stdin()).lines();
                let mut out = Terminal { output, interactive: std::io::stdin().is_terminal() };
                repl(
                    &mut lines,
                    &mut writer,
                    &mut input,
                    &mut interrupts,
                    &mut out,
                    timeout_ms,
                    CANCEL_WAIT,
                )
                .await
            }
        })
    });
    match result {
        Ok(code) => code,
        Err(message) => {
            eprintln!("cmux: {message}");
            3
        }
    }
}
