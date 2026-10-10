//! The project list (plans/cmux-next/projects.md, cx-m0p7): one durable list of
//! the folders the user works in, owned by the store. Sources (agent harnesses
//! through acpmux's chat index, editors' recent lists, the user, cmux
//! workspaces) report paths; the user's edits (rename, pin, hide, order) are an
//! overlay no resync ever touches.
//!
//! This module is the pure reducer: no IO. The store never resolves or stats
//! an observed path (a read inside a privacy-protected folder raises a macOS
//! prompt attributed to cmux): paths are normalized lexically here, `project.add`
//! resolves the folder the user picked, and the app reports disk facts
//! (`apply_disk`) with its own privacy rules.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The source of a path the user added by hand (a picker, Choose Folder).
pub(crate) const USER_SOURCE: &str = "user";
/// The longest path accepted (PATH_MAX on macOS and Linux).
const MAX_PATH_BYTES: usize = 4096;
/// The longest source id and display name accepted.
const MAX_NAME_BYTES: usize = 256;
/// The most projects kept. Past it, the least recently used imports with no
/// user edit and no `user` source go first (a chat index can name one folder
/// per worktree or agent run).
pub(crate) const MAX_PROJECTS: usize = 1000;
/// macOS's data volume firmlink: `/System/Volumes/Data/Users/me` is `/Users/me`.
const DATA_VOLUME: &str = "/System/Volumes/Data";

/// When one source first reported a project, and when it was last used there.
/// (No "last seen" time: it would change on every resync and rewrite every row.)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct SourceSeen {
    pub first_seen_ms: i64,
    pub last_used_ms: i64,
}

/// The user's edits. A resync never changes them.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Overlay {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rename: Option<String>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub hidden: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<i32>,
}

impl Overlay {
    // Used by `disable_source`, which the per-source settings call (projects.md slice 3).
    #[allow(dead_code)]
    fn is_empty(&self) -> bool {
        self == &Overlay::default()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ProjectState {
    Present,
    /// Gone from every source and from disk: shown dimmed, removable, never
    /// deleted automatically.
    Missing,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Project {
    pub path: String,
    pub sources: BTreeMap<String, SourceSeen>,
    #[serde(default)]
    pub overlay: Overlay,
    pub state: ProjectState,
}

impl Project {
    /// The display name: the user's rename, else the folder's last component.
    pub(crate) fn name(&self) -> &str {
        self.overlay.rename.as_deref().unwrap_or_else(|| {
            self.path.rsplit('/').find(|part| !part.is_empty()).unwrap_or(&self.path)
        })
    }

    pub(crate) fn last_used_ms(&self) -> i64 {
        self.sources.values().map(|seen| seen.last_used_ms).max().unwrap_or(0)
    }
}

/// One path a source reports, with when it was last used there.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Observation {
    pub path: String,
    pub last_used_ms: i64,
}

/// A user edit (`project.update`); an absent field is left as it is, JSON
/// null clears a rename or an order (`Some(None)`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct OverlayEdit {
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub rename: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden: Option<bool>,
    #[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
    pub order: Option<Option<i32>>,
}

/// A field that is present (`Some`), null included (`Some(None)`); serde's
/// `default` gives `None` only when the field is absent.
fn present<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

/// Why the store refuses a request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ProjectReject {
    InvalidPath(String),
    RefusedPath(String),
    UnknownProject(String),
    InvalidName(String),
}

impl ProjectReject {
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::InvalidPath(_) => "invalid_path",
            Self::RefusedPath(_) => "refused_path",
            Self::UnknownProject(_) => "unknown_project",
            Self::InvalidName(_) => "invalid_argument",
        }
    }
}

/// Paths that are never projects: the user's home, `/`, temp dirs, agent
/// homes. `home` is the user's home folder in canonical form.
#[derive(Clone, Debug)]
pub(crate) struct Refusals {
    pub home: String,
    /// Folders whose contents are never projects (agent config homes, cmux's
    /// agent-home), in canonical form.
    pub roots: Vec<String>,
}

