//! `cmux app try .`: copy your nightly and swap your working tree into the copy.
//!
//! Leo (2026-11-18): "people should not need to get dev builds. Stop using dev builds when you can just
//! swap the code into the app. ... just copy your nightly and swap the code into that copy". And: "clone your
//! existing thing, or just have a sort of golden copy of your thing, and then the code comes in, and then I know
//! afterwards I can just get the code out, or I can delete that copy."
//!
//! The golden copy is the installed NIGHTLY (or `--from APP`). Each `cmux app try .` makes a fresh APFS clone
//! of it beside everything else (its own bundle id, data, socket, daemon and settings: the person's cmux is
//! never touched), puts the checkout's web (a dev server, so later saves show live) and Rust (published tree
//! build, else a local cargo build) in, and leaves it running. `--extract` keeps the code that went in (a
//! branch and a patch), `--stop` quits and deletes the clone.
//!
//! The work is the checkout's own `scripts/cmux-next/hot-verify.py run|extract|stop` (with
//! side-instance.sh): the tree being tried brings the scripts. This file names the clone, routes, and prints.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use cmux_json::JsonGet as _;
use cmux_process::Command as Process;
use serde_json::{Value, json};

use super::super::super::{GlobalArgs, OutputMode};

/// The golden copy when no `--from` names one.
pub(super) const DEFAULT_FROM: &str = "/Applications/cmux NIGHTLY.app";
/// The engine in the checkout being tried.
pub(super) const ENGINE: &str = "scripts/cmux-next/hot-verify.py";
/// hot-verify.py's "the change needs a build" exit.
const NEEDS_BUILD: i32 = 3;

/// What `cmux app try .` does with the clone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Action {
    /// A fresh clone of the golden copy, the working tree swapped in, launched.
    Run,
    /// Keep the code that went in: a branch and a patch.
    Extract,
    /// Quit the clone and delete it.
    Stop,
}

/// A word that names a working tree rather than a PR, branch or commit: `dir:PATH`, `.`, `..`, or a path
/// starting `./`, `../`, `/` or `~/` (no branch name starts that way: resolve::classify refuses them).
pub(super) fn dir_target(word: &str, home: Option<&Path>) -> Option<PathBuf> {
    if let Some(path) = word.strip_prefix("dir:") {
        return (!path.is_empty()).then(|| PathBuf::from(path));
    }
    if let Some(rest) = word.strip_prefix("~/") {
        return home.map(|home| home.join(rest));
    }
    let pathish = matches!(word, "." | "..")
        || ["./", "../", "/"].iter().any(|prefix| word.starts_with(prefix));
    pathish.then(|| PathBuf::from(word))
}

/// The clone's side-instance name for checkout `tree`: `try-<folder>-<hash of the path>`, stable, so each run
/// in one checkout replaces its own clone and two checkouts never share one.
pub(super) fn side_name(tree: &Path) -> String {
    let folder =
        tree.file_name().map(|name| name.to_string_lossy().to_lowercase()).unwrap_or_default();
    let mut slug = String::new();
    for c in folder.chars() {
        let c = if c.is_ascii_lowercase() || c.is_ascii_digit() { c } else { '-' };
        if !(c == '-' && slug.ends_with('-')) {
            slug.push(c);
        }
    }
    let mut slug: String = slug.trim_matches('-').chars().take(28).collect();
    while slug.ends_with('-') {
        slug.pop();
    }
    if slug.is_empty() {
        slug.push_str("tree");
    }
    // FNV-1a over the path's bytes: the same checkout always gets the same name, on every build.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in tree.as_os_str().as_encoded_bytes() {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3);
    }
    format!("try-{slug}-{:06x}", hash & 0xff_ffff)
}

/// hot-verify.py's arguments for `action` (dry run: its plan of the tree against the golden copy).
pub(super) fn engine_args(
    action: Action,
    tree: &Path,
    from: &Path,
    side: &str,
    dry_run: bool,
) -> Vec<OsString> {
    let source = || {
        let mut source = OsString::from("dir:");
        source.push(tree);
        source
    };
    let words: Vec<OsString> = match (action, dry_run) {
        (Action::Run, true) => vec![
            "plan".into(),
            "--source".into(),
            source(),
            "--app".into(),
            from.into(),
            "--repo".into(),
            tree.into(),
        ],
        (Action::Run, false) => vec![
            "run".into(),
            "--source".into(),
            source(),
            "--app".into(),
            from.into(),
            "--repo".into(),
            tree.into(),
            "--side".into(),
            side.into(),
            "--label".into(),
            format!("cmux {side}").into(),
        ],
        (Action::Extract, _) => vec!["extract".into(), "--side".into(), side.into()],
        (Action::Stop, _) => vec!["stop".into(), "--side".into(), side.into(), "--remove".into()],
    };
    let mut argv = vec![tree.join(ENGINE).into_os_string()];
    argv.extend(words);
    argv
}

