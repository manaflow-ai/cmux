//! Where the customization lives, and where its generations are kept.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Names another folder for generations, drafts and profiles' history (tests).
pub const STATE_OVERRIDE: &str = "CMUX_CUSTOMIZE_STATE_DIR";

/// The folders one customization is made of.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Roots {
    /// The folder of the settings file (`~/.config/cmux`).
    pub config_dir: PathBuf,
    /// The settings file itself (`cmux-next.json`, or `CMUX_NEXT_CONFIG_FILE`).
    pub settings_file: PathBuf,
    /// The person's own views app (`local/customize`).
    pub customize_dir: PathBuf,
    /// Generations, the draft and the lock. Never inside what it snapshots.
    pub state_dir: PathBuf,
}

impl Roots {
    /// The roots this process's environment names; `None` with no home.
    pub fn from_env() -> Option<Roots> {
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
        // (cmux-tui-core `apps::catalog::customize_dir`); a test in cmux-tui
        // holds the two together.
        let customize_dir = env("CMUX_CUSTOMIZE_DIR")
            .map(PathBuf::from)
            .or_else(|| env("XDG_CONFIG_HOME").map(|xdg| PathBuf::from(xdg).join("cmux/customize")))
            .or_else(|| home.as_ref().map(|home| home.join(".config/cmux/customize")))
            .unwrap_or_else(|| config_dir.join("customize"));
        let state_dir = if let Some(dir) = env(STATE_OVERRIDE) {
            PathBuf::from(dir)
        } else if overridden {
            // A launch with its own settings file (a tagged test build) never
            // reads or writes the person's generations.
            config_dir.join(".customize-state")
        } else {
            default_state_dir(&env, home.as_deref()?)
        };
        Some(Roots { config_dir, settings_file, customize_dir, state_dir })
    }

    /// Roots under one folder, for tests and benches: `<root>/config` and
    /// `<root>/state`.
    pub fn under(root: &Path) -> Roots {
        let config_dir = root.join("config");
        Roots {
            settings_file: config_dir.join("cmux-next.json"),
            customize_dir: config_dir.join("customize"),
            state_dir: root.join("state"),
            config_dir,
        }
    }

    /// Saved profiles: `<config dir>/profiles/NAME.json`.
    pub fn profiles_dir(&self) -> PathBuf {
        self.config_dir.join("profiles")
    }
}

#[cfg(target_os = "macos")]
fn default_state_dir(_env: &impl Fn(&str) -> Option<OsString>, home: &Path) -> PathBuf {
    home.join("Library/Application Support/cmux/customize")
}

#[cfg(not(target_os = "macos"))]
fn default_state_dir(env: &impl Fn(&str) -> Option<OsString>, home: &Path) -> PathBuf {
    env("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/state"))
        .join("cmux/customize")
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
        assert_eq!(roots.settings_file, PathBuf::from("/home/pat/.config/cmux/cmux-next.json"));
        assert_eq!(roots.customize_dir, PathBuf::from("/home/pat/.config/cmux/customize"));
        assert!(!roots.state_dir.starts_with(&roots.config_dir));
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
        assert_eq!(roots.customize_dir, PathBuf::from("/x/cmux/customize"));
    }
}
