//! `cmux ext remix REF`: Fork and customize. cmux.com's "Fork and customize"
//! button opens `cmux://build?remix=REF`, which starts a chat asking its agent
//! to run this. It fetches the extension's source at that commit with `git`
//! (any host: one shallow fetch of the commit, a full fetch when the host
//! refuses fetching by commit) into a new folder of the person's, makes it
//! `local/NAME` with its own git repository, and prints what the agent does
//! next: ask what to change, change it, and publish it to a new GitHub
//! repository of the person's (`cmux ext share`, on by default).
//!
//! REF is the install reference (`HOST/OWNER/REPO[/PATH][@REF]`, with or
//! without `https://`): PATH is the folder holding the manifest in a
//! repository with several extensions, REF a commit (what the button
//! sends), branch or tag; none is the default branch.

use cmux_process::{Command, Stdio};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::Field as _;
use super::scaffold;

/// The manifest files an extension folder holds, v2 content in either.
pub(super) const MANIFESTS: [&str; 2] = ["cmux-app.json", "cmux-app.v2.json"];
/// The README badge image cmux.com serves; a line with it is a badge.
pub(super) const BADGE_SVG: &str = "https://cmux.com/extensions/badge.svg";
/// The projects folders, in the order New project picks one (acpmux `server/project_new.rs`).
const PROJECT_ROOTS: [&str; 5] = ["Projects", "projects", "Developer", "code", "src"];

/// Where an extension's source lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct SourceRef {
    pub host: String,
    pub owner: String,
    pub repo: String,
    /// The folder holding the manifest, `""` for the repository's root.
    pub path: String,
    /// A commit, branch or tag; `None` for the default branch.
    pub rev: Option<String>,
}

fn segment_ok(part: &str) -> bool {
    !part.is_empty()
        && part != "."
        && part != ".."
        && part.len() <= 100
        && part.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

fn rev_ok(rev: &str) -> bool {
    !rev.is_empty()
        && rev.len() <= 200
        && !rev.starts_with('-')
        && !rev.contains("..")
        && rev.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/'))
}

impl SourceRef {
    /// Reads `HOST/OWNER/REPO[/PATH][@REF]`, `https://HOST/...`, with `.git`
    /// on REPO or a trailing `/`. `None` for anything else.
    pub(super) fn parse(text: &str) -> Option<SourceRef> {
        let text = text.trim();
        let text =
            text.strip_prefix("https://").or_else(|| text.strip_prefix("http://")).unwrap_or(text);
        let (location, rev) = match text.rsplit_once('@') {
            Some((location, rev)) => (location, Some(rev)),
            None => (text, None),
        };
        if rev.is_some_and(|rev| !rev_ok(rev)) {
            return None;
        }
        let mut parts = location.trim_end_matches('/').split('/');
        let host = parts.next()?.to_ascii_lowercase();
        let host_ok = host.contains('.')
            && !host.starts_with('.')
            && !host.ends_with('.')
            && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-'));
        let owner = parts.next()?;
        let repo = parts.next()?;
        let repo = repo.strip_suffix(".git").unwrap_or(repo);
        let path: Vec<&str> = parts.collect();
        let ok = host_ok
            && segment_ok(owner)
            && segment_ok(repo)
            && path.iter().all(|part| segment_ok(part));
        ok.then(|| SourceRef {
            host,
            owner: owner.to_string(),
            repo: repo.to_string(),
            path: path.join("/"),
            rev: rev.map(str::to_string),
        })
    }

    /// `HOST/OWNER/REPO`.
    pub(super) fn repository(&self) -> String {
        format!("{}/{}/{}", self.host, self.owner, self.repo)
    }

    /// The URL `git` fetches, under `base` in tests (a folder of bare repositories).
    fn clone_url(&self, base: Option<&Path>) -> String {
        match base {
            Some(base) => {
                base.join(&self.host).join(&self.owner).join(&self.repo).display().to_string()
            }
            None => format!("https://{}.git", self.repository()),
        }
    }

    /// The reference, written as the button writes it: with `commit` in place of the asked rev.
    pub(super) fn display(&self, commit: Option<&str>) -> String {
        let mut out = self.repository();
        if !self.path.is_empty() {
            out.push('/');
            out.push_str(&self.path);
        }
        if let Some(rev) = commit.or(self.rev.as_deref()) {
            out.push('@');
            out.push_str(rev);
        }
        out
    }

    /// The source's web page at `commit` (GitHub, GitLab and Codeberg read `/tree/`).
    pub(super) fn web_url(&self, commit: &str) -> String {
        let base = format!("https://{}", self.repository());
        let tree = if self.host == "gitlab.com" { "-/tree" } else { "tree" };
        if self.path.is_empty() {
            format!("{base}/{tree}/{commit}")
        } else {
            format!("{base}/{tree}/{commit}/{}", self.path)
        }
    }

    /// cmux.com's page for the source (GitHub keeps the short form).
    pub(super) fn page_url(&self) -> String {
        let mut out = if self.host == "github.com" {
            format!("https://cmux.com/extensions/{}/{}", self.owner, self.repo)
        } else {
            format!("https://cmux.com/extensions/{}", self.repository())
        };
        if !self.path.is_empty() {
            out.push('/');
            out.push_str(&self.path);
        }
        out
    }
}

/// `ext remix`'s options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct RemixOptions {
    pub source: String,
    /// `--dir`: the new folder; none picks `~/Projects/NAME` (or `NAME-2`, ...).
    pub dir: Option<PathBuf>,
    /// `--name`: the new extension's name; none keeps the source's.
    pub name: Option<String>,
}

