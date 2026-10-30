//! How a harness program was installed, read from where its file really is,
//! and the update that channel runs.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub(super) mod bun;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Channel {
    /// `npm install -g` (a package under `<prefix>/lib/node_modules`).
    Npm,
    /// `bun add -g` (a package under `~/.bun/install/global`).
    Bun,
    /// A Homebrew formula (`Cellar`).
    Brew,
    /// A Homebrew cask (`Caskroom`).
    BrewCask,
    /// The vendor's own installer, which updates itself (`claude update`).
    Native,
    /// Run through a launcher, interpreter or shell (`npx`, `uvx`, `node`,
    /// `sh`): the program behind it is not checked, and nothing is updated.
    Launcher,
    /// A binary placed by hand or by an installer cmux does not know.
    Standalone,
    /// Not found.
    Missing,
}

/// Where a program came from: its channel and, for a package manager, the
/// package (or formula) name and the folder it writes to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Install {
    pub channel: Channel,
    pub package: Option<String>,
    /// The folder an update writes (npm's `lib/node_modules`), to bind its
    /// target prefix and tell whether it needs elevated rights.
    pub writes: Option<PathBuf>,
}

/// The vendor installers cmux knows: a folder under the home, the npm package
/// that publishes the same versions, and the program's own update verb.
const NATIVE: &[(&str, &str, &str)] = &[
    (".local/share/claude", "@anthropic-ai/claude-code", "update"),
    (".claude/local", "@anthropic-ai/claude-code", "update"),
    (".opencode", "opencode-ai", "upgrade"),
];

/// Programs that run another program (a launcher fetching it per launch, an
/// interpreter, a shell): the harness is behind them, not them.
const RUNNERS: &[&str] = &[
    "npx", "uvx", "bunx", "pnpx", "pnpm", "yarn", "uv", "pipx", "node", "bun", "deno", "python",
    "python3", "env", "sh", "bash", "zsh", "dash",
];

/// A launcher names the program behind it, not an installed agent CLI.
pub(super) fn is_launcher(name: &str) -> bool {
    RUNNERS.contains(&name)
}

/// The install behind `program` (as configured) found at `path` (its real
/// file, symlinks resolved), for a user whose home is `home`.
pub fn detect(program: &str, path: Option<&Path>, home: &Path) -> Install {
    let plain = |channel| Install { channel, package: None, writes: None };
    let name = Path::new(program).file_name().and_then(|n| n.to_str()).unwrap_or(program);
    if is_launcher(name) {
        return plain(Channel::Launcher);
    }
    let Some(path) = path else { return plain(Channel::Missing) };
    let text = path.to_string_lossy();
    // Homebrew and the vendor installers first: their packages may bundle a
    // `node_modules` folder that npm does not own.
    for (marker, channel) in [("/Cellar/", Channel::Brew), ("/Caskroom/", Channel::BrewCask)] {
        if let Some((_, after)) = text.split_once(marker) {
            let package = after.split('/').next().filter(|s| !s.is_empty()).map(str::to_owned);
            return Install { channel, package, writes: None };
        }
    }
    for (folder, package, _) in NATIVE {
        if path.starts_with(home.join(folder)) {
            return Install {
                channel: Channel::Native,
                package: Some((*package).into()),
                writes: None,
            };
        }
    }
    // Only npm's and bun's global folders; pnpm, yarn and a project's own
    // `node_modules` update some other way.
    if let Some(install) = bun::detect(path, home) {
        return install;
    }
    if let Some((before, after)) = text.split_once("/lib/node_modules/")
        && let Some(package) = package_name(after)
    {
        let writes = Some(PathBuf::from(format!("{before}/lib/node_modules")));
        return Install { channel: Channel::Npm, package: Some(package), writes };
    }
    plain(Channel::Standalone)
}

/// `@scope/name/bin/x` -> `@scope/name`; `name/bin/x` -> `name`.
fn package_name(after: &str) -> Option<String> {
    let mut parts = after.split('/');
    let first = parts.next().filter(|s| !s.is_empty() && !s.starts_with('.'))?;
    if first.starts_with('@') {
        let second = parts.next().filter(|s| !s.is_empty())?;
        return Some(format!("{first}/{second}"));
    }
    Some(first.to_owned())
}

