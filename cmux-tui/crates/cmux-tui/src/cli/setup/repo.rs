//! `cmux setup install|update|remove|export|installed`: a whole cmux
//! customization from a git repo, like dotfiles (cmux-customize `setup`).
//!
//! `install` fetches the repo at one commit (or reads a folder on this
//! machine, `./DIR`, kept as a local install), reads its `cmux-setup.json`,
//! shows one consent card with everything it will change (settings, theme,
//! shortcuts, views, stylesheets, actions and the commands they run, and
//! each extension with its scopes), then applies it through cmux-customize
//! as one generation and one library entry, installs its extensions through
//! the App Store's own `cmux apps install` (which shows cmux's card for each),
//! and keeps a receipt. `remove` undoes it; `update` moves it to the newest
//! commit of the ref it was installed from. Every verb takes `--json`.

use cmux_process::Command;
use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};

use cmux_customize::setup::{
    self, ExportHeader, ExtensionReceipt, Plan, Receipt, Reference, SETUP_FILE, SetupSource, TOPIC,
};
use cmux_customize::{Customize, Error};
use serde_json::{Value, json};

use super::super::{GlobalArgs, OutputMode, wire};

pub(super) const VERBS: &[&str] =
    &["install", "update", "remove", "export", "installed", "check", "on", "off", "order"];

pub(super) const HELP: &str = "\
Setups: a whole cmux customization in one git repo (theme, sidebar, shortcuts, views, actions, extensions).

  cmux setup check DIR [--owner OWNER] [--strict]    Check a setup folder the way install would, offline: every
                                                     problem at once, nothing installed (exit 0 ok, 1 errors, 2 usage;
                                                     --strict: warnings fail too)
  cmux setup install HOST/OWNER/REPO[@REF] [--yes]   Fetch it at one commit, show what it changes, apply it
  cmux setup install ./DIR [--as OWNER/NAME] [--yes] Try a setup folder on this machine before you publish it
  cmux setup update [REPO|ID] [--yes]                Move an installed setup to its ref's newest commit (a folder:
                                                     to what the folder holds now)
  cmux setup remove [REPO|ID|DIR]                    Take off its layer only: its settings, views, actions and extensions
  cmux setup off|on [REPO|ID|DIR]                    Turn its layer off (still installed, in its place) or back on
  cmux setup order ID [ID]...                        Put the setups in this order, top first (a higher one wins a key both set)
  cmux setup installed                               The installed setups, top layer first
  cmux setup export DIR --id OWNER/NAME [--name N] [--description D] [--repo OWNER/REPO] [--extension REF]...
                                                     Write your customization as a setup repo (README with badge)

A setup repo has cmux-setup.json at its root; its page is cmux.com/setups/OWNER/REPO.
Setups stack like dotfiles: each one is a layer of its own, the newest on top. Its views go to
the folder setups/setup-OWNER-NAME beside your customize folder (the app local/setup-OWNER-NAME), never into
your own customize folder, and what you change after installing stays above it. Removing one takes off
only its layer: the other setups and your own changes stay as they are.
--yes skips the question (needed with --json or without a terminal). Every verb takes --json.

A folder (a path starting with ./, ../, / or ~) installs the same way as a repo: the same card, one
generation, one receipt whose source is the folder. It is kept under its id, or under --as OWNER/NAME, which
only a folder takes (so a look that is not published, or names another owner, can be tried); remove it by that
id or folder. One id is installed once: a folder with the id of an installed setup needs --as.

