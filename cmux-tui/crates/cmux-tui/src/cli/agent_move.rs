//! `cmux move`, `cmux teleport` and `cmux evacuate`: one verb that moves agent
//! sessions to another machine (also spelled `cmux agent move|teleport|evacuate`).
//!
//! The move implementation belongs to acpmux (`session move`). This verb only
//! reads its words and runs that one implementation through the same entry the
//! `acpmux` CLI uses, so the menu, palette and CLI cannot drift apart.
//!
//! - `teleport` is `move`, word for word.
//! - `evacuate` is `move` with `--to auto` unless a target is named, and with
//!   every session here that is between turns (`--all-idle`) when none is named.
//! - `--to`, `--machine` and `--host` name the target; `here` means this machine
//!   (`local`, for a move `--from` another machine).
//! - `--to cloud`, a Cloud machine's name, and `--to here` for a chat the app shows on a Cloud
//!   machine run the app's Move to Cloud and Bring Back Local instead (agent_move_cloud.rs): the
//!   app's one move, never a second one here.
//! - A close misspelling of an option (`--dryrun`, `--after_turn`, `--too`) is
//!   taken as the option it clearly means, with a note on stderr.

use std::time::Duration;

use cmux_process::Command;

use super::{GlobalArgs, UsageError, chat_start::joined, wire};

const MOVE_DEADLINE: Duration = Duration::from_secs(20 * 60);

/// The three names of the verb.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Verb {
    Move,
    Teleport,
    Evacuate,
}

impl Verb {
    fn from_word(word: &str) -> Option<Self> {
        match word {
            "move" => Some(Self::Move),
            "teleport" => Some(Self::Teleport),
            "evacuate" => Some(Self::Evacuate),
            _ => None,
        }
    }

