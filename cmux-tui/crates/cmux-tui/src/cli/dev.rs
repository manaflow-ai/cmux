//! Developer-only commands that launch local tooling.
//!
//! These commands are deliberately outside the resource grammar. They are
//! explicit, opt-in process launches and never discover or mutate a cmux
//! daemon on their own.

use std::env;
use std::path::PathBuf;
use std::process::Command;

use super::surface::Surface;

const UI_LAYER_WORDS: [&str; 2] = ["dev", "ui-host"];
const UI_LAYER_REPO_ENV: &str = "CMUX_UI_LAYER_REPO";
const UI_LAYER_LAUNCHER: &str = "Prototypes/UiLayerHost/launch.sh";

/// Handles `cmux dev ui-host` before the normal daemon/resource parser.
///
/// The command is available only through the curated `cmux` surface. A
/// `cmux-tui` invocation with the same words remains an ordinary usage error.
pub(super) fn run_if_requested(args: &[String], surface: Surface) -> Option<i32> {
    if surface != Surface::Cmux || !is_requested(args) {
        return None;
    }
    Some(run_ui_layer(&args[UI_LAYER_WORDS.len()..]))
}

fn is_requested(args: &[String]) -> bool {
    args.len() >= UI_LAYER_WORDS.len()
        && args[..UI_LAYER_WORDS.len()].iter().map(String::as_str).eq(UI_LAYER_WORDS)
}

fn run_ui_layer(args: &[String]) -> i32 {
    if !is_dev_build() {
        eprintln!(
            "cmux: `dev ui-host` requires a Debug or DEV cmux build; it is unavailable in release builds"
        );
        return 1;
    }
    if env::consts::OS != "macos" {
        eprintln!("cmux: `dev ui-host` runs on a developer Mac; this host is not macOS");
        return 1;
    }

    let repository = match repository_root() {
        Ok(path) => path,
        Err(error) => {
            eprintln!("cmux: `dev ui-host`: {error}");
            return 1;
        }
    };
    let launcher = repository.join(UI_LAYER_LAUNCHER);
    if !launcher.is_file() {
        eprintln!(
            "cmux: `dev ui-host` launcher is missing: {}\n  set {UI_LAYER_REPO_ENV} to a cmux checkout containing {UI_LAYER_LAUNCHER}",
            launcher.display()
        );
        return 1;
    }

    let status =
        Command::new("/bin/bash").arg(&launcher).args(args).current_dir(&repository).status();
    match status {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            eprintln!("cmux: `dev ui-host` could not start the launcher: {error}");
            1
        }
    }
}

fn is_dev_build() -> bool {
    if cfg!(debug_assertions) {
        return true;
    }
    let executable = env::current_exe().ok();
    crate::app_identity::AppIdentity::detect(|key| env::var(key).ok(), executable.as_deref())
        .and_then(|identity| identity.bundle_id)
        .is_some_and(|bundle| crate::app_identity::is_debug_bundle(&bundle))
}

fn repository_root() -> Result<PathBuf, String> {
    if let Some(value) = env::var_os(UI_LAYER_REPO_ENV) {
        let path = PathBuf::from(value);
        if !path.is_absolute() {
            return Err(format!("{UI_LAYER_REPO_ENV} must be an absolute checkout path"));
        }
        return validate_repository(path);
    }

    let current = env::current_dir()
        .map_err(|error| format!("cannot read the current directory: {error}"))?;
    current
        .ancestors()
        .find_map(|candidate| validate_repository(candidate.to_path_buf()).ok())
        .ok_or_else(|| {
            format!("run it from a cmux checkout or set {UI_LAYER_REPO_ENV} to the checkout path")
        })
}

fn validate_repository(path: PathBuf) -> Result<PathBuf, String> {
    let launcher = path.join(UI_LAYER_LAUNCHER);
    if launcher.is_file() {
        Ok(path)
    } else {
        Err(format!("no {UI_LAYER_LAUNCHER} under {}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn only_curated_surface_handles_ui_layer_command() {
        let args = strings(&["dev", "ui-host"]);
        assert!(is_requested(&args));
        assert!(run_if_requested(&args, Surface::CmuxTui).is_none());
    }

    #[test]
    fn forwards_launcher_arguments() {
        assert!(is_requested(&strings(&["dev", "ui-host", "--watch"])));
        assert!(!is_requested(&strings(&["dev"])));
        assert!(!is_requested(&strings(&["ui-host", "dev"])));
    }
}
