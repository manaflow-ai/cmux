//! `cmux ext`: the extension author's CLI (docs/cmux-next/extensions/dev-loop.md).
//!
//! An extension is an app on the app platform; `ext` is the author-facing
//! noun and `cmux apps ...` keeps working unchanged. `ext new` scaffolds a
//! folder, `ext dev` loads it into the running cmux and reloads it on every
//! save (`dev.rs`), `ext shot` shows what it rendered (`shot.rs`), `ext list`
//! and `ext remove` show and drop the folders `ext dev` loaded. `ext publish`
//! checks a folder is ready to list on cmux.com from its git repository
//! (`publish.rs`). `ext remix` copies a published extension into a new folder
//! to change (`remix.rs`). `ext share` prints the link that adds a pushed folder
//! (`share.rs`), and publishes a folder with no `origin` yet to a new GitHub
//! repository (`share_repo.rs`).

mod daemon;
mod design;
mod design_system;
mod dev;
#[cfg(test)]
mod kinds_tests;
mod pack;
mod publish;
#[cfg(test)]
mod publish_tests;
#[cfg(test)]
mod recipes_tests;
mod remix;
#[cfg(test)]
mod remix_tests;
mod scaffold;
mod scene;
mod scene_type;
mod share;
mod share_repo;
mod shot;
mod source;
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
    /// `ext share`: GitHub is not connected; the folder is kept.
    pub const NOT_CONNECTED: i32 = 7;
    /// `ext shot --record`: the scenes could not be written to `preview/scenes.json`.
    pub const RECORD_FAILED: i32 = 9;
    /// `ext add`: the source could not be fetched; `ext search`: GitHub did not answer.
    pub const FETCH_FAILED: i32 = 7;
    /// `ext share`: the folder cannot be shared yet.
    pub const NOT_SHAREABLE: i32 = 8;
    pub const INTERRUPTED: i32 = 130;
}

