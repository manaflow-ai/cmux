//! Automatic shell integration for the interactive shells cmux-tui launches.
//!
//! The embedded terminal is ghostty-vt, which reflows the primary screen on
//! every resize and clears a redrawable prompt so the shell can repaint it.
//! Both depend on OSC 133 semantic prompt marks. Without them the terminal
//! cannot tell a prompt from output, so each SIGWINCH redraw lands on reflowed
//! cells and leaves prompt fragments behind. Ghostty emits those marks by
//! injecting its shell integration scripts when it spawns a shell; this module
//! does the same for cmux-tui, using the scripts from ghostty-next, the Ghostty
//! submodule that builds ghostty-vt, so both halves always match.
//!
//! The injection mirrors Ghostty's `src/termio/shell_integration.zig`: zsh via
//! `ZDOTDIR`, bash via `--posix` plus `ENV`, and fish via `XDG_DATA_DIRS`.

use std::ffi::OsStr;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use sha2::{Digest, Sha256};

mod cli_path;
mod ghostty_files;

use ghostty_files::Mode;

struct Script {
    path: &'static str,
    contents: &'static str,
}

const SCRIPTS: &[Script] = &[
    Script {
        path: "zsh/.zshenv",
        contents: include_str!("../../../../ghostty-next/src/shell-integration/zsh/.zshenv"),
    },
    // The cmux-tui additions run after the user's startup files: zsh's
    // integration body runs from `.zshenv` and registers a precmd hook, and
    // the bash script sources the startup files before its own setup.
    Script {
        path: "zsh/ghostty-integration",
        contents: concat!(
            include_str!("../../../../ghostty-next/src/shell-integration/zsh/ghostty-integration"),
            include_str!("shell_integration/agent-shims.zsh"),
            include_str!("shell_integration/incognito-history.zsh"),
        ),
    },
    Script {
        path: "bash/ghostty.bash",
        contents: concat!(
            include_str!("../../../../ghostty-next/src/shell-integration/bash/ghostty.bash"),
            include_str!("shell_integration/agent-shims.bash"),
            include_str!("shell_integration/incognito-history.bash"),
        ),
    },
    Script {
        path: "bash/bash-preexec.sh",
        contents: include_str!(
            "../../../../ghostty-next/src/shell-integration/bash/bash-preexec.sh"
        ),
    },
    Script {
        path: "fish/vendor_conf.d/ghostty-shell-integration.fish",
        contents: include_str!(
            "../../../../ghostty-next/src/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"
        ),
    },
    // Ghostty's fish script ends with `exit`, so the cmux-tui addition is its
    // own vendor file; fish reads every `vendor_conf.d` file at startup.
    Script {
        path: "fish/vendor_conf.d/cmux-tui-agent-shims.fish",
        contents: include_str!("shell_integration/cmux-tui-agent-shims.fish"),
    },
    Script {
        path: "fish/vendor_conf.d/cmux-tui-incognito-history.fish",
        contents: include_str!("shell_integration/cmux-tui-incognito-history.fish"),
    },
];

/// The directory holding cmux-tui's `codex` and `claude` shims. Integrated
/// shells move it back to the front of PATH after the user's startup files
/// (and before each command), so a startup file that prepends the directory
/// of the real agent cannot bypass the shim and its per-terminal hooks. The
/// app's own integration (`Resources/cmux-cli-path`) does the same.
pub const AGENT_SHIMS_ENV: &str = "CMUX_TUI_AGENT_SHIMS";

/// Set (to `1`) in the shells of an incognito workspace's terminals: the
/// integration scripts keep history off after the user's startup files
/// ([`keep_no_history`]).
pub const INCOGNITO_ENV: &str = "CMUX_TUI_INCOGNITO";

