//! The files a session's tool calls read and edited, and who else touches the same ones.
//!
//! Each `tool_call` or `tool_call_update` that names a file (its `locations`, a diff in its
//! content, `rawInput.file_path`) adds the file to the session's index (`SessionMeta::
//! touched_files`, `hub/touched.rs`): its repository, its path there, whether it was edited and
//! when. A file is keyed by repository and path in it, not by its path on disk, so two worktrees
//! of one repository, or two clones of it on two machines, name it the same way: the repository
//! is its `origin` remote (`github.com/OWNER/REPO`), else its common git directory.
//!
//! [`Query`] and [`rank`] answer "who else is working on these files": given files, a topic, a
//! branch or a worktree, the other sessions that touch them, best first. Everything here is pure
//! but the repository lookup ([`repo_of`]), which reads a few small git files and caches them.
//! Leo, 2026-11-05: "I feel like ACP mugs can maybe reveal that, like CMUX next can maybe do
//! that, like for other agents, other harnesses as well."

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

/// A session keeps at most this many files: the oldest go first.
pub const MAX_FILES: usize = 300;
/// How far back "recent" reaches when a query names no window: a day.
pub const DEFAULT_SINCE_MS: u64 = 24 * 60 * 60 * 1000;
/// The most files one answer row lists; `filesInCommon` counts them all.
const MAX_ROW_FILES: usize = 20;

/// One file a session touched.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TouchedFile {
    /// The repository ([`Repo::id`]); empty outside one, where `path` is absolute.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub repo: String,
    /// The path in the repository, `/`-separated.
    pub path: String,
    /// A tool call edited it (an edit, a write, a delete, a move); else it was only read.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub edited: bool,
    /// When it was last touched, Unix ms. A file a query names (`{repo, path}`) has none.
    #[serde(default)]
    pub at: u64,
    /// When it was last edited, Unix ms: a later read moves `at` on, not this. An index kept
    /// before this field has none, and its `at` stands in.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub edited_at: u64,
}

fn is_zero(n: &u64) -> bool {
    *n == 0
}

impl TouchedFile {
    fn key(&self) -> (&str, &str) {
        (&self.repo, &self.path)
    }

    /// It was edited at or after `since`, Unix ms.
    pub fn edited_since(&self, since: u64) -> bool {
        self.edited && (if self.edited_at == 0 { self.at } else { self.edited_at }) >= since
    }
}

/// A repository a file is in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Repo {
    /// The same on every machine for one GitHub repository: its `origin` remote without scheme,
    /// user and `.git` (`github.com/manaflow-ai/cmux`); else its common git directory.
    pub id: String,
    /// The worktree's top folder.
    pub root: PathBuf,
    /// The branch `origin/HEAD` names (the repository's default), when the clone has it.
    pub default_branch: Option<String>,
}

/// The repositories found so far, by worktree top folder (they never move under a live session).
static REPOS: LazyLock<Mutex<HashMap<PathBuf, Option<Repo>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// The repository `path` (absolute) is in, or `None` outside one. Read from git's own files,
/// never a git process (`git_state.rs`), and cached by worktree.
pub fn repo_of(path: &Path) -> Option<Repo> {
    let top = path.ancestors().find(|folder| folder.join(".git").exists())?;
    if let Some(known) = REPOS.lock().unwrap_or_else(|e| e.into_inner()).get(top) {
        return known.clone();
    }
    let repo = read_repo(top);
    let mut repos = REPOS.lock().unwrap_or_else(|e| e.into_inner());
    // A bound, not an LRU: a daemon sees a few hundred worktrees at most.
    if repos.len() > 4096 {
        repos.clear();
    }
    repos.insert(top.to_path_buf(), repo.clone());
    repo
}

fn read_repo(top: &Path) -> Option<Repo> {
    let dot_git = top.join(".git");
    let common = if dot_git.is_dir() {
        dot_git
    } else {
        let text = small_file(&dot_git)?;
        let git_dir = top.join(text.strip_prefix("gitdir:")?.trim());
        match small_file(&git_dir.join("commondir")) {
            Some(common) => git_dir.join(common.trim()),
            None => git_dir,
        }
    };
    let common = std::fs::canonicalize(&common).unwrap_or(common);
    let id = std::fs::read_to_string(common.join("config"))
        .ok()
        .and_then(|config| origin_url(&config))
        .and_then(|url| remote_id(&url))
        .unwrap_or_else(|| common.to_string_lossy().into_owned());
    let default_branch = small_file(&common.join("refs/remotes/origin/HEAD"))
        .and_then(|head| head.trim().strip_prefix("ref: refs/remotes/origin/").map(str::to_owned));
    Some(Repo { id, root: top.to_path_buf(), default_branch })
}