/// What `ext remix` made.
#[derive(Debug, Clone)]
pub(super) struct Remix {
    pub source: SourceRef,
    pub commit: String,
    pub dir: PathBuf,
    pub name: String,
    pub app: String,
    pub manifest: &'static str,
    /// Manifest errors after the rename, for the agent to fix.
    pub issues: Vec<String>,
    /// Whether the first commit was made (git may have no identity).
    pub committed: bool,
}

impl Remix {
    pub(super) fn to_json(&self) -> Value {
        json!({
            "ok": true,
            "source": {
                "repository": self.source.repository(),
                "path": self.source.path,
                "commit": self.commit,
                "ref": self.source.display(Some(&self.commit)),
                "url": self.source.web_url(&self.commit),
            },
            "dir": self.dir,
            "name": self.name,
            "app": self.app,
            "manifest": self.manifest,
            "issues": self.issues,
            "committed": self.committed,
            "brief": self.brief(),
        })
    }

    /// What the agent does next: the ask, the dev loop, and publishing (on by default).
    pub(super) fn brief(&self) -> String {
        let dir = self.dir.display();
        let mut out = format!(
            "Remixed {} at {} into {dir} as {}, a folder of the person's with its own git repository.\n",
            self.source.display(None),
            short(&self.commit),
            self.app
        );
        if !self.issues.is_empty() {
            out.push_str(&format!(
                "First fix the manifest ({}): {}\n",
                self.manifest,
                self.issues.join("; ")
            ));
        }
        out.push_str(&format!(
            "1. Ask the person what to change, unless they already said; then change it in {dir}.\n\
             2. After each edit run `cmux ext dev {dir} --once --json` until it is ok; before saying it is done, run `cmux ext shot {dir} --json` and look at the picture.\n\
             3. Publish it (on by default): tell the person it goes to a new public GitHub repository of theirs named {name}, then run `cmux ext share {dir} --json` unless they said to keep it local (or `--private`). Give them the page link it prints. When it says GitHub is not connected, the folder stays as it is: tell them the one step it prints.\n",
            name = self.name,
        ));
        out
    }
}

fn short(commit: &str) -> &str {
    commit.get(..12).unwrap_or(commit)
}

/// The manifest file in `dir`, if it holds one.
pub(super) fn manifest_file(dir: &Path) -> Option<&'static str> {
    MANIFESTS.into_iter().find(|file| dir.join(file).is_file())
}