/// History off for a terminal of an incognito workspace (design/spaces.md
/// "Incognito": nothing kept): `HISTFILE=/dev/null` for bash and zsh,
/// `fish_private_mode` for fish, and [`INCOGNITO_ENV`] so the integration
/// scripts turn it off again after startup files that set `HISTFILE`
/// (macOS `/etc/zshrc` does). Appended last, so it wins over an inherited
/// or caller value.
pub(crate) fn keep_no_history(env: &mut Vec<(String, String)>) {
    env.retain(|(key, _)| key != "HISTFILE" && key != "fish_private_mode" && key != INCOGNITO_ENV);
    env.push(("HISTFILE".into(), "/dev/null".into()));
    env.push(("fish_private_mode".into(), "1".into()));
    env.push((INCOGNITO_ENV.into(), "1".into()));
}

/// Opt-out: `CMUX_TUI_SHELL_INTEGRATION=none` launches shells unmodified.
const OPT_OUT_ENV: &str = "CMUX_TUI_SHELL_INTEGRATION";

/// The features the scripts enable (title, cursor shape, path). Ghostty
/// always exports it (`setupFeatures` in `src/termio/shell_integration.zig`);
/// without it the title is whatever the user's own hooks set.
const FEATURES_ENV: &str = "GHOSTTY_SHELL_FEATURES";

/// The scripts' ssh wrappers run `$GHOSTTY_BIN_DIR/ghostty +ssh`.
const GHOSTTY_BIN_DIR_ENV: &str = "GHOSTTY_BIN_DIR";

/// The features whose scripts run the Ghostty CLI.
const CLI_FEATURES: [&str; 2] = ["ssh-env", "ssh-terminfo"];

/// Where the shell finds the Ghostty CLI: its `GHOSTTY_BIN_DIR` as given, or
/// the directory of `GHOSTTY_BIN`, which the shell then needs exported.
#[derive(Debug, Clone, PartialEq, Eq)]
enum GhosttyCliDir {
    Given,
    FromBinary(String),
}

fn ghostty_cli_dir(lookup: &dyn Fn(&str) -> Option<String>) -> Option<GhosttyCliDir> {
    if lookup(GHOSTTY_BIN_DIR_ENV).is_some_and(|dir| !dir.is_empty()) {
        return Some(GhosttyCliDir::Given);
    }
    let binary = lookup("GHOSTTY_BIN").filter(|binary| !binary.is_empty())?;
    let dir = Path::new(&binary).parent()?.to_str()?.to_string();
    (!dir.is_empty()).then_some(GhosttyCliDir::FromBinary(dir))
}

/// `features` without the ones the shell cannot serve: with no Ghostty CLI,
/// the ssh wrappers would make `ssh` run a missing program, so they go and
/// plain `ssh` runs (Ghostty itself always has its CLI).
fn usable_features(features: &str, has_cli: bool) -> String {
    if has_cli {
        return features.to_string();
    }
    features
        .split(',')
        .filter(|feature| !CLI_FEATURES.contains(feature))
        .collect::<Vec<_>>()
        .join(",")
}

