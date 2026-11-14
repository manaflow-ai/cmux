//! `cmux ext`: the extension author's CLI (docs/cmux-next/extensions/dev-loop.md).
//!
//! An extension is an app on the app platform; `ext` is the author-facing
//! noun and `cmux apps ...` keeps working unchanged. `ext new` scaffolds a
//! folder, `ext dev` loads it into the running cmux and reloads it on every
//! save (`dev.rs`), `ext shot` shows what it rendered (`shot.rs`), `ext list`
//! and `ext remove` show and drop the folders `ext dev` loaded.

mod daemon;
mod dev;
mod scaffold;
mod scene;
mod shot;
#[cfg(test)]
mod tests;

use std::path::PathBuf;
use std::sync::mpsc::channel;

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

/// A key read that never panics: a missing key, or a value that is not an
/// object, reads as `null` (what `value["key"]` returns, without the index).
pub(super) trait Field {
    fn field(&self, key: &str) -> &Value;
}

impl Field for Value {
    fn field(&self, key: &str) -> &Value {
        static NULL: Value = Value::Null;
        self.get(key).unwrap_or(&NULL)
    }
}

/// Exit codes of `ext dev` (`--once` is what an agent's loop reads).
pub(super) mod exit {
    pub const OK: i32 = 0;
    pub const LOAD_FAILED: i32 = 1;
    pub const USAGE: i32 = 2;
    pub const NO_DAEMON: i32 = 3;
    pub const MANIFEST_INVALID: i32 = 4;
    pub const BUILD_FAILED: i32 = 5;
    /// `ext shot`: it loaded and rendered, but no picture was taken.
    pub const SHOT_FAILED: i32 = 6;
    pub const INTERRUPTED: i32 = 130;
}

const HELP: &str = "\
cmux ext: make a cmux extension and watch it change as you work.
  cmux ext new NAME [--kind K] a working extension folder ./NAME on the SDK this cmux ships;
                               K: section (default, a sidebar section), pane, command
  cmux ext dev [DIR]           load DIR into cmux, then reload it on every save (Ctrl-C stops)
  cmux ext dev --once --json   one validate + build + reload; exit 0 ok, 1 load, 3 no cmux, 4 manifest, 5 build
  cmux ext shot [DIR] [--out PNG] [--json]
                               one reload, then what it rendered: the view's outline and a
                               picture of the cmux window that shows it; exit 6 no picture
  cmux ext list | remove ID    the extensions loaded this way; remove drops one
  cmux ext capabilities [--op NAME] [--json]
                               what an extension can read and do: each op's scope, risk class
                               and consent text, from the running cmux (--json adds the types)

ext dev options: --build CMD (run instead of the packer), --build-timeout SECS (default 120),
  --remove-on-exit, --no-install.
Docs: docs/cmux-next/extensions/dev-loop.md";

/// `ext dev`'s options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct DevOptions {
    pub dir: PathBuf,
    pub once: bool,
    pub remove_on_exit: bool,
    /// Ask the person to install it when it is not (watch mode).
    pub install: bool,
    pub build: Option<String>,
    /// How long one build may run before it is stopped (`--build-timeout`).
    pub build_timeout: std::time::Duration,
    /// `bun` for the packer (found on PATH; tests set none).
    pub bun: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    Help,
    New {
        name: String,
        kind: String,
        dir: Option<PathBuf>,
    },
    Dev(DevOptions),
    Shot(shot::ShotOptions),
    List,
    Remove {
        app: String,
    },
    /// The running cmux's capability manifest, or one op's row.
    Capabilities {
        op: Option<String>,
    },
}

