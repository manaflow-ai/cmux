//! Sharing extensions: `cmux ext add SOURCE` installs one from a git URL, a shared link or a
//! folder; `cmux ext share [DIR]` prints the link that installs yours; `cmux ext search [QUERY]`
//! lists the ones people tagged on GitHub (docs/cmux-next/extensions/dev-loop.md, "Share it").
//!
//! `ext add` adds no loader: it fetches the source (`source.rs`), then runs the reload
//! `ext dev --once` runs on the fetched folder (validate with the daemon's own validator, copy into
//! the local apps folder, wait for the daemon's reload, mount once), records where it came from in
//! the copy's marker, and asks the person to install it through the existing consent card
//! (`cmux apps install`). Until they confirm it loads as a preview, as `ext dev` does.
//!
//! A fetched extension is never built here: a build would run a stranger's tooling on this Mac
//! (the packer's macros run code). The repository must hold its built main script, which
//! `ext share` checks before printing a link.

use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_cloud_start_core::machine_repo;
use serde_json::{Value, json};

use super::dev::{self, Outcome};
use super::source::{self, Source};
use super::{DevOptions, Field as _, exit};
use crate::cli::GlobalArgs;

/// The GitHub topic `ext share` asks for and `ext search` lists.
pub(super) const TOPIC: &str = "cmux-extension";

// timeout: one search request to GitHub's API; past it the search fails with the reason.
const SEARCH_TIMEOUT: Duration = Duration::from_secs(20);

/// `ext add`'s options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct AddOptions {
    pub source: String,
    /// Ask the person to install it (the consent card) once it loads.
    pub install: bool,
}

/// Where an added extension came from, as its marker records it.
fn origin_json(repo: &machine_repo::Repo, fetched: &source::Fetched) -> Value {
    json!({
        "url": repo.url(),
        "ref": fetched.reference,
        "path": fetched.subdir,
        "commit": fetched.commit,
        "link": share_link(repo, &fetched.commit, fetched.subdir.as_deref()),
    })
}

/// Adds `origin` to the marker of the copy `ext dev`'s reload made in `folder`.
pub(super) fn record_origin(folder: &Path, origin: &Value) -> Result<(), String> {
    let marker = folder.join(dev::MARKER);
    let mut body: Value = std::fs::read(&marker)
        .ok()
        .and_then(|raw| serde_json::from_slice(&raw).ok())
        .unwrap_or_else(|| json!({}));
    if let Some(object) = body.as_object_mut() {
        object.insert("origin".into(), origin.clone());
    }
    std::fs::write(&marker, body.to_string())
        .map_err(|err| format!("cannot write {}: {err}", marker.display()))
}

/// The origin a copy's marker records, if `ext add` made it.
pub(super) fn recorded_origin(folder: &Path) -> Option<Value> {
    let raw = std::fs::read(folder.join(dev::MARKER)).ok()?;
    let body: Value = serde_json::from_slice(&raw).ok()?;
    body.get("origin").filter(|origin| origin.is_object()).cloned()
}

/// The fetched folder and its origin, or the exit code of a failure already printed.
fn fetch_source(raw: &str, json_out: bool) -> Result<(PathBuf, Option<Value>), i32> {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let fail = |message: String, code: i32| {
        if json_out {
            println!(
                "{}",
                json!({ "ok": false, "phase": "fetch", "exitCode": code, "errors": [{ "message": message }] })
            );
        } else {
            eprintln!("cmux: {message}");
        }
        code
    };
    match source::parse(raw, &cwd) {
        Err(message) => Err(fail(message, exit::USAGE)),
        Ok(Source::Folder(dir)) if dir.is_dir() => Ok((dir, None)),
        Ok(Source::Folder(dir)) => {
            Err(fail(format!("{} is not a folder", dir.display()), exit::USAGE))
        }
        Ok(Source::Git { repo, tail, subdir }) => {
            let Some(cache) = source::user_cache() else {
                return Err(fail(
                    "HOME is not set, so there is no cache to clone into".into(),
                    exit::FETCH_FAILED,
                ));
            };
            let clone = source::cache_dir(&cache, &repo);
            if !json_out {
                eprintln!("fetching {} ...", repo.display());
            }
            match source::fetch(&repo.url(), &tail, subdir.as_deref(), &clone) {
                Ok(fetched) => {
                    let origin = origin_json(&repo, &fetched);
                    Ok((fetched.dir, Some(origin)))
                }
                Err(message) => Err(fail(message, exit::FETCH_FAILED)),
            }
        }
    }
}

