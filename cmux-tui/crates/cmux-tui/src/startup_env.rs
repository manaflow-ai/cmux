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
    unsafe { cmux_link::token::take_from_process_env() };
    // SAFETY: as above.
    unsafe { cmux_tui_core::server::take_chief_tools_socket_from_env() };
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
    unsafe { cmux_tui_core::server::take_chief_tools_socket_from_env() };
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

/// The brain tools socket this process was started with (see above).
pub(crate) fn chief_tools_socket() -> Option<PathBuf> {
    CHIEF_TOOLS_SOCKET.get().cloned().flatten()
}