/// The first projects folder under `home` that exists, else `home/Projects`.
pub(super) fn projects_root(home: &Path) -> PathBuf {
    PROJECT_ROOTS
        .iter()
        .map(|root| home.join(root))
        .find(|root| root.is_dir())
        .unwrap_or_else(|| home.join(PROJECT_ROOTS[0]))
}

/// `root/name`, or the first `root/name-N` that does not exist.
pub(super) fn free_folder(root: &Path, name: &str) -> PathBuf {
    let first = root.join(name);
    if !first.exists() {
        return first;
    }
    (2..10_000).map(|n| root.join(format!("{name}-{n}"))).find(|dir| !dir.exists()).unwrap_or(first)
}

fn git(dir: &Path) -> Command {
    let mut command = Command::new("git");
    command.arg("-C").arg(dir).stdin(Stdio::null());
    command
}

/// Runs `command`; its stderr's last line as the error.
pub(super) fn run_quiet(command: &mut Command) -> Result<String, String> {
    let out =
        command.stdin(Stdio::null()).output().map_err(|e| format!("cannot run a command: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        Err(err.trim().lines().last().unwrap_or("failed").to_string())
    }
}

/// Fetches `source` into the empty git repository `work` and checks it out; returns the commit.
/// One shallow fetch of the rev (a commit too, which GitHub, GitLab and Codeberg serve); a host
/// that refuses fetching a commit by its id gets a full fetch, then the commit is checked out.
fn fetch(work: &Path, source: &SourceRef, base: Option<&Path>) -> Result<String, String> {
    run_quiet(git(work).args(["init", "-q"]))?;
    let url = source.clone_url(base);
    let rev = source.rev.as_deref().unwrap_or("HEAD");
    let shallow = run_quiet(git(work).args(["fetch", "-q", "--depth", "1", "--", &url, rev]));
    let target = match shallow {
        Ok(_) => "FETCH_HEAD".to_string(),
        Err(first) => {
            let is_commit = rev.len() == 40 && rev.chars().all(|c| c.is_ascii_hexdigit());
            if !is_commit {
                return Err(format!("cannot fetch {}: {first}", source.display(None)));
            }
            run_quiet(git(work).args([
                "fetch",
                "-q",
                "--",
                &url,
                "+refs/heads/*:refs/remotes/source/*",
                "+refs/tags/*:refs/tags/*",
            ]))
            .map_err(|e| format!("cannot fetch {}: {e}", source.display(None)))?;
            rev.to_string()
        }
    };
    let commit =
        run_quiet(git(work).args(["rev-parse", "--verify", &format!("{target}^{{commit}}")]))
            .map_err(|_| format!("{} has no commit {rev}", source.repository()))?;
    run_quiet(git(work).args(["checkout", "-q", "--detach", &commit]))?;
    Ok(commit)
}

/// Copies `from` into the new folder `to`, leaving out `.git`.
fn copy_tree(from: &Path, to: &Path) -> Result<(), String> {
    std::fs::create_dir_all(to).map_err(|e| format!("{}: {e}", to.display()))?;
    let entries = std::fs::read_dir(from).map_err(|e| format!("{}: {e}", from.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name();
        if name == ".git" {
            continue;
        }
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        let target = to.join(&name);
        if kind.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else if kind.is_symlink() {
            let link = std::fs::read_link(entry.path()).map_err(|e| e.to_string())?;
            std::os::unix::fs::symlink(link, &target)
                .map_err(|e| format!("{}: {e}", target.display()))?;
        } else {
            std::fs::copy(entry.path(), &target)
                .map_err(|e| format!("{}: {e}", target.display()))?;
        }
    }
    Ok(())
}

/// The text files an id's name is written in: the manifest, catalogs and sources.
fn source_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') || name == "node_modules" || name == "dist" {
            continue;
        }
        if path.is_dir() {
            source_files(&path, out);
        } else if [".json", ".ts", ".tsx", ".js", ".mjs"].iter().any(|ext| name.ends_with(ext)) {
            out.push(path);
        }
    }
}

