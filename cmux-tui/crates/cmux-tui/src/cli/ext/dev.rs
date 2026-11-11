//! `cmux ext dev [DIR] [--once] [--json]`: one validate, build, reload and
//! load check of an extension folder, then (without `--once`) the same on
//! every save until Ctrl-C, the daemon going away, or the folder going away.
//!
//! The daemon already loads and hot-reloads `<state>/apps/local/<name>`
//! (cmux-tui-core apps/local_reload.rs: only the changed app restarts, and a
//! script that does not load while its views are open is tried in a host of
//! its own and refused, the last good one staying live). `ext dev` adds no
//! loader: it copies the package's files into that folder (only files that
//! changed, each by an atomic rename, the manifest last), waits for the
//! daemon's own reload answer (`apps-changed` with `local-reload`, or
//! `apps-reload-failed`), then mounts the app's view once (`apps-mount`; a
//! preview mount when it is not installed) to learn whether the new script
//! loads and renders, and unmounts it. The daemon says where its local
//! folder is in `apps-list` (`local_dir`).

use std::collections::{BTreeMap, BTreeSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::{Sender, channel};
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use notify::event::{AccessKind, AccessMode, EventKind};
use serde_json::{Value, json};

use super::daemon::{Daemon, Stop, Wake};
use super::{DevOptions, Field as _, exit};
use crate::cli::GlobalArgs;

/// Quiet time after the last file event before a reload starts: an editor's
/// save (write, rename, chmod) and a build tool's burst become one reload.
pub(super) const DEBOUNCE: Duration = Duration::from_millis(120);

/// How long one build may run (`--build-timeout SECS` changes it): a hung
/// build stops with a build error instead of holding the loop.
pub(super) const BUILD_TIMEOUT: Duration = Duration::from_secs(120);

/// How long the daemon may take to pick up a copied change.
const PICKUP_DEADLINE: Duration = Duration::from_secs(10);

/// How long the load check may take (the daemon's own trial waits 5 s).
const PROBE_DEADLINE: Duration = Duration::from_secs(10);

/// Package files copied per reload (a runaway folder costs no more).
const MAX_FILES: usize = 2_000;
const MAX_BYTES: u64 = 64 << 20;

/// Bytes hashed for the folder fingerprint (the loop guard), as the daemon's.
const MAX_HASHED_BYTES: u64 = 4 << 20;

/// The marker `ext dev` leaves in each folder it makes in the local apps
/// folder: a dot file, which the daemon's fingerprint skips. `ext remove`
/// and `--remove-on-exit` delete only folders that have it.
pub(super) const MARKER: &str = ".cmux-ext-dev.json";

/// The packer every sample and first-party app is built with, embedded so an
/// extension folder outside a cmux checkout builds the same way.
const PACK_TS: &str = include_str!("../../../../cmux-app-host/tools/pack.ts");

/// One problem with file and position where known.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct Problem {
    pub file: Option<String>,
    pub line: Option<u64>,
    pub column: Option<u64>,
    /// A JSON pointer into the manifest (manifest problems).
    pub field: Option<String>,
    pub message: String,
}

impl Problem {
    pub(super) fn message(message: impl Into<String>) -> Self {
        Self { message: message.into(), ..Self::default() }
    }

    fn in_file(file: &str, message: impl Into<String>) -> Self {
        Self { file: Some(file.to_string()), message: message.into(), ..Self::default() }
    }

    fn to_json(&self) -> Value {
        json!({
            "file": self.file, "line": self.line, "column": self.column,
            "field": self.field, "message": self.message,
        })
    }

    /// `file:line:column: field: message`, the parts that are known.
    pub(super) fn text(&self) -> String {
        let mut place = self.file.clone().unwrap_or_default();
        for n in [self.line, self.column].into_iter().flatten() {
            place.push_str(&format!(":{n}"));
        }
        if let Some(field) = self.field.as_deref().filter(|f| !f.is_empty()) {
            place = if place.is_empty() { field.to_string() } else { format!("{place} {field}") };
        }
        if place.is_empty() { self.message.clone() } else { format!("{place}: {}", self.message) }
    }
}

/// The stage a reload reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Phase {
    Manifest,
    Build,
    Daemon,
    Reload,
    Load,
    Done,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Phase::Manifest => "manifest",
            Phase::Build => "build",
            Phase::Daemon => "daemon",
            Phase::Reload => "reload",
            Phase::Load => "load",
            Phase::Done => "done",
        }
    }

    fn exit_code(self) -> i32 {
        match self {
            Phase::Done => exit::OK,
            Phase::Manifest => exit::MANIFEST_INVALID,
            Phase::Build => exit::BUILD_FAILED,
            Phase::Daemon => exit::NO_DAEMON,
            Phase::Reload | Phase::Load => exit::LOAD_FAILED,
        }
    }
}

/// A validated extension folder.
#[derive(Debug, Clone)]
pub(super) struct Package {
    pub dir: PathBuf,
    pub manifest: Value,
    pub id: String,
    /// The folder name under the local apps folder (the id's name).
    pub name: String,
}

const V1: &str = "cmux-app.json";
const V2: &str = "cmux-app.v2.json";

/// Validates `dir` with the validator the daemon runs (`cmux-app-manifest`),
/// reading the manifest file the daemon reads for a local folder.
pub(super) fn load_package(dir: &Path) -> Result<Package, Vec<Problem>> {
    let manifest_file = if dir.join(V1).is_file() {
        V1
    } else if dir.join(V2).is_file() {
        V2
    } else {
        return Err(vec![Problem {
            file: Some(V1.into()),
            ..Problem::message(format!(
                "{} has no {V1} (cmux ext new NAME makes one)",
                dir.display()
            ))
        }]);
    };
    let report = cmux_app_manifest::validate_package_file(dir, manifest_file);
    let errors: Vec<Problem> = report
        .issues
        .iter()
        .filter(|issue| issue.severity == cmux_app_manifest::Severity::Error)
        .map(|issue| Problem {
            file: Some(manifest_file.into()),
            field: Some(if issue.path.is_empty() { "/".into() } else { issue.path.clone() }),
            ..Problem::message(format!("{} ({})", issue.message, issue.code))
        })
        .collect();
    if !errors.is_empty() {
        return Err(errors);
    }
    let Some(manifest) = report.manifest else {
        return Err(vec![Problem::message(format!("{manifest_file} did not parse"))]);
    };
    let id = manifest.field("id").as_str().unwrap_or_default().to_string();
    let field = |message: String| Problem {
        file: Some(manifest_file.into()),
        field: Some("/id".into()),
        ..Problem::message(message)
    };
    // The daemon's local folder only holds `local/` apps (catalog.rs), and
    // `local/customize` loads only from the customize folder.
    let Some(name) = id.strip_prefix("local/").map(str::to_string) else {
        return Err(vec![field(format!(
            "{id}: an extension in development is a local/ app; use \"local/{}\"",
            id.split('/').nth(1).unwrap_or("name")
        ))]);
    };
    if name == "customize" {
        return Err(vec![field(
            "local/customize is your customize folder (~/.config/cmux/customize), which cmux already reloads on save; pick another name".into(),
        )]);
    }
    Ok(Package { dir: dir.to_path_buf(), manifest, id, name })
}