/// `ext add SOURCE`.
pub(super) fn run_add(
    global: &GlobalArgs,
    options: &AddOptions,
    globals: &[String],
    json_out: bool,
) -> i32 {
    let (dir, origin) = match fetch_source(&options.source, json_out) {
        Ok(found) => found,
        Err(code) => return code,
    };
    let local = origin.is_none();
    let dev_options = DevOptions {
        dir: dir.clone(),
        once: true,
        remove_on_exit: false,
        install: false,
        build: None,
        build_timeout: dev::BUILD_TIMEOUT,
        // A folder of your own builds as `ext dev` builds it; a fetched one never builds.
        bun: if local { dev::find_bun() } else { None },
    };
    let mut outcome = dev::once(global, &dev_options, true);
    if let (true, Some(folder), Some(origin)) = (outcome.ok(), &outcome.folder, &origin)
        && let Err(message) = record_origin(folder, origin)
    {
        outcome.logs.push(json!({ "level": "warn", "message": message }));
    }
    let (text, code) = report(&outcome, &dir, origin.as_ref(), json_out);
    println!("{text}");
    if code == exit::OK
        && !json_out
        && options.install
        && outcome.installed == Some(false)
        && let Some(app) = &outcome.app
    {
        return ask_install(app, globals);
    }
    code
}

/// What `ext add` prints and exits with.
pub(super) fn report(
    outcome: &Outcome,
    dir: &Path,
    origin: Option<&Value>,
    json_out: bool,
) -> (String, i32) {
    let code = outcome.exit_code();
    if json_out {
        let mut value = outcome.to_json(dir);
        if let Some(object) = value.as_object_mut() {
            object.insert("from".into(), origin.cloned().unwrap_or(Value::Null));
        }
        return (value.to_string(), code);
    }
    let mut text = outcome.line();
    if let Some(origin) = origin.filter(|_| outcome.ok()) {
        let commit = origin.field("commit").as_str().unwrap_or("");
        text.push_str(&format!(
            "\nadded {} from {} at {}",
            outcome.app.as_deref().unwrap_or("the extension"),
            origin.field("url").as_str().unwrap_or(""),
            commit.get(..commit.len().min(12)).unwrap_or(commit)
        ));
    }
    if !outcome.scene.is_empty() {
        text.push_str("\nrendered:");
        for line in &outcome.scene {
            text.push_str("\n  ");
            text.push_str(line);
        }
    }
    if outcome.ok() {
        let app = outcome.app.as_deref().unwrap_or("local/NAME");
        text.push_str(&format!("\nadd it again to update it; cmux ext remove {app} removes it"));
    }
    (text, code)
}

/// The global words for a child `cmux`, without an output mode (the child prints its own).
fn child_globals(globals: &[String]) -> Vec<String> {
    globals
        .iter()
        .filter(|word| !matches!(word.as_str(), "--json" | "--jsonl" | "--quiet"))
        .cloned()
        .collect()
}

/// Asks the person to install `app` with the existing consent card, and waits for their answer.
fn ask_install(app: &str, globals: &[String]) -> i32 {
    let Ok(exe) = std::env::current_exe() else {
        println!("next: cmux apps install {app}");
        return exit::OK;
    };
    println!("asking you to install {app} in cmux (until then it loads as a preview)");
    let mut argv = child_globals(globals);
    argv.extend(["apps".into(), "install".into(), app.into()]);
    match cmux_process::Command::new(exe).args(argv).status() {
        Ok(status) => status.code().unwrap_or(1),
        Err(_) => {
            println!("next: cmux apps install {app}");
            exit::OK
        }
    }
}

