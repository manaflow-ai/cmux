//! Developer-only commands that launch local tooling.
//!
//! These commands are deliberately outside the resource grammar. They are
//! explicit, opt-in process launches and never discover or mutate a cmux
//! daemon on their own.

use std::env;
use std::path::PathBuf;
use std::process::Command;

use super::surface::Surface;

const UI_LAYER_REPO_ENV: &str = "CMUX_UI_LAYER_REPO";

/// A checkout launcher the curated `cmux` surface runs for a pair of words.
struct Launcher {
    words: [&'static str; 2],
    script: &'static str,
    /// Only a Debug or DEV cmux runs it.
    dev_only: bool,
}

const LAUNCHERS: [Launcher; 2] = [
    Launcher {
        words: ["dev", "ui-host"],
        script: "Prototypes/UiLayerHost/launch.sh",
        dev_only: true,
    },
    // The view shell: the UI in real windows on the mock host (Prototypes/ViewShell/README.md). It
    // reads nothing of the person's data but their theme, so any build may open it.
    Launcher {
        words: ["preview", "open"],
        script: "Prototypes/ViewShell/launch.sh",
        dev_only: false,
    },
];

/// Handles `cmux dev ui-host` and `cmux preview open` before the normal daemon/resource parser.
///
/// The commands are available only through the curated `cmux` surface. A
/// `cmux-tui` invocation with the same words remains an ordinary usage error.
pub(super) fn run_if_requested(args: &[String], surface: Surface) -> Option<i32> {
    if surface != Surface::Cmux {
        return None;
    }
    LAUNCHERS.iter().find_map(|launcher| {
        requested_rest(args, launcher).map(|rest| run_launcher(launcher, rest))
    })
}

/// The words after the launcher's two words, when `args` start with them.
fn requested_rest<'a>(args: &'a [String], launcher: &Launcher) -> Option<&'a [String]> {
    let (head, rest) = args.split_at_checked(launcher.words.len())?;
    head.iter().map(String::as_str).eq(launcher.words).then_some(rest)
}

#[cfg(test)]
fn is_requested(args: &[String]) -> bool {
    LAUNCHERS.iter().any(|launcher| requested_rest(args, launcher).is_some())
}

fn run_launcher(launcher: &Launcher, args: &[String]) -> i32 {
    let name = launcher.words.join(" ");
    if launcher.dev_only && !is_dev_build() {
        eprintln!(
            "cmux: `{name}` requires a Debug or DEV cmux build; it is unavailable in release builds"
        );
        return 1;
    }
    if env::consts::OS != "macos" {
        eprintln!("cmux: `{name}` runs on a developer Mac; this host is not macOS");
        return 1;
    }

    let repository = match repository_root(launcher.script) {
        Ok(path) => path,
        Err(error) => {
            eprintln!("cmux: `{name}`: {error}");
            return 1;
        }
    };
    let script = repository.join(launcher.script);
    let status =
        Command::new("/bin/bash").arg(&script).args(args).current_dir(&repository).status();
    match status {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            eprintln!("cmux: `{name}` could not start the launcher: {error}");
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

fn repository_root(script: &str) -> Result<PathBuf, String> {
    if let Some(value) = env::var_os(UI_LAYER_REPO_ENV) {
        let path = PathBuf::from(value);
        if !path.is_absolute() {
            return Err(format!("{UI_LAYER_REPO_ENV} must be an absolute checkout path"));
        }
        return validate_repository(path, script);
    }

    let current = env::current_dir()
        .map_err(|error| format!("cannot read the current directory: {error}"))?;
    current
        .ancestors()
        .find_map(|candidate| validate_repository(candidate.to_path_buf(), script).ok())
        .ok_or_else(|| {
            format!("run it from a cmux checkout or set {UI_LAYER_REPO_ENV} to the checkout path")
        })
}

fn validate_repository(path: PathBuf, script: &str) -> Result<PathBuf, String> {
    if path.join(script).is_file() {
        Ok(path)
    } else {
        Err(format!("no {script} under {}", path.display()))
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
        assert!(is_requested(&strings(&["preview", "open", "--size", "1280x800"])));
        assert!(!is_requested(&strings(&["preview"])));
        assert!(!is_requested(&strings(&["open", "preview"])));
        assert!(!is_requested(&strings(&["dev"])));
        assert!(!is_requested(&strings(&["ui-host", "dev"])));
    }
}
