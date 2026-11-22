//! Ghostty's shell integration for a terminal the app asks the daemon to
//! spawn, built the way Ghostty builds it for its own shells
//! (`ghostty/src/termio/Exec.zig`, `shell_integration.zig`), and the bundled
//! `cmux` layer over it ([`BundledCli`]).
//!
//! The daemon has its own integration for a terminal it starts with no
//! caller env (cmux-tui-core `shell_integration`, its scripts materialized in
//! its state root). This one is the app's: it points at the app bundle's
//! Ghostty resources, covers elvish and nushell, and hands bash and nushell
//! their arguments through `shell_args` (`terminal-shell-args-v1`).

use crate::fs::Fs;
use crate::{Env, last_component, parent_path};
use serde::Deserialize;

/// Ghostty's bash integration script, relative to `shell-integration`.
pub const GHOSTTY_BASH_SCRIPT: &str = "/bash/ghostty.bash";
/// The XDG base-directory default when `XDG_DATA_DIRS` is unset.
pub const DEFAULT_XDG_DATA_DIRS: &str = "/usr/local/share:/usr/share";

/// `shell-integration-features` bits, in Ghostty's packed-struct order.
pub const CURSOR: u32 = 1 << 0;
pub const SUDO: u32 = 1 << 1;
pub const TITLE: u32 = 1 << 2;
pub const SSH_ENV: u32 = 1 << 3;
pub const SSH_TERMINFO: u32 = 1 << 4;
pub const PATH: u32 = 1 << 5;
/// Ghostty's defaults: cursor, title, path.
pub const DEFAULT_FEATURES: u32 = CURSOR | TITLE | PATH;

/// `shell-integration`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    None,
    #[default]
    Detect,
    Bash,
    Elvish,
    Fish,
    Nushell,
    Zsh,
}

/// The user's integration settings and the bundle's Ghostty paths.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Integration {
    #[serde(default)]
    pub mode: Mode,
    #[serde(default = "default_features")]
    pub features: u32,
    /// `cursor-style-blink`; none counts as blinking.
    #[serde(default)]
    pub cursor_blink: Option<bool>,
    /// `<Resources>/ghostty`.
    #[serde(default)]
    pub resources_directory: Option<String>,
    /// `<Resources>/bin/ghostty`; without it the ssh features are dropped.
    #[serde(default)]
    pub ghostty_binary: Option<String>,
}

fn default_features() -> u32 {
    DEFAULT_FEATURES
}

fn non_empty(value: Option<&String>) -> Option<&str> {
    value.map(String::as_str).filter(|v| !v.is_empty())
}

impl Integration {
    /// `GHOSTTY_SHELL_FEATURES`: enabled names sorted, `cursor` with its blink
    /// state; none when none is enabled.
    pub fn features_value(&self) -> Option<String> {
        let mut features = self.features;
        if non_empty(self.ghostty_binary.as_ref()).is_none() {
            features &= !(SSH_ENV | SSH_TERMINFO);
        }
        let mut names = Vec::new();
        if features & CURSOR != 0 {
            names.push(if self.cursor_blink.unwrap_or(true) {
                "cursor:blink"
            } else {
                "cursor:steady"
            });
        }
        for (bit, name) in [
            (PATH, "path"),
            (SSH_ENV, "ssh-env"),
            (SSH_TERMINFO, "ssh-terminfo"),
            (SUDO, "sudo"),
            (TITLE, "title"),
        ] {
            if features & bit != 0 {
                names.push(name);
            }
        }
        (!names.is_empty()).then(|| names.join(","))
    }

    /// The shell Ghostty would integrate for `shell` (a path or name): a
    /// forced mode wins, `none` never integrates, and Apple's `/bin/bash` is
    /// never detected.
    pub fn shell_for(&self, shell: Option<&str>) -> Option<Mode> {
        match self.mode {
            Mode::None => return None,
            Mode::Detect => {}
            forced => return Some(forced),
        }
        let shell = shell.filter(|s| !s.is_empty())?;
        match last_component(shell) {
            "bash" => (shell != "/bin/bash").then_some(Mode::Bash),
            "elvish" => Some(Mode::Elvish),
            "fish" => Some(Mode::Fish),
            "nu" => Some(Mode::Nushell),
            "zsh" => Some(Mode::Zsh),
            _ => None,
        }
    }