fn small_file(path: &Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    (meta.len() <= 4096).then(|| std::fs::read_to_string(path).ok()).flatten()
}

/// The `url` of `[remote "origin"]` in a git config.
fn origin_url(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines().map(str::trim) {
        if line.starts_with('[') {
            in_origin = line.replace(' ', "") == "[remote\"origin\"]";
        } else if in_origin
            && let Some((key, value)) = line.split_once('=')
            && key.trim() == "url"
        {
            return Some(value.trim().to_owned());
        }
    }
    None
}

/// `https://github.com/o/r.git`, `git@github.com:o/r`, `ssh://git@github.com/o/r` all become
/// `github.com/o/r`, lowercased; a local path stays as it is.
pub fn remote_id(url: &str) -> Option<String> {
    let url = url.trim();
    if url.is_empty() {
        return None;
    }
    let rest = match url.split_once("://") {
        Some((_, rest)) => rest.to_owned(),
        // scp-like `user@host:path`, not a Windows drive or a local path.
        None => match url.split_once(':') {
            Some((host, path)) if !host.contains('/') && host.len() > 1 => format!("{host}/{path}"),
            _ => return Some(url.to_owned()),
        },
    };
    let rest = rest.rsplit_once('@').map_or(rest.as_str(), |(_, r)| r);
    let rest = rest.trim_end_matches('/').trim_end_matches(".git");
    Some(rest.replace(":/", "/").to_lowercase())
}

/// The file `abs` (absolute, canonical) as the index keys it: its repository and path there.
pub fn key_of(abs: &str) -> (String, String) {
    let path = Path::new(abs);
    match repo_of(path) {
        Some(repo) => match path.strip_prefix(&repo.root) {
            Ok(rel) => (repo.id, rel.to_string_lossy().replace('\\', "/")),
            Err(_) => (String::new(), abs.to_owned()),
        },
        None => (String::new(), abs.to_owned()),
    }
}

/// The files a tool update names, as written (the canonical form beside each when the hub has
/// added it), and whether the call edits them: `Some(true)` for an edit, delete or move or a
/// call carrying a diff, `Some(false)` for a read or search, `None` when the update says neither
/// (a later update of a call keeps what its first said).
pub fn paths_of(update: &Value) -> (Vec<String>, Option<bool>) {
    let mut out: Vec<String> = vec![];
    let mut add = |v: &Value| {
        let canon = v.pointer("/_meta/acpmux/canonicalPath").and_then(Value::as_str);
        if let Some(p) = canon.or_else(|| v.get("path").and_then(Value::as_str))
            && !p.is_empty()
            && !out.iter().any(|o| o == p)
        {
            out.push(p.to_owned());
        }
    };
    for location in update.get("locations").and_then(Value::as_array).into_iter().flatten() {
        add(location);
    }
    let mut diff = false;
    for block in update.get("content").and_then(Value::as_array).into_iter().flatten() {
        if block.get("type").and_then(Value::as_str) == Some("diff") {
            diff = true;
            add(block);
        }
    }
    if let Some(input) = update.get("rawInput") {
        for key in ["file_path", "filePath", "notebook_path"] {
            if let Some(p) = input.get(key).and_then(Value::as_str) {
                let canon = update.pointer("/_meta/acpmux/canonicalPath").and_then(Value::as_str);
                add(&json!({"path": canon.filter(|_| key == "file_path").unwrap_or(p)}));
            }
        }
    }
    let edited = match update.get("kind").and_then(Value::as_str) {
        Some("edit" | "delete" | "move") => Some(true),
        _ if diff => Some(true),
        Some("read" | "search") => Some(false),
        Some(_) if !out.is_empty() => Some(false),
        _ => None,
    };
    (out, edited)
}

/// Adds `file` to `files`, or moves its time on (an edit stays an edit, at the time it was made). Past [`MAX_FILES`] the
/// least recently touched goes.
pub fn merge(files: &mut Vec<TouchedFile>, file: TouchedFile) {
    let edited_at = if file.edited { file.edited_at.max(file.at) } else { 0 };
    if let Some(old) = files.iter_mut().find(|f| f.key() == file.key()) {
        old.at = old.at.max(file.at);
        old.edited |= file.edited;
        old.edited_at = old.edited_at.max(edited_at);
        return;
    }
    files.push(TouchedFile { edited_at, ..file });
    if files.len() > MAX_FILES
        && let Some((oldest, _)) = files.iter().enumerate().min_by_key(|(_, f)| f.at)
    {
        files.swap_remove(oldest);
    }
}

