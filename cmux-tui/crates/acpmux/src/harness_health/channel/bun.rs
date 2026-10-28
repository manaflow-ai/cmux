//! A Bun update keeps both destinations in argv, including across cache reads
//! by older binaries. No shell, generated config file or ambient global target.

use std::path::{Component, Path, PathBuf};

use super::{Install, UpdatePlan, absolute_prefix, package_name};

const GLOBAL: &str = "BUN_INSTALL_GLOBAL_DIR=";
const BIN: &str = "BUN_INSTALL_BIN=";

pub(super) struct Roots {
    pub global: PathBuf,
    pub bin: PathBuf,
    config_dir: Option<PathBuf>,
}

impl Roots {
    pub(super) fn discover(home: &Path) -> Option<Self> {
        // A supplied/fixture home must not inherit another user's login paths.
        let own_home = dirs::home_dir().as_deref() == Some(home);
        let var = |key: &str| {
            own_home
                .then(|| std::env::var(key).ok().or_else(|| crate::login_env::var(key)))
                .flatten()
                .filter(|v| !v.is_empty())
        };
        Self::read(home, var)
    }

    fn read(home: &Path, var: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let selected_config = var("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute());
        let config_dir = selected_config.clone().unwrap_or_else(|| home.to_path_buf());
        let config = match std::fs::File::open(config_dir.join(".bunfig.toml")) {
            Ok(file) => {
                use std::io::Read;
                let mut text = String::new();
                file.take(65537).read_to_string(&mut text).ok()?;
                if text.len() > 65536 {
                    return None;
                }
                text.parse::<toml::Table>().ok()?
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => toml::Table::new(),
            Err(_) => return None,
        };
        let setting = |key: &str| -> Option<Option<String>> {
            let Some(install) = config.get("install") else { return Some(None) };
            let install = install.as_table()?;
            match install.get(key) {
                Some(value) => Some(Some(value.as_str()?.to_owned())),
                None => Some(None),
            }
        };
        let install = var("BUN_INSTALL").map(PathBuf::from).unwrap_or_else(|| home.join(".bun"));
        let global = var("BUN_INSTALL_GLOBAL_DIR")
            .or(setting("globalDir")?)
            .map(PathBuf::from)
            .unwrap_or_else(|| install.join("install/global"));
        let bin = var("BUN_INSTALL_BIN")
            .or(setting("globalBinDir")?)
            .map(PathBuf::from)
            .unwrap_or_else(|| install.join("bin"));
        let resolve = |path: PathBuf| {
            let path = match path.strip_prefix("~/") {
                Ok(rest) => home.join(rest),
                Err(_) => path,
            };
            absolute_prefix(&path).then(|| path.canonicalize().unwrap_or(path))
        };
        let config_dir = match selected_config {
            Some(path) => Some(resolve(path)?),
            None => None,
        };
        Some(Self { global: resolve(global)?, bin: resolve(bin)?, config_dir })
    }
}

fn valid_package(package: &str) -> bool {
    let part = |s: &str| {
        s.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    };
    if package.len() > 214 {
        return false;
    }
    match package.strip_prefix('@') {
        Some(scoped) => scoped.split_once('/').is_some_and(|(a, b)| part(a) && part(b)),
        None => part(package),
    }
}

pub(super) fn detect(path: &Path, home: &Path) -> Option<Install> {
    let roots = Roots::discover(home)?;
    let modules = roots.global.join("node_modules");
    let package = package_name(path.strip_prefix(modules).ok()?.to_str()?)?;
    valid_package(&package).then_some(Install {
        channel: super::Channel::Bun,
        package: Some(package),
        writes: Some(roots.global),
    })
}

pub(super) fn argv(
    install: &Install,
    path: &Path,
    real: &Path,
    home: &Path,
) -> Option<Vec<String>> {
    if !cfg!(unix) {
        return None;
    }
    let roots = Roots::discover(home)?;
    let package = install.package.as_deref().filter(|p| valid_package(p))?;
    if install.writes.as_deref()? != roots.global.as_path()
        || path.parent()?.canonicalize().ok()? != roots.bin
        || path.canonicalize().ok()? != real
        || !real.starts_with(roots.global.join("node_modules").join(package))
    {
        return None;
    }
    let mut argv = vec!["/usr/bin/env".into()];
    if roots.config_dir.is_none() {
        argv.extend(["-u".into(), "XDG_CONFIG_HOME".into()]);
    }
    argv.extend([
        format!("{GLOBAL}{}", roots.global.to_str()?),
        format!("{BIN}{}", roots.bin.to_str()?),
    ]);
    if let Some(config) = roots.config_dir {
        argv.push(format!("XDG_CONFIG_HOME={}", config.to_str()?));
    }
    argv.extend(["bun".into(), "add".into(), "-g".into(), format!("{package}@latest")]);
    Some(argv)
}

struct Parts<'a> {
    bin: &'a Path,
    manager: &'a str,
    manager_index: usize,
    package: &'a str,
}

fn parts(argv: &[String]) -> Option<Parts<'_>> {
    let (env, global, bin, manager, add, flag, package, index) = match argv {
        [env, unset, key, global, bin, manager, add, flag, package]
            if unset == "-u" && key == "XDG_CONFIG_HOME" =>
        {
            (env, global, bin, manager, add, flag, package, 5)
        }
        [env, global, bin, config, manager, add, flag, package]
            if config
                .strip_prefix("XDG_CONFIG_HOME=")
                .is_some_and(|p| absolute_prefix(Path::new(p))) =>
        {
            (env, global, bin, manager, add, flag, package, 4)
        }
        _ => return None,
    };
    let global = Path::new(global.strip_prefix(GLOBAL)?);
    let bin = Path::new(bin.strip_prefix(BIN)?);
    (env == "/usr/bin/env"
        && add == "add"
        && flag == "-g"
        && manager_valid(manager)
        && absolute_prefix(global)
        && absolute_prefix(bin)
        && !argv.iter().any(|s| s.contains('\0'))
        && argv.iter().map(String::len).sum::<usize>() <= 16 * 1024)
        .then_some(Parts { bin, manager, manager_index: index, package })
}

