//! The first copy of a Cloud machine's folder on a Mac that never had it
//! (Transfer to This Mac of a chat started on the machine or by someone
//! else, `cmux link seed fetch`): the machine's folder lands in a new, empty
//! folder here by `cmux link sync pull`'s own engine ([`super::pull`]), with
//! a base that says nothing was pushed, so every file and, in git, the
//! branch, its commits and what is staged come back as the machine has them.
//!
//! The machine is not trusted, as in every pull: names are checked, no
//! repository path or hook comes back, every git object is checked
//! (`transfer.fsckObjects`), and secrets never come back (`keep_new`: the
//! caller's rule, `cmux link access`'s secret names; untracked `.env*` files
//! never do). Ignored files stay there: the machine's top `.gitignore` is
//! written here first, so this working copy's ignore rules are the
//! machine's before any file is chosen (a nested `.gitignore` arrives with
//! the files and rules what is below it from the next pull on).
//!
//! Only a folder that does not exist yet or is empty is filled; one this
//! command made is removed again when the fetch fails, so a retry starts
//! over. A partial clone (a seed: `--filter=blob:none`) lacks history
//! objects and is refused here as `fetch.partial_clone`: `cmux link seed
//! fetch` takes it from its remote instead ([`super::super::seed_cli`]).

use cmux_process::Command;
use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context as _, bail};

use super::git_back::{self, GitBase};
use super::pull::{self, Pulled};
use super::remote::Remote;
use super::{Back, Manifest};

/// What the machine's folder is, as a fetch needs to know it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::link) enum Shape {
    /// No repository: files only.
    Plain,
    /// A repository with every object (a copy pushed it, or the machine made it).
    Git,
    /// A partial clone: its history comes from `remote_url`, its changes
    /// from the seed export.
    Partial { remote_url: Option<String> },
}

/// What the machine's folder at `remote_root` is.
pub(in crate::link) fn shape(socket: &Path, remote_root: &str) -> anyhow::Result<Shape> {
    let mut remote = Remote::connect(socket)?;
    match remote.kind(remote_root)?.as_deref() {
        Some("dir") => {}
        Some(_) => bail!("{remote_root} on the machine is not a folder"),
        None => bail!("{remote_root} is not on the machine"),
    }
    if remote.kind(&format!("{remote_root}/.git"))?.as_deref() != Some("dir") {
        return Ok(Shape::Plain);
    }
    let config = remote.read(&format!("{remote_root}/.git/config"))?.unwrap_or_default();
    let config = String::from_utf8_lossy(&config);
    Ok(if is_partial(&config) {
        Shape::Partial { remote_url: origin_url(&config) }
    } else {
        Shape::Git
    })
}

/// Whether a git config makes the repository a partial clone.
pub(in crate::link) fn is_partial(config: &str) -> bool {
    config.lines().map(|line| line.trim().to_ascii_lowercase().replace(' ', "")).any(|line| {
        line == "promisor=true"
            || line.starts_with("partialclonefilter=")
            || line.starts_with("partialclone=")
    })
}

