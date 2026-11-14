//! A cached projection of durable transfer events, never a second revocation authority.
//! Startup reads it once (including closed chats); info only reads the cached result.

use super::*;

impl Session {
    /// Whether durable transfer history denies opening this chat here. Unknown while its
    /// restored log is unread or unreadable; callers must not treat unknown as permission.
    pub fn transfer_blocked(&self) -> Option<bool> {
        self.transfer_authority
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .map(|(_, blocked)| blocked)
    }

    pub(super) fn note_transfer_event(&self, record: &EventRecord) {
        if let Some(blocked) = transfer_state(record) {
            self.note_transfer_authority(record.seq, blocked);
        }
    }

    fn note_transfer_authority(&self, seq: u64, blocked: bool) {
        let mut latest = self.transfer_authority.lock().unwrap_or_else(|e| e.into_inner());
        // A new append may race the startup scan. An older replay cannot revoke an abort
        // or undo a new move that was durably appended while the scan was running.
        if latest.is_none_or(|(seen, _)| seq >= seen) {
            *latest = Some((seq, blocked));
        }
    }
}

/// Only the daemon's own records decide: an agent's update (`dir: "in"`) may carry any kind.
fn transfer_state(record: &EventRecord) -> Option<bool> {
    if record.dir != "mux" {
        return None;
    }
    match record.kind.as_str() {
        "transfer_out" | "transferred" => Some(true),
        "transfer_aborted" | "imported" => Some(false),
        _ => None,
    }
}

impl Hub {
    /// The record kinds [`transfer_state`] reads.
    pub(crate) const TRANSFER_KINDS: &[&str] =
        &["transfer_out", "transferred", "transfer_aborted", "imported"];

    pub(super) fn restore_transfer_authority(&self, session: &Session) {
        self.restore_transfer_authority_after(session, None);
    }

    /// [`Self::restore_transfer_authority`] of the records past a restore point, from its value
    /// (`restore_point.rs`); none: the whole log. Returns the value read, or none when the log
    /// did not read.
    pub(super) fn restore_transfer_authority_after(
        &self,
        session: &Session,
        from: Option<&super::restore_point::RestorePoint>,
    ) -> Option<Option<(u64, bool)>> {
        let after = from.map_or(0, |p| p.seq);
        let start = from.and_then(|p| p.transfer_authority);
        let mut latest = start.unwrap_or((0, false));
        let mut found = start.is_some();
        // Fail closed on an unreadable log. This runs only in load_session_log, never in
        // info, and does not hold the cache lock while reading disk.
        match self.store.scan_kinds_after_strict(
            &session.id,
            after,
            Self::TRANSFER_KINDS,
            &mut |record| {
                if let Some(blocked) = transfer_state(&record)
                    && record.seq >= latest.0
                {
                    latest = (record.seq, blocked);
                    found = true;
                }
                true
            },
        ) {
            Ok(()) => {
                session.note_transfer_authority(latest.0, latest.1);
                Some(found.then_some(latest))
            }
            Err(error) => {
                tracing::warn!(session = %session.id, "transfer authority unreadable: {error}");
                None
            }
        }
    }

    /// Restore the highest transfer fencing epoch before a session can accept a resumed move.
    /// Epochs live in transfer events rather than session metadata so old stores remain readable.
    pub(super) fn restore_ownership_epoch(&self, session: &Session) -> anyhow::Result<()> {
        self.restore_ownership_epoch_after(session, None).map(drop)
    }

    /// [`Self::restore_ownership_epoch`] of the records past a restore point, from its epoch
    /// (`restore_point.rs`); none: the whole log. Returns the epoch.
    pub(super) fn restore_ownership_epoch_after(
        &self,
        session: &Session,
        from: Option<&super::restore_point::RestorePoint>,
    ) -> anyhow::Result<u64> {
        let mut epoch = from.map_or(0, |p| p.ownership_epoch);
        let mut malformed = false;
        self.store.scan_kinds_after_strict(
            &session.id,
            from.map_or(0, |p| p.seq),
            &["transfer_out", "transferred", "transferred_in", "transfer_aborted"],
            &mut |record| {
                if let Some(value) = record.msg.get("epoch") {
                    if let Some(value) = value.as_u64() {
                        epoch = epoch.max(value);
                    } else {
                        malformed = true;
                    }
                }
                true
            },
        )?;
        anyhow::ensure!(!malformed, "transfer event contains a malformed ownership epoch");
        session.restore_ownership_epoch(epoch);
        Ok(epoch)
    }
}

#[cfg(test)]
mod tests;
