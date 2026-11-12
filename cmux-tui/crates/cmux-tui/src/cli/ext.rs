//! `cmux ext`: the extension author's CLI (docs/cmux-next/extensions/dev-loop.md).
//!
//! An extension is an app on the app platform; `ext` is the author-facing
//! noun and `cmux apps ...` keeps working unchanged. `ext new` scaffolds a
//! folder, `ext dev` loads it into the running cmux and reloads it on every
//! save (`dev.rs`), `ext list` and `ext remove` show and drop the folders
//! `ext dev` loaded.

mod daemon;
mod dev;
mod scaffold;
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
    pub const INTERRUPTED: i32 = 130;
}

const HELP: &str = "\
cmux ext: make a cmux extension and watch it change as you work.
  cmux ext new NAME            a working extension folder ./NAME (a sidebar section)
  cmux ext dev [DIR]           load DIR into cmux, then reload it on every save (Ctrl-C stops)
  cmux ext dev --once --json   one validate + build + reload; exit 0 ok, 1 load, 3 no cmux, 4 manifest, 5 build
  cmux ext list | remove ID    the extensions loaded this way; remove drops one

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
    New { name: String, kind: String, dir: Option<PathBuf> },
    Dev(DevOptions),
    List,
    Remove { app: String },
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
        "list" if rest.is_empty() => Ok(Request::List),
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
        Request::List | Request::Remove { .. } => list_or_remove(global, request, json_out),
    }
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
