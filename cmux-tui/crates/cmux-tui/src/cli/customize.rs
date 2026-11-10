//! `cmux customize`: change cmux by asking, watch it change, keep it or put
//! it back (cmuxterm-hq `plans/cmux-next/customize-by-asking/DESIGN.md`).
//!
//! The grammar, the words a person reads and the chat that does an ask live
//! here; everything else is the `cmux-customize` crate, which the GUI and
//! the `customize_*` MCP tools call too. The MCP tools run these verbs in
//! this process ([`run_json`]), so a tool and the CLI never differ.
//!
//! No verb needs the app or the daemon except an ask, which starts an agent
//! chat: status, apply, discard and rollback are file operations, so they
//! work with cmux quit and in safe mode.

mod ask;
mod render;
#[cfg(test)]
mod tests;

use cmux_customize::{Customize, Error};
use serde_json::{Value, json};

use super::OutputMode;

pub(super) const HELP: &str = "\
cmux customize: change cmux by asking, watch it change, keep it or put it back.

  cmux customize 'make the sidebar compact'   Ask: an agent changes cmux while you watch (a preview)
  cmux customize                              What is previewing, and what to do next (`status`)
  cmux customize diff                         The preview as text
  cmux customize apply [NOTE]                 Keep the preview: it becomes the next generation
  cmux customize discard                      Put the applied setup back (the draft is kept, by number)
  cmux customize rollback [N]                 Go back one generation, or to generation N
  cmux customize generations                  Every generation, newest first (`ls`)
  cmux customize show N                       What generation N changed
  cmux customize save NAME [NOTE]             Save what is live as a profile: one file to keep or share
  cmux customize use NAME|FILE                Preview a profile, then apply or discard it
  cmux customize profiles                     The saved profiles

You can also edit the files yourself (`cmux customize paths`): every save shows in cmux at
once, an agent you ask next keeps your edits, and apply, discard and rollback work the same.

For an agent (the customize_* MCP tools are these verbs):
  cmux customize brief 'WISH'                 Open the draft and print what to edit and how; starts no chat
  cmux customize check                        Validate what is live, and mark your turn done

Ask options:
  --harness HARNESS   The agent that does it: claude (default), codex, ...
  --model MODEL       Its model
  -w, --wait          Wait for the agent's turn to end, then print its reply and the preview
  --timeout DURATION  How long --wait waits: 30s, 5m (default 15m)
  --new               A new chat, instead of going on in the draft's chat