/// What a who-else question asks about. Any of its parts makes a match.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Query {
    /// Files, keyed as the index keys them (`repo`, `path`; `edited` and `at` unused).
    #[serde(default)]
    pub files: Vec<TouchedFile>,
    /// The asker's repository and branch: another clone on the same branch matches.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    /// The asker's worktree top folder on this machine: another session in it matches.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
    /// Words a session's name, title or last prompt must share.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub topic: Option<String>,
    /// Only files touched and sessions active since this Unix ms count.
    #[serde(default)]
    pub since: u64,
    /// The asker's session and the root of its tree: neither it nor its own sub-sessions are
    /// "someone else".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exclude_root: Option<String>,
}

/// One session a who-else question looks at.
#[derive(Debug, Clone, Default)]
pub struct Candidate {
    pub session_id: String,
    pub root: String,
    pub name: String,
    pub title: Option<String>,
    pub last_prompt: Option<String>,
    pub harness: String,
    pub status: String,
    pub cwd: String,
    pub repo: Option<String>,
    pub worktree: Option<String>,
    pub branch: Option<String>,
    pub default_branch: Option<String>,
    pub pull_requests: Vec<String>,
    pub updated_at: u64,
    pub files: Vec<TouchedFile>,
}

/// Words that say nothing about a topic.
const STOPWORDS: &[&str] = &[
    "about", "after", "also", "from", "have", "into", "just", "like", "make", "more", "only",
    "other", "same", "should", "that", "their", "them", "then", "there", "these", "this", "what",
    "when", "where", "which", "with", "work", "working", "would", "your", "else", "files", "file",
];

/// A topic's significant words: lowercase, four letters or more, no stopwords, once each.
pub fn topic_words(text: &str) -> BTreeSet<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .map(str::to_lowercase)
        .filter(|w| w.chars().count() >= 4 && !STOPWORDS.contains(&w.as_str()))
        .collect()
}

/// Branches every clone has: sitting on one is not working on the same thing.
fn shared_branch(branch: &str, default_branch: Option<&str>) -> bool {
    matches!(branch, "main" | "master") || Some(branch) == default_branch
}

/// How `c` matches `q`, as an answer row, or `None` when it does not. `host` is the machine the
/// row is on (`None` for this one).
pub fn row(q: &Query, c: &Candidate, now: u64) -> Option<Value> {
    if q.exclude_root.as_deref().is_some_and(|r| r == c.root || r == c.session_id) {
        return None;
    }
    let active = c.updated_at.max(c.files.iter().map(|f| f.at).max().unwrap_or(0));
    let live = matches!(c.status.as_str(), "running" | "waiting" | "ready" | "idle");
    if active < q.since && !matches!(c.status.as_str(), "running" | "waiting") {
        return None;
    }
    let mut common: Vec<&TouchedFile> = c
        .files
        .iter()
        .filter(|f| f.at >= q.since && q.files.iter().any(|w| w.key() == f.key()))
        .collect();
    let edit = |f: &TouchedFile| f.edited_since(q.since);
    common.sort_by(|a, b| edit(b).cmp(&edit(a)).then(b.at.cmp(&a.at)));
    let same_worktree = q.worktree.is_some() && q.worktree == c.worktree;
    let same_branch = !same_worktree
        && q.repo.is_some()
        && q.repo == c.repo
        && q.branch.as_deref().is_some_and(|b| {
            c.branch.as_deref() == Some(b) && !shared_branch(b, c.default_branch.as_deref())
        });
    let topic: Vec<String> = match q.topic.as_deref().map(topic_words) {
        Some(want) if !want.is_empty() => {
            let text = [Some(c.name.as_str()), c.title.as_deref(), c.last_prompt.as_deref()]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" ");
            let have = topic_words(&text);
            let hit: Vec<String> = want.intersection(&have).cloned().collect();
            // Most of a long topic, or all of a one-word one.
            let enough = hit.len() >= 2.min(want.len()) && hit.len() * 2 >= want.len();
            if enough { hit } else { vec![] }
        }
        _ => vec![],
    };
    if common.is_empty() && !same_worktree && !same_branch && topic.is_empty() {
        return None;
    }
    let edited = common.iter().filter(|f| edit(f)).count();
    // Edits in common first, then reads, then the rest; recency breaks ties (`rank`).
    let score = edited * 100
        + (common.len() - edited) * 10
        + usize::from(same_worktree) * 50
        + usize::from(same_branch) * 50
        + topic.len() * 5;
    let files: Vec<Value> = common
        .iter()
        .take(MAX_ROW_FILES)
        .map(|f| json!({"repo": f.repo, "path": f.path, "edited": edit(f), "at": f.at}))
        .collect();
    Some(json!({
        "sessionId": c.session_id,
        "name": c.name,
        "title": c.title,
        "harness": c.harness,
        "status": c.status,
        "live": live,
        "cwd": c.cwd,
        "branch": c.branch,
        "pullRequests": c.pull_requests,
        "lastActiveAt": active,
        "agoMs": now.saturating_sub(active),
        "filesInCommon": common.len(),
        "editedInCommon": edited,
        "files": files,
        "sameWorktree": same_worktree,
        "sameBranch": same_branch,
        "topicWords": topic,
        "score": score,
    }))
}

