//! Folder trust (`acp.trust.get` / `acp.trust.set`), owned by acpmux.
//!
//! `get` is a read-only projection: each agent's own level for the folder,
//! read from Claude Code's `~/.claude.json` (`projects[cwd].hasTrustDialogAccepted`)
//! and Codex's `~/.codex/config.toml` (`[projects."<cwd>"] trust_level`), and
//! acpmux's own decision for the folder. Those agent files keep their one
//! writer; acpmux never writes them. `set` records the user's decision in
//! acpmux's own per-folder record (`<home>/trust.json`); level `unknown`
//! clears it, so each agent's own level answers again.
//!
//! A folder in a git repository (`repository`) with no decision of its own takes its linked
//! worktree's decision, else its repository's, and that answers it as its own would (before
//! each agent's level): "Trust this repo" answers every worktree of it once, Not now holds in
//! every one, and a worktree cmux makes for a chat is never asked about again.
//! Nothing else is inherited: a decision for a plain folder covers that folder alone, and a
//! repository at or above home (or with home unknown) is never answered as a whole.
//!
//! A folder the app made for a new chat (agent-home, `made_by_cmux`), and a worktree cmux made
//! (`~/.cmux/worktrees/<project>/<name>`, `cmux_worktree`), is trusted by construction when
//! acpmux has no record for it: nobody is asked. An agent's own untrusted level, for the
//! worktree or its repository, still holds a cmux worktree, and for a Web client it counts as
//! an auto-trust rule does: no person's answer.
//! A folder under the person's project roots, or in a repository whose remotes are all the
//! person's own organizations, is trusted the same way (`trust_auto.rs`, switchable in Settings);
//! an explicit "Don't trust" or an agent's own untrusted level still wins.
//! These rules serve `get` and the trust gate (`session_level`) alike.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::no_panic::JsonExt;
use serde_json::{Value, json};

/// A folder's trust: what the pane shows and asks about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Trusted,
    Untrusted,
    Unknown,
}

impl Level {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "trusted" => Some(Self::Trusted),
            "untrusted" => Some(Self::Untrusted),
            "unknown" => Some(Self::Unknown),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Trusted => "trusted",
            Self::Untrusted => "untrusted",
            Self::Unknown => "unknown",
        }
    }

    /// The stricter of two levels: untrusted over unknown over trusted.
    pub fn stricter(self, other: Self) -> Self {
        let rank = |level: Self| match level {
            Self::Untrusted => 0,
            Self::Unknown => 1,
            Self::Trusted => 2,
        };
        if rank(self) <= rank(other) { self } else { other }
    }
}

/// Where the agents' files and acpmux's record live.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Paths {
    pub claude_json: PathBuf,
    pub codex_config: PathBuf,
    pub record: PathBuf,
    /// The folder that holds cmux's agent-home folders (`agent_home_root`): the private folder
    /// cmux makes for each new chat in a workspace without a folder. None: no such folder.
    pub agent_home: Option<PathBuf>,
    /// The folder cmux makes its worktrees in (`cmux_worktrees_root`): a linked worktree at
    /// `<root>/<project>/<name>` is one cmux made. None: no such folder.
    pub cmux_worktrees: Option<PathBuf>,
}

impl Paths {
    /// The user's files and this daemon's record (`config::home()`).
    pub fn current() -> Option<Self> {
        let user = dirs::home_dir()?;
        Some(Self {
            claude_json: user.join(".claude.json"),
            codex_config: user.join(".codex").join("config.toml"),
            record: crate::config::home().join("trust.json"),
            agent_home: agent_home_root(),
            cmux_worktrees: cmux_worktrees_root(),
        })
    }
}

/// `~/Library/Application Support/cmux/agent-home` on macOS (the app's `AgentHome.standard`):
/// the app makes each workspace's agent-home folder there.
pub fn agent_home_root() -> Option<PathBuf> {
    dirs::data_dir().map(|data| data.join("cmux").join("agent-home"))
}

/// `~/.cmux/worktrees` (`cmux_git::worktree_root`), where cmux makes the worktrees for its chats
/// and lanes, on every host.
pub fn cmux_worktrees_root() -> Option<PathBuf> {
    dirs::home_dir().map(|home| cmux_git::worktree_root::worktree_root_path(&home))
}

