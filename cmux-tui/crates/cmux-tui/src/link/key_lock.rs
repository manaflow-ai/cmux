//! The link's hold on this machine's WireGuard key (`cmux_link::key_holder`):
//! `serve` takes the lock before it reads its key and keeps it for its life.
//!
//! Where: `serve --key-lock-dir D` when given. `ensure` and `install-agent`
//! always give it, resolved in the app's own process, which has the app's
//! environment: a `serve` that launchd starts has none of it (no
//! `CMUX_TUI_STATE_DIR`, no `ACPMUX_HOME`), so it must not guess. Without the
//! flag (a hand-run `serve`), the rule below decides.
//!
//! The rule: a link on its app's own state directory (`<CMUX_TUI_STATE_DIR>/link`,
//! what the app starts) shares the lock with that app's acpmux, in its
//! acpmux home ([`crate::acp::key_lock_home`]): `ACPMUX_HOME`, else
//! `~/.acpmux` for release and channel builds and `~/.acpmux/builds/<key>`
//! for a tagged DEV build. A link on any other state directory, or outside
//! any app without `ACPMUX_HOME` (a test, a hand-run link), has a key of its
//! own and locks in its state directory.
//!
//! Which acpmux home a link adopts the node key of (`key_adoption.rs`) is
//! recorded the same way: `init`, `ensure` and `install-agent` write the home
//! they resolved ([`record_home`]) into the link's state directory, and `serve`
//! trusts only that record, never its own environment.

use std::path::{Path, PathBuf};

use anyhow::anyhow;
use cmux_link::key_holder::{KeyHolder, KeyHolderError};
use serde_json::json;

use super::ensure::ReadyPipe;
use super::state::{self, LinkState};

/// How long `serve` waits for acpmux's WireGuard transport to hand over the key lock (it asks
/// every 2 s); well inside `ensure`'s start budget.
const HANDOFF_WAIT: std::time::Duration = std::time::Duration::from_secs(8);

/// The flag that names the lock directory to `serve`.
pub(super) const FLAG: &str = "--key-lock-dir";

/// The lock for `state`'s link, in `explicit` (`--key-lock-dir`) when given.
/// When another process holds it (acpmux's Labs WireGuard transport), the
/// link does not serve: the holder's pid goes on the ready pipe (`ensure`
/// reports it) and in the error.
pub(super) fn take(
    state: &LinkState,
    explicit: Option<&Path>,
    ready: &mut Option<ReadyPipe>,
) -> anyhow::Result<KeyHolder> {
    let dir = explicit.map_or_else(|| lock_dir(state), Path::to_path_buf);
    // A lock in the acpmux home this link adopts from may be held by acpmux's WireGuard
    // transport, started before this link was set up: it hands the lock over once it sees the
    // link (`Transport::yield_to_link`, every 2 s). Wait that long, never more.
    let hands_over = acpmux::cli::mesh_node_key::recorded_home(state.dir())
        .is_some_and(|home| same_dir(&home, &dir));
    let deadline = std::time::Instant::now() + HANDOFF_WAIT;
    let mut acquired = KeyHolder::acquire(&dir);
    while hands_over
        && matches!(acquired, Err(KeyHolderError::KeyHeld { .. }))
        && std::time::Instant::now() < deadline
    {
        std::thread::sleep(std::time::Duration::from_millis(200));
        acquired = KeyHolder::acquire(&dir);
    }
    match acquired {
        Ok(holder) => Ok(holder),
        Err(KeyHolderError::KeyHeld { pid }) => {
            let message = held_message(pid, &dir);
            if let Some(ready) = ready.take() {
                ready.send(&json!({
                    "event": "link-failed",
                    "error": "key_held",
                    "holder_pid": pid,
                    "message": message,
                }));
            }
            Err(anyhow!("key_held: {message}"))
        }
        Err(KeyHolderError::Io(error)) => {
            Err(anyhow!("lock this machine's WireGuard key in {}: {error}", dir.display()))
        }
    }
}

/// What `serve` and `ensure` say when another process holds the key.
fn held_message(pid: Option<u32>, dir: &Path) -> String {
    let holder = pid.map_or_else(|| "another process".to_owned(), |pid| format!("process {pid}"));
    format!(
        "{holder} holds this machine's WireGuard key (lock in {}), so this link does not serve; \
         it is most likely acpmux with transport.wireguard on",
        dir.display()
    )
}

/// The lock directory for `state`'s link by this process's environment: what
/// `ensure` and `install-agent` pass to `serve` as [`FLAG`].
pub(super) fn lock_dir(state: &LinkState) -> PathBuf {
    acpmux_home(state).unwrap_or_else(|| state.dir().to_path_buf())
}

/// The acpmux home `state`'s link shares the lock with, by this process's
/// environment: only a link on its app's own state directory has one.
fn acpmux_home(state: &LinkState) -> Option<PathBuf> {
    let own = state::default_dir().is_some_and(|own| same_dir(&own, state.dir()));
    own.then(crate::acp::key_lock_home).flatten()
}

/// Record, from the app's own process (`init`, `ensure`, `install-agent`),
/// the acpmux home [`lock_dir`] resolves for `state`'s link, or that it has
/// none (`acpmux::cli::mesh_node_key::record_link_home`). `serve` adopts only
/// that recorded home's node key: launchd starts it with none of the app's
/// environment, so it never resolves the home itself.
pub(super) fn record_home(state: &LinkState) -> anyhow::Result<()> {
    acpmux::cli::mesh_node_key::record_link_home(state.dir(), acpmux_home(state).as_deref())
}

fn same_dir(a: &Path, b: &Path) -> bool {
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    canonical(a) == canonical(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// launchd starts `serve` with none of the app's environment, so the
    /// agent's arguments carry the lock directory resolved in the app.
    #[test]
    fn the_launchd_agent_arguments_carry_the_key_lock_dir() {
        let dir = tempfile::tempdir().unwrap();
        let state = LinkState::open(Some(dir.path().join("link"))).unwrap();
        let arguments = super::super::agent_arguments(&state, &super::super::Flags::new());
        let at = arguments.iter().position(|argument| argument == FLAG).expect("no --key-lock-dir");
        assert_eq!(arguments[at + 1], lock_dir(&state).to_string_lossy());
        assert_eq!(arguments[..2], ["link", "serve"]);
    }
}