impl Refusals {
    /// `path` in its stored form (absolute, no trailing slash, no `.` or `..`,
    /// the data volume firmlink removed), or why it is not a project. Lexical:
    /// nothing is read from disk.
    pub(crate) fn normalize(&self, path: &str) -> Result<String, ProjectReject> {
        if path.is_empty() || path.len() > MAX_PATH_BYTES || path.contains('\0') {
            return Err(ProjectReject::InvalidPath(
                "path must be 1 to 4096 bytes without NUL".into(),
            ));
        }
        if !path.starts_with('/') || (path.len() > 1 && path.ends_with('/')) {
            return Err(ProjectReject::InvalidPath(
                "path must be absolute without a trailing slash".into(),
            ));
        }
        if path.split('/').any(|part| part == "." || part == "..") {
            return Err(ProjectReject::InvalidPath("path must be canonical (no . or ..)".into()));
        }
        let path = match path.strip_prefix(DATA_VOLUME) {
            Some(rest) if rest.is_empty() || rest.starts_with('/') => {
                if rest.is_empty() {
                    "/"
                } else {
                    rest
                }
            }
            _ => path,
        };
        // The Mac's disk ignores case: compare folded.
        let folded = path.to_lowercase();
        let home = self.home.trim_end_matches('/').to_lowercase();
        let refused = folded == "/"
            || folded == home
            || (!home.is_empty()
                && home.starts_with(&folded)
                && home.as_bytes().get(folded.len()) == Some(&b'/'))
            || ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
                .iter()
                .any(|root| is_within(&folded, root))
            || self.roots.iter().any(|root| is_within(&folded, &root.to_lowercase()));
        if refused {
            return Err(ProjectReject::RefusedPath(format!("{path} is never a project")));
        }
        Ok(path.to_string())
    }
}

/// `path` is `root` or inside it.
fn is_within(path: &str, root: &str) -> bool {
    let root = root.trim_end_matches('/');
    !root.is_empty()
        && (path == root
            || (path.starts_with(root) && path.as_bytes().get(root.len()) == Some(&b'/')))
}

fn check_source(source: &str) -> Result<(), ProjectReject> {
    let valid = !source.is_empty()
        && source.len() <= MAX_NAME_BYTES
        && source
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'));
    if valid {
        Ok(())
    } else {
        Err(ProjectReject::InvalidName(format!("bad source id {source:?}")))
    }
}

/// The project list. Keyed by canonical path.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Projects {
    by_path: BTreeMap<String, Project>,
}

impl Projects {
    pub(crate) fn from_projects(projects: impl IntoIterator<Item = Project>) -> Self {
        Self {
            by_path: projects.into_iter().map(|project| (project.path.clone(), project)).collect(),
        }
    }

    pub(crate) fn get(&self, path: &str) -> Option<&Project> {
        self.by_path.get(path)
    }

    /// Every project, the way readers show them: pinned first (by `order`,
    /// then name), then the most recently used. Hidden ones only when asked.
    pub(crate) fn list(&self, include_hidden: bool) -> Vec<&Project> {
        let mut projects: Vec<&Project> = self
            .by_path
            .values()
            .filter(|project| include_hidden || !project.overlay.hidden)
            .collect();
        projects.sort_by(|a, b| {
            b.overlay
                .pinned
                .cmp(&a.overlay.pinned)
                .then_with(|| match (a.overlay.pinned, a.overlay.order, b.overlay.order) {
                    (true, Some(x), Some(y)) => x.cmp(&y),
                    (true, Some(_), None) => std::cmp::Ordering::Less,
                    (true, None, Some(_)) => std::cmp::Ordering::Greater,
                    _ => std::cmp::Ordering::Equal,
                })
                .then_with(|| b.last_used_ms().cmp(&a.last_used_ms()))
                .then_with(|| a.path.cmp(&b.path))
        });
        projects
    }

    /// `source` reports `entries` (rules 1, 2, 3, 5). With `complete`, the
    /// entries are everything the source knows: a path it no longer lists
    /// loses that source (the project itself stays, see `reconcile`).
    /// Refused paths are skipped, never an error: a source is not the user.
    /// Returns the paths that changed.
    pub(crate) fn observe(
        &mut self,
        source: &str,
        entries: &[Observation],
        complete: bool,
        now_ms: i64,
        refusals: &Refusals,
    ) -> Result<Vec<String>, ProjectReject> {
        check_source(source)?;
        if source == USER_SOURCE {
            return Err(ProjectReject::InvalidName(
                "the user source is added with project.add".into(),
            ));
        }
        let mut changed = Vec::new();
        let mut reported = std::collections::BTreeSet::new();
        for entry in entries {
            let Ok(path) = refusals.normalize(&entry.path) else { continue };
            reported.insert(path.clone());
            let project = self.by_path.entry(path.clone()).or_insert_with(|| Project {
                path: path.clone(),
                sources: BTreeMap::new(),
                overlay: Overlay::default(),
                state: ProjectState::Present,
            });
            let before = project.clone();
            let seen = project
                .sources
                .entry(source.to_string())
                .or_insert(SourceSeen { first_seen_ms: now_ms, last_used_ms: entry.last_used_ms });
            seen.last_used_ms = seen.last_used_ms.max(entry.last_used_ms);
            // A source reporting it again: it exists again.
            project.state = ProjectState::Present;
            if *project != before {
                changed.push(path);
            }
        }
        if complete {
            for project in self.by_path.values_mut() {
                if !reported.contains(&project.path) && project.sources.remove(source).is_some() {
                    changed.push(project.path.clone());
                }
            }
        }
        changed.extend(self.evict_past_cap());
        changed.sort();
        changed.dedup();
        Ok(changed)
    }

