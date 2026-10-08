//! Keeps the app's bundled `cmux` first on `PATH` after the user's startup
//! files, in a shell the daemon integrates.
//!
//! The cmux-next app starts its daemon with `CMUX_BUNDLED_CLI_PATH`
//! (`<Resources>/bin/cmux`) and that bin dir first on `PATH`. A terminal the
//! daemon starts without a caller env (`cmux tab create terminal`, `cmux
//! workspace create` from a shell) inherits both, but the user's startup
//! files run later and often prepend a directory with another `cmux`
//! (`~/.local/bin`). The app ships layers in `<Resources>/cmux-cli-path` that
//! move the bundled bin dir back to the front before the first prompt and
//! remove their own variables; the app wraps its own spawns with them
//! (`BundledCLIEnvironment.swift`). This wraps the daemon's Ghostty injection
//! with the same layers, so both spawn paths give the same `cmux`. Without a
//! bundled CLI, or without the layer file next to it, nothing changes.

use std::path::Path;

use super::Shell;
use crate::daemon_env::set_env;

/// The app's bundled CLI, `<Resources>/bin/cmux`.
const BUNDLED_CLI_ENV: &str = "CMUX_BUNDLED_CLI_PATH";
/// zsh: the `ZDOTDIR` (Ghostty's) that the layer's `.zshenv` restores.
pub(crate) const ZSH_NEXT_ZDOTDIR_ENV: &str = "CMUX_CLI_ZSH_ZDOTDIR";
/// bash: Ghostty's `ENV` script, which the layer sources.
pub(crate) const BASH_NEXT_ENV_ENV: &str = "CMUX_CLI_BASH_ENV";
/// fish: the `XDG_DATA_DIRS` entry the layer removes again.
pub(crate) const FISH_DATA_DIR_ENV: &str = "CMUX_CLI_FISH_XDG_DIR";

const ZSH_LAYER: &str = "zsh/.zshenv";
const BASH_LAYER: &str = "bash/cmux-cli-path.bash";
const FISH_LAYER: &str = "fish/vendor_conf.d/cmux-cli-path.fish";

/// `<Resources>/cmux-cli-path` beside the bundled CLI in `lookup`, when it
/// holds `file`.
fn layer_dir(lookup: &dyn Fn(&str) -> Option<String>, file: &str) -> Option<String> {
    let cli = lookup(BUNDLED_CLI_ENV).filter(|cli| !cli.is_empty())?;
    let layer = Path::new(&cli).parent()?.parent()?.join("cmux-cli-path");
    layer.join(file).is_file().then(|| layer.to_string_lossy().into_owned())
}

fn last(env: &[(String, String)], key: &str) -> Option<String> {
    env.iter().rev().find(|(name, _)| name == key).map(|(_, value)| value.clone())
}

/// Wraps the Ghostty injection that `env` already carries for `shell` with
/// the app's layer, as `BundledCLIEnvironment.apply` does for the app's own
/// spawns.
pub(super) fn wrap(
    shell: Shell,
    env: &mut Vec<(String, String)>,
    lookup: &dyn Fn(&str) -> Option<String>,
) {
    match shell {
        Shell::Zsh => {
            let (Some(layer), Some(next)) = (layer_dir(lookup, ZSH_LAYER), last(env, "ZDOTDIR"))
            else {
                return;
            };
            set_env(env, ZSH_NEXT_ZDOTDIR_ENV, &next);
            set_env(env, "ZDOTDIR", &format!("{layer}/zsh"));
        }
        Shell::Bash => {
            // Only over Ghostty's script: bash reads `ENV` only in the POSIX
            // mode that the injection starts it in.
            let Some(next) =
                last(env, "ENV").filter(|script| script.ends_with("/bash/ghostty.bash"))
            else {
                return;
            };
            let Some(layer) = layer_dir(lookup, BASH_LAYER) else { return };
            set_env(env, BASH_NEXT_ENV_ENV, &next);
            set_env(env, "ENV", &format!("{layer}/{BASH_LAYER}"));
        }
        Shell::Fish => {
            let Some(layer) = layer_dir(lookup, FISH_LAYER) else { return };
            let current = last(env, "XDG_DATA_DIRS")
                .filter(|dirs| !dirs.is_empty())
                .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
            set_env(env, FISH_DATA_DIR_ENV, &layer);
            set_env(env, "XDG_DATA_DIRS", &format!("{layer}:{current}"));
        }
    }
}
