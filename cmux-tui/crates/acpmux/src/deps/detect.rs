//! Which ecosystems a folder uses, what each one's cache holds, how it
//! installs, and its cache key.

use std::path::{Path, PathBuf};
use std::process::Command;

use sha2::{Digest, Sha256};

/// Bumped when what an archive holds, or how it is laid out, changes.
// v2: archives packed with zstd -12 --long=27, each stored with its timing record (`remote::meta_key`).
const KEY_VERSION: &str = "acpmux-deps v2";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ecosystem {
    Bun,
    Npm,
    Pnpm,
    Yarn,
    Cargo,
    Uv,
}

impl Ecosystem {
    pub fn name(self) -> &'static str {
        match self {
            Ecosystem::Bun => "bun",
            Ecosystem::Npm => "npm",
            Ecosystem::Pnpm => "pnpm",
            Ecosystem::Yarn => "yarn",
            Ecosystem::Cargo => "cargo",
            Ecosystem::Uv => "uv",
        }
    }

    /// The tool that installs, and the version commands whose output goes into the key.
    fn versions(self) -> &'static [&'static [&'static str]] {
        match self {
            // node too: native addons in node_modules are built for one node ABI.
            Ecosystem::Bun => &[&["bun", "--version"], &["node", "--version"]],
            Ecosystem::Npm => &[&["npm", "--version"]],
            Ecosystem::Pnpm => &[&["pnpm", "--version"]],
            Ecosystem::Yarn => &[&["yarn", "--version"], &["node", "--version"]],
            Ecosystem::Cargo => &[&["cargo", "--version"]],
            Ecosystem::Uv => &[&["uv", "--version"]],
        }
    }
}

/// One project in the folder: an ecosystem and its lockfile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Project {
    pub ecosystem: Ecosystem,
    pub dir: PathBuf,
    pub lockfile: PathBuf,
}

/// The projects in `dir` (not its subfolders). One JavaScript package manager
/// per folder, by lockfile: bun, then pnpm, yarn and npm.
pub fn detect(dir: &Path) -> Vec<Project> {
    let found = |name: &str| Some(dir.join(name)).filter(|p| p.is_file());
    let mut out = Vec::new();
    let js = [
        (Ecosystem::Bun, "bun.lock"),
        (Ecosystem::Bun, "bun.lockb"),
        (Ecosystem::Pnpm, "pnpm-lock.yaml"),
        (Ecosystem::Yarn, "yarn.lock"),
        (Ecosystem::Npm, "package-lock.json"),
    ];
    if let Some((ecosystem, lockfile)) =
        js.iter().find_map(|(eco, name)| found(name).map(|path| (*eco, path)))
    {
        out.push(Project { ecosystem, dir: dir.to_owned(), lockfile });
    }
    for (ecosystem, name) in [(Ecosystem::Cargo, "Cargo.lock"), (Ecosystem::Uv, "uv.lock")] {
        if let Some(lockfile) = found(name) {
            out.push(Project { ecosystem, dir: dir.to_owned(), lockfile });
        }
    }
    out
}

/// Whether the project's own installed tree is already there: its
/// `node_modules` (JavaScript) or `.venv` (uv). Cargo's fetch replaces nothing.
pub fn installed(project: &Project) -> bool {
    let tree = match project.ecosystem {
        Ecosystem::Bun | Ecosystem::Npm | Ecosystem::Pnpm | Ecosystem::Yarn => "node_modules",
        Ecosystem::Uv => ".venv",
        Ecosystem::Cargo => return false,
    };
    std::fs::read_dir(project.dir.join(tree)).is_ok_and(|mut entries| entries.next().is_some())
}

/// What one project's archive holds and how it installs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    /// Archive paths are relative to this folder.
    pub root: PathBuf,
    /// The folders under `root` that are packed.
    pub include: Vec<PathBuf>,
    /// The archive is a project's own `node_modules`: restored only when
    /// absent, unpacked to the side and moved into place in one rename. A
    /// package manager's download cache is merged into what is there instead.
    pub replaces: bool,
    pub install: Vec<String>,
}

static NEUTRAL_PROBES: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Ask tools from the home folder instead of the project, so no project
/// config or project-pinned tool (`yarnPath`, plugins, `.npmrc` cache dirs)
/// is read: what a restore-only warm uses.
pub fn neutral_probes(on: bool) {
    NEUTRAL_PROBES.store(on, std::sync::atomic::Ordering::Relaxed);
}

/// The first line a command prints, or None when it cannot run.
fn output(argv: &[&str], dir: &Path) -> Option<String> {
    let (program, args) = argv.split_first()?;
    let neutral = NEUTRAL_PROBES.load(std::sync::atomic::Ordering::Relaxed);
    let cwd = if neutral { home().unwrap_or_else(std::env::temp_dir) } else { dir.to_owned() };
    let mut command = Command::new(program);
    command.args(args).current_dir(cwd);
    if neutral {
        // Yarn Classic otherwise hands off to a yarnPath it finds.
        command.env("YARN_IGNORE_PATH", "1");
    }
    let out = command.output().ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines().next().map(|line| line.trim().to_owned()).filter(|line| !line.is_empty())
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from)
}