/// The file the app writes in each agent-home folder it makes (`AgentHome.ensure`).
pub const AGENT_HOME_MARKER: &str = ".cmux-agent-home";

/// A folder path the record can key: absolute, without a trailing slash.
/// The path is resolved (symlinks, `.` and `..`, /tmp vs /private/tmp) when it exists,
/// so one folder has one key.
pub fn normalize_cwd(cwd: &str) -> Result<String, String> {
    if cwd.is_empty() || !Path::new(cwd).is_absolute() {
        return Err(format!("cwd must be an absolute path, got {cwd:?}"));
    }
    let resolved = std::fs::canonicalize(cwd).map(|path| path.to_string_lossy().into_owned());
    let path = resolved.unwrap_or_else(|_| cwd.to_owned());
    let without_slash = path.trim_end_matches('/');
    Ok(if without_slash.is_empty() { "/".to_owned() } else { without_slash.to_owned() })
}

/// `cwd` and its parent folders, nearest first: an agent that trusts a folder
/// trusts what is inside it.
fn ancestors(cwd: &str) -> impl Iterator<Item = &str> {
    Path::new(cwd).ancestors().filter_map(Path::to_str).filter(|path| !path.is_empty())
}

/// Claude Code's level: trusted once its trust dialog was accepted for the folder.
pub fn claude_level(claude_json: &str, cwd: &str) -> Level {
    let Ok(value) = serde_json::from_str::<Value>(claude_json) else { return Level::Unknown };
    let Some(projects) = value.get("projects") else { return Level::Unknown };
    let accepted = |path: &str| {
        projects
            .get(path)
            .and_then(|project| project.get("hasTrustDialogAccepted"))
            .and_then(Value::as_bool)
            == Some(true)
    };
    if ancestors(cwd).any(accepted) { Level::Trusted } else { Level::Unknown }
}

/// Codex's level from `[projects."<path>"] trust_level = "…"` in its config.toml,
/// for the folder or its nearest parent that has one.
pub fn codex_level(config_toml: &str, cwd: &str) -> Level {
    let Ok(config) = config_toml.parse::<toml::Table>() else { return Level::Unknown };
    let Some(projects) = config.get("projects").and_then(toml::Value::as_table) else {
        return Level::Unknown;
    };
    ancestors(cwd)
        .find_map(|path| projects.get(path)?.get("trust_level")?.as_str().and_then(Level::parse))
        .unwrap_or(Level::Unknown)
}

/// Serializes `set`'s read, change and write of the record within this daemon.
static RECORD_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Why a trust call failed: a bad request, or the record could not be read or written.
#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    Invalid(String),
    Record(String),
}

/// acpmux's record; a missing file is empty, an unreadable one is an error, so a
/// damaged record is never overwritten with a fresh one.
fn read_record(path: &Path) -> Result<BTreeMap<String, String>, Failure> {
    let mut file = match crate::config::private_state_file(path) {
        Ok(file) => file,
        Err(_)
            if std::fs::symlink_metadata(path)
                .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
        {
            return Ok(BTreeMap::new());
        }
        Err(error) => {
            return Err(Failure::Record(format!("trust record {}: {error:#}", path.display())));
        }
    };
    let mut text = String::new();
    match file.read_to_string(&mut text) {
        Ok(_) => serde_json::from_str(&text).map_err(|e| {
            Failure::Record(format!("trust record {} is damaged: {e}", path.display()))
        }),
        Err(e) => Err(Failure::Record(format!("trust record {}: {e}", path.display()))),
    }
}

/// The git repository that holds a folder: its main working tree's root, and for a linked
/// worktree that worktree's own root.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Repository {
    pub root: PathBuf,
    /// The linked worktree's root; None in the main working tree.
    pub worktree: Option<PathBuf>,
}

