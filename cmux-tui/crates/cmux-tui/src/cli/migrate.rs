//! `cmux migrate`: move to cmux Cloud from wherever the work is now (cmuxterm-hq RFD 0168 "Moving
//! to AutoCloud"). Each source reads, read-only, into a plan (cmux-migrate); `apply` makes it real
//! step by step through this binary's own Cloud verbs (the signed-in app), or headless through
//! `cloud journey --repo [--keep]` (CI, Linux); `undo` deletes what a move made.
//!
//! Leo, 2026-11-24: "we ought to be able to have good migration capabilities all around for people
//! of all stages any and all levels of technical sophistication and teams and organizations of any
//! size and demand to move to autocloud"

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_migrate::apply::{self, Cloud, Created, Event, Local, PatchRoute, WorkPatch};
use cmux_migrate::ledger::{Ledger, Load};
use cmux_migrate::sources::competitors::{self, Product, Route};
use cmux_migrate::sources::{compose, devcontainer, laptop, nix, ssh_host};
use cmux_migrate::{Plan, Step};
use serde_json::{Value, json};

use super::cloud_start_chat::{Ran, Runner, SelfRunner, shell_quote, step_result};
use super::{GlobalArgs, OutputMode};

pub(super) const USAGE: &str = "\
usage: cmux migrate plan SOURCE [--json] [--out FILE]
       cmux migrate apply PLAN.json|SOURCE [--only KEY]... [--dry-run] [--headless [--backend B]]
       cmux migrate undo SOURCE_ID --yes
       cmux migrate status
       cmux migrate routes

Moves your work to cmux Cloud: one machine per project, its repo cloned, its
setup as a .cmux/machine.toml, its secrets' names (values go from this
computer's keychain over the app, never through a file or a log), your local
commits and changes, your agent chat histories, and your shell, git, editor and
agent settings. Nothing here changes the source; `undo` deletes what a move made.

SOURCE:
  this-computer | laptop        code folders, settings and chats in your home
  PATH                          a checkout: its devcontainer, compose file or Nix
                                setup (else read as a laptop folder)
  ssh:HOST                      a box you reach over SSH (one read-only probe)
  codespaces | coder            your workspaces there (gh / coder CLI, signed in)
  gitpod [PATH]                 a checkout's .gitpod.yml
  t3code | t3 [t3code:PATH]     T3 Code's projects, thread worktrees and their
                                Claude Code / Codex sessions (CMUX_SWITCH_KIT=1)
  daytona | exe.dev | namespace | devpod | devin | capy
                                how that product's workspaces move (`routes`)

`plan` prints what would move (the dry run); `apply` asks the signed-in cmux
app to make it, and records each finished step in ~/.cmux/migrate/ledger.json,
so running it again goes on where it stopped and makes nothing twice.
--headless makes each machine without the app (CMUX_CLOUD_ACCESS_TOKEN or the
dogfood sign-in; see `cmux cloud journey --help`) and measures its time to the
first chat reply; it only clones and sets up: local work, chats and settings are
skipped (said so), and a later run in the app carries them.
Shell history is listed unchecked (it can hold typed tokens): check it in the
plan to carry it.
";

/// The switch kit (cmuxterm-hq#23822) is off until `CMUX_SWITCH_KIT=1`.
fn switch_kit_on() -> bool {
    std::env::var("CMUX_SWITCH_KIT").is_ok_and(|v| v == "1")
}

/// `t3code` or `t3code:PATH` (a T3 home), when the switch kit is on.
fn t3code_source(source: &str) -> Option<Option<&str>> {
    if !switch_kit_on() {
        return None;
    }
    match source {
        "t3code" | "t3" => Some(None),
        _ => source.strip_prefix("t3code:").map(Some),
    }
}

/// Reads T3 Code's database read-only and plans its projects and thread worktrees.
fn t3code_plan(home: &Path, path: Option<&str>) -> Result<Plan, String> {
    use cmux_migrate::sources::t3code;
    let env = std::env::var("T3CODE_HOME").ok();
    let t3_home = match path {
        Some(p) => std::path::absolute(p).map_err(|e| format!("{p}: {e}"))?,
        None => t3code::home_dir(home, env.as_deref()),
    };
    let catalog = t3code::read(&t3_home.join(t3code::DATABASE)).map_err(|e| e.to_string())?;
    Ok(t3code::plan(home, &t3_home, &catalog, &laptop::GitCli::default()))
}

/// One external reader (ssh probe, `gh`, `coder`) ends by then.
const READER_BOUND: Duration = Duration::from_secs(120);
/// A create the app answers `pending` for is waited on this long.
const CREATE_BOUND: Duration = Duration::from_secs(600);
/// One `cloud file-write --contents-file` request: a big file goes in parts joined on the machine.
const WRITE_CHUNK: usize = 48 * 1024;
/// A headless create (clone, setup, first chat) ends by then.
const HEADLESS_BOUND: Duration = Duration::from_secs(1800);

