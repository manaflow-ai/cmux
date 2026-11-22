//! Plugin builds: a scrubbed environment, its own process group, and a
//! deadline that kills the whole group.

use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use super::{PLUGIN_BUILD_TIMEOUT, PluginManifest};

#[cfg(test)]
pub(super) fn is_sensitive_env_name(name: &str) -> bool {
    let name = name.to_ascii_uppercase();
    name.contains("TOKEN")
        || name.contains("PASSWORD")
        || name.contains("SECRET")
        || name.contains("PRIVATE_KEY")
        || name.contains("ACCESS_KEY")
        || name.contains("AUTH_SOCK")
        || name == "DOCKER_AUTH_CONFIG"
        || name == "API_KEY"
        || name.ends_with("_API_KEY")
        || name == "AUTHORIZATION"
}

pub(super) fn is_safe_plugin_build_env_name(name: &str) -> bool {
    matches!(
        name,
        "PATH"
            | "HOME"
            | "TMPDIR"
            | "LANG"
            | "LC_ALL"
            | "LC_CTYPE"
            | "TERM"
            | "CI"
            | "RUSTUP_HOME"
            | "RUSTUP_TOOLCHAIN"
            | "CARGO_HOME"
            | "CARGO_BUILD_TARGET"
            | "RUSTFLAGS"
    ) || name.starts_with("LC_")
}

fn scrub_plugin_build_environment(command: &mut Command) {
    for (key, _) in std::env::vars_os() {
        if !is_safe_plugin_build_env_name(&key.to_string_lossy()) {
            command.env_remove(key);
        }
    }
}

fn kill_plugin_build_process(child: &mut Child) {
    #[cfg(unix)]
    {
        if let Ok(group) = libc::pid_t::try_from(child.id()) {
            // The build runs in its own process group, so a timeout also
            // removes descendants such as package-manager subprocesses.
            // SAFETY: this is the process group created for this child.
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
    }
    let _ = child.kill();
}

pub(super) fn run_plugin_build_command(
    command: &mut Command,
    timeout: Duration,
) -> anyhow::Result<()> {
    let mut child = command.spawn()?;
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait()? {
            if !status.success() {
                anyhow::bail!("build command failed with status {status}");
            }
            return Ok(());
        }
        if Instant::now() >= deadline {
            kill_plugin_build_process(&mut child);
            let _ = child.wait();
            anyhow::bail!("build command timed out after {:.1} seconds", timeout.as_secs_f64());
        }
        thread::sleep(Duration::from_millis(100));
    }
}

pub(super) fn run_build_if_needed(manifest: &PluginManifest, dir: &Path) -> anyhow::Result<()> {
    let Some(build) = &manifest.build else { return Ok(()) };
    let mut command = Command::new(&build.command[0]);
    command.args(&build.command[1..]).current_dir(dir).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    scrub_plugin_build_environment(&mut command);
    run_plugin_build_command(&mut command, PLUGIN_BUILD_TIMEOUT)
}
