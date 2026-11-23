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
//! work with cmux quit and in safe mode. With a daemon running, a verb asks
//! it to load the customization folder before it returns ([`load_views`]),
//! so the views it wrote are there for the next thing the person opens.

mod ask;
mod dir;
mod doctor;
mod expire;
mod library;
mod pr;
mod render;
mod source;
#[cfg(test)]
mod tests;

use cmux_customize::schema::{Schema, Section};
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
  cmux customize use NAME|FILE                Preview a profile (or a recipe, by name), then apply or discard it
  cmux customize try [NAME|FILE] [--minutes N] Try it on: applied now, back by itself in N minutes (10)
  cmux customize keep                         Keep what you are trying on
  cmux customize revert                       Stop trying it on: put back what was there before
  cmux customize use CODE                     Try code not in your build: on top of your library, live
    pr:N                                      a pull request (CI publishes its web layer)
    branch:NAME | sha:SHA                     a branch's tip or a commit of manaflow-ai/cmux, pushed, no PR
    dir:PATH [--watch]                        your working copy, built here: no push, no CI; --watch
                                              builds and applies it again on every save
    OWNER/REPO@REF                            a fork's branch, from the layer the fork's own CI published
                                              (cmux-web-layer-fork.yml): it runs that fork's code in your cmux
                                              (`library off NAME` puts back what was under any of them)
  cmux customize try CODE [--minutes N]       Try code on: as `use`, then off by itself in N minutes (10);
                                              `library on NAME` keeps it, `library off NAME` ends it now
  cmux customize profiles                     The saved profiles
  cmux customize recipes [--open]             Ready-made changes to try with `use` (--open: the guide, in cmux)
  cmux customize library [VERB]               Everything you applied, kept as layers: list|status|on|off|order|export|import|remove
  cmux customize doctor                       What changes your customization unexpectedly: stale layers, broken,
                                              shadowed, leftover or misplaced files, unknown keys, values off their default; `fix ID ...`, `recover`
  cmux customize library refresh             Every code layer against what is published and this app; with
                                              --if-app-changed only when the app's commit changed (cmux runs it at start)

If a layer broke cmux (no app needed, with cmux quit too):
  cmux customize library status               Which layers are on, in one line (also in `cmux version`)
  cmux customize library expire               Turn off layers past their bound: a merged or closed PR,
                                              a code layer on over 24 h, a hand overlay as old
  cmux customize library on web-dev-overlay   Turn an expired hand-installed overlay back on
  cmux customize library off --code           Every code layer off (PR, branch, folder, fork); cmux serves its own pages
  cmux customize library reset                Every layer off: settings, files and web-dev.json as before any

You can also edit the files yourself (`cmux customize paths`): every save shows in cmux at
once, an agent you ask next keeps your edits, and apply, discard and rollback work the same.

For an agent (the customize_* MCP tools are these verbs):
  cmux customize brief 'WISH'                 Open the draft and print what to edit and how; starts no chat
  cmux customize check                        Validate what is live, and mark your turn done
  cmux customize schema [PART]                Every key you can change (settings, theme, views, extensions); --typescript, --rust

Ask options:
  --harness HARNESS   The agent that does it: claude (default), codex, ...
  --model MODEL       Its model
  -w, --wait          Wait for the agent's turn to end, then print its reply and the preview
  --timeout DURATION  How long --wait waits: 30s, 5m (default 15m)
  --new               A new chat, instead of going on in the draft's chat
