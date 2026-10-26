//! Where the session owner's panic log lives (cx-urd.59). The owner's panic
//! hook appends to it (cmux-tui `owner_start/owner_panic.rs`) and
//! `oracle-state` reports it, so both read the one path rule here.

use std::path::PathBuf;

/// The log for `session`: `owner-panics-<session>.jsonl` at the state root
/// (the parent of the sessions directory). A session name that needs
/// escaping gets a hash suffix, so two names never share a log.
pub fn owner_panic_log_path(session: &str) -> Option<PathBuf> {
    let sessions = crate::platform::workspace_state_dir()?;
    let root = sessions.parent().map(PathBuf::from).unwrap_or(sessions);
    let safe: String = session
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '-' })
        .collect();
    let name = if safe == session {
        safe
    } else {
        // FNV-1a: stable across builds, no dependency.
        let hash = session.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3)
        });
        format!("{safe}-{:08x}", hash as u32)
    };
    Some(root.join(format!("owner-panics-{name}.jsonl")))
}