fn messages() -> &'static crate::localization::TryMessages {
    super::messages()
}

/// Runs `cmux app try <tree> [--from APP] [--extract|--stop] [--dry-run]`.
pub(super) fn run(
    global: &GlobalArgs,
    tree: &Path,
    from: Option<&Path>,
    action: Action,
    dry_run: bool,
) -> i32 {
    let messages = messages();
    let Some(tree) = checkout(tree) else {
        return super::failure("try.no_checkout", messages.copy_no_checkout, global.output);
    };
    if !cfg!(target_os = "macos") {
        return elsewhere(global, &tree);
    }
    let from = from.map_or_else(|| PathBuf::from(DEFAULT_FROM), Path::to_path_buf);
    if action == Action::Run && !from.join("Contents/Info.plist").is_file() {
        let text = messages.copy_no_app.replace("{app}", &from.to_string_lossy());
        return super::failure("try.no_app", &text, global.output);
    }
    let side = side_name(&tree);
    let mut process = Process::new("python3");
    process.args(engine_args(action, &tree, &from, &side, dry_run)).current_dir(&tree);
    if let Some(path) =
        super::super::live::tool_path(std::env::var_os("PATH"), std::env::var_os("HOME"))
    {
        process.env("PATH", path);
    }
    if dry_run {
        // The plan alone, as hot-verify.py prints it.
        return match process.status() {
            Ok(status) => status.code().unwrap_or(1),
            Err(error) => cannot_run(global, &error.to_string()),
        };
    }
    // Its log goes to this terminal as it runs; its last stdout line is the result.
    process.stderr(cmux_process::Stdio::inherit());
    let output = match process.output() {
        Ok(output) => output,
        Err(error) => return cannot_run(global, &error.to_string()),
    };
    let code = output.status.code().unwrap_or(1);
    let result = String::from_utf8_lossy(&output.stdout)
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line).ok())
        .unwrap_or(Value::Null);
    let tree_arg = shell_word(&tree.to_string_lossy());
    match action {
        Action::Stop => {
            if code != 0 {
                return super::failure("try.stop_failed", messages.copy_stop_failed, global.output);
            }
            let text = messages.copy_stopped.replace("{side}", &side);
            report(global, &json!({ "side": side, "stopped": true }), &text)
        }
        Action::Extract => {
            if code != 0 || result.is_null() {
                let text = messages.copy_nothing_to_extract.replace("{tree}", &tree_arg);
                return super::failure("try.nothing_to_extract", &text, global.output);
            }
            let text = messages
                .copy_extracted
                .replace("{branch}", result.get_str("branch").unwrap_or_default())
                .replace("{patch}", result.get_str("patch").unwrap_or_default())
                .replace("{count}", &result.get_array("files").len().to_string())
                .replace("{tree}", &tree_arg);
            report(global, &result, &text)
        }
        Action::Run if code == NEEDS_BUILD => needs_build(global, &tree, &side, &result),
        Action::Run if code == 0 && !result.is_null() => {
            let text = running(&result, &from, &tree_arg);
            report(global, &result, &text)
        }
        Action::Run => {
            let errors = result
                .get_array("errors")
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("; ");
            let text = messages.copy_failed.replace("{error}", &errors);
            super::super::super::wire::print_local_error(
                &json!({ "code": "try.copy_failed", "message": text, "result": result }),
                global.output,
                1,
            )
        }
    }
}

fn report(global: &GlobalArgs, value: &Value, text: &str) -> i32 {
    if global.output == OutputMode::Human {
        println!("{text}");
        return 0;
    }
    super::super::super::wire::print_local_success(value, global.output)
}

fn cannot_run(global: &GlobalArgs, error: &str) -> i32 {
    let text = messages().copy_cannot_run.replace("{error}", error);
    super::failure("try.cannot_run", &text, global.output)
}

/// The checkout around `path` that carries the engine.
fn checkout(path: &Path) -> Option<PathBuf> {
    let output = Process::new("git")
        .arg("-C")
        .arg(path)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    let tree = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    let tree = tree.canonicalize().unwrap_or(tree);
    tree.join(ENGINE).is_file().then_some(tree)
}

