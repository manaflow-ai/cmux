//! What a chat's Cloud machine is sized for, read from the chat's folder with no prompt
//! (leo-workspace design/cloud-work-mode.md, "Auto-sizing": the person never picks a machine, a
//! size or an environment). The app runs the local git commands (bounded, no network) and lists
//! the folder; here their output becomes `POST /api/vm`'s `autosize` (web/services/vms/autosize.ts).

use crate::machine_repo::{self, Repo};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

/// The server's limits (autosize.ts `parseAutosizeRepo`): at most 500 names of at most 255
/// characters, a key of at most 200 characters.
pub const MAX_ROOT_FILES: usize = 500;
pub const MAX_NAME_LENGTH: usize = 255;
pub const MAX_KEY_LENGTH: usize = 200;

/// The words that make a chat a test run.
pub const TEST_WORDS: [&str; 8] =
    ["test", "tests", "testing", "e2e", "xctest", "pytest", "vitest", "jest"];
/// The words that make a chat a build.
pub const BUILD_WORDS: [&str; 7] =
    ["build", "builds", "building", "rebuild", "compile", "compiles", "compiling"];

/// `autosize.taskKind`: a chat is light work whatever the repo; a build or a test gets the
/// fleet's measured grant for the repo's toolchain.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskKind {
    #[default]
    Chat,
    Build,
    Test,
}

/// The kind the chat's own words make obvious, else a chat. Kept simple on purpose, and it is the
/// whole rule: a word that names testing makes it a test; else a word that names building makes
/// it a build. Whole words only, so "latest" or "rebuilding trust" name no task, and testing wins
/// over building because a test run builds first.
pub fn task_kind(text: Option<&str>) -> TaskKind {
    let Some(text) = text else { return TaskKind::Chat };
    let lower = text.to_lowercase();
    let words: BTreeSet<&str> =
        lower.split(|c: char| !c.is_alphanumeric()).filter(|word| !word.is_empty()).collect();
    if TEST_WORDS.iter().any(|word| words.contains(word)) {
        TaskKind::Test
    } else if BUILD_WORDS.iter().any(|word| words.contains(word)) {
        TaskKind::Build
    } else {
        TaskKind::Chat
    }
}

/// `POST /api/vm`'s `autosize`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Autosize {
    pub task_kind: TaskKind,
    pub repo_key: Option<String>,
    pub repo_size_mb: Option<i64>,
    pub root_files: Vec<String>,
}

impl Autosize {
    /// The JSON object the create sends: the task kind, and the repo's key, size and root files
    /// when there are any.
    pub fn body(&self) -> Value {
        let mut repo = Map::new();
        if let Some(key) = &self.repo_key {
            repo.insert("key".into(), json!(key));
        }
        if let Some(size) = self.repo_size_mb {
            repo.insert("sizeMb".into(), json!(size));
        }
        if !self.root_files.is_empty() {
            repo.insert("rootFiles".into(), json!(self.root_files));
        }
        let mut body = Map::new();
        body.insert("taskKind".into(), serde_json::to_value(self.task_kind).unwrap_or(Value::Null));
        if !repo.is_empty() {
            body.insert("repo".into(), Value::Object(repo));
        }
        Value::Object(body)
    }
}

/// `for-each-ref`'s `%(upstream:remoteref) NUL %(upstream:track) NUL %(upstream:remotename)`: the
/// upstream's remote name, the third field; none for none or one git can't take as a name.
pub fn remote_name(line: &str) -> Option<String> {
    let name = line.split('\0').nth(2)?;
    (!name.is_empty() && !name.starts_with('-') && !name.contains(['\n', '\r']))
        .then(|| name.to_owned())
}

/// Pushed when there is an upstream and it is neither gone nor behind this branch (`[ahead N]`).
pub fn is_pushed(line: &str) -> bool {
    let mut parts = line.splitn(2, '\0');
    let upstream = parts.next().unwrap_or("");
    let track = parts.next().unwrap_or("");
    !upstream.is_empty() && !track.contains("ahead") && !track.contains("gone")
}

/// The branch as the remote names it (`refs/heads/topic` there), never the local tracking ref's tail.
pub fn remote_branch(line: &str) -> Option<String> {
    line.split('\0').next()?.strip_prefix("refs/heads/").map(str::to_owned)
}

/// `count-objects -v`'s loose `size` plus `size-pack` (KiB), in whole MiB, at least 1.
pub fn objects_mb(text: &str) -> Option<i64> {
    let mut kib = 0i64;
    let mut seen = false;
    for line in text.lines() {
        let Some((name, value)) = line.split_once(':') else { continue };
        let (name, value) = (name.trim(), value.trim());
        if name != "size" && name != "size-pack" {
            continue;
        }
        let Ok(value) = value.parse::<i64>() else { continue };
        kib = kib.saturating_add(value);
        seen = true;
    }
    seen.then(|| kib.saturating_add(1023).checked_div(1024).unwrap_or(0).max(1))
}