/// `GHOSTTY_SHELL_FEATURES` and the Ghostty CLI directory for a shell the
/// daemon starts.
fn export_features(
    env: &mut Vec<(String, String)>,
    lookup: &dyn Fn(&str) -> Option<String>,
    user: &ghostty_files::Settings,
) {
    // A caller (or daemon) value is the user's resolved feature set; with
    // none, the user's Ghostty config files give it, then Ghostty's defaults
    // (DAEMON-SHELL-FEATURES-FROM-GHOSTTY-FILES).
    let cli_dir = ghostty_cli_dir(lookup);
    let given = lookup(FEATURES_ENV);
    let features = given.clone().unwrap_or_else(|| user.env_value());
    let usable = usable_features(&features, cli_dir.is_some());
    if given.as_deref() != Some(usable.as_str()) {
        env.push((FEATURES_ENV.into(), usable));
    }
    if let Some(GhosttyCliDir::FromBinary(dir)) = cli_dir {
        env.push((GHOSTTY_BIN_DIR_ENV.into(), dir));
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Shell {
    Bash,
    Fish,
    Zsh,
}

/// An interactive shell launch after shell integration was applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellLaunch {
    pub command: Vec<String>,
    /// Environment for the child, in application order. The input entries
    /// come first, so an injected value wins over an inherited or extra one.
    pub env: Vec<(String, String)>,
}

/// Apply shell integration to the default interactive shell.
///
/// Only the default shell is modified: an explicit command is the caller's
/// program, and `-c` style launches are never interactive. Any failure leaves
/// the launch unchanged, so a shell always starts.
/// The launch of a terminal's `command`: the default shell (`None` or
/// empty), integrated by [`integrate_default_shell`], or the caller's
/// program unchanged. An incognito terminal's interactive shell that nobody
/// integrated is integrated too: its scripts are what keep its history off
/// after the startup files ran ([`keep_no_history`]).
pub fn shell_launch(command: Option<Vec<String>>, env: Vec<(String, String)>) -> ShellLaunch {
    match command.filter(|command| !command.is_empty()) {
        None => integrate_default_shell(vec![crate::platform::default_shell()], env),
        Some(command) if needs_incognito_integration(&command, &env) => {
            integrate_default_shell(command, env)
        }
        Some(command) => ShellLaunch { command, env },
    }
}

/// The keys a terminal with launch environment `env` must not inherit from
/// the daemon's own environment, removed after `env` is applied.
pub fn inherited_keys_to_unset(env: &[(String, String)]) -> Vec<&'static str> {
    inherited_keys_to_unset_from(env, &|key| std::env::var(key).ok())
}

fn inherited_keys_to_unset_from(
    env: &[(String, String)],
    inherited: &dyn Fn(&str) -> Option<String>,
) -> Vec<&'static str> {
    let own = |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone());
    // An incognito terminal keeps its markers; a daemon started outside an
    // incognito terminal has none to pass on.
    if is_incognito(&own) || !is_incognito(inherited) {
        return Vec::new();
    }
    std::iter::once(INCOGNITO_ENV)
        .chain(["fish_private_mode", "HISTFILE"].into_iter().filter(|key| own(key).is_none()))
        .collect()
}

/// Whether `env` is an incognito terminal's.
fn is_incognito(lookup: &dyn Fn(&str) -> Option<String>) -> bool {
    lookup(INCOGNITO_ENV).is_some_and(|value| !value.is_empty())
}

/// The app's cmux-cli-path startup files that run the incognito history
/// hook, as the app bundle ships them (`BundledCLIEnvironment`).
const APP_ZSHENV: &str = include_str!("../../../../Resources/cmux-cli-path/zsh/.zshenv");
const APP_FISH: &str =
    include_str!("../../../../Resources/cmux-cli-path/fish/vendor_conf.d/cmux-cli-path.fish");

/// The daemon's own script at `path` under its scripts root.
fn script(path: &str) -> Option<&'static str> {
    SCRIPTS.iter().find(|script| script.path == path).map(|script| script.contents)
}

