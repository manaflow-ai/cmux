//! `cmux ext share [DIR]`: publish an extension folder to a new GitHub
//! repository of the person's, with their own `gh` login (the one the app's
//! GitHub features use; never another token). What Ask to build and
//! Fork and customize end with, on by default: the agent says where it goes,
//! then runs this unless the person asked to keep it local.
//!
//! It makes the manifest the owner's (`id` `OWNER/NAME`, `repository`), puts
//! the "Get it on cmux" badge in README.md, commits, creates the repository
//! (`gh repo create --source --push`) with the topic `cmux-extension` that
//! cmux.com's crawler searches, and prints the extension's cmux.com page.
//! With no `gh` or no login nothing leaves the machine: the folder stays and
//! the answer names the one step that connects GitHub.

use cmux_process::{Command, Stdio};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::Field as _;
use super::remix::{self, BADGE_SVG, run_quiet};
use super::scaffold;

/// The GitHub topic cmux.com's crawler searches.
pub(super) const TOPIC: &str = "cmux-extension";

/// `ext share`'s options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ShareOptions {
    pub dir: PathBuf,
    /// `--name`: the repository's name; none is the extension's name.
    pub name: Option<String>,
    /// `--private`: a private repository (cmux.com lists only public ones).
    pub private: bool,
    /// The `gh` program (`CMUX_EXT_GH` in tests).
    pub gh: PathBuf,
}

/// What `ext share` did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Shared {
    /// Published: `OWNER/REPO`, and whether the repository already was the folder's.
    Published { owner: String, repo: String, private: bool, updated: bool },
    /// GitHub is not connected; the folder is kept. `step` connects it.
    NotConnected { step: String, reason: String },
}

/// The README badge for `owner/repo`, exactly as cmux.com documents it.
pub(super) fn badge(owner: &str, repo: &str) -> String {
    format!("[![Get it on cmux]({BADGE_SVG})](https://cmux.com/extensions/{owner}/{repo})")
}

/// `readme` with the badge for `owner/repo` under its first heading (any other badge line goes).
pub(super) fn with_badge(readme: &str, owner: &str, repo: &str, title: &str) -> String {
    let badge = badge(owner, repo);
    let mut lines: Vec<String> =
        readme.lines().filter(|line| !line.contains(BADGE_SVG)).map(str::to_string).collect();
    if !lines.iter().any(|line| line.starts_with("# ")) {
        lines.insert(0, format!("# {title}"));
    }
    let at = lines.iter().position(|line| line.starts_with("# ")).map_or(0, |i| i + 1);
    // The blank lines under the heading (the old badge's too) go; one goes on each side of it.
    while lines.get(at).is_some_and(|line| line.trim().is_empty()) {
        lines.remove(at);
    }
    let rest = at < lines.len();
    lines.splice(at..at, [String::new(), badge]);
    if rest {
        lines.insert(at + 2, String::new());
    }
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

impl Shared {
    pub(super) fn to_json(&self, dir: &Path) -> Value {
        match self {
            Shared::Published { owner, repo, private, updated } => json!({
                "ok": true,
                "published": true,
                "updated": updated,
                "dir": dir,
                "repository": format!("https://github.com/{owner}/{repo}"),
                "private": private,
                "topic": TOPIC,
                "page": format!("https://cmux.com/extensions/{owner}/{repo}"),
                "install": format!("cmux://apps/install?repo=github.com/{owner}/{repo}"),
                "badge": badge(owner, repo),
                "listed": if *private {
                    "private: cmux.com lists only public repositories"
                } else {
                    "cmux.com lists it once reviewed"
                },
            }),
            Shared::NotConnected { step, reason } => json!({
                "ok": false,
                "published": false,
                "dir": dir,
                "kept": true,
                "reason": reason,
                "connect": step,
            }),
        }
    }

    pub(super) fn text(&self, dir: &Path) -> String {
        match self {
            Shared::Published { owner, repo, private, updated } => {
                let mut out = format!(
                    "{} https://github.com/{owner}/{repo}{}\npage: https://cmux.com/extensions/{owner}/{repo}{}\n",
                    if *updated { "pushed to" } else { "published to" },
                    if *private { " (private)" } else { "" },
                    if *private {
                        " (listed only once the repository is public)"
                    } else {
                        " (listed once reviewed)"
                    },
                );
                out.push_str(&format!("topic: {TOPIC}\n"));
                out
            }
            Shared::NotConnected { step, reason } => format!(
                "not published: {reason}. The extension stays in {}.\nTo publish it: {step}, then run cmux ext share again.\n",
                dir.display()
            ),
        }
    }
}

fn git(dir: &Path) -> Command {
    let mut command = Command::new("git");
    command.arg("-C").arg(dir);
    command
}

/// The person's GitHub login through `gh`, or why there is none (with the step that fixes it).
fn login(gh: &Path) -> Result<String, Shared> {
    match Command::new(gh).args(["api", "user", "--jq", ".login"]).stdin(Stdio::null()).output() {
        Err(_) => Err(Shared::NotConnected {
            step: "install the GitHub CLI (brew install gh) and run gh auth login".into(),
            reason: "the GitHub CLI (gh) is not installed".into(),
        }),
        Ok(out) if !out.status.success() || out.stdout.trim_ascii().is_empty() => {
            Err(Shared::NotConnected {
                step: "run gh auth login".into(),
                reason: "GitHub is not connected".into(),
            })
        }
        Ok(out) => Ok(String::from_utf8_lossy(&out.stdout).trim().to_string()),
    }
}

/// The GitHub repository the folder's `origin` already is, as `(owner, repo)`.
fn origin(dir: &Path) -> Option<(String, String)> {
    let url = run_quiet(git(dir).args(["config", "--get", "remote.origin.url"])).ok()?;
    let path = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("git@github.com:"))
        .or_else(|| url.strip_prefix("ssh://git@github.com/"))?;
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, repo) = path.split_once('/')?;
    Some((owner.to_string(), repo.to_string()))
}

