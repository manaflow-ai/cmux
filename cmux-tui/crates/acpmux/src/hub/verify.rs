//! Part of `Hub`; see `hub/mod.rs`. Harness-level verification of every edit (Leo, 2026-11-24:
//! "let's RFD AND FUCKING GOOOOO", harness magic): when a session's edit tool calls complete,
//! the daemon, with no model tokens, waits for [`DEBOUNCE`] after the last edit (and for the
//! turn's tools to be done), runs a fast, bounded, niced check chosen by the touched files'
//! language in the session's folder, and tells the agent only about errors that are NEW.
//!
//! Checks: Rust `cargo check -p <crate>` (past the bound: `rustfmt --check` for syntax errors
//! of the touched files), TS/JS `tsc --noEmit -p` when the project has its own `tsc` (past the
//! bound: `node --check` for plain JS) and `biome check` when configured, Python
//! `py_compile`, shell `bash -n`, JSON and TOML parsed here. Swift and everything else: none.
//!
//! New means not in the baseline: the same check run at the session's first edit of that file
//! or crate (taken when the edit's tool call starts, before it lands). A check whose baseline
//! is missing records its first result as the baseline and says nothing.
//!
//! Delivery: a steer into the running turn (as `touched.rs`'s notice), prefixed `[verify]`,
//! capped at [`MAX_LINES`] lines, once per distinct error set. When no turn runs it waits and
//! rides the next prompt as hidden context. A turn ending with a "builds/tests pass" claim
//! while a check is red gets a `verify_red` verdict in its `claim_checks` (`claim_check.rs`).
//!
//! Off: `agents.harnessMagic.verify.enabled` false, or `ACPMUX_HM_VERIFY=0`. Any failure here
//! leaves the turn as it was. Counters, per turn, on `turn_result`: `harnessMagic.verify.`
//! `runs`, `red`, `notices`, `msTotal`, `skippedSlow`.

use super::*;
use crate::path_canon::canonical_path;
use crate::touched_files as tf;
use regex::Regex;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

pub(crate) const SETTING_ENABLED: &str = "agents.harnessMagic.verify.enabled";
const ENV_OFF: &str = "ACPMUX_HM_VERIFY";
/// Quiet time after the last edit before the check runs.
const DEBOUNCE: Duration = Duration::from_secs(2);
/// How long one check may run.
const BOUND: Duration = Duration::from_secs(20);
/// The longest a run waits for the turn's tools to end.
const MAX_WAIT: Duration = Duration::from_secs(10 * 60);
/// Lines one notice carries, at most.
pub(crate) const MAX_LINES: usize = 30;
const MAX_LINE_CHARS: usize = 240;
const KIND: &str = "verify";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Check {
    Cargo { dir: PathBuf, package: String, files: Vec<PathBuf> },
    Rustfmt { file: PathBuf },
    Tsc { dir: PathBuf, plain_js: Vec<PathBuf> },
    Biome { dir: PathBuf, file: PathBuf },
    Node { file: PathBuf },
    Python { file: PathBuf },
    Bash { file: PathBuf },
    Json { file: PathBuf },
    Toml { file: PathBuf },
}

impl Check {
    /// What a baseline is kept under.
    pub(crate) fn key(&self) -> String {
        match self {
            Self::Cargo { dir, .. } => format!("cargo:{}", dir.display()),
            Self::Tsc { dir, .. } => format!("tsc:{}", dir.display()),
            Self::Biome { file, .. } => format!("biome:{}", file.display()),
            Self::Rustfmt { file } => format!("rustfmt:{}", file.display()),
            Self::Node { file } => format!("node:{}", file.display()),
            Self::Python { file } => format!("py:{}", file.display()),
            Self::Bash { file } => format!("bash:{}", file.display()),
            Self::Json { file } => format!("json:{}", file.display()),
            Self::Toml { file } => format!("toml:{}", file.display()),
        }
    }
}

