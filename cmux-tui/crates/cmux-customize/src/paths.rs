//! Where the customization lives, and where its generations are kept.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Names another folder for generations, drafts and profiles' history (tests).
pub const STATE_OVERRIDE: &str = "CMUX_CUSTOMIZE_STATE_DIR";

/// The folders one customization is made of.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Roots {
    /// The folder of the settings file (`~/.config/cmux`, `~/.config/cmux-next` on macOS).
    pub config_dir: PathBuf,
    /// The settings file itself (`cmux-next.json`, or `CMUX_NEXT_CONFIG_FILE`).
    pub settings_file: PathBuf,
    /// The person's own views app (`local/customize`).
    pub customize_dir: PathBuf,
    /// The automations store the runner reads (cmux-automations `Store::default_root`).
    pub automations_dir: PathBuf,
    /// Generations, the draft and the lock. Never inside what it snapshots.
    pub state_dir: PathBuf,
}

impl Roots {
    /// The roots this process's environment names; `None` with no home.
    /// An old install's state moves to NEXT's folder first (macOS).
    pub fn from_env() -> Option<Roots> {
        if std::env::var_os(STATE_OVERRIDE).is_none() {
            cmux_config::location::migrate_legacy_state_once();
        }
        Roots::from(|name| std::env::var_os(name).filter(|value| !value.is_empty()))
    }

    /// [`Roots::from_env`] with an injected environment.
    pub fn from(env: impl Fn(&str) -> Option<OsString>) -> Option<Roots> {
        let home = env("HOME").map(PathBuf::from);
        let overridden = env(cmux_config::CONFIG_OVERRIDE).is_some();
        if home.is_none() && !overridden {
            return None;
        }
        let settings_file = cmux_config::location::config_path_from(&env);
        let config_dir = settings_file.parent().map(Path::to_path_buf)?;
        // The same order the daemon reads its customize folder in
        // (cmux-tui-core `apps::catalog::customize_dir`); the test below
        // holds this side of it.
        let shared = home.as_ref().map(|home| home.join(".config").join(cmux_config::NEXT_DIR));
        let customize_dir = env("CMUX_CUSTOMIZE_DIR")
            .map(PathBuf::from)
            .or_else(|| {
                env("XDG_CONFIG_HOME")
                    .map(|xdg| PathBuf::from(xdg).join(cmux_config::NEXT_DIR).join("customize"))
            })
            .or_else(|| shared.as_ref().map(|dir| dir.join("customize")))
            .unwrap_or_else(|| config_dir.join("customize"));
        // The runner's order (cmux-automations `Store::default_root`): a
        // preview, a generation and a rollback cover the folder it reads.
        let automations_dir = env("CMUX_AUTOMATIONS_DIR")
            .filter(|dir| !dir.is_empty())
            .map(PathBuf::from)
            .or_else(|| shared.as_ref().map(|dir| dir.join("automations")))
            .unwrap_or_else(|| config_dir.join("automations"));
        let state_dir = if let Some(dir) = env(STATE_OVERRIDE) {
            PathBuf::from(dir)
        } else if overridden {
            // A launch with its own settings file (a tagged test build) never
            // reads or writes the person's generations.
            config_dir.join(".customize-state")
        } else {
            default_state_dir(&env, home.as_deref()?)
        };
        Some(Roots { config_dir, settings_file, customize_dir, automations_dir, state_dir })
    }

    /// Roots under one folder, for tests and benches: `<root>/config` and
    /// `<root>/state`.
    pub fn under(root: &Path) -> Roots {
        let config_dir = root.join("config");
        Roots {
            settings_file: config_dir.join("cmux-next.json"),
            customize_dir: config_dir.join("customize"),
            automations_dir: config_dir.join("automations"),
            state_dir: root.join("state"),
            config_dir,
        }
    }

    /// Installed setups' own views layers (`setup::layers`): `setups/` next
    /// to the customize folder (`~/.config/cmux/setups`; `cmux-next` on macOS), so a setup never
    /// writes into the person's own views. The daemon reads the same folder
    /// (cmux-tui-core `apps::catalog::setups_dir`).
    pub fn setups_dir(&self) -> PathBuf {
        self.customize_dir.with_file_name("setups")
    }

    /// Saved profiles: `<config dir>/profiles/NAME.json`.
    pub fn profiles_dir(&self) -> PathBuf {
        self.config_dir.join("profiles")
    }
}

/// One place on every system, outside the config folder (whose watcher
/// would otherwise see every generation written) and outside the app's own
/// per-build state: generations describe the person's config folder, which
/// every build of cmux shares. A build with its own settings file keeps its
/// own (see `from`).
fn default_state_dir(env: &impl Fn(&str) -> Option<OsString>, home: &Path) -> PathBuf {
    env("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/state"))
        .join(cmux_config::NEXT_DIR)
        .join("customize")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
        move |name| {
            pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| OsString::from(value))
        }
    }

    #[test]
    fn the_default_roots_sit_under_home() {
        let roots = Roots::from(env(&[("HOME", "/home/pat")])).unwrap();
        // `cmux-next` on macOS (cmux Classic owns `cmux` there), `cmux` elsewhere.
        let dir = cmux_config::NEXT_DIR;
        let under = |path: &str| PathBuf::from(path.replace("{dir}", dir));
        assert_eq!(roots.settings_file, under("/home/pat/.config/{dir}/cmux-next.json"));
        assert_eq!(roots.customize_dir, under("/home/pat/.config/{dir}/customize"));
        assert_eq!(roots.state_dir, under("/home/pat/.local/state/{dir}/customize"));
    }

    #[test]
    fn a_launch_with_its_own_settings_file_keeps_its_own_generations() {
        let roots = Roots::from(env(&[
            ("HOME", "/home/pat"),
            ("CMUX_NEXT_CONFIG_FILE", "/tmp/tagged/cmux-next.json"),
        ]))
        .unwrap();
        assert_eq!(roots.state_dir, PathBuf::from("/tmp/tagged/.customize-state"));
    }

    #[test]
    fn the_customize_folder_follows_the_daemons_order() {
        let roots = Roots::from(env(&[
            ("HOME", "/home/pat"),
            ("XDG_CONFIG_HOME", "/x"),
            ("CMUX_CUSTOMIZE_DIR", "/mine"),
        ]))
        .unwrap();
        assert_eq!(roots.customize_dir, PathBuf::from("/mine"));
        let roots = Roots::from(env(&[("HOME", "/home/pat"), ("XDG_CONFIG_HOME", "/x")])).unwrap();
        assert_eq!(
            roots.customize_dir,
            PathBuf::from("/x").join(cmux_config::NEXT_DIR).join("customize")
        );
    }

    #[test]
    fn the_automations_folder_is_the_runners() {
        let roots = Roots::from(env(&[
            ("HOME", "/home/pat"),
            ("CMUX_NEXT_CONFIG_FILE", "/tmp/tagged/cmux-next.json"),
        ]))
        .unwrap();
        // Not the tagged settings file's folder: the runner's own default,
        // next to the customize folder under HOME.
        assert_eq!(roots.automations_dir, roots.customize_dir.with_file_name("automations"));
        assert!(roots.automations_dir.starts_with("/home/pat"));
        let roots = Roots::from(env(&[
            ("HOME", "/home/pat"),
            ("CMUX_NEXT_CONFIG_FILE", "/tmp/tagged/cmux-next.json"),
            ("CMUX_AUTOMATIONS_DIR", "/tmp/tagged/automations"),
        ]))
        .unwrap();
        assert_eq!(roots.automations_dir, PathBuf::from("/tmp/tagged/automations"));
    }
}
