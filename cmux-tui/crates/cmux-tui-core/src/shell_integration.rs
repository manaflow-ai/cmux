//! Automatic shell integration for the interactive shells cmux-tui launches.
//!
//! The embedded terminal is ghostty-vt, which reflows the primary screen on
//! every resize and clears a redrawable prompt so the shell can repaint it.
//! Both depend on OSC 133 semantic prompt marks. Without them the terminal
//! cannot tell a prompt from output, so each SIGWINCH redraw lands on reflowed
//! cells and leaves prompt fragments behind. Ghostty emits those marks by
//! injecting its shell integration scripts when it spawns a shell; this module
//! does the same for cmux-tui, using the scripts from the Ghostty submodule
//! that builds ghostty-vt so both halves always match.
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
        contents: include_str!("../../../../ghostty/src/shell-integration/zsh/.zshenv"),
    },
    Script {
        path: "zsh/ghostty-integration",
        contents: include_str!("../../../../ghostty/src/shell-integration/zsh/ghostty-integration"),
    },
    Script {
        path: "bash/ghostty.bash",
        contents: include_str!("../../../../ghostty/src/shell-integration/bash/ghostty.bash"),
    },
    Script {
        path: "bash/bash-preexec.sh",
        contents: include_str!("../../../../ghostty/src/shell-integration/bash/bash-preexec.sh"),
    },
    Script {
        path: "fish/vendor_conf.d/ghostty-shell-integration.fish",
        contents: include_str!(
            "../../../../ghostty/src/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"
        ),
    },
];

/// Opt-out: `CMUX_TUI_SHELL_INTEGRATION=none` launches shells unmodified.
const OPT_OUT_ENV: &str = "CMUX_TUI_SHELL_INTEGRATION";

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
/// belong to this user and must not be symlinks; otherwise the launch goes
/// ahead without integration.
fn materialize(root: &Path) -> io::Result<PathBuf> {
    let container = root.parent().ok_or_else(|| io::Error::other("scripts root has no parent"))?;
    if let Some(base) = container.parent() {
        fs::create_dir_all(base)?;
    }
    ensure_private_dir(container)?;
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
            assert!(!fs::symlink_metadata(root.join("zsh/.zshenv")).unwrap().file_type().is_symlink());
            assert_eq!(fs::read_to_string(&decoy).unwrap(), "echo hijacked\n");
        }
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn opt_out_leaves_the_launch_unchanged() {
        let launch =
            integrate_default_shell(vec!["zsh".into()], vec![(OPT_OUT_ENV.into(), "none".into())]);
        assert_eq!(launch.command, vec!["zsh"]);
        assert_eq!(launch.env, vec![(OPT_OUT_ENV.to_string(), "none".to_string())]);
    }
}