fn up_find(from: &Path, names: &[&str]) -> Option<PathBuf> {
    let mut dir = from.parent()?;
    loop {
        if names.iter().any(|n| dir.join(n).is_file()) {
            return Some(dir.to_path_buf());
        }
        dir = dir.parent()?;
    }
}

fn package_name(manifest: &Path) -> Option<String> {
    let doc: toml::Value = std::fs::read_to_string(manifest).ok()?.parse().ok()?;
    doc.get("package")?.get("name")?.as_str().map(str::to_owned)
}

/// The checks `files` (absolute paths) call for, each once.
pub(crate) fn plan(files: &[PathBuf]) -> Vec<Check> {
    let mut out: Vec<Check> = vec![];
    let add = |c: Check, out: &mut Vec<Check>| {
        let Some(old) = out.iter_mut().find(|o| o.key() == c.key()) else {
            out.push(c);
            return;
        };
        match (old, c) {
            (Check::Tsc { plain_js, .. }, Check::Tsc { plain_js: more, .. }) => {
                plain_js.extend(more)
            }
            (Check::Cargo { files, .. }, Check::Cargo { files: more, .. }) => files.extend(more),
            _ => {}
        }
    };
    for file in files {
        let ext = file.extension().and_then(|e| e.to_str()).unwrap_or_default();
        let f = file.clone();
        match ext {
            "rs" => {
                let pkg = up_find(file, &["Cargo.toml"])
                    .and_then(|dir| package_name(&dir.join("Cargo.toml")).map(|p| (dir, p)));
                match pkg {
                    Some((dir, package)) => {
                        add(Check::Cargo { dir, package, files: vec![f] }, &mut out)
                    }
                    None => add(Check::Rustfmt { file: f }, &mut out),
                }
            }
            "ts" | "tsx" | "js" | "jsx" | "mjs" | "cjs" | "mts" | "cts" => {
                let plain = matches!(ext, "js" | "mjs" | "cjs");
                let tsc =
                    up_find(file, &["tsconfig.json"]).filter(|d| local_tool(d, "tsc").is_some());
                match tsc {
                    Some(dir) => add(
                        Check::Tsc { dir, plain_js: if plain { vec![f.clone()] } else { vec![] } },
                        &mut out,
                    ),
                    None if plain => add(Check::Node { file: f.clone() }, &mut out),
                    None => {}
                }
                if let Some(dir) = up_find(file, &["biome.json", "biome.jsonc"])
                    && local_tool(&dir, "biome").is_some()
                {
                    add(Check::Biome { dir, file: f }, &mut out);
                }
            }
            "py" => add(Check::Python { file: f }, &mut out),
            "sh" | "bash" => add(Check::Bash { file: f }, &mut out),
            "json" => add(Check::Json { file: f }, &mut out),
            "toml" => add(Check::Toml { file: f }, &mut out),
            _ => {}
        }
    }
    out
}

