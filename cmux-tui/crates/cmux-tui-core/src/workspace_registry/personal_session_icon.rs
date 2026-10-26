//! A machine's icon on the home session registry (`session-icon-v1`): the
//! sidebar shows each `list-personal` session record (this daemon's own, and
//! one per remote transport the app syncs with `put-session`) as a machine,
//! and its `icon` is the shared icon string. Only `set-session-icon` writes
//! it; the `put-session` upsert names its columns and never touches it.

use rusqlite::params;
use serde_json::json;

use super::WorkspaceRegistry;
use super::personal_store::{
    PersonalSession, commit_personal, read_session, require_icon_asset, subject,
    validate_session_id,
};

impl WorkspaceRegistry {
    /// Set (`Some`) or clear (`None`) the icon of the known session
    /// `session`. An asset icon must name a stored blob, checked in this
    /// transaction so no blob sweep runs in between. Returns the record and
    /// whether anything changed; an unchanged icon commits nothing.
    #[track_caller]
    pub fn set_session_icon(
        &mut self,
        session: &str,
        icon: Option<&str>,
    ) -> anyhow::Result<(PersonalSession, bool)> {
        validate_session_id(session)?;
        if let Some(icon) = icon {
            super::presentation_store::validate_icon_value(icon)?;
        }
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let before = read_session(&tx, session)?
            .ok_or_else(|| anyhow::anyhow!("unknown session {session}"))?;
        if let Some(icon) = icon {
            require_icon_asset(&tx, icon)?;
        }
        let changed = before.icon.as_deref() != icon;
        let mut after = before;
        if changed {
            tx.execute(
                "UPDATE sessions SET icon = ?2 WHERE session_id = ?1",
                params![session, icon],
            )?;
            after.icon = icon.map(str::to_string);
            commit_personal(
                &tx,
                "personal.session.updated",
                vec![subject("session", session)],
                &json!({"session": after}),
            )?;
        }
        tx.commit()?;
        Ok((after, changed))
    }
}