const HELP: &str = "\
cmux ext: make a cmux extension and watch it change as you work.
  cmux ext new NAME [--kind K] a working extension folder ./NAME on the SDK this cmux ships;
                               K: sidebar (default, a sidebar section), session-info (a section
                               in an agent chat's Session Info), pane (a view in a tab),
                               newtab (a view over the New Tab composer, picked in tabs.newTabApp),
                               widget (a New Tab and sidebar widget, small/medium/large),
                               command (a palette command, `cmux NAME ...` and an agent tool);
                               --repo OWNER/REPO (else the folder's github.com origin) makes the
                               id OWNER/NAME, sets repository and fills the README's badge
  cmux ext publish [DIR] [--repo OWNER/REPO] [--write-badge] [--json]
                               whether DIR is ready to list (manifest, id, README badge,
                               repository, a picture) and the steps: push, a release, the
                               registry PR; writes nothing to the network; exit 1 when
                               something is left to do
  cmux ext pack [DIR] [--out DIR] [--json]
                               the release assets: cmux-extension.tar.gz (the manifest and the
                               files it names) and cmux-app.v2.json in DIR/release; prints the sha256
  cmux ext dev [DIR]           load DIR into cmux, then reload it on every save (Ctrl-C stops)
  cmux ext dev --once --json   one validate + build + reload; exit 0 ok, 1 load, 3 no cmux, 4 manifest, 5 build
  cmux ext shot [DIR] [--out PNG] [--record] [--json]
                               one reload, then what it rendered: the view's outline, its design
                               warnings and a picture of the cmux window that shows it; exit 6
                               no picture. --record writes the scene (a widget: each declared size)
                               into DIR/preview/scenes.json; exit 9 when it cannot
  cmux ext add SOURCE [--no-install]
                               add someone's extension: a git URL, OWNER/NAME[@REF], a GitHub
                               /tree/REF/PATH link, URL#PATH, or a folder; again to update it
  cmux ext share [DIR]         the link that adds yours (checks it is pushed and built); a
                               folder with no origin yet is published first (below)
  cmux ext search [WORDS]      extensions people tagged cmux-extension on GitHub
  cmux ext reload [NAME]       read the extension folders again now and rerun NAME (local/NAME,
                               or every extension in a local folder): a save the watch missed
                               shows, and a script that does not load names file:line while the
                               last good view stays; exit 1 when one did not load
  cmux reload-config           cmux-next.json, the Ghostty config and every local extension, at once
  cmux ext design FILE... [--widget] [--system cmux-design.json] [--json]
                               the design check ext dev runs, on recorded scenes (a JSON array
                               of scene ops, or an object of them by name), against cmux's design
                               system or yours (ext dev reads DIR/cmux-design.json); exit 1 on a warning
  cmux ext design --listing DIR [--json]
                               registry review's design check: the folder's recorded scenes
                               (preview/scenes.json, which its files must ship) against its own
                               system; exit 1 when a scene warns or none is recorded
  cmux ext list | remove ID    the extensions loaded this way; remove drops one
  cmux ext remix HOST/OWNER/REPO[/PATH][@COMMIT] [--dir D] [--name N]
                               fork and customize: that extension's source at the commit in a
                               new folder (~/Projects/NAME) as local/NAME with its own git
                               repository, and the steps to change and publish it
  cmux ext share [DIR] [--name REPO] [--private]
                               no origin yet, or --name/--private: publish DIR to a new
                               GitHub repository of yours (your gh login):
                               the manifest and README badge made yours, topic cmux-extension,
                               and its cmux.com page; exit 7 when GitHub is not connected
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
    /// Render a widget at every size it declares (`ext shot --record`; `ext dev` renders one).
    pub every_size: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    Help,
    New {
        name: String,
        kind: String,
        dir: Option<PathBuf>,
        /// `--repo OWNER/REPO`: the GitHub repository it is published from.
        repo: Option<publish::Repo>,
    },
    Dev(DevOptions),
    Shot(shot::ShotOptions),
    Add(share::AddOptions),
    Search {
        query: Option<String>,
    },
    List,
    Remove {
        app: String,
    },
    /// `ext reload [NAME]`: `apps-reload` for one app, or every local one.
    Reload {
        app: Option<String>,
    },
    /// The running cmux's capability manifest, or one op's row.
    Capabilities {
        op: Option<String>,
    },
    /// `ext remix REF`: fork and customize.
    Remix(remix::RemixOptions),
    /// `ext share [DIR]`: the link that adds a pushed folder, or, for a folder with no `origin`
    /// (or with `--name` / `--private`), publish it to a new GitHub repository.
    Share {
        dir: PathBuf,
        name: Option<String>,
        private: bool,
    },
    /// `ext publish [DIR]`: is the folder ready to list, and the steps.
    Publish(publish::PublishOptions),
    /// `ext pack [DIR]`: the release assets.
    Pack(pack::PackOptions),
    /// `ext design FILE... [--widget]`: the design check on recorded scenes.
    Design {
        files: Vec<PathBuf>,
        widget: bool,
        /// `--system FILE`: a `cmux-design.json` to check against instead of cmux's system.
        system: Option<PathBuf>,
    },
    /// `ext design --listing DIR`: registry review's design check of a folder.
    DesignListing {
        dir: PathBuf,
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
            let mut repo = None;
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
                    "--repo" => {
                        let text = words.next().ok_or_else(|| usage("--repo needs OWNER/REPO"))?;
                        repo = Some(publish::Repo::parse(text).ok_or_else(|| {
                            usage(&format!(
                                "--repo {text}: give the GitHub repository as OWNER/REPO"
                            ))
                        })?);
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
            if let Some(problem) = scaffold::pending(&kind) {
                return Err(usage(&problem));
            }
            if !scaffold::KINDS.contains(&kind.as_str()) {
                return Err(usage(&format!(
                    "--kind {kind}: one of {}",
                    scaffold::KINDS.join(", ")
                )));
            }
            Ok(Request::New { name, kind, dir, repo })
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
                every_size: false,
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
        "add" => {
            let mut source = None;
            let mut install = true;
            for word in rest {
                match word.as_str() {
                    "--no-install" => install = false,
                    flag if flag.starts_with('-') => {
                        return Err(usage(&format!("unknown option {flag}")));
                    }
                    _ if source.is_some() => return Err(usage("ext add takes one SOURCE")),
                    _ => source = Some(word.clone()),
                }
            }
            let source = source.ok_or_else(|| usage("ext add needs a SOURCE"))?;
            Ok(Request::Add(share::AddOptions { source, install }))
        }
        "search" => {
            if let Some(flag) = rest.iter().find(|word| word.starts_with('-')) {
                return Err(usage(&format!("unknown option {flag}")));
            }
            let query = (!rest.is_empty()).then(|| rest.join(" "));
            Ok(Request::Search { query })
        }
        "shot" => {
            // One `ext dev --once` reload with no install card, plus where the picture goes.
            let mut out = None;
            let mut record = false;
            let mut dev = vec!["dev".to_string(), "--once".into(), "--no-install".into()];
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--out" => match words.next() {
                        // `-` is the PNG inline in a reply; ext shot names a file.
                        Some(path) if path != "-" => out = Some(PathBuf::from(path)),
                        _ => return Err(usage("--out needs a file path")),
                    },
                    "--record" => record = true,
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
                Request::Dev(mut dev) => {
                    dev.every_size = record;
                    Ok(Request::Shot(shot::ShotOptions { dev, out, record }))
                }
                _ => Err(usage("ext shot")),
            }
        }
        "design" => {
            let mut files = Vec::new();
            let mut widget = false;
            let mut system = None;
            let mut listing = None;
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--widget" => widget = true,
                    "--listing" => {
                        listing = Some(PathBuf::from(
                            words.next().ok_or_else(|| usage("--listing needs a folder"))?,
                        ));
                    }
                    "--system" => {
                        system = Some(PathBuf::from(
                            words
                                .next()
                                .ok_or_else(|| usage("--system needs a cmux-design.json"))?,
                        ));
                    }
                    flag if flag.starts_with('-') => {
                        return Err(usage(&format!("unknown option {flag}")));
                    }
                    _ => files.push(PathBuf::from(word)),
                }
            }
            if let Some(dir) = listing {
                if !files.is_empty() || widget || system.is_some() {
                    return Err(usage(
                        "ext design --listing DIR takes no FILE, --widget or --system: the folder's manifest and cmux-design.json say them",
                    ));
                }
                return Ok(Request::DesignListing { dir });
            }
            if files.is_empty() {
                return Err(usage("ext design needs a scene FILE"));
            }
            Ok(Request::Design { files, widget, system })
        }
        "pack" => {
            let mut options = pack::PackOptions { dir: PathBuf::from("."), out: None };
            let mut dir = None;
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--out" => {
                        let out = words.next().ok_or_else(|| usage("--out needs a folder"))?;
                        options.out = Some(PathBuf::from(out));
                    }
                    flag if flag.starts_with('-') => {
                        return Err(usage(&format!("unknown option {flag}")));
                    }
                    _ if dir.is_some() => return Err(usage("ext pack takes one DIR")),
                    _ => dir = Some(PathBuf::from(word)),
                }
            }
            if let Some(dir) = dir {
                options.dir = dir;
            }
            Ok(Request::Pack(options))
        }
        "publish" => {
            let mut options =
                publish::PublishOptions { dir: PathBuf::from("."), repo: None, write_badge: false };
            let mut dir = None;
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--repo" => {
                        let text = words.next().ok_or_else(|| usage("--repo needs OWNER/REPO"))?;
                        if publish::Repo::parse(text).is_none() {
                            return Err(usage(&format!(
                                "--repo {text}: give the GitHub repository as OWNER/REPO"
                            )));
                        }
                        options.repo = Some(text.clone());
                    }
                    "--write-badge" => options.write_badge = true,
                    flag if flag.starts_with('-') => {
                        return Err(usage(&format!("unknown option {flag}")));
                    }
                    _ if dir.is_some() => return Err(usage("ext publish takes one DIR")),
                    _ => dir = Some(PathBuf::from(word)),
                }
            }
            if let Some(dir) = dir {
                options.dir = dir;
            }
            Ok(Request::Publish(options))
        }
        "list" if rest.is_empty() => Ok(Request::List),
        "reload" => match rest {
            [] => Ok(Request::Reload { app: None }),
            [name] if !name.starts_with('-') => match reload_target(name) {
                Some(app) => Ok(Request::Reload { app: Some(app) }),
                None => Err(usage(&format!("ext reload: {name} is not an extension name"))),
            },
            _ => Err(usage("ext reload takes at most one NAME")),
        },
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
        "remix" => {
            let (mut source, mut dir, mut name) = (None, None, None);
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--dir" => {
                        dir = Some(PathBuf::from(
                            words.next().ok_or_else(|| usage("--dir needs a path"))?,
                        ));
                    }
                    "--name" => {
                        name =
                            Some(words.next().ok_or_else(|| usage("--name needs a name"))?.clone());
                    }
                    flag if flag.starts_with('-') => {
                        return Err(usage(&format!("unknown option {flag}")));
                    }
                    _ if source.is_some() => return Err(usage("ext remix takes one source")),
                    _ => source = Some(word.clone()),
                }
            }
            let source = source.ok_or_else(|| {
                usage("ext remix needs a source: HOST/OWNER/REPO[/PATH][@COMMIT]")
            })?;
            if remix::SourceRef::parse(&source).is_none() {
                return Err(usage(&format!(
                    "{source}: give the source as HOST/OWNER/REPO[/PATH][@COMMIT]"
                )));
            }
            Ok(Request::Remix(remix::RemixOptions { source, dir, name }))
        }
        "share" => {
            let (mut dir, mut name, mut private) = (None, None, false);
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--private" => private = true,
                    "--public" => private = false,
                    "--name" => {
                        name =
                            Some(words.next().ok_or_else(|| usage("--name needs a name"))?.clone());
                    }
                    flag if flag.starts_with('-') => {
                        return Err(usage(&format!("unknown option {flag}")));
                    }
                    _ if dir.is_some() => return Err(usage("ext share takes one DIR")),
                    _ => dir = Some(PathBuf::from(word)),
                }
            }
            Ok(Request::Share { dir: dir.unwrap_or_else(|| PathBuf::from(".")), name, private })
        }
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
        Request::New { name, kind, dir, repo } => {
            let dir = absolute(dir.unwrap_or_else(|| PathBuf::from(&name)));
            // A clone of the extension's own repository names it.
            let repo = repo.or_else(|| publish::origin_repo(&dir));
            match scaffold::scaffold_for(&dir, &name, &kind, repo.as_ref()) {
                Ok(files) => {
                    let git = publish::git_init(&dir);
                    let app = scaffold::app_id(&name, repo.as_ref());
                    if json_out {
                        println!(
                            "{}",
                            json!({
                                "app": app,
                                "dir": dir,
                                "files": files,
                                "repository": repo.as_ref().map(publish::Repo::url),
                                "gitInit": git == Some(true),
                                // Publishing to a new GitHub repository of the person's is the
                                // last step, on by default (`ext share`).
                                "publish": format!("cmux ext share {}", dir.display()),
                            })
                        );
                    } else {
                        println!("made {app} in {}", dir.display());
                        if git == Some(true) {
                            println!("made it a git repository (branch main)");
                        }
                        println!("next: cd {} && cmux ext dev", dir.display());
                        match &repo {
                            Some(repo) => println!(
                                "share: push it to {}, then cmux ext publish says what is left",
                                repo.url()
                            ),
                            None => println!(
                                "share: cmux ext publish --repo OWNER/REPO --write-badge, once it has a GitHub repository"
                            ),
                        }
                        // The last step, on by default: a new GitHub repository of the person's.
                        println!(
                            "when it works, publish it: cmux ext share {} makes a new GitHub repository of yours and prints its cmux.com page",
                            dir.display()
                        );
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
        Request::Add(options) => share::run_add(global, &options, &globals, json_out),
        Request::Search { query } => share::run_search(query.as_deref(), json_out),
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
        Request::Reload { app } => reload(global, app.as_deref(), json_out),
        Request::Capabilities { op } => capabilities(global, op.as_deref(), json_out),
        Request::Remix(mut options) => {
            options.dir = options.dir.map(absolute_new);
            let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("."), PathBuf::from);
            match remix::remix(&options, &home, None) {
                Ok(made) => {
                    if json_out {
                        println!("{}", made.to_json());
                    } else {
                        print!("{}", made.brief());
                    }
                    exit::OK
                }
                Err(message) => {
                    eprintln!("cmux: {message}");
                    1
                }
            }
        }
        Request::Share { dir, name, private } => {
            let dir = absolute(dir);
            // A folder already on a remote gets its link; a new one (no `origin`), or one asked
            // for a new repository by `--name` / `--private`, is published first.
            if name.is_none() && !private && share_repo::has_origin(&dir) {
                return share::run_share(&dir, json_out);
            }
            // The person's own `gh` login; `CMUX_EXT_GH` names another program (tests).
            let gh =
                std::env::var_os("CMUX_EXT_GH").map_or_else(|| PathBuf::from("gh"), PathBuf::from);
            match share_repo::share(&share_repo::ShareOptions {
                dir: dir.clone(),
                name,
                private,
                gh,
            }) {
                Ok(shared) => {
                    if json_out {
                        println!("{}", shared.to_json(&dir));
                    } else {
                        print!("{}", shared.text(&dir));
                    }
                    match shared {
                        share_repo::Shared::Published { .. } => exit::OK,
                        share_repo::Shared::NotConnected { .. } => exit::NOT_CONNECTED,
                    }
                }
                Err(message) => {
                    eprintln!("cmux: {message}");
                    1
                }
            }
        }
        Request::Design { files, widget, system } => {
            let surface = if widget { design::Surface::Widget } else { design::Surface::Other };
            let system = match system {
                None => design_system::System::cmux(),
                Some(path) => match std::fs::read_to_string(&path)
                    .map_err(|e| e.to_string())
                    .and_then(|text| serde_json::from_str(&text).map_err(|e| e.to_string()))
                    .and_then(|value| design_system::System::from_json(&value))
                {
                    Ok(system) => system,
                    Err(problem) => {
                        eprintln!("cmux: {}: {problem}", path.display());
                        return exit::MANIFEST_INVALID;
                    }
                },
            };
            design::run(&files, surface, &system, json_out)
        }
        Request::DesignListing { dir } => design::run_listing(&absolute(dir), json_out),
        Request::Pack(mut options) => {
            options.dir = absolute(options.dir);
            options.out = options.out.map(absolute);
            match pack::pack(&options) {
                Ok(packed) => {
                    if json_out {
                        println!("{}", packed.to_json());
                    } else {
                        print!("{}", packed.text());
                    }
                    exit::OK
                }
                Err(message) => {
                    eprintln!("cmux: {message}");
                    exit::MANIFEST_INVALID
                }
            }
        }
        Request::Publish(mut options) => {
            options.dir = absolute(options.dir);
            match publish::check(&options) {
                Ok(report) => {
                    if json_out {
                        println!("{}", report.to_json());
                    } else {
                        print!("{}", report.text());
                    }
                    if report.ready() { exit::OK } else { 1 }
                }
                Err(message) => {
                    eprintln!("cmux: {message}");
                    exit::USAGE
                }
            }
        }
    }
}

/// `dir` made absolute against the working folder (it need not exist yet).
fn absolute_new(dir: PathBuf) -> PathBuf {
    if dir.is_absolute() {
        dir
    } else {
        std::env::current_dir().map(|cwd| cwd.join(&dir)).unwrap_or(dir)
    }
}

/// The app id `ext reload NAME` asks for: `NAME` is `local/NAME`, and an
/// id with its publisher (`local/x`, `acme/x` from `CMUX_APPS_DIRS`) is
/// itself. `None` for a word that names no app.
pub(super) fn reload_target(name: &str) -> Option<String> {
    let ok = |part: &str| {
        !part.is_empty()
            && part.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    };
    match name.split_once('/') {
        Some((publisher, app)) if ok(publisher) && ok(app) => Some(name.to_string()),
        None if ok(name) => Some(format!("local/{name}")),
        _ => None,
    }
}

/// `ext reload [NAME]`: one `apps-reload`, then a line per app. Exit 1 when
/// a script did not load (the last good view stays), 3 with no daemon.
fn reload(global: &GlobalArgs, app: Option<&str>, json_out: bool) -> i32 {
    match reload_call(global, app) {
        Ok(data) => {
            if json_out {
                println!("{data}");
            } else {
                print!("{}", reload_text(&data));
            }
            reload_exit(&data)
        }
        Err((code, message)) => {
            eprintln!("cmux: {message}");
            code
        }
    }
}

/// How long a `customize` verb waits for the daemon to load the folder it
/// rewrote. Past it the verb returns anyway: the daemon's watch still loads it.
const CUSTOMIZE_LOAD_DEADLINE: std::time::Duration = std::time::Duration::from_secs(10);

/// How the daemon took a customization folder a `customize` verb rewrote.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum FolderLoad {
    /// It read the folder: the views in it are what cmux shows now.
    Loaded,
    /// It refused the folder, with why (its views stay as they were).
    Refused(String),
    /// No daemon runs, it is in safe mode, it is older than
    /// `apps-reload-local` or it did not answer in time: its watch loads the
    /// folder when it can, as before.
    NotAsked,
}