Every verb takes --json. Exit codes: 0 ok, 1 refused (the error's code says why), 2 bad arguments.
Nothing here needs the app but an ask: generations are files, so rollback works with cmux
quit and in safe mode.
";

/// Every verb, for \"did you mean\".
const VERBS: &[&str] = &[
    "status",
    "diff",
    "apply",
    "discard",
    "rollback",
    "generations",
    "show",
    "save",
    "use",
    "profiles",
    "paths",
    "brief",
    "check",
    "ask",
];

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct AskOptions {
    pub harness: Option<String>,
    pub model: Option<String>,
    pub wait: bool,
    pub timeout: Option<String>,
    pub new_chat: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    Help,
    Status,
    Diff,
    Ask { wish: String, options: AskOptions },
    Brief { wish: String },
    Check,
    Apply { note: Option<String> },
    Discard,
    Rollback { to: Option<u32> },
    Generations,
    Show { n: u32 },
    Save { name: String, note: String },
    Use { source: String },
    Profiles,
    Paths,
}

/// Parses the words after `customize` (`--json` already taken out). The
/// error is what was wrong, in one line.
pub(super) fn parse(words: &[String]) -> Result<Request, String> {
    let Some((first, rest)) = words.split_first() else { return Ok(Request::Status) };
    if matches!(first.as_str(), "-h" | "--help" | "help")
        || rest.iter().any(|w| w == "-h" || w == "--help")
    {
        return Ok(Request::Help);
    }
    let none = |request: Request| match rest.first() {
        None => Ok(request),
        Some(extra) => Err(format!("customize {first} takes nothing after it, got {extra:?}")),
    };
    let number = |word: &String| {
        word.trim_start_matches('#').parse::<u32>().map_err(|_| {
            format!("{word:?} is not a generation number (`cmux customize generations` lists them)")
        })
    };
    match first.as_str() {
        "status" | "st" => none(Request::Status),
        "diff" => none(Request::Diff),
        "check" => none(Request::Check),
        "discard" => none(Request::Discard),
        "generations" | "generation" | "gens" | "list" | "ls" | "history" | "log" => {
            none(Request::Generations)
        }
        "profiles" => none(Request::Profiles),
        "paths" => none(Request::Paths),
        "apply" => Ok(Request::Apply { note: (!rest.is_empty()).then(|| rest.join(" ")) }),
        "rollback" | "undo" | "switch" => match rest {
            [] => Ok(Request::Rollback { to: None }),
            [n] => Ok(Request::Rollback { to: Some(number(n)?) }),
            _ => Err("customize rollback takes one generation number".to_owned()),
        },
        "show" => match rest {
            [n] => Ok(Request::Show { n: number(n)? }),
            _ => Err("customize show needs one generation number".to_owned()),
        },
        "save" => {
            match rest.split_first() {
                Some((name, note)) if !name.starts_with('-') => {
                    Ok(Request::Save { name: name.clone(), note: note.join(" ") })
                }
                _ => Err("customize save needs a NAME, like `cmux customize save compact-night`"
                    .to_owned()),
            }
        }
        "use" => match rest {
            [source] if !source.starts_with('-') => Ok(Request::Use { source: source.clone() }),
            _ => Err("customize use needs one profile NAME or FILE".to_owned()),
        },
        "brief" => match wish_of(rest)? {
            (wish, options) if options == AskOptions::default() => Ok(Request::Brief { wish }),
            _ => Err("customize brief takes only the wish (it starts no chat)".to_owned()),
        },
        "ask" => wish_of(rest).map(|(wish, options)| Request::Ask { wish, options }),
        // A wish is said in words: one quoted argument with a space in it, or
        // several words. One bare word is a verb, so a typo gets a suggestion
        // instead of an agent.
        _ if first.starts_with('-') || words.len() > 1 || first.contains(char::is_whitespace) => {
            wish_of(words).map(|(wish, options)| Request::Ask { wish, options })
        }
        _ => {
            let near = VERBS
                .iter()
                .filter(|verb| super::scope_help::edit_distance(first, verb) <= 2)
                .map(|verb| format!("`{verb}`"))
                .collect::<Vec<_>>();
            let hint = if near.is_empty() {
                "say what you want in quotes, like `cmux customize 'make the sidebar compact'`"
                    .to_owned()
            } else {
                format!("did you mean {}?", near.join(" or "))
            };
            Err(format!("unknown customize command {first:?}; {hint}"))
        }
    }
}

/// The wish (every word that is not an option, joined) and the ask options.
fn wish_of(words: &[String]) -> Result<(String, AskOptions), String> {
    let mut options = AskOptions::default();
    let mut wish = Vec::new();
    let mut iter = words.iter();
    while let Some(word) = iter.next() {
        match word.as_str() {
            "--harness" | "--agent" => options.harness = Some(value_of(&mut iter, word)?),
            "--model" => options.model = Some(value_of(&mut iter, word)?),
            "--timeout" => options.timeout = Some(value_of(&mut iter, word)?),
            "-w" | "--wait" => options.wait = true,
            "--new" => options.new_chat = true,
            "--" => {
                wish.extend(iter.by_ref().cloned());
            }
            flag if flag.starts_with("--") => {
                return Err(format!("customize does not take {flag:?}"));
            }
            _ => wish.push(word.clone()),
        }
    }
    let wish = wish.join(" ").trim().to_owned();
    if wish.is_empty() {
        return Err(
            "say what you want, like `cmux customize 'make the sidebar compact'`".to_owned()
        );
    }
    Ok((wish, options))
}

fn value_of(iter: &mut std::slice::Iter<'_, String>, flag: &str) -> Result<String, String> {
    iter.next().cloned().ok_or_else(|| format!("{flag} needs a value"))
}

/// A verb that failed: the envelope's code and message, and the exit code.
#[derive(Debug)]
pub(super) struct Failure {
    pub code: String,
    pub message: String,
    pub details: Value,
    pub exit: i32,
}

impl Failure {
    fn usage(what: String) -> Failure {
        Failure { code: "usage.invalid".to_owned(), message: what, details: json!({}), exit: 2 }
    }

    pub(super) fn envelope(&self) -> Value {
        json!({"code": self.code, "message": self.message, "details": self.details, "retryable": false})
    }
}

impl From<Error> for Failure {
    fn from(error: Error) -> Failure {
        let details = match &error {
            Error::Invalid(problems) => json!({ "problems": problems }),
            Error::Untracked(skipped) => json!({ "skipped": skipped }),
            _ => json!({}),
        };
        Failure { code: error.code().to_owned(), message: error.to_string(), details, exit: 1 }
    }
}

/// Who reads a diff. An agent over MCP sees what the settings tools show it
/// (no credential, no setting only the person may read); a person at the
/// terminal sees their own settings, credentials still masked.
fn reader(origin: &str) -> cmux_customize::Reader {
    if origin == "mcp" { cmux_customize::Reader::Agent } else { cmux_customize::Reader::Person }
}

pub(super) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_millis() as u64)
}

