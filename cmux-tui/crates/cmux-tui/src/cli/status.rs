//! `cmux status …`: loading indicators for scripts and agents
//! (plans/cmux-next/status-indicators.md section 5). A shorthand over
//! `workspace [<ws>] status …`, whose target defaults to the caller's own
//! terminal (its workspace), else the current workspace.
//!
//! ```text
//! cmux status set [KEY] (TEXT | --label T) [--target ws_…|current] [--state S] [--progress 0.4|40%]
//!                 [--style arc|native|dot|none] [--ttl 30s] [--pid N] [--keep | --owner none]
//! cmux status clear [KEY] [--target …] [--all]
//! cmux status list [--target … | --all]
//! cmux status run [--label T] [--target …] [--badge-ttl 8s] -- CMD …
//! cmux status wait KEY [--target …] [--until settled|cleared|state=S] [--timeout D]
//! ```
//!
//! `KEY` defaults to `cli:<terminal>`, so repeated `set`s from one terminal
//! replace each other. `run` marks the entry busy and owned by this process
//! (a killed CLI leaves no spinner), runs CMD with the terminal's stdio,
//! then records success or error with the exit code and duration for
//! `--badge-ttl`, and exits with CMD's status (128 + signal when a signal
//! ended it). The app decides whether a finished run notifies (only when it
//! took long enough and the terminal is not visible).
//!
//! `wait` (status/status_wait.rs) blocks until the entry settles, clears or
//! shows a state. `cmux terminal <t> wait --until idle|prompt` lives here too
//! (status/terminal_wait.rs): it waits on the same status facts.

use cmux_process::Command;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Instant;

use super::command::CommandPlan;
use super::{GlobalArgs, OutputMode, Surface, UsageError};

mod status_wait;
mod terminal_wait;
pub(super) use terminal_wait::duration;

const DEFAULT_BADGE_TTL: &str = "8s";
/// Flags `set` passes through to `workspace status set` unchanged.
const SET_FLAGS: &[&str] =
    &["state", "progress", "style", "ttl", "pid", "owner", "target-terminal", "icon", "color"];

/// `cmux status …` from the full argv. `None` for any other command.
pub(super) fn run_args(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    if super::has_help_option(&command) {
        return None;
    }
    run(&global, &command)
}

/// A status set routed to another session (`--socket`, `--session`) cannot
/// name the caller's terminal, which belongs to the caller's session: drop
/// the defaults `workspace status set` filled from `CMUX_TUI_TERMINAL_ID`.
pub(super) fn drop_caller_terminal_when_routed(
    global: &GlobalArgs,
    plan: &mut super::command::RequestPlan,
) {
    use cmux_tui_core::resource::ResourceOperation;
    let routed = global.socket.is_some() || global.session.is_some();
    let is_set = matches!(
        plan.operation,
        super::command::WireOperation::Typed(ResourceOperation::WorkspaceStatusSet)
    );
    let (true, true, Some(caller)) = (routed, is_set, caller_terminal()) else { return };
    let Some(params) = plan.params.as_object_mut() else { return };
    if params.get("target_terminal").and_then(serde_json::Value::as_str) == Some(caller.as_str()) {
        params.remove("target_terminal");
    }
    let owner_is_caller = params
        .get("owner")
        .and_then(|owner| owner.get("terminal"))
        .and_then(serde_json::Value::as_str)
        == Some(caller.as_str());
    if owner_is_caller
        && let Some(owner) = params.get_mut("owner").and_then(serde_json::Value::as_object_mut)
    {
        owner.remove("terminal");
        if owner.is_empty() {
            params.remove("owner");
        }
    }
}

