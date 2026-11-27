//! The environment of a new workspace's first terminal (`WorkspaceSpawn.terminalEnvironment`) and the
//! placement keys agent hooks and the `cmux` CLI read in it (`DaemonConnection.placementEnvironment`).

use std::collections::BTreeMap;

/// The terminal's tab id, in the old app's form.
pub const SURFACE_KEY: &str = "CMUX_SURFACE_ID";
/// The same id under the old app's second name.
pub const PANEL_KEY: &str = "CMUX_PANEL_ID";
/// The workspace key, in the old app's form; only when the workspace is known.
pub const WORKSPACE_KEY: &str = "CMUX_WORKSPACE_ID";

/// Uppercase 8-4-4-4-12 form of a UUID or 32-hex id (the old app's ids); any other `raw` comes back
/// as it is. Dashes anywhere are dropped first, so a dashed UUID and its bare hex give one form.
pub fn uuid_form(raw: &str) -> String {
    let hex: String = raw.chars().filter(|c| *c != '-').collect::<String>().to_uppercase();
    if hex.chars().count() != 32 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return raw.to_owned();
    }
    let mut out = String::with_capacity(36);
    for (index, c) in hex.chars().enumerate() {
        if matches!(index, 8 | 12 | 16 | 20) {
            out.push('-');
        }
        out.push(c);
    }
    out
}

/// The placement keys for a terminal with id `terminal`: `CMUX_SURFACE_ID` and `CMUX_PANEL_ID`, and
/// `CMUX_WORKSPACE_ID` only when `workspace` is known.
pub fn placement_environment(workspace: Option<&str>, terminal: &str) -> BTreeMap<String, String> {
    let surface = uuid_form(terminal);
    let mut env = BTreeMap::new();
    env.insert(SURFACE_KEY.to_owned(), surface.clone());
    env.insert(PANEL_KEY.to_owned(), surface);
    if let Some(workspace) = workspace {
        env.insert(WORKSPACE_KEY.to_owned(), uuid_form(workspace));
    }
    env
}

/// The first terminal's environment: `app` (this Mac's launch identity; empty on a Cloud machine),
/// then the room's `room`, then the caller's `caller`, then the placement keys of `workspace` and
/// `terminal`; a later one wins.
pub fn terminal_environment(
    app: &BTreeMap<String, String>,
    room: Option<&BTreeMap<String, String>>,
    caller: &BTreeMap<String, String>,
    workspace: &str,
    terminal: &str,
) -> BTreeMap<String, String> {
    let mut vars = app.clone();
    if let Some(room) = room {
        vars.extend(room.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    vars.extend(caller.iter().map(|(k, v)| (k.clone(), v.clone())));
    vars.extend(placement_environment(Some(workspace), terminal));
    vars
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_form_dashes_32_hex() {
        assert_eq!(
            uuid_form("0123456789abcdef0123456789abcdef"),
            "01234567-89AB-CDEF-0123-456789ABCDEF"
        );
        assert_eq!(
            uuid_form("01234567-89ab-cdef-0123-456789abcdef"),
            "01234567-89AB-CDEF-0123-456789ABCDEF"
        );
        assert_eq!(uuid_form("ws-1"), "ws-1");
        assert_eq!(
            uuid_form("0123456789abcdef0123456789abcdeg"),
            "0123456789abcdef0123456789abcdeg"
        );
        assert_eq!(uuid_form(""), "");
    }
}