/// How the folder is built.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum BuildPlan {
    /// `--build CMD`, run with `sh -c` in the folder.
    Command(String),
    /// `src/main.ts` packed into `dist/main.js` by the embedded packer.
    Pack(PathBuf),
    /// Nothing to build; `note` says why when a source was skipped.
    None { note: Option<String> },
}

/// The plan for `pkg`: `--build`, else the packer when the main script is
/// built from `src/main.ts` and `bun` is at `bun`, else nothing.
pub(super) fn build_plan(pkg: &Package, command: Option<&str>, bun: Option<&Path>) -> BuildPlan {
    if let Some(command) = command {
        return BuildPlan::Command(command.to_string());
    }
    if !pkg.dir.join("src/main.ts").is_file() {
        return BuildPlan::None { note: None };
    }
    match bun {
        Some(bun) => BuildPlan::Pack(bun.to_path_buf()),
        None => BuildPlan::None {
            note: Some("bun is not on PATH: the main script is loaded as it is".into()),
        },
    }
}

/// Runs `plan`, stopped after `deadline`; the problems carry file:line from
/// the tool's output.
pub(super) fn build(
    pkg: &Package,
    plan: &BuildPlan,
    deadline: Duration,
) -> Result<(), Vec<Problem>> {
    let output = match plan {
        BuildPlan::None { .. } => return Ok(()),
        BuildPlan::Command(command) => {
            let mut sh = Command::new("sh");
            sh.arg("-c").arg(command).current_dir(&pkg.dir);
            run_bounded(sh, deadline)
        }
        BuildPlan::Pack(bun) => {
            let packer = tempfile::Builder::new()
                .prefix("cmux-ext-pack")
                .tempdir()
                .and_then(|dir| std::fs::write(dir.path().join("pack.ts"), PACK_TS).map(|()| dir));
            let packer = packer.map_err(|e| vec![Problem::message(format!("packer: {e}"))])?;
            let mut pack = Command::new(bun);
            pack.arg(packer.path().join("pack.ts")).arg(&pkg.dir).current_dir(&pkg.dir);
            run_bounded(pack, deadline)
        }
    };
    let output = match output {
        Ok(Some(output)) => output,
        Ok(None) => {
            return Err(vec![Problem::message(format!(
                "the build ran past {}s and was stopped (--build-timeout SECS allows longer)",
                deadline.as_secs()
            ))]);
        }
        Err(e) => return Err(vec![Problem::message(format!("the build did not start: {e}"))]),
    };
    if output.status.success() {
        return Ok(());
    }
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    Err(build_problems(&text, &pkg.dir))
}

/// One build step's output, or `None` when it ran past `deadline`: then its
/// process group (the step and anything it started) is killed. The step runs
/// in a group of its own, so nothing else is signalled.
fn run_bounded(
    mut command: Command,
    deadline: Duration,
) -> std::io::Result<Option<std::process::Output>> {
    use std::io::Read;
    use std::os::unix::process::CommandExt;
    use std::process::Stdio;
    use wait_timeout::ChildExt;

    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).process_group(0);
    let mut child = command.spawn()?;
    // Both pipes drain while the step runs, so a chatty build never blocks
    // on a full pipe.
    let (sender, receiver) = channel::<(bool, Vec<u8>)>();
    let readers = [
        child.stdout.take().map(|p| (true, Box::new(p) as Box<dyn Read + Send>)),
        child.stderr.take().map(|p| (false, Box::new(p) as Box<dyn Read + Send>)),
    ];
    let mut pending = 0_u8;
    for (is_stdout, mut pipe) in readers.into_iter().flatten() {
        pending = pending.saturating_add(1);
        let sender = sender.clone();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = pipe.read_to_end(&mut bytes);
            let _ = sender.send((is_stdout, bytes));
        });
    }
    drop(sender);
    let status = match child.wait_timeout(deadline)? {
        Some(status) => Some(status),
        None => {
            if let Ok(group) = libc::pid_t::try_from(child.id()) {
                // SAFETY: `group` is the process group this call made for
                // the child it spawned (`process_group(0)`).
                unsafe {
                    libc::killpg(group, libc::SIGKILL);
                }
            }
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    };
    let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
    let started = Instant::now();
    while pending > 0 {
        // A process that left the group may hold a pipe open: wait a moment.
        let left = Duration::from_secs(2).saturating_sub(started.elapsed());
        let Ok((is_stdout, bytes)) = receiver.recv_timeout(left) else { break };
        if is_stdout {
            stdout = bytes;
        } else {
            stderr = bytes;
        }
        pending = pending.saturating_sub(1);
    }
    Ok(status.map(|status| std::process::Output { status, stdout, stderr }))
}