/// `remote.origin.url` of a git config, when it is a plain `https://` URL
/// with no user info (the machine's text: a URL that could reach this Mac's
/// own files or carry a credential is never used).
pub(in crate::link) fn origin_url(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines().map(str::trim) {
        if line.starts_with('[') {
            in_origin = line.replace(' ', "").eq_ignore_ascii_case("[remote\"origin\"]");
            continue;
        }
        if !in_origin {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        if key.trim().eq_ignore_ascii_case("url") {
            let url = value.trim().trim_matches('"');
            let rest = url.strip_prefix("https://")?;
            let host = rest.split('/').next().unwrap_or_default();
            let plain = !host.is_empty()
                && !host.contains('@')
                && url.chars().all(|c| c.is_ascii_graphic())
                && !url.contains("..");
            return plain.then(|| url.to_owned());
        }
    }
    None
}

/// The nearest folder at or above `path` on the machine with a `.git` folder: the repository a
/// chat's folder is in. Never `/`, a top folder (`/home`) or a home folder itself (`/home/NAME`,
/// `/root`), whose dotfiles repository is not the chat's project. None when there is none.
pub(in crate::link) fn repo_root(socket: &Path, path: &str) -> anyhow::Result<Option<String>> {
    let mut remote = Remote::connect(socket)?;
    let mut here = path.trim_end_matches('/').to_owned();
    while deep_enough(&here) {
        if remote.kind(&format!("{here}/.git"))?.as_deref() == Some("dir") {
            return Ok(Some(here));
        }
        let Some((parent, _)) = here.rsplit_once('/') else { break };
        here = parent.to_owned();
    }
    Ok(None)
}

/// Whether `path` is `/`, a top folder (`/home`, `/tmp`) or a home folder itself (`/home/NAME`,
/// `/Users/NAME`, `/root`): a folder too broad to copy to another Mac, since it holds the machine's
/// own sign-ins and keys (dotfiles no secret list fully names).
pub(in crate::link) fn too_broad(path: &str) -> bool {
    let parts: Vec<&str> =
        path.split('/').filter(|part| !part.is_empty() && *part != ".").collect();
    parts.len() <= 1
        || (parts.len() == 2 && matches!(parts.first(), Some(&("home" | "Users"))))
        || parts.contains(&"..")
}

/// Whether `path` is below a home folder (`/home/NAME/x`, `/root/x`, `/Users/NAME/x`) or three
/// folders deep elsewhere: a folder a project can be.
fn deep_enough(path: &str) -> bool {
    let parts: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
    match parts.first() {
        Some(&"root") => parts.len() >= 2,
        Some(_) => parts.len() >= 3,
        None => false,
    }
}

/// The machine's seed record HEAD (`refs/cmux-seed/head`, loose or packed)
/// and its branch: what a partial clone's fetch starts from. None when the
/// folder is not a seed's.
pub(in crate::link) fn seed_head(
    socket: &Path,
    remote_root: &str,
) -> anyhow::Result<Option<(String, Option<String>)>> {
    let mut remote = Remote::connect(socket)?;
    let git = format!("{remote_root}/.git");
    let (head_ref, _) = git_back::machine_head(&mut remote, &git)?;
    let loose = remote
        .read(&format!("{git}/refs/cmux-seed/head"))?
        .map(|raw| String::from_utf8_lossy(&raw).trim().to_owned());
    let found = match loose {
        Some(id) => Some(id),
        None => {
            let packed = remote.read(&format!("{git}/packed-refs"))?.unwrap_or_default();
            String::from_utf8_lossy(&packed).lines().find_map(|line| {
                let (id, name) = line.split_once(' ')?;
                (name == "refs/cmux-seed/head").then(|| id.to_owned())
            })
        }
    };
    Ok(found.filter(|id| super::is_sha(id)).map(|id| (id, head_ref)))
}

/// Makes `local` (it must not exist, or be an empty folder). True when this
/// call made it, so a failed fetch removes it again.
pub(in crate::link) fn claim(local: &Path) -> anyhow::Result<bool> {
    match std::fs::symlink_metadata(local) {
        Ok(meta) if meta.is_dir() => {
            if std::fs::read_dir(local)?.next().is_some() {
                bail!("{} is not empty: a transfer fills only a new folder", local.display());
            }
            Ok(false)
        }
        Ok(_) => bail!("{} is not a folder", local.display()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            std::fs::create_dir_all(local)
                .with_context(|| format!("cannot make {}", local.display()))?;
            Ok(true)
        }
        Err(error) => Err(error).with_context(|| format!("cannot open {}", local.display())),
    }
}

/// Fills the empty folder `local` with the machine's `remote_root`
/// ([`Shape::Plain`] or [`Shape::Git`]); `adopt` keeps the records on both
/// sides (the chat moves here), else nothing on the machine changes.
pub(in crate::link) fn fetch(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    adopt: bool,
    keep_new: &dyn Fn(&str) -> bool,
) -> Back {
    let failed = |code: &str, error: String| Back::Failed { code: code.into(), error };
    let shape = match shape(socket, remote_root) {
        Ok(shape) => shape,
        Err(error) => return failed("fetch.no_folder", format!("{error:#}")),
    };
    if let Shape::Partial { .. } = shape {
        let why = "the machine's folder is a partial clone; it is fetched from its remote";
        return failed("fetch.partial_clone", why.into());
    }
    let made = match claim(local) {
        Ok(made) => made,
        Err(error) => return failed("fetch.folder_not_empty", format!("{error:#}")),
    };
    let answer = fill(socket, local, remote_root, shape == Shape::Git, adopt, keep_new);
    if !matches!(answer, Back::Done(_)) && made {
        let _ = std::fs::remove_dir_all(local);
    }
    answer
}

fn fill(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    git: bool,
    adopt: bool,
    keep_new: &dyn Fn(&str) -> bool,
) -> Back {
    let base = match prepare(socket, local, remote_root, git) {
        Ok(base) => base,
        Err(error) => {
            return Back::Failed { code: "sync_failed".into(), error: format!("{error:#}") };
        }
    };
    let fresh = Manifest { version: 1, files: BTreeMap::new(), git: base, links: BTreeMap::new() };
    match pull::pull_fresh(socket, local, remote_root, keep_new, fresh, adopt) {
        Ok(Pulled::Done(mut summary)) => {
            cmux_json::JsonSet::set(
                &mut summary,
                "mode",
                serde_json::json!(if git { "git" } else { "copy" }),
            );
            Back::Done(summary)
        }
        Ok(Pulled::Conflict(conflicts, reasons, _)) => Back::Conflict(conflicts, reasons),
        Err(error) => {
            Back::Failed { code: pull::failure_code(&error), error: format!("{error:#}") }
        }
    }
}

/// In git: an empty repository here on the machine's branch, with the
/// machine's top `.gitignore`, and the base that says it has nothing yet.
fn prepare(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    git: bool,
) -> anyhow::Result<Option<GitBase>> {
    if !git {
        if super::in_git(local) {
            bail!("{} is inside a git working copy; pick a folder outside it", local.display());
        }
        return Ok(None);
    }
    let mut remote = Remote::connect(socket)?;
    let (head_ref, _) = git_back::machine_head(&mut remote, &format!("{remote_root}/.git"))?;
    run(Command::new("git").arg("-C").arg(local).args(["init", "-q"]))?;
    if let Some(name) = &head_ref {
        run(Command::new("git").arg("-C").arg(local).args(["symbolic-ref", "HEAD", name]))?;
    }
    if let Some(ignore) = remote.read(&format!("{remote_root}/.gitignore"))? {
        std::fs::write(local.join(".gitignore"), ignore).context("cannot write .gitignore")?;
    }
    let here = git_back::base_of(local)?;
    Ok(Some(GitBase { head_ref, head: None, staged: here.staged }))
}

fn run(command: &mut Command) -> anyhow::Result<()> {
    let out = command.env("GIT_TERMINAL_PROMPT", "0").output().context("cannot run git")?;
    if !out.status.success() {
        bail!("git failed: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{claim, deep_enough, is_partial, origin_url, too_broad};

    #[test]
    fn a_repository_root_is_never_a_home_or_top_folder() {
        for (path, ok) in [
            ("/", false),
            ("/home", false),
            ("/home/cmux", false),
            ("/home/cmux/app", true),
            ("/root", false),
            ("/root/app", true),
            ("/Users/me", false),
            ("/Users/me/app", true),
            ("/work/a", false),
            ("/work/a/b", true),
        ] {
            assert_eq!(deep_enough(path), ok, "{path}");
        }
        for (path, broad) in [
            ("/", true),
            ("", true),
            ("/home", true),
            ("/tmp", true),
            ("/root", true),
            ("/root/", true),
            ("/home/cmux", true),
            ("/home/cmux/", true),
            ("/Users/me", true),
            ("/home/cmux/../..", true),
            ("/home/cmux/app", false),
            ("/root/app", false),
            ("/workspace/app", false),
            ("/tmp/x", false),
        ] {
            assert_eq!(too_broad(path), broad, "{path}");
        }
    }

    #[test]
    fn agent_and_tool_sign_ins_never_come_over_but_project_settings_do() {
        use crate::link::access_cli::is_secret;
        for path in [
            ".codex/auth.json",
            "x/.claude/.credentials.json",
            ".claude.json",
            ".config/gh/hosts.yml",
            ".Docker/Config.json",
        ] {
            assert!(is_secret(path), "{path}");
        }
        for path in [
            ".claude/settings.json",
            ".claude/commands/review.md",
            ".config/app.toml",
            "src/auth.json",
        ] {
            assert!(!is_secret(path), "{path}");
        }
    }

    #[test]
    fn a_seed_clone_is_partial_and_a_copy_is_not() {
        let seed = "[core]\n\trepositoryformatversion = 1\n[remote \"origin\"]\n\turl = https://github.com/acme/app.git\n\tpromisor = true\n\tpartialclonefilter = blob:none\n";
        assert!(is_partial(seed));
        assert!(!is_partial(
            "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://github.com/acme/app.git\n"
        ));
    }

    #[test]
    fn only_a_plain_https_origin_is_taken_from_the_machine() {
        let config = |url: &str| {
            format!(
                "[remote \"upstream\"]\n\turl = https://evil.test/x\n[remote \"origin\"]\n\turl = {url}\n"
            )
        };
        assert_eq!(
            origin_url(&config("https://github.com/acme/app.git")).as_deref(),
            Some("https://github.com/acme/app.git")
        );
        assert_eq!(origin_url(&config("https://token@github.com/acme/app.git")), None);
        assert_eq!(origin_url(&config("file:///Users/me/secret")), None);
        assert_eq!(origin_url(&config("/Users/me/repo")), None);
        assert_eq!(origin_url(&config("ext::sh -c touch% /tmp/pwned")), None);
        assert_eq!(origin_url("[core]\n"), None);
    }

    #[test]
    fn only_a_new_or_empty_folder_is_claimed() {
        let dir = tempfile::tempdir().unwrap();
        let fresh = dir.path().join("a/b");
        assert!(claim(&fresh).unwrap());
        assert!(!claim(&fresh).unwrap());
        std::fs::write(fresh.join("x"), "1").unwrap();
        assert!(claim(&fresh).is_err());
    }
}