/// The repository holding `cwd` (canonical), from what git wrote: a `.git` folder, or a linked
/// worktree's `.git` file whose gitdir is `<repository>/.git/worktrees/<name>`, names the file
/// back (`<gitdir>/gitdir`) and has a `commondir` resolving to that same `.git`. Everything
/// checked lives in the repository's own `.git`, so a `.git` file written by hand to point at a
/// trusted repository (or at a gitdir of its own whose `commondir` names one) proves nothing,
/// and neither does a submodule's (no `commondir`) or a bare repository's worktree. Relative
/// paths (`worktree.useRelativePaths`) resolve against the file that holds them.
pub fn repository(cwd: &Path) -> Option<Repository> {
    for folder in cwd.ancestors() {
        let dot_git = folder.join(".git");
        let Ok(meta) = std::fs::symlink_metadata(&dot_git) else { continue };
        if meta.is_dir() {
            return Some(Repository { root: folder.to_path_buf(), worktree: None });
        }
        if !meta.is_file() {
            return None;
        }
        let text = std::fs::read_to_string(&dot_git).ok()?;
        let gitdir =
            std::fs::canonicalize(folder.join(text.trim().strip_prefix("gitdir:")?.trim())).ok()?;
        let back = std::fs::read_to_string(gitdir.join("gitdir")).ok()?;
        if std::fs::canonicalize(gitdir.join(back.trim())).ok()?
            != std::fs::canonicalize(&dot_git).ok()?
        {
            return None;
        }
        let common = std::fs::read_to_string(gitdir.join("commondir")).ok()?;
        let common = std::fs::canonicalize(gitdir.join(common.trim())).ok()?;
        if common.file_name()? != ".git" || gitdir.parent()? != common.join("worktrees") {
            return None;
        }
        let root = common.parent()?.to_path_buf();
        return Some(Repository { root, worktree: Some(folder.to_path_buf()) });
    }
    None
}

/// Whether a repository at `root` may be answered as a whole: never the home folder or above
/// it (a dotfiles repository at home holds every folder in it), and never with home unknown.
fn answerable_whole(root: &Path, home: Option<&Path>) -> bool {
    home.is_some_and(|home| !home.starts_with(root))
}

/// acpmux's decision for `cwd` and the folder it was made for: the folder's own; else its
/// linked worktree's, else its repository's (`answerable_whole`). A person made each of them
/// in cmux for this folder or the repository holding it, so it answers before any agent's own
/// level, which may come from any folder above.
fn decision(
    record: &BTreeMap<String, String>,
    cwd: &str,
    repo: Option<&Repository>,
    home: Option<&Path>,
) -> Option<(String, Level)> {
    let at = |folder: &Path| {
        let folder = folder.to_str()?;
        Some((folder.to_owned(), Level::parse(record.get(folder)?)?))
    };
    at(Path::new(cwd)).or_else(|| {
        let repo = repo.filter(|repo| answerable_whole(&repo.root, home))?;
        repo.worktree.as_deref().and_then(at).or_else(|| at(&repo.root))
    })
}

/// `acp.trust.get {cwd}` → `{cwd, level, harnesses: {claude, codex}, decided, via?, repo?}`.
pub fn get(paths: &Paths, cwd: &str) -> Result<Value, Failure> {
    let home = dirs::home_dir().and_then(|home| std::fs::canonicalize(home).ok());
    get_at(paths, cwd, home.as_deref())
}

/// `get` with the home folder named (tests use their own).
fn get_at(paths: &Paths, cwd: &str, home: Option<&Path>) -> Result<Value, Failure> {
    let cwd = normalize_cwd(cwd).map_err(Failure::Invalid)?;
    let claude =
        claude_level(&std::fs::read_to_string(&paths.claude_json).unwrap_or_default(), &cwd);
    let codex =
        codex_level(&std::fs::read_to_string(&paths.codex_config).unwrap_or_default(), &cwd);
    let repo = repository(Path::new(&cwd));
    let found = decision(&read_record(&paths.record)?, &cwd, repo.as_ref(), home);
    let decided = found.as_ref().map(|(_, level)| *level);
    // The folder the decision was made for, when it is not this one: Undo forgets it there.
    let via = found.map(|(folder, _)| folder).filter(|folder| *folder != cwd);
    // A worktree cmux made, unless an agent already holds it, or its repository, as untrusted.
    let worktree = claude.stricter(codex) != Level::Untrusted
        && paths.cmux_worktrees.as_deref().is_some_and(|root| cmux_worktree(root, repo.as_ref()))
        && repo.as_ref().is_some_and(|repo| agents_level(paths, &repo.root) != Level::Untrusted);
    // The repository the pane offers to trust as a whole.
    let repo = repo.filter(|repo| answerable_whole(&repo.root, home));
    let agent_home = paths.agent_home.as_deref().is_some_and(|root| made_by_cmux(root, &cwd));
    // The person's own folders (project roots, own organizations) need no question, unless an
    // agent already holds the folder as untrusted: the rule widens an unknown, never a refusal.
    // A worktree cmux made is answered the same way: like a rule, it is no person's answer for a
    // Web client (`level_in`), since it holds its repository's content.
    let auto = (decided.is_none() && !agent_home && claude.stricter(codex) != Level::Untrusted)
        .then(|| {
            if worktree {
                Some(WORKTREE)
            } else {
                crate::trust_auto::AutoTrust::current().reason(&cwd).map(|r| r.label())
            }
        })
        .flatten();
    // acpmux's own decision answers first; then a folder cmux made (for a chat, or a worktree)
    // or one of the person's own (trusted by construction); then the stricter of the agents'
    // levels.
    let level = decided.unwrap_or_else(|| {
        if agent_home || auto.is_some() { Level::Trusted } else { claude.stricter(codex) }
    });
    Ok(json!({
        "cwd": cwd,
        "level": level.as_str(),
        "harnesses": {"claude": claude.as_str(), "codex": codex.as_str()},
        // acpmux answered (its record, its rule for folders cmux made, or an auto-trust rule):
        // `level` holds for every agent.
        "decided": decided.is_some() || agent_home || auto.is_some(),
        // Why no question was asked (`root`, `org` or `worktree`); absent otherwise.
        "auto": auto,
        // The folder acpmux's decision was made for (a worktree's root, or its repository).
        "via": via,
        // The repository holding the folder: what "Trust this repo" records.
        "repo": repo.map(|repo| json!({
            "root": repo.root.to_string_lossy(),
            "worktree": repo.worktree.is_some(),
        })),
    }))
}

