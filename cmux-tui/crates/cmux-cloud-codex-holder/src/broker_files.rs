//! A holder's files on its machines: the staged, committed delivery of an access file and the
//! `own` mode marker, its revocation (which restores the mode the machine had before), and a
//! relaunch taking back what an earlier run delivered.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::Value;

use crate::broker::Broker;
use crate::cx::Cx;
use crate::error::{BrokerError, Error};
use crate::target::{ACCESS_PATH, BRIDGE, MODE_PATH, TargetRef};
use crate::types::{Grant, now, valid_expiry};

pub(crate) const OWN: &[u8] = b"own\n";
const FOLDERS: [&str; 4] = [
    "/home/cmux/.config",
    "/home/cmux/.config/cmux",
    "/home/cmux/.config/cmux/codex-broker",
    "/home/cmux/.config/cmux/agent-auth",
];

/// The grant a left access file carries; only its expiry is used, to time the next renewal. An
/// unreadable one counts as expired, so renewal runs at once.
pub(crate) fn grant_in(access: &[u8]) -> Grant {
    let object: Value = serde_json::from_slice(access).unwrap_or(Value::Null);
    let text = |key: &str| object.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    Grant {
        access_token: text("accessToken"),
        account: text("chatgptAccountId"),
        // The machine's own file: a malformed expiry reads as already ended.
        expires_at: object
            .get("expiresAt")
            .and_then(Value::as_f64)
            .filter(|e| valid_expiry(*e))
            .unwrap_or(0.0),
    }
}

fn bridge_object(access: &[u8]) -> Option<serde_json::Map<String, Value>> {
    match serde_json::from_slice(access).ok()? {
        Value::Object(object) if object.get("bridge").and_then(Value::as_str) == Some(BRIDGE) => {
            Some(object)
        }
        _ => None,
    }
}

impl Broker {
    /// The machine's Codex mode before any holder delivery. An `own` marker under an access file
    /// a holder wrote is an earlier run's (one that quit and left it); its `previousMode` is the
    /// person's own. Any other `own`, including one under an older file that records none, is
    /// the person's choice (`cr use`, an agent login) and is kept.
    pub(crate) async fn mode_before_broker(
        cx: &Cx,
        target: &TargetRef,
    ) -> Result<Option<Vec<u8>>, Error> {
        let mode = cx.run(target.read_file(MODE_PATH)).await?;
        if mode.as_deref() != Some(OWN) {
            return Ok(mode);
        }
        let Some(access) = cx.run(target.read_file(ACCESS_PATH)).await? else { return Ok(mode) };
        let Some(object) = bridge_object(&access) else { return Ok(mode) };
        match object.get("previousMode") {
            None => Ok(mode),
            Some(Value::Null) => Ok(None),
            Some(Value::String(text)) => Ok(BASE64.decode(text).map_or(mode, Some)),
            Some(_) => Ok(mode),
        }
    }

    /// The access file this holder's delivery left on `target` under the `own` marker, or none
    /// when the machine holds none of it (Codex signed in some other way since, another Mac or
    /// account delivered over it, or nothing is there).
    pub(crate) async fn access_left_by_broker(
        cx: &Cx,
        target: &TargetRef,
        holder: &str,
    ) -> Result<Option<Vec<u8>>, Error> {
        if cx.run(target.read_file(MODE_PATH)).await?.as_deref() != Some(OWN) {
            return Ok(None);
        }
        let Some(access) = cx.run(target.read_file(ACCESS_PATH)).await? else { return Ok(None) };
        let mine = bridge_object(&access)
            .is_some_and(|object| object.get("holder").and_then(Value::as_str) == Some(holder));
        Ok(mine.then_some(access))
    }

    fn still_registered(&self, id: &str, generation: u64) -> bool {
        let state = self.st();
        state.targets.contains_key(id) && state.generations.get(id) == Some(&generation)
    }

    fn checked(&self, cx: &Cx, id: &str, generation: u64) -> Result<(), Error> {
        self.ensure_scope(cx)?;
        if !self.still_registered(id, generation) {
            return Err(BrokerError::Cancelled.into());
        }
        Ok(())
    }