/// Asks the daemon to load the customization folder now and waits for its
/// answer (`apps-reload-local`, the pass its folder watch runs): a
/// `customize use` returns with the look's views (its New Tab page, its
/// sidebar section) loaded, instead of seconds before the watch's late event
/// on a loaded Mac, when a New Tab page opened at once found no app to show
/// and showed cmux's own page for its whole life. Best effort: the verb
/// is a file change and works with no daemon.
pub(super) fn load_customize_folder(global: &GlobalArgs, folder: &std::path::Path) -> FolderLoad {
    let (sender, wakes) = channel();
    let Ok(mut daemon) = daemon::Daemon::connect(global, sender, wakes) else {
        return FolderLoad::NotAsked;
    };
    let folder = folder.display().to_string();
    let Ok(asked) = daemon.send(json!({ "cmd": "apps-reload-local", "folders": [&folder] })) else {
        return FolderLoad::NotAsked;
    };
    let answer = daemon.wait(std::time::Instant::now() + CUSTOMIZE_LOAD_DEADLINE, |value| {
        (value.get("id").and_then(Value::as_str) == Some(asked.as_str()))
            .then(|| daemon::answer(value))
    });
    // An older daemon refuses the request it cannot parse: its watch loads the folder.
    let Ok(Ok(data)) = answer else { return FolderLoad::NotAsked };
    if data.field("safeMode").as_bool() == Some(true) {
        return FolderLoad::NotAsked;
    }
    let refused = data.field("rejected").as_array().into_iter().flatten().find_map(|rejected| {
        (rejected.field("dir").as_str() == Some(folder.as_str()))
            .then(|| rejected.field("issue").as_str().unwrap_or("refused").to_owned())
    });
    refused.map_or(FolderLoad::Loaded, FolderLoad::Refused)
}