/// Renames the extension in `dir` from `old` to `new`: the manifest's id and every place the
/// id's namespace (`publisher.name`, catalog families and ops) is written. Returns whether
/// anything changed.
pub(super) fn rename_id(dir: &Path, old: &str, new: &str) -> Result<bool, String> {
    if old == new {
        return Ok(false);
    }
    let (old_ns, new_ns) =
        (cmux_app_manifest::app_namespace(old), cmux_app_manifest::app_namespace(new));
    let (old_quoted, new_quoted) = (format!("\"{old}\""), format!("\"{new}\""));
    let mut files = Vec::new();
    source_files(dir, &mut files);
    let mut changed = false;
    for file in files {
        let Ok(text) = std::fs::read_to_string(&file) else { continue };
        let renamed = text.replace(&old_quoted, &new_quoted).replace(&old_ns, &new_ns);
        if renamed != text {
            std::fs::write(&file, renamed).map_err(|e| format!("{}: {e}", file.display()))?;
            changed = true;
        }
    }
    Ok(changed)
}

/// `manifest` (its text) with `"repository"` set to `url`, or removed when `url` is `None`;
/// the other lines stay as they are. `None` when the text is not a JSON object.
pub(super) fn with_repository(manifest: &str, url: Option<&str>) -> Option<String> {
    let mut value: Value = serde_json::from_str(manifest).ok()?;
    let object = value.as_object_mut()?;
    let has = object.contains_key("repository");
    let mut lines: Vec<String> = manifest.lines().map(str::to_string).collect();
    let is_field = |line: &str| line.trim_start().starts_with("\"repository\":");
    match (has, url) {
        (false, None) => return Some(manifest.to_string()),
        (true, Some(url)) => {
            for line in &mut lines {
                if is_field(line) {
                    let indent = &line[..line.len() - line.trim_start().len()];
                    let comma = if line.trim_end().ends_with(',') { "," } else { "" };
                    *line = format!("{indent}\"repository\": {}{comma}", Value::from(url));
                }
            }
        }
        (true, None) => {
            if let Some(at) = lines.iter().position(|line| is_field(line)) {
                let had_comma = lines[at].trim_end().ends_with(',');
                lines.remove(at);
                if !had_comma
                    && let Some(prev) =
                        lines[..at].iter_mut().rev().find(|line| !line.trim().is_empty())
                    && prev.trim_end().ends_with(',')
                {
                    let trimmed = prev.trim_end().trim_end_matches(',').to_string();
                    *prev = trimmed;
                }
            }
        }
        (false, Some(url)) => {
            let at = lines.iter().position(|line| line.trim_start().starts_with("\"id\":"));
            let line = match at {
                Some(at) => {
                    let indent =
                        lines[at][..lines[at].len() - lines[at].trim_start().len()].to_string();
                    if !lines[at].trim_end().ends_with(',') {
                        lines[at].push(',');
                    }
                    (at + 1, format!("{indent}\"repository\": {},", Value::from(url)))
                }
                None => (1, format!("  \"repository\": {},", Value::from(url))),
            };
            lines.insert(line.0, line.1);
        }
    }
    let mut out = lines.join("\n");
    if manifest.ends_with('\n') {
        out.push('\n');
    }
    // A layout these line edits do not keep valid (one line, odd spacing): write it whole.
    if serde_json::from_str::<Value>(&out).is_err() {
        let object = value.as_object_mut()?;
        match url {
            Some(url) => {
                object.insert("repository".into(), Value::from(url));
            }
            None => {
                object.remove("repository");
            }
        }
        out = serde_json::to_string_pretty(&value).ok()? + "\n";
    }
    Some(out)
}

