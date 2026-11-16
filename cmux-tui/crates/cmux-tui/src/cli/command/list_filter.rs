//! `workspace list --name/--cwd`, `pane list --name/--cwd` and
//! `terminal list --cwd`: filters the CLI applies to the rows it already
//! reads (wire/list_filter.rs). The daemon's list request is unchanged.
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
}

impl ListFilter {
    pub(in crate::cli) fn is_empty(&self) -> bool {
        self.name.is_none() && self.cwd.is_none()
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
    Ok(ListFilter { name, cwd })
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
        let named = ListFilter { name: Some("api".into()), cwd: None };
        assert!(named.name_matches(Some("api")));
        assert!(!named.name_matches(Some("api-2")));
        assert!(!named.name_matches(None));
        assert!(ListFilter::default().name_matches(None));
    }
}