/// One daemon request on the session socket `global` names: the answer's data, or the daemon's
/// refusal as `code: message`; `Err` when there is no daemon or it did not answer.
pub(in crate::cli) fn daemon_call(
    global: &GlobalArgs,
    request: Value,
) -> Result<Result<Value, String>, String> {
    let (sender, wakes) = channel();
    let mut daemon = daemon::Daemon::connect(global, sender, wakes)?;
    daemon.call(request).map_err(|_| "the cmux daemon did not answer".to_string())
}

/// The daemon's `apps-reload` answer, or an exit code and message.
fn reload_call(global: &GlobalArgs, app: Option<&str>) -> Result<Value, (i32, String)> {
    let (sender, wakes) = channel();
    let mut daemon = daemon::Daemon::connect(global, sender, wakes)
        .map_err(|message| (exit::NO_DAEMON, message))?;
    let mut request = json!({ "cmd": "apps-reload" });
    if let Some(app) = app {
        request["app"] = json!(app);
    }
    let older = || {
        (
            1,
            format!(
                "the running daemon cannot reload extensions on request (it is older than cmux ext reload); restart it with this cmux: {}",
                super::fix_command::restart_routed_daemon()
            ),
        )
    };
    let data = match daemon.call(request) {
        Ok(Ok(data)) => data,
        // A daemon from before `apps-reload` refuses the request it cannot parse.
        Ok(Err(message)) if message.contains("unknown variant `apps-reload`") => {
            return Err(older());
        }
        Ok(Err(message)) => return Err((1, message)),
        Err(_) => return Err((exit::NO_DAEMON, "the cmux daemon did not answer".to_string())),
    };
    if data.field("reloaded").as_array().is_none() {
        return Err(older());
    }
    Ok(data)
}