/// The command that updates an install, as a program and its arguments.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct UpdatePlan {
    pub argv: Vec<String>,
    /// The line to show or type (quoted for a shell).
    pub command: String,
    /// The update writes a folder this user cannot: cmux never runs it,
    /// it shows `command` (with `sudo`) for the person to run.
    pub elevated: bool,
}

/// How to update `install` of the program found at `path` (its file at
/// `real`), or None when only the way it was installed can (a standalone
/// binary, a launcher, a missing one).
pub fn update_plan(
    install: &Install,
    path: Option<&Path>,
    real: Option<&Path>,
    home: &Path,
) -> Option<UpdatePlan> {
    let package = install.package.as_deref();
    let argv: Vec<String> = match (install.channel, package) {
        (Channel::Npm, Some(p)) => {
            let modules = install.writes.as_deref()?;
            let lib = modules.parent()?;
            if modules.file_name()? != "node_modules" || lib.file_name()? != "lib" {
                return None;
            }
            let prefix = lib.parent()?;
            if !absolute_prefix(prefix) {
                return None;
            }
            vec![
                "npm".into(),
                "install".into(),
                "-g".into(),
                "--prefix".into(),
                prefix.to_str()?.into(),
                format!("{p}@latest"),
            ]
        }
        (Channel::Bun, Some(_)) => bun::argv(install, path?, real?, home)?,
        (Channel::Brew, Some(f)) => vec!["brew".into(), "upgrade".into(), f.into()],
        (Channel::BrewCask, Some(c)) => {
            vec!["brew".into(), "upgrade".into(), "--cask".into(), c.into()]
        }
        (Channel::Native, _) => {
            let real = real?;
            let verb = NATIVE.iter().find(|(folder, ..)| real.starts_with(home.join(folder)))?.2;
            vec![path?.to_string_lossy().into_owned(), verb.into()]
        }
        _ => return None,
    };
    let elevated = install.writes.as_deref().is_some_and(|dir| !writable(dir))
        || (install.channel == Channel::Bun && !writable(bun::bin_dir(&argv)?));
    let line = argv.iter().map(|w| quote(w)).collect::<Vec<_>>().join(" ");
    let command = if elevated { format!("sudo {line}") } else { line };
    Some(UpdatePlan { argv, command, elevated })
}

/// Old saved health rows can still contain an update without a target.
/// Never execute that plan using whichever npm prefix today's shell selects.
pub(super) fn npm_update_matches(plan: &UpdatePlan, package: Option<&str>) -> bool {
    let argv = plan.argv.as_slice();
    let [program, verb, global, flag, prefix, _package] = argv else { return false };
    Path::new(program).file_name().is_some_and(|name| name == "npm")
        && verb == "install"
        && global == "-g"
        && flag == "--prefix"
        && absolute_prefix(Path::new(prefix))
        && package.is_some_and(|package| argv.last() == Some(&format!("{package}@latest")))
}

fn absolute_prefix(prefix: &Path) -> bool {
    prefix.is_absolute()
        && !prefix.components().any(|part| {
            matches!(part, std::path::Component::CurDir | std::path::Component::ParentDir)
        })
}

#[cfg(unix)]
fn writable(dir: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(c) = std::ffi::CString::new(dir.as_os_str().as_bytes()) else { return false };
    // SAFETY: `c` is a valid NUL-terminated path for the call's duration.
    unsafe { libc::access(c.as_ptr(), libc::W_OK) == 0 }
}

#[cfg(not(unix))]
fn writable(dir: &Path) -> bool {
    std::fs::metadata(dir).is_ok_and(|m| !m.permissions().readonly())
}

/// `word` quoted for a POSIX shell when it needs it.
pub fn quote(word: &str) -> String {
    let plain = !word.is_empty()
        && word.bytes().all(|b| b.is_ascii_alphanumeric() || b"@%+=:,./_-".contains(&b));
    if plain { word.to_owned() } else { format!("'{}'", word.replace('\'', "'\\''")) }
}