/// A cache folder named by a tool: its parent is the root, so the archive
/// holds the one folder.
fn split(path: PathBuf) -> Option<(PathBuf, PathBuf)> {
    let name = PathBuf::from(path.file_name()?);
    Some((path.parent()?.to_owned(), name))
}

/// A cache folder set by tool config (pnpm's `store-dir`, uv's `cache-dir`,
/// which a repo can choose) that is the filesystem root, the home folder or
/// one of its ancestors, or a credentials name, would pack far more than
/// dependencies: such a plan is refused.
fn too_broad(plan: &Plan) -> bool {
    let home = home();
    let bases = cache_bases();
    plan.include.iter().any(|rel| {
        let full = plan.root.join(rel);
        full.parent().is_none()
            || home.as_deref().is_some_and(|h| h.starts_with(&full))
            || rel.components().any(|c| super::archive::denied(&c.as_os_str().to_string_lossy()))
            // A shared cache unpacks only inside a known cache folder: a repo
            // that points uv's cache-dir at ~/.config never gets it overwritten.
            || (!plan.replaces
                && (full.components().any(|c| matches!(c, std::path::Component::ParentDir))
                    || !bases.iter().any(|base| full.starts_with(base) && full != *base)))
    })
}

/// Folders a package manager's own cache lives under: the user's cache
/// folders and each tool's home, from the environment (never from a repo).
fn cache_bases() -> Vec<PathBuf> {
    let mut bases: Vec<PathBuf> = ["XDG_CACHE_HOME", "CARGO_HOME", "UV_CACHE_DIR", "PNPM_HOME"]
        .iter()
        .filter_map(|name| std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from))
        .filter(|p| p.is_absolute())
        .collect();
    if let Some(home) = home() {
        for rel in
            [".cache", "Library/Caches", ".npm", ".cargo", ".local/share/pnpm", "Library/pnpm"]
        {
            bases.push(home.join(rel));
        }
    }
    bases
}

/// The install that runs after a restore, when the tool can be told to use
/// only what is cached (`--offline`); None to run the normal install.
pub fn offline_install(ecosystem: Ecosystem, install: &[String]) -> Option<Vec<String>> {
    let mut argv: Vec<String> =
        install.iter().filter(|a| *a != "--prefer-offline").cloned().collect();
    match ecosystem {
        Ecosystem::Cargo | Ecosystem::Uv | Ecosystem::Npm | Ecosystem::Pnpm => {
            argv.push("--offline".into());
            Some(argv)
        }
        // A restored node_modules leaves bun and yarn nearly nothing to do.
        Ecosystem::Bun | Ecosystem::Yarn => None,
    }
}

pub fn plan(project: &Project) -> Option<Plan> {
    plan_of(project).filter(|plan| !too_broad(plan))
}

fn plan_of(project: &Project) -> Option<Plan> {
    let dir = &project.dir;
    let tool = |argv: &[&str]| output(argv, dir);
    let strings = |argv: &[&str]| argv.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    Some(match project.ecosystem {
        Ecosystem::Bun => Plan {
            root: dir.clone(),
            include: vec!["node_modules".into()],
            replaces: true,
            install: strings(&["bun", "install", "--frozen-lockfile"]),
        },
        Ecosystem::Yarn => {
            let classic = tool(&["yarn", "--version"])?.starts_with("1.");
            Plan {
                root: dir.clone(),
                include: vec!["node_modules".into()],
                replaces: true,
                install: if classic {
                    strings(&["yarn", "install", "--frozen-lockfile"])
                } else {
                    strings(&["yarn", "install", "--immutable"])
                },
            }
        }
        // `npm ci` deletes node_modules, so npm keeps its download cache.
        Ecosystem::Npm => {
            let cache = PathBuf::from(tool(&["npm", "config", "get", "cache"])?);
            Plan {
                root: cache,
                include: vec!["_cacache".into()],
                replaces: false,
                install: strings(&["npm", "ci", "--prefer-offline", "--no-audit", "--no-fund"]),
            }
        }
        // pnpm's node_modules links into its store, so the store is what is kept.
        Ecosystem::Pnpm => {
            let (root, name) = split(PathBuf::from(tool(&["pnpm", "store", "path"])?))?;
            Plan {
                root,
                include: vec![name],
                replaces: false,
                install: strings(&["pnpm", "install", "--frozen-lockfile", "--prefer-offline"]),
            }
        }
        // Cargo's index and downloaded crates; never target/, never credentials,
        // and never git/db: a bare clone's FETCH_HEAD and config name the remote
        // URL, which for a private repository can carry a token.
        Ecosystem::Cargo => {
            let root = std::env::var_os("CARGO_HOME")
                .filter(|h| !h.is_empty())
                .map(PathBuf::from)
                .or_else(|| home().map(|h| h.join(".cargo")))?;
            Plan {
                root,
                include: vec!["registry/index".into(), "registry/cache".into()],
                replaces: false,
                install: strings(&["cargo", "fetch", "--locked"]),
            }
        }
        Ecosystem::Uv => {
            let (root, name) = split(PathBuf::from(tool(&["uv", "cache", "dir"])?))?;
            Plan {
                root,
                include: vec![name],
                replaces: false,
                install: strings(&["uv", "sync", "--frozen"]),
            }
        }
    })
}