/// A line or column number; None only if the pattern failed to build (then nothing is blanked).
static POSITION: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)(:|line |column |col |\(|,)\d+").ok());

/// An error line with its positions blanked, so an edit above it does not make it new.
pub(crate) fn normalize(line: &str) -> String {
    let line = line.trim();
    let blanked = match POSITION.as_ref() {
        Some(re) => re.replace_all(line, "${1}N"),
        None => line.into(),
    };
    blanked.chars().take(MAX_LINE_CHARS).collect()
}

/// The error lines of a check's output, by the tool that printed it.
pub(crate) fn error_lines(check: &Check, output: &str) -> Vec<String> {
    let keep = |l: &&str| -> bool {
        let l = l.trim();
        if l.is_empty() {
            return false;
        }
        match check {
            Check::Cargo { .. } => {
                (l.contains("error:") || l.contains("error["))
                    && !l.contains("aborting due to")
                    && !l.contains("could not compile")
            }
            Check::Rustfmt { .. } => l.starts_with("error"),
            Check::Tsc { .. } => l.contains("error TS"),
            Check::Biome { .. } => {
                POSITION.as_ref().is_some_and(|re| re.is_match(l)) && l.contains(" lint/")
                    || l.contains(" parse")
                    || l.contains(" format")
            }
            Check::Node { .. } | Check::Python { .. } => l.contains("Error"),
            Check::Bash { .. } | Check::Json { .. } | Check::Toml { .. } => true,
        }
    };
    output.lines().filter(keep).map(|l| l.trim().to_owned()).collect()
}

/// The lines of `now` whose normal form is not in `baseline`.
pub(crate) fn new_errors(baseline: &BTreeSet<String>, now: &[String]) -> Vec<String> {
    now.iter().filter(|l| !baseline.contains(&normalize(l))).cloned().collect()
}

/// The notice's text for `errors` (capped), None for none.
pub(crate) fn notice_text(errors: &[String], ms: u64) -> Option<String> {
    if errors.is_empty() {
        return None;
    }
    let mut out = format!(
        "[verify] {} new error(s) from the check run after your last edit ({ms} ms; not model-run):",
        errors.len()
    );
    for l in errors.iter().take(MAX_LINES - 2) {
        out.push('\n');
        out.push_str(l);
    }
    if errors.len() > MAX_LINES - 2 {
        out.push_str(&format!("\n... and {} more", errors.len() - (MAX_LINES - 2)));
    }
    Some(out)
}

pub(crate) fn enabled_by(env: Option<&str>, doc: Option<&Value>) -> bool {
    if env == Some("0") {
        return false;
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED))
        .and_then(|v| v.as_bool())
        .unwrap_or(true)
}

fn enabled() -> bool {
    let env = std::env::var(ENV_OFF).ok();
    if env.as_deref() == Some("0") {
        return false;
    }
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => enabled_by(env.as_deref(), Some(&doc)),
        _ => true,
    }
}

// ------------------------------------------------------------------ running

struct Outcome {
    lines: Vec<String>,
    slow: bool,
}

struct Ran {
    text: String,
    /// The bound passed and the check was killed.
    slow: bool,
}

async fn run_cmd(dir: &Path, prog: &str, args: &[&str]) -> Option<Ran> {
    let (dir, prog) = (dir.to_path_buf(), prog.to_owned());
    let args: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
    tokio::task::spawn_blocking(move || run_cmd_blocking(&dir, &prog, &args)).await.ok()?
}

/// The check as its own niced process group, its output in a file (so a long one never fills a
/// pipe), killed with its group past [`BOUND`].
fn run_cmd_blocking(dir: &Path, prog: &str, args: &[String]) -> Option<Ran> {
    let out = tempfile::NamedTempFile::new().ok()?;
    let mut child = cmux_process::Command::new("sh")
        .args(["-c", "f=$1; shift; exec nice -n 10 \"$@\" >\"$f\" 2>&1", "sh"])
        .arg(out.path())
        .arg(prog)
        .args(args)
        .current_dir(dir)
        .env("CARGO_TERM_COLOR", "never")
        .env("NO_COLOR", "1")
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    match child.wait_timeout(BOUND) {
        Ok(Some(_)) => {
            let text = String::from_utf8_lossy(&std::fs::read(out.path()).ok()?).into_owned();
            Some(Ran { text, slow: false })
        }
        Ok(None) => {
            // SAFETY: signals the process group this call made (`process_group(0)`); its pid is
            // not reaped yet, so the id is still this check's.
            #[cfg(unix)]
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL)
            };
            // Windows: no process group signal; the child itself.
            #[cfg(not(unix))]
            let _ = child.kill();
            let _ = child.wait();
            Some(Ran { text: String::new(), slow: true })
        }
        Err(_) => None,
    }
}

fn parent(p: &Path) -> &Path {
    p.parent().unwrap_or(Path::new("/"))
}

fn local_tool(dir: &Path, name: &str) -> Option<PathBuf> {
    let mut d = Some(dir);
    while let Some(p) = d {
        let c = p.join("node_modules/.bin").join(name);
        if c.is_file() {
            return Some(c);
        }
        d = p.parent();
    }
    None
}