/// Whether the bare interactive `shell` under `lookup` already runs the
/// incognito history hook at startup: the startup files it reads first are
/// the app's cmux-cli-path layer or the daemon's own scripts, byte for byte.
/// Neither a launch key nor a file that only names the marker proves it (a
/// caller may set or write any). A bare bash never reads `ENV` (only
/// `--posix` does), so it never has one.
fn runs_incognito_hook(shell: Shell, lookup: &dyn Fn(&str) -> Option<String>) -> bool {
    let is = |path: &Path, expected: Option<&str>| {
        expected.is_some_and(|expected| fs::read_to_string(path).is_ok_and(|text| text == expected))
    };
    match shell {
        Shell::Zsh => lookup("ZDOTDIR").is_some_and(|dir| {
            let dir = Path::new(&dir);
            let zshenv = dir.join(".zshenv");
            is(&zshenv, Some(APP_ZSHENV))
                || (is(&zshenv, script("zsh/.zshenv"))
                    && is(&dir.join("ghostty-integration"), script("zsh/ghostty-integration")))
        }),
        Shell::Bash => false,
        Shell::Fish => lookup("XDG_DATA_DIRS").is_some_and(|dirs| {
            dirs.split(':').filter(|dir| !dir.is_empty()).any(|dir| {
                let vendor = Path::new(dir).join("fish").join("vendor_conf.d");
                is(&vendor.join("cmux-cli-path.fish"), Some(APP_FISH))
                    || is(
                        &vendor.join("cmux-tui-incognito-history.fish"),
                        script("fish/vendor_conf.d/cmux-tui-incognito-history.fish"),
                    )
            })
        }),
    }
}

/// Whether every argument after the program is a login or interactive flag
/// (`-l`, `--login`, `-i`, or a cluster of them such as `-il`).
fn is_bare(command: &[String]) -> bool {
    command.iter().skip(1).all(|arg| {
        arg == "--login"
            || arg.strip_prefix('-').is_some_and(|flags| {
                !flags.is_empty() && flags.chars().all(|flag| matches!(flag, 'i' | 'l'))
            })
    })
}

/// An explicit `command` of an incognito terminal that is a bare
/// interactive zsh, bash or fish (login and interactive flags only) whose
/// startup files do not already run the incognito history hook.
fn needs_incognito_integration(command: &[String], env: &[(String, String)]) -> bool {
    let lookup =
        |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, value)| value.clone());
    is_incognito(&lookup)
        && is_bare(command)
        && shell_by_name(command).is_some_and(|shell| !runs_incognito_hook(shell, &lookup))
}

/// A bare incognito `command` of `shell` with no integration scripts to
/// run: started without the startup files that could turn its history back
/// on (fish also in private mode). Any other command is left alone.
fn without_startup_files(shell: Shell, mut command: Vec<String>) -> Vec<String> {
    if command.is_empty() || !is_bare(&command) {
        return command;
    }
    let flags: &[&str] = match shell {
        Shell::Zsh => &["-f"],
        Shell::Bash => &["--noprofile", "--norc"],
        Shell::Fish => &["--private", "--no-config"],
    };
    for (offset, flag) in flags.iter().enumerate() {
        command.insert(offset.saturating_add(1), (*flag).to_string());
    }
    command
}

pub fn integrate_default_shell(
    command: Vec<String>,
    extra_env: Vec<(String, String)>,
) -> ShellLaunch {
    integrate_with(command, extra_env, &|key| std::env::var(key).ok())
}