/// The person's own decision for `cwd` in acpmux's record, or None: never an
/// agent's level, and never the agent-home rule.
pub fn person_decision(paths: &Paths, cwd: &str) -> Result<Option<Level>, Failure> {
    let cwd = normalize_cwd(cwd).map_err(Failure::Invalid)?;
    Ok(read_record(&paths.record)?.get(&cwd).and_then(|level| Level::parse(level)))
}

/// Whether `cwd` (normalized: canonical when it exists) is an agent-home folder the app made: a
/// real folder that is a direct child of the canonical `root`, holding the app's marker as a
/// regular file. A symlink in agent-home resolves to its target, which is then no child of the
/// root; a folder inside an agent-home folder is not one either.
fn made_by_cmux(root: &Path, cwd: &str) -> bool {
    let Ok(root) = std::fs::canonicalize(root) else { return false };
    let path = Path::new(cwd);
    if path.parent() != Some(root.as_path()) {
        return false;
    }
    // The path is its own canonical spelling and a folder, never a symlink to one.
    let canonical = std::fs::canonicalize(path).is_ok_and(|resolved| resolved == path);
    let folder = std::fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_dir());
    let marker = std::fs::symlink_metadata(path.join(AGENT_HOME_MARKER))
        .is_ok_and(|meta| meta.file_type().is_file());
    canonical && folder && marker
}

/// `get`'s `auto` for a worktree cmux made (`cmux_worktree`).
pub const WORKTREE: &str = "worktree";

/// The stricter of the agents' own levels for `folder`.
fn agents_level(paths: &Paths, folder: &Path) -> Level {
    let folder = folder.to_string_lossy();
    let read = |path: &Path| std::fs::read_to_string(path).unwrap_or_default();
    claude_level(&read(&paths.claude_json), &folder)
        .stricter(codex_level(&read(&paths.codex_config), &folder))
}

/// Whether `repo` is a linked worktree cmux made: one git wrote (`repository`) directly at
/// `<root>/<project>/<name>`, the canonical `root` being cmux's worktree folder. A plain folder
/// there is not one, nor is a folder inside a repository's main working tree.
fn cmux_worktree(root: &Path, repo: Option<&Repository>) -> bool {
    let Ok(root) = std::fs::canonicalize(root) else { return false };
    repo.and_then(|repo| repo.worktree.as_deref())
        .and_then(Path::parent)
        .and_then(Path::parent)
        .is_some_and(|parent| parent == root)
}

/// A folder's trust for a session of one agent, read once: with the auto-trust rules
/// (`trust_auto.rs`) and without them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionTrust {
    /// The folder's record key (`normalize_cwd`).
    pub cwd: String,
    /// The level the app's pane goes by ([`session_level`]): an auto-trust rule answers.
    pub level: Level,
    /// The level without the auto-trust rules ([`web_session_level`]): acpmux's record (a
    /// person's answer), a folder cmux made for a chat, or the agent's own level.
    pub decided: Level,
}

