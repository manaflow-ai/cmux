//! Settings this process reads from its environment and removes before any
//! thread starts, so no child it spawns inherits them.

use std::path::PathBuf;

use super::{CLOUD_TEMPLATE_ENV, CloudTemplateEnv};

/// Reads `CMUX_LINK_TOKEN_VERIFIER` into the link's once-only setting and
/// removes it from the process environment (cloud-client-contract.md 1.7,
/// G3/G4). Also takes the brain's tools socket (`CMUX_TUI_CHIEF_TOOLS_SOCKET`,
/// chief-inspect) the same way, so no shell, agent or hook the daemon spawns
/// learns the path.
///
/// # Safety
///
/// The caller must call this as the first statement of `main`, while no
/// other thread exists: removing an environment variable is unsound while
/// another thread can read the environment.
#[cfg(unix)]
pub(crate) unsafe fn take_link_token_from_env() {
    remember_chief_tools_socket();
    // The first-party app directory override is for this process only
    // (cx-e0cs): no shell, agent or server the daemon spawns inherits it.
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { cmux_tui_core::first_party_dir::take_from_process_env() };
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { take_launch_credential() };
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { cmux_link::token::take_from_process_env() };
    // SAFETY: as above.
    unsafe { cmux_tui_core::server::take_chief_tools_socket_from_env() };
    // SAFETY: as above.
    unsafe { cmux_tui_core::chief_brains::take_from_env() };
    // SAFETY: as above.
    unsafe { take_owner_app_pid() };
    // SAFETY: as above.
    #[cfg(target_os = "linux")]
    unsafe {
        capture_systemd_listen_env();
    }
}

/// cmux-link and its token verifier exist only on unix; nothing to take.
///
/// # Safety
///
/// No requirement on these targets; `unsafe` keeps the call site identical
/// on every platform.
#[cfg(not(unix))]
pub(crate) unsafe fn take_link_token_from_env() {
    remember_chief_tools_socket();
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { cmux_tui_core::first_party_dir::take_from_process_env() };
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { take_launch_credential() };
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { cmux_tui_core::server::take_chief_tools_socket_from_env() };
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { cmux_tui_core::chief_brains::take_from_env() };
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { take_owner_app_pid() };
}

/// Read the Cloud template settings and remove them from this process's
/// environment, so no terminal host, shell, agent, or plugin it spawns
/// inherits them. Must run before any thread starts.
pub(crate) fn take_cloud_template_env() {
    const KEYS: [&str; 3] = [
        "CMUX_TUI_ADOPT_TEMPLATE_TERMINAL",
        "CMUX_TUI_TEMPLATE_BOUND_FILE",
        "CMUX_TUI_TEMPLATE_WORKSPACE_NAME",
    ];
    let settings = CloudTemplateEnv {
        adopt: std::env::var(KEYS[0]).is_ok_and(|value| value == "1"),
        bound_file: std::env::var_os(KEYS[1]).filter(|value| !value.is_empty()).map(PathBuf::from),
        workspace_name: std::env::var(KEYS[2]).ok().filter(|value| !value.is_empty()),
    };
    for key in KEYS {
        // SAFETY: called first in run_main, before this process starts any
        // thread, so no other thread can read the environment concurrently.
        unsafe { std::env::remove_var(key) };
    }
    let _ = CLOUD_TEMPLATE_ENV.set(settings);
}

/// The `CMUX_TUI_CHIEF_TOOLS_SOCKET` this process started with, kept before
/// `take_link_token_from_env` removes it, so `server ensure` hands it to the
/// owner it spawns (OwnerSpec.chief_tools_socket): the variable is removed
/// from this process, so the owner would not inherit it.
static CHIEF_TOOLS_SOCKET: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();

fn remember_chief_tools_socket() {
    let value = std::env::var_os("CMUX_TUI_CHIEF_TOOLS_SOCKET")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);
    let _ = CHIEF_TOOLS_SOCKET.set(value);
}

/// The terminal launch credential this process was started with
/// (plans/cmux-next/identity.md section 2). It names the one terminal that
/// started this process, so it is taken out of the environment at once: a
/// daemon, owner, TUI or helper this process starts never acts as that
/// terminal, and only the CLI sends it, to that terminal's own session.
static LAUNCH_CREDENTIAL: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();

/// # Safety
///
/// As [`take_link_token_from_env`]: no other thread may exist yet.
unsafe fn take_launch_credential() {
    let name = cmux_tui_core::launch_credential::LAUNCH_CREDENTIAL_ENV;
    let value = std::env::var(name).ok().filter(|value| !value.is_empty());
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { std::env::remove_var(name) };
    let _ = LAUNCH_CREDENTIAL.set(value);
}

/// The launch credential this process was started with (see above).
pub(crate) fn launch_credential() -> Option<String> {
    LAUNCH_CREDENTIAL.get().cloned().flatten()
}

/// The process id of the app that owns this owner (`server_lifecycle.rs`): the
/// app sets it for the `server ensure` it runs, which hands it to the owner it
/// spawns (`local_owner.rs`). Taken out of the environment at once, so no
/// shell, agent or owner started from a terminal claims the app as its own.
pub(crate) const OWNER_APP_PID_ENV: &str = "CMUX_TUI_OWNER_APP_PID";
static OWNER_APP_PID: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();