/// The build output's errors with their positions (`path:line[:column]`);
/// the output's last lines when it names none.
pub(super) fn build_problems(text: &str, dir: &Path) -> Vec<Problem> {
    let mut problems = Vec::new();
    let mut message: Option<String> = None;
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) =
            trimmed.strip_prefix("error:").or_else(|| trimmed.strip_prefix("Error:"))
        {
            message = Some(rest.trim().to_string());
        }
        if let Some((file, line_no, column, end)) = position(trimmed) {
            // `path:1:9: message` names its message after the position;
            // `at path:1:9` follows the `error:` line that names it.
            let rest = trimmed.get(end..).unwrap_or("").trim_start_matches(':').trim();
            let rest = rest.trim_start_matches("error:").trim();
            let rest = (!rest.is_empty()).then(|| rest.to_string());
            problems.push(Problem {
                file: Some(relative(&file, dir)),
                line: Some(line_no),
                column,
                field: None,
                message: rest.or_else(|| message.clone()).unwrap_or_else(|| "build error".into()),
            });
        }
    }
    if problems.is_empty() {
        let tail: Vec<&str> = text.lines().rev().take(20).collect();
        let tail: Vec<&str> = tail.into_iter().rev().collect();
        problems.push(Problem::message(if tail.is_empty() {
            "the build failed with no output".to_string()
        } else {
            tail.join("\n")
        }));
    }
    problems
}

/// The first `file.ext:line[:column]` in `text` (js, ts, mjs, json), and
/// where it ends in `text`.
pub(super) fn position(text: &str) -> Option<(String, u64, Option<u64>, usize)> {
    let pattern = regex::Regex::new(
        r"((?:[A-Za-z]:)?[A-Za-z0-9_./@~-]*\.(?:m?[jt]sx?|json)):(\d+)(?::(\d+))?",
    )
    .ok()?;
    let captures = pattern.captures(text)?;
    let file = captures.get(1)?.as_str().to_string();
    let line = captures.get(2)?.as_str().parse().ok()?;
    let column = captures.get(3).and_then(|c| c.as_str().parse().ok());
    Some((file, line, column, captures.get(0)?.end()))
}

fn relative(file: &str, dir: &Path) -> String {
    let path = Path::new(file);
    let canonical = dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf());
    path.strip_prefix(dir)
        .or_else(|_| path.strip_prefix(&canonical))
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| file.to_string())
}

/// A load error (`init: main.js:2:12 SyntaxError ...`) as a problem.
pub(super) fn load_problem(reason: &str) -> Problem {
    let reason = reason.strip_prefix("init: ").unwrap_or(reason);
    match position(reason) {
        Some((file, line, column, _)) => Problem {
            file: Some(file),
            line: Some(line),
            column,
            field: None,
            message: reason.to_string(),
        },
        None => Problem::message(reason),
    }
}

/// Whether a name in the folder is skipped by the watch, the sync and the
/// fingerprint: dot files (editor swaps, the packer's wrapper), backups and
/// node_modules (the daemon's fingerprint skips the same).
pub(super) fn skipped(name: &str) -> bool {
    name.starts_with('.') || name.ends_with('~') || name == "node_modules"
}

/// Every file under `dir` (relative), skipped names left out.
fn walk(dir: &Path, rel: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir.join(rel)) else { return };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(std::fs::DirEntry::file_name);
    for entry in entries {
        if out.len() > MAX_FILES {
            return;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if skipped(&name) {
            continue;
        }
        let path = rel.join(&*name);
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => walk(dir, &path, out),
            // A link is listed too: `package_files` refuses it by name.
            Ok(kind) if kind.is_file() || kind.is_symlink() => out.push(path),
            _ => {}
        }
    }
}

/// The files the daemon needs: the manifest files, the manifest's `files`
/// (a folder entry is everything in it), its main script, catalog, icon and
/// strings. With no `files`, everything but the sources (`src/`, `*.ts`).
/// A symbolic link, or a path out of the folder, is refused by name: the
/// copy in the state folder holds the folder's own files only.
pub(super) fn package_files(pkg: &Package) -> Result<Vec<PathBuf>, Problem> {
    let mut set: BTreeSet<PathBuf> = BTreeSet::new();
    let mut refused: Option<Problem> = None;
    let mut add = |entry: &str| {
        let entry = entry.trim_end_matches('/');
        if let Some(problem) = outside_or_linked(&pkg.dir, Path::new(entry)) {
            refused.get_or_insert(problem);
            return;
        }
        let path = pkg.dir.join(entry);
        if path.is_dir() {
            let mut found = Vec::new();
            walk(&pkg.dir, Path::new(entry), &mut found);
            set.extend(found);
        } else if path.is_file() {
            set.insert(PathBuf::from(entry));
        }
    };
    for file in [V1, V2] {
        add(file);
    }
    let manifest = &pkg.manifest;
    match manifest.get("files").and_then(Value::as_array) {
        Some(files) => files.iter().filter_map(Value::as_str).for_each(&mut add),
        None => {
            let mut found = Vec::new();
            walk(&pkg.dir, Path::new(""), &mut found);
            for path in found {
                let source = path.starts_with("src")
                    || path.extension().is_some_and(|e| e == "ts" || e == "tsx");
                if !source {
                    add(&path.to_string_lossy());
                }
            }
        }
    }
    for pointer in ["/runtime/main", "/catalog", "/icon", "/strings"] {
        if let Some(entry) = manifest.pointer(pointer).and_then(Value::as_str) {
            add(entry);
        }
    }
    if let Some(problem) = refused {
        return Err(problem);
    }
    // A folder entry's walk lists links inside it.
    if let Some(problem) = set.iter().find_map(|rel| outside_or_linked(&pkg.dir, rel)) {
        return Err(problem);
    }
    Ok(set.into_iter().collect())
}

/// Why `rel` may not be copied from `dir`: it leaves the folder (absolute,
/// `..`), or it or a folder on its way is a symbolic link.
fn outside_or_linked(dir: &Path, rel: &Path) -> Option<Problem> {
    use std::path::Component;
    let mut at = dir.to_path_buf();
    for part in rel.components() {
        match part {
            Component::Normal(name) => at.push(name),
            Component::CurDir => continue,
            _ => {
                return Some(Problem::in_file(
                    &rel.to_string_lossy(),
                    "outside the extension folder; list files inside it",
                ));
            }
        }
        if std::fs::symlink_metadata(&at).is_ok_and(|meta| meta.file_type().is_symlink()) {
            return Some(Problem::in_file(
                &rel.to_string_lossy(),
                format!(
                    "a symbolic link (to {}); copy the file into the extension folder",
                    std::fs::read_link(&at).unwrap_or_default().display()
                ),
            ));
        }
    }
    None
}

