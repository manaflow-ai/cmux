//! `cmux pack` for theme packs (`cmux_theme_pack`: a folder with
//! `cmux-pack.json` and its `assets/`, a whole look that loads with no
//! rebuild). Reading, checking and compiling run in process; applying writes
//! the pack's theme file (`themes/pack-OWNER-NAME.json`), which the running
//! app already watches, and then picks it (`appearance.themeFile`) with a
//! settings write sent as `cmux settings` sends it (`cmux theme use` does
//! the same). Undo and redo restore a whole pack, never half of one.
//!
//! - `check DIR`: the values the pack would lose and why, one per line on
//!   stderr, then a summary; exit 1 when it loses any.
//! - `use DIR|NAME [--watch]`: applies the pack (what fails falls back per
//!   key); `--watch` reapplies it on every save in DIR until Ctrl-C.
//! - `edit KEY VALUE`: one look value over the applied pack, as one undo step.
//! - `undo`, `redo`: one generation back or forward.
//! - `off`: every pack off, back to the theme file in use before (undoable).
//! - `history`: the generations, the applied one marked.
//! - `bench DIR [DIR...] [--runs N]`: load, compile and write time, into a
//!   scratch config folder so the look in use never changes.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_config::domains::Domains;
use cmux_config::schema::Schema;
use cmux_config::theme_file;
use cmux_theme_pack::{Context, Pack, PackDiagnostic, Step, Store, StoreError};
use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

pub(super) const USAGE: &str = "\
cmux pack: a whole look (tokens, colors, backgrounds, motion, tabs, fonts, slots) as one folder.
  cmux pack check DIR                       what the pack would lose and why; exit 1 when anything
  cmux pack use DIR|NAME [--watch]          apply it (NAME: a folder in packs/ beside settings);
                                            --watch reapplies it on every save until Ctrl-C
  cmux pack edit KEY VALUE                  one look value over the applied pack, as one undo step
  cmux pack undo | redo                     one whole pack back or forward
  cmux pack off                             every pack off, back to the look before (undoable)
  cmux pack history                         the generations, the applied one marked
  cmux pack bench DIR [DIR...] [--runs N]   load+compile+write time (p50/p95/max), in a scratch folder";

/// Runs `bench` makes when `--runs` is not given.
const DEFAULT_RUNS: usize = 200;
/// A save is often several events: changes this close together are one reload.
const DEBOUNCE: Duration = Duration::from_millis(50);

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Request {
    Check { dir: String },
    Use { spec: String, watch: bool },
    Edit { key: String, value: Value },
    Undo,
    Redo,
    Off,
    History,
    Bench { dirs: Vec<String>, runs: usize },
}

/// A command-line value: JSON when it parses (`true`, `0.8`, `"x"`, `{..}`), else the text.
fn value_arg(text: &str) -> Value {
    serde_json::from_str(text).unwrap_or_else(|_| Value::String(text.to_string()))
}

pub(super) fn parse(args: &[String]) -> Result<Request, String> {
    let usage = || USAGE.to_owned();
    let (verb, rest) = args.split_first().ok_or_else(usage)?;
    let mut positional: Vec<String> = Vec::new();
    let (mut watch, mut runs) = (false, None);
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--watch" if verb == "use" => watch = true,
            "--runs" if verb == "bench" => {
                let text = words.next().ok_or_else(usage)?;
                match text.parse::<usize>() {
                    Ok(count) if count > 0 => runs = Some(count),
                    _ => return Err(format!("--runs takes a positive count, not {text:?}")),
                }
            }
            "-h" | "--help" => return Err(usage()),
            flag if flag.starts_with("--") => {
                return Err(format!("unknown option {flag}\n\n{USAGE}"));
            }
            _ => positional.push(word.clone()),
        }
    }
    Ok(match (verb.as_str(), positional.as_slice()) {
        ("check", [dir]) => Request::Check { dir: dir.clone() },
        ("use", [spec]) => Request::Use { spec: spec.clone(), watch },
        ("edit", [key, value]) => Request::Edit { key: key.clone(), value: value_arg(value) },
        ("undo", []) => Request::Undo,
        ("redo", []) => Request::Redo,
        ("off", []) => Request::Off,
        ("history", []) => Request::History,
        ("bench", [_, ..]) => {
            Request::Bench { dirs: positional.clone(), runs: runs.unwrap_or(DEFAULT_RUNS) }
        }
        _ => return Err(usage()),
    })
}

