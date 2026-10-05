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

struct Script {
    path: &'static str,
    contents: &'static str,
}

const SCRIPTS: &[Script] = &[
    Script {
        path: "zsh/.zshenv",
        contents: include_str!("../../../../ghostty-next/src/shell-integration/zsh/.zshenv"),
    },
    Script {
        path: "zsh/ghostty-integration",
        contents: include_str!(
            "../../../../ghostty-next/src/shell-integration/zsh/ghostty-integration"
        ),
    },
    Script {
        path: "bash/ghostty.bash",
        contents: include_str!("../../../../ghostty-next/src/shell-integration/bash/ghostty.bash"),
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
];

/// Opt-out: `CMUX_TUI_SHELL_INTEGRATION=none` launches shells unmodified.
const OPT_OUT_ENV: &str = "CMUX_TUI_SHELL_INTEGRATION";

/// The features the scripts enable (title, cursor shape, path). Ghostty
/// always exports it (`setupFeatures` in `src/termio/shell_integration.zig`);
/// without it the title is whatever the user's own hooks set.
const FEATURES_ENV: &str = "GHOSTTY_SHELL_FEATURES";

/// Ghostty's default `shell-integration-features` (cursor, path, title) with
/// its default blinking cursor, in its sorted order.
const DEFAULT_FEATURES: &str = "cursor:blink,path,title";

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
pub fn integrate_default_shell(
    command: Vec<String>,
    extra_env: Vec<(String, String)>,
) -> ShellLaunch {
    let inherited = extra_env.clone();
    let lookup = move |key: &str| -> Option<String> {
        inherited
            .iter()
            .rev()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value.clone())
            .or_else(|| std::env::var(key).ok())
    };
    if lookup(OPT_OUT_ENV).as_deref() == Some("none") {
        return ShellLaunch { command, env: extra_env };
    }
    let Some(shell) = detect_shell(&command) else {
        return ShellLaunch { command, env: extra_env };
    };
    let Some(root) = scripts_root().and_then(|root| materialize(&root).ok()) else {
        return ShellLaunch { command, env: extra_env };
    };
    apply(shell, &root, command, extra_env, &lookup)
}

