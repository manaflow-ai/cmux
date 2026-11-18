//! Where `cmux ext add` gets an extension: a folder on this Mac, or a git
//! repository named the way people share one.
//!
//! A repository is named the way `cmux chat --repo` takes it: `OWNER/NAME` on GitHub, or an https
//! URL (`machine_repo::parse`, so never a `file:`, `ext::` or credentialed URL), with an optional
//! `@REF`. A GitHub browser link to a folder, `https://github.com/OWNER/NAME/tree/REF/PATH`, or a
//! `#PATH` after any of these, names the extension's folder inside the repository. `ext share`
//! prints the first form, pinned to a commit.
//!
//! The repository is cloned once into this user's cache (`~/.cache/cmux/extensions/HOST/OWNER/NAME`)
//! and fetched again on each `ext add`, so adding it again updates it. That folder belongs to
//! `ext add`: it is checked out detached at the commit the source names.

use std::ffi::OsStr;
use std::path::{Component, Path, PathBuf};

use cmux_cloud_start_core::machine_repo::{self, Invalid, Repo};

/// A parsed `ext add` source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Source {
    /// An extension folder on this Mac.
    Folder(PathBuf),
    /// A repository; `tail` is the path after `/tree/` (a ref, then maybe a folder) or after `@`,
    /// `subdir` the `#PATH`.
    Git { repo: Repo, tail: Vec<String>, subdir: Option<String> },
}

/// Reads `raw`: an existing folder (or one written as a path) is a folder; anything else must
/// name a repository.
pub(super) fn parse(raw: &str, cwd: &Path) -> Result<Source, String> {
    let raw = raw.trim();
    let looks_like_path = raw.starts_with('/') || raw.starts_with('.') || raw.starts_with('~');
    let local = match raw.strip_prefix("~/") {
        Some(rest) => std::env::var_os("HOME").map(|home| PathBuf::from(home).join(rest)),
        None => Some(cwd.join(raw)),
    };
    if let Some(dir) = local.filter(|dir| looks_like_path || dir.is_dir()) {
        return Ok(Source::Folder(dir));
    }
    let (spec, subdir) = match raw.split_once('#') {
        Some((spec, path)) => (spec, Some(clean_subdir(path)?)),
        None => (raw, None),
    };
    let (base, tail) = split_tree(spec);
    let mut repo = machine_repo::parse(base).map_err(|invalid| {
        match invalid {
            Invalid::Unrecognized => format!(
                "{raw}: give an extension folder, OWNER/NAME on GitHub, or an https git URL (a GitHub /tree/REF/PATH link works too)"
            ),
            Invalid::CredentialsInUrl => {
                format!("{raw}: the URL holds a login or token; give it without one (git uses your own)")
            }
            Invalid::InvalidRef => format!("{raw}: the @REF is not a branch, tag or commit"),
        }
    })?;
    // `@REF` wins over a `/tree/` tail (as `machine_repo::parse` reads them).
    let tail = match repo.r#ref.take() {
        Some(reference) => vec![reference],
        None => tail,
    };
    // Each part is a ref name's or a folder's part, never an option or a relative step.
    for part in &tail {
        let ok =
            !part.starts_with('-') && part != "." && part != ".." && machine_repo::is_ref(part);
        if !ok {
            return Err(format!(
                "{raw}: {part:?} in the /tree/ path is not a branch, tag, commit or folder name"
            ));
        }
    }
    Ok(Source::Git { repo, tail, subdir })
}

/// A GitHub `/tree/` link split into the repository and the path after `tree`. Other forms are
/// returned whole, with no tail.
fn split_tree(spec: &str) -> (&str, Vec<String>) {
    let rest = spec.strip_prefix("https://").or_else(|| spec.strip_prefix("http://"));
    let Some(rest) = rest.filter(|rest| rest.to_ascii_lowercase().starts_with("github.com/"))
    else {
        return (spec, Vec::new());
    };
    let parts: Vec<&str> = rest.trim_end_matches('/').split('/').collect();
    match parts.as_slice() {
        [_, _, _, tree, tail @ ..] if *tree == "tree" && !tail.is_empty() => {
            let cut = spec.len() - rest.len()
                + parts.iter().take(3).copied().collect::<Vec<_>>().join("/").len();
            (spec.get(..cut).unwrap_or(spec), tail.iter().map(|part| part.to_string()).collect())
        }
        _ => (spec, Vec::new()),
    }
}

/// A `#PATH`: relative, inside the repository, no empty parts.
fn clean_subdir(path: &str) -> Result<String, String> {
    let path = path.trim_matches('/');
    let ok = !path.is_empty()
        && Path::new(path).components().all(|part| matches!(part, Component::Normal(_)));
    if ok {
        Ok(path.to_string())
    } else {
        Err(format!("#{path}: give a folder inside the repository"))
    }
}

/// Where `repo` is cloned: `CACHE/cmux/extensions/HOST/OWNER/NAME`.
pub(super) fn cache_dir(cache: &Path, repo: &Repo) -> PathBuf {
    let mut dir = cache.join("cmux").join("extensions").join(&repo.host);
    dir.extend(repo.owner.split('/'));
    dir.join(&repo.name)
}

/// This user's cache folder: `XDG_CACHE_HOME`, else `~/.cache`.
pub(super) fn user_cache() -> Option<PathBuf> {
    std::env::var_os("XDG_CACHE_HOME")
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
}