/// Copies `pkg`'s files into `target`, changed files only, each written to a
/// dot file and renamed into place, the manifests last; removes files the
/// package no longer has. `Ok(true)` when anything changed.
pub(super) fn sync(pkg: &Package, target: &Path) -> Result<bool, Problem> {
    let io = |what: &str, path: &Path, e: std::io::Error| {
        Problem::message(format!("{what} {}: {e}", path.display()))
    };
    claim(pkg, target)?;
    let mut files = package_files(pkg)?;
    if files.len() > MAX_FILES {
        return Err(Problem::message(format!("the package has more than {MAX_FILES} files")));
    }
    // Manifests last: the daemon may read between two renames, and a new
    // manifest naming a script must not land before the script.
    files.sort_by_key(|path| path == Path::new(V1) || path == Path::new(V2));
    let mut changed = false;
    let mut total = 0u64;
    for rel in &files {
        let from = pkg.dir.join(rel);
        let bytes = std::fs::read(&from).map_err(|e| io("cannot read", &from, e))?;
        total += bytes.len() as u64;
        if total > MAX_BYTES {
            return Err(Problem::message(format!("the package is over {} MiB", MAX_BYTES >> 20)));
        }
        let to = target.join(rel);
        if std::fs::read(&to).is_ok_and(|old| old == bytes) {
            continue;
        }
        let parent = to.parent().unwrap_or(target);
        std::fs::create_dir_all(parent).map_err(|e| io("cannot create", parent, e))?;
        let name = to.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let staged = parent.join(format!(".{name}.ext-dev-{}", std::process::id()));
        std::fs::write(&staged, &bytes).map_err(|e| io("cannot write", &staged, e))?;
        std::fs::rename(&staged, &to).map_err(|e| io("cannot write", &to, e))?;
        changed = true;
    }
    let keep: BTreeSet<&PathBuf> = files.iter().collect();
    let mut present = Vec::new();
    walk(target, Path::new(""), &mut present);
    for rel in present.iter().filter(|rel| !keep.contains(rel)) {
        let path = target.join(rel);
        std::fs::remove_file(&path).map_err(|e| io("cannot remove", &path, e))?;
        changed = true;
    }
    Ok(changed)
}

/// Makes `target` this folder's, or refuses one `ext dev` did not make (or
/// made for another folder).
fn claim(pkg: &Package, target: &Path) -> Result<(), Problem> {
    let source = pkg.dir.canonicalize().unwrap_or_else(|_| pkg.dir.clone());
    let marker = target.join(MARKER);
    if target.exists() {
        let Ok(raw) = std::fs::read(&marker) else {
            return Err(Problem::message(format!(
                "{} is already there and cmux ext dev did not make it; move it away or rename this extension's id",
                target.display()
            )));
        };
        let owner = serde_json::from_slice::<Value>(&raw).ok();
        let owner = owner.as_ref().and_then(|v| v.field("source").as_str()).map(PathBuf::from);
        if owner.as_deref() != Some(source.as_path()) {
            return Err(Problem::message(format!(
                "{} is being developed from {}; stop that one, or `cmux ext remove {}` first",
                pkg.id,
                owner.map(|p| p.display().to_string()).unwrap_or_else(|| "another folder".into()),
                pkg.id
            )));
        }
        return Ok(());
    }
    std::fs::create_dir_all(target)
        .map_err(|e| Problem::message(format!("cannot create {}: {e}", target.display())))?;
    let body = json!({ "source": source, "app": pkg.id }).to_string();
    std::fs::write(&marker, body)
        .map_err(|e| Problem::message(format!("cannot write {}: {e}", marker.display())))
}

/// Removes a folder `ext dev` made (it has the marker); `Ok(false)` when
/// there is none.
pub(super) fn remove_made_folder(target: &Path) -> Result<bool, String> {
    if !target.exists() {
        return Ok(false);
    }
    if !target.join(MARKER).is_file() {
        return Err(format!(
            "{} was not made by cmux ext dev; remove the app with `cmux apps remove`",
            target.display()
        ));
    }
    std::fs::remove_dir_all(target)
        .map_err(|e| format!("cannot remove {}: {e}", target.display()))?;
    Ok(true)
}

/// The contents of every file under `dir` (skipped names left out), hashed:
/// a burst that leaves this unchanged since the last reload (the build's own
/// output, a save of the same text) reloads nothing.
pub(super) fn fingerprint(dir: &Path) -> u64 {
    let mut files = Vec::new();
    walk(dir, Path::new(""), &mut files);
    let mut hasher = DefaultHasher::new();
    let mut budget = MAX_HASHED_BYTES;
    for rel in files {
        let path = dir.join(&rel);
        let Ok(meta) = std::fs::metadata(&path) else { continue };
        (&rel, meta.len()).hash(&mut hasher);
        match budget.checked_sub(meta.len()) {
            Some(rest) => {
                budget = rest;
                std::fs::read(&path).unwrap_or_default().hash(&mut hasher);
            }
            None => meta.modified().ok().hash(&mut hasher),
        }
    }
    hasher.finish()
}

/// Where each contribution shows, from the manifest.
fn placements(manifest: &Value, shown: bool) -> Vec<Value> {
    let Some(implements) = manifest.get("implements").and_then(Value::as_object) else {
        return Vec::new();
    };
    implements
        .iter()
        .map(|(interface, entry)| {
            let place = match interface.as_str() {
                "cmux.section/1" => {
                    match entry.pointer("/options/defaultRegion").and_then(Value::as_str) {
                        Some(region) => format!("sidebar, {region} region"),
                        None => "sidebar".into(),
                    }
                }
                "cmux.session.info.section/1" => "the agent pane's Session Info".into(),
                "cmux.pane/1" => "a tab (Open in the Command Palette)".into(),
                "cmux.chat.widget/1" => "chat messages that name the app".into(),
                "cmux.newtab.widget/1" => "the new tab page".into(),
                "cmux.sidebar.rows/1" => "workspace rows in the sidebar".into(),
                other => other.to_string(),
            };
            json!({ "interface": interface, "where": place, "shown": shown })
        })
        .collect()
}