    fn word(self) -> &'static str {
        match self {
            Self::Move => "move",
            Self::Teleport => "teleport",
            Self::Evacuate => "evacuate",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct MoveRequest {
    sessions: Vec<String>,
    machine: String,
    all_idle: bool,
    options: Vec<String>,
}

/// Options that take no value, as acpmux spells them.
const SWITCHES: &[&str] = &[
    "--all-idle",
    "--after-turn",
    "--interrupt",
    "--leave-dirty",
    "--carry-changes",
    "--dry-run",
    "--timings",
];
/// Options that take a value, as acpmux spells them (`--to` is ours: acpmux's `--machine`).
const VALUED: &[&str] = &["--to", "--cwd", "--from"];
/// Other spellings that mean one of the options above.
const SPELLINGS: &[(&str, &str)] = &[
    ("--machine", "--to"),
    ("--host", "--to"),
    ("--target", "--to"),
    ("--dest", "--to"),
    ("--destination", "--to"),
    ("--onto", "--to"),
    ("--all", "--all-idle"),
    ("--idle", "--all-idle"),
    ("--dry", "--dry-run"),
    ("-n", "--dry-run"),
    ("--wait", "--after-turn"),
    ("--force", "--interrupt"),
    ("--dirty", "--leave-dirty"),
    ("--carry", "--carry-changes"),
    ("--with-changes", "--carry-changes"),
    ("--dir", "--cwd"),
    ("--timing", "--timings"),
    ("--folder", "--cwd"),
];

fn help(verb: Verb) -> String {
    let lead = match verb {
        Verb::Move => {
            "cmux move: move agent sessions to another machine. Also `cmux teleport` (the same verb) and `cmux evacuate`."
        }
        Verb::Teleport => {
            "cmux teleport: the same verb as `cmux move`: move agent sessions to another machine. Also `cmux evacuate`."
        }
        Verb::Evacuate => {
            "cmux evacuate: `cmux move` for every session on this machine: with no SESSION, every session here that is between turns; with no --to, `--to auto`. Also `cmux move` and `cmux teleport`."
        }
    };
    format!(
        "\
{lead}

USAGE
  cmux move [SESSION...] --to MACHINE|cloud|auto|here [OPTIONS]
  cmux teleport [SESSION...] --to MACHINE|cloud|auto|here [OPTIONS]
  cmux evacuate [SESSION...] [--to MACHINE|auto] [OPTIONS]

A session moves with its history, queue and draft; its folder is made on the
target (a checkout's branch is pushed and becomes a worktree there). It is
acpmux's `session move`: `cmux agent move` and `acpmux session move` are the
same move.

`--to cloud` (or a Cloud machine's name) is the app's Move to Cloud for a chat
tab the app shows: your one Cloud machine (name one when you have several;
`cmux setup cloud-machine` makes one). `--to here` for a chat on a Cloud
machine is the app's Bring Back Local. Both need the app open and signed in
(`cmux login`); they are `cmux cloud move` and `cmux cloud bring-back`.

OPTIONS
  --to MACHINE|auto|here  Where to (`--machine` and `--host` work too). auto: the best
                          of your machines, never a reserved one, one per checkout.
                          here: this machine, for sessions moved --from another one,
                          or a chat on a Cloud machine (Bring Back Local).
                          cloud: your Cloud machine (Move to Cloud).
  --from MACHINE          The machine the sessions are on, when not this one
  --all-idle              Every session here that is between turns (evacuate's default)
  --after-turn            Let a running turn end on its own, then move
  --interrupt             Stop a running turn instead of refusing the move
  --leave-dirty           Move a checkout with uncommitted changes; they stay here
  --carry-changes         Take a checkout's uncommitted changes along
  --cwd PATH              Run the sessions in this folder there; no worktree is made
  --dry-run               Say where each session would go and change nothing
  --timings               Add how long each step took to the answer
  --json                  Print one JSON result

EXAMPLES
  cmux move my-chat --to auto
  cmux move my-chat --to cloud --dry-run
  cmux move my-chat --to here
  cmux teleport my-chat --to build-box --after-turn
  cmux move first second --to build-box --dry-run
  cmux evacuate
  cmux evacuate --to build-box --dry-run
  cmux move my-chat --from build-box --to here
"
    )
}

/// The verb's name when `command` runs it: `move …`, or `agent move …`.
fn verb_of(command: &[String]) -> Option<(Verb, usize)> {
    match command {
        [first, ..] if Verb::from_word(first).is_some() => Some((Verb::from_word(first)?, 1)),
        [scope, second, ..] if scope == "agent" => Some((Verb::from_word(second)?, 2)),
        _ => None,
    }
}

/// Handles the verb before the noun-first parser sees it.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    let (verb, skip) = verb_of(&command)?;
    let words = command.get(skip..).unwrap_or_default();
    if words.iter().any(|word| word == "--help" || word == "-h" || word == "help") {
        print!("{}", help(verb));
        return Some(0);
    }
    let request = match parse_request(verb, &global, words) {
        Ok(request) => request,
        Err(error) => return Some(usage(verb, &global, &error.0)),
    };
    let from = request.options.iter().position(|option| option == "--from");
    let ask = super::agent_move_cloud::Ask {
        sessions: &request.sessions,
        target: &request.machine,
        from: from.and_then(|at| request.options.get(at + 1)).map(String::as_str),
        all_idle: request.all_idle,
        options: &request.options,
        dry_run: request.options.iter().any(|option| option == "--dry-run"),
        timings: request.options.iter().any(|option| option == "--timings"),
    };
    if let Some(code) = super::agent_move_cloud::run_if_routed(&global, &ask) {
        return Some(code);
    }
    let timings = ask.timings;
    let began = std::time::Instant::now();
    let words = acpmux_words(request);
    let refs: Vec<&str> = words.iter().map(String::as_str).collect();
    let executable = match std::env::current_exe() {
        Ok(executable) => executable,
        Err(error) => {
            return Some(wire::print_local_error(
                &serde_json::json!({"code":"acpmux.unreachable","message":format!("cannot find cmux: {error}"),"details":{},"retryable":true}),
                global.output,
                3,
            ));
        }
    };
    let mut command = Command::new(executable);
    command.arg0("cmux");
    let command = joined::acp_command(command, &refs);
    match joined::run_acp(command, &refs, None, MOVE_DEADLINE) {
        Ok(mut value) => {
            if timings && let Some(object) = value.as_object_mut() {
                let move_ms = began.elapsed().as_millis() as u64;
                object.insert("timings".into(), serde_json::json!({ "move_ms": move_ms }));
            }
            Some(wire::print_local_success(&value, global.output))
        }
        Err(error) => Some(wire::print_local_error(&error, global.output, 1)),
    }
}

/// The `acpmux` words for a request: `session move …`.
fn acpmux_words(request: MoveRequest) -> Vec<String> {
    let mut words = vec!["session".to_owned(), "move".to_owned()];
    words.extend(request.sessions);
    words.push("--machine".to_owned());
    words.push(request.machine);
    if request.all_idle {
        words.push("--all-idle".to_owned());
    }
    // `--timings` is this verb's: acpmux's move times nothing itself.
    words.extend(request.options.into_iter().filter(|option| option != "--timings"));
    // run_acp parses the final JSON value, but acpmux otherwise defaults to a
    // human report with no JSON to return to this command.
    words.push("--json".to_owned());
    words
}

/// The option `word` means: an exact spelling, another spelling of it, or a
/// close misspelling (one or two edits from exactly one option).
fn canonical(word: &str) -> Option<&'static str> {
    let normal = word.replace('_', "-").to_ascii_lowercase();
    let options = || SWITCHES.iter().chain(VALUED.iter()).copied();
    if let Some(exact) = options().find(|option| *option == normal) {
        return Some(exact);
    }
    if let Some((_, option)) = SPELLINGS.iter().find(|(spelling, _)| *spelling == normal) {
        return Some(*option);
    }
    let squashed = |text: &str| text.replace('-', "");
    if let Some(option) = options().find(|option| squashed(option) == squashed(&normal)) {
        return Some(option);
    }
    if !normal.starts_with("--") || normal.len() < 5 {
        return None;
    }
    let names = options().chain(SPELLINGS.iter().map(|(spelling, _)| *spelling));
    let mut close = names
        .filter(|name| name.len() >= 5 && edits(name, &normal) <= 2)
        .map(|name| SPELLINGS.iter().find(|(s, _)| *s == name).map_or(name, |(_, option)| *option));
    let first = close.next()?;
    close.all(|other| other == first).then_some(first)
}

/// Levenshtein distance, for close misspellings of an option.
fn edits(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut next = Vec::with_capacity(row.len());
        next.push(i + 1);
        for (cb, pair) in b.iter().zip(row.windows(2)) {
            let [diagonal, up] = *pair else { continue };
            let left = next.last().copied().unwrap_or(i + 1);
            next.push((diagonal + usize::from(ca != *cb)).min(left + 1).min(up + 1));
        }
        row = next;
    }
    row.last().copied().unwrap_or(0)
}

/// The target as acpmux names it.
fn target(verb: Verb, value: &str) -> Result<String, UsageError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(UsageError::new(format!(
            "{}: --to needs a machine, cloud, auto or here",
            verb.word()
        )));
    }
    match value.to_ascii_lowercase().as_str() {
        "here" | "local" | "this-machine" | "this-mac" => Ok("local".to_owned()),
        "auto" | "any" | "best" => Ok("auto".to_owned()),
        // The app's Move to Cloud (agent_move_cloud.rs).
        "cloud" => Ok("cloud".to_owned()),
        _ => Ok(value.to_owned()),
    }
}

