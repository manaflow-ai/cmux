//! `cmux repo read|ls|run|commit|tier`: a chat works on a GitHub repository with nothing cloned
//! (crate `cmux-no-checkout`). Leo, 2026-11-17: "what other assistants do ... they don't fetch the
//! entire repository. They just do it all through the GitHub MCP connection".
//!
//!     cmux repo read OWNER/NAME PATH [--ref BRANCH]
//!     cmux repo ls OWNER/NAME [PATTERN...] [--ref BRANCH]
//!     cmux repo run OWNER/NAME --path P [--path P...] [--patch FILE|-] [--ref BRANCH] -- CMD [ARG...]
//!     cmux repo commit OWNER/NAME --branch B --message M [--ref BASE] [--patch FILE|-]
//!                      [--put PATH=LOCAL_FILE]... [--delete PATH]... [--pr TITLE [--body TEXT] [--draft]]
//!     cmux repo tier [--repo] [--folder DIR] [--run nothing|whole|paths:FILES:BYTES]
//!                    [--projection served|unserved]
//!
//! `run` writes only the paths it names (a path, a folder, or a glob), with the patch applied, to
//! a temporary folder, runs the command there and deletes the folder when it ends. `commit` makes
//! the commit through the git data API (blobs, a tree on the base, a commit, the branch) and, with
//! `--pr`, opens the pull request. The token: on a cmux Cloud machine the one its Cloud agent
//! mints for this repository (`cmux github`, the team's GitHub App), else `GH_TOKEN` or
//! `GITHUB_TOKEN`, else none (a public repository reads without one). Every verb but `read` and
//! `run`'s command prints one JSON line on stdout.

use std::path::Path;

use anyhow::{Context as _, bail};
use cmux_no_checkout::{Folder, GitHub, Remote, Run, Task, github, patch, tier};
use serde_json::json;
use zeroize::Zeroizing;

const USAGE: &str = "usage: cmux repo read OWNER/NAME PATH [--ref B] | ls OWNER/NAME [PATTERN...] \
[--ref B] | run OWNER/NAME --path P... [--patch FILE|-] [--ref B] -- CMD... | commit OWNER/NAME \
--branch B --message M [--ref BASE] [--patch FILE|-] [--put PATH=FILE]... [--delete PATH]... \
[--pr TITLE [--body TEXT] [--draft]] | tier [--repo] [--folder DIR] [--run nothing|whole|paths:FILES:BYTES] \
[--projection served|unserved]";

/// Whether `verb` is one of this file's.
pub(super) fn handles(verb: &str) -> bool {
    matches!(verb, "read" | "ls" | "run" | "commit" | "tier")
}

pub(super) fn run(verb: &str, args: &[String]) -> i32 {
    if verb == "tier" {
        return finish(tier_command(args).map(|v| println!("{v}")).map(|()| 0));
    }
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => return finish(Err(e.into())),
    };
    finish(runtime.block_on(async {
        match verb {
            "read" => read(args).await,
            "ls" => ls(args).await,
            "run" => run_command(args).await,
            _ => commit(args).await,
        }
    }))
}

fn finish(result: anyhow::Result<i32>) -> i32 {
    match result {
        Ok(code) => code,
        Err(e) => {
            eprintln!("cmux repo: {e:#}");
            eprintln!("{USAGE}");
            1
        }
    }
}

/// Flags and the words left, until `--`.
struct Parsed {
    words: Vec<String>,
    flags: Vec<(String, String)>,
    switches: Vec<String>,
    rest: Vec<String>,
}

impl Parsed {
    fn new(args: &[String], valued: &[&str], switches: &[&str]) -> anyhow::Result<Self> {
        let mut out =
            Self { words: Vec::new(), flags: Vec::new(), switches: Vec::new(), rest: Vec::new() };
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            if arg == "--" {
                out.rest = it.cloned().collect();
                break;
            }
            if valued.contains(&arg.as_str()) {
                let value = it.next().with_context(|| format!("{arg} needs a value"))?;
                out.flags.push((arg.clone(), value.clone()));
            } else if switches.contains(&arg.as_str()) {
                out.switches.push(arg.clone());
            } else if arg.starts_with("--") {
                bail!("unknown flag {arg}");
            } else {
                out.words.push(arg.clone());
            }
        }
        Ok(out)
    }

    fn one(&self, flag: &str) -> Option<&str> {
        self.flags.iter().rev().find(|(k, _)| k == flag).map(|(_, v)| v.as_str())
    }

    fn all(&self, flag: &str) -> Vec<String> {
        self.flags.iter().filter(|(k, _)| k == flag).map(|(_, v)| v.clone()).collect()
    }

    fn on(&self, switch: &str) -> bool {
        self.switches.iter().any(|s| s == switch)
    }
}