/// The interface the load check mounts: a view that renders with no context.
fn probe_interface(manifest: &Value) -> Option<String> {
    let implements = manifest.get("implements")?.as_object()?;
    let has_export = |name: &str| implements.get(name).and_then(|e| e.get("export")).is_some();
    const PREFERRED: [&str; 5] = [
        "cmux.section/1",
        "cmux.newtab.widget/1",
        "cmux.pane/1",
        "cmux.session.info.section/1",
        "cmux.chat.widget/1",
    ];
    PREFERRED
        .iter()
        .find(|name| has_export(name))
        .map(|name| name.to_string())
        .or_else(|| implements.keys().find(|name| has_export(name)).cloned())
}

/// One reload's result (`--once --json` prints it).
#[derive(Debug, Clone)]
pub(super) struct Outcome {
    pub phase: Phase,
    pub errors: Vec<Problem>,
    pub app: Option<String>,
    pub folder: Option<PathBuf>,
    pub build: Option<&'static str>,
    pub build_note: Option<String>,
    pub build_ms: Option<u128>,
    pub reload_ms: Option<u128>,
    pub changed: bool,
    pub installed: Option<bool>,
    pub placed: Vec<Value>,
    pub probe: Option<String>,
    pub logs: Vec<Value>,
    pub next: Option<String>,
    /// Ctrl-C ended the reload.
    pub interrupted: bool,
}

impl Outcome {
    fn new(phase: Phase) -> Self {
        Self {
            phase,
            errors: Vec::new(),
            app: None,
            folder: None,
            build: None,
            build_note: None,
            build_ms: None,
            reload_ms: None,
            changed: false,
            installed: None,
            placed: Vec::new(),
            probe: None,
            logs: Vec::new(),
            next: None,
            interrupted: false,
        }
    }

    fn failed(mut self, phase: Phase, errors: Vec<Problem>) -> Self {
        self.phase = phase;
        self.errors = errors;
        self
    }

    pub(super) fn ok(&self) -> bool {
        self.phase == Phase::Done
    }

    /// The exit code: the phase that failed, or 130 after Ctrl-C.
    pub(super) fn exit_code(&self) -> i32 {
        if self.interrupted { exit::INTERRUPTED } else { self.phase.exit_code() }
    }

    pub(super) fn to_json(&self, dir: &Path) -> Value {
        json!({
            "ok": self.ok(),
            "phase": self.phase.name(),
            "exitCode": self.exit_code(),
            "app": self.app,
            "dir": dir,
            "installedAt": self.folder,
            "errors": self.errors.iter().map(Problem::to_json).collect::<Vec<_>>(),
            "build": self.build,
            "buildNote": self.build_note,
            "buildMs": self.build_ms,
            "reloadMs": self.reload_ms,
            "changed": self.changed,
            "installed": self.installed,
            "placed": self.placed,
            "probe": self.probe,
            "logs": self.logs,
            "next": self.next,
        })
    }

    /// The one line `ext dev` prints for a reload.
    pub(super) fn line(&self) -> String {
        let errors = || {
            let mut text = String::new();
            for problem in &self.errors {
                text.push_str("\n  ");
                text.push_str(&problem.text().replace('\n', "\n  "));
            }
            text
        };
        match self.phase {
            Phase::Done if !self.changed && self.reload_ms.is_none() => {
                "no change to the files cmux loads".into()
            }
            Phase::Done => {
                let mut line = match self.reload_ms {
                    Some(ms) => format!("reloaded in {ms} ms"),
                    None => "reloaded".into(),
                };
                if let Some(ms) = self.build_ms {
                    line.push_str(&format!(" (build {ms} ms)"));
                }
                if self.installed == Some(false) {
                    line.push_str(", as a preview (not installed)");
                }
                line
            }
            Phase::Manifest => format!("manifest invalid:{}", errors()),
            Phase::Build => format!("build failed:{}", errors()),
            Phase::Daemon => format!("cmux is not reachable:{}", errors()),
            Phase::Reload => format!("not reloaded:{}", errors()),
            Phase::Load => {
                format!("load failed (the last good version stays live):{}", errors())
            }
        }
    }
}

/// The loop's state across reloads.
pub(super) struct Session {
    pub dir: PathBuf,
    pub build: Option<String>,
    pub bun: Option<PathBuf>,
    pub build_timeout: Duration,
    pub daemon: Daemon,
    local_dir: Option<PathBuf>,
    followed: BTreeSet<String>,
    probes: u64,
    /// The last reload's folder and id (for the exit message).
    pub last: Option<(String, PathBuf)>,
    /// The folder's fingerprint right after the last build: what that
    /// reload loaded (its own build output included).
    pub built_print: Option<u64>,
}

impl Session {
    pub(super) fn new(dir: PathBuf, options: &DevOptions, daemon: Daemon) -> Self {
        Self {
            dir,
            build: options.build.clone(),
            bun: options.bun.clone(),
            build_timeout: options.build_timeout,
            daemon,
            local_dir: None,
            followed: BTreeSet::new(),
            probes: 0,
            last: None,
            built_print: None,
        }
    }