/// `None` when `command` is not a `status` command (or `terminal <t> wait`).
fn run(global: &GlobalArgs, command: &[String]) -> Option<i32> {
    let (first, rest) = command.split_first()?;
    if super::canonical_scope(first) == "terminal" {
        return super::terminal_talk::run(global, rest)
            .or_else(|| terminal_wait::run(global, rest));
    }
    if first != "status" {
        return None;
    }
    if let Some((verb, words)) = rest.split_first()
        && verb == "wait"
    {
        return Some(status_wait::run(global, words));
    }
    Some(match parse(rest) {
        Ok(Status::Send(words)) => send(global, &words),
        Ok(Status::Run(run)) => run_command(global, run),
        Err(error) => {
            super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

#[derive(Debug, PartialEq)]
enum Status {
    /// Words of the equivalent `workspace … status …` command.
    Send(Vec<String>),
    Run(RunPlan),
}

#[derive(Debug, PartialEq)]
struct RunPlan {
    key: String,
    label: String,
    target: Vec<String>,
    badge_ttl: String,
    /// The command to run and its arguments.
    program: String,
    args: Vec<String>,
}

fn caller_terminal() -> Option<String> {
    std::env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|id| !id.is_empty())
}

fn default_key() -> String {
    caller_terminal().map_or_else(|| "cli".to_owned(), |terminal| format!("cli:{terminal}"))
}

/// Positional words, `(name, value)` options, and the words after `--`.
type SplitWords = (Vec<String>, Vec<(String, Option<String>)>, Option<Vec<String>>);

/// Split `--name value`, `--name=value` and bare `--flag` options from
/// positional words, up to a `--` separator.
fn split_options(words: &[String]) -> SplitWords {
    let mut positional = Vec::new();
    let mut options = Vec::new();
    let mut index = 0;
    while let Some(word) = words.get(index) {
        if word == "--" {
            return (
                positional,
                options,
                Some(words.get(index + 1..).unwrap_or_default().to_vec()),
            );
        }
        if let Some(name) = word.strip_prefix("--") {
            if let Some((name, value)) = name.split_once('=') {
                options.push((name.to_owned(), Some(value.to_owned())));
            } else if matches!(name, "all" | "keep") {
                options.push((name.to_owned(), None));
            } else {
                options.push((name.to_owned(), words.get(index + 1).cloned()));
                index += 1;
            }
        } else {
            positional.push(word.clone());
        }
        index += 1;
    }
    (positional, options, None)
}

fn parse(words: &[String]) -> Result<Status, UsageError> {
    let (positional, options, argv) = split_options(words);
    let mut target = Vec::new();
    let mut label = None;
    let mut badge_ttl = None;
    let mut passthrough = Vec::new();
    let mut all = false;
    for (name, value) in options {
        let value_of = |value: Option<String>| {
            value
                .filter(|value| !value.starts_with("--"))
                .ok_or_else(|| UsageError::new(format!("--{name} needs a value")))
        };
        match name.as_str() {
            "target" => target = vec![value_of(value)?],
            "label" => label = Some(value_of(value)?),
            "badge-ttl" => badge_ttl = Some(value_of(value)?),
            "all" => all = true,
            "keep" => passthrough.extend(["--owner".to_owned(), "none".to_owned()]),
            flag if SET_FLAGS.contains(&flag) => {
                passthrough.push(format!("--{flag}"));
                passthrough.push(value_of(value)?);
            }
            other => return Err(UsageError::new(format!("unknown flag --{other} for status"))),
        }
    }
    let words = |action: &[&str], extra: Vec<String>| {
        let mut words = vec!["workspace".to_owned()];
        words.extend(target.clone());
        words.push("status".to_owned());
        words.extend(action.iter().map(|word| (*word).to_owned()));
        words.extend(extra);
        words
    };
    let positional: Vec<&str> = positional.iter().map(String::as_str).collect();
    // A flag the verb does not read is an error, never silently dropped.
    let verb = positional.first().copied().unwrap_or("");
    let refuse = |flag: &str| Err(UsageError::new(format!("status {verb} does not take {flag}")));
    if all && !matches!(verb, "clear" | "list") {
        return refuse("--all");
    }
    if all && verb == "list" && !target.is_empty() {
        return Err(UsageError::new("status list --all lists every workspace; drop --target"));
    }
    if label.is_some() && !matches!(verb, "set" | "run") {
        return refuse("--label");
    }
    if badge_ttl.is_some() && verb != "run" {
        return refuse("--badge-ttl");
    }
    let badge_ttl = badge_ttl.unwrap_or_else(|| DEFAULT_BADGE_TTL.to_owned());
    match (positional.as_slice(), argv) {
        (["set"], None) | (["set", _], None) | (["set", _, _], None) => {
            let key = positional.get(1).map_or_else(default_key, |key| (*key).to_owned());
            // `status set KEY TEXT`, the `workspace status set` form, names the text
            // positionally; --label is the same text.
            let label = match (label, positional.get(2)) {
                (Some(_), Some(_)) => {
                    return Err(UsageError::new("status set takes TEXT or --label, not both"));
                }
                (Some(label), None) => label,
                (None, Some(text)) => (*text).to_owned(),
                (None, None) => {
                    return Err(UsageError::new("status set needs TEXT or --label"));
                }
            };
            let mut extra = vec![key, label];
            extra.extend(passthrough);
            Ok(Status::Send(words(&["set"], extra)))
        }
        (["clear"], None) if passthrough.is_empty() => {
            let extra = if all { Vec::new() } else { vec![default_key()] };
            Ok(Status::Send(words(&["clear"], extra)))
        }
        (["clear", key], None) if passthrough.is_empty() && !all => {
            Ok(Status::Send(words(&["clear"], vec![(*key).to_owned()])))
        }
        (["list"], None) if passthrough.is_empty() => {
            let extra = if all { vec!["--all".to_owned()] } else { Vec::new() };
            Ok(Status::Send(words(&["list"], extra)))
        }
        (["run"], Some(_)) if !passthrough.is_empty() => {
            Err(UsageError::new("status run takes only --label, --target and --badge-ttl"))
        }
        (["run"], argv) => {
            let mut argv = argv.unwrap_or_default().into_iter();
            let Some(program) = argv.next() else {
                return Err(UsageError::new("status run needs a command after --"));
            };
            let label = label.unwrap_or_else(|| {
                std::path::Path::new(&program)
                    .file_name()
                    .map_or_else(|| program.clone(), |name| name.to_string_lossy().into_owned())
            });
            let key = format!("run:{}", std::process::id());
            Ok(Status::Run(RunPlan {
                key,
                label,
                target,
                badge_ttl,
                program,
                args: argv.collect(),
            }))
        }
        _ => Err(UsageError::new("status takes set, clear, list, run or wait")),
    }
}

/// Send the equivalent `workspace … status …` request.
fn send(global: &GlobalArgs, words: &[String]) -> i32 {
    let plan = super::command::parse(words, Surface::current()).and_then(|mut plan| {
        super::apply_idempotency_key(&mut plan, global.idempotency_key.as_deref())?;
        Ok(plan)
    });
    match plan {
        Ok(CommandPlan::Protocol(request)) => super::wire::run(global.clone(), *request),
        Ok(_) => super::app::failure(
            "usage.invalid",
            "cmux: status is a daemon request",
            global.output,
            2,
        ),
        Err(error) => {
            super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    }
}

/// The child `status run` waits for, so forwarded signals reach it.
static CHILD: AtomicI32 = AtomicI32::new(0);

/// Forward a signal to the child. SIGINT and SIGQUIT the terminal sends
/// (`si_pid` 0) already reach the child through its process group, so only
/// ones another process sent are forwarded; SIGTERM and SIGHUP always are.
extern "C" fn forward_signal(
    signal: libc::c_int,
    info: *mut libc::siginfo_t,
    _: *mut libc::c_void,
) {
    let child = CHILD.load(Ordering::SeqCst);
    // SAFETY: the kernel passes a valid siginfo with SA_SIGINFO.
    let sender = if info.is_null() { 0 } else { unsafe { (*info).si_pid() } };
    let from_terminal = sender == 0 && matches!(signal, libc::SIGINT | libc::SIGQUIT);
    if child > 0 && !from_terminal {
        // SAFETY: kill is async-signal-safe.
        unsafe { libc::kill(child, signal) };
    }
}

const FORWARDED: [libc::c_int; 4] = [libc::SIGINT, libc::SIGQUIT, libc::SIGTERM, libc::SIGHUP];

/// Install `forward_signal` for the forwarded signals; returns the old
/// actions. Caught (not ignored) signals reset to their defaults in the
/// child at exec, so the command still sees Ctrl-C normally. A signal the
/// caller ignores (`nohup` ignores SIGHUP) stays ignored, so the command
/// inherits that too.
fn install_forwarding() -> Vec<libc::sigaction> {
    FORWARDED
        .iter()
        .map(|signal| {
            // SAFETY: plain sigaction calls with zeroed, then filled, structs.
            unsafe {
                let mut previous: libc::sigaction = std::mem::zeroed();
                libc::sigaction(*signal, std::ptr::null(), &mut previous);
                if previous.sa_sigaction == libc::SIG_IGN {
                    return previous;
                }
                let mut action: libc::sigaction = std::mem::zeroed();
                action.sa_sigaction = forward_signal as *const () as libc::sighandler_t;
                action.sa_flags = libc::SA_SIGINFO | libc::SA_RESTART;
                libc::sigemptyset(&mut action.sa_mask);
                libc::sigaction(*signal, &action, &mut previous);
                previous
            }
        })
        .collect()
}

fn restore_forwarding(previous: &[libc::sigaction]) {
    for (signal, action) in FORWARDED.iter().zip(previous) {
        // SAFETY: restoring the actions saved by install_forwarding.
        unsafe { libc::sigaction(*signal, action, std::ptr::null_mut()) };
    }
}

fn run_command(global: &GlobalArgs, run: RunPlan) -> i32 {
    let mut quiet = global.clone();
    quiet.output = OutputMode::Quiet;
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let set = |phase: &str, state: &str, extra: &[String]| {
        let mut words = vec!["workspace".to_owned()];
        words.extend(run.target.clone());
        words.extend(["status", "set"].map(str::to_owned));
        words.extend([run.key.clone(), run.label.clone(), "--state".into(), state.into()]);
        words.extend(extra.iter().cloned());
        // One idempotency key per write, so a retried write never applies twice.
        let mut keyed = quiet.clone();
        keyed.idempotency_key = Some(format!("status-run-{}-{nonce}-{phase}", std::process::id()));
        send(&keyed, &words)
    };
    // Best effort: the command runs even when no daemon answers.
    let marked = set("busy", "busy", &["--pid".into(), std::process::id().to_string()]) == 0;
    if !marked {
        eprintln!("cmux: status run could not mark {} busy; running it anyway", run.label);
    }
    let previous = install_forwarding();
    let started = Instant::now();
    let mut child = match Command::new(&run.program).args(&run.args).inherit_like_std().spawn() {
        Ok(child) => child,
        Err(error) => {
            restore_forwarding(&previous);
            eprintln!("cmux: cannot run {}: {error}", run.program);
            if marked {
                set(
                    "final",
                    "error",
                    &["--exit-code".into(), "127".into(), "--ttl".into(), run.badge_ttl.clone()],
                );
            }
            return 127;
        }
    };
    CHILD.store(i32::try_from(child.id()).unwrap_or(0), Ordering::SeqCst);
    let status = child.wait();
    CHILD.store(0, Ordering::SeqCst);
    restore_forwarding(&previous);
    let (code, signal) = match status {
        Ok(status) => (exit_code(status), terminating_signal(status)),
        Err(error) => {
            eprintln!("cmux: waiting for {} failed: {error}", run.program);
            (1, None)
        }
    };
    if marked {
        // The catalog carries durations as uint32 milliseconds (49 days).
        let duration = started.elapsed().as_millis().min(u128::from(u32::MAX)).to_string();
        let state = if code == 0 { "success" } else { "error" };
        set(
            "final",
            state,
            &[
                "--exit-code".into(),
                code.to_string(),
                "--duration-ms".into(),
                duration,
                "--ttl".into(),
                run.badge_ttl.clone(),
            ],
        );
    }
    // A command killed by Ctrl-C ends this process the same way, so a shell
    // loop around `cmux status run` stops too.
    if let Some(signal) = signal {
        // SAFETY: restore the default action, then raise to ourselves.
        unsafe {
            libc::signal(signal, libc::SIG_DFL);
            libc::raise(signal);
        }
    }
    code
}

fn terminating_signal(status: std::process::ExitStatus) -> Option<libc::c_int> {
    use std::os::unix::process::ExitStatusExt;
    status.signal().filter(|signal| {
        matches!(*signal, libc::SIGINT | libc::SIGQUIT | libc::SIGTERM | libc::SIGHUP)
    })
}

/// The shell convention: the exit status, or 128 + the signal number.
fn exit_code(status: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    status.code().or_else(|| status.signal().map(|signal| 128 + signal)).unwrap_or(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(args: &[&str]) -> Vec<String> {
        args.iter().map(|arg| (*arg).to_owned()).collect()
    }

    fn sent(args: &[&str]) -> Vec<String> {
        match parse(&words(args)) {
            Ok(Status::Send(words)) => words,
            other => panic!("{args:?} did not send: {other:?}"),
        }
    }

    #[test]
    fn status_list_all_lists_every_workspace() {
        assert_eq!(sent(&["list", "--all"]), words(&["workspace", "status", "list", "--all"]));
    }

    #[test]
    fn status_list_all_with_a_target_is_refused() {
        assert!(parse(&words(&["list", "--all", "--target", "ws_1"])).is_err());
    }

    #[test]
    fn status_flags_a_verb_does_not_read_are_refused() {
        for args in [
            &["set", "k", "text", "--all"][..],
            &["run", "--all", "--", "true"],
            &["list", "--label", "x"],
            &["clear", "--label", "x"],
            &["set", "k", "text", "--badge-ttl", "3s"],
            &["clear", "--badge-ttl", "3s"],
            &["list", "--badge-ttl", "3s"],
        ] {
            assert!(parse(&words(args)).is_err(), "{args:?} was accepted");
        }
    }

    #[test]
    fn status_run_keeps_its_label_and_badge_ttl() {
        let Ok(Status::Run(run)) =
            parse(&words(&["run", "--label", "build", "--badge-ttl", "3s", "--", "make"]))
        else {
            panic!("run did not parse");
        };
        assert_eq!((run.label.as_str(), run.badge_ttl.as_str()), ("build", "3s"));
    }
}