/// [`integrate_default_shell`] over the daemon's own environment
/// `inherited`.
fn integrate_with(
    command: Vec<String>,
    extra_env: Vec<(String, String)>,
    inherited: &dyn Fn(&str) -> Option<String>,
) -> ShellLaunch {
    let launch_env = extra_env.clone();
    let own = move |key: &str| -> Option<String> {
        launch_env.iter().rev().find(|(name, _)| name == key).map(|(_, value)| value.clone())
    };
    let lookup = |key: &str| -> Option<String> { own(key).or_else(|| inherited(key)) };
    // An incognito shell is integrated even under the opt-outs: the
    // integration is what keeps its history off (design/spaces.md
    // "Incognito": nothing kept). Only the launch says so: the daemon's own
    // environment carries an incognito terminal's marker when the daemon
    // started in one ([`inherited_keys_to_unset`]).
    let incognito = is_incognito(&own);
    if lookup(OPT_OUT_ENV).as_deref() == Some("none") && !incognito {
        return ShellLaunch { command, env: extra_env };
    }
    let user = ghostty_files::read(&lookup);
    // No integration (`shell-integration = none`, an unknown shell, a shell
    // with no scripts here, or no scripts at all): Ghostty still exports the
    // features (`Exec` sets them before it detects the shell), for a manual
    // integration.
    let features_only = |mut env: Vec<(String, String)>| {
        export_features(&mut env, &lookup, &user);
        env
    };
    // An incognito shell is integrated as the shell it is: a forced mode
    // naming another shell would give it that shell's flags and no history
    // hook of its own.
    let shell = if incognito {
        // Fail closed: a shell the integration cannot take here reads no
        // startup files.
        if let Some(command) = unintegrable_incognito(&command, cfg!(target_os = "macos")) {
            return ShellLaunch { env: features_only(extra_env), command };
        }
        shell_by_name(&command).or_else(|| shell_for(user.mode, &command))
    } else {
        shell_for(user.mode, &command)
    };
    let Some(shell) = shell else {
        return ShellLaunch { env: features_only(extra_env), command };
    };
    let Some(root) = scripts_root().and_then(|root| materialize(&root).ok()) else {
        // Fail closed: an incognito shell whose history hook cannot run
        // reads no startup files.
        let command = if incognito { without_startup_files(shell, command) } else { command };
        return ShellLaunch { env: features_only(extra_env), command };
    };
    apply(shell, &root, command, extra_env, &lookup, &user)
}

/// The shell to integrate under the user's `shell-integration`: none for
/// `none`, the command's shell for `detect`, else the forced shell, as
/// Ghostty's `Exec` does. elvish and nushell have no scripts here.
fn shell_for(mode: Mode, command: &[String]) -> Option<Shell> {
    match mode {
        Mode::Detect => detect_shell(command),
        Mode::Bash => Some(Shell::Bash),
        Mode::Fish => Some(Shell::Fish),
        Mode::Zsh => Some(Shell::Zsh),
        Mode::None | Mode::Elvish | Mode::Nushell => None,
    }
}

fn detect_shell(command: &[String]) -> Option<Shell> {
    if is_apple_bash(command, cfg!(target_os = "macos")) {
        return None;
    }
    shell_by_name(command)
}

/// Whether `command` runs Apple's patched Bash 3.2, which ignores ENV in
/// POSIX startup, which the bash injection depends on. /bin is
/// SIP-protected, so /bin/bash on macOS is always that build.
fn is_apple_bash(command: &[String], macos: bool) -> bool {
    macos && command.first().is_some_and(|exe| exe == "/bin/bash")
}

/// An incognito `command` naming a shell the integration cannot take
/// (Apple's `/bin/bash` on `macos`): the same command without startup files.
fn unintegrable_incognito(command: &[String], macos: bool) -> Option<Vec<String>> {
    let named = shell_by_name(command)?;
    is_apple_bash(command, macos).then(|| without_startup_files(named, command.to_vec()))
}

/// The shell `command` runs, by its program's name alone.
fn shell_by_name(command: &[String]) -> Option<Shell> {
    let exe = command.first()?;
    let name = Path::new(exe).file_name().and_then(OsStr::to_str)?;
    match name {
        "bash" => Some(Shell::Bash),
        "fish" => Some(Shell::Fish),
        "zsh" => Some(Shell::Zsh),
        _ => None,
    }
}