/// `cmux [global options] pack ...`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, words) = super::parse_globals(args).ok()?;
    let rest = words.split_first().filter(|(scope, _)| *scope == "pack").map(|(_, rest)| rest)?;
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
    if rest.first().is_none_or(|first| matches!(first.as_str(), "-h" | "--help" | "help")) {
        println!("{USAGE}");
        return Some(if rest.is_empty() { 2 } else { 0 });
    }
    let prefix: Vec<String> = args.iter().take_while(|word| *word != "pack").cloned().collect();
    Some(match parse(&rest) {
        Ok(request) => run(&global, &prefix, request),
        Err(message) => {
            eprintln!("{message}");
            2
        }
    })
}

/// Where the app reads: the settings file and the folder beside it.
struct Paths {
    settings: PathBuf,
    config_dir: PathBuf,
}

impl Paths {
    fn current() -> Paths {
        let settings = cmux_config::config_path();
        let config_dir = settings.parent().map(Path::to_path_buf).unwrap_or_default();
        Paths { settings, config_dir }
    }

    /// The settings file as written (`{}` when missing or unreadable).
    fn settings_root(&self) -> Value {
        std::fs::read_to_string(&self.settings)
            .ok()
            .and_then(|text| cmux_config::jsonc::parse(&text).ok())
            .filter(Value::is_object)
            .unwrap_or_else(|| json!({}))
    }

    /// The theme file picked now (`appearance.themeFile`).
    fn in_use(&self) -> Option<String> {
        theme_file::name_in(&self.settings_root()).map(str::to_string)
    }
}

fn fail(global: &GlobalArgs, code: &str, message: String) -> i32 {
    super::wire::print_local_error(&json!({ "code": code, "message": message }), global.output, 1)
}

fn ok(global: &GlobalArgs, value: &Value, text: &str) -> i32 {
    if matches!(global.output, OutputMode::Json | OutputMode::JsonLines) {
        return super::wire::print_local_success(value, global.output);
    }
    println!("{text}");
    0
}

fn store_fail(global: &GlobalArgs, error: &StoreError) -> i32 {
    let code = match error {
        StoreError::Load(_) => "pack.unreadable",
        StoreError::Io(_) => "io",
        StoreError::NothingApplied => "pack.none",
        StoreError::Refused(_) => "pack.refused",
        StoreError::NothingToUndo | StoreError::NothingToRedo => "pack.history_end",
        // `cmux settings` printed its own error; its status is the result.
        StoreError::NotPicked(status) => return *status,
    };
    fail(global, code, error.to_string())
}

/// The `cmux settings` words that pick what `step` applies: its theme file,
/// the one before any pack, or none (as `cmux theme reset` with no key).
fn step_settings_args(step: &Step) -> Vec<&str> {
    match step {
        Step::Apply { theme, .. } | Step::Restore(Some(theme)) => {
            vec!["set", theme_file::SETTING_KEY, theme.as_str()]
        }
        Step::Restore(None) => vec!["reset", theme_file::SETTING_KEY],
    }
}

/// The theme file name `step` picks (`None`: no theme file).
fn step_theme(step: &Step) -> Option<&str> {
    match step {
        Step::Apply { theme, .. } | Step::Restore(Some(theme)) => Some(theme.as_str()),
        Step::Restore(None) => None,
    }
}

/// Picks `step`'s theme file with `cmux settings ARGS...`, sent with this
/// run's global options (`prefix`, the words before `pack`) and quiet, so
/// the pack verb prints the one result. Nothing is sent when the setting
/// already picks it: the app repaints from the file it watches.
fn settings(prefix: &[String], in_use: Option<&str>, step: &Step) -> i32 {
    if in_use == step_theme(step) {
        return 0;
    }
    let mut command: Vec<String> = prefix
        .iter()
        .filter(|word| !matches!(word.as_str(), "--json" | "--jsonl" | "--quiet"))
        .cloned()
        .collect();
    command.push("--quiet".to_string());
    command.push("settings".to_string());
    command.extend(step_settings_args(step).into_iter().map(str::to_string));
    super::run(&command, "")
}

/// The store's pick (`Store::picking`): `settings` with this run's global
/// options, so the store saves the moved history only once the setting moved.
fn picker(prefix: &[String]) -> impl Fn(Option<&str>, &Step) -> Result<(), i32> + Clone + 'static {
    let prefix = prefix.to_vec();
    move |in_use: Option<&str>, step: &Step| match settings(&prefix, in_use, step) {
        0 => Ok(()),
        status => Err(status),
    }
}