/// Parses the words after `ext` (`--json` already taken out).
pub(super) fn parse(words: &[String]) -> Result<Request, String> {
    let usage = |what: &str| format!("{what}\n\n{HELP}");
    let Some((verb, rest)) = words.split_first() else { return Ok(Request::Help) };
    match verb.as_str() {
        "-h" | "--help" | "help" => Ok(Request::Help),
        _ if rest.iter().any(|w| w == "-h" || w == "--help") => Ok(Request::Help),
        "new" => {
            let mut name = None;
            let mut kind = "section".to_string();
            let mut dir = None;
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--kind" => {
                        kind = words.next().ok_or_else(|| usage("--kind needs a kind"))?.clone();
                    }
                    "--dir" => {
                        dir = Some(PathBuf::from(
                            words.next().ok_or_else(|| usage("--dir needs a path"))?,
                        ));
                    }
                    flag if flag.starts_with('-') => {
                        return Err(usage(&format!("unknown option {flag}")));
                    }
                    _ if name.is_some() => return Err(usage("ext new takes one NAME")),
                    _ => name = Some(word.clone()),
                }
            }
            let name = name.ok_or_else(|| usage("ext new needs a NAME"))?;
            if !scaffold::valid_name(&name) {
                return Err(usage(&format!(
                    "{name}: a name is lowercase letters, digits and '-', starting with a letter or digit (not \"customize\")"
                )));
            }
            if kind == "widget" {
                return Err(usage(
                    "--kind widget needs the new tab page's widget interface, which this cmux does not have yet; --kind section works",
                ));
            }
            if !scaffold::KINDS.contains(&kind.as_str()) {
                return Err(usage(&format!(
                    "--kind {kind}: one of {}",
                    scaffold::KINDS.join(", ")
                )));
            }
            Ok(Request::New { name, kind, dir })
        }
        "dev" => {
            let mut options = DevOptions {
                dir: PathBuf::from("."),
                once: false,
                remove_on_exit: false,
                install: true,
                build: None,
                build_timeout: dev::BUILD_TIMEOUT,
                bun: None,
            };
            let mut dir = None;
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--once" => options.once = true,
                    "--keep" => options.remove_on_exit = false,
                    "--remove-on-exit" => options.remove_on_exit = true,
                    "--no-install" => options.install = false,
                    "--build" => {
                        options.build = Some(
                            words.next().ok_or_else(|| usage("--build needs a command"))?.clone(),
                        );
                    }
                    "--build-timeout" => {
                        let seconds = words
                            .next()
                            .and_then(|s| s.parse::<u64>().ok())
                            .filter(|s| *s > 0)
                            .ok_or_else(|| usage("--build-timeout needs a number of seconds"))?;
                        options.build_timeout = std::time::Duration::from_secs(seconds);
                    }
                    flag if flag.starts_with('-') => {
                        return Err(usage(&format!("unknown option {flag}")));
                    }
                    _ if dir.is_some() => return Err(usage("ext dev takes one DIR")),
                    _ => dir = Some(PathBuf::from(word)),
                }
            }
            if let Some(dir) = dir {
                options.dir = dir;
            }
            Ok(Request::Dev(options))
        }
        "shot" => {
            // One `ext dev --once` reload with no install card, plus where the picture goes.
            let mut out = None;
            let mut dev = vec!["dev".to_string(), "--once".into(), "--no-install".into()];
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--out" => match words.next() {
                        // `-` is the PNG inline in a reply; ext shot names a file.
                        Some(path) if path != "-" => out = Some(PathBuf::from(path)),
                        _ => return Err(usage("--out needs a file path")),
                    },
                    "--once" | "--keep" | "--remove-on-exit" | "--no-install" => {
                        return Err(usage(&format!(
                            "{word}: ext shot reloads once and installs nothing"
                        )));
                    }
                    "--build" | "--build-timeout" => {
                        dev.push(word.clone());
                        dev.extend(words.next().cloned());
                    }
                    _ => dev.push(word.clone()),
                }
            }
            match parse(&dev)? {
                Request::Dev(dev) => Ok(Request::Shot(shot::ShotOptions { dev, out })),
                _ => Err(usage("ext shot")),
            }
        }
        "list" if rest.is_empty() => Ok(Request::List),
        "capabilities" => match rest {
            [] => Ok(Request::Capabilities { op: None }),
            [flag, op] if flag == "--op" && !op.starts_with('-') => {
                Ok(Request::Capabilities { op: Some(op.clone()) })
            }
            _ => Err(usage("ext capabilities takes --op NAME and --json")),
        },
        "remove" => match rest {
            [app] if app.strip_prefix("local/").is_some_and(scaffold::valid_name) => {
                Ok(Request::Remove { app: app.clone() })
            }
            [app] if app.starts_with("local/") => Err(usage(&format!(
                "{app}: an extension id is local/NAME, NAME lowercase letters, digits and '-'"
            ))),
            [app] => Err(usage(&format!(
                "{app}: ext remove drops an extension `ext dev` loaded (local/NAME); other apps: cmux apps remove"
            ))),
            _ => Err(usage("ext remove needs one ID")),
        },
        other => Err(usage(&format!("unknown ext verb {other}"))),
    }
}