/// What a fetch checked out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Fetched {
    /// The clone.
    pub clone: PathBuf,
    /// The extension's folder in it (the clone itself, or a folder inside).
    pub dir: PathBuf,
    pub commit: String,
    /// The branch, tag or commit the source named; none: the default branch.
    pub reference: Option<String>,
    /// The folder inside the repository, relative; none: its root.
    pub subdir: Option<String>,
}

/// Clones `url` into `clone` (or fetches the clone already there), checks out the commit `tail`
/// names (detached), and finds the extension's folder. `url` must come from [`parse`] (an https
/// URL); tests pass a local one.
pub(super) fn fetch(
    url: &str,
    tail: &[String],
    subdir: Option<&str>,
    clone: &Path,
) -> Result<Fetched, String> {
    if clone.join(".git").is_dir() {
        let origin = git(Some(clone), ["remote", "get-url", "origin"])?;
        if origin.trim_end_matches(".git") != url.trim_end_matches(".git") {
            return Err(format!(
                "{} is a clone of {origin}, not {url}; remove that folder to add from here",
                clone.display()
            ));
        }
        git(Some(clone), ["fetch", "--quiet", "--tags", "--prune", "origin"])
            .map_err(|said| format!("git fetch {url} failed: {said}"))?;
        // The default branch may have moved or been renamed.
        let _ = git(Some(clone), ["remote", "set-head", "origin", "--auto"]);
    } else {
        if let Some(parent) = clone.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|err| format!("could not make {}: {err}", parent.display()))?;
        }
        // Blobless: every commit and tree now (so any ref or commit resolves), file contents
        // when checked out.
        let args = ["clone", "--quiet", "--filter=blob:none", "--", url];
        git(None, args.map(OsStr::new).into_iter().chain([clone.as_os_str()]))
            .map_err(|said| format!("git clone {url} failed: {said}"))?;
    }
    let commit_of = |name: &str| {
        git(Some(clone), ["rev-parse", "--verify", "--quiet", &format!("{name}^{{commit}}")]).ok()
    };
    let (commit, reference, tree_path) = resolve(tail, commit_of).ok_or_else(|| match tail {
        [] => format!("{url} has no default branch"),
        _ => format!("{url} has no branch, tag or commit named {}", tail.join("/")),
    })?;
    git(
        Some(clone),
        ["-c", "advice.detachedHead=false", "checkout", "--quiet", "--detach", &commit],
    )
    .map_err(|said| format!("git checkout {commit} in {} failed: {said}", clone.display()))?;
    let subdir = match (tree_path, subdir) {
        (Some(path), Some(more)) => Some(format!("{path}/{more}")),
        (path, more) => path.or_else(|| more.map(str::to_string)),
    };
    let dir = match &subdir {
        Some(path) => clone.join(path),
        None => clone.to_path_buf(),
    };
    // A folder that is a link could lead out of the clone.
    let inside = dir
        .canonicalize()
        .ok()
        .zip(clone.canonicalize().ok())
        .is_some_and(|(dir, clone)| dir.starts_with(clone));
    if !dir.is_dir() || !inside {
        return Err(format!(
            "{url} at {} has no folder {}",
            commit.get(..commit.len().min(12)).unwrap_or(&commit),
            subdir.as_deref().unwrap_or("/")
        ));
    }
    Ok(Fetched { clone: clone.to_path_buf(), dir, commit, reference, subdir })
}

/// The commit `tail` names, the ref as written, and the folder after it: the shortest leading
/// part of `tail` that is a branch, tag or commit is the ref (a branch name may hold `/`), the
/// rest is the folder. Full commit IDs are object pins, never ref names. An empty `tail`
/// is the default branch.
pub(super) fn resolve(
    tail: &[String],
    commit_of: impl Fn(&str) -> Option<String>,
) -> Option<(String, Option<String>, Option<String>)> {
    if tail.is_empty() {
        // Only origin's default branch: the clone's own HEAD is whatever an earlier add checked out.
        let commit = commit_of("refs/remotes/origin/HEAD")?;
        return Some((commit, None, None));
    }
    if let Some((pin, rest)) = tail.split_first()
        && matches!(pin.len(), 40 | 64)
        && pin.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        // A publisher controls branch/tag names, including names identical to a shared
        // commit. Resolve the object itself and fail closed if Git returns another ID.
        let commit = commit_of(pin).filter(|commit| commit.eq_ignore_ascii_case(pin))?;
        let subdir = (!rest.is_empty()).then(|| rest.join("/"));
        return Some((commit, Some(pin.clone()), subdir));
    }
    (1..=tail.len()).find_map(|cut| {
        let reference = tail.get(..cut)?.join("/");
        let commit = [
            format!("refs/remotes/origin/{reference}"),
            format!("refs/tags/{reference}"),
            reference.clone(),
        ]
        .iter()
        .find_map(|name| commit_of(name))?;
        let rest = (cut < tail.len()).then(|| tail.get(cut..).map(|rest| rest.join("/"))).flatten();
        Some((commit, Some(reference), rest))
    })
}

/// `git ARGS` (in `dir` when given) with no prompt: a repository that needs a login fails at once.
/// Err: what git said.
pub(super) fn git<I, S>(dir: Option<&Path>, args: I) -> Result<String, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut command = cmux_process::Command::new("git");
    if let Some(dir) = dir {
        command.arg("-C").arg(dir);
    }
    let output = command
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .map_err(|err| format!("could not run git: {err}"))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned());
    }
    let said = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    Err(if said.is_empty() { format!("exit {}", output.status) } else { said })
}