impl SessionTrust {
    /// Trusted by an auto-trust rule alone: no person (nor cmux) decided it.
    pub fn by_rule_only(&self) -> bool {
        self.level == Level::Trusted && self.decided != Level::Trusted
    }
}

/// The folder's level for a session of the agent `family`, with and without the auto-trust
/// rules (see [`session_level`]).
pub fn session_trust(paths: &Paths, cwd: &str, family: &str) -> Result<SessionTrust, Failure> {
    let reply = get(paths, cwd)?;
    Ok(SessionTrust {
        cwd: reply.field("cwd").as_str().unwrap_or_default().to_owned(),
        level: level_in(&reply, family, true),
        decided: level_in(&reply, family, false),
    })
}

/// The folder's level for a session of the agent `family`: acpmux's own
/// decision first; without one, that agent's own level (Claude Code's or
/// Codex's), or the stricter of both for any other agent. The pane reads the
/// same rule from `get` (`decided`, `harnesses`), so its question and the
/// trust gate (`server/trust_gate.rs`) agree.
pub fn session_level(paths: &Paths, cwd: &str, family: &str) -> Result<(String, Level), Failure> {
    session_trust(paths, cwd, family).map(|t| (t.cwd, t.level))
}

/// `session_level` for a Web client (or a peer forwarding for one): an auto-trust rule
/// (`trust_auto.rs`) is no answer here. A Web client cannot answer the question itself, so a
/// folder it starts in needs a decision a person made: in the app, the CLI, or an agent's own.
pub fn web_session_level(
    paths: &Paths,
    cwd: &str,
    family: &str,
) -> Result<(String, Level), Failure> {
    session_trust(paths, cwd, family).map(|t| (t.cwd, t.decided))
}

/// The level `get`'s `reply` gives an agent of `family`; `auto_answers`: whether an auto-trust
/// rule counts.
fn level_in(reply: &Value, family: &str, auto_answers: bool) -> Level {
    let level_at = |pointer: &str| {
        reply
            .pointer(pointer)
            .and_then(Value::as_str)
            .and_then(Level::parse)
            .unwrap_or(Level::Unknown)
    };
    let agent = |name: &str| level_at(&format!("/harnesses/{name}"));
    if !auto_answers && reply["auto"].is_string() {
        // Without the rule nothing decided: each agent's own level answers.
        return match family {
            "claude" | "codex" => agent(family),
            _ => agent("claude").stricter(agent("codex")),
        };
    }
    if reply["decided"].as_bool() == Some(true) {
        return level_at("/level");
    }
    match family {
        "claude" | "codex" => agent(family),
        _ => level_at("/level"),
    }
}

/// `acp.trust.set {cwd, level}`: records the decision; `unknown` forgets it.
pub fn set(paths: &Paths, cwd: &str, level: &str) -> Result<Value, Failure> {
    let cwd = normalize_cwd(cwd).map_err(Failure::Invalid)?;
    let level = Level::parse(level).ok_or_else(|| {
        Failure::Invalid(format!("level must be trusted, untrusted or unknown, got {level:?}"))
    })?;
    let _serialized = RECORD_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut record = read_record(&paths.record)?;
    match level {
        Level::Unknown => record.remove(&cwd),
        decided => record.insert(cwd.clone(), decided.as_str().to_owned()),
    };
    if let Some(parent) = paths.record.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| Failure::Record(format!("trust record: {e}")))?;
    }
    let bytes = serde_json::to_vec_pretty(&record).map_err(|e| Failure::Record(e.to_string()))?;
    crate::config::write_atomic(&paths.record, &bytes)
        .map_err(|e| Failure::Record(format!("trust record: {e}")))?;
    Ok(json!({"cwd": cwd, "level": level.as_str()}))
}

#[cfg(all(test, unix))]
mod security_tests {
    use super::*;