/// Syntax errors of `files` only: the fast fallback for a crate whose full check ran out of time.
async fn rustfmt_syntax(files: &[PathBuf]) -> Option<Ran> {
    let mut text = String::new();
    for f in files {
        let r =
            run_cmd(parent(f), "rustfmt", &["--check", "--edition", "2021", &f.to_string_lossy()])
                .await?;
        text.push_str(&r.text);
    }
    Some(Ran { text, slow: false })
}

async fn run_check(
    check: &Check,
    slow_scopes: &mut BTreeSet<String>,
    skip_slow: &BTreeSet<String>,
) -> Option<Outcome> {
    let s = |p: &Path| p.to_string_lossy().into_owned();
    let (ran, as_check): (Ran, Check) = match check {
        Check::Cargo { dir, package, files } => {
            let full = if skip_slow.contains(&check.key()) {
                Ran { text: String::new(), slow: true }
            } else {
                run_cmd(dir, "cargo", &["check", "--message-format", "short", "-q", "-p", package])
                    .await?
            };
            if full.slow {
                slow_scopes.insert(check.key());
                let r = rustfmt_syntax(files).await?;
                let lines = error_lines(&Check::Rustfmt { file: PathBuf::new() }, &r.text);
                return Some(Outcome { lines, slow: true });
            }
            (full, check.clone())
        }
        Check::Rustfmt { file } => (
            run_cmd(parent(file), "rustfmt", &["--check", "--edition", "2021", &s(file)]).await?,
            check.clone(),
        ),
        Check::Tsc { dir, plain_js } => {
            let tsc = local_tool(dir, "tsc")?;
            let r = run_cmd(dir, &s(&tsc), &["--noEmit", "-p", &s(dir)]).await?;
            if r.slow {
                slow_scopes.insert(check.key());
                let mut lines = vec![];
                for f in plain_js {
                    let o = run_cmd(dir, "node", &["--check", &s(f)]).await?;
                    lines.extend(error_lines(&Check::Node { file: f.clone() }, &o.text));
                }
                return Some(Outcome { lines, slow: true });
            }
            (r, check.clone())
        }
        Check::Biome { dir, file } => {
            let bin = local_tool(dir, "biome")?;
            let r = run_cmd(
                dir,
                &s(&bin),
                &["check", "--colors=off", "--max-diagnostics=20", &s(file)],
            )
            .await?;
            (r, check.clone())
        }
        Check::Node { file } => {
            (run_cmd(parent(file), "node", &["--check", &s(file)]).await?, check.clone())
        }
        Check::Python { file } => (
            run_cmd(parent(file), "python3", &["-m", "py_compile", &s(file)]).await?,
            check.clone(),
        ),
        Check::Bash { file } => {
            (run_cmd(parent(file), "bash", &["-n", &s(file)]).await?, check.clone())
        }
        Check::Json { file } => {
            let text = std::fs::read_to_string(file).ok()?;
            let err = serde_json::from_str::<Value>(&text).err().map(|e| e.to_string());
            (Ran { text: err.unwrap_or_default(), slow: false }, check.clone())
        }
        Check::Toml { file } => {
            let text = std::fs::read_to_string(file).ok()?;
            let err = text.parse::<toml::Table>().err().map(|e| {
                let m = e.to_string();
                if m.trim().is_empty() { "TOML parse error".to_owned() } else { m }
            });
            (Ran { text: err.unwrap_or_default(), slow: false }, check.clone())
        }
    };
    if ran.slow {
        return Some(Outcome { lines: vec![], slow: true });
    }
    Some(Outcome { lines: error_lines(&as_check, &ran.text), slow: false })
}

// -------------------------------------------------------------------- state

#[derive(Default)]
struct Counters {
    runs: u64,
    red: u64,
    notices: u64,
    ms_total: u64,
    skipped_slow: u64,
}

