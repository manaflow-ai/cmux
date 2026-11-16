//! An extension as a git repository: the GitHub repository it lives in
//! (`--repo`, the manifest's `repository`, or the folder's `origin`), the
//! "Get it on cmux" badge its README carries, and `cmux ext publish`, which
//! checks a folder is ready to be listed on cmux.com and prints the steps.
//! Nothing here writes to the network: listing is a push, a topic, or a
//! submission the author makes.

use cmux_process::{Command, Stdio};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::Field as _;

/// The badge image cmux.com serves.
pub(super) const BADGE_SVG: &str = "https://cmux.com/extensions/badge.svg";
/// The GitHub topic the cmux.com crawler searches.
pub(super) const TOPIC: &str = "cmux-extension";
/// Where an author submits a repository by hand.
pub(super) const SUBMIT_URL: &str = "https://cmux.com/extensions";
/// The README line that marks the badge and install line as placeholders.
pub(super) const PLACEHOLDER_NOTE: &str = "<!-- cmux: OWNER/REPO below is a placeholder; once this folder has a GitHub repository, run `cmux ext publish --repo OWNER/REPO --write-badge` to fill it in. -->";

/// A GitHub repository, `OWNER/REPO` as GitHub spells it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Repo {
    pub owner: String,
    pub name: String,
}

impl Repo {
    /// Reads `OWNER/REPO`, `github.com/OWNER/REPO`, `https://github.com/OWNER/REPO`
    /// (with `.git` or a trailing `/`), `git@github.com:OWNER/REPO.git` and
    /// `ssh://git@github.com/OWNER/REPO.git`. `None` for anything else,
    /// another host included.
    pub(super) fn parse(text: &str) -> Option<Repo> {
        let text = text.trim();
        let path = ["https://github.com/", "http://github.com/", "ssh://git@github.com/"]
            .iter()
            .find_map(|prefix| text.strip_prefix(prefix))
            .or_else(|| text.strip_prefix("git@github.com:"))
            .or_else(|| text.strip_prefix("github.com/"))
            .unwrap_or(text);
        if path.contains("://") || path.contains('@') {
            return None;
        }
        let path = path.trim_end_matches('/');
        let path = path.strip_suffix(".git").unwrap_or(path);
        let (owner, name) = path.split_once('/')?;
        let owner_ok = (1..=39).contains(&owner.len())
            && !owner.starts_with('-')
            && owner.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
        let name_ok = !name.is_empty()
            && name.len() <= 100
            && name != "."
            && name != ".."
            && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
        (owner_ok && name_ok).then(|| Repo { owner: owner.to_string(), name: name.to_string() })
    }

    /// The repository of a manifest's `repository` field.
    pub(super) fn of_manifest(manifest: &Value) -> Option<Repo> {
        let url = manifest.field("repository").as_str()?;
        if url.starts_with("https://github.com/") { Repo::parse(url) } else { None }
    }

    /// `OWNER/REPO`.
    pub(super) fn slug(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }

    /// The manifest id's publisher: the owner, lowercased.
    pub(super) fn publisher(&self) -> String {
        self.owner.to_ascii_lowercase()
    }

    /// The manifest's `repository`.
    pub(super) fn url(&self) -> String {
        format!("https://github.com/{}", self.slug())
    }

    /// The extension's page on cmux.com.
    pub(super) fn page_url(&self) -> String {
        format!("https://cmux.com/extensions/{}", self.slug())
    }

    /// The README badge, linking to the extension's page.
    pub(super) fn badge(&self) -> String {
        badge_for(&self.slug())
    }

    /// The command that installs it from the repository.
    pub(super) fn install_command(&self) -> String {
        install_for(&self.slug())
    }

    /// Why an extension in this repository cannot use the id `PUBLISHER/NAME`,
    /// if it cannot: `cmux` and `manaflow-ai` are cmux's own publishers.
    pub(super) fn publisher_problem(&self) -> Option<String> {
        let publisher = self.publisher();
        (publisher == "cmux").then(|| {
            format!(
                "{}: the publisher cmux is reserved for cmux's own extensions; use a repository of your own account",
                self.slug()
            )
        })
    }
}

fn badge_for(slug: &str) -> String {
    format!("[![Get it on cmux]({BADGE_SVG})](https://cmux.com/extensions/{slug})")
}

fn install_for(slug: &str) -> String {
    format!("cmux apps install github.com/{slug}")
}