    #[test]
    fn acpmux_trust_record_never_follows_a_link() {
        let root = std::env::temp_dir().join(format!(
            "acpmux-trust-link-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        let cwd = root.join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        let target = root.join("planted.json");
        std::fs::write(&target, format!(r#"{{"{}":"trusted"}}"#, cwd.display())).unwrap();
        let record = root.join("trust.json");
        std::os::unix::fs::symlink(&target, &record).unwrap();
        let paths = Paths {
            claude_json: root.join("claude.json"),
            codex_config: root.join("config.toml"),
            record,
            agent_home: None,
            cmux_worktrees: None,
        };
        let error =
            get(&paths, &cwd.to_string_lossy()).expect_err("a linked trust decision loaded");
        assert!(matches!(error, Failure::Record(_)), "{error:?}");
        let _ = std::fs::remove_dir_all(&root);
    }
}

#[cfg(all(test, unix))]
mod scope_tests {
    use super::*;

    /// A scratch folder (canonical) with `home/` in it and the trust files under `state/`.
    fn scratch(tag: &str) -> (PathBuf, Paths) {
        let root = std::env::temp_dir().join(format!(
            "acpmux-trust-scope-{tag}-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        std::fs::create_dir_all(root.join("home")).unwrap();
        std::fs::create_dir_all(root.join("state")).unwrap();
        let root = std::fs::canonicalize(root).unwrap();
        let paths = Paths {
            claude_json: root.join("state/claude.json"),
            codex_config: root.join("state/config.toml"),
            record: root.join("state/trust.json"),
            agent_home: None,
            cmux_worktrees: None,
        };
        (root, paths)
    }

    /// A repository at `main` and a linked worktree of it at `tree`, laid out as git writes them.
    fn repo_with_worktree(main: &Path, tree: &Path) {
        std::fs::create_dir_all(main.join("src")).unwrap();
        let gitdir = main.join(".git/worktrees/w");
        std::fs::create_dir_all(&gitdir).unwrap();
        std::fs::create_dir_all(tree.join("src")).unwrap();
        std::fs::write(tree.join(".git"), format!("gitdir: {}\n", gitdir.display())).unwrap();
        std::fs::write(gitdir.join("gitdir"), format!("{}\n", tree.join(".git").display()))
            .unwrap();
        std::fs::write(gitdir.join("commondir"), "../..\n").unwrap();
    }

    fn read(paths: &Paths, cwd: &Path, home: &Path) -> Value {
        get_at(paths, &cwd.to_string_lossy(), Some(home)).unwrap()
    }

    #[test]
    fn a_worktree_of_a_trusted_repo_is_trusted_with_no_question() {
        let (root, paths) = scratch("worktree");
        let home = root.join("home");
        let main = home.join("Projects/app");
        let tree = home.join(".cmux/worktrees/app/fix-retry");
        repo_with_worktree(&main, &tree);
        // Unknown until the repository is trusted, and the reply names the repository to trust.
        let before = read(&paths, &tree.join("src"), &home);
        assert_eq!(before["level"], "unknown", "{before}");
        assert_eq!(before["repo"]["root"], main.to_string_lossy().as_ref(), "{before}");
        assert_eq!(before["repo"]["worktree"], true, "{before}");
        set(&paths, &main.to_string_lossy(), "trusted").unwrap();
        for folder in [tree.clone(), tree.join("src"), main.join("src")] {
            let reply = read(&paths, &folder, &home);
            assert_eq!(reply["level"], "trusted", "{folder:?}: {reply}");
            assert_eq!(reply["decided"], true, "{folder:?}: {reply}");
            assert_eq!(reply["via"], main.to_string_lossy().as_ref(), "{folder:?}: {reply}");
        }
        // The worktree's own answer wins over its repository's, and Undo there brings it back.
        set(&paths, &tree.to_string_lossy(), "untrusted").unwrap();
        assert_eq!(read(&paths, &tree.join("src"), &home)["level"], "untrusted");
        set(&paths, &tree.to_string_lossy(), "unknown").unwrap();
        assert_eq!(read(&paths, &tree.join("src"), &home)["level"], "trusted");
        // Forgetting the repository's answer asks again everywhere.
        set(&paths, &main.to_string_lossy(), "unknown").unwrap();
        assert_eq!(read(&paths, &tree, &home)["level"], "unknown");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A worktree cmux made (`~/.cmux/worktrees/<project>/<name>`) is trusted by construction,
    /// whatever its repository's answer is, unless a person or an agent said Don't trust. Only a
    /// linked worktree git wrote at that depth is one: a plain folder there is not.
    #[test]
    fn a_worktree_cmux_made_is_trusted_with_no_question() {
        let (root, mut paths) = scratch("cmux-worktree");
        let home = root.join("home");
        let worktrees = home.join(".cmux/worktrees");
        paths.cmux_worktrees = Some(worktrees.clone());
        let main = home.join("Projects/app");
        let tree = worktrees.join("app/directional-motion");
        repo_with_worktree(&main, &tree);
        for folder in [tree.clone(), tree.join("src")] {
            let reply = read(&paths, &folder, &home);
            assert_eq!(reply["level"], "trusted", "{folder:?}: {reply}");
            assert_eq!(reply["decided"], true, "{folder:?}: {reply}");
            assert_eq!(
                session_level(&paths, &folder.to_string_lossy(), "codex").unwrap().1,
                Level::Trusted
            );
            // A Web client still needs a person's answer: the worktree holds the repository's
            // content.
            assert_eq!(
                web_session_level(&paths, &folder.to_string_lossy(), "claude").unwrap().1,
                Level::Unknown
            );
        }
        // The repository itself is still asked about.
        assert_eq!(read(&paths, &main, &home)["level"], "unknown");
        // A plain folder under the root is no worktree cmux made.
        let plain = worktrees.join("app/plain");
        std::fs::create_dir_all(&plain).unwrap();
        assert_eq!(read(&paths, &plain, &home)["level"], "unknown");
        // A person's Don't trust, for the repository or the worktree, still wins.
        set(&paths, &main.to_string_lossy(), "untrusted").unwrap();
        assert_eq!(read(&paths, &tree, &home)["level"], "untrusted");
        set(&paths, &main.to_string_lossy(), "unknown").unwrap();
        set(&paths, &tree.to_string_lossy(), "untrusted").unwrap();
        assert_eq!(read(&paths, &tree.join("src"), &home)["level"], "untrusted");
        set(&paths, &tree.to_string_lossy(), "unknown").unwrap();
        // So does an agent's own untrusted level, for the repository or the worktree.
        std::fs::write(
            &paths.codex_config,
            format!("[projects.\"{}\"]\ntrust_level = \"untrusted\"\n", main.display()),
        )
        .unwrap();
        assert_eq!(read(&paths, &tree, &home)["level"], "unknown");
        std::fs::write(
            &paths.codex_config,
            format!("[projects.\"{}\"]\ntrust_level = \"untrusted\"\n", tree.display()),
        )
        .unwrap();
        assert_eq!(
            session_level(&paths, &tree.to_string_lossy(), "codex").unwrap().1,
            Level::Untrusted
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_git_file_that_its_repository_does_not_name_back_inherits_nothing() {
        let (root, paths) = scratch("forged");
        let home = root.join("home");
        let main = home.join("Projects/app");
        let tree = home.join("elsewhere/tree");
        repo_with_worktree(&main, &tree);
        // Somebody's own folder points its .git file at the trusted repository's worktree entry.
        let forged = home.join("downloads/forged");
        std::fs::create_dir_all(&forged).unwrap();
        std::fs::write(
            forged.join(".git"),
            format!("gitdir: {}\n", main.join(".git/worktrees/w").display()),
        )
        .unwrap();
        set(&paths, &main.to_string_lossy(), "trusted").unwrap();
        let reply = read(&paths, &forged, &home);
        assert_eq!(reply["level"], "unknown", "{reply}");
        assert!(reply["repo"].is_null(), "{reply}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_git_file_with_its_own_gitdir_naming_a_trusted_repository_inherits_nothing() {
        let (root, paths) = scratch("own-gitdir");
        let home = root.join("home");
        let main = home.join("Projects/app");
        std::fs::create_dir_all(main.join(".git")).unwrap();
        set(&paths, &main.to_string_lossy(), "trusted").unwrap();
        // An extracted archive: its .git file names a gitdir of its own that names the file back
        // and whose commondir is the trusted repository's .git.
        let forged = home.join("Downloads/forged");
        std::fs::create_dir_all(forged.join("meta")).unwrap();
        std::fs::write(forged.join(".git"), "gitdir: meta\n").unwrap();
        std::fs::write(forged.join("meta/gitdir"), format!("{}\n", forged.join(".git").display()))
            .unwrap();
        std::fs::write(forged.join("meta/commondir"), format!("{}\n", main.join(".git").display()))
            .unwrap();
        let reply = read(&paths, &forged, &home);
        assert_eq!(reply["level"], "unknown", "{reply}");
        assert!(reply["via"].is_null(), "{reply}");
        assert!(reply["repo"].is_null(), "{reply}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_worktree_git_wrote_with_relative_paths_inherits_too() {
        let (root, paths) = scratch("relative");
        let home = root.join("home");
        let main = home.join("Projects/app");
        let tree = home.join("Projects/app-fix");
        let gitdir = main.join(".git/worktrees/app-fix");
        std::fs::create_dir_all(&gitdir).unwrap();
        std::fs::create_dir_all(&tree).unwrap();
        // As `git -c worktree.useRelativePaths=true worktree add` writes them.
        std::fs::write(tree.join(".git"), "gitdir: ../app/.git/worktrees/app-fix\n").unwrap();
        std::fs::write(gitdir.join("gitdir"), "../../../../app-fix/.git\n").unwrap();
        std::fs::write(gitdir.join("commondir"), "../..\n").unwrap();
        set(&paths, &main.to_string_lossy(), "trusted").unwrap();
        let reply = read(&paths, &tree, &home);
        assert_eq!(reply["level"], "trusted", "{reply}");
        assert_eq!(reply["via"], main.to_string_lossy().as_ref(), "{reply}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_decision_for_a_plain_folder_covers_only_that_folder() {
        let (root, paths) = scratch("plain");
        let home = root.join("home");
        let project = home.join("Projects/notes");
        std::fs::create_dir_all(project.join("2026/october")).unwrap();
        set(&paths, &project.to_string_lossy(), "trusted").unwrap();
        assert_eq!(read(&paths, &project, &home)["level"], "trusted");
        let inside = read(&paths, &project.join("2026/october"), &home);
        assert_eq!(inside["level"], "unknown", "{inside}");
        assert!(inside["via"].is_null(), "{inside}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_repository_answer_holds_over_agents_levels_from_folders_above() {
        let (root, paths) = scratch("agent-above");
        let home = root.join("home");
        let main = home.join("Projects/app");
        let tree = home.join(".cmux/worktrees/app/fix-retry");
        repo_with_worktree(&main, &tree);
        // Claude Code trusts every folder under home; Not now on the repository still holds in
        // its worktrees, and no auto-trust rule answers over it.
        std::fs::write(
            &paths.claude_json,
            format!(
                r#"{{"projects": {{"{}": {{"hasTrustDialogAccepted": true}}}}}}"#,
                home.display()
            ),
        )
        .unwrap();
        set(&paths, &main.to_string_lossy(), "untrusted").unwrap();
        let reply = read(&paths, &tree, &home);
        assert_eq!(reply["level"], "untrusted", "{reply}");
        assert_eq!(reply["decided"], true, "{reply}");
        assert!(reply["auto"].is_null(), "{reply}");
        // Codex holds home untrusted; Trust repo answers the worktree for every agent.
        std::fs::write(&paths.claude_json, "").unwrap();
        std::fs::write(
            &paths.codex_config,
            format!("[projects.\"{}\"]\ntrust_level = \"untrusted\"\n", home.display()),
        )
        .unwrap();
        set(&paths, &main.to_string_lossy(), "trusted").unwrap();
        let reply = read(&paths, &tree, &home);
        assert_eq!(reply["level"], "trusted", "{reply}");
        assert_eq!(reply["decided"], true, "{reply}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn no_home_folder_no_repository_answer() {
        let (root, paths) = scratch("no-home");
        let main = root.join("home/Projects/app");
        let tree = root.join("home/.cmux/worktrees/app/fix-retry");
        repo_with_worktree(&main, &tree);
        set(&paths, &main.to_string_lossy(), "trusted").unwrap();
        let reply = get_at(&paths, &tree.to_string_lossy(), None).unwrap();
        assert_eq!(reply["level"], "unknown", "{reply}");
        assert!(reply["repo"].is_null(), "{reply}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_repository_at_home_is_never_offered_as_a_whole() {
        let (root, paths) = scratch("dotfiles");
        let home = root.join("home");
        std::fs::create_dir_all(home.join(".git")).unwrap();
        std::fs::create_dir_all(home.join("scratch")).unwrap();
        let reply = read(&paths, &home.join("scratch"), &home);
        assert!(reply["repo"].is_null(), "{reply}");
        let _ = std::fs::remove_dir_all(&root);
    }
}