/// 0 when every asked script loaded, else 1.
pub(super) fn reload_exit(data: &Value) -> i32 {
    if data.field("refused").as_array().is_some_and(|refused| !refused.is_empty()) {
        exit::LOAD_FAILED
    } else {
        exit::OK
    }
}

/// `reloaded local/x`, `local/y did not load (the last good version stays): REASON`,
/// `removed local/z`; `no extensions in a local folder` when there was none.
pub(super) fn reload_text(data: &Value) -> String {
    let list =
        |key: &str| -> Vec<Value> { data.field(key).as_array().cloned().unwrap_or_default() };
    let mut out = String::new();
    for app in list("reloaded") {
        out.push_str(&format!("reloaded {}\n", app.as_str().unwrap_or("?")));
    }
    for row in list("refused") {
        let reason = row.field("reason").as_str().unwrap_or("");
        let reason = reason.strip_prefix("init: ").unwrap_or(reason);
        out.push_str(&format!(
            "{} did not load (the last good version stays):\n  {reason}\n",
            row.field("app").as_str().unwrap_or("?")
        ));
    }
    for app in list("removed") {
        out.push_str(&format!("removed {} (its folder is gone)\n", app.as_str().unwrap_or("?")));
    }
    if out.is_empty() {
        out.push_str("no extensions in a local folder (cmux ext new NAME makes one)\n");
    }
    out
}