/// `host/owner/name[/…]`, lower-cased, from a remote URL (`https://`, `ssh://`, `git://` or git's
/// scp form `user@host:path`). Only the host and the path are kept, never a login or a password,
/// and the key fits the server's form (autosize.ts `REPO_KEY`). A local path or a `file://` remote
/// has no key.
pub fn repo_key(remote: &str) -> Option<String> {
    let text = remote.trim();
    let (host, path) = if let Some((scheme, rest)) = text.split_once("://") {
        if !["https", "http", "ssh", "git"].contains(&scheme.to_lowercase().as_str()) {
            return None;
        }
        let (authority, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
        let host_port = authority.rsplit('@').next().unwrap_or(authority);
        let host = if host_port.starts_with('[') {
            host_port.split(']').next().map(|host| format!("{host}]")).unwrap_or_default()
        } else {
            host_port.split(':').next().unwrap_or("").to_owned()
        };
        let path = path.split(['?', '#']).next().unwrap_or("");
        if host.is_empty() || path.contains(char::is_whitespace) {
            return None;
        }
        (host, path.to_owned())
    } else if let Some(colon) = text.find(':').filter(|_| !text.starts_with('/')) {
        let (authority, rest) = text.split_at_checked(colon)?;
        let rest = rest.strip_prefix(':').unwrap_or(rest);
        (authority.rsplit('@').next().unwrap_or(authority).to_owned(), rest.to_owned())
    } else {
        return None;
    };
    let mut segments: Vec<String> =
        path.split('/').filter(|segment| !segment.is_empty()).map(str::to_owned).collect();
    if let Some(last) = segments.last_mut()
        && last.to_lowercase().ends_with(".git")
    {
        last.truncate(last.len().saturating_sub(4));
    }
    if segments.len() < 2
        || segments.iter().any(|segment| segment.is_empty() || segment == "." || segment == "..")
        || host.is_empty()
    {
        return None;
    }
    let key = std::iter::once(host).chain(segments).collect::<Vec<_>>().join("/").to_lowercase();
    let allowed = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || "._~-/".contains(c);
    (key.chars().count() <= MAX_KEY_LENGTH
        && key.chars().all(allowed)
        && key.starts_with(|c: char| c.is_ascii_alphanumeric()))
    .then_some(key)
}

/// The names at the folder's top within the server's limits: never `.git`, sorted.
pub fn root_files(names: &[String]) -> Vec<String> {
    let mut files: Vec<String> = names
        .iter()
        .filter(|name| *name != ".git" && name.chars().count() <= MAX_NAME_LENGTH)
        .cloned()
        .collect();
    files.sort();
    files.truncate(MAX_ROOT_FILES);
    files
}

/// What the app read for a chat in `folder`: each git command's trimmed output (none when it
/// failed, was empty or was not run) and the listing of the working copy's top.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    pub folder: String,
    /// The chat's prompt or title.
    pub text: Option<String>,
    /// The chat's agent (`codex`, `claude`, …).
    pub harness: Option<String>,
    /// `rev-parse --show-toplevel`.
    pub top: Option<String>,
    /// `symbolic-ref --quiet --short HEAD`.
    pub branch: Option<String>,
    /// `for-each-ref` of the branch's upstream ([`remote_name`]).
    pub upstream: Option<String>,
    /// `ls-remote --get-url`.
    pub remote: Option<String>,
    /// `count-objects -v`.
    pub objects: Option<String>,
    /// The names at the top.
    pub names: Vec<String>,
    /// The top has a `.cmux/machine.toml`.
    pub machine_config: bool,
}

/// Everything a Cloud machine for a chat needs, with the GitHub repository a new machine clones.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkPick {
    /// The working copy's top (git), else the chat's folder itself.
    pub root: String,
    pub repo_key: Option<String>,
    /// The GitHub repository a new machine can clone (`cloud new-machine --repo`), at
    /// `clone_ref` when that is set, else at the remote's default branch. None for a local
    /// path, a remote that is not GitHub, or no remote.
    pub repo: Option<Repo>,
    /// The branch the remote has, when this one is pushed, `repo` is set and the name is a safe
    /// ref ([`machine_repo::is_ref`]: the repo step single-quotes it, and git allows a `'`): the
    /// ref a new machine clones. `repo`'s own `ref`.
    pub clone_ref: Option<String>,
    pub branch: Option<String>,
    pub pushed: bool,
    pub size_mb: Option<i64>,
    pub root_files: Vec<String>,
    pub task_kind: TaskKind,
    pub has_machine_config: bool,
    /// The chat's agent is Codex, whose sign-in on a machine comes from the Codex broker.
    pub needs_codex_broker: bool,
}

pub fn work_pick(facts: &Facts) -> WorkPick {
    let pushed = facts.upstream.as_deref().is_some_and(is_pushed);
    // A local path remote (`../paint`, even `octo/paint`) has no key and names no GitHub repo.
    let key = facts.remote.as_deref().and_then(repo_key);
    let github = key
        .as_ref()
        .and(facts.remote.as_deref())
        .and_then(|remote| machine_repo::parse(remote).ok())
        .filter(Repo::is_github);
    // A branch name the repo step can't carry unquoted clones the default branch.
    let clone_ref = github
        .as_ref()
        .and(facts.upstream.as_deref())
        .and_then(remote_branch)
        .filter(|branch| pushed && machine_repo::is_ref(branch));
    let repo =
        github.map(|repo| Repo { r#ref: clone_ref.clone(), ..Repo::new(&repo.owner, &repo.name) });
    WorkPick {
        root: facts.top.clone().unwrap_or_else(|| facts.folder.clone()),
        repo_key: key,
        repo,
        clone_ref,
        branch: facts.branch.clone(),
        pushed,
        size_mb: facts.objects.as_deref().and_then(objects_mb),
        root_files: root_files(&facts.names),
        task_kind: task_kind(facts.text.as_deref()),
        has_machine_config: facts.machine_config,
        needs_codex_broker: facts.harness.as_deref() == Some("codex"),
    }
}

#[cfg(test)]
mod tests;