    /// Drops the least recently used imports with no user edit and no `user`
    /// source until at most `MAX_PROJECTS` remain. Returns the paths dropped.
    fn evict_past_cap(&mut self) -> Vec<String> {
        let excess = self.by_path.len().saturating_sub(MAX_PROJECTS);
        if excess == 0 {
            return Vec::new();
        }
        let mut candidates: Vec<(i64, String)> = self
            .by_path
            .values()
            .filter(|project| {
                project.overlay.is_empty() && !project.sources.contains_key(USER_SOURCE)
            })
            .map(|project| (project.last_used_ms(), project.path.clone()))
            .collect();
        candidates.sort();
        let dropped: Vec<String> =
            candidates.into_iter().take(excess).map(|(_, path)| path).collect();
        for path in &dropped {
            self.by_path.remove(path);
        }
        dropped
    }

    /// The user adds a folder (source `user`, rule 5). Unhides it. Returns the
    /// paths that changed (the project, and any import the cap dropped).
    pub(crate) fn add(
        &mut self,
        path: &str,
        now_ms: i64,
        refusals: &Refusals,
    ) -> Result<Vec<String>, ProjectReject> {
        let path = refusals.normalize(path)?;
        let project = self.by_path.entry(path.clone()).or_insert_with(|| Project {
            path: path.clone(),
            sources: BTreeMap::new(),
            overlay: Overlay::default(),
            state: ProjectState::Present,
        });
        let before = project.clone();
        let seen = project
            .sources
            .entry(USER_SOURCE.to_string())
            .or_insert(SourceSeen { first_seen_ms: now_ms, last_used_ms: now_ms });
        seen.last_used_ms = seen.last_used_ms.max(now_ms);
        project.overlay.hidden = false;
        project.state = ProjectState::Present;
        let mut changed = if *project != before { vec![path] } else { Vec::new() };
        changed.extend(self.evict_past_cap());
        Ok(changed)
    }

    /// The user's edit of a project's overlay. Returns whether it changed.
    pub(crate) fn update(&mut self, path: &str, edit: &OverlayEdit) -> Result<bool, ProjectReject> {
        if let Some(Some(name)) = &edit.rename
            && (name.trim().is_empty() || name.len() > MAX_NAME_BYTES || name.contains('\0'))
        {
            return Err(ProjectReject::InvalidName("name must be 1 to 256 bytes".into()));
        }
        let project = self
            .by_path
            .get_mut(path)
            .ok_or_else(|| ProjectReject::UnknownProject(path.to_string()))?;
        let before = project.overlay.clone();
        if let Some(rename) = &edit.rename {
            project.overlay.rename = rename.clone();
        }
        if let Some(pinned) = edit.pinned {
            project.overlay.pinned = pinned;
        }
        if let Some(hidden) = edit.hidden {
            project.overlay.hidden = hidden;
        }
        if let Some(order) = edit.order {
            project.overlay.order = order;
        }
        Ok(project.overlay != before)
    }

    /// The user removes a project. One a source still reports is hidden, so
    /// the next resync does not bring it back; any other one is deleted.
    pub(crate) fn remove(&mut self, path: &str) -> Result<(), ProjectReject> {
        let project = self
            .by_path
            .get_mut(path)
            .ok_or_else(|| ProjectReject::UnknownProject(path.to_string()))?;
        project.sources.remove(USER_SOURCE);
        if project.sources.is_empty() {
            self.by_path.remove(path);
        } else {
            project.overlay.hidden = true;
        }
        Ok(())
    }

    /// The user turned `source` off: it leaves every project. A project with
    /// nothing left (no source, no edit) goes; an edited one stays.
    // The per-source settings call it (projects.md slice 3).
    #[allow(dead_code)]
    pub(crate) fn disable_source(&mut self, source: &str) -> Vec<String> {
        let mut changed = Vec::new();
        self.by_path.retain(|path, project| {
            if project.sources.remove(source).is_some() {
                changed.push(path.clone());
            }
            !(project.sources.is_empty()
                && project.overlay.is_empty()
                && changed.last() == Some(path))
        });
        changed
    }

    /// Rule 4, with the disk facts the app checked (`project.sync`): a project
    /// in `gone` that no source other than the user reports is missing; one in
    /// `existing` is present. Returns the paths that changed.
    pub(crate) fn apply_disk(&mut self, existing: &[String], gone: &[String]) -> Vec<String> {
        let mut changed = Vec::new();
        for (paths, state) in [(gone, ProjectState::Missing), (existing, ProjectState::Present)] {
            for path in paths {
                let Some(project) = self.by_path.get_mut(path) else { continue };
                let reported = project.sources.keys().any(|source| source != USER_SOURCE);
                if state == ProjectState::Missing && reported {
                    continue;
                }
                if project.state != state {
                    project.state = state;
                    changed.push(path.clone());
                }
            }
        }
        changed
    }
}
