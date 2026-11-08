//! The agent helpers a daemon's panes run, all of this daemon's own build:
//! the `claude` and `codex` shims first on the pane PATH, the agent hook
//! helper in `CMUX_TUI_HOOK`, and this build's `cmux` in `CMUX_TUI_CLI`
//! (the `cmux` on PATH can be another install, W5-Q).
//!
//! Every install on a machine (the npm package, the app bundle, a tagged dev
//! build) shares the user's data home. When all of them wrote one
//! `cmux-tui/shims/claude` and read one `cmux-tui/bin/cmux-tui-hook`, the
//! build that wrote last ran in every other build's panes, and an older
//! helper reported to a newer daemon. So each build keeps its shims and its
//! hook launcher in a folder of its own, `cmux-tui/builds/<key>`, the key a
//! hash of the build's resolved executable path; two daemons of one build
//! share it, two builds never do. The shared paths are only read, as the
//! ones to stay away from.

use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest as _, Sha256};

use crate::agent_hook_install;

/// File name of the standalone hook helper an install ships beside its CLI.
const HOOK_HELPER: &str = "cmux-tui-hook";

/// The pane variable that names this build's `cmux` by absolute path.
pub(crate) const CLI_ENV: &str = "CMUX_TUI_CLI";

/// The program name that selects the `cmux` CLI surface (cli/surface.rs).
const CLI_NAME: &str = "cmux";

/// This build's folder under cmux-tui's data home.
fn build_dir(executable: &Path) -> Option<PathBuf> {
    let digest = Sha256::digest(executable.as_os_str().as_encoded_bytes());
    let key: String = digest.iter().take(8).map(|byte| format!("{byte:02x}")).collect();
    Some(agent_hook_install::runtime_cmux_tui_data_home()?.join("builds").join(key))
}

/// The folder of this build's `claude` and `codex` shims.
fn shim_dir(executable: &Path) -> Option<PathBuf> {
    Some(build_dir(executable)?.join("shims"))
}

/// The shim folder a wrapper leaves out of the agent's PATH: the one its
/// daemon put first on the pane PATH (`CMUX_TUI_AGENT_SHIMS`), else this
/// build's. Shims of other builds are found by their marker.
pub(crate) fn wrapper_shim_dir(executable: &Path) -> Option<PathBuf> {
    std::env::var_os(cmux_tui_core::AGENT_SHIMS_ENV)
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .or_else(|| shim_dir(executable))
}

/// This build's hook helper: the standalone `cmux-tui-hook` beside the
/// executable, else a launcher in the build folder that runs the
/// executable's own hook mode (written when missing or stale).
fn hook_helper(executable: &Path) -> Option<PathBuf> {
    let sibling = executable.parent()?.join(HOOK_HELPER);
    if agent_hook_install::is_executable_file(&sibling) {
        return Some(sibling);
    }
    let launcher = build_dir(executable)?.join("bin").join(HOOK_HELPER);
    let script = format!(
        "#!/bin/sh\nexec {} {} \"$@\"\n",
        agent_hook_install::shell_quote(executable.to_str()?),
        agent_hook_install::HOOK_MODE_ARG,
    );
    let current = agent_hook_install::is_executable_file(&launcher)
        && fs::read(&launcher).is_ok_and(|existing| existing == script.as_bytes());
    if !current {
        fs::create_dir_all(launcher.parent()?).ok()?;
        agent_hook_install::atomic_write(&launcher, script.as_bytes(), Some(0o755)).ok()?;
    }
    Some(launcher)
}

/// This build's `cmux`, by an absolute path whose file name is `cmux` (the
/// name selects the `cmux` CLI surface): the executable itself when it is
/// named so, else a `cmux` beside it that is the same file (the app
/// bundle), else a link in the build folder (written when missing or stale).
fn own_cli(executable: &Path) -> Option<PathBuf> {
    if executable.file_stem().is_some_and(|stem| stem == CLI_NAME) {
        return Some(executable.to_path_buf());
    }
    let sibling =
        executable.with_file_name(CLI_NAME).with_extension(std::env::consts::EXE_EXTENSION);
    if same_file(&sibling, executable) {
        return Some(sibling);
    }
    own_cli_link(executable)
}

#[cfg(unix)]
fn own_cli_link(executable: &Path) -> Option<PathBuf> {
    let link = build_dir(executable)?.join("bin").join(CLI_NAME);
    if fs::read_link(&link).is_ok_and(|target| target == executable) {
        return Some(link);
    }
    let folder = link.parent()?;
    fs::create_dir_all(folder).ok()?;
    // Link beside it, then rename over: two daemons of one build may race.
    let staged = folder.join(format!(".{CLI_NAME}.{}", std::process::id()));
    let _ = fs::remove_file(&staged);
    std::os::unix::fs::symlink(executable, &staged).ok()?;
    if fs::rename(&staged, &link).is_err() {
        let _ = fs::remove_file(&staged);
        return None;
    }
    Some(link)
}