    /// Delivers `grant` to a registered machine: staged files, one privileged commit, staged
    /// files removed. A failure erases what it committed and restores the machine's mode.
    pub(crate) async fn deliver(
        &self,
        cx: &Cx,
        grant: &Grant,
        target: &TargetRef,
        expected_generation: Option<u64>,
    ) -> Result<(), Error> {
        let id = target.machine_id().to_owned();
        let _lock = self.lock_target(&id).await;
        let (generation, prior) = {
            let state = self.st();
            if !state.targets.contains_key(&id) {
                return Err(BrokerError::Cancelled.into());
            }
            let generation = expected_generation.unwrap_or_else(|| state.generation(&id));
            if state.pending_revocations.contains(&id) || state.generation(&id) != generation {
                return Err(BrokerError::Cancelled.into());
            }
            (generation, state.installed.get(&id).cloned())
        };
        let suffix = uuid::Uuid::new_v4().to_string().to_lowercase();
        let stage_access = format!("/home/cmux/.config/cmux/codex-broker/.access-{suffix}.json");
        let stage_mode = format!("/home/cmux/.config/cmux/agent-auth/.codex-{suffix}");
        let mut data = Vec::new();
        let mut committed = false;
        let mut commit_attempted = false;
        let result: Result<(), Error> = async {
            self.validate(cx, target, true).await?;
            self.ensure_scope(cx)?;
            if !self.still_registered(&id, generation) || !target.is_live().await? {
                return Err(BrokerError::TargetOffline.into());
            }
            if !self.st().loaded_previous_mode.contains(&id) {
                let previous = Self::mode_before_broker(cx, target).await?;
                let mut state = self.st();
                state.previous_mode.insert(id.clone(), previous);
                state.loaded_previous_mode.insert(id.clone());
            }
            // The access file carries the mode to restore, so a later run revokes what an
            // earlier one left at quit (#33482) without mistaking its marker for the person's.
            let previous = self.st().previous_mode.get(&id).cloned().flatten();
            let object: BTreeMap<&str, Value> = BTreeMap::from([
                ("schema", Value::from(1)),
                ("bridge", Value::from(BRIDGE)),
                ("accessToken", Value::from(grant.access_token.as_str())),
                ("chatgptAccountId", Value::from(grant.account.as_str())),
                ("expiresAt", Value::from(grant.expires_at.trunc() as i64)),
                ("installationID", Value::from(uuid::Uuid::new_v4().to_string().to_uppercase())),
                ("holder", Value::from(self.holder_id())),
                ("previousMode", previous.map_or(Value::Null, |p| Value::from(BASE64.encode(p)))),
            ]);
            data =
                serde_json::to_vec(&object).map_err(|_| Error::from(BrokerError::InvalidReply))?;
            self.ensure_scope(cx)?;
            for folder in FOLDERS {
                cx.run(target.make_directory(folder)).await?;
            }
            self.checked(cx, &id, generation)?;
            self.st()
                .pending_stage
                .entry(id.clone())
                .or_default()
                .extend([stage_access.clone(), stage_mode.clone()]);
            cx.run(target.write_file(&stage_access, &data, 0o600)).await?;
            self.checked(cx, &id, generation)?;
            cx.run(target.write_file(&stage_mode, OWN, 0o600)).await?;
            self.checked(cx, &id, generation)?;
            commit_attempted = true;
            self.st().installed.insert(id.clone(), data.clone());
            // Recorded before the commit, so a quit or crash right after it still leaves a record.
            self.record.delivered(&id);
            cx.run(target.commit_files(&stage_access, ACCESS_PATH, &stage_mode, MODE_PATH)).await?;
            committed = true;
            self.ensure_scope(cx)?;
            let stages = self
                .st()
                .pending_stage
                .get(&id)
                .cloned()
                .unwrap_or_else(|| BTreeSet::from([stage_access.clone(), stage_mode.clone()]));
            for stage in &stages {
                cx.run(target.remove_file(stage)).await?;
            }
            self.st().pending_stage.remove(&id);
            self.checked(cx, &id, generation)
        }
        .await;
        let Err(error) = result else { return Ok(()) };
        self.after_failed_delivery(cx, target, error, prior, data, committed, commit_attempted)
            .await
    }