Every verb takes --json. Exit codes: 0 ok, 1 refused (the error's code says why), 2 bad arguments.
Nothing here needs the app but an ask: generations are files, so rollback works with cmux
quit and in safe mode.

If a layer breaks the window itself, quit cmux and open it once on its built-in web UI:
  open -a \"cmux NIGHTLY\" --args --no-customizations
(or CMUX_NO_CUSTOMIZATIONS=1, or hold Option and Shift as it starts). It edits no file. A page that
does not start from a layer falls back on its own and turns the layer off, saying why.
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
    "recipes",
    "try",
    "keep",
    "revert",
    "library",
    "doctor",
    "paths",
    "brief",
    "check",
    "ask",
    "schema",
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
    Ask {
        wish: String,
        options: AskOptions,
    },
    Brief {
        wish: String,
    },
    Check,
    Apply {
        note: Option<String>,
    },
    Discard,
    Rollback {
        to: Option<u32>,
    },
    Generations,
    Show {
        n: u32,
    },
    Save {
        name: String,
        note: String,
    },
    Use {
        /// `--watch` (a `dir:` source only): build and apply again on a save.
        watch: bool,
        source: String,
    },
    /// A try-on of a profile, or with `None` of what is live now; with a
    /// code source (`pr:N`, `dir:PATH`, ...), that code's library entry, on
    /// until its time is up.
    Try {
        source: Option<String>,
        duration_ms: u64,
    },
    Keep,
    Revert,
    /// Settles a try-on whose time is up; with `wait`, waits for it first
    /// (the child `try` leaves running, and the app's start).
    Settle {
        wait: bool,
    },
    /// Waits for every code try (`try pr:N`) and turns each off at its time
    /// (the child a code `try` leaves running).
    SettleCode,
    Profiles,
    Recipes {
        open: bool,
    },
    Library(library::Request),
    Doctor(doctor::Request),
    Paths,
    Schema {
        section: Option<Section>,
        format: SchemaFormat,
    },
}

/// How `customize schema` answers: the schema, or the SDK types written from it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SchemaFormat {
    Schema,
    TypeScript,
    Rust,
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
        "recipes" | "recipe" => match rest {
            [] => Ok(Request::Recipes { open: false }),
            [flag] if flag == "--open" => Ok(Request::Recipes { open: true }),
            _ => Err("customize recipes takes only --open".to_owned()),
        },
        "keep" => none(Request::Keep),
        "revert" => none(Request::Revert),
        "settle" => match rest {
            [] => Ok(Request::Settle { wait: false }),
            [flag] if flag == "--wait" => Ok(Request::Settle { wait: true }),
            [a, b] if a == "--wait" && b == "--code" => Ok(Request::SettleCode),
            _ => Err("customize settle takes only --wait (and --code)".to_owned()),
        },
        "try" | "try-on" => try_of(rest),
        "library" | "lib" => library::parse(rest).map(Request::Library),
        "doctor" | "dr" => doctor::parse(rest).map(Request::Doctor),
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
        "use" => {
            let watch = rest.iter().any(|word| word == "--watch");
            let words: Vec<&String> = rest.iter().filter(|word| *word != "--watch").collect();
            match words.as_slice() {
                [source] if watch && !matches!(source::parse(source), Some(source::Source::Dir(_))) => {
                    Err("--watch is for a folder: cmux customize use dir:PATH --watch".to_owned())
                }
                [source] if !source.starts_with('-') || source::parse(source).is_some() => {
                    Ok(Request::Use { watch, source: (*source).clone() })
                }
                _ => Err("customize use needs one profile NAME or FILE, or code: pr:N, branch:NAME, sha:SHA, dir:PATH or OWNER/REPO@REF".to_owned()),
            }
        }
        "brief" => match wish_of(rest)? {
            (wish, options) if options == AskOptions::default() => Ok(Request::Brief { wish }),
            _ => Err("customize brief takes only the wish (it starts no chat)".to_owned()),
        },
        "ask" => wish_of(rest).map(|(wish, options)| Request::Ask { wish, options }),
        "schema" => schema_of(rest),
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

/// `try [NAME|FILE] [--minutes N]`.
fn try_of(words: &[String]) -> Result<Request, String> {
    let mut source = None;
    let mut minutes = f64::from(cmux_customize::DEFAULT_TRY_ON_MINUTES);
    let mut iter = words.iter();
    while let Some(word) = iter.next() {
        match word.as_str() {
            "--minutes" | "-m" => {
                let value = value_of(&mut iter, word)?;
                minutes = value
                    .parse::<f64>()
                    .ok()
                    .filter(|minutes| minutes.is_finite() && *minutes > 0.0)
                    .ok_or_else(|| format!("--minutes takes a number of minutes, got {value:?}"))?;
            }
            flag if flag.starts_with('-') => {
                return Err(format!("customize try does not take {flag:?}"));
            }
            _ if source.is_none() => source = Some(word.clone()),
            _ => return Err("customize try takes one profile NAME or FILE, or code: pr:N, branch:NAME, sha:SHA, dir:PATH or OWNER/REPO@REF".to_owned()),
        }
    }
    Ok(Request::Try { source, duration_ms: (minutes * 60_000.0).round() as u64 })
}