/// The token for `repo` (module docs): the Cloud agent's mint, else the env's, else none.
fn token(repo: &str, write: bool) -> anyhow::Result<github::Token> {
    let socket = Path::new(cmux_host::cloud::wire::AGENT_SOCKET);
    if socket.exists() {
        let ask = cmux_host::github_cli::gh_ask(repo, write);
        return match cmux_host::github_cli::ask_retrying(socket, &ask) {
            Ok(minted) => Ok(Some(Zeroizing::new(minted.token))),
            // A public repository still reads without one.
            Err(_) if !write => Ok(None),
            Err(e) => bail!("{}", e.explained(repo)),
        };
    }
    Ok(["GH_TOKEN", "GITHUB_TOKEN"]
        .iter()
        .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
        .map(Zeroizing::new))
}

async fn open(parsed: &Parsed, write: bool) -> anyhow::Result<Remote> {
    let repo = parsed.words.first().context("OWNER/NAME is required")?;
    let gh = GitHub::new(github::GITHUB_API, repo, token(repo, write)?, None)?;
    Remote::open(gh, parsed.one("--ref")).await
}

async fn read(args: &[String]) -> anyhow::Result<i32> {
    let parsed = Parsed::new(args, &["--ref"], &[])?;
    let path = parsed.words.get(1).context("PATH is required")?;
    let mut remote = open(&parsed, false).await?;
    let bytes = remote.read(path).await?;
    use std::io::Write as _;
    std::io::stdout().write_all(&bytes)?;
    Ok(0)
}

async fn ls(args: &[String]) -> anyhow::Result<i32> {
    let parsed = Parsed::new(args, &["--ref"], &[])?;
    let mut patterns: Vec<String> = parsed.words.iter().skip(1).cloned().collect();
    if patterns.is_empty() {
        patterns.push("**".to_owned());
    }
    let mut remote = open(&parsed, false).await?;
    for file in remote.files(&patterns).await? {
        println!("{}", file.path);
    }
    Ok(0)
}

fn patch_text(parsed: &Parsed) -> anyhow::Result<Option<String>> {
    Ok(match parsed.one("--patch") {
        None => None,
        Some("-") => Some(std::io::read_to_string(std::io::stdin())?),
        Some(file) => {
            Some(std::fs::read_to_string(file).with_context(|| format!("cannot read {file}"))?)
        }
    })
}

async fn run_command(args: &[String]) -> anyhow::Result<i32> {
    let parsed = Parsed::new(args, &["--ref", "--path", "--patch"], &[])?;
    let paths = parsed.all("--path");
    if paths.is_empty() || parsed.rest.is_empty() {
        bail!("run needs at least one --path and a command after --");
    }
    let mut remote = open(&parsed, false).await?;
    if let Some(text) = patch_text(&parsed)? {
        patch::apply(&mut remote, &text).await?;
    }
    let projected = remote.project(&paths).await?;
    // The command has the terminal: its own output is the chat's to read.
    let status = cmux_process::Command::new(&parsed.rest[0])
        .args(&parsed.rest[1..])
        .current_dir(projected.path())
        .status()
        // (blocking: this CLI runs nothing else meanwhile)
        .with_context(|| format!("cannot run {}", parsed.rest[0]))?;
    let (files, bytes) = (projected.files, projected.bytes);
    projected.close()?;
    let meter = remote.github().meter();
    eprintln!(
        "{}",
        json!({"projected_files": files, "projected_bytes": bytes, "github_calls": meter.calls(),
               "bytes_down": meter.bytes_down(), "left_on_disk": 0, "exit": status.code()})
    );
    Ok(status.code().unwrap_or(1))
}