fn diagnostics_json(diagnostics: &[PackDiagnostic]) -> Value {
    Value::Array(
        diagnostics
            .iter()
            .map(|d| json!({ "section": d.section, "key": d.key, "message": d.message, "value": d.value, "text": d.display() }))
            .collect(),
    )
}

fn print_problems(diagnostics: &[PackDiagnostic]) {
    for diagnostic in diagnostics {
        eprintln!("{}", diagnostic.display());
    }
}

fn capability_names(pack: &Pack) -> Vec<&'static str> {
    pack.capabilities.iter().map(|capability| capability.name()).collect()
}

fn milliseconds(elapsed: Duration) -> f64 {
    (elapsed.as_secs_f64() * 100_000.0).round() / 100.0
}

/// A pack folder named on the command line, made absolute: the history keeps
/// it, and `edit` and `--watch` read it again from wherever they run.
fn resolve(store: &Store, spec: &str) -> PathBuf {
    let dir = store.resolve(spec);
    dir.canonicalize().unwrap_or(dir)
}

pub(super) fn run(global: &GlobalArgs, prefix: &[String], request: Request) -> i32 {
    let paths = Paths::current();
    // Pruning never removes the theme file the setting picks now, and the
    // store saves a moved history only after `cmux settings` picked its file.
    let store = Store::new(&paths.config_dir).keeping(paths.in_use()).picking(picker(prefix));
    let base = paths.settings_root();
    // Before anything touches the schema, so its first touch is timed cold.
    if let Request::Bench { dirs, runs } = &request {
        return bench(global, &store, dirs, *runs, &base);
    }
    let domains = Domains::default();
    let context = Context { schema: Schema::embedded(), domains: &domains, base: &base };
    match request {
        Request::Check { dir } => check(global, &resolve(&store, &dir), &context),
        Request::Use { spec, watch } => {
            let dir = resolve(&store, &spec);
            let in_use = paths.in_use();
            let started = Instant::now();
            let (pack, step) = match store.apply(&dir, in_use, false, &context) {
                Ok(applied) => applied,
                Err(error) => return store_fail(global, &error),
            };
            let load_ms = milliseconds(started.elapsed());
            print_problems(&pack.diagnostics);
            let code = ok(
                global,
                &json!({
                    "pack": pack.id,
                    "name": pack.name,
                    "dir": pack.dir,
                    "theme": theme_of(&step),
                    "keys": pack.keys(),
                    "capabilities": capability_names(&pack),
                    "diagnostics": diagnostics_json(&pack.diagnostics),
                    "load_ms": load_ms,
                }),
                &format!(
                    "{} ({}) applied in {load_ms} ms: {} values, {} dropped",
                    pack.name,
                    pack.id,
                    pack.keys().len(),
                    pack.diagnostics.len()
                ),
            );
            if !watch {
                return code;
            }
            watch_and_reload(global, prefix, &dir, &paths, &context)
        }
        Request::Edit { key, value } => {
            // A refused edit, or one whose file was not picked, is an error
            // from the store (no step); this one applied and is picked.
            let (pack, step) = match store.edit(&key, value.clone(), &context) {
                Ok(applied) => applied,
                Err(error) => return store_fail(global, &error),
            };
            ok(
                global,
                &json!({ "pack": pack.id, "theme": theme_of(&step), "key": key, "value": value, "applied": true }),
                &format!("{}: {key} = {value}", pack.id),
            )
        }
        Request::Undo => move_step(global, store.undo()),
        Request::Redo => move_step(global, store.redo()),
        Request::Off => move_step(global, store.off()),
        Request::History => history(global, &store),
        Request::Bench { .. } => 0, // answered above, before the context
    }
}

fn check(global: &GlobalArgs, dir: &Path, context: &Context<'_>) -> i32 {
    let pack = match cmux_theme_pack::load(dir, &Map::new(), context) {
        Ok(pack) => pack,
        Err(error) => return fail(global, "pack.unreadable", error.to_string()),
    };
    print_problems(&pack.diagnostics);
    let capabilities = capability_names(&pack);
    let code = i32::from(!pack.diagnostics.is_empty());
    if matches!(global.output, OutputMode::Json | OutputMode::JsonLines) {
        super::wire::print_local_success(
            &json!({
                "id": pack.id,
                "name": pack.name,
                "keys": pack.keys(),
                "capabilities": capabilities,
                "diagnostics": diagnostics_json(&pack.diagnostics),
            }),
            global.output,
        );
    } else {
        println!(
            "{} ({}): {} values, capabilities {}, {} dropped",
            pack.name,
            pack.id,
            pack.keys().len(),
            if capabilities.is_empty() { "none".to_string() } else { capabilities.join(", ") },
            pack.diagnostics.len()
        );
    }
    code
}