/// `cmux [global options] ext ...` when `args` names it.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, words) = super::parse_globals(args).ok()?;
    let rest = words.split_first().filter(|(verb, _)| *verb == "ext").map(|(_, rest)| rest)?;
    // `--json` after the verb, as `cmux apps list --json`.
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
    let json_out = matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let request = match parse(&rest) {
        Ok(request) => request,
        Err(message) => {
            eprintln!("{message}");
            return Some(exit::USAGE);
        }
    };
    // The global words, for the `apps install` child `ext dev` may start.
    let globals = args
        .iter()
        .position(|w| w == "ext")
        .and_then(|at| args.get(..at))
        .map(<[_]>::to_vec)
        .unwrap_or_default();
    Some(run(&global, request, json_out, globals))
}

fn absolute(dir: PathBuf) -> PathBuf {
    let dir = if dir.is_absolute() {
        dir
    } else {
        std::env::current_dir().map(|cwd| cwd.join(&dir)).unwrap_or(dir)
    };
    dir.canonicalize().unwrap_or(dir)
}

fn run(global: &GlobalArgs, request: Request, json_out: bool, globals: Vec<String>) -> i32 {
    match request {
        Request::Help => {
            println!("{HELP}");
            exit::OK
        }
        Request::New { name, kind, dir } => {
            let dir = absolute(dir.unwrap_or_else(|| PathBuf::from(&name)));
            match scaffold::scaffold(&dir, &name, &kind) {
                Ok(files) => {
                    if json_out {
                        println!(
                            "{}",
                            json!({ "app": format!("local/{name}"), "dir": dir, "files": files })
                        );
                    } else {
                        println!("made local/{name} in {}", dir.display());
                        println!("next: cd {} && cmux ext dev", dir.display());
                    }
                    exit::OK
                }
                Err(message) => {
                    eprintln!("cmux: {message}");
                    1
                }
            }
        }
        Request::Dev(mut options) => {
            options.dir = absolute(options.dir);
            options.bun = dev::find_bun();
            if !options.dir.is_dir() {
                eprintln!("cmux: {} is not a folder", options.dir.display());
                return exit::USAGE;
            }
            if options.once {
                dev::run_once(global, &options, json_out)
            } else {
                dev::run_watch(global, &options, globals)
            }
        }
        Request::Shot(mut options) => {
            options.dev.dir = absolute(options.dev.dir);
            options.dev.bun = dev::find_bun();
            if !options.dev.dir.is_dir() {
                eprintln!("cmux: {} is not a folder", options.dev.dir.display());
                return exit::USAGE;
            }
            // `window screenshot` makes a relative --out absolute itself; the child runs here too.
            options.out = options.out.map(|out| {
                if out.is_absolute() {
                    out
                } else {
                    std::env::current_dir().map(|cwd| cwd.join(&out)).unwrap_or(out)
                }
            });
            shot::run(global, &options, &globals, json_out)
        }
        Request::List | Request::Remove { .. } => list_or_remove(global, request, json_out),
        Request::Capabilities { op } => capabilities(global, op.as_deref(), json_out),
    }
}

/// `ext capabilities`: the running daemon's capability manifest
/// (`apps-capabilities`), so the answer is the API that cmux serves.
fn capabilities(global: &GlobalArgs, op: Option<&str>, json_out: bool) -> i32 {
    let (sender, wakes) = channel();
    let mut daemon = match daemon::Daemon::connect(global, sender, wakes) {
        Ok(daemon) => daemon,
        Err(message) => {
            eprintln!("cmux: {message}");
            return exit::NO_DAEMON;
        }
    };
    let request = match op {
        Some(op) => json!({ "cmd": "apps-capabilities", "op": op }),
        None => json!({ "cmd": "apps-capabilities" }),
    };
    let data = match daemon.call(request) {
        Ok(Ok(data)) => data,
        Ok(Err(message)) => {
            eprintln!("cmux: {message}");
            return 1;
        }
        Err(_) => {
            eprintln!("cmux: the cmux daemon did not answer");
            return exit::NO_DAEMON;
        }
    };
    if data.field("ops").as_array().is_none() {
        eprintln!(
            "cmux: the running daemon has no capability manifest (it is older than cmux ext capabilities); restart it with this cmux: {}",
            super::fix_command::restart_routed_daemon()
        );
        return 1;
    }
    if json_out {
        println!("{data}");
    } else {
        print!("{}", capabilities_table(&data));
    }
    exit::OK
}