    #[allow(clippy::too_many_arguments, reason = "the failed delivery's whole state, in one place")]
    async fn after_failed_delivery(
        &self,
        cx: &Cx,
        target: &TargetRef,
        error: Error,
        prior: Option<Vec<u8>>,
        data: Vec<u8>,
        mut committed: bool,
        commit_attempted: bool,
    ) -> Result<(), Error> {
        let id = target.machine_id().to_owned();
        // A quit cut this renewal short: whatever it committed stays, like every other delivery.
        if self.st().detached {
            return Err(BrokerError::Cancelled.into());
        }
        let restore_prior = |broker: &Self| {
            let mut state = broker.st();
            match &prior {
                Some(prior) => state.installed.insert(id.clone(), prior.clone()),
                None => state.installed.remove(&id),
            };
        };
        let mut reconciliation_failed = false;
        if commit_attempted && !committed {
            // Exec can commit and lose its reply. Reconcile independently of the caller's
            // cancel; a unique installation ID binds it.
            match target.read_file(ACCESS_PATH).await {
                Ok(current) => {
                    committed = current.as_deref() == Some(data.as_slice());
                    if !committed {
                        restore_prior(self);
                    }
                }
                Err(_) => {
                    // Retain transport until revocation can reconcile this installation.
                    restore_prior(self);
                    let mut state = self.st();
                    state.uncertain.insert(id.clone(), (prior.clone(), data.clone()));
                    state.pending_revocations.insert(id.clone());
                    reconciliation_failed = true;
                }
            }
        }
        let previous = {
            let mut state = self.st();
            if committed || cx.is_cancelled() || error.is(BrokerError::ScopeChanged) {
                state.targets.remove(&id);
                state.bump(&id);
                state.pending_revocations.insert(id.clone());
                state.revocation_targets.insert(id.clone(), target.clone());
            }
            if committed {
                state.removal_attempted.insert(id.clone());
            }
            state.previous_mode.get(&id).cloned().flatten()
        };
        // Cleanup must complete even when the initiating task was cancelled.
        let stages = self.st().pending_stage.get(&id).cloned().unwrap_or_default();
        let cleanup: Result<(), Error> = async {
            for stage in &stages {
                target.remove_file(stage).await?;
            }
            if committed {
                target.remove_file(ACCESS_PATH).await?;
                match &previous {
                    Some(previous) => target.write_file(MODE_PATH, previous, 0o600).await?,
                    None => target.remove_file(MODE_PATH).await?,
                }
            }
            Ok(())
        }
        .await;
        if cleanup.is_err() {
            return Err(BrokerError::RemoteDeliveryFailed.into());
        }
        if committed {
            let mut state = self.st();
            state.installed.remove(&id);
            state.removal_attempted.remove(&id);
            drop(state);
            self.record.forget(&id);
        }
        self.st().pending_stage.remove(&id);
        if reconciliation_failed {
            return Err(BrokerError::RemoteDeliveryFailed.into());
        }
        Err(match error {
            Error::Broker(error) => Error::Broker(error),
            _ if cx.is_cancelled() => BrokerError::Cancelled.into(),
            _ => BrokerError::RemoteDeliveryFailed.into(),
        })
    }

