//! Folders that need no trust question: the person's own.
//!
//! A folder is trusted without a prompt when it sits under one of the person's project roots
//! (settings `agents.trust.projectRoots`), or when its git repository's remotes all belong to the
//! person's own GitHub organizations (`agents.trust.ownOrgs`). The rules only ever widen what is
//! unknown: an explicit "Don't trust" and an agent's own untrusted level still win
//! (`trust::get`), and `agents.trust.autoTrust` turns both rules off.
//!
//! The settings file is read at each use, like the other daemon-read settings
//! (`user_settings.rs`). A file that cannot be read turns the rules off: a default that widens
//! trust must not apply to a file nobody could read. The defaults live in
//! `schemas/settings/source/trust.json`, the one definition the app's Settings shares.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::user_settings::{self, Settings};

pub const SETTING_AUTO: &str = "agents.trust.autoTrust";
pub const SETTING_ROOTS: &str = "agents.trust.projectRoots";
pub const SETTING_ORGS: &str = "agents.trust.ownOrgs";

/// The rows the daemon reads, from the shared settings source.
const CATALOG_SOURCE: &str = include_str!("../../../../schemas/settings/source/trust.json");

/// Why a folder needs no question.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reason {
    /// Inside this project root.
    Root(PathBuf),
    /// Every remote of its repository belongs to this organization or user (the first of them).
    Org(String),
}

impl Reason {
    /// The short form `acp.trust.get` reports (`auto`).
    pub fn label(&self) -> &'static str {
        match self {
            Self::Root(_) => "root",
            Self::Org(_) => "org",
        }
    }
}

/// The person's auto-trust rules.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AutoTrust {
    pub enabled: bool,
    /// Absolute project roots, `~/` already expanded.
    pub roots: Vec<PathBuf>,
    /// Lowercase GitHub owners.
    pub orgs: Vec<String>,
}

impl AutoTrust {
    /// The rules in force now: the settings file over the catalog defaults.
    pub fn current() -> Self {
        let home = dirs::home_dir();
        match user_settings::read() {
            Settings::Missing => Self::from_doc(&Value::Null, home.as_deref()),
            Settings::Parsed(doc) => Self::from_doc(&doc, home.as_deref()),
            Settings::Unreadable(_) => Self::default(),
        }
    }

    /// The rules a settings document names; a key it lacks takes the catalog default.
    pub fn from_doc(doc: &Value, home: Option<&Path>) -> Self {
        let defaults = defaults();
        let read = |key: &str| user_settings::value(doc, key);
        let enabled = read(SETTING_AUTO).and_then(|v| v.as_bool()).unwrap_or(defaults.enabled);
        let strings = |key: &str, fallback: &[String]| -> Vec<String> {
            match read(key) {
                Some(Value::Array(items)) => {
                    items.iter().filter_map(Value::as_str).map(str::to_owned).collect()
                }
                _ => fallback.to_vec(),
            }
        };
        // The home folder (and anything above it) as a root would trust everything in it, the
        // privacy-guarded folders and dotfiles included: it is no project root.
        let canonical_home = home.and_then(|home| std::fs::canonicalize(home).ok());
        let roots = strings(SETTING_ROOTS, &defaults.roots)
            .iter()
            .filter_map(|root| expand(root, home))
            .filter(|root| {
                let root = std::fs::canonicalize(root).unwrap_or_else(|_| root.clone());
                !canonical_home.as_deref().is_some_and(|home| home.starts_with(&root))
            })
            .collect();
        let orgs = strings(SETTING_ORGS, &defaults.orgs)
            .iter()
            .map(|org| org.trim().to_ascii_lowercase())
            .filter(|org| !org.is_empty())
            .collect();
        Self { enabled, roots, orgs }
    }

    /// Why `cwd` (absolute) needs no question, or None.
    pub fn reason(&self, cwd: &str) -> Option<Reason> {
        if !self.enabled {
            return None;
        }
        // Resolved, so a symlink out of a root, `..` and /tmp vs /private/tmp cannot reach in.
        let cwd = std::fs::canonicalize(cwd).ok()?;
        for root in &self.roots {
            // A root that is "/" or the home folder itself would trust everything: skipped.
            let Ok(root) = std::fs::canonicalize(root) else { continue };
            if root.parent().is_some() && cwd.starts_with(&root) {
                return Some(Reason::Root(root));
            }
        }
        let owners = remote_owners(&cwd)?;
        let first = owners.first()?;
        owners.iter().all(|owner| self.orgs.contains(owner)).then(|| Reason::Org(first.clone()))
    }
}