/// Windows has no `cmux` link of its own: only a `cmux` beside the build.
#[cfg(not(unix))]
fn own_cli_link(_executable: &Path) -> Option<PathBuf> {
    None
}

/// The hook helper a wrapped agent launch uses: the `CMUX_TUI_HOOK` the
/// launch inherited (its daemon's choice for the pane, or one the person
/// set for this launch) when that is an absolute executable file other than
/// the shared per-user helper any build's `agent hook install` writes, else
/// this build's own.
pub(crate) fn launch_hook_helper(
    executable: &Path,
    inherited: Option<OsString>,
) -> Option<PathBuf> {
    let shared = agent_hook_install::runtime_helper_path();
    inherited
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && agent_hook_install::is_executable_file(path))
        .filter(|path| shared.as_deref().is_none_or(|shared| !same_file(path, shared)))
        .or_else(|| hook_helper(executable))
}

fn same_file(a: &Path, b: &Path) -> bool {
    a == b || matches!((a.canonicalize(), b.canonicalize()), (Ok(a), Ok(b)) if a == b)
}

/// Points this daemon's panes at this build's helpers: `CMUX_TUI_CLI`,
/// `CMUX_TUI_HOOK`, the shim folder first on PATH (kept first over a caller
/// PATH and after shell startup files), and `CMUX_TUI_AGENT_SHIMS`. A helper
/// that could not be written leaves its part of the pane environment alone.
pub(crate) fn configure_pane(options: &mut cmux_tui_core::SurfaceOptions) {
    let Ok(executable) = crate::claude_wrapper::current_executable() else { return };
    if let Some(cli) = own_cli(&executable).and_then(|cli| cli.into_os_string().into_string().ok())
    {
        options.extra_env.push((CLI_ENV.into(), cli));
    }
    if let Some(helper) =
        hook_helper(&executable).and_then(|helper| helper.into_os_string().into_string().ok())
    {
        options.extra_env.push(("CMUX_TUI_HOOK".into(), helper));
    }
    let Some(dir) = shim_dir(&executable) else { return };
    let claude = crate::claude_wrapper::install_shim(&dir, &executable).is_ok();
    let codex = crate::codex_wrapper::install_shim(&dir, &executable).is_ok();
    let inherited = std::env::var_os("PATH").unwrap_or_default();
    let (Some(text), Some(path)) = (
        dir.to_str(),
        crate::claude_wrapper::path_with_shim_first(&inherited, &dir)
            .and_then(|path| path.into_string().ok()),
    ) else {
        return;
    };
    if !claude && !codex {
        return;
    }
    options.extra_env.push(("PATH".into(), path));
    if claude {
        options.claude_shim_dir = Some(text.to_owned());
    }
    options.extra_env.push((cmux_tui_core::AGENT_SHIMS_ENV.into(), text.to_owned()));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_build_folders_differ_per_executable_and_stay_put_per_build() {
        let a = Path::new("/opt/a/cmux-tui");
        let b = Path::new("/opt/b/cmux-tui");
        let (Some(dir_a), Some(dir_b)) = (build_dir(a), build_dir(b)) else {
            return; // No HOME in this environment: no data home to compare.
        };
        assert_ne!(dir_a, dir_b);
        assert_eq!(build_dir(a), Some(dir_a.clone()));
        assert_eq!(dir_a.file_name().unwrap().len(), 16);
        assert_eq!(dir_a.parent().unwrap().file_name().unwrap(), "builds");
    }

    #[test]
    fn own_build_launch_keeps_a_persons_hook_but_not_the_shared_one() {
        let dir = tempfile::tempdir().unwrap();
        let mine = dir.path().join("my-hook");
        agent_hook_install::atomic_write(&mine, b"#!/bin/sh\n", Some(0o755)).unwrap();
        let exe = dir.path().join("cmux-tui");
        agent_hook_install::atomic_write(&exe, b"", Some(0o755)).unwrap();
        let sibling = dir.path().join(HOOK_HELPER);
        agent_hook_install::atomic_write(&sibling, b"#!/bin/sh\n", Some(0o755)).unwrap();
        assert_eq!(launch_hook_helper(&exe, Some(mine.clone().into())), Some(mine));
        // A relative or missing value is not a helper: this build's own runs.
        assert_eq!(launch_hook_helper(&exe, Some("my-hook".into())), Some(sibling.clone()));
        assert_eq!(launch_hook_helper(&exe, None), Some(sibling.clone()));
        if let Some(shared) = agent_hook_install::runtime_helper_path()
            && agent_hook_install::is_executable_file(&shared)
        {
            assert_eq!(launch_hook_helper(&exe, Some(shared.into())), Some(sibling));
        }
    }
}