    /// Removes the delivered access file and the own marker. The local holder is signed out only
    /// when the caller asks for it.
    pub async fn revoke(&self, cx: &Cx, target: &TargetRef, sign_out: bool) -> Result<(), Error> {
        let id = target.machine_id().to_owned();
        let registered = {
            let mut state = self.st();
            let registered =
                state.targets.remove(&id).is_some() || state.pending_revocations.contains(&id);
            state.bump(&id);
            registered
        };
        self.cancel_catch_up(&id);
        if !registered {
            return Ok(());
        }
        {
            let mut state = self.st();
            state.pending_revocations.insert(id.clone());
            state.revocation_targets.insert(id.clone(), target.clone());
        }
        let _lock = self.lock_target(&id).await;
        let stages = self.st().pending_stage.get(&id).cloned();
        if let Some(stages) = stages {
            if target.is_live().await != Ok(true) {
                return Err(BrokerError::TargetOffline.into());
            }
            for stage in &stages {
                cx.run(target.remove_file(stage)).await?;
            }
            self.st().pending_stage.remove(&id);
        }
        // A registration awaiting its first grant owns no machine files.
        let (installed, uncertain) = {
            let state = self.st();
            (state.installed.get(&id).cloned(), state.uncertain.get(&id).cloned())
        };
        if installed.is_none() && uncertain.is_none() {
            {
                let mut state = self.st();
                state.previous_mode.remove(&id);
                state.loaded_previous_mode.remove(&id);
                state.removal_attempted.remove(&id);
                state.pending_revocations.remove(&id);
                state.revocation_targets.remove(&id);
            }
            self.stop_renewal_if_empty();
            if sign_out && self.st().targets.is_empty() {
                let _ = self.request(cx, "logout", None, None).await;
            }
            return Ok(());
        }
        // Stop renewal without waking a paused machine. Its last access token stays usable until
        // provider expiry; file removal needs a running machine.
        if target.is_live().await != Ok(true) {
            if self.end_renewal_if_empty() && sign_out {
                let _ = self.request(cx, "logout", None, None).await;
            }
            return Err(BrokerError::TargetOffline.into());
        }
        let current = cx.run(target.read_file(ACCESS_PATH)).await?;
        let known = uncertain.map(|(_, candidate)| candidate);
        let owned = current.is_some() && (current == installed || current == known);
        let attempted = self.st().removal_attempted.contains(&id);
        if (owned || (current.is_none() && attempted))
            && cx.run(target.read_file(MODE_PATH)).await?.as_deref() == Some(OWN)
        {
            self.st().removal_attempted.insert(id.clone());
            if current.is_some() {
                cx.run(target.remove_file(ACCESS_PATH)).await?;
            }
            let previous = self.st().previous_mode.get(&id).cloned().flatten();
            match previous {
                Some(previous) => cx.run(target.write_file(MODE_PATH, &previous, 0o600)).await?,
                None => cx.run(target.remove_file(MODE_PATH)).await?,
            }
        }
        {
            let mut state = self.st();
            state.installed.remove(&id);
            state.uncertain.remove(&id);
            state.removal_attempted.remove(&id);
            state.previous_mode.remove(&id);
            state.loaded_previous_mode.remove(&id);
            state.pending_revocations.remove(&id);
            state.revocation_targets.remove(&id);
        }
        // The machine is read back and holds none of this holder's access now.
        self.record.forget(&id);
        if self.end_renewal_if_empty() && sign_out {
            let _ = self.request(cx, "logout", None, None).await;
        }
        Ok(())
    }

    /// No machine left: the cache and the scheduled renewal end. Whether none was left.
    fn end_renewal_if_empty(&self) -> bool {
        let mut state = self.st();
        if !state.targets.is_empty() {
            return false;
        }
        state.cached = None;
        if let Some(job) = state.refresh_task.take() {
            job.cancel();
        }
        true
    }

    pub(crate) fn stop_renewal_if_empty(&self) {
        if self.end_renewal_if_empty() {
            self.cancel_catch_ups();
        }
    }

    /// The service confirmed the deletion; there is no machine file left to restore. Not a
    /// substitute for revoking an existing machine.
    pub fn discard_deleted_target(&self, id: &str) {
        {
            let mut state = self.st();
            state.bump(id);
            state.targets.remove(id);
        }
        self.cancel_catch_up(id);
        {
            let mut state = self.st();
            state.revocation_targets.remove(id);
            state.pending_revocations.remove(id);
            state.previous_mode.remove(id);
            state.installed.remove(id);
            state.uncertain.remove(id);
            state.pending_stage.remove(id);
            state.removal_attempted.remove(id);
            state.loaded_previous_mode.remove(id);
        }
        self.record.forget(id);
        self.end_renewal_if_empty();
    }