    /// Validate, build, copy, wait for the daemon's reload, check the load.
    /// `probe_unchanged`: check the load even when no file changed
    /// (`--once`, and the first reload).
    pub(super) fn reload(&mut self, probe_unchanged: bool) -> Outcome {
        let mut outcome = Outcome::new(Phase::Manifest);
        self.built_print = None;
        let pkg = match load_package(&self.dir) {
            Ok(pkg) => pkg,
            Err(errors) => return outcome.failed(Phase::Manifest, errors),
        };
        outcome.app = Some(pkg.id.clone());
        let plan = build_plan(&pkg, self.build.as_deref(), self.bun.as_deref());
        outcome.build = match &plan {
            BuildPlan::Command(_) => Some("command"),
            BuildPlan::Pack(_) => Some("pack"),
            BuildPlan::None { note } => {
                outcome.build_note = note.clone();
                None
            }
        };
        let started = Instant::now();
        if let Err(errors) = build(&pkg, &plan, self.build_timeout) {
            return outcome.failed(Phase::Build, errors);
        }
        if outcome.build.is_some() {
            outcome.build_ms = Some(started.elapsed().as_millis());
        }
        // The build may have rewritten the manifest or the script.
        let pkg = match load_package(&self.dir) {
            Ok(pkg) => pkg,
            Err(errors) => return outcome.failed(Phase::Manifest, errors),
        };
        self.built_print = Some(fingerprint(&self.dir));
        let gone = |mut outcome: Outcome, stop: Stop| {
            let message = match stop {
                Stop::Gone => "the cmux daemon closed the connection",
                Stop::Interrupted => "interrupted",
                Stop::Timeout => "the cmux daemon did not answer",
            };
            outcome.interrupted = stop == Stop::Interrupted;
            outcome.failed(Phase::Daemon, vec![Problem::message(message)])
        };
        let (local_dir, record) = match self.list(&pkg.id) {
            Ok(found) => found,
            Err(Ok(message)) => {
                return outcome.failed(Phase::Daemon, vec![Problem::message(message)]);
            }
            Err(Err(stop)) => return gone(outcome, stop),
        };
        if let Err(stop) = self.follow(&pkg.id) {
            return gone(outcome, stop);
        }
        let target = local_dir.join(&pkg.name);
        outcome.folder = Some(target.clone());
        self.last = Some((pkg.id.clone(), target.clone()));
        if let Some(stop) = self.daemon.drain() {
            return gone(outcome, stop);
        }
        let _ = self.daemon.take_logs();
        let synced = Instant::now();
        outcome.changed = match sync(&pkg, &target) {
            Ok(changed) => changed,
            Err(problem) => return outcome.failed(Phase::Reload, vec![problem]),
        };
        if outcome.changed {
            match self.pickup(&pkg.id, &target) {
                Ok(Ok(())) => {}
                Ok(Err(problem)) => {
                    outcome.logs = self.daemon.take_logs();
                    return outcome.failed(Phase::Load, vec![problem]);
                }
                Err(Stop::Timeout) => {
                    return outcome.failed(
                        Phase::Reload,
                        vec![Problem::message(format!(
                            "cmux did not reload {} within {} s (is this the daemon the app uses?)",
                            pkg.id,
                            PICKUP_DEADLINE.as_secs()
                        ))],
                    );
                }
                Err(stop) => return gone(outcome, stop),
            }
        }
        // The install state now (the reload may have changed the record).
        let record = match self.list(&pkg.id) {
            Ok((_, record)) => record,
            Err(_) => record,
        };
        let installed =
            record.as_ref().is_some_and(|r| r.field("installed").as_bool() == Some(true));
        let enabled = record.as_ref().is_none_or(|r| r.field("enabled").as_bool() != Some(false));
        let hidden = record.as_ref().is_some_and(|r| r.field("hidden").as_bool() == Some(true));
        outcome.installed = Some(installed);
        outcome.placed = placements(&pkg.manifest, installed && enabled && !hidden);
        if !installed {
            outcome.next = Some(format!(
                "cmux apps install {}   (shows a card in cmux; until then it loads as a preview)",
                pkg.id
            ));
        } else if !enabled {
            outcome.next = Some(format!("{} is turned off in Settings > Apps", pkg.id));
        }
        if outcome.changed || probe_unchanged {
            outcome.probe = probe_interface(&pkg.manifest);
            if let Some(interface) = outcome.probe.clone().filter(|_| enabled) {
                match self.probe(&pkg.id, &interface, !installed) {
                    Ok(Ok(())) => {}
                    Ok(Err(problem)) => {
                        outcome.logs = self.daemon.take_logs();
                        return outcome.failed(Phase::Load, vec![problem]);
                    }
                    Err(Stop::Timeout) => {
                        return outcome.failed(
                            Phase::Load,
                            vec![Problem::message(format!(
                                "{interface} did not render within {} s",
                                PROBE_DEADLINE.as_secs()
                            ))],
                        );
                    }
                    Err(stop) => return gone(outcome, stop),
                }
            }
            outcome.reload_ms = Some(synced.elapsed().as_millis());
        }
        outcome.logs = self.daemon.take_logs();
        outcome.phase = Phase::Done;
        outcome
    }

    /// `apps-list`: the daemon's local folder and the app's record. The
    /// outer error is a message (`Ok`) or a stop (`Err`).
    fn list(&mut self, id: &str) -> Result<(PathBuf, Option<Value>), Result<String, Stop>> {
        let data = self.daemon.call(json!({ "cmd": "apps-list" })).map_err(Err)?.map_err(Ok)?;
        let local_dir = match (&self.local_dir, data.field("local_dir").as_str()) {
            (_, Some(dir)) => PathBuf::from(dir),
            (Some(dir), None) => dir.clone(),
            (None, None) => {
                return Err(Ok(format!(
                    "the running daemon does not say where it loads local apps from (it is older than cmux ext dev, or has no state folder); restart it with this cmux: {}",
                    super::super::fix_command::restart_routed_daemon()
                )));
            }
        };
        self.local_dir = Some(local_dir.clone());
        let record = data
            .field("apps")
            .as_array()
            .into_iter()
            .flatten()
            .find(|row| row.field("id").as_str() == Some(id))
            .cloned();
        Ok((local_dir, record))
    }

    /// Streams the app's log lines (and the supervisor's, which name a
    /// local folder the daemon refused).
    fn follow(&mut self, id: &str) -> Result<(), Stop> {
        for app in [id, "cmux/supervisor"] {
            if self.followed.contains(app) {
                continue;
            }
            // A daemon that refuses a follow still reloads; logs are extra.
            let _ = self.daemon.call(json!({ "cmd": "apps-logs", "app": app, "follow": true }))?;
            self.followed.insert(app.to_string());
        }
        Ok(())
    }

    /// Waits for the daemon's answer to a copied change: its reload of the
    /// app, its refusal of the saved script (an open view keeps the last
    /// good one), or its refusal of the folder.
    fn pickup(&mut self, id: &str, target: &Path) -> Result<Result<(), Problem>, Stop> {
        let folder = target.display().to_string();
        self.daemon.wait(Instant::now() + PICKUP_DEADLINE, |value| {
            let event = value.get("event").and_then(Value::as_str)?;
            let app = value.get("app").and_then(Value::as_str);
            match event {
                "apps-changed"
                    if app == Some(id)
                        && value.field("transaction").as_str() == Some("local-reload") =>
                {
                    Some(Ok(()))
                }
                "apps-reload-failed" if app == Some(id) => {
                    Some(Err(load_problem(value.field("reason").as_str().unwrap_or(""))))
                }
                "apps-log" if app == Some("cmux/supervisor") => {
                    let message = value.field("message").as_str().unwrap_or("");
                    let issue = message.strip_prefix(&folder)?.strip_prefix(": ")?;
                    Some(Err(Problem { file: Some(V1.into()), ..Problem::message(issue) }))
                }
                _ => None,
            }
        })
    }