#[derive(Default)]
struct State {
    generation: u64,
    pending: BTreeSet<PathBuf>,
    /// Edit tool calls started and not yet ended, by `toolCallId`, with their files.
    calls: BTreeMap<String, Vec<PathBuf>>,
    baselines: BTreeMap<String, BTreeSet<String>>,
    baseline_started: BTreeSet<String>,
    slow: BTreeSet<String>,
    red: BTreeMap<String, Vec<String>>,
    last_sent: Option<u64>,
    held: Option<String>,
    counters: Counters,
}

struct Entry {
    state: StdMutex<State>,
    /// One check of a session at a time, baselines first (the lock is fair).
    serial: tokio::sync::Mutex<()>,
}

static STATES: LazyLock<StdMutex<HashMap<String, Arc<Entry>>>> = LazyLock::new(Default::default);
/// One check per folder at a time across sessions: cargo shares its target directory's lock.
static FOLDERS: LazyLock<StdMutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>> =
    LazyLock::new(Default::default);

fn entry(id: &str) -> Arc<Entry> {
    let mut map = STATES.lock().unwrap_or_else(|e| e.into_inner());
    if map.len() > 1000 {
        map.retain(|_, e| {
            let s = e.state.lock().unwrap_or_else(|e| e.into_inner());
            !s.red.is_empty() || !s.pending.is_empty() || s.held.is_some()
        });
    }
    map.entry(id.to_owned())
        .or_insert_with(|| {
            Arc::new(Entry { state: Default::default(), serial: Default::default() })
        })
        .clone()
}

fn folder_lock(dir: &Path) -> Arc<tokio::sync::Mutex<()>> {
    FOLDERS.lock().unwrap_or_else(|e| e.into_inner()).entry(dir.to_path_buf()).or_default().clone()
}

fn digest(lines: &[String]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    let mut n: Vec<String> = lines.iter().map(|l| normalize(l)).collect();
    n.sort();
    n.hash(&mut h);
    h.finish()
}

/// The turn's counters onto its `turn_result`: what ran since the last one.
pub(super) fn stamp(session_id: &str, msg: &mut serde_json::Map<String, Value>) {
    let Some(e) = STATES.lock().unwrap_or_else(|e| e.into_inner()).get(session_id).cloned() else {
        return;
    };
    let c = std::mem::take(&mut e.state.lock().unwrap_or_else(|e| e.into_inner()).counters);
    if c.runs == 0 && c.skipped_slow == 0 {
        return;
    }
    for (k, v) in [
        ("runs", c.runs),
        ("red", c.red),
        ("notices", c.notices),
        ("msTotal", c.ms_total),
        ("skippedSlow", c.skipped_slow),
    ] {
        msg.insert(format!("harnessMagic.{KIND}.{k}"), json!(v));
    }
}

/// Whether a check of `session_id` is red now (`claim_check.rs`).
pub(super) fn is_red(session_id: &str) -> bool {
    STATES
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(session_id)
        .is_some_and(|e| !e.state.lock().unwrap_or_else(|e| e.into_inner()).red.is_empty())
}

/// The held notice for the next prompt's hidden context, once.
pub(super) fn take_held(session_id: &str) -> Option<String> {
    let e = STATES.lock().unwrap_or_else(|e| e.into_inner()).get(session_id).cloned()?;
    e.state.lock().unwrap_or_else(|e| e.into_inner()).held.take()
}

