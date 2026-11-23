//! `workspace list --name/--cwd/--id/--tree`, `pane list --name/--cwd` and
//! `terminal list --cwd`: filters the CLI applies to the rows it already
//! reads (wire/list_filter.rs). The daemon's list request is unchanged.
//!
//! `--id <id>[,<id>...]` keeps the workspaces with one of those ids (or an
//! id starting with one), so an agent reads the workspaces it names instead
//! of grepping the whole list (Leo, 2026-11-19: "acpmux should expose these
//! a lot better"). `--tree` gives each workspace its panes and their tabs,
//! and lifts `extra.created_by` (the person, agent session or script that
//! made it) to `created_by`.
//!
//! `--name` matches a row's `name` exactly. `--cwd <path>` matches a
//! terminal whose folder is `<path>` or inside it; a workspace or pane
//! matches when any of its terminals does. `<path>` is made absolute
//! against the current folder and compared both as written (`.` and `..`
//! resolved) and with its links resolved, since a terminal reports the
//! folder its shell names (macOS `/tmp` is `/private/tmp`). Filters
//! combine with AND; no match is an empty list and exit 0.

use std::path::{Component, Path, PathBuf};

use super::{CommandPlan, Flags, UsageError, flags::missing_value};

/// The filters one list command carries. Empty filters nothing.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct ListFilter {
    /// `--name`: the exact `name` a row must have.
    pub name: Option<String>,
    /// `--cwd`: the folder a row's terminal must be in or under.
    pub cwd: Option<CwdFilter>,
    /// `--id`: the ids (or id prefixes) a row's `id` must be one of.
    pub ids: Vec<String>,
    /// `--tree`: each workspace with its panes, tabs and creator.
    pub tree: bool,
}

impl ListFilter {
    pub(in crate::cli) fn is_empty(&self) -> bool {
        self.name.is_none() && self.cwd.is_none() && self.ids.is_empty() && !self.tree
    }

    /// Whether row `id` passes `--id`: equal to one of its ids or starting with it.
    pub(in crate::cli) fn id_matches(&self, id: Option<&str>) -> bool {
        self.ids.is_empty()
            || id.is_some_and(|id| self.ids.iter().any(|wanted| id.starts_with(wanted.as_str())))
    }

    /// Whether row `name` passes `--name`.
    pub(in crate::cli) fn name_matches(&self, name: Option<&str>) -> bool {
        self.name.as_deref().is_none_or(|wanted| name == Some(wanted))
    }
}

/// The spellings of one `--cwd` folder, each absolute, without a trailing
/// slash (`/` stays `/`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct CwdFilter {
    roots: Vec<String>,
}

impl CwdFilter {
    /// `path` made absolute against `base`, `.` and `..` resolved, plus
    /// its link-resolved spelling when that differs (and exists).
    fn new(path: &str, base: &Path) -> Self {
        let absolute = lexical(&base.join(path));
        let mut roots = vec![absolute.to_string_lossy().into_owned()];
        if let Ok(real) = std::fs::canonicalize(&absolute) {
            let real = real.to_string_lossy().into_owned();
            if !roots.contains(&real) {
                roots.push(real);
            }
        }
        Self { roots }
    }

    /// Whether a terminal folder `cwd` is a root or inside one, compared
    /// part by part with this platform's separators (`/`, and `\\` on
    /// Windows), so `/a/bc` is not inside `/a/b`.
    pub(in crate::cli) fn contains(&self, cwd: &str) -> bool {
        let cwd = Path::new(cwd);
        self.roots.iter().any(|root| cwd.starts_with(Path::new(root)))
    }

    /// The filter of an absolute `path`, for tests elsewhere in the CLI.
    #[cfg(test)]
    pub(in crate::cli) fn for_test(path: &str) -> Self {
        Self { roots: vec![path.to_owned()] }
    }
}