    /// Mounts `interface` once and waits for its first scene (loaded) or its
    /// failure (the load error); then unmounts it.
    fn probe(
        &mut self,
        id: &str,
        interface: &str,
        preview: bool,
    ) -> Result<Result<(), Problem>, Stop> {
        self.probes += 1;
        let mount_id = format!("ext-dev-probe-{}-{}", std::process::id(), self.probes);
        let mut context = json!({});
        if preview {
            context.set("preview", json!(true));
        }
        let request = self.daemon.send(json!({
            "cmd": "apps-mount", "app": id, "interface": interface,
            "mount_id": mount_id, "context": context,
        }))?;
        let result = self.daemon.wait(Instant::now() + PROBE_DEADLINE, |value| {
            if value.get("id").and_then(Value::as_str) == Some(request.as_str()) {
                if value.field("ok").as_bool() == Some(true) {
                    return None;
                }
                let message = value.field("error").as_str().unwrap_or("the mount was refused");
                return Some(Err(Problem::message(message.to_string())));
            }
            if value.field("mount_id").as_str() != Some(mount_id.as_str()) {
                return None;
            }
            match value.field("event").as_str()? {
                "apps-scene" => Some(Ok(())),
                "apps-mount-failed" => {
                    Some(Err(load_problem(value.field("reason").as_str().unwrap_or(""))))
                }
                _ => None,
            }
        });
        // A failed mount is gone already; the daemon answers that unmount
        // with an error, which changes nothing.
        let _ = self.daemon.call(json!({ "cmd": "apps-unmount", "mount_id": mount_id }));
        result
    }
}

/// The folder watch: one notify watcher whose events (changes only, skipped
/// names left out) wake the loop. No timer and no poll.
pub(super) fn watch(
    dir: &Path,
    sender: Sender<Wake>,
) -> notify::Result<notify::RecommendedWatcher> {
    use notify::Watcher as _;
    let roots: Vec<PathBuf> =
        [Some(dir.to_path_buf()), dir.canonicalize().ok()].into_iter().flatten().collect();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if relevant(&event, &roots) {
            let _ = sender.send(Wake::Files);
        }
    })?;
    watcher.watch(dir, notify::RecursiveMode::Recursive)?;
    Ok(watcher)
}

/// Whether a watch event can mean a change to the extension's files: not a
/// read (inotify reports every open, and a reload reads the folder), not a
/// skipped name. A lost-events report counts.
pub(super) fn relevant(event: &notify::Result<notify::Event>, roots: &[PathBuf]) -> bool {
    let Ok(event) = event else { return true };
    if event.need_rescan() {
        return true;
    }
    match event.kind {
        EventKind::Access(AccessKind::Close(AccessMode::Write)) => {}
        EventKind::Access(_) => return false,
        _ => {}
    }
    event.paths.iter().any(|path| {
        let rel = roots.iter().find_map(|root| path.strip_prefix(root).ok());
        match rel {
            Some(rel) => !rel.components().any(|c| skipped(&c.as_os_str().to_string_lossy())),
            None => false,
        }
    })
}

/// The JSON fields of an extension row for `ext list`.
pub(super) fn list_rows(data: &Value) -> Vec<Value> {
    data.field("apps")
        .as_array()
        .into_iter()
        .flatten()
        .filter(|row| row.field("id").as_str().is_some_and(|id| id.starts_with("local/")))
        .map(|row| {
            json!({
                "app": row.field("id"), "version": row.field("version"),
                "installed": row.field("installed"), "enabled": row.field("enabled"),
                "available": row.field("available"), "folder": row.field("bundle_dir"),
            })
        })
        .collect()
}

/// Groups `ext list` rows by app for the table.
pub(super) fn list_table(rows: &[Value]) -> String {
    let mut by_app: BTreeMap<String, &Value> = BTreeMap::new();
    for row in rows {
        by_app.insert(row.field("app").as_str().unwrap_or("").to_string(), row);
    }
    let width = by_app.keys().map(String::len).max().unwrap_or(3).max(3);
    let mut out = format!("{:width$}  {:9}  {:10}  FOLDER\n", "APP", "VERSION", "STATE");
    for (app, row) in by_app {
        let state = if row.field("installed").as_bool() != Some(true) {
            "preview"
        } else if row.field("enabled").as_bool() == Some(false) {
            "off"
        } else {
            "installed"
        };
        out.push_str(&format!(
            "{app:width$}  {:9}  {state:10}  {}\n",
            row.field("version").as_str().unwrap_or(""),
            row.field("folder").as_str().unwrap_or("")
        ));
    }
    out
}

/// Ctrl-C wakes the loop (the CLI's signal handlers are installed at start).
pub(super) fn arm_interrupt(sender: Sender<Wake>) {
    let _ = std::thread::Builder::new().name("cmux-ext-interrupt".into()).spawn(move || {
        crate::wait_for_shutdown_signal();
        let _ = sender.send(Wake::Interrupt);
    });
}

/// `bun` on PATH.
pub(super) fn find_bun() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|dir| dir.join("bun")).find(|bun| bun.is_file())
}

/// `ext dev --once`: one reload, its result printed; the exit code says how
/// it ended.
pub(super) fn run_once(global: &GlobalArgs, options: &DevOptions, json_out: bool) -> i32 {
    let dir = options.dir.clone();
    let outcome = once(global, options, true);
    if json_out {
        println!("{}", outcome.to_json(&dir));
    } else {
        println!("{}", outcome.line());
        if let Some(next) = &outcome.next {
            println!("next: {next}");
        }
    }
    outcome.exit_code()
}