check reads only DIR (no daemon, no network, not your own customization) and runs every check install
runs, plus the theme reader on themes/*.json and the app manifest validator on customize/cmux-app.json.
A key cmux retired is a warning whose fix names the setting that replaced it. With --json it prints
{schema_version, setup_id, ok, findings: [{severity, code, path, key?, line?, message, fix?}]};
severity is error (install refuses it, or cmux leaves that part out) or warning. --owner is the repo's
owner for the id rule (default: the owner `repository` names, else the id's own).
";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    /// `reference` is a repo, or a folder (`./DIR`); `as_id` only with a folder.
    Install {
        reference: String,
        yes: bool,
        as_id: Option<String>,
    },
    Update {
        which: Option<String>,
        yes: bool,
    },
    Remove {
        which: Option<String>,
    },
    Installed,
    On {
        which: Option<String>,
        on: bool,
    },
    Order {
        ids: Vec<String>,
    },
    Export {
        dir: PathBuf,
        header: ExportHeader,
    },
    Check {
        dir: PathBuf,
        owner: Option<String>,
        strict: bool,
    },
}

pub(super) fn parse(args: &[String]) -> Result<Request, String> {
    let (verb, rest) = args.split_first().ok_or_else(|| HELP.to_owned())?;
    let yes = rest.iter().any(|word| word == "--yes" || word == "-y");
    let words: Vec<&String> =
        rest.iter().filter(|word| *word != "--yes" && *word != "-y").collect();
    let one = |words: &[&String]| -> Result<Option<String>, String> {
        match words {
            [] => Ok(None),
            [word] if !word.starts_with('-') => Ok(Some((*word).clone())),
            [word, ..] => Err(format!("cmux setup {verb}: unexpected {word:?}")),
        }
    };
    match verb.as_str() {
        "install" => {
            let mut words = words;
            let as_id = match words.iter().position(|word| *word == "--as") {
                Some(at) => {
                    let id = words
                        .get(at + 1)
                        .filter(|id| !id.starts_with('-'))
                        .map(|id| (*id).clone())
                        .ok_or("cmux setup install: --as needs OWNER/NAME")?;
                    words.drain(at..=at + 1);
                    Some(id)
                }
                None => None,
            };
            match one(&words)? {
                Some(reference) => Ok(Request::Install { reference, yes, as_id }),
                None => Err(
                    "cmux setup install needs a repo (HOST/OWNER/REPO[@REF]) or a folder (./DIR)"
                        .to_owned(),
                ),
            }
        }
        "check" if !yes => {
            let (mut dir, mut owner, mut strict) = (None, None, false);
            let mut iter = rest.iter();
            while let Some(word) = iter.next() {
                match word.as_str() {
                    "--strict" => strict = true,
                    "--owner" => {
                        owner = Some(
                            iter.next()
                                .filter(|value| !value.starts_with('-'))
                                .cloned()
                                .ok_or("cmux setup check: --owner needs a value")?,
                        );
                    }
                    other if other.starts_with('-') => {
                        return Err(format!("cmux setup check: unknown option {other:?}"));
                    }
                    other if dir.is_none() => dir = Some(PathBuf::from(other)),
                    other => return Err(format!("cmux setup check: unexpected {other:?}")),
                }
            }
            let dir = dir.ok_or("cmux setup check needs the setup folder: cmux setup check DIR")?;
            Ok(Request::Check { dir, owner, strict })
        }
        "update" => Ok(Request::Update { which: one(&words)?, yes }),
        "remove" if !yes => Ok(Request::Remove { which: one(&words)? }),
        "installed" if rest.is_empty() => Ok(Request::Installed),
        "on" | "off" if !yes => Ok(Request::On { which: one(&words)?, on: verb == "on" }),
        "order" if !yes => {
            if words.is_empty() || words.iter().any(|word| word.starts_with('-')) {
                return Err(
                    "cmux setup order needs the setups, top first: cmux setup order ID [ID]..."
                        .to_owned(),
                );
            }
            Ok(Request::Order { ids: words.into_iter().cloned().collect() })
        }
        "export" => {
            let mut dir = None;
            let mut header = ExportHeader::default();
            let mut iter = words.into_iter();
            while let Some(word) = iter.next() {
                let mut value = |name: &str| {
                    iter.next()
                        .cloned()
                        .ok_or_else(|| format!("cmux setup export: {name} needs a value"))
                };
                match word.as_str() {
                    "--id" => header.id = value("--id")?,
                    "--name" => header.name = value("--name")?,
                    "--description" => header.description = value("--description")?,
                    "--repo" => header.repo = value("--repo")?,
                    "--extension" => header.extensions.push(value("--extension")?),
                    other if other.starts_with('-') => {
                        return Err(format!("cmux setup export: unknown option {other:?}"));
                    }
                    other if dir.is_none() => dir = Some(PathBuf::from(other)),
                    other => return Err(format!("cmux setup export: unexpected {other:?}")),
                }
            }
            let dir = dir.ok_or("cmux setup export needs a folder to write the repo in")?;
            if header.id.is_empty() {
                return Err(
                    "cmux setup export needs --id OWNER/NAME (OWNER: your GitHub name)".to_owned()
                );
            }
            if header.name.is_empty() {
                header.name = header.id.split('/').next_back().unwrap_or_default().to_owned();
            }
            Ok(Request::Export { dir, header })
        }
        other => Err(format!("cmux setup {other}: unexpected arguments")),
    }
}

/// Runs a setups verb; the exit code.
pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    if args.iter().any(|arg| matches!(arg.as_str(), "-h" | "--help")) {
        print!("{HELP}");
        return 0;
    }
    let request = match parse(args) {
        Ok(request) => request,
        Err(message) => return failure(global.output, "usage.invalid", &message, Value::Null, 2),
    };
    // Reads only the folder: never the person's customization.
    if let Request::Check { dir, owner, strict } = &request {
        return check(global.output, dir, owner.as_deref(), *strict);
    }
    let customize = match Customize::from_env() {
        Ok(customize) => customize,
        Err(error) => {
            return failure(global.output, error.code(), &error.to_string(), Value::Null, 1);
        }
    };
    let apps = CliApps { global };
    let answer = match request {
        Request::Install { reference, yes, as_id } => {
            install_as(&customize, &apps, global.output, &reference, yes, as_id.as_deref())
        }
        Request::Update { which, yes } => {
            update(&customize, &apps, global.output, which.as_deref(), yes)
        }
        Request::Remove { which } => remove(&customize, &apps, which.as_deref()),
        Request::Installed => {
            customize.setups().map(|setups| json!({"setups": setups})).map_err(Failure::from)
        }
        Request::On { which, on } => set_on(&customize, &apps, which.as_deref(), on),
        Request::Order { ids } => order(&customize, &apps, &ids),
        Request::Export { dir, header } => export(&customize, &dir, &header),
        Request::Check { .. } => unreachable_check(),
    };
    match answer {
        Ok(value) => {
            if global.output == OutputMode::Human {
                println!("{}", human(&value));
                0
            } else {
                wire::print_local_success(&value, global.output)
            }
        }
        Err(Failure { code, message, details }) => {
            failure(global.output, code, &message, details, 1)
        }
    }
}

fn unreachable_check() -> Result<Value, Failure> {
    Err(refused("setup.check", "cmux setup check runs before the customization is read"))
}

/// `cmux setup check DIR`: the report, and its exit code (1 on an error, or
/// with `strict` a warning).
pub(super) fn check(output: OutputMode, dir: &Path, owner: Option<&str>, strict: bool) -> i32 {
    let options =
        setup::CheckOptions { owner, running: running_version(), history: &setup::RetiredKeys };
    let report = setup::check_dir(dir, &options);
    let exit = check_exit(&report, strict);
    if output == OutputMode::Human {
        println!("{}", check_text(&report, dir, strict));
        return exit;
    }
    let value = serde_json::to_value(&report).unwrap_or(Value::Null);
    match wire::print_local_success(&value, output) {
        0 => exit,
        code => code,
    }
}

pub(super) fn check_exit(report: &setup::Report, strict: bool) -> i32 {
    i32::from(report.errors() > 0 || (strict && report.warnings() > 0))
}

/// The report as a person reads it: one block per finding, like a compiler.
pub(super) fn check_text(report: &setup::Report, dir: &Path, strict: bool) -> String {
    // Every string comes from the folder: shown inert.
    let value = inert(&serde_json::to_value(report).unwrap_or(Value::Null));
    let mut lines = Vec::new();
    for finding in value["findings"].as_array().into_iter().flatten() {
        let text = |key: &str| finding[key].as_str().unwrap_or_default().to_owned();
        let mut place = text("path");
        if let Some(line) = finding["line"].as_u64() {
            place.push_str(&format!(":{line}"));
        }
        if let Some(key) = finding["key"].as_str() {
            place.push_str(&format!(" ({key})"));
        }
        lines.push(format!("{}[{}] {place}: {}", text("severity"), text("code"), text("message")));
        if let Some(fix) = finding["fix"].as_str() {
            lines.push(format!("  fix: {fix}"));
        }
    }
    for skipped in value["skipped"].as_array().into_iter().flatten() {
        lines.push(format!("note: not checked: {}", skipped["why"].as_str().unwrap_or_default()));
    }
    let name = value["setup_id"].as_str().map_or_else(|| dir.display().to_string(), str::to_owned);
    let (errors, warnings) = (report.errors(), report.warnings());
    let count = |n: usize, what: &str| format!("{n} {what}{}", if n == 1 { "" } else { "s" });
    lines.push(if errors > 0 {
        format!(
            "{name}: {}, {}. cmux setup install would refuse it.",
            count(errors, "error"),
            count(warnings, "warning")
        )
    } else if strict && warnings > 0 {
        format!("{name}: {} (--strict).", count(warnings, "warning"))
    } else if warnings > 0 {
        format!(
            "{name}: no errors, {}. cmux setup install would take it.",
            count(warnings, "warning")
        )
    } else {
        format!("{name}: no problems. cmux setup install would take it.")
    });
    lines.join("\n")
}

fn failure(output: OutputMode, code: &str, message: &str, details: Value, exit: i32) -> i32 {
    wire::print_local_error(
        &json!({"code": code, "message": message, "details": details, "retryable": false}),
        output,
        exit,
    )
}

#[derive(Debug)]
pub(super) struct Failure {
    code: &'static str,
    message: String,
    details: Value,
}

impl From<Error> for Failure {
    fn from(error: Error) -> Failure {
        Failure { code: error.code(), message: error.to_string(), details: Value::Null }
    }
}

fn refused(code: &'static str, message: impl Into<String>) -> Failure {
    Failure { code, message: message.into(), details: Value::Null }
}

/// What a setup reaches outside the customization: the repo (fetched at one
/// commit) and the App Store (what an extension asks for, install it with
/// cmux's own card, remove it).
pub(super) trait Apps {
    fn fetch(&self, reference: &Reference) -> Result<Checkout, Failure> {
        fetch(reference)
    }
    /// The App Store's `apps info` answer for a reference; `None` when cmux
    /// cannot say (not running, not reachable).
    fn info(&self, reference: &str) -> Option<Value>;
    fn install(&self, reference: &str) -> Result<Value, String>;
    fn remove(&self, app: &str) -> Result<(), String>;
    /// Asks a running cmux to read the setup layers again (best effort: its
    /// file watch reads a layer's own files anyway).
    fn reload_layers(&self) {}
}

struct CliApps<'a> {
    global: &'a GlobalArgs,
}

impl CliApps<'_> {
    fn cmux(&self, words: &[&str]) -> Result<Value, String> {
        let exe = std::env::current_exe().map_err(|error| error.to_string())?;
        let mut command = Command::new(exe);
        // The child reaches the daemon and app the setup command was pointed at.
        if let Some(socket) = &self.global.socket {
            command.arg("--socket").arg(socket);
        }
        if let Some(socket) = &self.global.app_socket {
            command.arg("--app-socket").arg(socket);
        }
        if let Some(session) = &self.global.session {
            command.args(["--session", session]);
        }
        if let Some(machine) = &self.global.machine {
            command.args(["--machine", machine]);
        }
        let output =
            command.args(words).arg("--json").output().map_err(|error| error.to_string())?;
        let text = String::from_utf8_lossy(&output.stdout);
        if !output.status.success() {
            let error = String::from_utf8_lossy(&output.stderr);
            let message = serde_json::from_str::<Value>(error.trim())
                .ok()
                .and_then(|value| at(&value, "/error/message").as_str().map(str::to_owned))
                .unwrap_or_else(|| error.trim().to_owned());
            return Err(message);
        }
        Ok(serde_json::from_str(text.trim()).unwrap_or(Value::Null))
    }
}

impl Apps for CliApps<'_> {
    fn info(&self, reference: &str) -> Option<Value> {
        self.cmux(&["apps", "info", reference]).ok()
    }

    fn install(&self, reference: &str) -> Result<Value, String> {
        self.cmux(&["apps", "install", reference])
    }

    fn remove(&self, app: &str) -> Result<(), String> {
        self.cmux(&["apps", "remove", app]).map(|_| ())
    }

    fn reload_layers(&self) {
        // No cmux running is fine: it reads the layers when it starts.
        let _ = self.cmux(&["ext", "reload"]);
    }
}

/// A repo checked out at one commit, in a folder of its own that goes away
/// with it.
pub(super) struct Checkout {
    dir: PathBuf,
    commit: String,
}

impl Drop for Checkout {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// `git` with no prompt, no hooks and no system config: the repo is data.
/// `config` (`-c` pairs) comes after cmux's own.
fn git(dir: &Path, config: &[&str], args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .current_dir(dir)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.https.allow=always",
        ])
        .args(config)
        .args(args)
        .output()
        .map_err(|error| format!("git: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// Fetches `reference` at its ref (the default branch when none) and checks
/// out that one commit. Any git host: a shallow fetch of the commit, and of
/// a setup in a folder only that folder's files.
fn fetch(reference: &Reference) -> Result<Checkout, Failure> {
    fetch_from(reference, &reference.clone_url(), &[])
}

/// [`fetch`] from `url`, with `config` on every git call (the tests' repo on
/// disk needs the file protocol).
fn fetch_from(reference: &Reference, url: &str, config: &[&str]) -> Result<Checkout, Failure> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    let dir = std::env::temp_dir().join(format!("cmux-setup-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).map_err(|error| refused("setup.fetch", error.to_string()))?;
    let mut checkout = Checkout { dir, commit: String::new() };
    let wanted = reference.git_ref.as_deref().unwrap_or("HEAD");
    let run = |args: &[&str]| git(&checkout.dir, config, args);
    // A setup in a folder (a look in a monorepo) fetches the commit's trees
    // with no file contents, then checks out only its folder: the checkout
    // fetches that folder's files from `origin` in one batch. A host with no
    // filter support sends the whole commit, as before.
    let sparse = (!reference.path.is_empty()).then(|| format!("/{}/", reference.path));
    let fetch_args: &[&str] = if sparse.is_some() {
        &["fetch", "-q", "--depth", "1", "--filter=blob:none", "--no-tags", "origin", wanted]
    } else {
        &["fetch", "-q", "--depth", "1", "--no-tags", "origin", wanted]
    };
    let fetched = run(&["init", "-q"])
        .and_then(|_| run(&["remote", "add", "origin", url]))
        .and_then(|_| run(fetch_args))
        .and_then(|_| match &sparse {
            // The setting and pattern file every git with partial clone reads
            // (`sparse-checkout set --no-cone` needs 2.35).
            Some(folder) => run(&["config", "core.sparseCheckout", "true"]).and_then(|_| {
                let info = checkout.dir.join(".git/info");
                std::fs::create_dir_all(&info)
                    .and_then(|()| {
                        std::fs::write(info.join("sparse-checkout"), format!("{folder}\n"))
                    })
                    .map(|()| String::new())
                    .map_err(|error| format!("sparse-checkout: {error}"))
            }),
            None => Ok(String::new()),
        })
        .and_then(|_| run(&["-c", "advice.detachedHead=false", "checkout", "-q", "FETCH_HEAD"]))
        .and_then(|_| run(&["rev-parse", "HEAD"]));
    match fetched {
        Ok(commit) if commit.len() == 40 => {
            checkout.commit = commit;
            Ok(checkout)
        }
        Ok(_) => Err(refused("setup.fetch", format!("{reference}: git named no commit"))),
        Err(why) => {
            Err(refused("setup.fetch", format!("could not fetch {reference} ({url}): {why}")))
        }
    }
}

fn setup_dir(checkout: &Checkout, reference: &Reference) -> PathBuf {
    if reference.path.is_empty() {
        checkout.dir.clone()
    } else {
        checkout.dir.join(&reference.path)
    }
}

fn running_version() -> &'static str {
    crate::distribution::DISTRIBUTION_VERSION
}

/// The scopes an extension asks for, as the App Store names them; `None`
/// when cmux cannot say now (it shows them on its own card).
fn scopes(info: &Value) -> Option<Vec<String>> {
    let listing = info.get("data").unwrap_or(info);
    let found = ["scopes", "permissions", "capabilities"].iter().find_map(|key| {
        listing.get(*key).or_else(|| listing.get("app").and_then(|app| app.get(*key)))
    })?;
    let list = found.as_array()?;
    Some(
        list.iter()
            .filter_map(|scope| match scope {
                Value::String(text) => Some(text.clone()),
                Value::Object(fields) => ["scope", "id", "name"]
                    .iter()
                    .find_map(|key| fields.get(*key).and_then(Value::as_str))
                    .map(str::to_owned),
                _ => None,
            })
            .collect(),
    )
}

fn app_id(info: &Value) -> Option<String> {
    let listing = info.get("data").unwrap_or(info);
    ["app", "id"].iter().find_map(|key| match listing.get(*key) {
        Some(Value::String(id)) => Some(id.clone()),
        Some(Value::Object(app)) => app.get("id").and_then(Value::as_str).map(str::to_owned),
        _ => None,
    })
}

fn is_installed(info: &Value) -> bool {
    let listing = info.get("data").unwrap_or(info);
    at(listing, "/install/installed") == &json!(true) || listing["installed"] == json!(true)
}

/// The consent card: the plan, the source and every extension with what it
/// asks for.
fn card(plan: &Plan, opened: &Opened, extensions: &[Value]) -> Value {
    let reference = opened.source.reference();
    let local = opened.source.folder().is_some();
    // Kept under its id whatever its source: removed by it too.
    let undo = match reference {
        Some(reference) => format!("cmux setup remove {}", reference.key()),
        None => format!("cmux setup remove {}", plan.id),
    };
    json!({
        "setup": plan,
        "source": {
            "reference": opened.source.to_string(),
            "repository": opened.repository(),
            "commit": opened.commit,
            "page": reference.map(Reference::page_url),
            "local": local,
        },
        "reviewed": false,
        "extensions": extensions,
        "undo": undo,
    })
}

fn extension_rows(apps: &dyn Apps, plan: &Plan) -> Vec<Value> {
    plan.extensions
        .iter()
        .map(|reference| {
            let info = apps.info(reference);
            json!({
                "reference": reference,
                "app": info.as_ref().and_then(app_id),
                "installed": info.as_ref().is_some_and(is_installed),
                "scopes": info.as_ref().and_then(scopes),
            })
        })
        .collect()
}

/// Asks the person, on a terminal; `--yes` answers for them. Without a
/// terminal or with --json and no --yes, nothing changes and the card comes
/// back so the caller can show it and ask.
fn consent(output: OutputMode, card: &Value, verb: &str, yes: bool) -> Result<(), Failure> {
    if yes {
        return Ok(());
    }
    let interactive = output == OutputMode::Human && std::io::stdin().is_terminal();
    if !interactive {
        if output == OutputMode::Human {
            eprintln!("{}\n", card_text(card));
        }
        return Err(Failure {
            code: "setup.needs_consent",
            message: format!(
                "nothing was changed: show the person this card, then run it again with --yes ({verb})"
            ),
            details: card.clone(),
        });
    }
    println!("{}", card_text(card));
    print!("{verb} this setup? [y/N] ");
    let _ = std::io::stdout().flush();
    let mut answer = String::new();
    let _ = std::io::stdin().lock().read_line(&mut answer);
    if matches!(answer.trim(), "y" | "Y" | "yes") {
        Ok(())
    } else {
        Err(refused("setup.declined", "nothing was changed"))
    }
}

pub(super) fn card_text(card: &Value) -> String {
    // Everything on the card but its own layout comes from the repo: a
    // terminal control or line break in it is shown inert, so a setup can
    // neither drive the terminal nor fake a line of the card.
    let card = &inert(card);
    let setup = &card["setup"];
    let mut lines = vec![format!(
        "{} ({}) from {} at {}",
        setup["name"].as_str().unwrap_or_default(),
        setup["id"].as_str().unwrap_or_default(),
        at(card, "/source/reference").as_str().unwrap_or_default(),
        at(card, "/source/commit").as_str().unwrap_or_default().get(..12).unwrap_or_default(),
    )];
    if card["reviewed"] != json!(true) {
        lines.push(if card["source"]["local"] == json!(true) {
            "Not reviewed by cmux: it comes straight from this folder.".to_owned()
        } else {
            "Not reviewed by cmux: it comes straight from the repo.".to_owned()
        });
    }
    if let Some(description) = setup["description"].as_str() {
        lines.push(description.to_owned());
    }
    lines.push("It will change:".to_owned());
    if let Some(theme) = setup["theme"].as_str() {
        lines.push(format!("  theme: {theme}"));
    }
    for setting in setup["settings"].as_array().into_iter().flatten() {
        let mut line = format!(
            "  setting {} = {}",
            setting["key"].as_str().unwrap_or_default(),
            setting["value"]
        );
        if let Some(yours) = setting.get("replaces") {
            line.push_str(&format!(" (yours: {yours})"));
        }
        lines.push(line);
    }
    // Written for another cmux: what it calls by an older name, and what
    // this cmux leaves out (the rest installs).
    for notice in setup["renamed"].as_array().into_iter().flatten() {
        let from = notice["from"].as_str().unwrap_or_default();
        lines.push(if notice["kind"] == json!("renamed_value") {
            format!(
                "  ({from}: {} is the older name of {})",
                notice["old_value"], notice["new_value"]
            )
        } else {
            format!("  ({from} is the older name of {})", notice["to"].as_str().unwrap_or_default())
        });
    }
    for skipped in setup["skipped"].as_array().into_iter().flatten() {
        lines.push(format!(
            "  left out: setting {} ({})",
            skipped["key"].as_str().unwrap_or_default(),
            skipped["reason"].as_str().unwrap_or_default()
        ));
    }
    for file in setup["files"].as_array().into_iter().flatten() {
        let path = file["path"].as_str().unwrap_or_default();
        let what = match file["part"].as_str().unwrap_or_default() {
            "keybindings" => format!(
                "{} shortcuts, added to yours",
                setup["keybindings"].as_u64().unwrap_or_default()
            ),
            "views" => format!(
                "views in a layer of their own, {}; your own views stay",
                setup["layer"].as_str().unwrap_or_default()
            ),
            part => part.trim_end_matches('s').to_owned(),
        };
        let replaces = if file["replaces"] == json!(true) { ", replaces yours" } else { "" };
        lines.push(format!("  file {path} ({what}{replaces})"));
    }
    for font in setup["fonts"].as_array().into_iter().flatten() {
        lines.push(format!(
            "  font {} ({}, copied into your fonts folder)",
            font.as_str().unwrap_or_default(),
            setup["font_license"].as_str().unwrap_or_default()
        ));
    }
    for action in setup["actions"].as_array().into_iter().flatten() {
        let replaces = if action["replaces"] == json!(true) { " (replaces yours)" } else { "" };
        lines.push(format!(
            "  action {}: runs {} `{}`{replaces}",
            action["name"].as_str().unwrap_or_default(),
            action["kind"].as_str().unwrap_or_default(),
            action["runs"].as_str().unwrap_or_default(),
        ));
    }
    for extension in card["extensions"].as_array().into_iter().flatten() {
        let reference = extension["reference"].as_str().unwrap_or_default();
        let scopes = match extension["scopes"].as_array() {
            Some(list) if list.is_empty() => "no scopes".to_owned(),
            Some(list) => format!(
                "scopes: {}",
                list.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", ")
            ),
            None => "cmux shows its scopes on its own card".to_owned(),
        };
        let state =
            if extension["installed"] == json!(true) { "already installed" } else { "installs" };
        lines.push(format!("  extension {reference} ({state}; {scopes})"));
    }
    if let Some(requires) = setup["requires"].as_str() {
        lines.push(format!("Requires cmux {requires}."));
    }
    match card["undo"].as_str() {
        Some(undo) => lines.push(format!("Undo: {undo}")),
        None => lines.push(format!(
            "Undo: cmux setup remove {}",
            at(card, "/source/reference")
                .as_str()
                .unwrap_or_default()
                .split('@')
                .next()
                .unwrap_or_default()
        )),
    }
    lines.join("\n")
}

/// The value at a JSON pointer (`/source/commit`), or null.
fn at<'a>(value: &'a Value, pointer: &str) -> &'a Value {
    value.pointer(pointer).unwrap_or(&Value::Null)
}

/// A commit's first 12 hex digits (all of it when shorter).
fn short(commit: &str) -> &str {
    commit.get(..12).unwrap_or(commit)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_millis() as u64)
}

/// A setup read at one version: from a repo fetched at one commit (its
/// checkout goes away with this), or from a folder on this machine.
struct Opened {
    read: setup::Setup,
    source: SetupSource,
    /// The commit; for a folder, `local-` and the first hex of what it
    /// holds, so a changed folder reads as a new version.
    commit: String,
    _checkout: Option<Checkout>,
}

impl Opened {
    fn label(&self) -> String {
        match &self.source {
            SetupSource::Folder { path } => {
                format!("setup {} from {}", self.read.manifest.id, path.display())
            }
            SetupSource::Repo { .. } => {
                format!("setup {} at {}", self.read.manifest.id, short(&self.commit))
            }
        }
    }

    fn repository(&self) -> String {
        match &self.source {
            SetupSource::Repo { reference } => reference.repository(),
            SetupSource::Folder { path } => path.display().to_string(),
        }
    }

    /// The owner the id rule checks against: the repo's, or for a folder
    /// the id's own (a folder is no one's repo; `cmux/` ids stay refused).
    fn owner(&self) -> String {
        match &self.source {
            SetupSource::Repo { reference } => reference.owner.clone(),
            SetupSource::Folder { .. } => {
                self.read.manifest.id.split('/').next().unwrap_or_default().to_owned()
            }
        }
    }
}

/// Reads the setup `source` names; a folder under `as_id` when given.
fn open(apps: &dyn Apps, source: &SetupSource, as_id: Option<&str>) -> Result<Opened, Failure> {
    match source {
        SetupSource::Folder { path } => {
            let mut read = setup::read_dir(path)?;
            if let Some(id) = as_id {
                setup::check_id(id, id.split('/').next().unwrap_or_default())?;
                read = read.renamed(id);
            }
            let commit = format!("local-{}", read.sha256.get(..12).unwrap_or(&read.sha256));
            Ok(Opened { read, source: source.clone(), commit, _checkout: None })
        }
        SetupSource::Repo { reference } => {
            if as_id.is_some() {
                return Err(refused(
                    "usage.invalid",
                    "--as is for a folder on this machine (cmux setup install ./DIR --as OWNER/NAME); a repo installs under its own id",
                ));
            }
            let checkout = apps.fetch(reference)?;
            let read = setup::read_dir(&setup_dir(&checkout, reference))?;
            let commit = checkout.commit.clone();
            Ok(Opened { read, source: source.clone(), commit, _checkout: Some(checkout) })
        }
    }
}

/// The source `text` names: a folder when it is a path (`./`, `../`, `/`
/// or `~`, made absolute; it must hold the setup file), else a repo.
fn parse_source(text: &str) -> Result<SetupSource, Failure> {
    let is_path = matches!(text, "." | ".." | "~")
        || ["./", "../", "/", "~/"].iter().any(|start| text.starts_with(start));
    if !is_path {
        return Ok(SetupSource::Repo { reference: Reference::parse(text)? });
    }
    let path = match text.strip_prefix('~') {
        Some(rest) => {
            let home = std::env::var_os("HOME")
                .ok_or_else(|| refused("setup.not_a_setup", "there is no home folder for ~"))?;
            PathBuf::from(home).join(rest.trim_start_matches('/'))
        }
        None => PathBuf::from(text),
    };
    let dir = std::fs::canonicalize(&path)
        .map_err(|error| refused("setup.not_a_setup", format!("{}: {error}", path.display())))?;
    if !dir.join(SETUP_FILE).is_file() {
        return Err(refused(
            "setup.not_a_setup",
            format!("{} has no {SETUP_FILE}, so it is not a cmux setup", dir.display()),
        ));
    }
    Ok(SetupSource::Folder { path: dir })
}

/// Installs the repo or folder `text` names, as a layer of its own on top
/// of the other setups; a folder under `as_id` when given (a look tried
/// before it is published).
pub(super) fn install_as(
    customize: &Customize,
    apps: &dyn Apps,
    output: OutputMode,
    text: &str,
    yes: bool,
    as_id: Option<&str>,
) -> Result<Value, Failure> {
    let source = parse_source(text)?;
    let installed = customize.setups()?;
    let same_source = installed.iter().find(|receipt| {
        receipt.source.key() == source.key() && as_id.is_none_or(|id| id == receipt.id)
    });
    if let Some(receipt) = same_source {
        // Installed already: this is an update to the named ref (or folder).
        return apply_update(customize, apps, output, receipt.clone(), Some(source), yes);
    }
    let opened = open(apps, &source, as_id)?;
    let read = &opened.read;
    if let Some(other) = installed.iter().find(|receipt| receipt.id == read.manifest.id) {
        return Err(refused(
            "setup.id_taken",
            format!(
                "{} is installed already, from {}: remove it first, or try this one under another id (cmux setup install ./DIR --as {}-dev)",
                other.id, other.source, other.id
            ),
        ));
    }
    let plan = customize.plan_setup(read, &opened.owner(), running_version())?;
    let extensions = extension_rows(apps, &plan);
    let card = card(&plan, &opened, &extensions);
    consent(output, &card, "Install", yes)?;
    let installed = customize.install_setup(read, &opened.label(), "cli", now_ms())?;
    let (extension_receipts, extension_errors) = install_extensions(apps, &extensions, &[]);
    let receipt = Receipt::new(
        read,
        &installed,
        opened.source.clone(),
        &opened.commit,
        extension_receipts,
        now_ms(),
    );
    customize.record_setup(receipt.clone())?;
    apps.reload_layers();
    Ok(json!({
        "installed": receipt,
        "card": card,
        "extension_errors": extension_errors,
        "undo": card["undo"],
        "page": opened.source.reference().map(Reference::page_url),
    }))
}

/// Installs the extensions not installed yet; the receipts (kept ones
/// first) and the errors (an extension that did not install is named, the
/// setup stays).
fn install_extensions(
    apps: &dyn Apps,
    rows: &[Value],
    kept: &[ExtensionReceipt],
) -> (Vec<ExtensionReceipt>, Vec<Value>) {
    let mut receipts = Vec::new();
    let mut errors = Vec::new();
    for row in rows {
        let reference = row["reference"].as_str().unwrap_or_default().to_owned();
        if let Some(old) = kept.iter().find(|old| old.reference == reference) {
            receipts.push(old.clone());
            continue;
        }
        if row["installed"] == json!(true) {
            receipts.push(ExtensionReceipt {
                reference,
                app: row["app"].as_str().map(str::to_owned),
                installed_by_setup: false,
            });
            continue;
        }
        match apps.install(&reference) {
            Ok(answer) => receipts.push(ExtensionReceipt {
                app: app_id(&answer).or_else(|| row["app"].as_str().map(str::to_owned)),
                reference,
                installed_by_setup: true,
            }),
            Err(why) => errors.push(json!({"reference": reference, "error": why})),
        }
    }
    (receipts, errors)
}

fn find(customize: &Customize, which: Option<&str>) -> Result<Receipt, Failure> {
    let setups = customize.setups()?;
    match which {
        Some(which) => customize.setup(which)?.ok_or_else(|| {
            refused(
                "setup.not_installed",
                format!("{which} is not an installed setup; `cmux setup installed` lists them"),
            )
        }),
        None if setups.len() > 1 => Err(refused(
            "setup.ambiguous",
            "more than one setup is installed: name one (`cmux setup installed` lists them)",
        )),
        None => setups
            .into_iter()
            .next()
            .ok_or_else(|| refused("setup.not_installed", "no setup is installed")),
    }
}

fn update(
    customize: &Customize,
    apps: &dyn Apps,
    output: OutputMode,
    which: Option<&str>,
    yes: bool,
) -> Result<Value, Failure> {
    let receipt = find(customize, which)?;
    apply_update(customize, apps, output, receipt, None, yes)
}

/// Moves `receipt` to the newest commit of `to` (or the source it was
/// installed from); a folder to what it holds now: the old layer comes off
/// and the new one goes on in its place in the order, as one question.
fn apply_update(
    customize: &Customize,
    apps: &dyn Apps,
    output: OutputMode,
    receipt: Receipt,
    to: Option<SetupSource>,
    yes: bool,
) -> Result<Value, Failure> {
    let source = to.unwrap_or_else(|| receipt.source.clone());
    // A folder is read under the id it was installed as (`--as` included).
    let as_id = source.folder().map(|_| receipt.id.as_str());
    let opened = open(apps, &source, as_id)?;
    let read = &opened.read;
    if opened.commit == receipt.commit {
        if read.sha256 != receipt.sha256 {
            return Err(refused(
                "setup.changed_at_commit",
                format!(
                    "{source} at {} reads differently than when it was installed; nothing was changed",
                    receipt.commit
                ),
            ));
        }
        return Ok(json!({"current": receipt, "updated": false}));
    }
    let plan = customize.plan_setup(read, &opened.owner(), running_version())?;
    let extensions = extension_rows(apps, &plan);
    let card = card(&plan, &opened, &extensions);
    consent(output, &card, "Update", yes)?;
    let label = opened.label();
    // One change: when the new commit does not go on, the old one is put back.
    let installed = customize.replace_setup(&receipt, read, &label, "cli", now_ms())?;
    let (mut extension_receipts, extension_errors) =
        install_extensions(apps, &extensions, &receipt.extensions);
    // An extension the new commit no longer lists, that this setup installed, goes.
    for old in &receipt.extensions {
        if old.installed_by_setup
            && !plan.extensions.contains(&old.reference)
            && let Some(app) = &old.app
        {
            let _ = apps.remove(app);
        }
    }
    extension_receipts.retain(|kept| plan.extensions.contains(&kept.reference));
    // The old layer's remove put your own actions back first, so what the
    // new one replaced is yours.
    let mut updated = Receipt::new(
        read,
        &installed,
        opened.source.clone(),
        &opened.commit,
        extension_receipts,
        now_ms(),
    );
    updated.on = true;
    customize.record_setup(updated.clone())?;
    if !receipt.on {
        // An update keeps a setup you turned off, off.
        updated = customize.set_setup_on(&updated.id, false, "cli", now_ms())?;
    }
    apps.reload_layers();
    Ok(json!({
        "installed": updated,
        "updated": true,
        "from": receipt.commit,
        "card": card,
        "extension_errors": extension_errors,
    }))
}

fn remove(customize: &Customize, apps: &dyn Apps, which: Option<&str>) -> Result<Value, Failure> {
    let receipt = find(customize, which)?;
    let removed = customize.remove_setup(&receipt, "cli", now_ms())?;
    let mut extensions = Vec::new();
    for extension in receipt.extensions.iter().filter(|extension| extension.installed_by_setup) {
        let Some(app) = &extension.app else { continue };
        let result = apps.remove(app);
        extensions.push(json!({"app": app, "removed": result.is_ok(), "error": result.err()}));
    }
    apps.reload_layers();
    Ok(json!({"removed": removed, "extensions": extensions}))
}

/// `cmux setup on|off ID`: its layer on or off, still installed, in its place.
fn set_on(
    customize: &Customize,
    apps: &dyn Apps,
    which: Option<&str>,
    on: bool,
) -> Result<Value, Failure> {
    let receipt = find(customize, which)?;
    let receipt = customize.set_setup_on(&receipt.id, on, "cli", now_ms())?;
    apps.reload_layers();
    Ok(json!({"toggled": receipt, "setups": customize.setups()?}))
}

/// `cmux setup order ID...`: the setups in that order, top first.
fn order(customize: &Customize, apps: &dyn Apps, which: &[String]) -> Result<Value, Failure> {
    let mut ids = Vec::new();
    for one in which {
        ids.push(find(customize, Some(one))?.id);
    }
    let setups = customize.order_setups(&ids, "cli", now_ms())?;
    apps.reload_layers();
    Ok(json!({"ordered": true, "setups": setups}))
}

fn export(customize: &Customize, dir: &Path, header: &ExportHeader) -> Result<Value, Failure> {
    let exported = customize.export_setup(dir, header, now_ms())?;
    let repo = if header.repo.is_empty() { header.id.clone() } else { header.repo.clone() };
    Ok(json!({
        "exported": exported,
        "next": [
            format!("cd {} && git init && git add -A && git commit -m 'My cmux setup'", dir.display()),
            format!("push it to github.com/{repo} and add the topic {TOPIC}"),
            format!("cmux setup install github.com/{repo}"),
        ],
    }))
}

/// The answer as a person reads it.
fn human(value: &Value) -> String {
    let value = &inert(value);
    if let Some(installed) = value.get("installed") {
        let mut lines = vec![format!(
            "{} {} ({} at {}).",
            if value["updated"] == json!(true) { "Updated" } else { "Installed" },
            installed["name"].as_str().unwrap_or_default(),
            installed["id"].as_str().unwrap_or_default(),
            installed["commit"].as_str().unwrap_or_default().get(..12).unwrap_or_default(),
        )];
        for error in value["extension_errors"].as_array().into_iter().flatten() {
            lines.push(format!(
                "Extension {} did not install: {}",
                error["reference"].as_str().unwrap_or_default(),
                error["error"].as_str().unwrap_or_default()
            ));
        }
        if let Some(undo) = value["undo"].as_str() {
            lines.push(format!("Undo: {undo}"));
        }
        return lines.join("\n");
    }
    if let Some(current) = value.get("current") {
        return format!(
            "{} is at the newest commit already ({}).",
            current["id"].as_str().unwrap_or_default(),
            current["commit"].as_str().unwrap_or_default().get(..12).unwrap_or_default()
        );
    }
    if let Some(removed) = value.get("removed") {
        let mut line = format!(
            "Removed {}: what you had is back.",
            removed["id"].as_str().unwrap_or_default()
        );
        if let Some(kept) = removed["kept_actions"].as_array().filter(|kept| !kept.is_empty()) {
            let names: Vec<_> = kept.iter().filter_map(Value::as_str).collect();
            line.push_str(&format!(" Kept the actions you changed since: {}.", names.join(", ")));
        }
        if let Some(shared) =
            removed["shared_actions"].as_array().filter(|shared| !shared.is_empty())
        {
            let names: Vec<_> = shared.iter().filter_map(Value::as_str).collect();
            line.push_str(&format!(
                " Left the actions another installed setup also sets: {}.",
                names.join(", ")
            ));
        }
        return line;
    }
    if let Some(setups) = value.get("setups").and_then(Value::as_array) {
        if setups.is_empty() {
            return "No setup is installed.".to_owned();
        }
        let mut lines = Vec::new();
        if let Some(toggled) = value.get("toggled") {
            lines.push(format!(
                "{} is {}.",
                toggled["id"].as_str().unwrap_or_default(),
                if toggled["on"] == json!(false) { "off (still installed)" } else { "on" }
            ));
        }
        lines.push("Top layer first:".to_owned());
        lines.extend(setups.iter().map(|setup| {
            format!(
                "{}  {}  {}  {}",
                setup["id"].as_str().unwrap_or_default(),
                if setup["on"] == json!(false) { "off" } else { "on " },
                setup["repository"].as_str().unwrap_or_default(),
                setup["commit"].as_str().unwrap_or_default().get(..12).unwrap_or_default()
            )
        }));
        return lines.join("\n");
    }
    if let Some(exported) = value.get("exported") {
        let mut lines = vec![format!(
            "Wrote the setup {} to {} ({}): {} settings, {} files, {} actions.",
            exported["id"].as_str().unwrap_or_default(),
            exported["dir"].as_str().unwrap_or_default(),
            SETUP_FILE,
            exported["settings"],
            exported["files"].as_array().map_or(0, Vec::len),
            exported["actions"].as_array().map_or(0, Vec::len),
        )];
        for left in exported["left_out"].as_array().into_iter().flatten() {
            lines.push(format!("  left out: {}", left.as_str().unwrap_or_default()));
        }
        lines.push(format!(
            "Its page once pushed: {}",
            exported["page_url"].as_str().unwrap_or_default()
        ));
        lines.push("Next:".to_owned());
        for step in value["next"].as_array().into_iter().flatten() {
            lines.push(format!("  {}", step.as_str().unwrap_or_default()));
        }
        return lines.join("\n");
    }
    value.to_string()
}

/// `value` with every string (and key) made inert for a terminal: C0 and C1
/// controls, DEL, and line and paragraph separators, line breaks included,
/// become U+FFFD.
pub(super) fn inert(value: &Value) -> Value {
    fn text(text: &str) -> String {
        text.chars()
            .map(|c| {
                if matches!(c, '\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}' | '\u{2028}' | '\u{2029}') {
                    '\u{fffd}'
                } else {
                    c
                }
            })
            .collect()
    }
    match value {
        Value::String(s) => Value::String(text(s)),
        Value::Array(items) => Value::Array(items.iter().map(inert).collect()),
        Value::Object(map) => {
            Value::Object(map.iter().map(|(key, item)| (text(key), inert(item))).collect())
        }
        other => other.clone(),
    }
}

#[cfg(test)]
mod tests;