/// `readme` without the source's badge, with a line that names what it was remixed from.
fn remixed_readme(readme: &str, source: &SourceRef, commit: &str) -> String {
    let line = format!(
        "Remixed from [{}]({}) at `{}`.",
        source.display(None),
        source.web_url(commit),
        short(commit)
    );
    let mut lines: Vec<&str> = readme.lines().filter(|line| !line.contains(BADGE_SVG)).collect();
    let at = lines.iter().position(|line| line.starts_with("# ")).map_or(0, |i| i + 1);
    if at == 0 {
        lines.splice(0..0, [line.as_str(), ""]);
    } else {
        lines.splice(at..at, ["", line.as_str()]);
    }
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

/// The name part of an app id (`acme/todo` is `todo`), when it is a name `ext new` takes.
fn id_name(id: &str) -> Option<String> {
    let name =
        id.rsplit_once('/').map_or(id, |(_, name)| name).to_ascii_lowercase().replace('_', "-");
    scaffold::valid_name(&name).then_some(name)
}

/// Runs `ext remix`. `home` is the person's home folder; `base` stands in for the network in tests.
pub(super) fn remix(
    options: &RemixOptions,
    home: &Path,
    base: Option<&Path>,
) -> Result<Remix, String> {
    let source = SourceRef::parse(&options.source).ok_or_else(|| {
        format!("{}: give the source as HOST/OWNER/REPO[/PATH][@COMMIT], e.g. github.com/OWNER/REPO@COMMIT", options.source)
    })?;
    if let Some(name) = &options.name
        && !scaffold::valid_name(name)
    {
        return Err(format!(
            "--name {name}: lowercase letters, digits and '-', starting with a letter or digit"
        ));
    }
    let work =
        tempfile::Builder::new().prefix("cmux-remix-").tempdir().map_err(|e| e.to_string())?;
    let commit = fetch(work.path(), &source, base)?;
    let root = if source.path.is_empty() {
        work.path().to_path_buf()
    } else {
        work.path().join(&source.path)
    };
    if !root.is_dir() {
        return Err(format!(
            "{} has no folder {} at {}",
            source.repository(),
            source.path,
            short(&commit)
        ));
    }
    let manifest = manifest_file(&root).ok_or_else(|| {
        format!(
            "{} has no cmux-app.json at {}: it is not a cmux extension",
            source.display(None),
            short(&commit)
        )
    })?;
    let text = std::fs::read_to_string(root.join(manifest)).map_err(|e| e.to_string())?;
    let parsed: Value = serde_json::from_str(&text).map_err(|e| format!("{manifest}: {e}"))?;
    let old_id = parsed.field("id").as_str().unwrap_or_default().to_string();
    let name = options
        .name
        .clone()
        .or_else(|| id_name(&old_id))
        .or_else(|| id_name(&source.repo))
        .unwrap_or_else(|| "remix".to_string());
    let dir = match &options.dir {
        Some(dir) => {
            if std::fs::read_dir(dir).is_ok_and(|mut entries| entries.next().is_some()) {
                return Err(format!("{} already exists and is not empty", dir.display()));
            }
            dir.clone()
        }
        None => free_folder(&projects_root(home), &name),
    };
    copy_tree(&root, &dir)?;
    let app = format!("local/{name}");
    if !old_id.is_empty() {
        rename_id(&dir, &old_id, &app)?;
    }
    let path = dir.join(manifest);
    let text = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    if let Some(text) = with_repository(&text, None) {
        std::fs::write(&path, text).map_err(|e| e.to_string())?;
    }
    let readme = std::fs::read_to_string(dir.join("README.md")).unwrap_or_default();
    std::fs::write(dir.join("README.md"), remixed_readme(&readme, &source, &commit))
        .map_err(|e| e.to_string())?;
    let report = cmux_app_manifest::validate_package_file(&dir, manifest);
    let issues = report
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
    let init = run_quiet(git(&dir).args(["init", "-q", "-b", "main"]))
        .or_else(|_| run_quiet(git(&dir).args(["init", "-q"])));
    let committed = init.is_ok()
        && run_quiet(git(&dir).args(["add", "-A"])).is_ok()
        && run_quiet(git(&dir).args([
            "commit",
            "-q",
            "-m",
            &format!("Remix of {}", source.display(Some(&commit))),
        ]))
        .is_ok();
    Ok(Remix { source, commit, dir, name, app, manifest, issues, committed })
}