/// `Some(exit code)` when `args` is `customize …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, words) = super::parse_globals(args).ok()?;
    let rest =
        words.split_first().filter(|(scope, _)| *scope == "customize").map(|(_, rest)| rest)?;
    // `--json` after the verb, as everywhere.
    let rest: Vec<String> = rest
        .iter()
        .filter(|word| {
            let json = *word == "--json";
            if json {
                global.output = OutputMode::Json;
            }
            !json
        })
        .cloned()
        .collect();
    let request = match parse(&rest) {
        Ok(request) => request,
        Err(what) => {
            return Some(super::scope_usage_failure(global.output, "customize", &what, HELP));
        }
    };
    if request == Request::Help {
        print!("{HELP}");
        return Some(0);
    }
    let json_out = matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let chat = ask::Child { globals: super::chat_start::global_words(&global) };
    let result = Customize::from_env()
        .map_err(Failure::from)
        .and_then(|customize| execute(&customize, request, "cli", now_ms(), &chat));
    Some(match result {
        Ok(answer) => {
            if json_out {
                println!("{}", answer.json());
            } else if global.output != OutputMode::Quiet {
                print!("{}", answer.human(now_ms()));
            }
            answer.exit()
        }
        Err(failure) if failure.exit == 2 => {
            super::scope_usage_failure(global.output, "customize", &failure.message, HELP)
        }
        Err(failure) => {
            let envelope_exit = failure.exit;
            let message = if json_out {
                failure.message.clone()
            } else {
                format!("cmux: {}", failure.message)
            };
            let envelope = Failure { message, ..failure }.envelope();
            super::wire::print_local_error(&envelope, global.output, envelope_exit)
        }
    })
}

/// `cmux customize WORDS…` in this process with its JSON answer returned:
/// what the `customize_*` MCP tools call. An ask from MCP is the calling
/// agent's own work, so no verb here starts a chat.
pub(super) fn run_json(words: &[String], origin: &str) -> Result<Value, Value> {
    let request = parse(words).map_err(|what| Failure::usage(what).envelope())?;
    if matches!(request, Request::Ask { .. } | Request::Help) {
        return Err(Failure::usage(
            "this verb is not a tool; use customize_ask for the brief".to_owned(),
        )
        .envelope());
    }
    let customize = Customize::from_env().map_err(|error| Failure::from(error).envelope())?;
    execute(&customize, request, origin, now_ms(), &ask::NoChat)
        .map(|answer| answer.json())
        .map_err(|failure| failure.envelope())
}

/// One verb against one customization.
pub(super) fn execute(
    customize: &Customize,
    request: Request,
    origin: &str,
    now_ms: u64,
    chat: &dyn ask::Chat,
) -> Result<render::Answer, Failure> {
    use render::Answer;
    // The first verb anyone runs records generation 1, so there is always
    // something to go back to.
    customize.ensure_baseline(now_ms)?;
    Ok(match request {
        Request::Help => return Err(Failure::usage("customize needs a command".to_owned())),
        Request::Status => Answer::Status(customize.status()?),
        Request::Check => {
            customize.end_turn()?;
            Answer::Status(customize.status()?)
        }
        Request::Diff => Answer::Diff(customize.diff(reader(origin))?),
        Request::Show { n } => Answer::Show(n, customize.generation_diff(n, reader(origin))?),
        Request::Brief { wish } => {
            let begun = customize.begin(&wish, origin, now_ms)?;
            let status = customize.status()?;
            let brief = cmux_customize::brief(&wish, customize.roots(), &status);
            Answer::Brief { brief, begun, status }
        }
        Request::Ask { wish, options } => {
            ask::ask(customize, &wish, &options, origin, now_ms, chat)?
        }
        Request::Apply { note } => {
            Answer::Applied(customize.apply(note.as_deref(), origin, now_ms)?)
        }
        Request::Discard => Answer::Discarded(customize.discard(origin, now_ms)?),
        Request::Rollback { to } => Answer::RolledBack(customize.rollback(to, origin, now_ms)?),
        Request::Generations => Answer::Generations(customize.generations()?),
        Request::Save { name, note } => {
            Answer::Saved(customize.save_profile(&name, &note, now_ms)?)
        }
        Request::Use { source } => {
            let profile = customize.load_profile(&source)?;
            let begun = customize.preview_profile(&profile, origin, now_ms)?;
            Answer::Using { name: profile.name, begun, status: customize.status()? }
        }
        Request::Profiles => Answer::Profiles(customize.profiles()?),
        Request::Paths => Answer::Paths(customize.roots().clone()),
    })
}