/// The repository of the git checkout whose top folder is `dir`, from its
/// `origin` remote, when that is on github.com. A folder inside another
/// checkout (an extension in a monorepo) has none: that checkout's remote
/// is not the extension's.
pub(super) fn origin_repo(dir: &Path) -> Option<Repo> {
    if !dir.join(".git").exists() {
        return None;
    }
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["config", "--get", "remote.origin.url"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let url = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let on_github = url.contains("github.com/") || url.starts_with("git@github.com:");
    if on_github { Repo::parse(&url) } else { None }
}

/// Makes `dir` a git repository (branch `main`) when it is in none, so a
/// new extension is ready to commit and push. `Some(true)` when it made one,
/// `Some(false)` when `dir` already is in one, `None` when git is missing
/// or failed (the folder is still a working extension).
pub(super) fn git_init(dir: &Path) -> Option<bool> {
    let inside = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", "--is-inside-work-tree"])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if inside.status.success() {
        return Some(false);
    }
    let init = |args: &[&str]| {
        Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    };
    // `-b` is git 2.28's; an older git names the branch itself.
    (init(&["init", "-q", "-b", "main"]) || init(&["init", "-q"])).then_some(true)
}

/// The README part about getting and sharing it: the badge, then (after the
/// description) the install line. With no repository, both carry the
/// `OWNER/REPO` placeholder under `PLACEHOLDER_NOTE`.
pub(super) fn readme_badge(repo: Option<&Repo>) -> String {
    match repo {
        Some(repo) => repo.badge(),
        None => format!("{PLACEHOLDER_NOTE}\n{}", badge_for("OWNER/REPO")),
    }
}

pub(super) fn readme_install(repo: Option<&Repo>) -> String {
    match repo {
        Some(repo) => repo.install_command(),
        None => install_for("OWNER/REPO"),
    }
}

/// `readme` with the badge for `repo`: a badge line already there (the
/// placeholder's or another repository's) is replaced, the placeholder
/// install line and note too; with none, the badge goes under the first
/// heading (or on top). `None` when it is already right.
pub(super) fn with_badge(readme: &str, repo: &Repo) -> Option<String> {
    let badge = repo.badge();
    let placeholder_install = install_for("OWNER/REPO");
    let mut found = false;
    let mut lines: Vec<String> = Vec::new();
    for line in readme.lines() {
        if line.trim() == PLACEHOLDER_NOTE {
            continue;
        }
        if line.contains(BADGE_SVG) {
            if !found {
                lines.push(badge.clone());
            }
            found = true;
        } else if line.contains(&placeholder_install) {
            lines.push(line.replace(&placeholder_install, &repo.install_command()));
        } else {
            lines.push(line.to_string());
        }
    }
    if !found {
        let at = lines.iter().position(|line| line.starts_with("# ")).map_or(0, |i| i + 1);
        if at == 0 {
            lines.splice(0..0, [badge, String::new()]);
        } else {
            lines.splice(at..at, [String::new(), badge]);
        }
    }
    let mut out = lines.join("\n");
    if readme.ends_with('\n') || readme.is_empty() {
        out.push('\n');
    }
    (out != readme).then_some(out)
}

/// `ext publish`'s options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct PublishOptions {
    pub dir: PathBuf,
    /// `--repo OWNER/REPO`.
    pub repo: Option<String>,
    /// `--write-badge`: put the badge into README.md.
    pub write_badge: bool,
}

/// One check of `ext publish`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Check {
    pub name: &'static str,
    pub ok: bool,
    pub message: String,
}

/// What `ext publish` found.
#[derive(Debug, Clone)]
pub(super) struct Report {
    pub dir: PathBuf,
    pub repo: Option<Repo>,
    pub id: Option<String>,
    pub checks: Vec<Check>,
    /// The README changed by `--write-badge`.
    pub wrote_badge: bool,
    pub next: Vec<String>,
}

impl Report {
    pub(super) fn ready(&self) -> bool {
        self.checks.iter().all(|check| check.ok)
    }