/// The reload behind `run_once` (tests read it directly, with no Ctrl-C
/// watch: with no signal handler installed it would wake at once).
pub(super) fn once(global: &GlobalArgs, options: &DevOptions, interrupts: bool) -> Outcome {
    // A broken manifest or build needs no daemon to report.
    if let Err(errors) = load_package(&options.dir) {
        return Outcome::new(Phase::Manifest).failed(Phase::Manifest, errors);
    }
    let (sender, wakes) = channel();
    if interrupts {
        arm_interrupt(sender.clone());
    }
    let daemon = match Daemon::connect(global, sender, wakes) {
        Ok(daemon) => daemon,
        Err(message) => {
            let mut outcome = Outcome::new(Phase::Daemon);
            let Ok(pkg) = load_package(&options.dir) else {
                return outcome.failed(Phase::Daemon, vec![Problem::message(message)]);
            };
            outcome.app = Some(pkg.id.clone());
            // With no daemon the build still runs: a broken build is the
            // first thing to fix, and it says so with its own exit code.
            let plan = build_plan(&pkg, options.build.as_deref(), options.bun.as_deref());
            if let Err(errors) = build(&pkg, &plan, options.build_timeout) {
                return outcome.failed(Phase::Build, errors);
            }
            return outcome.failed(Phase::Daemon, vec![Problem::message(message)]);
        }
    };
    Session::new(options.dir.clone(), options, daemon).reload(true)
}

/// `ext dev` without `--once`: reload, then reload on every save.
pub(super) fn run_watch(
    global: &GlobalArgs,
    options: &DevOptions,
    install_argv: Vec<String>,
) -> i32 {
    let dir = options.dir.clone();
    let (sender, wakes) = channel();
    arm_interrupt(sender.clone());
    let _watcher = match watch(&dir, sender.clone()) {
        Ok(watcher) => watcher,
        Err(error) => {
            eprintln!("cmux: cannot watch {}: {error}", dir.display());
            return exit::LOAD_FAILED;
        }
    };
    let daemon = match Daemon::connect(global, sender.clone(), wakes) {
        Ok(daemon) => daemon,
        Err(message) => {
            eprintln!("cmux: {message}");
            return exit::NO_DAEMON;
        }
    };
    let mut session = Session::new(dir.clone(), options, daemon);
    session.daemon.echo_logs = true;
    println!("cmux ext dev: watching {} (Ctrl-C stops)", dir.display());
    let first = session.reload(true);
    println!("{}", first.line());
    if first.interrupted {
        return exit::OK;
    }
    if first.phase == Phase::Daemon {
        return exit::NO_DAEMON;
    }
    if first.installed == Some(false) && options.install {
        if let Some(app) = &first.app {
            ask_install(app, install_argv, sender.clone());
        }
    } else if let Some(next) = &first.next {
        println!("next: {next}");
    }
    let mut print = session.built_print.unwrap_or_else(|| fingerprint(&dir));
    if session.daemon.files_changed {
        let _ = sender.send(Wake::Files);
    }
    let code = loop {
        let stop = match session.daemon.next_wake() {
            None | Some(Wake::DaemonGone) => Some(("the cmux daemon went away", exit::NO_DAEMON)),
            Some(Wake::Interrupt) => Some(("stopped", exit::OK)),
            Some(Wake::Installed(installed)) => {
                super::daemon::print_installed(installed);
                None
            }
            Some(Wake::Daemon(_)) => None,
            Some(Wake::Files) => {
                // Debounce: DEBOUNCE of quiet after the last file event (a
                // deadline only while file events come; log lines and other
                // daemon events do not hold the reload back), then one reload.
                let mut stop = None;
                let mut quiet_at = Instant::now() + DEBOUNCE;
                loop {
                    let left = quiet_at.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        break;
                    }
                    match session.daemon.next_wake_within(left) {
                        None => break,
                        Some(Wake::Files) => quiet_at = Instant::now() + DEBOUNCE,
                        Some(Wake::Interrupt) => stop = Some(("stopped", exit::OK)),
                        Some(Wake::DaemonGone) => {
                            stop = Some(("the cmux daemon went away", exit::NO_DAEMON));
                        }
                        Some(Wake::Installed(installed)) => {
                            super::daemon::print_installed(installed);
                        }
                        Some(Wake::Daemon(_)) => {}
                    }
                    if stop.is_some() {
                        break;
                    }
                }
                if stop.is_none() && !dir.is_dir() {
                    stop = Some(("the extension folder is gone", exit::OK));
                }
                if stop.is_none() && fingerprint(&dir) != print {
                    session.daemon.files_changed = false;
                    let outcome = session.reload(false);
                    println!("{}", outcome.line());
                    if outcome.interrupted {
                        stop = Some(("stopped", exit::OK));
                    } else if outcome.phase == Phase::Daemon {
                        stop = Some(("the cmux daemon went away", exit::NO_DAEMON));
                    }
                    // What this reload loaded, its build's own output
                    // included; a save during the reload differs from it
                    // and reloads again.
                    print = session.built_print.unwrap_or_else(|| fingerprint(&dir));
                    if session.daemon.files_changed {
                        let _ = sender.send(Wake::Files);
                    }
                }
                stop
            }
        };
        if let Some((why, code)) = stop {
            println!("{why}");
            break code;
        }
    };
    if let Some((app, folder)) = &session.last {
        if options.remove_on_exit {
            match remove_made_folder(folder) {
                Ok(_) => println!(
                    "{app} is removed from cmux (its copy in {} is deleted)",
                    folder.display()
                ),
                Err(message) => eprintln!("cmux: {message}"),
            }
        } else {
            println!("{app} stays in cmux (`cmux ext remove {app}` removes it)");
        }
    }
    code
}

/// Asks the person to install `app` with the existing consent flow
/// (`cmux apps install`, a card in cmux), in a child that may wait for them;
/// its end wakes the loop.
fn ask_install(app: &str, mut argv: Vec<String>, sender: Sender<Wake>) {
    let Ok(exe) = std::env::current_exe() else { return };
    argv.extend(["apps".into(), "install".into(), app.into()]);
    println!("asking you to install {app} in cmux (until then it loads as a preview)");
    let child = Command::new(exe)
        .args(argv)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .spawn();
    let Ok(mut child) = child else { return };
    let _ = std::thread::Builder::new().name("cmux-ext-install".into()).spawn(move || {
        let installed = child.wait().is_ok_and(|status| status.success());
        let _ = sender.send(Wake::Installed(installed));
    });
}