/// The link that installs the extension at `commit`: a GitHub folder link, or `URL@COMMIT#PATH`.
pub(super) fn share_link(repo: &machine_repo::Repo, commit: &str, subdir: Option<&str>) -> String {
    if repo.is_github() {
        let mut link = format!("https://github.com/{}/{}/tree/{commit}", repo.owner, repo.name);
        if let Some(path) = subdir {
            link.push('/');
            link.push_str(path);
        }
        return link;
    }
    let url = repo.url();
    let mut link = format!("{}@{commit}", url.strip_suffix(".git").unwrap_or(&url));
    if let Some(path) = subdir {
        link.push('#');
        link.push_str(path);
    }
    link
}

/// What keeps a folder from being shared, and notes that do not.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct ShareCheck {
    pub link: Option<String>,
    pub blocking: Vec<String>,
    pub notes: Vec<String>,
}

/// Checks `dir` and makes its link: a valid manifest, in a git repository with an origin that
/// `ext add` can read, at a commit that is pushed, with the built main script committed.
pub(super) fn check_share(dir: &Path) -> Result<ShareCheck, Vec<dev::Problem>> {
    let pkg = dev::load_package(dir)?;
    let mut check = ShareCheck::default();
    let git = |args: &[&str]| source::git(Some(dir), args);
    let Ok(top) = git(&["rev-parse", "--show-toplevel"]) else {
        check.blocking.push(
            "not in a git repository: git init, commit, push it to GitHub, then run cmux ext share again".into(),
        );
        return Ok(check);
    };
    let top = PathBuf::from(top);
    let here = dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf());
    let top = top.canonicalize().unwrap_or(top);
    let subdir = here
        .strip_prefix(&top)
        .ok()
        .map(|rel| rel.to_string_lossy().into_owned())
        .filter(|rel| !rel.is_empty());
    let repo = match git(&["remote", "get-url", "origin"]) {
        Err(_) => {
            check
                .blocking
                .push("no origin remote: push the repository (to GitHub, for search) first".into());
            None
        }
        Ok(origin) => match machine_repo::parse(&origin) {
            Ok(repo) => Some(repo),
            Err(_) => {
                check.blocking.push(format!(
                    "origin {origin} is not a GitHub repository or an https git URL, so cmux ext add cannot fetch it"
                ));
                None
            }
        },
    };
    let commit = git(&["rev-parse", "HEAD"]).ok();
    if commit.is_none() {
        check.blocking.push("no commit yet: commit the extension first".into());
    }
    let pushed = git(&["branch", "-r", "--contains", "HEAD"]).is_ok_and(|out| !out.is_empty());
    if commit.is_some() && !pushed {
        check
            .blocking
            .push("this commit is not pushed: git push, then run cmux ext share again".into());
    }
    let main =
        pkg.manifest.pointer("/runtime/main").and_then(Value::as_str).unwrap_or("dist/main.js");
    if git(&["ls-files", "--error-unmatch", "--", main]).is_err() {
        check.blocking.push(format!(
            "{main} is not committed: an added extension is never built, so commit the built script (cmux ext dev writes it)"
        ));
    }
    if git(&["status", "--porcelain", "--", "."]).is_ok_and(|out| !out.is_empty()) {
        check
            .notes
            .push("there are uncommitted changes here; the link installs the last commit".into());
    }
    if repo.as_ref().is_some_and(machine_repo::Repo::is_github) {
        check.notes.push(format!(
            "add the topic {TOPIC} to the GitHub repository so cmux ext search lists it"
        ));
    }
    if let (Some(repo), Some(commit)) = (&repo, &commit) {
        check.link = Some(share_link(repo, commit, subdir.as_deref()));
    }
    Ok(check)
}

/// `ext share [DIR]`.
pub(super) fn run_share(dir: &Path, json_out: bool) -> i32 {
    let check = match check_share(dir) {
        Ok(check) => check,
        Err(errors) => {
            let texts: Vec<String> = errors.iter().map(dev::Problem::text).collect();
            if json_out {
                println!(
                    "{}",
                    json!({ "ok": false, "exitCode": exit::MANIFEST_INVALID, "errors": texts })
                );
            } else {
                eprintln!("manifest invalid:\n  {}", texts.join("\n  "));
            }
            return exit::MANIFEST_INVALID;
        }
    };
    let ok = check.blocking.is_empty() && check.link.is_some();
    let code = if ok { exit::OK } else { exit::NOT_SHAREABLE };
    if json_out {
        let add = check.link.as_ref().map(|link| format!("cmux ext add {link}"));
        println!(
            "{}",
            json!({ "ok": ok, "exitCode": code, "link": check.link, "add": add,
                    "blocking": check.blocking, "notes": check.notes })
        );
        return code;
    }
    if let Some(link) = &check.link {
        println!("{link}");
        println!("anyone installs it with: cmux ext add {link}");
    }
    for problem in &check.blocking {
        println!("not shareable yet: {problem}");
    }
    for note in &check.notes {
        println!("note: {note}");
    }
    code
}