    /// After a relaunch: takes back a machine an earlier run delivered access to and left at
    /// quit (the delivery record). While it still holds that access under the `own` marker it
    /// registers again: renewal picks back up (cmux#33878) and a sign-out, a switch or the off
    /// switch erases it (cmux#33877). With `erase` (an earlier erase could not reach it) it is
    /// erased now. A machine with none of this holder's access is forgotten; a paused one stays.
    pub async fn resume(self: &Arc<Self>, cx: &Cx, target: &TargetRef, erase: bool) {
        let id = target.machine_id().to_owned();
        {
            let state = self.st();
            if state.stopped || state.targets.contains_key(&id) {
                return;
            }
        }
        // Erasing only removes this holder's own file, so it needs no current scope: a scope that
        // ended (a switch, a sign-out) still erases what it left. Renewing does.
        if (!erase && !self.in_scope()) || target.is_live().await != Ok(true) {
            return;
        }
        let pending = {
            let state = self.st();
            state.pending_revocations.contains(&id).then(|| {
                state.revocation_targets.get(&id).cloned().unwrap_or_else(|| target.clone())
            })
        };
        if let Some(pending) = pending {
            // An erase this run could not finish (the machine was paused): it is back, so finish it.
            let _ = self.revoke(cx, &pending, false).await;
            return;
        }
        let generation = self.st().generation(&id);
        let lock = self.lock_target(&id).await;
        let unchanged = |broker: &Self| {
            let state = broker.st();
            !state.stopped
                && !state.targets.contains_key(&id)
                && !state.pending_revocations.contains(&id)
                && state.generation(&id) == generation
        };
        if !unchanged(self) {
            return;
        }
        let read: Result<Option<Vec<u8>>, Error> = async {
            // Renewing needs the same owner check as a delivery; erasing only removes this holder's file.
            if !erase {
                self.validate(cx, target, true).await?;
            }
            let left = Self::access_left_by_broker(cx, target, &self.holder_id()).await?;
            if left.is_some() {
                let previous = Self::mode_before_broker(cx, target).await?;
                let mut state = self.st();
                state.previous_mode.insert(id.clone(), previous);
                state.loaded_previous_mode.insert(id.clone());
            }
            Ok(left)
        }
        .await;
        let Ok(left) = read else { return };
        let left = {
            let mut state = self.st();
            match left {
                Some(left) if !state.stopped && state.generation(&id) == generation => {
                    state.installed.insert(id.clone(), left.clone());
                    state.targets.insert(id.clone(), target.clone());
                    state.generations.insert(id.clone(), generation);
                    left
                }
                left => {
                    state.previous_mode.remove(&id);
                    state.loaded_previous_mode.remove(&id);
                    drop(state);
                    if left.is_none() {
                        self.record.forget(&id);
                    }
                    return;
                }
            }
        };
        drop(lock);
        if erase {
            // A failure keeps the record's erase mark, so a later pass tries again.
            let _ = self.revoke(cx, target, false).await;
            return;
        }
        let left_grant = grant_in(&left);
        let renew_by = left_grant.expires_at - 120.0;
        let joins = {
            let state = self.st();
            let cached_is_current =
                state.cached.as_ref().is_some_and(|c| c.expires_at > now() + 120.0);
            cached_is_current
                || (state.refresh_task.is_some()
                    && state.next_renewal_at.is_some_and(|at| renew_by < at))
        };
        if joins {
            // Renewal already runs and the machine joins it with the current grant, or the
            // scheduled renewal comes after this machine's access ends and it gets fresh access
            // now. A failure tries again until that access ends (cmux#34010).
            if let Err(error) = self.catch_up(cx, target, generation).await
                && Self::catch_up_retries(&error)
            {
                self.retry_catch_up(target, generation, left_grant.expires_at);
            }
        } else {
            self.schedule_refresh(&left_grant, 0);
        }
    }
}

#[cfg(test)]
#[path = "broker_files_tests.rs"]
mod tests;