/// `schema [PART] [--typescript|--rust]`.
fn schema_of(words: &[String]) -> Result<Request, String> {
    let (mut section, mut format) = (None, SchemaFormat::Schema);
    for word in words {
        match word.as_str() {
            "--typescript" | "--ts" => format = SchemaFormat::TypeScript,
            "--rust" => format = SchemaFormat::Rust,
            part if section.is_none() && !part.starts_with('-') => {
                section = Some(Section::parse(part).ok_or_else(|| {
                    format!("customize schema has no part {part:?}; name {}", Section::NAMES)
                })?);
            }
            other => return Err(format!("customize schema does not take {other:?}")),
        }
    }
    if section.is_some() && format != SchemaFormat::Schema {
        return Err("customize schema --typescript and --rust write every part".to_owned());
    }
    Ok(Request::Schema { section, format })
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
            Error::Protected(keys) => json!({ "settings": keys }),
            _ => json!({}),
        };
        Failure { code: error.code().to_owned(), message: error.to_string(), details, exit: 1 }
    }
}

/// The global options the chat commands run with: where the caller pointed
/// (`--socket`, `--session`, `--machine`), never how it asked for output.
/// Each chat command is given its own `--json`, so passing the caller's
/// `--json`, `--jsonl` or `--quiet` on too would give the child two output
/// flags, and it would refuse them.
pub(super) fn child_globals(global: &super::GlobalArgs) -> Vec<String> {
    let global = super::GlobalArgs { output: OutputMode::Human, ..global.clone() };
    super::chat_start::global_words(&global)
}

/// Who reads a diff. An agent over MCP sees what the settings tools show it
/// (no credential, no setting only the person may read); a person at the
/// terminal sees their own settings, credentials still masked.
fn reader(origin: &str) -> cmux_customize::Reader {
    if origin == "mcp" { cmux_customize::Reader::Agent } else { cmux_customize::Reader::Person }
}