    /// `env` plus the integration for a terminal running `shell` (none: the
    /// env's `SHELL`). `home` is the fallback for `HISTFILE` when the env has
    /// no `HOME`.
    pub fn apply(&self, env: &Env, shell: Option<&str>, home: &str, fs: &Fs) -> Env {
        let mut env = env.clone();
        if let Some(binary) = non_empty(self.ghostty_binary.as_ref()) {
            let bin_dir = parent_path(binary);
            env.insert("GHOSTTY_BIN".into(), binary.into());
            env.insert("GHOSTTY_BIN_DIR".into(), bin_dir.clone());
            let path = env.get("PATH").cloned().unwrap_or_default();
            if path.is_empty() {
                env.insert("PATH".into(), bin_dir);
            } else if !path.split(':').any(|p| p == bin_dir) {
                env.insert("PATH".into(), format!("{path}:{bin_dir}"));
            }
        }
        let resources = non_empty(self.resources_directory.as_ref());
        if let Some(resources) = resources {
            let current =
                env.get("XDG_DATA_DIRS").cloned().unwrap_or_else(|| DEFAULT_XDG_DATA_DIRS.into());
            let value = format!("{resources}/..");
            env.insert(
                "XDG_DATA_DIRS".into(),
                if current.is_empty() { value } else { format!("{current}:{value}") },
            );
            // Always a leading colon: an empty MANPATH element keeps the system man path.
            let manpath = env.get("MANPATH").cloned().unwrap_or_default();
            env.insert("MANPATH".into(), format!("{manpath}:{resources}/../man"));
        }
        if let Some(features) = self.features_value() {
            env.insert("GHOSTTY_SHELL_FEATURES".into(), features);
        }
        let Some(resources) = resources else { return env };
        let env_shell = env.get("SHELL").cloned();
        let Some(integrated) = self.shell_for(shell.or(env_shell.as_deref())) else { return env };
        let integration = format!("{resources}/shell-integration");
        match integrated {
            Mode::Zsh => {
                let zsh = format!("{integration}/zsh");
                if fs.is_dir(&zsh) {
                    if let Some(old) = env.get("ZDOTDIR").cloned() {
                        env.insert("GHOSTTY_ZSH_ZDOTDIR".into(), old);
                    }
                    env.insert("ZDOTDIR".into(), zsh);
                }
            }
            Mode::Fish | Mode::Elvish | Mode::Nushell => {
                if fs.is_dir(&integration) {
                    let current = env
                        .get("XDG_DATA_DIRS")
                        .cloned()
                        .unwrap_or_else(|| DEFAULT_XDG_DATA_DIRS.into());
                    env.insert("GHOSTTY_SHELL_INTEGRATION_XDG_DIR".into(), integration.clone());
                    env.insert("XDG_DATA_DIRS".into(), format!("{integration}:{current}"));
                }
            }
            Mode::Bash => {
                // `setupBash`: POSIX mode reads the integration from `ENV`.
                if fs.is_dir(&format!("{integration}/bash")) {
                    if let Some(old) = env.get("ENV").cloned() {
                        env.insert("GHOSTTY_BASH_ENV".into(), old);
                    }
                    env.insert("ENV".into(), format!("{integration}{GHOSTTY_BASH_SCRIPT}"));
                    env.insert("GHOSTTY_BASH_INJECT".into(), "1".into());
                    // POSIX mode defaults HISTFILE to ~/.sh_history.
                    if !env.contains_key("HISTFILE") {
                        let home = non_empty(env.get("HOME")).unwrap_or(home).to_string();
                        env.insert("HISTFILE".into(), format!("{home}/.bash_history"));
                        env.insert("GHOSTTY_BASH_UNEXPORT_HISTFILE".into(), "1".into());
                    }
                }
            }
            Mode::None | Mode::Detect => {}
        }
        env
    }
}

/// The arguments Ghostty adds for the integration [`Integration::apply`]
/// wrote into `env`, for the env's `SHELL`: bash `--posix`, nushell
/// `--execute 'use ghostty *'`; none for every other shell or without it.
pub fn shell_arguments(env: &Env) -> Option<Vec<String>> {
    let shell = non_empty(env.get("SHELL"))?;
    match last_component(shell) {
        "bash" => {
            let injected = shell != "/bin/bash"
                && env.contains_key("GHOSTTY_BASH_INJECT")
                && (env.get("ENV").is_some_and(|e| e.ends_with(GHOSTTY_BASH_SCRIPT))
                    || BundledCli::wraps_ghostty_bash(env));
            injected.then(|| vec!["--posix".into()])
        }
        "nu" => env
            .contains_key("GHOSTTY_SHELL_INTEGRATION_XDG_DIR")
            .then(|| vec!["--execute".into(), "use ghostty *".into()]),
        _ => None,
    }
}