fn apply(
    shell: Shell,
    root: &Path,
    mut command: Vec<String>,
    mut env: Vec<(String, String)>,
    lookup: &dyn Fn(&str) -> Option<String>,
    user: &ghostty_files::Settings,
) -> ShellLaunch {
    // The daemon integrates this shell, so it owns the Ghostty integration
    // keys: a caller value for one of them never reaches the shell.
    crate::daemon_env::warn_dropped(&crate::daemon_env::strip_integration_owned(&mut env));
    export_features(&mut env, lookup, user);
    let root_str = root.to_string_lossy().into_owned();
    match shell {
        Shell::Zsh => {
            // A `ZDOTDIR` that is already a shell integration's own
            // directory is not the user's: the one it saved is. Recording it
            // would make the integration source itself.
            let previous = match lookup("ZDOTDIR") {
                Some(dir) if Path::new(&dir).join("ghostty-integration").is_file() => {
                    lookup("GHOSTTY_ZSH_ZDOTDIR")
                }
                other => other,
            };
            if let Some(previous) = previous {
                env.push(("GHOSTTY_ZSH_ZDOTDIR".into(), previous));
            }
            env.push(("ZDOTDIR".into(), format!("{root_str}/zsh")));
        }
        Shell::Bash => {
            // The default shell carries no arguments of its own; anything
            // that makes bash non-interactive or already POSIX is left alone.
            if command.iter().skip(1).any(|arg| {
                arg == "--posix"
                    || (arg.starts_with('-') && !arg.starts_with("--") && arg.contains('c'))
            }) {
                return ShellLaunch { command, env };
            }
            command.insert(1, "--posix".into());
            if let Some(previous) = lookup("ENV") {
                env.push(("GHOSTTY_BASH_ENV".into(), previous));
            }
            env.push(("ENV".into(), format!("{root_str}/bash/ghostty.bash")));
            env.push(("GHOSTTY_BASH_INJECT".into(), "1".into()));
            // POSIX mode defaults HISTFILE to ~/.sh_history; the script
            // unexports this again once it leaves POSIX mode.
            if lookup("HISTFILE").is_none()
                && let Some(home) = lookup("HOME")
            {
                env.push(("HISTFILE".into(), format!("{home}/.bash_history")));
                env.push(("GHOSTTY_BASH_UNEXPORT_HISTFILE".into(), "1".into()));
            }
        }
        Shell::Fish => {
            let current = lookup("XDG_DATA_DIRS")
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
            env.push(("GHOSTTY_SHELL_INTEGRATION_XDG_DIR".into(), root_str.clone()));
            env.push(("XDG_DATA_DIRS".into(), format!("{root_str}:{current}")));
        }
    }
    cli_path::wrap(shell, &mut env, lookup);
    ShellLaunch { command, env }
}

fn scripts_root() -> Option<PathBuf> {
    let base = crate::platform::workspace_state_dir()
        .and_then(|sessions| sessions.parent().map(Path::to_path_buf))
        .unwrap_or_else(crate::platform::runtime_dir);
    Some(base.join("shell-integration").join(content_digest()))
}