/// The web ABI an app's own pages need: `bundle`'s, else the app this CLI is
/// in (or `CMUX_CUSTOMIZE_APP`). What a web-dev overlay is judged against.
pub(super) fn app_web_abi(bundle: Option<&std::path::Path>) -> Option<u32> {
    match bundle {
        Some(bundle) => pr::web_abi_of(bundle),
        None => pr::App::find().abi,
    }
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
    // The schema reads only this build's tables: no store, no baseline.
    if let Request::Schema { section, format } = request {
        let answer = render::Answer::Schema(Schema::current(), section, format);
        if json_out && format == SchemaFormat::Schema {
            println!("{}", answer.json());
        } else if global.output != OutputMode::Quiet {
            print!("{}", answer.human(now_ms()));
        }
        return Some(0);
    }
    let chat = ask::Child { globals: child_globals(&global) };
    let result = Customize::from_env().map_err(Failure::from).and_then(|customize| {
        let answer = execute(&customize, request, "cli", now_ms(), &chat)?;
        Ok((answer, load_views(&global, &customize)))
    });
    Some(match result {
        Ok((answer, loaded)) => {
            if let super::ext::FolderLoad::Refused(issue) = &loaded
                && global.output != OutputMode::Quiet
            {
                eprintln!("cmux: the customization's views did not load: {issue}");
            }
            spawn_waiter_for(&answer);
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
pub(super) fn run_json(
    global: &super::GlobalArgs,
    words: &[String],
    origin: &str,
) -> Result<Value, Value> {
    let request = parse(words).map_err(|what| Failure::usage(what).envelope())?;
    if matches!(request, Request::Ask { .. } | Request::Help) {
        return Err(Failure::usage(
            "this verb is not a tool; use customize_ask for the brief".to_owned(),
        )
        .envelope());
    }
    if let Request::Schema { section, format } = request {
        return Ok(render::Answer::Schema(Schema::current(), section, format).json());
    }
    let customize = Customize::from_env().map_err(|error| Failure::from(error).envelope())?;
    let answer = execute(&customize, request, origin, now_ms(), &ask::NoChat)
        .map_err(|failure| failure.envelope())?;
    load_views(global, &customize);
    spawn_waiter_for(&answer);
    Ok(answer.json())
}

/// Asks the running daemon to load the customization folder now, after a
/// verb that may have rewritten it (`use`, `discard`, `rollback`, a try-on, a
/// library change, or any verb that settled a try-on whose time was up), and
/// waits for its answer. Without it the verb returned before the daemon's
/// folder watch, seconds late on a loaded Mac, had loaded the look's app: a
/// New Tab page opened at once found no app to show and kept cmux's own
/// page. A folder that did not change costs the daemon one fingerprint read;
/// with no daemon, or one too old to ask, nothing waits.
pub(super) fn load_views(
    global: &super::GlobalArgs,
    customize: &Customize,
) -> super::ext::FolderLoad {
    super::ext::load_customize_folder(global, &customize.roots().customize_dir)
}

/// The JSON key a code try's answer carries its end time under; its
/// presence is what leaves the code waiter running.
const TRY_UNTIL: &str = "try_until_ms";

/// Leaves the waiter a try needs running: `settle --wait` for a profile's
/// try-on, `settle --wait --code` for a code try.
fn spawn_waiter_for(answer: &render::Answer) {
    match answer {
        render::Answer::TriedOn(_) => spawn_waiter(&["customize", "settle", "--wait"]),
        render::Answer::Library { json, .. } if json.get(TRY_UNTIL).is_some() => {
            spawn_waiter(&["customize", "settle", "--wait", "--code"]);
        }
        _ => {}
    }
}

/// Leaves `cmux customize settle --wait [--code]` running on its own, so a
/// try reverts at its time with this process gone. It is not the only guard:
/// the app's start and every verb settle a try-on whose time is up (and
/// `library status`/`list` expire a code try), so a waiter lost to a reboot
/// changes nothing but when the revert lands.
fn spawn_waiter(args: &[&str]) {
    let Ok(exe) = std::env::current_exe() else { return };
    let mut command = cmux_process::Command::new(exe);
    command
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        // Its own session: the terminal's hangup or Ctrl-C does not reach it.
        .new_session();
    if let Ok(mut child) = command.spawn() {
        // It returns once no try-on is left (kept, reverted or replaced), and init reaps it.
        child.detach("a try-on reverts at its time after the command that started it exits");
    }
}

/// `cmux customize try CODE [--minutes N]`: `use CODE`, then the entry goes
/// off by itself when its time is up (cmuxterm-hq
/// `docs/design/experiments-shelf.md`: "`cmux customize try pr:N --minutes
/// 5` should take a PR the same way"). A folder is built once (no watch).
fn try_code(
    customize: &Customize,
    source: &str,
    duration_ms: u64,
    origin: &str,
    now_ms: u64,
) -> Result<render::Answer, Failure> {
    let max_ms = u64::from(cmux_customize::MAX_TRY_ON_MINUTES) * 60_000;
    // Said before any fetch or build, so a bad time costs nothing.
    if !(1_000..=max_ms).contains(&duration_ms) {
        return Err(Error::TryOnTime.into());
    }
    let answer = match source::parse(source) {
        Some(source::Source::Dir(path)) => dir::use_dir(customize, &path, false, origin, now_ms)?,
        Some(code) => pr::use_code(customize, code, origin, now_ms)?,
        None => return Err(Failure::usage(format!("{source:?} is not code to try"))),
    };
    let render::Answer::Library { mut json, mut human } = answer else { return Ok(answer) };
    let Some(name) = json.get("name").and_then(Value::as_str).map(str::to_owned) else {
        return Ok(render::Answer::Library { json, human });
    };
    let on = customize.library()?.entries.iter().any(|entry| entry.name == name && entry.on);
    if !on {
        // Nothing a running cmux can take: it is in the library, off, and
        // there is nothing to time.
        return Ok(render::Answer::Library { json, human });
    }
    // From when it is on, not when the fetch or build began.
    let until_ms = self::now_ms().max(now_ms).saturating_add(duration_ms);
    customize.library_try_until(&name, until_ms, origin, now_ms)?;
    if let Some(object) = json.as_object_mut() {
        object.insert(TRY_UNTIL.to_owned(), json!(until_ms));
    }
    human.push_str(&format!(
        "  trying it on: off by itself in {}\n  cmux customize library on {name}    keep it\n",
        cmux_customize::library::expire::minutes(duration_ms)
    ));
    Ok(render::Answer::Library { json, human })
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
    // A try-on whose time is up reverts at the first look, whoever looks.
    let settled = match &request {
        Request::Settle { wait: true } => customize.run_try_on_timer()?,
        _ => customize.settle(now_ms)?.into_iter().collect(),
    };
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
        Request::Use { source, watch } => match source::parse(&source) {
            Some(source::Source::Dir(path)) => {
                dir::use_dir(customize, &path, watch, origin, now_ms)?
            }
            Some(code) => pr::use_code(customize, code, origin, now_ms)?,
            None => {
                let profile = load_profile_or_recipe(customize, &source)?;
                let begun = customize.preview_profile(&profile, origin, now_ms)?;
                Answer::Using { name: profile.name, begun, status: customize.status()? }
            }
        },
        Request::Try { source: Some(source), duration_ms } if source::parse(&source).is_some() => {
            try_code(customize, &source, duration_ms, origin, now_ms)?
        }
        Request::SettleCode => {
            let expired = customize.run_code_try_timer(app_web_abi(None), origin);
            let human = library::expired_lines(&expired, None);
            Answer::Library { json: json!({ "expired": expired }), human }
        }
        Request::Try { source, duration_ms } => {
            let profile = source
                .as_deref()
                .map(|source| load_profile_or_recipe(customize, source))
                .transpose()?;
            Answer::TriedOn(customize.try_on(profile.as_ref(), duration_ms, origin, now_ms)?)
        }
        Request::Keep => Answer::Settled(customize.keep()?.into_iter().collect(), "keep"),
        Request::Revert => Answer::Settled(
            settled.into_iter().chain(customize.revert_try_on(origin, now_ms)?).collect(),
            "revert",
        ),
        Request::Settle { .. } => Answer::Settled(settled, "settle"),
        Request::Profiles => Answer::Profiles(customize.profiles()?),
        Request::Recipes { open } => recipes(customize, open, chat)?,
        Request::Library(request) => library::execute(customize, request, origin, now_ms)?,
        Request::Doctor(request) => doctor::execute(customize, request, origin, now_ms)?,
        Request::Paths => Answer::Paths(customize.roots().clone()),
        Request::Schema { section, format } => Answer::Schema(Schema::current(), section, format),
    })
}

/// Writes the recipes (cmux-customize-recipes) where `use` reads them, and
/// with `open` shows their guide in cmux's Markdown page, where each
/// recipe's command has a Run button: the one-click Try it. The recipes
/// are profiles, so trying one is `use`: a draft, then apply or discard.
fn recipes(
    customize: &Customize,
    open: bool,
    chat: &dyn ask::Chat,
) -> Result<render::Answer, Failure> {
    let dir = customize.roots().state_dir.join("recipes");
    let written = cmux_customize_recipes::write_all(&dir).map_err(Error::from)?;
    let opened = open.then(|| {
        let guide = written.guide.display().to_string();
        match chat.run(&["open".to_owned(), guide]) {
            Ok(result) if result.ok => Ok(()),
            Ok(result) => Err(result.stderr.trim().to_owned()),
            Err(error) => Err(error),
        }
    });
    Ok(render::Answer::Recipes { written, opened })
}

/// A saved profile called `source`, else the profile at that path; when
/// neither exists and `source` is a recipe's name, that recipe (so
/// `cmux customize use ukiyo-e` works without `recipes` first). A saved
/// profile of the same name wins over the recipe.
fn load_profile_or_recipe(
    customize: &Customize,
    source: &str,
) -> Result<cmux_customize::profile::Profile, Error> {
    match customize.load_profile(source) {
        Ok(profile) => Ok(profile),
        Err(error) => match cmux_customize_recipes::find(source) {
            Some(recipe) if !std::path::Path::new(source).exists() => {
                recipe.profile().map_err(Error::Profile)
            }
            _ => Err(error),
        },
    }
}