/// The rows of a GitHub repository search answer.
pub(super) fn search_rows(answer: &Value) -> Vec<Value> {
    answer
        .field("items")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let name = item.field("full_name").as_str()?;
            Some(json!({
                "name": name,
                "description": item.field("description").as_str().unwrap_or(""),
                "stars": item.field("stargazers_count").as_u64().unwrap_or(0),
                "url": item.field("html_url"),
                "add": format!("cmux ext add {name}"),
            }))
        })
        .collect()
}

/// The search request's URL.
pub(super) fn search_url(query: Option<&str>) -> String {
    let mut q = format!("topic:{TOPIC}");
    if let Some(words) = query.map(str::trim).filter(|words| !words.is_empty()) {
        q.push(' ');
        q.push_str(words);
    }
    let params = [("q", q.as_str()), ("sort", "stars"), ("order", "desc"), ("per_page", "30")];
    url::Url::parse_with_params("https://api.github.com/search/repositories", params)
        .map(|url| url.to_string())
        .unwrap_or_default()
}

async fn search(query: Option<&str>) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(SEARCH_TIMEOUT)
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|err| err.to_string())?;
    let mut request = client.get(search_url(query)).header("Accept", "application/vnd.github+json");
    // A token raises GitHub's search limit (10 a minute without one); never required.
    let token = ["GH_TOKEN", "GITHUB_TOKEN"]
        .iter()
        .find_map(|name| std::env::var(name).ok().filter(|value| !value.is_empty()));
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let response = request.send().await.map_err(|err| err.to_string())?;
    let status = response.status();
    let text = response.text().await.map_err(|err| err.to_string())?;
    let body: Option<Value> = serde_json::from_str(&text).ok();
    if !status.is_success() {
        let said = body.as_ref().and_then(|b| b.field("message").as_str()).unwrap_or("no message");
        return Err(format!("GitHub answered {status}: {said}"));
    }
    body.ok_or_else(|| format!("GitHub answered {status} with no JSON"))
}

/// `ext search [QUERY]`.
pub(super) fn run_search(query: Option<&str>, json_out: bool) -> i32 {
    let answer = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|err| err.to_string())
        .and_then(|runtime| runtime.block_on(search(query)));
    let answer = match answer {
        Ok(answer) => answer,
        Err(message) => {
            if json_out {
                println!(
                    "{}",
                    json!({ "ok": false, "exitCode": exit::FETCH_FAILED, "errors": [message] })
                );
            } else {
                eprintln!("cmux: the search failed: {message}");
            }
            return exit::FETCH_FAILED;
        }
    };
    let rows = search_rows(&answer);
    if json_out {
        println!("{}", json!({ "ok": true, "topic": TOPIC, "extensions": rows }));
        return exit::OK;
    }
    if rows.is_empty() {
        println!(
            "no extensions found (they are GitHub repositories with the topic {TOPIC}; cmux ext share says how to add yours)"
        );
        return exit::OK;
    }
    print!("{}", search_table(&rows));
    exit::OK
}

/// The search rows as a table, one extension per two lines: name, stars and description, then
/// the command that adds it.
pub(super) fn search_table(rows: &[Value]) -> String {
    let mut out = String::new();
    for row in rows {
        let description: String =
            row.field("description").as_str().unwrap_or("").chars().take(80).collect();
        out.push_str(&format!(
            "{}  ({} stars)  {description}\n    {}\n",
            row.field("name").as_str().unwrap_or(""),
            row.field("stars").as_u64().unwrap_or(0),
            row.field("add").as_str().unwrap_or("")
        ));
    }
    out
}