fn detect_shell(command: &[String]) -> Option<Shell> {
    let exe = command.first()?;
    let name = Path::new(exe).file_name().and_then(OsStr::to_str)?;
    match name {
        // Apple's patched Bash 3.2 ignores ENV in POSIX startup, which the
        // bash injection depends on. /bin is SIP-protected, so /bin/bash on
        // macOS is always that build.
        "bash" if cfg!(target_os = "macos") && exe == "/bin/bash" => None,
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
) -> ShellLaunch {
    // The daemon integrates this shell, so it owns the Ghostty integration
    // keys: a caller value for one of them never reaches the shell.
    crate::daemon_env::warn_dropped(&crate::daemon_env::strip_integration_owned(&mut env));
    // A caller (or daemon) value is the user's resolved feature set.
    let cli_dir = ghostty_cli_dir(lookup);
    match lookup(FEATURES_ENV) {
        None => env.push((FEATURES_ENV.into(), DEFAULT_FEATURES.into())),
        Some(features) => {
            let usable = usable_features(&features, cli_dir.is_some());
            if usable != features {
                env.push((FEATURES_ENV.into(), usable));
            }
        }
    }
    if let Some(GhosttyCliDir::FromBinary(dir)) = cli_dir {
        env.push((GHOSTTY_BIN_DIR_ENV.into(), dir));
    }
    let root_str = root.to_string_lossy().into_owned();
    match shell {
        Shell::Zsh => {
            if let Some(previous) = lookup("ZDOTDIR") {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn env_of(launch: &ShellLaunch, key: &str) -> Option<String> {
        launch.env.iter().rev().find(|(name, _)| name == key).map(|(_, value)| value.clone())
    }

    fn launch(shell: &str, env: &[(&str, &str)]) -> ShellLaunch {
        let env: Vec<(String, String)> =
            env.iter().map(|(key, value)| ((*key).into(), (*value).into())).collect();
        let lookup = {
            let env = env.clone();
            move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
        };
        apply(
            detect_shell(&[shell.into()]).expect("supported shell"),
            Path::new("/state/shell-integration/abc"),
            vec![shell.into()],
            env,
            &lookup,
        )
    }

    #[test]
    fn detects_supported_shells_by_basename() {
        assert_eq!(detect_shell(&["/usr/bin/zsh".into()]), Some(Shell::Zsh));
        assert_eq!(detect_shell(&["/opt/homebrew/bin/bash".into()]), Some(Shell::Bash));
        assert_eq!(detect_shell(&["fish".into()]), Some(Shell::Fish));
        assert_eq!(detect_shell(&["/bin/sh".into()]), None);
        assert_eq!(detect_shell(&[]), None);
        if cfg!(target_os = "macos") {
            assert_eq!(detect_shell(&["/bin/bash".into()]), None);
        } else {
            assert_eq!(detect_shell(&["/bin/bash".into()]), Some(Shell::Bash));
        }
    }

    #[test]
    fn zsh_points_zdotdir_at_the_scripts_and_keeps_the_previous_one() {
        let plain = launch("zsh", &[]);
        assert_eq!(plain.command, vec!["zsh"]);
        assert_eq!(env_of(&plain, "ZDOTDIR").as_deref(), Some("/state/shell-integration/abc/zsh"));
        assert_eq!(env_of(&plain, "GHOSTTY_ZSH_ZDOTDIR"), None);

        let custom = launch("zsh", &[("ZDOTDIR", "/home/me/.config/zsh")]);
        assert_eq!(env_of(&custom, "GHOSTTY_ZSH_ZDOTDIR").as_deref(), Some("/home/me/.config/zsh"));
        assert_eq!(env_of(&custom, "ZDOTDIR").as_deref(), Some("/state/shell-integration/abc/zsh"));
    }

    #[test]
    fn bash_starts_in_posix_mode_with_env_pointing_at_the_script() {
        let bash = launch("/usr/local/bin/bash", &[("HOME", "/home/me")]);
        assert_eq!(bash.command, vec!["/usr/local/bin/bash", "--posix"]);
        assert_eq!(
            env_of(&bash, "ENV").as_deref(),
            Some("/state/shell-integration/abc/bash/ghostty.bash")
        );
        assert_eq!(env_of(&bash, "GHOSTTY_BASH_INJECT").as_deref(), Some("1"));
        assert_eq!(env_of(&bash, "HISTFILE").as_deref(), Some("/home/me/.bash_history"));
        assert_eq!(env_of(&bash, "GHOSTTY_BASH_UNEXPORT_HISTFILE").as_deref(), Some("1"));

        let with_env = launch("bash", &[("ENV", "/etc/env.sh"), ("HISTFILE", "/tmp/h")]);
        assert_eq!(env_of(&with_env, "GHOSTTY_BASH_ENV").as_deref(), Some("/etc/env.sh"));
        assert_eq!(env_of(&with_env, "HISTFILE").as_deref(), Some("/tmp/h"));
        assert_eq!(env_of(&with_env, "GHOSTTY_BASH_UNEXPORT_HISTFILE"), None);
    }

    /// The daemon integrates the default shell, so it owns the Ghostty
    /// integration keys: no caller value for one of them reaches the shell.
    #[test]
    fn a_daemon_integrated_shell_drops_caller_integration_keys() {
        let caller = [
            ("GHOSTTY_ZSH_ZDOTDIR", "/caller/zdotdir"),
            ("GHOSTTY_BASH_ENV", "/caller/env.sh"),
            ("GHOSTTY_BASH_INJECT", "caller-inject"),
            ("GHOSTTY_BASH_UNEXPORT_HISTFILE", "caller-unexport"),
            ("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", "/caller/xdg"),
        ];
        for shell in ["/usr/local/bin/bash", "zsh", "fish"] {
            let mut env = vec![("HOME", "/home/me")];
            env.extend(caller);
            let launched = launch(shell, &env);
            for (key, value) in caller {
                assert!(
                    !launched.env.iter().any(|(name, current)| name == key && current == value),
                    "{shell}: a caller {key} reached the shell: {:?}",
                    launched.env
                );
            }
        }
        let bash = launch("/usr/local/bin/bash", &[("HOME", "/home/me"), caller[2]]);
        assert_eq!(env_of(&bash, "GHOSTTY_BASH_INJECT").as_deref(), Some("1"));
    }

    #[test]
    fn fish_prepends_the_scripts_to_xdg_data_dirs() {
        let default = launch("fish", &[]);
        assert_eq!(
            env_of(&default, "XDG_DATA_DIRS").as_deref(),
            Some("/state/shell-integration/abc:/usr/local/share:/usr/share")
        );
        assert_eq!(
            env_of(&default, "GHOSTTY_SHELL_INTEGRATION_XDG_DIR").as_deref(),
            Some("/state/shell-integration/abc")
        );
        let custom = launch("fish", &[("XDG_DATA_DIRS", "/opt/share")]);
        assert_eq!(
            env_of(&custom, "XDG_DATA_DIRS").as_deref(),
            Some("/state/shell-integration/abc:/opt/share")
        );
    }

    #[test]
    fn materialize_writes_every_script_privately_and_repairs_missing_ones() {
        let base = std::env::temp_dir().join(format!(
            "cmux-tui-shell-integration-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&base).unwrap();
        let base = fs::canonicalize(&base).unwrap();
        let root = base.join("shell-integration").join(content_digest());
        materialize(&root).unwrap();
        for script in SCRIPTS {
            assert_eq!(fs::read_to_string(root.join(script.path)).unwrap(), script.contents);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(root.join("zsh")).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700);
        }
        fs::remove_file(root.join("bash/ghostty.bash")).unwrap();
        materialize(&root).unwrap();
        assert!(root.join("bash/ghostty.bash").is_file());
        // A symlink in place of a script is replaced by the real file.
        #[cfg(unix)]
        {
            let decoy = base.join("decoy");
            fs::write(&decoy, "echo hijacked\n").unwrap();
            fs::remove_file(root.join("zsh/.zshenv")).unwrap();
            std::os::unix::fs::symlink(&decoy, root.join("zsh/.zshenv")).unwrap();
            materialize(&root).unwrap();
            assert!(
                !fs::symlink_metadata(root.join("zsh/.zshenv")).unwrap().file_type().is_symlink()
            );
            assert_eq!(fs::read_to_string(&decoy).unwrap(), "echo hijacked\n");
        }
        fs::remove_dir_all(&base).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn scripts_are_refused_below_a_directory_others_can_replace() {
        use std::os::unix::fs::PermissionsExt;
        let base = std::env::temp_dir().join(format!(
            "cmux-tui-shell-integration-shared-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&base).unwrap();
        let base = fs::canonicalize(&base).unwrap();
        fs::set_permissions(&base, fs::Permissions::from_mode(0o777)).unwrap();
        let root = base.join("shell-integration").join(content_digest());
        assert!(materialize(&root).is_err());
        assert!(!base.join("shell-integration").exists());
        fs::set_permissions(&base, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(materialize(&root).unwrap(), root);
        fs::remove_dir_all(&base).unwrap();
    }

    /// Ghostty exports `GHOSTTY_SHELL_FEATURES` for every shell it starts
    /// (`setupFeatures`); without it the scripts set no title, cursor shape
    /// or path. A daemon-integrated shell gets Ghostty's defaults, and a
    /// caller value (the app's resolved `shell-integration-features`) wins.
    #[test]
    fn a_daemon_integrated_shell_gets_ghosttys_default_features() {
        for shell in ["/usr/local/bin/bash", "zsh", "fish"] {
            let launched = launch(shell, &[("HOME", "/home/me")]);
            assert_eq!(
                env_of(&launched, "GHOSTTY_SHELL_FEATURES").as_deref(),
                Some("cursor:blink,path,title"),
                "{shell}"
            );
            let configured =
                launch(shell, &[("HOME", "/home/me"), ("GHOSTTY_SHELL_FEATURES", "path")]);
            assert_eq!(
                env_of(&configured, "GHOSTTY_SHELL_FEATURES").as_deref(),
                Some("path"),
                "{shell}"
            );
        }
    }

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
        let launched = apply(Shell::Zsh, &root, vec![zsh.into()], env, &lookup);

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

    /// The scripts' ssh wrappers run `$GHOSTTY_BIN_DIR/ghostty +ssh`. A shell
    /// with the ssh features and no Ghostty CLI would wrap `ssh` around a
    /// missing program, so the features are dropped; with a CLI they stay and
    /// the shell gets `GHOSTTY_BIN_DIR`.
    #[test]
    fn ssh_features_need_a_ghostty_cli() {
        let all = "cursor:blink,path,ssh-env,ssh-terminfo,sudo,title";
        for shell in ["/usr/local/bin/bash", "zsh", "fish"] {
            let none = launch(shell, &[("HOME", "/home/me"), (FEATURES_ENV, all)]);
            assert_eq!(
                env_of(&none, FEATURES_ENV).as_deref(),
                Some("cursor:blink,path,sudo,title"),
                "{shell}"
            );
            assert_eq!(env_of(&none, "GHOSTTY_BIN_DIR"), None, "{shell}");
            let only_ssh = launch(shell, &[(FEATURES_ENV, "ssh-env,ssh-terminfo")]);
            assert_eq!(env_of(&only_ssh, FEATURES_ENV).as_deref(), Some(""), "{shell}");
            let empty_bin = launch(shell, &[(FEATURES_ENV, "ssh-env"), ("GHOSTTY_BIN", "")]);
            assert_eq!(env_of(&empty_bin, FEATURES_ENV).as_deref(), Some(""), "{shell}");

            let bin = launch(shell, &[(FEATURES_ENV, all), ("GHOSTTY_BIN", "/opt/g/bin/ghostty")]);
            assert_eq!(env_of(&bin, FEATURES_ENV).as_deref(), Some(all), "{shell}");
            assert_eq!(env_of(&bin, "GHOSTTY_BIN_DIR").as_deref(), Some("/opt/g/bin"), "{shell}");
            let dir = launch(shell, &[(FEATURES_ENV, all), ("GHOSTTY_BIN_DIR", "/opt/h/bin")]);
            assert_eq!(env_of(&dir, FEATURES_ENV).as_deref(), Some(all), "{shell}");
            assert_eq!(env_of(&dir, "GHOSTTY_BIN_DIR").as_deref(), Some("/opt/h/bin"), "{shell}");
        }
    }

    /// The embedded scripts are exactly the zsh, bash and fish injection files
    /// of ghostty-next, the Ghostty that builds ghostty-vt: a file that
    /// ghostty-next adds, removes or changes cannot be missed.
    #[test]
    fn the_embedded_scripts_are_ghostty_nexts_injection_files() {
        let tree = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../ghostty-next/src/shell-integration");
        let mut files = Vec::new();
        let mut pending: Vec<PathBuf> =
            ["zsh", "bash", "fish"].iter().map(|d| tree.join(d)).collect();
        while let Some(dir) = pending.pop() {
            for entry in fs::read_dir(&dir).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    pending.push(path);
                } else {
                    files.push(
                        path.strip_prefix(&tree).unwrap().to_string_lossy().replace('\\', "/"),
                    );
                }
            }
        }
        files.sort();
        let mut embedded: Vec<String> =
            SCRIPTS.iter().map(|script| script.path.to_string()).collect();
        embedded.sort();
        assert_eq!(files, embedded);
        for script in SCRIPTS {
            assert_eq!(
                fs::read_to_string(tree.join(script.path)).unwrap(),
                script.contents,
                "{}",
                script.path
            );
        }
    }

    /// The real shells: with the ssh features and no Ghostty CLI, `ssh` is not
    /// wrapped; with a CLI directory it is (the control that the probe sees
    /// the wrapper at all).
    #[cfg(unix)]
    #[test]
    fn a_shell_without_a_ghostty_cli_runs_plain_ssh() {
        let shells: Vec<(Shell, &str)> = [
            (Shell::Zsh, ["/bin/zsh", "/usr/bin/zsh"].into_iter().find(|p| Path::new(p).is_file())),
            (
                Shell::Bash,
                ["/usr/bin/bash", "/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"]
                    .into_iter()
                    .find(|p| Path::new(p).is_file() && detect_shell(&[(*p).into()]).is_some()),
            ),
        ]
        .into_iter()
        .filter_map(|(shell, exe)| exe.map(|exe| (shell, exe)))
        .collect();
        if shells.is_empty() {
            eprintln!("skipped: neither zsh nor a usable bash is installed");
            return;
        }
        for (shell, exe) in shells {
            let plain = probe_ssh(shell, exe, None);
            assert!(!plain.contains("function"), "{exe} without a CLI wrapped ssh: {plain:?}");
            let wrapped = probe_ssh(shell, exe, Some("/opt/g/bin"));
            assert!(wrapped.contains("function"), "{exe} with a CLI did not wrap ssh: {wrapped:?}");
        }
    }

    /// `type ssh` in an integrated interactive `shell` whose features ask for
    /// the ssh wrappers; returns what it printed.
    #[cfg(unix)]
    fn probe_ssh(shell: Shell, exe: &str, bin_dir: Option<&str>) -> String {
        use std::io::Read;
        let base = std::env::temp_dir().join(format!(
            "cmux-tui-shell-ssh-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let user = base.join("user");
        fs::create_dir_all(&user).unwrap();
        let base = fs::canonicalize(&base).unwrap();
        let user = fs::canonicalize(&user).unwrap();
        let root = materialize(&base.join("shell-integration").join(content_digest())).unwrap();
        fs::write(user.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
        fs::write(user.join(".zshrc"), "PS1='$ '\n").unwrap();
        fs::write(user.join(".bashrc"), "PS1='$ '\n").unwrap();
        let mut env = vec![
            ("HOME".to_string(), user.to_string_lossy().into_owned()),
            (FEATURES_ENV.to_string(), "ssh-env,ssh-terminfo".to_string()),
        ];
        if shell == Shell::Zsh {
            env.push(("ZDOTDIR".to_string(), user.to_string_lossy().into_owned()));
        }
        if let Some(dir) = bin_dir {
            env.push(("GHOSTTY_BIN_DIR".to_string(), dir.to_string()));
        }
        let lookup = {
            let env = env.clone();
            move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
        };
        let launched = apply(shell, &root, vec![exe.into()], env, &lookup);
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
        command.env("GHOSTTY_BIN", "");
        for (key, value) in &launched.env {
            command.env(key.clone(), value.clone());
        }
        let mut spawned = pty.spawn(command).unwrap();
        let mut reader = spawned.master.try_clone_reader().unwrap();
        let mut writer = spawned.master.take_writer().unwrap();
        let (chunks, received) = std::sync::mpsc::channel::<Vec<u8>>();
        std::thread::spawn(move || {
            let mut chunk = [0u8; 4096];
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
                        "no {:?} from {exe}: {:?}",
                        String::from_utf8_lossy(needle),
                        String::from_utf8_lossy(output)
                    ),
                }
            }
        };
        read_until(&mut output, b"$ ");
        // The end marker's echoed text (`ssh-$((40+2))`) differs from its output.
        writer.write_all(b"type ssh 2>&1 | head -n 1; echo ssh-$((40+2))\n").unwrap();
        read_until(&mut output, b"ssh-42\r\n");
        writer.write_all(b"exit\n").unwrap();
        drop(writer);
        while spawned.child.try_wait().unwrap().is_none() {
            assert!(std::time::Instant::now() < deadline, "{exe} did not exit");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        drop(spawned);
        fs::remove_dir_all(&base).unwrap();
        let text = String::from_utf8_lossy(&output).into_owned();
        // Only the probe's own output: after its echoed line, before the marker.
        let start = text.find("ssh-$((40+2))").map_or(0, |at| at + "ssh-$((40+2))".len());
        let end = text.rfind("ssh-42").unwrap_or(text.len());
        text[start..end.max(start)].to_string()
    }

    #[test]
    fn opt_out_leaves_the_launch_unchanged() {
        let launch =
            integrate_default_shell(vec!["zsh".into()], vec![(OPT_OUT_ENV.into(), "none".into())]);
        assert_eq!(launch.command, vec!["zsh"]);
        assert_eq!(launch.env, vec![(OPT_OUT_ENV.to_string(), "none".to_string())]);
    }
}