async fn commit(args: &[String]) -> anyhow::Result<i32> {
    let valued =
        ["--ref", "--branch", "--message", "--patch", "--put", "--delete", "--pr", "--body"];
    let parsed = Parsed::new(args, &valued, &["--draft"])?;
    let branch = parsed.one("--branch").context("--branch is required")?;
    let message = parsed.one("--message").context("--message is required")?;
    let mut remote = open(&parsed, true).await?;
    let base = remote.branch().to_owned();
    if branch == base {
        bail!("--branch {branch} is the base: commit to a new branch and open a pull request");
    }
    if let Some(text) = patch_text(&parsed)? {
        patch::apply(&mut remote, &text).await?;
    }
    for put in parsed.all("--put") {
        let (path, file) = put.split_once('=').context("--put is PATH=LOCAL_FILE")?;
        let bytes = std::fs::read(file).with_context(|| format!("cannot read {file}"))?;
        remote.write(path, bytes).await?;
    }
    for path in parsed.all("--delete") {
        remote.delete(&path).await?;
    }
    let changed: Vec<String> = remote.edits().keys().cloned().collect();
    let sha = remote.commit(branch, message).await?;
    let pull = match parsed.one("--pr") {
        Some(title) => {
            let body = parsed.one("--body").unwrap_or_default();
            let pull =
                remote.github().open_pull(title, body, branch, &base, parsed.on("--draft")).await?;
            json!({"number": pull.number, "url": pull.url})
        }
        None => serde_json::Value::Null,
    };
    let meter = remote.github().meter();
    println!(
        "{}",
        json!({"ok": true, "commit": sha, "branch": branch, "base": base, "changed": changed,
               "pull": pull, "github_calls": meter.calls(), "bytes_up": meter.bytes_up(),
               "bytes_down": meter.bytes_down()})
    );
    Ok(0)
}

/// Whether `folder` holds work its GitHub remote lacks: no GitHub `origin`, uncommitted
/// changes, or commits not on its upstream (or no upstream).
fn local_work(folder: &Path) -> bool {
    let git = |args: &[&str]| {
        cmux_process::Command::new("git")
            .arg("-C")
            .arg(folder)
            .args(args)
            .output()
            .ok()
            .filter(|out| out.status.success())
            .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
    };
    let github = git(&["remote", "get-url", "origin"])
        .and_then(|url| cmux_host::github_cli::repo_from(&url))
        .is_some();
    let dirty = git(&["status", "--porcelain"]).is_none_or(|s| !s.is_empty());
    let ahead = git(&["rev-list", "--count", "@{upstream}..HEAD"]).is_none_or(|n| n != "0");
    !github || dirty || ahead
}

fn tier_command(args: &[String]) -> anyhow::Result<serde_json::Value> {
    let parsed = Parsed::new(args, &["--folder", "--run", "--projection"], &["--repo"])?;
    let folder = match parsed.one("--folder") {
        Some(dir) => {
            let dir = Path::new(dir);
            let estimate = crate::link::sync_cli::estimate::of_folder(dir)?;
            Some(Folder { local_work: local_work(dir), past_copy_limits: estimate.why.is_some() })
        }
        None => None,
    };
    let run = match parsed.one("--run").unwrap_or("nothing") {
        "nothing" => Run::Nothing,
        "whole" => Run::WholeTree,
        other => {
            let mut parts = other
                .strip_prefix("paths:")
                .context("--run is nothing, whole or paths:FILES:BYTES")?
                .split(':');
            let mut number = || parts.next().and_then(|n| n.parse::<u64>().ok());
            let (files, bytes) = (number(), number());
            Run::Paths {
                files: files.context("--run paths:FILES:BYTES")?,
                bytes: bytes.context("--run paths:FILES:BYTES")?,
            }
        }
    };
    let projection_served = match parsed.one("--projection").unwrap_or("unserved") {
        "served" => true,
        "unserved" => false,
        other => bail!("--projection is served or unserved, not {other}"),
    };
    let task = Task { github_repo: parsed.on("--repo"), folder, run, projection_served };
    let choice = tier::choose(&task);
    Ok(json!({"ok": true, "tier": choice.tier.name(), "why": choice.why,
              "folder": folder.map(|f| json!({"local_work": f.local_work, "past_copy_limits": f.past_copy_limits}))}))
}
