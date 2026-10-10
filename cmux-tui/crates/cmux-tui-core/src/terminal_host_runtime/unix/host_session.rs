//! The first steps of a spawned `__terminal-host` (cx-g1fa.4): leave the
//! daemon's session and take back the open-file limit cmux started with.
//!
//! The daemon starts a standby host with `posix_spawn` (no `pre_exec`), so
//! the spawn does not `fork()` the daemon: a fork copies the page tables and
//! the mappings of every daemon thread (two per terminal) under the mm lock,
//! which grew with the terminal count (66 ms per create at 2000 terminals).
//! `posix_spawn` cannot run `setsid(2)` or `setrlimit(2)` in the child, so
//! the host runs them itself before anything else. Until `setsid` returns
//! (exec, loader and runtime start: milliseconds on macOS) the new host still
//! shares the daemon's session and process group; a group signal in that
//! window can end only a standby host, which owns no PTY yet. A failed
//! `setsid` stops the host with an error.
//!
//! The limit travels in an environment variable, not an argument: a host
//! binary of another build (a macOS bundle rebuilt in place) ignores it
//! instead of refusing an unknown argument. The host removes it before it
//! starts its shell.

use super::*;

/// The environment variable that carries the soft `RLIMIT_NOFILE` cmux
/// started with.
const NOFILE_SOFT_ENV: &str = "CMUX_TUI_HOST_NOFILE_SOFT";

/// The environment a spawned host takes (nothing when the daemon did not
/// raise its limit).
pub(crate) fn host_session_env() -> Option<(&'static str, String)> {
    cmux_pty::original_open_file_limit().map(|soft| (NOFILE_SOFT_ENV, soft.to_string()))
}

/// The flag that names the app that spawned a host (cx-hostorphan): with no
/// path in the command line (cx-0tgl LF), `ps`, leak audits and benches
/// still see which app and tag a host belongs to.
pub(crate) const OWNER_FLAG: &str = "--owner";

/// `--owner <bundle>:<tag>@<daemon pid>` for a spawned host's command line.
/// The bundle is `CMUX_BUNDLE_ID`, else the name of the `.app` that holds
/// the daemon without its suffix; the tag is `CMUX_TAG`; `-` when unknown.
/// Each part keeps only `[A-Za-z0-9._-]` (others become `_`), so the value
/// never holds a path, a space or `.app/`: `pkill -f "<app>.app"` still
/// matches no host.
pub(crate) fn host_owner_args() -> [String; 2] {
    static OWNER: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    let owner = OWNER.get_or_init(|| {
        let env = |name: &str| std::env::var(name).ok().filter(|value| !value.trim().is_empty());
        let bundle = env("CMUX_BUNDLE_ID").or_else(|| {
            let exe = std::env::current_exe().ok()?;
            exe.components().find_map(|part| {
                part.as_os_str().to_str()?.strip_suffix(".app").map(str::to_owned)
            })
        });
        format!(
            "{}:{}@{}",
            owner_part(bundle.as_deref()),
            owner_part(env("CMUX_TAG").as_deref()),
            std::process::id()
        )
    });
    [OWNER_FLAG.to_owned(), owner.clone()]
}

fn owner_part(value: Option<&str>) -> String {
    let Some(value) = value else { return "-".to_owned() };
    value
        .chars()
        .take(96)
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '_' })
        .collect()
}

/// Leave the daemon's session, restore the open-file limit, then strip every
/// inherited descriptor ([`isolate_terminal_host_process_fds`]). A host
/// already in its own session (an adopting host's launcher still runs
/// `setsid` itself) keeps it.
pub fn enter_terminal_host_process() -> anyhow::Result<()> {
    // SAFETY: getpid/getsid/setsid take no pointers; the host is still
    // single-threaded here.
    let own_session = unsafe { libc::getsid(0) == libc::getpid() };
    if !own_session && unsafe { libc::setsid() } < 0 {
        return Err(std::io::Error::last_os_error())
            .context("terminal host could not leave the daemon's session");
    }
    if let Some(soft) = std::env::var_os(NOFILE_SOFT_ENV) {
        // SAFETY: the host is still single-threaded: no other thread reads
        // the environment while this removes the variable its shell must
        // not inherit.
        unsafe { std::env::remove_var(NOFILE_SOFT_ENV) };
        let soft = soft
            .to_str()
            .and_then(|soft| soft.parse::<u64>().ok())
            .with_context(|| format!("invalid {NOFILE_SOFT_ENV}"))?;
        cmux_pty::restore_open_file_limit(soft)
            .context("terminal host could not restore its open-file limit")?;
    }
    isolate_terminal_host_process_fds()
}