/// # Safety
///
/// As [`take_link_token_from_env`]: no other thread may exist yet.
unsafe fn take_owner_app_pid() {
    let value = std::env::var(OWNER_APP_PID_ENV).ok().filter(|value| !value.is_empty());
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { std::env::remove_var(OWNER_APP_PID_ENV) };
    let _ = OWNER_APP_PID.set(value);
}

/// The systemd socket-activation variables (sd_listen_fds(3)) this process
/// started with. They are taken out of the environment at once, as
/// `sd_listen_fds(unset_environment = 1)` does, so no child inherits a
/// `LISTEN_PID` naming this process; `provider_authority::take_management_listener`
/// takes them later, after the server has started threads.
#[cfg(target_os = "linux")]
#[derive(Clone, Default)]
pub(crate) struct SystemdListenEnv {
    pub(crate) pid: Option<String>,
    pub(crate) fds: Option<String>,
    pub(crate) names: Option<String>,
}

#[cfg(target_os = "linux")]
static SYSTEMD_LISTEN_ENV: std::sync::OnceLock<SystemdListenEnv> = std::sync::OnceLock::new();
#[cfg(target_os = "linux")]
static SYSTEMD_LISTEN_ENV_TAKEN: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// # Safety
///
/// As [`take_link_token_from_env`]: no other thread may exist yet.
#[cfg(target_os = "linux")]
unsafe fn capture_systemd_listen_env() {
    const KEYS: [&str; 3] = ["LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"];
    let [pid, fds, names] = KEYS.map(|key| std::env::var(key).ok());
    for key in KEYS {
        // SAFETY: forwarded from this function's own contract (see # Safety).
        unsafe { std::env::remove_var(key) };
    }
    let _ = SYSTEMD_LISTEN_ENV.set(SystemdListenEnv { pid, fds, names });
}

/// The systemd socket-activation variables this process started with, to the
/// first caller only: the descriptors they name have one owner.
#[cfg(target_os = "linux")]
pub(crate) fn take_systemd_listen_env() -> SystemdListenEnv {
    if SYSTEMD_LISTEN_ENV_TAKEN.swap(true, std::sync::atomic::Ordering::AcqRel) {
        return SystemdListenEnv::default();
    }
    SYSTEMD_LISTEN_ENV.get().cloned().unwrap_or_default()
}

/// The owning app's pid this process was started with (see above).
pub(crate) fn owner_app_pid() -> Option<String> {
    OWNER_APP_PID.get().cloned().flatten()
}

/// The brain tools socket this process was started with (see above).
pub(crate) fn chief_tools_socket() -> Option<PathBuf> {
    CHIEF_TOOLS_SOCKET.get().cloned().flatten()
}

/// Agent caller claims (cx-4nar). An owner an agent started (a Chief turn,
/// an acpmux session) must not pass them to a person's terminals in it, or
/// `--all-sessions` there refuses the person (cli/federation.rs
/// `agent_marker`). acpmux sets the first three in every agent (agent.rs
/// `spawn`); the Chief's turn env sets the owner socket (optchat-chief
/// cmux_env.rs), a route to the Chief's own owner; cmux-tasks reads the
/// principal, class and harness (owner.rs). The one list for both owner
/// starts: a detached owner drops them from its command
/// (local_owner.rs `configure_detached_owner_environment`), a foreground
/// owner from its own environment (`take_agent_caller_env`).
pub(crate) const AGENT_CALLER_ENV: [&str; 7] = [
    "ACPMUX_ENV",
    "ACPMUX_SESSION_ID",
    "ACPMUX_SESSION_NAME",
    "CMUX_CHIEF_OWNER_SOCKET",
    "CMUX_AGENT_PRINCIPAL",
    "CMUX_AGENT_CLASS",
    "CMUX_AGENT_HARNESS",
];

/// Remove the agent caller claims from this process's environment when it
/// runs as a foreground owner (`server start`, `--headless`, the
/// interactive mux), so no terminal host, shell or hook it spawns inherits
/// them. The process acts for the person whose terminals it hosts, not for
/// the agent that started it.
///
/// # Safety
///
/// The caller must call this while no other thread exists: removing an
/// environment variable is unsound while another thread can read the
/// environment.
pub(crate) unsafe fn take_agent_caller_env() {
    for key in AGENT_CALLER_ENV {
        // SAFETY: forwarded from this function's own contract (see # Safety).
        unsafe { std::env::remove_var(key) };
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    /// Descriptor 3 has one owner: only the first take sees the variables.
    #[test]
    fn systemd_listen_env_is_taken_once() {
        let _ = SYSTEMD_LISTEN_ENV.set(SystemdListenEnv {
            pid: Some("1".into()),
            fds: Some("1".into()),
            names: Some("cmux-provider-authority".into()),
        });
        let first = take_systemd_listen_env();
        assert_eq!(first.fds.as_deref(), Some("1"));
        let second = take_systemd_listen_env();
        assert!(second.pid.is_none() && second.fds.is_none() && second.names.is_none());
    }
}
