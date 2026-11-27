//! The agent helpers a daemon's panes run, all of this daemon's own build:
//! the `claude` and `codex` shims first on the pane PATH, the agent hook
//! helper in `CMUX_TUI_HOOK`, the Claude Code plugin in
//! `CLAUDE_CODE_PLUGIN_DIRS`, and this build's `cmux` in `CMUX_TUI_CLI` (the
//! `cmux` on PATH can be another install, W5-Q).
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

/// The shared per-user shim folder of builds before per-build folders. Their
/// terminals keep it in `CMUX_TUI_AGENT_SHIMS` for as long as they live (a
/// terminal host outlives app updates), and their shell integration keeps it
/// first on PATH, so its `claude` and `codex` still start every agent of
/// those terminals.
fn shared_shim_dir() -> Option<PathBuf> {
    Some(agent_hook_install::runtime_cmux_tui_data_home()?.join("shims"))
}

/// A shim for the shared folder `dir` that names no build: it starts the
/// agent through the terminal's own cmux. Terminals of the builds that used
/// this folder predate `CMUX_TUI_CLI`, so their route is the app's bundled
/// `CMUX_BUNDLED_CLI_PATH`, taken only when it is a cmux-next bundle, whose
/// `cmux-tui` is the same file as its `cmux` (a classic app ships a separate
/// Swift `cmux` that has no `agent` wrappers). `CMUX_TUI_CLI` comes first for
/// any newer terminal that reaches the folder. Every build writes the same
/// bytes, so the last writer no longer decides which build's wrapper a
/// terminal runs. Without either it runs the executable the older shim
/// named (`writer`, the quoted path its writer put there, kept verbatim so a
/// rewrite reproduces the same bytes) while it still exists: a classic app's
/// or npm install's `cmux-tui` at a fixed path keeps adding the hooks it
/// added before. Without any it runs the agent itself, as the per-build shims
/// do when their build is gone.
fn shared_shim_script(
    name: &str,
    marker: &str,
    verb: &str,
    agent: &str,
    dir: &Path,
    writer: Option<&str>,
) -> Option<String> {
    let dir = agent_hook_install::shell_quote(dir.to_str()?);
    let writer = writer
        .map(|target| {
            format!("if [ -x {target} ]; then\n  exec {target} agent {verb} \"$@\"\nfi\n")
        })
        .unwrap_or_default();
    Some(format!(
        "#!/bin/sh\n\
         {marker}\n\
         # Written by cmux-tui for terminals started with this folder in\n\
         # CMUX_TUI_AGENT_SHIMS: starts {agent} through the terminal's own cmux.\n\
         for cli in \"${{CMUX_TUI_CLI-}}\" \"${{CMUX_BUNDLED_CLI_PATH-}}\"; do\n  \
           case $cli in\n    \
             /*)\n      \
               if [ -x \"$cli\" ] && {{ [ \"$cli\" = \"${{CMUX_TUI_CLI-}}\" ] || [ \"$cli\" -ef \"${{cli%/*}}/cmux-tui\" ]; }}; then\n        \
                 exec \"$cli\" agent {verb} \"$@\"\n      \
               fi\n      \
               ;;\n  \
           esac\n\
         done\n\
         {writer}\
         set -f\n\
         IFS=:\n\
         kept=\n\
         for entry in $PATH; do\n  [ \"$entry\" = {dir} ] || kept=\"${{kept:+$kept:}}$entry\"\ndone\n\
         unset IFS\n\
         set +f\n\
         PATH=$kept\n\
         export PATH\n\
         exec {name} \"$@\"\n"
    ))
}

/// The quoted executable an older shim (or a rewritten one) execs for
/// `verb`: the token of its `exec '<path>' agent <verb> "$@"` line, as
/// written. `exec "$cli" ...` lines of a rewritten shim are not one.
fn shim_writer_target<'a>(existing: &'a str, verb: &str) -> Option<&'a str> {
    let tail = format!(" agent {verb} \"$@\"");
    existing.lines().find_map(|line| {
        let token = line.trim().strip_prefix("exec ")?.strip_suffix(tail.as_str())?;
        (token.len() > 2 && token.starts_with('\'') && token.ends_with('\'')).then_some(token)
    })
}

/// Rewrites the `claude` and `codex` shims an older build left in the
/// shared folder (an older build names its own executable there, and a
/// deleted dev build's shim silently starts the agent without cmux) as
/// [`shared_shim_script`]s. Only files that are cmux-tui shims are touched,
/// and nothing is created: with no older build, no terminal names the folder.
fn refresh_shared_shims_in(dir: &Path) {
    let shims = [
        ("claude", crate::claude_wrapper::SHIM_MARKER, crate::claude_wrapper::VERB, "Claude Code"),
        ("codex", crate::codex_wrapper::SHIM_MARKER, crate::codex_wrapper::VERB, "Codex"),
    ];
    for (name, marker, verb, agent) in shims {
        let path = dir.join(name);
        let Ok(existing) = fs::read(&path) else { continue };
        let is_ours = fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.is_file())
            && existing.windows(marker.len()).any(|window| window == marker.as_bytes());
        if !is_ours {
            continue;
        }
        let text = String::from_utf8_lossy(&existing);
        let writer = shim_writer_target(&text, verb);
        let Some(script) = shared_shim_script(name, marker, verb, agent, dir, writer) else {
            continue;
        };
        if existing != script.as_bytes() {
            let _ =
                agent_hook_install::replace_rewritable_file(&path, script.as_bytes(), Some(0o700));
        }
    }
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
    hook_launcher(&build_dir(executable)?, executable)
}