/// `path` with `.` dropped and `..` taking off the previous part, without
/// reading the file system.
fn lexical(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// A flag's value; a flag given without one is a usage error.
fn value(flags: &mut Flags, name: &str) -> Result<Option<String>, UsageError> {
    let given = flags.values.contains_key(name);
    match flags.take(name) {
        Some(value) if !value.is_empty() => Ok(Some(value)),
        _ if given => Err(missing_value(name)),
        _ => Ok(None),
    }
}

/// Takes `--name` (when `name`) and `--cwd` (when `cwd`) for a list.
pub(super) fn take(flags: &mut Flags, name: bool, cwd: bool) -> Result<ListFilter, UsageError> {
    let name = if name { value(flags, "name")? } else { None };
    let cwd = match if cwd { value(flags, "cwd")? } else { None } {
        Some(path) => {
            let base = std::env::current_dir().map_err(|error| {
                UsageError::new(format!(
                    "--cwd {path}: cannot read the current folder ({error}); pass an absolute path"
                ))
            })?;
            // A quoted `~/…` reaches us unexpanded; read it as the shell would.
            let home = std::env::var_os("HOME").filter(|home| !home.is_empty());
            let path = match (path.strip_prefix('~'), home) {
                (Some(rest), Some(home)) if rest.is_empty() || rest.starts_with('/') => {
                    format!("{}{rest}", Path::new(&home).display())
                }
                _ => path,
            };
            Some(CwdFilter::new(&path, &base))
        }
        None => None,
    };
    Ok(ListFilter { name, cwd, ..ListFilter::default() })
}

/// `workspace list`'s filters: `--name`, `--cwd`, `--id` and `--tree`.
pub(super) fn take_workspace(flags: &mut Flags) -> Result<ListFilter, UsageError> {
    let mut filter = take(flags, true, true)?;
    if let Some(ids) = value(flags, "id")? {
        filter.ids =
            ids.split(',').map(str::trim).filter(|id| !id.is_empty()).map(str::to_owned).collect();
        if filter.ids.is_empty() {
            return Err(missing_value("id"));
        }
    }
    filter.tree = flags.boolean("tree");
    Ok(filter)
}

impl CommandPlan {
    /// The same list with `filter` applied to its rows.
    pub(super) fn filtered(self, filter: ListFilter) -> Self {
        match self {
            Self::Protocol(mut plan) => {
                plan.filter = filter;
                Self::Protocol(plan)
            }
            other => other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filter(path: &str, base: &str) -> CwdFilter {
        CwdFilter::new(path, Path::new(base))
    }

    #[test]
    fn cwd_matches_the_folder_and_what_is_inside_it_only() {
        let projects = filter("/nonexistent-cmux/projects/", "/");
        assert!(projects.contains("/nonexistent-cmux/projects"));
        assert!(projects.contains("/nonexistent-cmux/projects/"));
        assert!(projects.contains("/nonexistent-cmux/projects/app/src"));
        assert!(!projects.contains("/nonexistent-cmux/projects-old"));
        assert!(!projects.contains("/nonexistent-cmux"));
        assert!(filter("/", "/").contains("/anything"));
    }

    #[cfg(windows)]
    #[test]
    fn cwd_matches_inside_a_windows_folder() {
        let projects = filter(r"C:\work\projects", r"C:\");
        assert!(projects.contains(r"C:\work\projects\app"));
        assert!(projects.contains(r"C:\work\projects"));
        assert!(!projects.contains(r"C:\work\projects-old"));
    }

    #[test]
    fn cwd_is_made_absolute_against_the_current_folder() {
        let relative = filter("../b/./c", "/nonexistent-cmux/a");
        assert_eq!(relative.roots, vec!["/nonexistent-cmux/b/c".to_owned()]);
        assert!(relative.contains("/nonexistent-cmux/b/c/d"));
    }

    #[test]
    fn name_matches_exactly() {
        let named = ListFilter { name: Some("api".into()), ..ListFilter::default() };
        assert!(named.name_matches(Some("api")));
        assert!(!named.name_matches(Some("api-2")));
        assert!(!named.name_matches(None));
        assert!(ListFilter::default().name_matches(None));
    }

    #[test]
    fn id_matches_one_of_the_ids_or_a_prefix_of_one() {
        let by_id =
            ListFilter { ids: vec!["ws_7aee".into(), "ws_5899".into()], ..Default::default() };
        assert!(by_id.id_matches(Some("ws_7aee67b9a4766d8f988977bc5c1380ba")));
        assert!(by_id.id_matches(Some("ws_5899901293e83f3696104e5260ca3de6")));
        assert!(!by_id.id_matches(Some("ws_fddd5e")));
        assert!(!by_id.id_matches(None));
        assert!(ListFilter::default().id_matches(None));
    }
}