/// `cmux [global options] reload-config [--json]`: one reload
/// for cmux. The app reads `cmux-next.json` and the Ghostty config again
/// (its Reload Configuration action), and the daemon reruns every local
/// extension (`apps-reload`). Either half runs when the other cannot: with
/// no app, the extensions still reload; the exit names the worse half.
pub(super) fn run_reload_config_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, words) = super::parse_globals(args).ok()?;
    let (verb, rest) = words.split_first()?;
    if verb != "reload-config" {
        return None;
    }
    let mut extra = Vec::new();
    for word in rest {
        match word.as_str() {
            "--json" => global.output = OutputMode::Json,
            "-h" | "--help" => {
                println!(
                    "usage: cmux reload-config [--json]\n\n  Reads cmux-next.json and the Ghostty config again, and reruns every extension in a\n  local folder (cmux ext reload). A file that does not parse, or a script that does not\n  load, keeps the last good version and is named with its file and line."
                );
                return Some(exit::OK);
            }
            other => extra.push(other.to_string()),
        }
    }
    if !extra.is_empty() {
        eprintln!("cmux: reload-config takes no arguments (got {})", extra.join(" "));
        return Some(exit::USAGE);
    }
    let json_out = matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let settings = reload_settings(&global);
    let extensions = reload_call(&global, None);
    let code = match (&settings, &extensions) {
        (_, Ok(data)) if reload_exit(data) != exit::OK => exit::LOAD_FAILED,
        (Err(_), Err((code, _))) => *code,
        (Err(_), Ok(_)) | (Ok(()), Err(_)) => 1,
        (Ok(()), Ok(_)) => exit::OK,
    };
    if json_out {
        let half = |ok: bool, error: Option<String>| match error {
            None if ok => json!({ "ok": true }),
            error => json!({ "ok": false, "error": error }),
        };
        println!(
            "{}",
            json!({
                "settings": half(settings.is_ok(), settings.as_ref().err().cloned()),
                "extensions": match &extensions {
                    Ok(data) => data.clone(),
                    Err((_, message)) => json!({ "ok": false, "error": message }),
                },
            })
        );
    } else {
        match &settings {
            Ok(()) => println!("reloaded cmux-next.json and the Ghostty config"),
            Err(message) => eprintln!("cmux: settings not reloaded: {message}"),
        }
        match &extensions {
            Ok(data) => print!("{}", reload_text(data)),
            Err((_, message)) => eprintln!("cmux: extensions not reloaded: {message}"),
        }
    }
    Some(code)
}

/// The app's `reloadConfiguration` action (Reload Configuration in the
/// palette and the app menu): settings and the Ghostty config.
fn reload_settings(global: &GlobalArgs) -> Result<(), String> {
    let describe = |error: &Value| {
        error.field("message").as_str().map(str::to_string).unwrap_or_else(|| error.to_string())
    };
    let mut stream = super::app::connect_command(global).map_err(|error| describe(&error))?;
    let mut params = Value::Object(super::app::action_run_params(
        "reloadConfiguration",
        super::app::ActionName::Any,
        super::app::action_origin(),
    ));
    super::app::insert_run_key(&mut params, None)?;
    match super::app::request_with_retry(
        &mut stream,
        "action.run",
        &params,
        std::time::Duration::from_secs(10),
    )? {
        Ok(_) => Ok(()),
        Err(error) => Err(describe(&error)),
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