/// `~/x` against `home`; an absolute path as it is; anything else is not a root.
fn expand(root: &str, home: Option<&Path>) -> Option<PathBuf> {
    let root = root.trim();
    if let Some(rest) = root.strip_prefix("~/") {
        return home.map(|home| home.join(rest));
    }
    (root.starts_with('/') && root.len() > 1).then(|| PathBuf::from(root))
}

struct Defaults {
    enabled: bool,
    roots: Vec<String>,
    orgs: Vec<String>,
}

fn defaults() -> &'static Defaults {
    static DEFAULTS: std::sync::OnceLock<Defaults> = std::sync::OnceLock::new();
    DEFAULTS.get_or_init(|| parse_defaults(CATALOG_SOURCE).unwrap_or(Defaults {
        enabled: true,
        roots: vec!["~/Projects".to_owned()],
        orgs: vec!["teamleaderleo".to_owned(), "manaflow-ai".to_owned()],
    }))
}

fn parse_defaults(source: &str) -> Option<Defaults> {
    let doc: Value = serde_json::from_str(source).ok()?;
    let row = |key: &str| -> Option<Value> {
        doc["lists"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|list| list["rows"].as_array().into_iter().flatten())
            .find(|row| row["key"] == key)
            .map(|row| row["default"].clone())
    };
    let list = |key: &str| -> Option<Vec<String>> {
        Some(row(key)?.as_array()?.iter().filter_map(Value::as_str).map(str::to_owned).collect())
    };
    Some(Defaults {
        enabled: row(SETTING_AUTO)?.as_bool()?,
        roots: list(SETTING_ROOTS)?,
        orgs: list(SETTING_ORGS)?,
    })
}

/// The lowercase GitHub owners of every remote of the repository that holds `cwd`: None when
/// there is no repository, no remote, or a remote that is not on github.com.
fn remote_owners(cwd: &Path) -> Option<Vec<String>> {
    let config = std::fs::read_to_string(git_config_path(cwd)?).ok()?;
    let mut owners = Vec::new();
    let mut in_remote = false;
    for line in config.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_remote = line.starts_with("[remote ");
        } else if in_remote
            && let Some((key, value)) = line.split_once('=')
            && key.trim().eq_ignore_ascii_case("url")
        {
            owners.push(github_owner(value.trim())?);
        }
    }
    (!owners.is_empty()).then_some(owners)
}

/// The `config` file of the repository holding `cwd`: its `.git` folder's, or for a linked
/// worktree (`.git` is a file naming a gitdir with a `commondir`) the main repository's.
fn git_config_path(cwd: &Path) -> Option<PathBuf> {
    for folder in cwd.ancestors() {
        let dot_git = folder.join(".git");
        let Ok(meta) = std::fs::symlink_metadata(&dot_git) else { continue };
        if meta.is_dir() {
            return Some(dot_git.join("config"));
        }
        if meta.is_file() {
            let text = std::fs::read_to_string(&dot_git).ok()?;
            let gitdir = text.trim().strip_prefix("gitdir:")?.trim();
            let gitdir = folder.join(gitdir);
            let common = std::fs::read_to_string(gitdir.join("commondir")).ok();
            let common = common.map_or(gitdir.clone(), |rel| gitdir.join(rel.trim()));
            return Some(common.join("config"));
        }
    }
    None
}