/// Whether `owner/repo` exists on GitHub.
fn exists(gh: &Path, slug: &str) -> bool {
    Command::new(gh)
        .args(["repo", "view", slug, "--json", "name"])
        .stdin(Stdio::null())
        .output()
        .is_ok_and(|out| out.status.success())
}

/// Runs `ext share`. An error is a problem with the folder (no manifest, invalid) or a failed
/// `gh` / `git` step after the login was found.
pub(super) fn share(options: &ShareOptions) -> Result<Shared, String> {
    let dir = &options.dir;
    let manifest = remix::manifest_file(dir).ok_or_else(|| {
        format!("{} has no cmux-app.json: it is not an extension folder", dir.display())
    })?;
    let path = dir.join(manifest);
    let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let parsed: Value = serde_json::from_str(&text).map_err(|e| format!("{manifest}: {e}"))?;
    let old_id = parsed.field("id").as_str().unwrap_or_default().to_string();
    let name = match &options.name {
        Some(name) if scaffold::valid_name(name) => name.clone(),
        Some(name) => return Err(format!("--name {name}: lowercase letters, digits and '-'")),
        None => old_id
            .rsplit_once('/')
            .map(|(_, name)| name.to_string())
            .filter(|name| scaffold::valid_name(name))
            .ok_or_else(|| {
                format!("{manifest}: id {old_id:?} has no name to publish under; pass --name NAME")
            })?,
    };

    let login = match login(&options.gh) {
        Ok(login) => login,
        Err(not_connected) => return Ok(not_connected),
    };
    // The folder's own repository when it already has one of this login's; else a new name.
    let (repo, updated) = match origin(dir) {
        Some((owner, repo)) if owner.eq_ignore_ascii_case(&login) => (repo, true),
        _ => {
            let free = std::iter::once(name.clone())
                .chain((2..100).map(|n| format!("{name}-{n}")))
                .find(|repo| !exists(&options.gh, &format!("{login}/{repo}")))
                .ok_or_else(|| {
                    format!("{login}/{name} and its next names are taken; pass --name")
                })?;
            (free, false)
        }
    };
    let publisher = login.to_ascii_lowercase();
    if publisher == "cmux" {
        return Err("the publisher cmux is reserved for cmux's own extensions".into());
    }
    let url = format!("https://github.com/{login}/{repo}");

    // The manifest and README, the owner's. What they held is kept until the manifest validates,
    // and put back when it does not, so a refused publish leaves the folder as it was.
    let readme_path = dir.join("README.md");
    if std::fs::symlink_metadata(&readme_path).is_ok_and(|meta| meta.file_type().is_symlink()) {
        return Err(
            "README.md is a symbolic link; publish a folder whose README.md is a file".into()
        );
    }
    let mut touched = Vec::new();
    remix::source_files(dir, &mut touched);
    touched.push(readme_path.clone());
    let saved: Vec<(PathBuf, Option<Vec<u8>>)> = touched
        .into_iter()
        .map(|file| {
            let bytes = std::fs::read(&file).ok();
            (file, bytes)
        })
        .collect();
    let restore = || {
        for (file, bytes) in &saved {
            let _ = match bytes {
                Some(bytes) => std::fs::write(file, bytes),
                None => std::fs::remove_file(file),
            };
        }
    };
    let new_id = format!("{publisher}/{name}");
    if !old_id.is_empty() {
        remix::rename_id(dir, &old_id, &new_id)?;
    }
    let text = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let text = remix::with_repository(&text, Some(&url))
        .ok_or_else(|| format!("{manifest} is not a JSON object"))?;
    std::fs::write(&path, text).map_err(|e| e.to_string())?;
    let title = parsed.field("name").as_str().unwrap_or(&name).to_string();
    let readme = std::fs::read_to_string(&readme_path).unwrap_or_default();
    std::fs::write(&readme_path, with_badge(&readme, &login, &repo, &title))
        .map_err(|e| e.to_string())?;
    let report = cmux_app_manifest::validate_package_file(dir, manifest);
    let errors: Vec<String> = report
        .issues
        .iter()
        .filter(|issue| issue.severity == cmux_app_manifest::Severity::Error)
        .map(|issue| {
            format!(
                "{}: {} ({})",
                if issue.path.is_empty() { "/" } else { &issue.path },
                issue.message,
                issue.code
            )
        })
        .collect();
    if !errors.is_empty() {
        restore();
        return Err(format!(
            "{manifest} does not validate, nothing was published or changed: {}",
            errors.join("; ")
        ));
    }

    // Commit, then the repository.
    if !dir.join(".git").exists() {
        run_quiet(git(dir).args(["init", "-q", "-b", "main"]))
            .or_else(|_| run_quiet(git(dir).args(["init", "-q"])))?;
    }
    run_quiet(git(dir).args(["add", "-A"]))?;
    let staged = !git(dir)
        .args(["diff", "--cached", "--quiet"])
        .status()
        .is_ok_and(|status| status.success());
    let has_head = run_quiet(git(dir).args(["rev-parse", "--verify", "HEAD"])).is_ok();
    if staged || !has_head {
        run_quiet(git(dir).args(["commit", "-q", "-m", &format!("Publish {title}")]))
            .map_err(|e| format!("git commit: {e} (set git config user.name and user.email)"))?;
    }
    let slug = format!("{login}/{repo}");
    if updated {
        run_quiet(git(dir).args(["push", "-q", "-u", "origin", "HEAD"]))
            .map_err(|e| format!("git push: {e}"))?;
    } else {
        let mut create = Command::new(&options.gh);
        create.args([
            "repo",
            "create",
            &slug,
            if options.private { "--private" } else { "--public" },
        ]);
        create.arg("--source").arg(dir).args(["--remote", "origin", "--push"]);
        let description = parsed
            .field("tagline")
            .as_str()
            .or_else(|| parsed.field("description").as_str())
            .map(|text| text.chars().take(300).collect::<String>());
        if let Some(description) = description.filter(|text| !text.is_empty()) {
            create.args(["--description", &description]);
        }
        run_quiet(&mut create).map_err(|e| format!("gh repo create {slug}: {e}"))?;
    }
    run_quiet(Command::new(&options.gh).args(["repo", "edit", &slug, "--add-topic", TOPIC]))
        .map_err(|e| format!("published {url}, but adding the topic {TOPIC} failed: {e}"))?;
    Ok(Shared::Published { owner: login, repo, private: options.private, updated })
}