fn content_digest() -> String {
    let mut hasher = Sha256::new();
    for script in SCRIPTS {
        hasher.update(script.path.as_bytes());
        hasher.update([0]);
        hasher.update(script.contents.as_bytes());
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    digest[..8].iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Write the scripts under `root`, or confirm they are already intact. The
/// check runs on every launch because a shell pointed at a missing script
/// would start without its rc files (bash stays in POSIX mode).
///
/// Every new shell sources these files, so the directories and files must
/// belong to this user and must not be symlinks, and no other user may be
/// able to replace a directory above them; otherwise the launch goes ahead
/// without integration. The returned root is canonical, so shells never
/// resolve the scripts through a symlink.
fn materialize(root: &Path) -> io::Result<PathBuf> {
    let invalid = || io::Error::other("scripts root needs a parent and a name");
    let digest = root.file_name().ok_or_else(invalid)?;
    let container = root.parent().ok_or_else(invalid)?;
    let container_name = container.file_name().ok_or_else(invalid)?;
    let base = container.parent().ok_or_else(invalid)?;
    fs::create_dir_all(base)?;
    let base = fs::canonicalize(base)?;
    check_trusted_ancestors(&base)?;
    let container = base.join(container_name);
    let root = container.join(digest);
    let root = root.as_path();
    ensure_private_dir(&container)?;
    ensure_private_dir(root)?;
    for script in SCRIPTS {
        let path = root.join(script.path);
        let parent = path.parent().ok_or_else(|| io::Error::other("script has no parent"))?;
        let mut missing = Vec::new();
        let mut dir = parent;
        while dir != root {
            missing.push(dir);
            dir = dir.parent().ok_or_else(|| io::Error::other("script outside its root"))?;
        }
        for dir in missing.into_iter().rev() {
            ensure_private_dir(dir)?;
        }
        if check_owned(&path, false).is_ok()
            && fs::read(&path).is_ok_and(|existing| existing == script.contents.as_bytes())
        {
            continue;
        }
        // Unique per call: shells can launch concurrently in one process.
        let temp = parent.join(format!(
            ".{}.{}.{}.tmp",
            path.file_name().and_then(OsStr::to_str).unwrap_or("script"),
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let written = (|| {
            let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&temp)?;
            file.write_all(script.contents.as_bytes())?;
            file.sync_all()?;
            crate::platform::restrict_file(&temp)?;
            fs::rename(&temp, &path)
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temp);
        }
        written?;
    }
    Ok(root.to_path_buf())
}

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Every directory from `base` up to `/` must belong to this user or root.
/// One that every user can write to must be a root-owned sticky directory
/// (like `/tmp`), where no other user can rename our entries. Group write is
/// accepted on this user's own directories (umask 002 with a private group).
#[cfg(unix)]
fn check_trusted_ancestors(base: &Path) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let uid = crate::platform::effective_uid();
    for dir in base.ancestors() {
        let metadata = fs::symlink_metadata(dir)?;
        let mode = metadata.mode();
        let owner_ok = metadata.uid() == uid || metadata.uid() == 0;
        let shared = mode & 0o002 != 0 || (mode & 0o020 != 0 && metadata.uid() != uid);
        let sticky_root = mode & 0o1000 != 0 && metadata.uid() == 0;
        if !metadata.is_dir() || !owner_ok || (shared && !sticky_root) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("{} could be replaced by another user", dir.display()),
            ));
        }
    }
    Ok(())
}

#[cfg(not(unix))]
fn check_trusted_ancestors(_base: &Path) -> io::Result<()> {
    Ok(())
}

fn ensure_private_dir(dir: &Path) -> io::Result<()> {
    match fs::create_dir(dir) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    check_owned(dir, true)?;
    crate::platform::restrict_directory(dir)
}