/// The text form: one line per op (op, scope, class, risk, gesture or
/// escalation), then the never list's size and the API version.
pub(super) fn capabilities_table(data: &Value) -> String {
    let rows: Vec<[String; 4]> = data
        .field("ops")
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| {
            let text = |key: &str| row.field(key).as_str().unwrap_or("-").to_string();
            if row.field("never").as_bool() == Some(true) {
                return [text("op"), "never".into(), "-".into(), text("consent")];
            }
            let mut notes = Vec::new();
            if row.field("gesture").as_bool() == Some(true) {
                notes.push("needs a user gesture".to_string());
            }
            if let Some(scope) = row.field("escalation").field("scope").as_str() {
                notes.push(format!("with a command: {scope}"));
            }
            if row.field("external").as_bool() == Some(true) {
                notes.push("refused when sandboxed".to_string());
            }
            let risk = row.field("risk").as_str().unwrap_or("no grant");
            [text("op"), text("scope"), format!("{} {risk}", text("class")), notes.join("; ")]
        })
        .collect();
    const HEADERS: [&str; 4] = ["OP", "SCOPE", "CLASS RISK", "NOTES"];
    let mut widths = HEADERS.map(str::len);
    for row in &rows {
        for (width, cell) in widths.iter_mut().zip(row) {
            *width = (*width).max(cell.chars().count());
        }
    }
    let mut out = String::new();
    let mut line = |cells: [&str; 4]| {
        let text = format!(
            "{:w0$}  {:w1$}  {:w2$}  {}",
            cells[0],
            cells[1],
            cells[2],
            cells[3],
            w0 = widths[0],
            w1 = widths[1],
            w2 = widths[2]
        );
        out.push_str(text.trim_end());
        out.push('\n');
    };
    line(HEADERS);
    for row in &rows {
        line([&row[0], &row[1], &row[2], &row[3]]);
    }
    if let Some(never) = data.field("never").as_array() {
        out.push_str(&format!(
            "{} ops no app may call (cmux ext capabilities --op NAME says why one is refused)\n",
            never.len()
        ));
    }
    if let Some(version) = data.field("apiVersion").as_str() {
        out.push_str(&format!("cmux app API {version}\n"));
    }
    out
}

/// `ext list` (the `local/` apps the daemon loads) and `ext remove ID` (drops
/// the folder `ext dev` made for it; the daemon's reload removes the app).
fn list_or_remove(global: &GlobalArgs, request: Request, json_out: bool) -> i32 {
    let (sender, wakes) = channel();
    let mut daemon = match daemon::Daemon::connect(global, sender, wakes) {
        Ok(daemon) => daemon,
        Err(message) => {
            eprintln!("cmux: {message}");
            return exit::NO_DAEMON;
        }
    };
    let data = match daemon.call(json!({ "cmd": "apps-list" })) {
        Ok(Ok(data)) => data,
        Ok(Err(message)) => {
            eprintln!("cmux: {message}");
            return 1;
        }
        Err(_) => {
            eprintln!("cmux: the cmux daemon did not answer");
            return exit::NO_DAEMON;
        }
    };
    match request {
        Request::Remove { app } => {
            let Some(local_dir) = data.field("local_dir").as_str() else {
                eprintln!(
                    "cmux: the running daemon does not say where it loads local apps from; restart it with this cmux: {}",
                    super::fix_command::restart_routed_daemon()
                );
                return 1;
            };
            // `parse` checked the id: `local/` once, then a plain folder name.
            let name = app.strip_prefix("local/").unwrap_or(&app);
            let folder = PathBuf::from(local_dir).join(name);
            match dev::remove_made_folder(&folder) {
                Ok(true) => {
                    println!("removed {app} (its copy in {} is deleted)", folder.display());
                    exit::OK
                }
                Ok(false) => {
                    eprintln!(
                        "cmux: cmux ext dev did not load {app}; other apps: cmux apps remove {app}"
                    );
                    1
                }
                Err(message) => {
                    eprintln!("cmux: {message}");
                    1
                }
            }
        }
        _ => {
            let rows = dev::list_rows(&data);
            if json_out {
                println!("{}", json!({ "extensions": rows }));
            } else if rows.is_empty() {
                println!("no local extensions (cmux ext new NAME makes one)");
            } else {
                print!("{}", dev::list_table(&rows));
            }
            exit::OK
        }
    }
}