    pub(super) fn to_json(&self) -> Value {
        json!({
            "ok": self.ready(),
            "ready": self.ready(),
            "dir": self.dir,
            "repository": self.repo.as_ref().map(Repo::url),
            "id": self.id,
            "page": self.repo.as_ref().map(Repo::page_url),
            "badge": self.repo.as_ref().map(Repo::badge),
            "install": self.repo.as_ref().map(Repo::install_command),
            "wroteBadge": self.wrote_badge,
            "checks": self.checks.iter().map(|check| json!({
                "check": check.name,
                "ok": check.ok,
                "message": check.message,
            })).collect::<Vec<_>>(),
            "next": self.next,
        })
    }

    pub(super) fn text(&self) -> String {
        let mut out = String::new();
        for check in &self.checks {
            out.push_str(&format!(
                "{} {}: {}\n",
                if check.ok { "ok  " } else { "todo" },
                check.name,
                check.message
            ));
        }
        if self.wrote_badge {
            out.push_str("wrote the badge into README.md\n");
        }
        out.push_str(if self.ready() {
            "\nready to list. Next:\n"
        } else {
            "\nnot ready to list yet: fix the todo lines above, then run cmux ext publish again. After that:\n"
        });
        for (i, step) in self.next.iter().enumerate() {
            out.push_str(&format!("  {}. {step}\n", i + 1));
        }
        out
    }
}

const MANIFESTS: [&str; 2] = ["cmux-app.json", "cmux-app.v2.json"];