/// Undo, redo or off: the store wrote the step's theme file and picked it.
fn move_step(global: &GlobalArgs, result: Result<Step, StoreError>) -> i32 {
    let step = match result {
        Ok(step) => step,
        Err(error) => return store_fail(global, &error),
    };
    let theme = step_theme(&step);
    let (kind, text) = match (&step, theme) {
        (Step::Apply { .. }, Some(theme)) => ("apply", format!("themes/{theme}.json")),
        (_, Some(theme)) => ("restore", format!("back to themes/{theme}.json")),
        (_, None) => ("restore", "back to the stock look".to_string()),
    };
    ok(global, &json!({ "step": kind, "theme": theme }), &text)
}

fn history(global: &GlobalArgs, store: &Store) -> i32 {
    let history = store.history();
    let mark = |index: usize| if index == history.cursor { "*" } else { " " };
    let mut lines = vec![format!(
        "{} 0 before: {}",
        mark(0),
        history
            .before
            .as_deref()
            .map_or("the stock look".to_string(), |name| format!("themes/{name}.json"))
    )];
    let generations: Vec<Value> = history
        .generations
        .iter()
        .enumerate()
        .map(|(index, generation)| {
            lines.push(format!(
                "{} {} {} ({}){}",
                mark(index + 1),
                index + 1,
                generation.pack,
                generation.theme,
                match generation.edits.len() {
                    0 => String::new(),
                    1 => ", 1 edit".to_string(),
                    count => format!(", {count} edits"),
                }
            ));
            json!({
                "pack": generation.pack,
                "theme": generation.theme,
                "dir": generation.dir,
                "edits": generation.edits.len(),
            })
        })
        .collect();
    ok(
        global,
        &json!({ "before": history.before, "cursor": history.cursor, "generations": generations }),
        &lines.join("\n"),
    )
}

/// Whether a watch event can mean a change to the pack's files: not a read
/// (inotify reports every open, and each reload reads the folder). A
/// lost-events report counts.
fn relevant(event: &notify::Result<notify::Event>) -> bool {
    use notify::event::{AccessKind, AccessMode, EventKind};
    let Ok(event) = event else { return true };
    if event.need_rescan() {
        return true;
    }
    match event.kind {
        EventKind::Access(AccessKind::Close(AccessMode::Write)) => true,
        EventKind::Access(_) => false,
        _ => true,
    }
}

/// `use --watch`: reapplies the pack on each save in `dir` (debounced) as a
/// live generation, so saving twenty times is one undo step. While the pack
/// stays applied the theme file name does not change, so no settings write:
/// the app repaints from the file. When the history moved meanwhile (an undo,
/// another pack), the reload is a new step under a new name, picked the way
/// `use` picks it. A pack that cannot be read keeps the last good look.
/// Ctrl-C ends it.
fn watch_and_reload(
    global: &GlobalArgs,
    prefix: &[String],
    dir: &Path,
    paths: &Paths,
    context: &Context<'_>,
) -> i32 {
    use notify::Watcher as _;
    let (send, receive) = mpsc::channel::<notify::Result<notify::Event>>();
    let mut watcher = match notify::recommended_watcher(send) {
        Ok(watcher) => watcher,
        Err(error) => {
            return fail(global, "io", format!("could not watch {}: {error}", dir.display()));
        }
    };
    if let Err(error) = watcher.watch(dir, notify::RecursiveMode::Recursive) {
        return fail(global, "io", format!("could not watch {}: {error}", dir.display()));
    }
    let json = matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    if !json {
        println!("watching {} (Ctrl-C ends)", dir.display());
    }
    let pick = picker(prefix);
    let mut reloads = 0u64;
    loop {
        let Ok(first) = receive.recv() else {
            return fail(global, "io", "the folder watch stopped".to_string());
        };
        let mut changed = relevant(&first);
        while let Ok(more) = receive.recv_timeout(DEBOUNCE) {
            changed |= relevant(&more);
        }
        if !changed {
            continue;
        }
        reloads += 1;
        let started = Instant::now();
        // As `use`: the store picks the step's file when its name changed,
        // and keeps the history where it was when that fails.
        match reload(dir, paths, context, pick.clone()) {
            Ok((pack, _, _)) => {
                let ms = milliseconds(started.elapsed());
                print_problems(&pack.diagnostics);
                if json {
                    println!(
                        "{}",
                        json!({ "reload": reloads, "ms": ms, "diagnostics": pack.diagnostics.len() })
                    );
                } else {
                    println!("reloaded in {ms} ms ({} dropped)", pack.diagnostics.len());
                }
            }
            Err(error) => {
                if json {
                    println!(
                        "{}",
                        json!({ "reload": reloads, "error": error.to_string(), "kept": "last good look" })
                    );
                } else {
                    eprintln!("{error}; keeping the last good look");
                }
            }
        }
    }
}