/// `Some(exit code)` when `args` is `migrate …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [migrate, rest @ ..] = command_args.as_slice() else { return None };
    if migrate != "migrate" {
        return None;
    }
    let mut words: Vec<String> = rest.to_vec();
    let mut output = global.output;
    if let Some(i) = words.iter().position(|w| w == "--json") {
        words.remove(i);
        output = OutputMode::Json;
    }
    if words.is_empty() || words.iter().any(|w| w == "-h" || w == "--help" || w == "help") {
        print!("{USAGE}");
        return Some(0);
    }
    let parsed = match parse(&words) {
        Ok(parsed) => parsed,
        Err(message) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {message}\n{USAGE}"),
                output,
                2,
            ));
        }
    };
    Some(match run(&global, output, parsed) {
        Ok(code) => code,
        Err(message) => {
            super::app::failure("migrate.failed", &format!("cmux: {message}"), output, 1)
        }
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Command {
    Plan { source: String, out: Option<PathBuf> },
    Apply { from: String, only: Vec<String>, dry_run: bool, headless: Option<String> },
    Undo { source_id: String },
    Status,
    Routes,
}

pub(super) fn parse(words: &[String]) -> Result<Command, String> {
    let (verb, rest) = words.split_first().ok_or("a verb: plan, apply, undo, status, routes")?;
    let mut positional = Vec::new();
    let (mut out, mut only, mut dry_run, mut headless, mut backend, mut yes) =
        (None, Vec::new(), false, false, None::<String>, false);
    let mut it = rest.iter();
    while let Some(word) = it.next() {
        let mut value = |flag: &str| it.next().cloned().ok_or(format!("{flag} needs a value"));
        match word.as_str() {
            "--out" => out = Some(PathBuf::from(value("--out")?)),
            "--only" => only.push(value("--only")?),
            "--backend" => backend = Some(value("--backend")?),
            "--dry-run" => dry_run = true,
            "--headless" => headless = true,
            "--yes" => yes = true,
            flag if flag.starts_with("--") => return Err(format!("unknown option {flag}")),
            _ => positional.push(word.clone()),
        }
    }
    if backend.is_some() && !headless {
        return Err("--backend goes with --headless".into());
    }
    let one = |what: &str| -> Result<String, String> {
        match positional.as_slice() {
            [one] => Ok(one.clone()),
            [first, second] if first == "gitpod" => Ok(format!("gitpod:{second}")),
            [] => Err(format!("{verb} needs {what}")),
            _ => Err(format!("{verb} takes one {what}")),
        }
    };
    match verb.as_str() {
        "plan" => Ok(Command::Plan { source: one("SOURCE")?, out }),
        "apply" => Ok(Command::Apply {
            from: one("PLAN.json or SOURCE")?,
            only,
            dry_run,
            headless: headless.then(|| backend.unwrap_or_else(|| "prod".into())),
        }),
        "undo" if !yes => Err("undo deletes every machine that move made: add --yes".into()),
        "undo" => Ok(Command::Undo { source_id: one("SOURCE_ID")? }),
        "status" => Ok(Command::Status),
        "routes" => Ok(Command::Routes),
        other => Err(format!("unknown verb {other}")),
    }
}

fn run(global: &GlobalArgs, output: OutputMode, command: Command) -> Result<i32, String> {
    match command {
        Command::Routes => {
            let rows: Vec<Value> = Product::ALL.iter().map(|p| route_json(*p)).collect();
            print_answer(output, &json!({ "routes": rows }), || {
                rows.iter()
                    .map(|r| {
                        format!(
                            "{:<11} {}",
                            r["product"].as_str().unwrap_or(""),
                            r["how"].as_str().unwrap_or("")
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
            });
            Ok(0)
        }
        Command::Plan { source, out } => {
            if let Some(product) = product_named(&source)
                && !matches!(product, Product::Codespaces | Product::Coder | Product::Gitpod)
            {
                let route = route_json(product);
                print_answer(output, &route, || route["how"].as_str().unwrap_or("").to_owned());
                return Ok(0);
            }
            let plan = read_source(&source)?;
            let text = serde_json::to_string_pretty(&plan).map_err(|e| e.to_string())?;
            if let Some(out) = out {
                std::fs::write(&out, format!("{text}\n"))
                    .map_err(|e| format!("{}: {e}", out.display()))?;
            }
            print_answer(output, &serde_json::to_value(&plan).unwrap_or(Value::Null), || {
                plan_words(&plan)
            });
            Ok(0)
        }
        Command::Status => {
            let ledger = load_ledger()?;
            let stats = ledger.stats();
            let answer = json!({
                "attempted": stats.attempted, "done": stats.done,
                "median_first_chat_ms": stats.median_first_chat_ms,
                "projects": serde_json::to_value(&ledger.projects).unwrap_or(Value::Null),
            });
            print_answer(output, &answer, || {
                let median = stats
                    .median_first_chat_ms
                    .map(|ms| format!("; median time to first chat {:.1} s", ms as f64 / 1000.0))
                    .unwrap_or_default();
                format!("{} of {} projects moved{median}", stats.done, stats.attempted)
            });
            Ok(0)
        }
        Command::Undo { source_id } => {
            let mut ledger = load_ledger()?;
            let mut cloud = AppCloud { runner: SelfRunner::new(global) };
            let mut events = Vec::new();
            let outcome = apply::undo(&source_id, &mut ledger, &mut cloud, &mut |e| {
                say(output, e, &mut events)
            });
            save_ledger(&ledger)?;
            finish(output, &events, outcome.failed)
        }
        Command::Apply { from, only, dry_run, headless } => {
            let plan = if from.ends_with(".json") && Path::new(&from).is_file() {
                let text = std::fs::read_to_string(&from).map_err(|e| format!("{from}: {e}"))?;
                serde_json::from_str::<Plan>(&text)
                    .map_err(|e| format!("{from}: not a plan: {e}"))?
            } else {
                read_source(&from)?
            };
            if dry_run {
                let steps: Vec<Value> = plan
                    .steps()
                    .iter()
                    .map(|s| serde_json::to_value(s).unwrap_or(Value::Null))
                    .collect();
                print_answer(output, &json!({ "steps": steps }), || {
                    plan.steps().iter().map(step_words).collect::<Vec<_>>().join("\n")
                });
                return Ok(0);
            }
            let mut ledger = load_ledger()?;
            let local = HomeLocal::new();
            let mut events = Vec::new();
            // The headless route carries no local files: apply skips those steps, said once each
            // and left undone, so a later run in the app carries them.
            // Saved after every step, not only at the end: a crash or Ctrl-C after a machine is
            // made keeps its id, so a rerun skips it and undo can delete it.
            let mut checkpoint = |ledger: &Ledger| {
                if let Err(why) = save_ledger(ledger) {
                    eprintln!("cmux migrate: could not save the ledger: {why}");
                }
            };
            let outcome = match headless {
                Some(backend) => {
                    let mut cloud = Headless { global: global.clone(), backend };
                    apply::apply_saving(
                        &plan,
                        &only,
                        &mut ledger,
                        &mut cloud,
                        &local,
                        &mut |e| say(output, e, &mut events),
                        &mut checkpoint,
                    )
                }
                None => {
                    let mut cloud = AppCloud { runner: SelfRunner::new(global) };
                    apply::apply_saving(
                        &plan,
                        &only,
                        &mut ledger,
                        &mut cloud,
                        &local,
                        &mut |e| say(output, e, &mut events),
                        &mut checkpoint,
                    )
                }
            };
            save_ledger(&ledger)?;
            finish(output, &events, outcome.failed)
        }
    }
}

/// A source word into its plan.
pub(super) fn read_source(source: &str) -> Result<Plan, String> {
    let home = home()?;
    if let Some(host) = source.strip_prefix("ssh:") {
        if host.is_empty() || host.starts_with('-') {
            return Err("ssh:HOST needs a host".into());
        }
        let ran = bounded(
            "ssh",
            &["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, "sh", "-s"],
            Some(ssh_host::PROBE),
        )?;
        return Ok(ssh_host::plan(host, &ran));
    }
    if let Some(path) = source.strip_prefix("gitpod:").or((source == "gitpod").then_some(".")) {
        let root = PathBuf::from(path);
        let yml = std::fs::read_to_string(root.join(".gitpod.yml"))
            .map_err(|e| format!("{}: {e}", root.join(".gitpod.yml").display()))?;
        let repo = cmux_migrate::sources::project_files::repo_at(&root).url;
        return competitors::gitpod_plan(&root.display().to_string(), repo.as_deref(), &yml);
    }
    if let Some(t3) = t3code_source(source) {
        return t3code_plan(&home, t3);
    }
    match source {
        "this-computer" | "laptop" | "this-mac" => {
            let options = laptop::Options::new(laptop::host_name());
            return Ok(laptop::plan(&home, &options, &laptop::GitCli::default()));
        }
        "codespaces" => {
            let list = bounded(
                "gh",
                &["codespace", "list", "--json", competitors::CODESPACES_LIST_FIELDS],
                None,
            )?;
            let secrets = bounded("gh", &["api", "user/codespaces/secrets"], None).ok();
            return competitors::codespaces_plan(&list, secrets.as_deref());
        }
        "coder" => {
            let list = bounded("coder", &["list", "-o", "json"], None)?;
            return competitors::coder_plan(&list);
        }
        _ => {}
    }
    let root = PathBuf::from(source);
    if !root.is_dir() {
        return Err(format!("{source}: not a folder or a known source (see cmux migrate --help)"));
    }
    // A checkout's CI config and secret references join whichever project the reader below makes.
    let routed = if !devcontainer::find(&root).is_empty() {
        Some(devcontainer::plan(&root))
    } else if compose::find(&root).is_some() {
        Some(compose::plan(&root))
    } else if nix::project(&root).is_some() {
        Some(nix::plan(&root))
    } else {
        None
    };
    if let Some(mut plan) = routed {
        cmux_migrate::sources::merge_ci_and_secrets(&root, &mut plan);
        return Ok(plan);
    }
    let root = root.canonicalize().map_err(|e| format!("{source}: {e}"))?;
    let mut options = laptop::Options::new(laptop::host_name());
    options.roots = Some(vec![root.clone()]);
    let mut plan = laptop::plan(&home, &options, &laptop::GitCli::default());
    cmux_migrate::sources::merge_ci_and_secrets(&root, &mut plan);
    Ok(plan)
}

fn product_named(word: &str) -> Option<Product> {
    let word = word.to_ascii_lowercase().replace(['.', '-', '_', ' '], "");
    Product::ALL.into_iter().find(|p| {
        let name = format!("{p:?}").to_ascii_lowercase();
        name == word || (word == "ona" && *p == Product::Gitpod)
    })
}

fn route_json(product: Product) -> Value {
    let name = format!("{product:?}").to_ascii_lowercase();
    match competitors::route(product) {
        Route::Devcontainer => json!({ "product": name, "route": "devcontainer",
            "how": "clone the repo and run `cmux migrate apply PATH`: its devcontainer becomes the machine's setup" }),
        Route::SshHost { how } => json!({ "product": name, "route": "ssh-host",
            "how": format!("`cmux migrate plan ssh:HOST` through {how}") }),
        Route::Unsupported { why, imports } => json!({ "product": name, "route": "unsupported",
            "how": format!("{why}; what moves: {imports}") }),
    }
}

fn plan_words(plan: &Plan) -> String {
    let mut lines = vec![format!(
        "{} ({}): {} project(s)",
        plan.source.label,
        plan.source.id,
        plan.projects.len()
    )];
    for p in &plan.projects {
        let repo =
            p.repo.as_ref().and_then(|r| r.url.clone()).unwrap_or_else(|| "no remote".into());
        lines.push(format!(
            "  [{}] {} {repo}: {} setup, {} secret name(s), {} chat(s)",
            if p.checked { "x" } else { " " },
            p.name,
            p.machine.setup.len(),
            p.machine.secret_names.len(),
            p.chats.len()
        ));
        lines.extend(p.notes.iter().map(|n| format!("      {n}")));
    }
    for c in &plan.carry {
        lines.push(format!("  [{}] carry {}", if c.checked { "x" } else { " " }, c.path));
    }
    lines.extend(plan.warnings.iter().map(|w| format!("  warning: {w}")));
    lines.extend(plan.unsupported.iter().map(|u| format!("  not moved: {} ({})", u.what, u.why)));
    lines.join("\n")
}

fn step_words(step: &Step) -> String {
    match step {
        Step::CreateMachine { name, repo, .. } => {
            format!("create machine {name} {}", repo.as_deref().unwrap_or("(no repo)"))
        }
        Step::CarryWorktree { path, .. } => format!("carry local commits and changes in {path}"),
        Step::DeliverSecrets { names, .. } => format!("deliver secrets {}", names.join(", ")),
        Step::CarryFiles { paths } => format!("carry {}", paths.join(", ")),
        Step::CarrySecretFiles { paths } => {
            format!("leave logins on this computer: {}", paths.join(", "))
        }
        Step::MoveChats { chats, .. } => format!("move {} chat histories", chats.len()),
    }
}

fn say(output: OutputMode, event: &Event, events: &mut Vec<Value>) {
    let (word, step, project, text) = match event {
        Event::Done { step, project, detail } => ("done", step, project, detail),
        Event::Skipped { step, project, why } => ("skipped", step, project, why),
        Event::Failed { step, project, error } => ("failed", step, project, error),
    };
    let value = json!({ "event": word, "step": step, "project": project, "detail": text });
    match output {
        OutputMode::Human => eprintln!("{word:<7} {step} {project}: {text}"),
        _ => eprintln!("{value}"),
    }
    events.push(value);
}

fn finish(output: OutputMode, events: &[Value], failed: usize) -> Result<i32, String> {
    let stats = load_ledger().map(|l| l.stats()).ok();
    let answer = json!({
        "events": events, "failed": failed,
        "median_first_chat_ms": stats.as_ref().and_then(|s| s.median_first_chat_ms),
    });
    print_answer(output, &answer, || {
        if failed == 0 {
            "moved".into()
        } else {
            format!("{failed} step(s) failed: run it again to retry them")
        }
    });
    Ok(i32::from(failed > 0))
}

fn print_answer(output: OutputMode, value: &Value, human: impl FnOnce() -> String) {
    match output {
        OutputMode::Human => println!("{}", human()),
        _ => println!("{value}"),
    }
}

fn home() -> Result<PathBuf, String> {
    std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| "HOME is not set".to_owned())
}

fn ledger_path() -> Result<PathBuf, String> {
    Ok(home()?.join(".cmux/migrate/ledger.json"))
}

fn load_ledger() -> Result<Ledger, String> {
    let path = ledger_path()?;
    match Ledger::load(&path) {
        Load::None => Ok(Ledger::new()),
        Load::Ledger(ledger) => Ok(ledger),
        Load::Newer(version) => Err(format!(
            "{} was written by a newer cmux migrate (ledger version {version}); run `cmux migrate status` from that cmux, or move the file aside to start a new ledger",
            path.display()
        )),
        Load::Unreadable(why) => Err(format!("{}: {why}", path.display())),
    }
}

fn save_ledger(ledger: &Ledger) -> Result<(), String> {
    let path = ledger_path()?;
    ledger.save(&path).map_err(|e| format!("{}: {e}", path.display()))
}

/// `program args`, with `stdin` written to it, ended at [`READER_BOUND`]: its stdout, or why not.
fn bounded(program: &str, args: &[&str], stdin: Option<&str>) -> Result<String, String> {
    let mut command = cmux_process::Command::new(program);
    command
        .args(args)
        .stdin(if stdin.is_some() {
            cmux_process::Stdio::piped()
        } else {
            cmux_process::Stdio::null()
        })
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped());
    let mut child = command.spawn().map_err(|e| format!("{program}: {e}"))?;
    if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
        let _ = pipe.write_all(text.as_bytes());
    }
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    // Scoped readers: both are joined before this returns, so neither outlives the call.
    let (status, out, err) = std::thread::scope(|scope| {
        let out = scope.spawn(move || read_all(stdout));
        let err = scope.spawn(move || read_all(stderr));
        let deadline = Instant::now() + READER_BOUND;
        let status = loop {
            if child.exited_within(Duration::from_millis(200)).unwrap_or(true) {
                break child.wait().map_err(|e| format!("{program}: {e}"));
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                break Err(format!(
                    "{program} took over {} s and was stopped",
                    READER_BOUND.as_secs()
                ));
            }
        };
        (status, out.join().unwrap_or_default(), err.join().unwrap_or_default())
    });
    let status = status?;
    if status.success() {
        Ok(out)
    } else {
        Err(format!("{program} {}: {}", args.first().unwrap_or(&""), tail(&err, 400)))
    }
}

fn read_all(pipe: Option<impl std::io::Read>) -> String {
    let mut text = String::new();
    if let Some(mut pipe) = pipe {
        let _ = pipe.read_to_string(&mut text);
    }
    text
}

/// The signed-in app's Cloud verbs, each as this binary with `--json`.
pub(super) struct AppCloud<R: Runner> {
    pub runner: R,
}

impl<R: Runner> AppCloud<R> {
    fn verb(&mut self, words: &[&str]) -> Result<Value, String> {
        let mut args: Vec<String> = words.iter().map(|w| (*w).to_owned()).collect();
        args.push("--json".into());
        let ran: Ran = self.runner.cmux(&args);
        step_result(&ran).map_err(|error| {
            error
                .get("message")
                .and_then(Value::as_str)
                .map_or_else(|| error.to_string(), str::to_owned)
        })
    }

    fn target(machine: &str) -> String {
        format!("machine:{machine}")
    }
}

impl<R: Runner> Cloud for AppCloud<R> {
    fn create_machine(
        &mut self,
        name: &str,
        repo: Option<&str>,
        machine_toml: &str,
    ) -> Result<Created, String> {
        let dir = std::env::temp_dir().join(format!("cmux-migrate-{}", std::process::id()));
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let file = dir.join(format!("{name}.machine.toml"));
        std::fs::write(&file, machine_toml).map_err(|e| e.to_string())?;
        let file_arg = file.display().to_string();
        let mut words = vec![
            "cloud",
            "new-machine",
            "--name",
            name,
            "--persistent",
            "--machine-config",
            &file_arg,
        ];
        if let Some(repo) = repo {
            words.extend(["--repo", repo]);
        }
        let made = self.verb(&words);
        let _ = std::fs::remove_file(&file);
        let made = made?;
        if let Some(id) = made.get("machine_id").and_then(Value::as_str)
            && made.get("pending").and_then(Value::as_bool) != Some(true)
        {
            return Ok(Created { machine_id: id.to_owned(), checkout: None, first_chat_ms: None });
        }
        // A slow create: wait for the machine to be listed under its name.
        let deadline = self.runner.now() + CREATE_BOUND;
        while self.runner.now() < deadline {
            let listed = self.verb(&["cloud", "list-machines"])?;
            let id = listed
                .get("machines")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find(|row| row.get("title").and_then(Value::as_str) == Some(name))
                .and_then(|row| row.get("machine_id").and_then(Value::as_str));
            if let Some(id) = id {
                return Ok(Created {
                    machine_id: id.to_owned(),
                    checkout: None,
                    first_chat_ms: None,
                });
            }
            self.runner.pause(Duration::from_secs(5));
        }
        Err(format!(
            "machine {name} was still being made after {} s: run this again once `cmux vm ls` lists it",
            CREATE_BOUND.as_secs()
        ))
    }

    fn deliver_secrets(&mut self, machine: &str, names: &[String]) -> Result<Vec<String>, String> {
        let joined = names.join(",");
        let target = Self::target(machine);
        let answer =
            self.verb(&["cloud", "deliver-secrets", "--target", &target, "--names", &joined])?;
        Ok(answer
            .get("missing")
            .and_then(Value::as_array)
            .map(|m| m.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default())
    }

    /// The text goes through a private (0600) temp file read by `--contents-file`, never as an
    /// argument: argv is visible to every process on this computer (`ps`).
    fn write_file(&mut self, machine: &str, path: &str, text: &str) -> Result<(), String> {
        let target = Self::target(machine);
        let dir = path.rsplit_once('/').map_or("/", |(dir, _)| dir).to_owned();
        self.exec(machine, &format!("mkdir -p {}", shell_quote(&dir)))?;
        let mut send = |to: &str, part: &str| -> Result<(), String> {
            let mut file = tempfile::Builder::new()
                .prefix("cmux-migrate-")
                .tempfile()
                .map_err(|e| format!("a temp file: {e}"))?;
            file.write_all(part.as_bytes()).map_err(|e| format!("a temp file: {e}"))?;
            let local = file.path().display().to_string();
            self.verb(&[
                "cloud",
                "file-write",
                "--target",
                &target,
                "--path",
                to,
                "--contents-file",
                &local,
            ])
            .map(|_| ())
        };
        if text.len() <= WRITE_CHUNK {
            return send(path, text);
        }
        let mut parts = Vec::new();
        let mut rest = text;
        while !rest.is_empty() {
            let mut cut = rest.len().min(WRITE_CHUNK);
            while !rest.is_char_boundary(cut) {
                cut -= 1;
            }
            let part = format!("{path}.cmux-part-{:04}", parts.len());
            send(&part, &rest[..cut])?;
            parts.push(shell_quote(&part));
            rest = &rest[cut..];
        }
        let parts = parts.join(" ");
        self.exec(machine, &format!("cat {parts} > {} && rm -f {parts}", shell_quote(path)))?;
        Ok(())
    }

    fn exec(&mut self, machine: &str, command: &str) -> Result<String, String> {
        let target = Self::target(machine);
        let ran = self.verb(&["cloud", "exec", "--target", &target, "--command", command])?;
        let code = ran.get("exit_code").and_then(Value::as_i64).unwrap_or(0);
        let stdout = ran.get("stdout").and_then(Value::as_str).unwrap_or("").to_owned();
        if code == 0 {
            Ok(stdout)
        } else {
            let stderr = ran.get("stderr").and_then(Value::as_str).unwrap_or("");
            Err(format!("exit {code}: {}", tail(stderr, 400)))
        }
    }

    fn delete_machine(&mut self, machine: &str) -> Result<(), String> {
        let target = Self::target(machine);
        self.verb(&["cloud", "kill-machine", "--target", &target, "--confirm"]).map(|_| ())
    }
}

/// Each machine through `cloud journey --repo --machine-config [--keep]` (no app: CI, Linux). It
/// measures the time to the first chat reply in the machine's checkout; local files do not go.
struct Headless {
    global: GlobalArgs,
    backend: String,
}

const HEADLESS_ONLY: &str = "--headless only makes machines (clone and setup): run without --headless, in the signed-in app, to carry local files";

impl Cloud for Headless {
    fn create_machine(
        &mut self,
        name: &str,
        repo: Option<&str>,
        machine_toml: &str,
    ) -> Result<Created, String> {
        let repo = repo.ok_or("--headless needs a project with a remote to clone")?;
        let dir = std::env::temp_dir().join(format!("cmux-migrate-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let config = dir.join("machine.toml");
        std::fs::write(&config, machine_toml).map_err(|e| e.to_string())?;
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let mut command = cmux_process::Command::new(exe);
        let keep = std::env::var("CMUX_MIGRATE_JOURNEY_DELETE").as_deref() != Ok("1");
        let stub = std::env::var("CMUX_MIGRATE_MODEL_STUB").ok();
        command
            .args(super::cloud_start_chat::forwarded_globals(&self.global))
            .args(headless_journey_args(&self.backend, repo, &dir, &config, keep, stub.as_deref()))
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::inherit());
        let mut child = command.spawn().map_err(|e| e.to_string())?;
        let deadline = Instant::now() + HEADLESS_BOUND;
        while !child.exited_within(Duration::from_secs(1)).unwrap_or(true) {
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "the headless create took over {} s",
                    HEADLESS_BOUND.as_secs()
                ));
            }
        }
        let _ = child.wait();
        let text = std::fs::read_to_string(dir.join("journey.json"))
            .map_err(|e| format!("journey.json: {e}"))?;
        let journey: Value =
            serde_json::from_str(&text).map_err(|e| format!("journey.json: {e}"))?;
        headless_created(&journey)
    }

    /// No keychain here: every name is still to set (`cmux cloud secret set NAME`).
    fn deliver_secrets(&mut self, _: &str, names: &[String]) -> Result<Vec<String>, String> {
        Ok(names.to_vec())
    }
    fn write_file(&mut self, _: &str, _: &str, _: &str) -> Result<(), String> {
        Err(HEADLESS_ONLY.into())
    }
    fn exec(&mut self, _: &str, _: &str) -> Result<String, String> {
        Err(HEADLESS_ONLY.into())
    }
    fn delete_machine(&mut self, machine: &str) -> Result<(), String> {
        Err(format!("--headless cannot delete {machine}: `cmux vm rm {machine}`"))
    }
    fn carries_files(&self) -> bool {
        false
    }
}

/// `cloud journey`'s words for one headless create. `keep` leaves the machine running (a person's
/// move); without it the journey deletes it after the first reply, pass or fail (CI sets
/// `CMUX_MIGRATE_JOURNEY_DELETE=1`, so its runs leave no machines behind).
pub(super) fn headless_journey_args(
    backend: &str,
    repo: &str,
    out: &Path,
    config: &Path,
    keep: bool,
    stub: Option<&str>,
) -> Vec<String> {
    let mut args: Vec<String> = ["cloud", "journey", "--backend", backend, "--repo", repo, "--out"]
        .map(str::to_owned)
        .to_vec();
    args.push(out.display().to_string());
    args.push("--machine-config".into());
    args.push(config.display().to_string());
    if keep {
        args.push("--keep".into());
    }
    if let Some(stub) = stub {
        args.extend(["--model-stub".to_owned(), stub.to_owned()]);
    }
    args
}

/// A kept journey's machine and its time to the first reply: every step's time through `reply`.
pub(super) fn headless_created(journey: &Value) -> Result<Created, String> {
    let steps =
        journey.get("steps").and_then(Value::as_array).ok_or("journey.json has no steps")?;
    let field = |s: &Value, k: &str| s.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
    if let Some(failed) = steps.iter().find(|s| field(s, "status").eq_ignore_ascii_case("fail")) {
        return Err(format!("{}: {}", field(failed, "step"), field(failed, "detail")));
    }
    let machine_id = steps
        .iter()
        .find(|s| field(s, "step") == "create machine")
        .and_then(|s| field(s, "detail").split_whitespace().next().map(str::to_owned))
        .ok_or("the journey made no machine")?;
    let mut total = 0i64;
    let mut replied = false;
    for step in steps {
        total += step.get("ms").and_then(Value::as_i64).unwrap_or(0);
        if field(step, "step") == "reply" {
            replied = true;
            break;
        }
    }
    let checkout = steps
        .iter()
        .find(|s| field(s, "step") == "clone repo")
        .and_then(|s| field(s, "detail").rsplit_once(" in ").map(|(_, path)| path.to_owned()));
    Ok(Created { machine_id, checkout, first_chat_ms: replied.then_some(total) })
}

/// This computer: files under HOME, git through cmux-git.
struct HomeLocal {
    home: PathBuf,
    started: Instant,
    epoch_ms: i64,
}

impl HomeLocal {
    fn new() -> Self {
        let epoch_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX));
        Self { home: home().unwrap_or_default(), started: Instant::now(), epoch_ms }
    }

    fn real(&self, path: &str) -> PathBuf {
        match path.strip_prefix("~/") {
            Some(rest) => self.home.join(rest),
            None => PathBuf::from(path),
        }
    }

    fn plan_path(&self, real: &Path) -> String {
        match real.strip_prefix(&self.home) {
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => real.display().to_string(),
        }
    }

    fn git(&self, checkout: &Path, args: &[&str]) -> Result<String, String> {
        let overrides = cmux_git::filter_overrides(checkout).map_err(|e| e.to_string())?;
        let out = cmux_git::run::run_git_within(
            checkout,
            &overrides,
            args,
            64 << 20,
            Duration::from_secs(60),
        )
        .map_err(|e| format!("git {}: {e}", args.first().unwrap_or(&"")))?;
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

impl HomeLocal {
    /// Unpushed commits and the working tree of a checkout here, against the commit it shares
    /// with its upstream (else the remote's default branch), which the machine checks out first.
    fn local_work_patch(&self, checkout: &str) -> Result<WorkPatch, String> {
        let dir = self.real(checkout);
        let line = |args: &[&str]| {
            self.git(&dir, args).ok().map(|o| o.trim().to_owned()).filter(|o| !o.is_empty())
        };
        let upstream = line(&["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
            .or_else(|| line(&["rev-parse", "--abbrev-ref", "origin/HEAD"]));
        let base = upstream.as_deref().and_then(|up| line(&["merge-base", up, "HEAD"]));
        let branch = line(&["symbolic-ref", "--short", "-q", "HEAD"]);
        let commits = match &base {
            Some(base) => {
                self.git(&dir, &["format-patch", "--stdout", "--binary", &format!("{base}..HEAD")])?
            }
            None => String::new(),
        };
        let mut work = self.git(&dir, &["-c", "core.quotepath=off", "diff", "--binary", "HEAD"])?;
        // Untracked files as new-file diffs written here: git's own route (`add -N`) would touch the real index.
        let untracked = self.git(&dir, &["ls-files", "--others", "--exclude-standard", "-z"])?;
        let mut total = 0u64;
        for path in untracked.split('\0').filter(|p| !p.is_empty()).take(2000) {
            let Ok(meta) = std::fs::metadata(dir.join(path)) else { continue };
            if !meta.is_file()
                || meta.len() > apply::MAX_FILE_BYTES
                || total + meta.len() > apply::MAX_CARRY_BYTES
            {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(dir.join(path)) else { continue };
            total += meta.len();
            work.push_str(&new_file_diff(path, &text));
        }
        Ok(WorkPatch { commits, work, base, branch })
    }
}

impl Local for HomeLocal {
    fn read_text(&self, path: &str, max: u64) -> Option<String> {
        let real = self.real(path);
        let meta = std::fs::metadata(&real).ok()?;
        if !meta.is_file() || meta.len() > max {
            return None;
        }
        String::from_utf8(std::fs::read(real).ok()?).ok()
    }

    fn files(&self, path: &str) -> Vec<(String, u64)> {
        let mut found = Vec::new();
        let mut stack = vec![(self.real(path), 0usize)];
        while let Some((dir, depth)) = stack.pop() {
            let Ok(meta) = std::fs::symlink_metadata(&dir) else { continue };
            if meta.is_file() {
                found.push((self.plan_path(&dir), meta.len()));
                continue;
            }
            // Chat histories go per project (move-chats), never as settings.
            if !meta.is_dir()
                || depth > 6
                || dir
                    .file_name()
                    .is_some_and(|n| n == "projects" || n == "sessions" || n == ".git")
            {
                continue;
            }
            for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
                stack.push((entry.path(), depth + 1));
            }
            if found.len() > 5000 {
                break;
            }
        }
        found
    }

    /// Read where the checkout is: here for a laptop or a folder, over the source's shell for an
    /// SSH host or a codespace ([`apply::patch_route`]).
    fn work_patch(
        &self,
        source: &cmux_migrate::Source,
        project: &str,
        checkout: &str,
    ) -> Result<WorkPatch, String> {
        match apply::patch_route(source, project) {
            PatchRoute::Local => self.local_work_patch(checkout),
            PatchRoute::Remote { program, args } => {
                let args: Vec<&str> = args.iter().map(String::as_str).collect();
                let out = bounded(&program, &args, Some(&apply::remote_patch_script(checkout)))?;
                apply::parse_remote_patch(&out)
            }
            PatchRoute::Unsupported(why) => Err(why),
        }
    }

    fn now_ms(&self) -> i64 {
        self.epoch_ms + i64::try_from(self.started.elapsed().as_millis()).unwrap_or(0)
    }
}

/// A unified diff that adds `path` with `text` (what `git diff` prints for a new file).
pub(super) fn new_file_diff(path: &str, text: &str) -> String {
    let mut out = format!("diff --git a/{path} b/{path}\nnew file mode 100644\n");
    if text.is_empty() {
        return out;
    }
    let lines: Vec<&str> = text.split_inclusive('\n').collect();
    out.push_str(&format!("--- /dev/null\n+++ b/{path}\n@@ -0,0 +1,{} @@\n", lines.len()));
    for line in lines {
        out.push('+');
        out.push_str(line);
        if !line.ends_with('\n') {
            out.push_str("\n\\ No newline at end of file\n");
        }
    }
    out
}

fn tail(text: &str, max: usize) -> String {
    let text = text.trim();
    let skip = text.chars().count().saturating_sub(max);
    text.chars().skip(skip).collect()
}

#[cfg(test)]
#[path = "migrate_tests.rs"]
mod tests;