impl Hub {
    /// One tool call update of the running turn (`stalled_turn.rs` `note_tool_update`).
    pub(super) fn note_verify(self: &Arc<Self>, session: &Arc<Session>, update: &Value) {
        if !matches!(
            update.get("sessionUpdate").and_then(Value::as_str),
            Some("tool_call" | "tool_call_update")
        ) || tokio::runtime::Handle::try_current().is_err()
        {
            return;
        }
        let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or_default();
        let status = update.get("status").and_then(Value::as_str);
        let done = matches!(status, Some("completed" | "failed"));
        let (paths, edited) = tf::paths_of(update);
        let named = edited == Some(true) && !paths.is_empty();
        // A completion update often names neither the kind nor the file: the call's start did.
        let known = !id.is_empty()
            && STATES.lock().unwrap_or_else(|e| e.into_inner()).get(&session.id).is_some_and(|e| {
                e.state.lock().unwrap_or_else(|e| e.into_inner()).calls.contains_key(id)
            });
        if !(named || done && known) {
            return;
        }
        if !enabled() {
            return;
        }
        let cwd = session.meta().cwd.clone();
        let mut files: Vec<PathBuf> =
            paths.iter().filter_map(|p| canonical_path(p, Some(&cwd))).map(PathBuf::from).collect();
        let e = entry(&session.id);
        if !done {
            if files.is_empty() {
                return;
            }
            if !id.is_empty() {
                let mut s = e.state.lock().unwrap_or_else(|e| e.into_inner());
                if s.calls.len() > 256 {
                    s.calls.clear();
                }
                let known = s.calls.entry(id.to_owned()).or_default();
                for f in &files {
                    if !known.contains(f) {
                        known.push(f.clone());
                    }
                }
            }
            self.verify_baseline(e, files);
            return;
        }
        let started =
            e.state.lock().unwrap_or_else(|e| e.into_inner()).calls.remove(id).unwrap_or_default();
        for f in started {
            if !files.contains(&f) {
                files.push(f);
            }
        }
        if files.is_empty() || status == Some("failed") {
            return;
        }
        self.verify_schedule(session, e, files);
    }