/// The human summary of a run that went in.
pub(super) fn running(result: &Value, from: &Path, tree_arg: &str) -> String {
    let messages = messages();
    let applied = result.get("applied");
    let mut layers = Vec::new();
    if let Some(web) = applied.and_then(|applied| applied.get("web")) {
        layers.push(if web.get_str("how") == Some("dev server") {
            messages.copy_layer_web_live
        } else {
            messages.copy_layer_web
        });
    }
    if applied.and_then(|applied| applied.get("rust")).is_some() {
        layers.push(messages.copy_layer_rust);
    }
    let layers =
        if layers.is_empty() { messages.copy_no_layers.to_owned() } else { layers.join(", ") };
    let socket = result.get_str("socket").unwrap_or_default();
    let seconds = result
        .get("edit_to_live_s")
        .and_then(Value::as_f64)
        .map(|s| format!("{s:.1}"))
        .unwrap_or_else(|| "0".to_owned());
    messages
        .copy_running
        .replace("{from}", &from.to_string_lossy())
        .replace("{copy}", result.get_str("copy").unwrap_or_default())
        .replace("{socket}", &shell_word(socket))
        .replace("{layers}", &layers)
        .replace("{seconds}", &seconds)
        .replace("{tree}", tree_arg)
}

/// A change a copy of the NIGHTLY cannot take: why, and the build that can, which never runs on this Mac.
/// Hook: when the Swift binary swap (the app's executable and frameworks put into the copy and re-sealed)
/// lands, the Swift reasons route there before the dev build is offered.
fn needs_build(global: &GlobalArgs, tree: &Path, side: &str, result: &Value) -> i32 {
    let text = needs_build_text(result, &head_of(tree), side, &tree.to_string_lossy());
    super::super::super::wire::print_local_error(
        &json!({ "code": "try.needs_build", "message": text, "plan": result.get("plan") }),
        global.output,
        NEEDS_BUILD,
    )
}

pub(super) fn needs_build_text(result: &Value, head: &str, side: &str, tree: &str) -> String {
    let messages = messages();
    let mut text = messages.copy_needs_build.replace("{tree}", tree);
    let build = result.get("plan").and_then(|plan| plan.get("build")).and_then(Value::as_object);
    let mut swift = false;
    for (why, paths) in build.into_iter().flatten() {
        swift |= why.starts_with("Swift");
        let paths = paths.as_array().map(Vec::as_slice).unwrap_or_default();
        let mut shown =
            paths.iter().filter_map(Value::as_str).take(5).collect::<Vec<_>>().join(", ");
        if paths.len() > 5 {
            shown.push_str(", ...");
        }
        text.push_str(&format!("\n  - {why}: {shown}"));
    }
    if swift {
        text.push('\n');
        text.push_str(messages.copy_swift);
    }
    text.push('\n');
    text.push_str(&messages.copy_dev_build.replace("{head}", head).replace("{side}", side));
    text
}

fn head_of(tree: &Path) -> String {
    git_line(tree, &["rev-parse", "HEAD"]).unwrap_or_else(|| "HEAD".to_owned())
}

fn git_line(tree: &Path, args: &[&str]) -> Option<String> {
    let output = Process::new("git").arg("-C").arg(tree).args(args).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// Not a Mac (a Linux agent host, a lane VM): no app to copy here. Says the fleet route, whether the tree
/// must be pushed first, and prints the plan of the tree (no app: against its merge base).
fn elsewhere(global: &GlobalArgs, tree: &Path) -> i32 {
    let messages = messages();
    let dirty = git_line(tree, &["status", "--porcelain"]).is_some_and(|out| !out.is_empty());
    let ahead = git_line(tree, &["rev-list", "--count", "@{upstream}..HEAD"])
        .and_then(|count| count.parse::<u32>().ok());
    let mut text = messages.copy_elsewhere.to_owned();
    if let Some(why) = unpushed(dirty, ahead) {
        text.push('\n');
        text.push_str(why);
    }
    if global.output != OutputMode::Human {
        return super::super::super::wire::print_local_error(
            &json!({ "code": "try.no_mac", "message": text }),
            global.output,
            2,
        );
    }
    println!("{text}");
    let _ = Process::new("python3")
        .arg(tree.join(ENGINE))
        .args(["plan", "--source"])
        .arg({
            let mut source = OsString::from("dir:");
            source.push(tree);
            source
        })
        .args(["--app", "/nonexistent/hot-verify-no-app", "--repo"])
        .arg(tree)
        .current_dir(tree)
        .status();
    2
}

/// Why the tree must be pushed before the fleet can see it, if it must.
pub(super) fn unpushed(dirty: bool, ahead: Option<u32>) -> Option<&'static str> {
    let messages = messages();
    if dirty {
        return Some(messages.copy_push_uncommitted);
    }
    match ahead {
        None => Some(messages.copy_push_no_upstream),
        Some(0) => None,
        Some(_) => Some(messages.copy_push_ahead),
    }
}

/// `word` as one shell word (single-quoted when it needs it).
pub(super) fn shell_word(word: &str) -> String {
    if !word.is_empty()
        && word.bytes().all(|b| b.is_ascii_alphanumeric() || b"/._-+:@%,=".contains(&b))
    {
        return word.to_owned();
    }
    format!("'{}'", word.replace('\'', r"'\''"))
}
