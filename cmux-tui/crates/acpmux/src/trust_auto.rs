//! Folders that need no trust question: the person's own.
//!
//! A folder is trusted without a prompt when it sits under one of the person's project roots
//! (settings `agents.trust.projectRoots`), or when its git repository's remotes all belong to the
//! person's own GitHub organizations (`agents.trust.ownOrgs`). The rules only ever widen what is
//! unknown: an explicit "Don't trust" and an agent's own untrusted level still win
//! (`trust::get`), and `agents.trust.autoTrust` turns both rules off.
//!
//! The settings file is read at each use, like the other daemon-read settings
//! (`user_settings.rs`). A file that cannot be read turns the rules off. The defaults live in
//! `schemas/settings/source/trust.json`, the one definition the app's Settings shares: off, with
//! no roots and no owners, so nothing is trusted by a rule until the person names their own.

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
    /// The canonical home folder: the organization rule trusts only folders inside it, so a
    /// repository an agent made elsewhere (`git init` in /tmp with a forged remote) is not one.
    pub home: Option<PathBuf>,
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
        // A key of the wrong type turns its rule off: a default must not fill in for a value
        // somebody wrote and got wrong.
        let enabled = match read(SETTING_AUTO) {
            None => defaults.enabled,
            Some(value) => value.as_bool().unwrap_or(false),
        };
        let strings = |key: &str, fallback: &[String]| -> Vec<String> {
            match read(key) {
                None => fallback.to_vec(),
                Some(Value::Array(items)) => {
                    items.iter().filter_map(Value::as_str).map(str::to_owned).collect()
                }
                Some(_) => Vec::new(),
            }
        };
        // A home at `/` (HOME=/) holds every folder: no folder is inside it for the org rule.
        let canonical_home = home
            .and_then(|home| std::fs::canonicalize(home).ok())
            .filter(|home| home.parent().is_some());
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
        Self { enabled, roots, orgs, home: canonical_home }
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
        // The organization rule: only inside the home folder, and only on evidence git wrote.
        if !self.home.as_deref().is_some_and(|home| cwd.starts_with(home)) {
            return None;
        }
        let owners = remote_owners(&cwd, self.home.as_deref()?)?;
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
    DEFAULTS.get_or_init(|| {
        parse_defaults(CATALOG_SOURCE).unwrap_or(Defaults {
            enabled: false,
            roots: Vec::new(),
            orgs: Vec::new(),
        })
    })
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
fn remote_owners(cwd: &Path, home: &Path) -> Option<Vec<String>> {
    let config = std::fs::read_to_string(git_config_path(cwd, home)?).ok()?;
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
/// Only a repository strictly inside `home` counts: a dotfiles repository at the home folder
/// (or above it) holds most of home, and must not make every folder in it the person's own.
fn git_config_path(cwd: &Path, home: &Path) -> Option<PathBuf> {
    let below_home = |folder: &&Path| *folder != home && folder.starts_with(home);
    for folder in cwd.ancestors().take_while(below_home) {
        let dot_git = folder.join(".git");
        let Ok(meta) = std::fs::symlink_metadata(&dot_git) else { continue };
        if meta.is_dir() {
            return Some(dot_git.join("config"));
        }
        if meta.is_file() {
            let text = std::fs::read_to_string(&dot_git).ok()?;
            let gitdir = folder.join(text.trim().strip_prefix("gitdir:")?.trim());
            // The repository must name this folder back (git writes `<gitdir>/gitdir`): a `.git`
            // file written by hand to point at somebody's repository proves nothing.
            let back = std::fs::read_to_string(gitdir.join("gitdir")).ok()?;
            if std::fs::canonicalize(back.trim()).ok()? != std::fs::canonicalize(&dot_git).ok()? {
                return None;
            }
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

    /// Rules for a person whose home folder is `home`.
    fn rules_at(home: &Path, doc: Value) -> AutoTrust {
        AutoTrust::from_doc(&doc, Some(home))
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
        for url in [
            "git@gitlab.com:manaflow-ai/cmux.git",
            "/srv/git/cmux",
            "https://github.com.evil.example/manaflow-ai/x",
        ] {
            assert_eq!(github_owner(url), None, "{url}");
        }
    }

    /// The person's rules: on, no roots, these owners.
    fn owners(orgs: &[&str]) -> Value {
        json!({"agents": {"trust": {"autoTrust": true, "projectRoots": [], "ownOrgs": orgs}}})
    }

    #[test]
    fn by_default_nothing_is_trusted_by_a_rule() {
        let auto = rules(Value::Null);
        assert!(!auto.enabled);
        assert!(auto.orgs.is_empty());
        assert!(auto.roots.is_empty());
        // Turned on without naming anything, still nothing.
        let d = scratch("defaults");
        repo(&d.join("r"), &[("origin", "git@github.com:manaflow-ai/x.git")]);
        let on = rules_at(&d, json!({"agents": {"trust": {"autoTrust": true}}}));
        assert_eq!(on.reason(d.join("r").to_str().unwrap()), None);
    }

    #[test]
    fn a_home_at_the_root_trusts_nothing_by_organization() {
        let d = scratch("roothome");
        repo(&d.join("r"), &[("origin", "git@github.com:manaflow-ai/x.git")]);
        let auto = rules_at(Path::new("/"), owners(&["manaflow-ai"]));
        assert_eq!(auto.home, None);
        assert_eq!(auto.reason(d.join("r").to_str().unwrap()), None);
    }

    #[test]
    fn a_dotfiles_repository_at_home_trusts_nothing_in_home() {
        let d = scratch("dotfiles");
        repo(&d, &[("origin", "git@github.com:teamleaderleo/dotfiles.git")]);
        std::fs::create_dir_all(d.join("Downloads/tarball")).unwrap();
        let auto = rules_at(&d, owners(&["teamleaderleo"]));
        assert_eq!(auto.reason(d.join("Downloads/tarball").to_str().unwrap()), None);
        assert_eq!(auto.reason(d.to_str().unwrap()), None);
        // A repository of its own inside home still counts.
        repo(&d.join("code/app"), &[("origin", "git@github.com:teamleaderleo/app.git")]);
        assert_eq!(
            auto.reason(d.join("code/app").to_str().unwrap()),
            Some(Reason::Org("teamleaderleo".into()))
        );
    }

    #[test]
    fn a_folder_under_a_root_is_trusted_but_outside_is_not() {
        let d = scratch("root");
        let root = d.join("projects");
        std::fs::create_dir_all(root.join("app/src")).unwrap();
        std::fs::create_dir_all(d.join("elsewhere")).unwrap();
        let auto = rules(
            json!({"agents": {"trust": {"autoTrust": true, "projectRoots": [root.to_string_lossy()]}}}),
        );
        assert_eq!(
            auto.reason(root.join("app/src").to_str().unwrap()),
            Some(Reason::Root(root.clone()))
        );
        assert_eq!(auto.reason(d.join("elsewhere").to_str().unwrap()), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_from_a_trusted_root_to_outside_is_not_trusted() {
        let d = scratch("symlink-root");
        let root = d.join("projects");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::create_dir_all(d.join("elsewhere")).unwrap();
        std::os::unix::fs::symlink(d.join("elsewhere"), root.join("link")).unwrap();
        let auto = rules(
            json!({"agents": {"trust": {"autoTrust": true, "projectRoots": [root.to_string_lossy()]}}}),
        );
        assert_eq!(auto.reason(root.join("link").to_str().unwrap()), None);
    }

    #[test]
    fn a_repo_is_trusted_only_when_every_remote_is_an_own_org() {
        let d = scratch("org");
        let own = d.join("own");
        let mixed = d.join("mixed");
        let none = d.join("none");
        repo(&own, &[("origin", "git@github.com:teamleaderleo/x.git")]);
        repo(
            &mixed,
            &[
                ("origin", "git@github.com:manaflow-ai/x.git"),
                ("up", "https://github.com/someone/x"),
            ],
        );
        repo(&none, &[]);
        let auto = rules_at(&d, owners(&["teamleaderleo", "manaflow-ai"]));
        assert_eq!(auto.reason(own.to_str().unwrap()), Some(Reason::Org("teamleaderleo".into())));
        assert_eq!(auto.reason(mixed.to_str().unwrap()), None);
        assert_eq!(auto.reason(none.to_str().unwrap()), None);
        // A repository outside the home folder (an agent's `git init` in /tmp) is not trusted.
        let elsewhere = scratch("org-elsewhere");
        repo(&elsewhere.join("forged"), &[("origin", "git@github.com:manaflow-ai/x.git")]);
        assert_eq!(auto.reason(elsewhere.join("forged").to_str().unwrap()), None);
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
        let auto = rules_at(&d, owners(&["manaflow-ai"]));
        // The repository does not name this folder back: a `.git` file written by hand.
        assert_eq!(auto.reason(tree.to_str().unwrap()), None);
        std::fs::write(gitdir.join("gitdir"), format!("{}\n", tree.join(".git").display()))
            .unwrap();
        assert_eq!(auto.reason(tree.to_str().unwrap()), Some(Reason::Org("manaflow-ai".into())));
    }

    #[test]
    fn the_switch_turns_both_rules_off_and_a_broken_file_never_widens() {
        let d = scratch("off");
        repo(&d.join("r"), &[("origin", "git@github.com:manaflow-ai/x.git")]);
        let off = rules_at(
            &d,
            json!({"agents": {"trust": {"autoTrust": false, "ownOrgs": ["manaflow-ai"]}}}),
        );
        assert_eq!(off.reason(d.join("r").to_str().unwrap()), None);
        // A value of the wrong type turns the rules off rather than falling back to the default.
        let typo = rules_at(
            &d,
            json!({"agents": {"trust": {"autoTrust": "false", "ownOrgs": ["manaflow-ai"]}}}),
        );
        assert_eq!(typo.reason(d.join("r").to_str().unwrap()), None);
        let on = rules_at(&d, owners(&["manaflow-ai"]));
        assert_eq!(
            on.reason(d.join("r").to_str().unwrap()),
            Some(Reason::Org("manaflow-ai".into()))
        );
        let bad_orgs = rules_at(
            &d,
            json!({"agents": {"trust": {"autoTrust": true, "ownOrgs": "manaflow-ai"}}}),
        );
        assert_eq!(bad_orgs.reason(d.join("r").to_str().unwrap()), None);
        assert_eq!(AutoTrust::default().reason(d.join("r").to_str().unwrap()), None);
    }

    #[test]
    fn the_home_folder_is_no_project_root() {
        let d = scratch("home");
        std::fs::create_dir_all(d.join("work")).unwrap();
        let doc = json!({"agents": {"trust": {
            "autoTrust": true, "projectRoots": [d.to_string_lossy(), "~/work"]
        }}});
        let auto = AutoTrust::from_doc(&doc, Some(&d));
        assert_eq!(auto.roots, [d.join("work")]);
        assert_eq!(
            auto.reason(d.join("work").to_str().unwrap()),
            Some(Reason::Root(d.join("work")))
        );
        assert_eq!(auto.reason(d.to_str().unwrap()), None);
    }

    #[test]
    fn a_root_that_is_the_filesystem_root_trusts_nothing_extra() {
        let d = scratch("slash");
        let auto = rules(json!({"agents": {"trust": {"autoTrust": true, "projectRoots": ["/"]}}}));
        assert_eq!(auto.reason(d.to_str().unwrap()), None);
    }
}