#[cfg(unix)]
fn check_owned(path: &Path, directory: bool) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink()
        || metadata.is_dir() != directory
        || metadata.uid() != crate::platform::effective_uid()
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a private shell integration path", path.display()),
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn check_owned(path: &Path, directory: bool) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || metadata.is_dir() != directory {
        return Err(io::Error::other(format!(
            "{} is not a shell integration path",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod test_pty;

#[cfg(all(test, unix))]
mod prompt_redraw_tests;

#[cfg(all(test, unix))]
mod incognito_history_tests;

#[cfg(all(test, target_os = "macos"))]
mod fork_watch;

#[cfg(all(test, unix))]
mod fork_count_tests;

#[cfg(test)]
mod tests {
    use super::*;

    /// zsh passes preexec a `$2` that drops every word that does not fit its
    /// 80-byte job text, and oh-my-zsh titles the terminal with it
    /// (`/usr/bin/python3 /long/a.py /long/b.json 60` became
    /// `/usr/bin/python3   60`). Ghostty's title feature runs after the
    /// user's hooks and titles the running command with the full line.
    #[cfg(unix)]
    #[test]
    fn a_daemon_integrated_zsh_titles_a_long_command_with_every_argument() {
        use std::io::Read;
        let Some(zsh) = ["/bin/zsh", "/usr/bin/zsh"].into_iter().find(|p| Path::new(p).is_file())
        else {
            eprintln!("skipped: zsh is not installed");
            return;
        };
        let base = std::env::temp_dir().join(format!(
            "cmux-tui-shell-title-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let user = base.join("user");
        fs::create_dir_all(&user).unwrap();
        let base = fs::canonicalize(&base).unwrap();
        let root = materialize(&base.join("shell-integration").join(content_digest())).unwrap();
        // No system rc files: a distribution's global zshrc can stop at an
        // interactive compinit question.
        fs::write(user.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
        // The title hook oh-my-zsh's termsupport installs, reduced to its use
        // of zsh's `$2`.
        fs::write(
            user.join(".zshrc"),
            "PS1='$ '\npreexec() { print -rn -- $'\\e]2;'\"$2\"$'\\a' }\n",
        )
        .unwrap();
        let env = vec![
            ("HOME".to_string(), base.to_string_lossy().into_owned()),
            (
                "ZDOTDIR".to_string(),
                fs::canonicalize(&user).unwrap().to_string_lossy().into_owned(),
            ),
        ];
        let lookup = {
            let env = env.clone();
            move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
        };
        let launched =
            apply(Shell::Zsh, &root, vec![zsh.into()], env, &lookup, &ghostty_files::read(&lookup));

        let pty = cmux_pty::open(cmux_pty::PtySize {
            rows: 24,
            cols: 200,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap();
        let mut command = cmux_pty::PtyCommand::new(&launched.command[0]);
        command.args(launched.command[1..].iter().cloned());
        command.env("TERM", "xterm-256color");
        for (key, value) in &launched.env {
            command.env(key.clone(), value.clone());
        }
        let mut spawned = pty.spawn(command).unwrap();
        let mut reader = spawned.master.try_clone_reader().unwrap();
        let mut writer = spawned.master.take_writer().unwrap();
        let (chunks, received) = std::sync::mpsc::channel::<Vec<u8>>();
        std::thread::spawn(move || {
            let mut chunk = [0u8; 4096];
            // EOF, or EIO once the child side closes (Linux).
            while let Ok(n) = reader.read(&mut chunk) {
                if n == 0 || chunks.send(chunk[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        let mut output = Vec::new();
        let read_until = |output: &mut Vec<u8>, needle: &[u8]| {
            while !output.windows(needle.len()).any(|window| window == needle) {
                let left = deadline.saturating_duration_since(std::time::Instant::now());
                match received.recv_timeout(left) {
                    Ok(chunk) => output.extend_from_slice(&chunk),
                    Err(_) => panic!(
                        "no {:?} from zsh: {:?}",
                        String::from_utf8_lossy(needle),
                        String::from_utf8_lossy(output)
                    ),
                }
            }
        };
        // Type the command at the prompt, as a user does: input typed before
        // the line editor starts can lose characters.
        read_until(&mut output, b"$ ");
        // The command's first output (`r92-42`) differs from its echoed
        // text (`r92-$((40+2))`), so it marks the moment it runs.
        let line = "print -r -- r92-$((40+2)) \
                        /Users/someone/nx-jobs/jobs/r92cb-live-final/artifacts/osc52-reader.py \
                        /Users/someone/nx-jobs/jobs/r92cb-live-final/artifacts/deny-reply.json 60";
        writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        read_until(&mut output, b"r92-42");
        writer.write_all(b"exit\n").unwrap();
        drop(writer);
        while spawned.child.try_wait().unwrap().is_none() {
            assert!(std::time::Instant::now() < deadline, "zsh did not exit");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        drop(spawned);

        // The title while the command runs: everything the shell wrote
        // before the command's own output (after every preexec hook),
        // parsed by the terminal the daemon reads titles from.
        let start = output.windows(6).position(|window| window == b"r92-42").unwrap();
        let mut terminal =
            ghostty_vt::Terminal::new(200, 24, 0, ghostty_vt::Callbacks::default()).unwrap();
        terminal.vt_write(&output[..start]);
        assert_eq!(terminal.title().as_deref(), Some(line));
        fs::remove_dir_all(&base).unwrap();
    }
}