fn parse_request(
    verb: Verb,
    global: &GlobalArgs,
    args: &[String],
) -> Result<MoveRequest, UsageError> {
    let name = verb.word();
    let mut machine = global.machine.as_deref().map(|value| target(verb, value)).transpose()?;
    let mut sessions = Vec::new();
    let mut options = Vec::new();
    let mut all_idle = false;
    let mut words = args.iter();
    while let Some(word) = words.next() {
        if word == "--" {
            sessions.extend(words.by_ref().cloned());
            break;
        }
        if !word.starts_with('-') || word == "-" {
            sessions.push(word.clone());
            continue;
        }
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) => (flag, Some(value.to_owned())),
            None => (word.as_str(), None),
        };
        let option = canonical(flag)
            .ok_or_else(|| UsageError::new(format!("{name}: unknown option {flag}")))?;
        if option != flag && SPELLINGS.iter().all(|(spelling, _)| *spelling != flag) {
            eprintln!("cmux {name}: taking {flag} as {option}");
        }
        if VALUED.contains(&option) {
            let value = match inline {
                Some(value) => value,
                None => words
                    .next()
                    .filter(|value| !value.starts_with('-'))
                    .cloned()
                    .ok_or_else(|| UsageError::new(format!("{name}: {option} needs a value")))?,
            };
            if option == "--to" {
                machine = Some(target(verb, &value)?);
            } else {
                options.push(option.to_owned());
                options.push(value);
            }
        } else if inline.is_some() {
            return Err(UsageError::new(format!("{name}: {option} takes no value")));
        } else if option == "--all-idle" {
            all_idle = true;
        } else if !options.iter().any(|seen| seen == option) {
            options.push(option.to_owned());
        }
    }
    if verb == Verb::Evacuate {
        machine.get_or_insert_with(|| "auto".to_owned());
        all_idle |= sessions.is_empty();
    }
    let machine = machine.ok_or_else(|| {
        UsageError::new(format!("{name} needs --to MACHINE|cloud|auto|here (try `--to auto`)"))
    })?;
    if all_idle && !sessions.is_empty() {
        return Err(UsageError::new(format!("{name}: name sessions or --all-idle, not both")));
    }
    if sessions.is_empty() && !all_idle {
        return Err(UsageError::new(format!(
            "{name} needs a SESSION (or --all-idle; `cmux evacuate` moves every idle one)"
        )));
    }
    Ok(MoveRequest { sessions, machine, all_idle, options })
}

fn usage(verb: Verb, global: &GlobalArgs, message: &str) -> i32 {
    super::scope_usage_failure(global.output, verb.word(), message, &help(verb))
}

#[cfg(test)]
#[path = "agent_move_tests.rs"]
mod tests;
