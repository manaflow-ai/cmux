//! A receiving daemon keeps the room records private until acpmux confirms the chat landed.
//! The same receipt can settle them after a lost finish reply or a daemon restart.

use std::collections::BTreeMap;

use super::{LinkShare, MAX_SAVED_BYTES, MAX_SHARES, fits, room};
use crate::mux::Mux;
use crate::server::agent_transfer::state_file::{read_trusted, save};
use serde_json::Value;
use std::path::Path;
use std::sync::{Arc, Mutex};

const PENDING_FILE: &str = "agent-session-shares-incoming.json";
type Receives = BTreeMap<String, Vec<LinkShare>>;

#[derive(Default)]
pub(super) struct Pending(Mutex<Option<Receives>>);

impl Pending {
    fn change<T>(
        &self,
        directory: Option<&Path>,
        apply: impl FnOnce(&mut Receives) -> Result<(T, bool), &'static str>,
    ) -> Result<T, &'static str> {
        let mut slot = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if slot.is_none() {
            let mut initial = Receives::new();
            if let Some(path) = directory.map(|dir| dir.join(PENDING_FILE)) {
                match path.symlink_metadata() {
                    Ok(_) => {
                        initial = read_trusted(&path)
                            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                            .ok_or("share.unreadable")?;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(_) => return Err("share.unreadable"),
                }
            }
            *slot = Some(initial);
        }
        let current = slot.as_mut().ok_or("share.unreadable")?;
        let mut updated = current.clone();
        let (answer, changed) = apply(&mut updated)?;
        if changed {
            if serde_json::to_vec(&updated).map_err(|_| "share.unsaved")?.len() > MAX_SAVED_BYTES {
                return Err("share.limit");
            }
            if let Some(directory) = directory {
                save(directory, PENDING_FILE, &updated).map_err(|_| "share.unsaved")?;
            }
            *current = updated;
        }
        Ok(answer)
    }
}

/// Checks the registry's capacity and ownership. A replay after activation may see the shares
/// already installed. It keeps subsequent local changes to the same records, including revokes.
fn install(
    all: &mut Vec<LinkShare>,
    incoming: &[LinkShare],
    replay: bool,
) -> Result<bool, &'static str> {
    let before = all.len();
    for share in incoming {
        if let Some(existing) = all.iter().find(|s| s.share_id == share.share_id) {
            if replay
                && existing.session == share.session
                && existing.secret_sha256 == share.secret_sha256
            {
                continue;
            }
            return Err("share.exists");
        }
        all.push(share.clone());
    }
    if all.len() > MAX_SHARES || !fits(all) {
        return Err("share.limit");
    }
    Ok(all.len() != before)
}

pub(crate) fn stage_transferred_chat_shares(
    mux: &Mux,
    receive: &str,
    session: &str,
    payload: Value,
) -> Result<(), &'static str> {
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let directory = mux.session_state_directory();
    let incoming: Vec<LinkShare> =
        serde_json::from_value(payload).map_err(|_| "share.bad_request")?;
    if incoming.is_empty()
        || incoming.len() > MAX_SHARES
        || incoming.iter().any(|s| s.session != session || s.live().is_err())
    {
        return Err("share.bad_request");
    }
    shares.pending_transfers.change(directory.as_deref(), |receives| {
        if let Some(staged) = receives.get(receive) {
            return if staged == &incoming { Ok(((), false)) } else { Err("share.exists") };
        }
        let now = shares.now();
        receives.retain(|_, records| records.iter().any(|s| s.expires_at > now));
        shares.with(directory.as_deref(), |all, _| {
            let mut reserved = all.clone();
            for records in receives.values() {
                install(&mut reserved, records, false)?;
            }
            install(&mut reserved, &incoming, false)?;
            Ok(((), false))
        })?;
        receives.insert(receive.to_owned(), incoming);
        Ok(((), true))
    })
}

pub(crate) fn finish_transferred_chat_shares(
    mux: &Arc<Mux>,
    receive: &str,
    landed: bool,
) -> Result<(), &'static str> {
    let shares = &mux.control_clients.agent_sessions.link_shares;
    let directory = mux.session_state_directory();
    let ids = shares.pending_transfers.change(directory.as_deref(), |receives| {
        let Some(incoming) = receives.remove(receive) else {
            return Ok((Vec::new(), false));
        };
        let ids = if landed {
            shares.with(directory.as_deref(), |all, now| {
                let active: Vec<_> = incoming.into_iter().filter(|s| s.expires_at > now).collect();
                let changed = install(all, &active, true)?;
                let ids: Vec<String> = active.into_iter().map(|share| share.share_id).collect();
                Ok((ids, changed))
            })?
        } else {
            Vec::new()
        };
        Ok((ids, true))
    })?;
    for share_id in ids {
        room::host(mux, &share_id);
    }
    Ok(())
}