/// Answer rows best first: score, then the most recently active.
pub fn rank(rows: &mut [Value]) {
    let n = |r: &Value, k: &str| r.get(k).and_then(Value::as_u64).unwrap_or(0);
    rows.sort_by(|a, b| {
        n(b, "score").cmp(&n(a, "score")).then(n(b, "lastActiveAt").cmp(&n(a, "lastActiveAt")))
    });
}

/// The one-line text of an answer row: `lane-x (codex on big-red, lane/x, #123): edited
/// src/a.rs, read src/b.rs; 12m ago`.
pub fn row_line(r: &Value) -> String {
    let s = |k: &str| r.get(k).and_then(Value::as_str).unwrap_or("");
    let mut about = vec![if s("host").is_empty() {
        s("harness").to_owned()
    } else {
        format!("{} on {}", s("harness"), s("host"))
    }];
    if !s("branch").is_empty() {
        about.push(s("branch").to_owned());
    }
    for pr in r.get("pullRequests").and_then(Value::as_array).into_iter().flatten() {
        if let Some(n) = pr.as_str().and_then(|u| u.rsplit('/').next()) {
            about.push(format!("#{n}"));
        }
    }
    let mut what = vec![];
    let files: Vec<&Value> =
        r.get("files").and_then(Value::as_array).into_iter().flatten().collect();
    let shown = |edited: bool| -> Vec<String> {
        files
            .iter()
            .filter(|f| f.get("edited").and_then(Value::as_bool) == Some(edited))
            .take(3)
            .filter_map(|f| f.get("path").and_then(Value::as_str).map(str::to_owned))
            .collect()
    };
    let edited = shown(true);
    let read = shown(false);
    let total = r.get("filesInCommon").and_then(Value::as_u64).unwrap_or(0) as usize;
    if !edited.is_empty() {
        what.push(format!("edited {}", edited.join(", ")));
    }
    if !read.is_empty() {
        what.push(format!("read {}", read.join(", ")));
    }
    if total > edited.len() + read.len() {
        what.push(format!("+{} more", total - edited.len() - read.len()));
    }
    if r.get("sameWorktree").and_then(Value::as_bool) == Some(true) {
        what.push("in this worktree".to_owned());
    }
    if r.get("sameBranch").and_then(Value::as_bool) == Some(true) {
        what.push("on this branch".to_owned());
    }
    if let Some(words) = r.get("topicWords").and_then(Value::as_array).filter(|w| !w.is_empty()) {
        let words: Vec<&str> = words.iter().filter_map(Value::as_str).collect();
        what.push(format!("topic: {}", words.join(", ")));
    }
    let ago = r.get("agoMs").and_then(Value::as_u64).unwrap_or(0);
    format!("{} ({}): {}; {}", s("name"), about.join(", "), what.join("; "), ago_text(ago))
}

/// `now`, `12m ago`, `3h ago`, `2d ago`.
pub fn ago_text(ms: u64) -> String {
    let m = ms / 60_000;
    match m {
        0 => "now".to_owned(),
        1..=59 => format!("{m}m ago"),
        60..=2879 => format!("{}h ago", m / 60),
        _ => format!("{}d ago", m / 1440),
    }
}

#[cfg(test)]
#[path = "touched_files_tests.rs"]
mod tests;