    fn verify_schedule(
        self: &Arc<Self>,
        session: &Arc<Session>,
        e: Arc<Entry>,
        files: Vec<PathBuf>,
    ) {
        let generation = {
            let mut s = e.state.lock().unwrap_or_else(|e| e.into_inner());
            s.pending.extend(files);
            s.generation += 1;
            s.generation
        };
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_named("verify-run", async move {
            let started = Instant::now();
            tokio::time::sleep(DEBOUNCE).await;
            loop {
                if e.state.lock().unwrap_or_else(|e| e.into_inner()).generation != generation {
                    return;
                }
                let busy = !session.open_tools.lock().unwrap_or_else(|e| e.into_inner()).is_empty();
                if !busy {
                    break;
                }
                if started.elapsed() > MAX_WAIT {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            hub.verify_run(&session, &e).await;
        });
    }

    async fn verify_run(self: &Arc<Self>, session: &Arc<Session>, e: &Arc<Entry>) {
        let files: Vec<PathBuf> = {
            let mut s = e.state.lock().unwrap_or_else(|e| e.into_inner());
            std::mem::take(&mut s.pending).into_iter().collect()
        };
        let checks = plan(&files);
        if checks.is_empty() {
            return;
        }
        let _serial = e.serial.lock().await;
        let started = Instant::now();
        for check in &checks {
            let skip = e.state.lock().unwrap_or_else(|e| e.into_inner()).slow.clone();
            let mut slow_now = BTreeSet::new();
            let folder = match check {
                Check::Cargo { dir, .. } | Check::Tsc { dir, .. } => Some(dir.clone()),
                _ => None,
            };
            let _folder = match &folder {
                Some(d) => Some(folder_lock(d).lock_owned().await),
                None => None,
            };
            let t = Instant::now();
            let out = run_check(check, &mut slow_now, &skip).await;
            let ms = t.elapsed().as_millis() as u64;
            let mut s = e.state.lock().unwrap_or_else(|e| e.into_inner());
            for k in slow_now {
                s.slow.insert(k);
            }
            let Some(out) = out else { continue };
            if out.slow {
                s.counters.skipped_slow += 1;
            }
            s.counters.runs += 1;
            s.counters.ms_total += ms;
            let key = check.key();
            let Some(base) = s.baselines.get(&key).cloned() else {
                let b = out.lines.iter().map(|l| normalize(l)).collect();
                s.baselines.insert(key, b);
                continue;
            };
            let new = new_errors(&base, &out.lines);
            if new.is_empty() {
                s.red.remove(&key);
            } else {
                s.red.insert(key, new);
            }
        }
        let ms = started.elapsed().as_millis() as u64;
        let all: Vec<String> = {
            let s = e.state.lock().unwrap_or_else(|e| e.into_inner());
            s.red.values().flatten().cloned().collect()
        };
        let text = notice_text(&all, ms);
        let fresh = {
            let mut s = e.state.lock().unwrap_or_else(|e| e.into_inner());
            if all.is_empty() {
                s.last_sent = None;
                s.held = None;
                false
            } else {
                let d = digest(&all);
                s.counters.red += 1;
                let fresh = s.last_sent != Some(d);
                if fresh {
                    s.last_sent = Some(d);
                    s.counters.notices += 1;
                }
                fresh
            }
        };
        if let (true, Some(text)) = (fresh, text) {
            self.verify_deliver(session, e, text);
        }
    }

    fn verify_deliver(self: &Arc<Self>, session: &Arc<Session>, e: &Arc<Entry>, text: String) {
        let steerable = session.steering.load(Ordering::SeqCst);
        let Some(turn) = session.turn().filter(|_| steerable) else {
            e.state.lock().unwrap_or_else(|e| e.into_inner()).held = Some(text);
            return;
        };
        let notice = json!({"sender": "acpmux verify", "severity": "warn", "title": "check failed after your edit"});
        let rendered = crate::prompt_provenance::notice_text(&notice, &text);
        let mut provenance = crate::prompt_provenance::notice(&notice, &session.id);
        if let Some(o) = provenance.as_object_mut() {
            // Hub-set, so it steers into the person's turn as `who_else`'s notice does.
            o.insert("kind".into(), json!(super::touched::NOTICE_KIND));
            o.insert("verify".into(), json!(true));
        }
        let opts = PromptOptions {
            prompt_id: Some(format!("verify-{}-{}", turn.turn_id, uuid::Uuid::now_v7())),
            resend: true,
            steer_only: true,
            interrupt_turn: Some(turn.turn_id.clone()),
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": rendered})];
        let (hub, session, e) = (self.clone(), session.clone(), e.clone());
        self.scope.spawn_named("verify-notice", async move {
            if hub.prompt_with(&session, blocks, "acpmux", true, opts).await.is_err() {
                // Not steered (the turn ended): it rides the next prompt.
                e.state.lock().unwrap_or_else(|e| e.into_inner()).held = Some(text);
            }
        });
    }

    /// Runs the baseline of each check `files` call for that has none, before the edit lands.
    fn verify_baseline(&self, e: Arc<Entry>, files: Vec<PathBuf>) {
        let checks: Vec<Check> = {
            let mut s = e.state.lock().unwrap_or_else(|e| e.into_inner());
            plan(&files).into_iter().filter(|c| s.baseline_started.insert(c.key())).collect()
        };
        if checks.is_empty() {
            return;
        }
        self.scope.spawn_named("verify-baseline", async move {
            let _serial = e.serial.lock().await;
            for check in checks {
                let skip = e.state.lock().unwrap_or_else(|e| e.into_inner()).slow.clone();
                let mut slow_now = BTreeSet::new();
                let _folder = match &check {
                    Check::Cargo { dir, .. } | Check::Tsc { dir, .. } => {
                        Some(folder_lock(dir).lock_owned().await)
                    }
                    _ => None,
                };
                let out = run_check(&check, &mut slow_now, &skip).await;
                let mut s = e.state.lock().unwrap_or_else(|e| e.into_inner());
                s.slow.extend(slow_now);
                if let Some(out) = out {
                    let b = out.lines.iter().map(|l| normalize(l)).collect();
                    s.baselines.insert(check.key(), b);
                }
            }
        });
    }
}

#[cfg(test)]
#[path = "verify_tests.rs"]
mod tests;