/// Validate a cached plan without filesystem, config, version or auth reads.
pub(in crate::harness_health) fn matches(
    plan: &UpdatePlan,
    package: Option<&str>,
    path: Option<&str>,
) -> bool {
    let Some(parts) = parts(&plan.argv) else { return false };
    package.is_some_and(|p| valid_package(p) && parts.package == format!("{p}@latest"))
        && path.map(Path::new).is_some_and(|p| absolute_prefix(p) && p.parent() == Some(parts.bin))
}

fn manager_valid(manager: &str) -> bool {
    manager == "bun"
        || (absolute_prefix(Path::new(manager))
            && Path::new(manager).file_name().is_some_and(|name| name == "bun"))
}

pub(in crate::harness_health) fn pin_manager(
    argv: &[String],
    lookup: impl FnOnce(&str) -> Option<String>,
) -> Option<Vec<String>> {
    let parts = parts(argv)?;
    let manager = if parts.manager == "bun" { lookup("bun")? } else { parts.manager.to_owned() };
    if !Path::new(&manager).is_absolute()
        || !manager_valid(&manager)
        || !executable(Path::new(&manager))
    {
        return None;
    }
    let mut pinned = argv.to_vec();
    *pinned.get_mut(parts.manager_index)? = manager;
    Some(pinned)
}

fn executable(path: &Path) -> bool {
    let Ok(meta) = path.metadata() else { return false };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        false
    }
}

pub(in crate::harness_health) fn recorded_path(plan: &UpdatePlan, path: &Path) -> Option<PathBuf> {
    let result = parts(&plan.argv)?.bin.join(path.file_name()?);
    (!result.components().any(|c| matches!(c, Component::ParentDir))).then_some(result)
}

pub(super) fn bin_dir(argv: &[String]) -> Option<&Path> {
    Some(parts(argv)?.bin)
}

#[cfg(test)]
#[path = "bun_tests.rs"]
mod tests;
