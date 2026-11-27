//! The name that a session reset gives the folder that it deletes, for the
//! rollback's check (`store_schemas`). The reset's own code is in
//! `session_reset.rs`.

use super::session_reset::is_canonical_reset_uuid_v4;

/// True for the name that a reset gives the folder that it deletes, of any
/// session: `.reset-<session>-<kind>-<id>.deleting`
/// (`rename_reset_dir_for_deletion` in `session_reset.rs`). A reset that did
/// not end leaves that folder in the state root, and the next reset of that
/// session deletes it (`pending_session_reset_dirs`). No open of a session
/// opens a folder with such a name. The reset itself can put the folder back
/// under the session's name: it does that when its look after the rename
/// fails. The folder of a session never has such a name: its name starts
/// with no dot.
pub(crate) fn is_pending_reset_dir_name(file_name: &str) -> bool {
    let Some(rest) =
        file_name.strip_prefix(".reset-").and_then(|rest| rest.strip_suffix(".deleting"))
    else {
        return false;
    };
    // The session's part can hold `-`: the kind and the id are the end, as
    // `pending_session_reset_kind` reads them.
    ["-session-", "-terminal-hosts-"]
        .iter()
        .any(|kind| rest.rsplit_once(*kind).is_some_and(|(_, id)| is_canonical_reset_uuid_v4(id)))
}