/// Checks `options.dir` is ready to list (writes the README badge with
/// `--write-badge`); an error is a usage problem (bad `--repo`, no folder).
pub(super) fn check(options: &PublishOptions) -> Result<Report, String> {
    let dir = &options.dir;
    if !dir.is_dir() {
        return Err(format!("{} is not a folder", dir.display()));
    }
    let flag =
        match &options.repo {
            Some(text) => Some(Repo::parse(text).ok_or_else(|| {
                format!("--repo {text}: give the GitHub repository as OWNER/REPO")
            })?),
            None => None,
        };
    let mut checks = Vec::new();
    let mut add = |name: &'static str, ok: bool, message: String| {
        checks.push(Check { name, ok, message });
    };

    // The manifest, as the store validator reads it.
    let file = MANIFESTS.into_iter().find(|file| dir.join(file).is_file());
    let manifest = match file {
        None => {
            add(
                "manifest",
                false,
                "no cmux-app.json in the folder (cmux ext new NAME makes one)".into(),
            );
            None
        }
        Some(file) => {
            let report = cmux_app_manifest::validate_package_file(dir, file);
            let errors: Vec<String> = report
                .issues
                .iter()
                .filter(|issue| issue.severity == cmux_app_manifest::Severity::Error)
                .map(|issue| {
                    let at = if issue.path.is_empty() { "/" } else { issue.path.as_str() };
                    format!("{at}: {} ({})", issue.message, issue.code)
                })
                .collect();
            if errors.is_empty() {
                add("manifest", true, format!("{file} validates"));
            } else {
                add("manifest", false, format!("{file}: {}", errors.join("; ")));
            }
            report.manifest
        }
    };
    let manifest = manifest.unwrap_or(Value::Null);
    let id = manifest.field("id").as_str().map(str::to_string);
    let field_repo = Repo::of_manifest(&manifest);
    let repo = flag.clone().or_else(|| field_repo.clone()).or_else(|| origin_repo(dir));

    // The repository field.
    match (&field_repo, &flag, manifest.field("repository").as_str()) {
        (Some(field), Some(flag), _) if field.slug() != flag.slug() => add(
            "repository",
            false,
            format!(
                "the manifest's repository is {} but --repo says {}; make them the same",
                field.url(),
                flag.url()
            ),
        ),
        (Some(field), ..) => add("repository", true, field.url()),
        (None, _, Some(other)) => add(
            "repository",
            false,
            format!("{other} is not a GitHub repository URL (https://github.com/OWNER/REPO)"),
        ),
        (None, ..) => add(
            "repository",
            false,
            match &repo {
                Some(repo) => format!("set \"repository\": \"{}\" in the manifest", repo.url()),
                None => "set \"repository\": \"https://github.com/OWNER/REPO\" in the manifest (or pass --repo OWNER/REPO)".into(),
            },
        ),
    }

    // The id: the owner's.
    let name = id.as_deref().and_then(|id| id.split_once('/')).map(|(_, name)| name.to_string());
    match (&id, &repo) {
        (None, _) => {}
        (Some(id), _) if id.starts_with("local/") => add(
            "id",
            false,
            format!(
                "{id} is a local id; a listed extension's id is its GitHub owner's: set \"id\": \"{}/{}\"{}",
                repo.as_ref().map_or("OWNER".to_string(), Repo::publisher),
                name.as_deref().unwrap_or("NAME"),
                if manifest.get("catalog").is_some() {
                    " and rename the catalog family and ops to match"
                } else {
                    ""
                }
            ),
        ),
        (Some(id), Some(repo)) => {
            let publisher = id.split('/').next().unwrap_or_default();
            if publisher == repo.publisher() {
                add("id", true, format!("{id} is {}'s", repo.owner));
            } else {
                add(
                    "id",
                    false,
                    format!(
                        "{id} must start with the repository owner: \"{}/{}\"",
                        repo.publisher(),
                        name.as_deref().unwrap_or("NAME")
                    ),
                );
            }
        }
        (Some(id), None) => add("id", true, id.clone()),
    }

    // The README and its badge.
    let readme_path = dir.join("README.md");
    let mut wrote_badge = false;
    match (std::fs::read_to_string(&readme_path), &repo) {
        (Err(_), _) => add(
            "readme",
            false,
            "no README.md: it is the extension's page on cmux.com; write one with the badge".into(),
        ),
        (Ok(readme), Some(repo)) => {
            let fixed = with_badge(&readme, repo);
            match fixed {
                None => add("badge", true, format!("README.md links to {}", repo.page_url())),
                Some(text) if options.write_badge => {
                    std::fs::write(&readme_path, text)
                        .map_err(|e| format!("cannot write {}: {e}", readme_path.display()))?;
                    wrote_badge = true;
                    add("badge", true, format!("README.md links to {}", repo.page_url()));
                }
                Some(_) => add(
                    "badge",
                    false,
                    format!(
                        "README.md has no badge for {}: add\n       {}\n       or run cmux ext publish --write-badge",
                        repo.slug(),
                        repo.badge()
                    ),
                ),
            }
        }
        (Ok(_), None) => add(
            "badge",
            false,
            "the badge needs the repository: pass --repo OWNER/REPO (with --write-badge to add it)"
                .into(),
        ),
    }

    // A picture for the listing: an image icon or a screenshot.
    let icon = manifest.field("icon").as_str().filter(|path| dir.join(path).is_file());
    let shots: Vec<&str> = manifest
        .field("screenshots")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let missing: Vec<&str> =
        shots.iter().copied().filter(|path| !dir.join(path).is_file()).collect();
    let present = shots.len() - missing.len();
    if !missing.is_empty() {
        add("picture", false, format!("screenshots not in the folder: {}", missing.join(", ")));
    } else if icon.is_some() || present > 0 {
        let mut what = Vec::new();
        if let Some(icon) = icon {
            what.push(format!("icon {icon}"));
        }
        if present > 0 {
            what.push(format!("{present} screenshot{}", if present == 1 { "" } else { "s" }));
        }
        add("picture", true, what.join(", "));
    } else {
        add(
            "picture",
            false,
            "no image icon or screenshot: add \"icon\": \"icon.png\" (listed in files) or \"screenshots\": [\"screenshot.png\"] (cmux ext shot --out screenshot.png takes one)".into(),
        );
    }

    let next = next_steps(dir, repo.as_ref());
    Ok(Report { dir: dir.clone(), repo, id, checks, wrote_badge, next })
}

/// The steps after the checks: push, the topic or the submission, install.
fn next_steps(dir: &Path, repo: Option<&Repo>) -> Vec<String> {
    let slug = repo.map_or("OWNER/REPO".to_string(), Repo::slug);
    let push = if origin_repo(dir).is_some() {
        "commit and push to GitHub: git add -A && git commit -m \"Publish\" && git push".to_string()
    } else if dir.join(".git").exists() {
        format!(
            "commit and push to GitHub: git add -A && git commit -m \"First version\" && gh repo create {slug} --public --source . --push"
        )
    } else {
        format!(
            "make it a git repository and push it: git init -b main && git add -A && git commit -m \"First version\" && gh repo create {slug} --public --source . --push"
        )
    };
    vec![
        push,
        format!(
            "add the GitHub topic {TOPIC} so cmux.com finds it: gh repo edit {slug} --add-topic {TOPIC}"
        ),
        format!("or submit it at {SUBMIT_URL}; it is listed once reviewed"),
        format!("anyone installs it with: {}", install_for(&slug)),
    ]
}