/// Writes (when its content changed) and returns the launcher of this
/// build's hook helper in its build folder `build`.
fn hook_launcher(build: &Path, executable: &Path) -> Option<PathBuf> {
    let launcher = build.join("bin").join(HOOK_HELPER);
    let script = format!(
        "#!/bin/sh\nexec {} {} \"$@\"\n",
        agent_hook_install::shell_quote(executable.to_str()?),
        agent_hook_install::HOOK_MODE_ARG,
    );
    let current = agent_hook_install::is_executable_file(&launcher)
        && fs::read(&launcher).is_ok_and(|existing| existing == script.as_bytes());
    if !current {
        fs::create_dir_all(launcher.parent()?).ok()?;
        agent_hook_install::replace_rewritable_file(&launcher, script.as_bytes(), Some(0o755))
            .ok()?;
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
    inherited_hook_helper(inherited).or_else(|| hook_helper(executable))
}

/// The inherited `CMUX_TUI_HOOK` when it names an absolute executable file
/// other than the shared per-user helper, else `None`. Reads only: it never
/// writes a launcher.
pub(crate) fn inherited_hook_helper(inherited: Option<OsString>) -> Option<PathBuf> {
    let shared = agent_hook_install::runtime_helper_path();
    inherited
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && agent_hook_install::is_executable_file(path))
        .filter(|path| shared.as_deref().is_none_or(|shared| !same_file(path, shared)))
}

/// The pane's `CLAUDE_CODE_PLUGIN_DIRS` with this build's Claude Code plugin
/// (claude_plugin.rs), written into the build folder. `None` leaves the
/// variable as the daemon inherited it: cmux-tui's Claude hooks are turned
/// off, this machine's Claude Code policy refuses plugin folders from the
/// environment, or the plugin could not be written.
fn claude_plugin_dirs(executable: &Path, helper: &Path) -> Option<String> {
    if std::env::var_os("CMUX_TUI_CLAUDE_HOOKS_DISABLED").is_some_and(|value| value == "1") {
        return None;
    }
    let home = std::env::var_os("HOME").filter(|home| !home.is_empty()).map(PathBuf::from);
    let config_dir =
        std::env::var_os("CLAUDE_CONFIG_DIR").filter(|dir| !dir.is_empty()).map(PathBuf::from);
    let policy = crate::claude_plugin::policy_files(home.as_deref(), config_dir.as_deref());
    if crate::claude_plugin::sideloading_disabled(&policy) {
        return None;
    }
    let dir = build_dir(executable)?.join(crate::claude_plugin::PLUGIN_FOLDER);
    crate::claude_plugin::install(&dir, executable, helper).ok()?;
    let inherited = std::env::var_os(crate::claude_plugin::PLUGIN_DIRS_ENV);
    crate::claude_plugin::pane_plugin_dirs(inherited.as_deref(), &dir)?.into_string().ok()
}

fn same_file(a: &Path, b: &Path) -> bool {
    a == b || matches!((a.canonicalize(), b.canonicalize()), (Ok(a), Ok(b)) if a == b)
}

/// Points this daemon's panes at this build's helpers: `CMUX_TUI_CLI`,
/// `CMUX_TUI_HOOK`, the shim folder first on PATH (kept first over a caller
/// PATH and after shell startup files), `CMUX_TUI_AGENT_SHIMS`, and this
/// build's Claude Code plugin in `CLAUDE_CODE_PLUGIN_DIRS`. A helper that
/// could not be written leaves its part of the pane environment alone.
pub(crate) fn configure_pane(options: &mut cmux_tui_core::SurfaceOptions) {
    let Ok(executable) = crate::claude_wrapper::current_executable() else { return };
    if let Some(cli) = own_cli(&executable).and_then(|cli| cli.into_os_string().into_string().ok())
    {
        options.extra_env.push((CLI_ENV.into(), cli));
    }
    let helper = hook_helper(&executable);
    if let Some(helper) =
        helper.clone().and_then(|helper| helper.into_os_string().into_string().ok())
    {
        options.extra_env.push(("CMUX_TUI_HOOK".into(), helper));
    }
    if let Some(dirs) = helper.and_then(|helper| claude_plugin_dirs(&executable, &helper)) {
        options.extra_env.push((crate::claude_plugin::PLUGIN_DIRS_ENV.into(), dirs));
    }
    if let Some(shared) = shared_shim_dir() {
        refresh_shared_shims_in(&shared);
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
#[path = "own_build_helpers_tests.rs"]
mod tests;