/// zsh: the `ZDOTDIR` the layer's `.zshenv` restores.
pub const ZSH_NEXT_ZDOTDIR_KEY: &str = "CMUX_CLI_ZSH_ZDOTDIR";
/// bash: Ghostty's `ENV` script, which the layer sources.
pub const BASH_NEXT_ENV_KEY: &str = "CMUX_CLI_BASH_ENV";
/// fish: the `XDG_DATA_DIRS` entry the layer removes again.
pub const FISH_DATA_DIR_KEY: &str = "CMUX_CLI_FISH_XDG_DIR";
const CLI_BASH_SCRIPT: &str = "/bash/cmux-cli-path.bash";
/// The bundled URL opener `BROWSER` names.
pub const URL_OPENER_NAME: &str = "cmux-open-url";

/// Makes `cmux` in the app's terminals the app's bundled CLI: its bin
/// directory first on `PATH`, `CMUX_BUNDLED_CLI_PATH`, `BROWSER` naming the
/// bundled opener unless set, and the layer (`<Resources>/cmux-cli-path`)
/// that moves the bin directory back to the front after the user's startup
/// files, for zsh, bash (over Ghostty's POSIX-mode `ENV`) and fish.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundledCli {
    /// `Contents/Resources/bin`.
    pub bin_directory: String,
    /// `Contents/Resources/cmux-cli-path`; none when the daemon integrates.
    #[serde(default)]
    pub path_integration: Option<String>,
}

impl BundledCli {
    /// Whether `env`'s `ENV` is the bash layer over Ghostty's script.
    pub fn wraps_ghostty_bash(env: &Env) -> bool {
        env.get("ENV").is_some_and(|e| e.ends_with(CLI_BASH_SCRIPT))
            && env.get(BASH_NEXT_ENV_KEY).is_some_and(|e| e.ends_with(GHOSTTY_BASH_SCRIPT))
    }

    /// `env` with the bundled CLI applied; unchanged when the bundle has no
    /// executable `cmux`.
    pub fn apply(&self, env: &Env, fs: &Fs) -> Env {
        let bin = self.bin_directory.as_str();
        let cli = format!("{bin}/cmux");
        if bin.is_empty() || !fs.is_executable(&cli) {
            return env.clone();
        }
        let mut env = env.clone();
        let path = env.get("PATH").cloned().unwrap_or_default();
        let rest = path.split(':').filter(|p| !p.is_empty() && *p != bin);
        env.insert("PATH".into(), std::iter::once(bin).chain(rest).collect::<Vec<_>>().join(":"));
        env.insert("CMUX_BUNDLED_CLI_PATH".into(), cli);
        // A `BROWSER` already set is the user's and wins. The bare name: gh
        // splits `BROWSER` on spaces, and an app path can hold one.
        if non_empty(env.get("BROWSER")).is_none()
            && fs.is_executable(&format!("{bin}/{URL_OPENER_NAME}"))
        {
            env.insert("BROWSER".into(), URL_OPENER_NAME.into());
        }
        let Some(layer) = non_empty(self.path_integration.as_ref()) else { return env };
        let Some(shell) = env.get("SHELL").map(|s| last_component(s).to_string()) else {
            return env;
        };
        match shell.as_str() {
            "zsh" if fs.exists(&format!("{layer}/zsh/.zshenv")) => {
                if let Some(next) = env.get("ZDOTDIR").cloned() {
                    env.insert(ZSH_NEXT_ZDOTDIR_KEY.into(), next);
                }
                env.insert("ZDOTDIR".into(), format!("{layer}/zsh"));
            }
            // Only over Ghostty's integration: bash reads `ENV` only in its POSIX mode.
            "bash" => {
                let next = env.get("ENV").filter(|e| e.ends_with(GHOSTTY_BASH_SCRIPT)).cloned();
                if let Some(next) = next
                    && env.contains_key("GHOSTTY_BASH_INJECT")
                    && fs.exists(&format!("{layer}{CLI_BASH_SCRIPT}"))
                {
                    env.insert(BASH_NEXT_ENV_KEY.into(), next);
                    env.insert("ENV".into(), format!("{layer}{CLI_BASH_SCRIPT}"));
                }
            }
            "fish" if fs.exists(&format!("{layer}/fish/vendor_conf.d/cmux-cli-path.fish")) => {
                let current = env
                    .get("XDG_DATA_DIRS")
                    .cloned()
                    .unwrap_or_else(|| DEFAULT_XDG_DATA_DIRS.into());
                env.insert(FISH_DATA_DIR_KEY.into(), layer.into());
                env.insert("XDG_DATA_DIRS".into(), format!("{layer}:{current}"));
            }
            _ => {}
        }
        env
    }
}