/// One `--watch` reload: the pack in `dir` as a live generation, with the
/// setting read fresh (an undo or another pack since may have changed what
/// it picks). `pick` picks the step's file (when the name differs) before
/// the history is saved. Returns that setting too.
fn reload(
    dir: &Path,
    paths: &Paths,
    context: &Context<'_>,
    pick: impl Fn(Option<&str>, &Step) -> Result<(), i32> + 'static,
) -> Result<(Pack, Step, Option<String>), StoreError> {
    let in_use = paths.in_use();
    let store = Store::new(&paths.config_dir).keeping(in_use.clone()).picking(pick);
    let (pack, step) = store.apply(dir, in_use.clone(), true, context)?;
    Ok((pack, step, in_use))
}

/// A fresh private folder for `bench` under the temp folder: a new random
/// name, made with no clobber (mode 0700 on unix), never a predictable path
/// and never one that was there before. Removed when it drops.
fn scratch_dir() -> std::io::Result<tempfile::TempDir> {
    let mut builder = tempfile::Builder::new();
    builder.prefix("cmux-pack-bench-");
    // Only this user may read or write the scratch folder, whatever the umask.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        builder.permissions(std::fs::Permissions::from_mode(0o700));
    }
    builder.tempdir()
}

/// The nearest-rank `percent` percentile of sorted `samples`.
fn percentile(samples: &[f64], percent: usize) -> f64 {
    let rank = samples.len().saturating_mul(percent).div_ceil(100).clamp(1, samples.len().max(1));
    samples.get(rank.saturating_sub(1)).copied().unwrap_or(0.0)
}

/// Times `Store::apply` (load, check, compile, write) `runs` times,
/// alternating `dirs`, into a scratch config folder: the user's look and
/// history never change. The first touch of the settings schema is timed
/// apart (`schema_ms`), since a CLI run pays it once.
fn bench(global: &GlobalArgs, store: &Store, dirs: &[String], runs: usize, base: &Value) -> i32 {
    let schema_started = Instant::now();
    let schema = Schema::embedded();
    let schema_ms = milliseconds(schema_started.elapsed());
    let dirs: Vec<PathBuf> = dirs.iter().map(|spec| resolve(store, spec)).collect();
    let scratch = match scratch_dir() {
        Ok(scratch) => scratch,
        Err(error) => {
            return fail(global, "io", format!("{}: {error}", std::env::temp_dir().display()));
        }
    };
    let bench_store = Store::new(scratch.path());
    let domains = Domains::default();
    let context = Context { schema, domains: &domains, base };
    let mut samples = Vec::with_capacity(runs);
    let mut failure = None;
    for dir in dirs.iter().cycle().take(runs) {
        let started = Instant::now();
        match bench_store.apply(dir, None, false, &context) {
            Ok(_) => samples.push(milliseconds(started.elapsed())),
            Err(error) => {
                failure = Some(error);
                break;
            }
        }
    }
    // Only the folder `scratch_dir` made, removed as it drops.
    drop(scratch);
    if let Some(error) = failure {
        return store_fail(global, &error);
    }
    samples.sort_by(f64::total_cmp);
    let (p50, p95) = (percentile(&samples, 50), percentile(&samples, 95));
    let max = samples.last().copied().unwrap_or_default();
    ok(
        global,
        &json!({ "runs": runs, "p50_ms": p50, "p95_ms": p95, "max_ms": max, "schema_ms": schema_ms }),
        &format!(
            "{runs} runs over {} pack(s): p50 {p50} ms, p95 {p95} ms, max {max} ms (schema first touch {schema_ms} ms)",
            dirs.len()
        ),
    )
}

#[cfg(test)]
mod tests;

/// The theme file `step` picks (`null` when it puts back the look before any pack).
fn theme_of(step: &Step) -> Option<&str> {
    match step {
        Step::Apply { theme, .. } => Some(theme),
        Step::Restore(before) => before.as_deref(),
    }
}