/// The C library this binary was built for: archives with native code are
/// not shared between glibc and musl.
fn libc() -> &'static str {
    if cfg!(target_env = "musl") {
        "musl"
    } else if cfg!(target_env = "gnu") {
        "gnu"
    } else {
        "none"
    }
}

/// `<ecosystem>-<sha256>` over the key version, the ecosystem, the platform,
/// the codec, each tool's version (or "missing") and the lockfile's bytes.
pub fn key(project: &Project, codec: &str) -> std::io::Result<String> {
    let versions: Vec<String> = project
        .ecosystem
        .versions()
        .iter()
        .map(|argv| output(argv, &project.dir).unwrap_or_else(|| "missing".to_owned()))
        .collect();
    let lockfile = std::fs::read(&project.lockfile)?;
    Ok(key_of(project.ecosystem, codec, &versions, &lockfile))
}

pub(crate) fn key_of(
    ecosystem: Ecosystem,
    codec: &str,
    versions: &[String],
    lockfile: &[u8],
) -> String {
    let mut hash = Sha256::new();
    for line in [KEY_VERSION, ecosystem.name(), std::env::consts::OS, std::env::consts::ARCH]
        .into_iter()
        .chain([libc(), codec])
        .chain(versions.iter().map(String::as_str))
    {
        hash.update(line.as_bytes());
        hash.update(b"\n");
    }
    hash.update(Sha256::digest(lockfile));
    let digest: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
    format!("{}-{digest}", ecosystem.name())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offline_after_a_restore() {
        let argv = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            offline_install(Ecosystem::Cargo, &argv(&["cargo", "fetch", "--locked"])),
            Some(argv(&["cargo", "fetch", "--locked", "--offline"]))
        );
        assert_eq!(
            offline_install(
                Ecosystem::Npm,
                &argv(&["npm", "ci", "--prefer-offline", "--no-audit"])
            ),
            Some(argv(&["npm", "ci", "--no-audit", "--offline"]))
        );
        assert_eq!(offline_install(Ecosystem::Bun, &argv(&["bun", "install"])), None);
    }

    #[test]
    fn detects_one_js_manager_and_the_others_beside_it() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["package-lock.json", "bun.lock", "Cargo.lock", "uv.lock"] {
            std::fs::write(dir.path().join(name), b"x").unwrap();
        }
        let found: Vec<_> = detect(dir.path()).iter().map(|p| p.ecosystem).collect();
        assert_eq!(found, [Ecosystem::Bun, Ecosystem::Cargo, Ecosystem::Uv]);
        assert!(detect(&dir.path().join("missing")).is_empty());
    }

    #[test]
    fn key_changes_with_every_input_and_matches_the_platform_pattern() {
        let v = |s: &str| vec![s.to_owned()];
        let base = key_of(Ecosystem::Cargo, "zstd", &v("cargo 1.90"), b"lock");
        let pattern = regex::Regex::new("^cargo-[0-9a-f]{64}$").unwrap();
        assert!(pattern.is_match(&base), "{base}");
        assert_eq!(base, key_of(Ecosystem::Cargo, "zstd", &v("cargo 1.90"), b"lock"));
        for other in [
            key_of(Ecosystem::Cargo, "zstd", &v("cargo 1.91"), b"lock"),
            key_of(Ecosystem::Cargo, "gzip", &v("cargo 1.90"), b"lock"),
            key_of(Ecosystem::Cargo, "zstd", &v("cargo 1.90"), b"lock2"),
        ] {
            assert_ne!(base, other);
        }
        assert!(key_of(Ecosystem::Uv, "zstd", &v("x"), b"lock").starts_with("uv-"));
    }

    #[test]
    fn refuses_a_cache_folder_that_holds_the_home_folder() {
        let plan = |root: &str, rel: &str| Plan {
            root: root.into(),
            include: vec![rel.into()],
            replaces: false,
            install: vec![],
        };
        let home = home().expect("HOME");
        let parent = home.parent().expect("home has a parent");
        let name = home.file_name().expect("home has a name").to_string_lossy().into_owned();
        assert!(too_broad(&plan(&parent.to_string_lossy(), &name)));
        let grand = parent.parent().unwrap_or(Path::new("/"));
        let first =
            parent.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if !first.is_empty() {
            assert!(too_broad(&plan(&grand.to_string_lossy(), &first)));
        }
        assert!(too_broad(&plan(&home.to_string_lossy(), ".ssh")));
        assert!(!too_broad(&plan(&home.join(".cache").to_string_lossy(), "uv")));
        // A shared cache outside every cache folder (a repo's uv cache-dir).
        assert!(too_broad(&plan(&home.to_string_lossy(), ".config")));
        assert!(too_broad(&plan(&home.join(".cache").to_string_lossy(), "../.config")));
    }
}