/// The owner of a github.com remote URL (`git@github.com:o/r.git`, `https://github.com/o/r`,
/// `ssh://git@github.com/o/r`), lowercase; None for any other host or shape.
fn github_owner(url: &str) -> Option<String> {
    let rest = if let Some(rest) = url.strip_prefix("git@github.com:") {
        rest
    } else {
        let rest = url.split_once("://")?.1;
        let (host, path) = rest.split_once('/')?;
        let host = host.rsplit('@').next()?;
        if !host.eq_ignore_ascii_case("github.com") {
            return None;
        }
        path
    };
    let owner = rest.split('/').next()?.trim();
    let valid = !owner.is_empty()
        && owner.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.');
    valid.then(|| owner.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn repo(dir: &Path, remotes: &[(&str, &str)]) {
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let mut text = String::from("[core]\n\trepositoryformatversion = 0\n");
        for (name, url) in remotes {
            text.push_str(&format!("[remote \"{name}\"]\n\turl = {url}\n"));
        }
        std::fs::write(dir.join(".git/config"), text).unwrap();
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("tauto-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::canonicalize(&d).unwrap()
    }

    fn rules(doc: Value) -> AutoTrust {
        AutoTrust::from_doc(&doc, Some(Path::new("/nonexistent-home")))
    }

    #[test]
    fn github_urls_name_their_owner() {
        for url in [
            "git@github.com:ManaFlow-AI/cmux.git",
            "https://github.com/manaflow-ai/cmux",
            "https://user@github.com/manaflow-ai/cmux.git",
            "ssh://git@github.com/manaflow-ai/cmux.git",
        ] {
            assert_eq!(github_owner(url).as_deref(), Some("manaflow-ai"), "{url}");
        }
        for url in ["git@gitlab.com:manaflow-ai/cmux.git", "/srv/git/cmux", "https://github.com.evil.example/manaflow-ai/x"] {
            assert_eq!(github_owner(url), None, "{url}");
        }
    }

    #[test]
    fn the_catalog_defaults_name_both_orgs_and_a_projects_root() {
        let auto = rules(Value::Null);
        assert!(auto.enabled);
        assert_eq!(auto.orgs, ["teamleaderleo", "manaflow-ai"]);
        assert_eq!(auto.roots, [PathBuf::from("/nonexistent-home/Projects")]);
    }

    #[test]
    fn a_folder_under_a_root_is_trusted_and_a_symlink_out_is_not() {
        let d = scratch("root");
        let root = d.join("projects");
        std::fs::create_dir_all(root.join("app/src")).unwrap();
        std::fs::create_dir_all(d.join("elsewhere")).unwrap();
        std::os::unix::fs::symlink(d.join("elsewhere"), root.join("link")).unwrap();
        let auto = rules(json!({"agents": {"trust": {"projectRoots": [root.to_string_lossy()]}}}));
        assert_eq!(
            auto.reason(root.join("app/src").to_str().unwrap()),
            Some(Reason::Root(root.clone()))
        );
        assert_eq!(auto.reason(root.join("link").to_str().unwrap()), None);
        assert_eq!(auto.reason(d.join("elsewhere").to_str().unwrap()), None);
    }

    #[test]
    fn a_repo_is_trusted_only_when_every_remote_is_an_own_org() {
        let d = scratch("org");
        let own = d.join("own");
        let mixed = d.join("mixed");
        let none = d.join("none");
        repo(&own, &[("origin", "git@github.com:teamleaderleo/x.git")]);
        repo(&mixed, &[("origin", "git@github.com:manaflow-ai/x.git"), ("up", "https://github.com/someone/x")]);
        repo(&none, &[]);
        let auto = rules(json!({"agents": {"trust": {"projectRoots": []}}}));
        assert_eq!(auto.reason(own.to_str().unwrap()), Some(Reason::Org("teamleaderleo".into())));
        assert_eq!(auto.reason(mixed.to_str().unwrap()), None);
        assert_eq!(auto.reason(none.to_str().unwrap()), None);
    }

    #[test]
    fn a_linked_worktree_reads_the_main_repositorys_remotes() {
        let d = scratch("wt");
        let main = d.join("main");
        repo(&main, &[("origin", "git@github.com:manaflow-ai/x.git")]);
        let gitdir = main.join(".git/worktrees/w");
        std::fs::create_dir_all(&gitdir).unwrap();
        std::fs::write(gitdir.join("commondir"), "../..\n").unwrap();
        let tree = d.join("w");
        std::fs::create_dir_all(&tree).unwrap();
        std::fs::write(tree.join(".git"), format!("gitdir: {}\n", gitdir.display())).unwrap();
        let auto = rules(json!({"agents": {"trust": {"projectRoots": []}}}));
        assert_eq!(auto.reason(tree.to_str().unwrap()), Some(Reason::Org("manaflow-ai".into())));
    }

    #[test]
    fn the_switch_turns_both_rules_off_and_a_broken_file_never_widens() {
        let d = scratch("off");
        repo(&d.join("r"), &[("origin", "git@github.com:manaflow-ai/x.git")]);
        let off = rules(json!({"agents": {"trust": {"autoTrust": false}}}));
        assert_eq!(off.reason(d.join("r").to_str().unwrap()), None);
        assert_eq!(AutoTrust::default().reason(d.join("r").to_str().unwrap()), None);
    }

    #[test]
    fn the_home_folder_is_no_project_root() {
        let d = scratch("home");
        std::fs::create_dir_all(d.join("work")).unwrap();
        let doc = json!({"agents": {"trust": {"projectRoots": [d.to_string_lossy(), "~/work"]}}});
        let auto = AutoTrust::from_doc(&doc, Some(&d));
        assert_eq!(auto.roots, [d.join("work")]);
        assert_eq!(auto.reason(d.join("work").to_str().unwrap()), Some(Reason::Root(d.join("work"))));
        assert_eq!(auto.reason(d.to_str().unwrap()), None);
    }

    #[test]
    fn a_root_that_is_the_filesystem_root_trusts_nothing_extra() {
        let d = scratch("slash");
        let auto = rules(json!({"agents": {"trust": {"projectRoots": ["/"]}}}));
        assert_eq!(auto.reason(d.to_str().unwrap()), None);
    }
}
