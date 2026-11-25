use super::*;

pub struct AuthDatabase {
    state_dir: PathBuf,
    daemon_name: String,
    identity: StaticIdentity,
    allow_carrier: bool,
    /// Carrier grants are refused until the owner installs a verifier.
    grant_verifier: std::sync::OnceLock<Arc<dyn crate::grant::GrantVerifier>>,
    /// Grant-admitted Noise keys, so a resume needs no grant.
    admitted_grants: crate::grant::AdmittedGrants,
    pub(super) state: Arc<Mutex<AuthState>>,
    persistence: Arc<PersistenceCoordinator>,
    pending_changed: Notify,
    revocation_tx: watch::Sender<u64>,
}

impl std::fmt::Debug for AuthDatabase {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AuthDatabase")
            .field("state_dir", &self.state_dir)
            .field("daemon_name", &self.daemon_name)
            .field("daemon_fingerprint", &self.identity.fingerprint())
            .field("allow_carrier", &self.allow_carrier)
            .field("grant_verifier", &self.grant_verifier.get().is_some())
            .finish_non_exhaustive()
    }
}

impl AuthDatabase {
    pub fn load_or_create(
        state_dir: impl Into<PathBuf>,
        daemon_name: impl Into<String>,
        allow_carrier: bool,
    ) -> Result<Arc<Self>, IdentityError> {
        Self::load(
            state_dir.into(),
            daemon_name.into(),
            allow_carrier,
            AuthStateLoadMode::CurrentOnly,
        )
    }

    /// Open current authorization state or explicitly migrate the legacy
    /// version after the caller has fenced every predecessor process.
    pub fn load_or_migrate_legacy(
        state_dir: impl Into<PathBuf>,
        daemon_name: impl Into<String>,
        allow_carrier: bool,
    ) -> Result<Arc<Self>, IdentityError> {
        Self::load(
            state_dir.into(),
            daemon_name.into(),
            allow_carrier,
            AuthStateLoadMode::MigrateLegacy,
        )
    }

    fn load(
        state_dir: PathBuf,
        daemon_name: String,
        allow_carrier: bool,
        load_mode: AuthStateLoadMode,
    ) -> Result<Arc<Self>, IdentityError> {
        secure_directory(&state_dir)?;
        let state_path = state_dir.join("devices.json");
        let lease_path = sibling_lock_path(&state_path).map_err(IdentityError::Io)?;
        let state_lease = OwnerFileLock::try_acquire(&lease_path).map_err(IdentityError::Io)?;
        // Persist the rollback fence while the authorization lease is held and
        // before creating identity.json. A crash cannot leave a directory that
        // a retry mistakes for unfenced legacy authorization state.
        let persisted = load_auth_state(&state_path, load_mode)?;
        let identity = load_or_create_identity(&state_dir.join("identity.json"))?;
        let (revocation_tx, _) = watch::channel(persisted.revocation_generation);
        let persistence =
            Arc::new(PersistenceCoordinator::new(state_path, persisted.revision, state_lease)?);
        Ok(Arc::new(Self {
            state_dir,
            daemon_name,
            identity,
            allow_carrier,
            grant_verifier: std::sync::OnceLock::new(),
            admitted_grants: crate::grant::AdmittedGrants::default(),
            state: Arc::new(Mutex::new(AuthState::from_persisted(persisted))),
            persistence,
            pending_changed: Notify::new(),
            revocation_tx,
        }))
    }

    pub fn identity(&self) -> StaticIdentity {
        self.identity.clone()
    }

    pub fn daemon_name(&self) -> &str {
        &self.daemon_name
    }

    /// Accept carrier grants checked by `verifier`. Set once, at daemon
    /// start, before the daemon serves; a second call is refused. Without
    /// it every grant is refused.
    pub fn set_grant_verifier(
        &self,
        verifier: Arc<dyn crate::grant::GrantVerifier>,
    ) -> Result<(), IdentityError> {
        self.grant_verifier
            .set(verifier)
            .map_err(|_| IdentityError::Invalid("a grant verifier is already installed".into()))
    }

    pub fn subscribe_revocations(&self) -> watch::Receiver<u64> {
        self.revocation_tx.subscribe()
    }

    /// Stop accepting authorization mutations, durably flush the final
    /// accepted revision, and join the persistence owner before process exit.
    pub async fn shutdown(&self) -> Result<(), IdentityError> {
        self.shutdown_with_cleanup(|_| Ok(())).await
    }

    /// Finalize authorization persistence while retaining its exclusive state
    /// lease through lifecycle cleanup. The cleanup observes the authoritative
    /// terminal persistence result before the lease is released.
    pub async fn shutdown_with_cleanup(
        &self,
        cleanup: impl FnOnce(&Result<(), IdentityError>) -> Result<(), IdentityError> + Send,
    ) -> Result<(), IdentityError> {
        let final_write = {
            let mut state = self.state.lock().await;
            if state.closing {
                None
            } else {
                state.closing = true;
                Some(self.persistence.submit(state.to_persisted()))
            }
        };
        if let Some(final_write) = final_write {
            // The coordinator retains the authoritative terminal result, so a
            // cancelled caller or worker failure remains observable after join.
            let _ = final_write.wait().await;
        }
        self.persistence.close_and_join_with_cleanup(cleanup)
    }

    pub async fn create_invitation(
        &self,
        ttl: Duration,
        route_hints: Vec<String>,
    ) -> Result<EnrollmentInvitation, IdentityError> {
        self.create_invitation_with_relay_access(ttl, route_hints, Vec::new()).await
    }

    pub async fn create_invitation_with_relay_access(
        &self,
        ttl: Duration,
        route_hints: Vec<String>,
        relay_access: Vec<EnrollmentRelayAccess>,
    ) -> Result<EnrollmentInvitation, IdentityError> {
        self.create_invitation_for_device(ttl, route_hints, relay_access, None).await
    }

    /// Create an invitation; with `bound_device`, one that only that device's
    /// key can claim, and which enrolls it with no approval step.
    pub async fn create_invitation_for_device(
        &self,
        ttl: Duration,
        route_hints: Vec<String>,
        mut relay_access: Vec<EnrollmentRelayAccess>,
        bound_device: Option<BoundDevice>,
    ) -> Result<EnrollmentInvitation, IdentityError> {
        let ttl = ttl.min(MAX_INVITATION_TTL);
        if ttl.is_zero() {
            return Err(IdentityError::Invalid("invitation ttl must be positive".into()));
        }
        let route_hints = credential_free_route_hints(route_hints)?;
        for access in &mut relay_access {
            access.route = credential_free_route_hint(&access.route)?;
        }
        validate_relay_access(&route_hints, &relay_access)?;
        let now = unix_time()?;
        let expires_at_unix = now.saturating_add(ttl.as_secs());
        let id = random_token(16)?;
        let mut secret = [0_u8; 32];
        getrandom::fill(&mut secret).map_err(|error| IdentityError::Random(error.to_string()))?;
        let invitation = EnrollmentInvitation {
            version: STATE_VERSION,
            id: id.clone(),
            secret: encode_key(&secret),
            daemon_public_key: encode_key(&self.identity.public_key()),
            daemon_fingerprint: self.identity.fingerprint(),
            daemon_name: self.daemon_name.clone(),
            expires_at_unix,
            route_hints,
            relay_access,
            approval_required: bound_device.is_none(),
            via_machine: None,
        };
        invitation.to_uri()?;
        let mut state = self.state.lock().await;
        state.ensure_open()?;
        state.prune_invitations(now);
        if state.invitations.len() >= MAX_LIVE_INVITATIONS {
            return Err(IdentityError::Invalid(format!(
                "maximum invitation count ({MAX_LIVE_INVITATIONS}) reached"
            )));
        }
        state.invitations.insert(
            id,
            InvitationRecord {
                secret,
                expires_at_unix,
                route_hints: invitation.route_hints.clone(),
                claimed_by: None,
                bound_device,
            },
        );
        let persistence = self.submit_mutation_locked(&mut state)?;
        drop(state);
        persistence.wait().await?;
        Ok(invitation)
    }

    pub async fn list_devices(&self) -> Vec<DeviceRecord> {
        self.state.lock().await.devices.values().cloned().collect()
    }

    pub async fn device_is_active(&self, device_id: &str) -> bool {
        if device_id.starts_with(TRUSTED_NETWORK_DEVICE_PREFIX) {
            return true;
        }
        // A grant admits a session once; revoking it is a pushed retire,
        // not a device-list change.
        if crate::grant::is_grant_device_id(device_id) {
            return self.grant_verifier.get().is_some();
        }
        if device_id.starts_with("carrier:") {
            return self.allow_carrier;
        }
        self.state
            .lock()
            .await
            .devices
            .get(device_id)
            .is_some_and(|device| device.revoked_at_unix.is_none())
    }

    /// Revalidate an authorization result at the point where a connection is
    /// published. The generation check closes the race where a revocation can
    /// happen after the Noise handshake but before all physical lanes arrive.
    pub async fn grant_is_current(&self, grant: &AuthGrant) -> bool {
        if grant.device_id.starts_with(TRUSTED_NETWORK_DEVICE_PREFIX) {
            return true;
        }
        if crate::grant::is_grant_device_id(&grant.device_id) {
            return self.grant_verifier.get().is_some();
        }
        if grant.device_id.starts_with("carrier:") {
            return self.allow_carrier;
        }
        let state = self.state.lock().await;
        grant.revocation_generation == state.revocation_generation
            && state
                .devices
                .get(&grant.device_id)
                .is_some_and(|device| device.revoked_at_unix.is_none())
    }

    pub async fn pending_enrollments(&self) -> Vec<PendingEnrollment> {
        self.pending_snapshot().await.unwrap_or_default()
    }

    /// Return a snapshot only when at least one enrollment is pending.
    ///
    /// Waiting callers used to clone every pending request merely to check
    /// whether the map was empty. Keeping the emptiness check under the same
    /// lock as the snapshot avoids that O(P) allocation on every notification
    /// cycle while preserving the existing snapshot semantics.
    async fn pending_snapshot(&self) -> Option<Vec<PendingEnrollment>> {
        let state = self.state.lock().await;
        if state.pending.is_empty() {
            return None;
        }
        Some(state.pending.values().map(|pending| pending.request.clone()).collect())
    }

    pub async fn wait_for_pending(
        &self,
        timeout: Duration,
    ) -> Result<Vec<PendingEnrollment>, IdentityError> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let notified = self.pending_changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if let Some(pending) = self.pending_snapshot().await {
                return Ok(pending);
            }
            if tokio::time::timeout_at(deadline, notified.as_mut()).await.is_err() {
                return self.pending_snapshot().await.ok_or(IdentityError::Timeout);
            }
        }
    }

    /// Keep the approval transaction alive if its admin caller disconnects.
    /// The transaction retains the authentication-state lock until its snapshot
    /// is durable, so no authorization reader can observe the staged device.
    pub async fn approve(
        self: &Arc<Self>,
        invitation_id: &str,
    ) -> Result<DeviceRecord, IdentityError> {
        let database = Arc::clone(self);
        let invitation_id = invitation_id.to_owned();
        outlive_caller("identity approval", async move {
            database.approve_durably(&invitation_id).await
        })
        .await
        .unwrap_or_else(|error| Err(IdentityError::Persistence(error)))
    }

    async fn approve_durably(&self, invitation_id: &str) -> Result<DeviceRecord, IdentityError> {
        let now = unix_time()?;
        let mut state = Arc::clone(&self.state).lock_owned().await;
        state.ensure_open()?;
        let pending = state
            .pending
            .remove(invitation_id)
            .ok_or_else(|| IdentityError::UnknownPending(invitation_id.into()))?;
        if !state.invitations.contains_key(invitation_id) {
            return Err(IdentityError::InvitationExpired(invitation_id.into()));
        }
        let approval_deadline =
            pending.request.requested_at_unix.saturating_add(APPROVAL_TIMEOUT.as_secs());
        if approval_deadline <= now {
            return Err(IdentityError::InvitationExpired(invitation_id.into()));
        }
        let enrollment = enroll_invited_device(
            state,
            Arc::clone(&self.persistence),
            self.daemon_name.clone(),
            invitation_id.to_owned(),
            pending.device_public_key,
            pending.request.device_name.clone(),
            now,
        )
        .await;
        let _ = pending.decision.send(enrollment.authorization);
        enrollment.record
    }

    pub async fn deny(&self, invitation_id: &str) -> Result<(), IdentityError> {
        let (decision, persistence) = {
            let mut state = self.state.lock().await;
            state.ensure_open()?;
            let pending = state
                .pending
                .remove(invitation_id)
                .ok_or_else(|| IdentityError::UnknownPending(invitation_id.into()))?;
            state.invitations.remove(invitation_id);
            let persistence = self.submit_mutation_locked(&mut state)?;
            (pending.decision, persistence)
        };
        let (completed_tx, completed_rx) = oneshot::channel();
        tokio::spawn(async move {
            let result = persistence.wait_result().await;
            let authorization = match &result {
                Ok(()) | Err(PersistenceFailure::Committed(_)) => Err("enrollment denied".into()),
                Err(error) => Err(error.message()),
            };
            let _ = decision.send(authorization);
            let _ = completed_tx.send(result);
        });
        completed_rx
            .await
            .unwrap_or_else(|_| {
                Err(PersistenceFailure::Uncommitted(
                    "identity denial persistence task stopped".into(),
                ))
            })
            .map_err(PersistenceFailure::into_identity_error)
    }

    /// Revoke an enrolled device; returns its record, now marked revoked, so
    /// the owner can be told which device it was.
    pub async fn revoke(&self, device_id: &str) -> Result<DeviceRecord, IdentityError> {
        let now = unix_time()?;
        let (generation, persistence, record) = {
            let mut state = self.state.lock().await;
            state.ensure_open()?;
            let device = state
                .devices
                .get_mut(device_id)
                .ok_or_else(|| IdentityError::UnknownDevice(device_id.into()))?;
            device.revoked_at_unix = Some(now);
            let record = device.clone();
            // An invitation bound to the revoked key was the owner's approval
            // of it ahead of time; revocation withdraws that approval too, so
            // a spare one cannot enroll the device again. Persisted with the
            // revocation. Re-enrolling takes a new invitation. A claimed one
            // stays: its claim path already refuses a revoked device.
            state.invitations.retain(|_, invitation| {
                invitation.claimed_by.is_some()
                    || invitation
                        .bound_device
                        .as_ref()
                        .is_none_or(|bound| bound.fingerprint() != device_id)
            });
            state.revocation_generation = state
                .revocation_generation
                .checked_add(1)
                .ok_or_else(|| IdentityError::Invalid("revocation generation exhausted".into()))?;
            let generation = state.revocation_generation;
            let persistence = self.submit_mutation_locked(&mut state)?;
            (generation, persistence, record)
        };
        // Revocation takes effect in memory immediately. Durability still
        // gates the method's successful return.
        let _ = self.revocation_tx.send(generation);
        persistence.wait().await.map(|()| record)
    }

    /// The daemon registered the new session a grant's link group formed
    /// (`session`, `generation`, `connection_attempt`): seal that group, so
    /// the grant opens nothing more. No-op for any other device.
    pub fn seal_grant_link_group(
        &self,
        device_id: &str,
        session: cmux_remote_protocol::SessionId,
        generation: u64,
        connection_attempt: ConnectionAttemptId,
    ) {
        if !crate::grant::is_grant_device_id(device_id) {
            return;
        }
        if let Some(verifier) = self.grant_verifier.get() {
            verifier.seal(crate::grant::link_group(session, generation, connection_attempt));
        }
    }

    pub async fn record_connection_attempt(
        &self,
        device_id: &str,
        connection_attempt: ConnectionAttemptId,
    ) -> Result<(), IdentityError> {
        // Carrier and trusted-network grants have no device record to stamp;
        // their admission is the transport's, not the device list's.
        if device_id.starts_with("carrier:") || device_id.starts_with(TRUSTED_NETWORK_DEVICE_PREFIX)
        {
            return Ok(());
        }
        let now = unix_time()?;
        let key = (device_id.to_string(), connection_attempt);
        let persistence = {
            let mut state = self.state.lock().await;
            state.ensure_open()?;
            if let Some(revision) = state.recorded_connection_attempts.get(&key).copied() {
                if self.persistence.durable_revision_at_least(revision) {
                    return Ok(());
                }
                self.persistence.submit(state.to_persisted())
            } else {
                let device = state
                    .devices
                    .get_mut(device_id)
                    .ok_or_else(|| IdentityError::UnknownDevice(device_id.into()))?;
                if device.revoked_at_unix.is_some() {
                    return Err(IdentityError::Invalid(format!(
                        "device {device_id} has been revoked"
                    )));
                }
                device.last_seen_at_unix = now;
                let persistence = self.submit_mutation_locked(&mut state)?;
                let revision = state.revision;
                if state.recorded_connection_attempts.len() >= MAX_RECORDED_CONNECTION_ATTEMPTS
                    && let Some(stale) = state.recorded_connection_attempt_order.pop_front()
                {
                    state.recorded_connection_attempts.remove(&stale);
                }
                state.recorded_connection_attempts.insert(key.clone(), revision);
                state.recorded_connection_attempt_order.push_back(key);
                persistence
            }
        };
        persistence.wait().await
    }

    fn submit_mutation_locked(
        &self,
        state: &mut AuthState,
    ) -> Result<PersistenceWaiter, IdentityError> {
        submit_mutation(&self.persistence, state)
    }
}

/// Run an authorization write to its end even when its caller (an admin
/// client, or a device's link) is dropped mid-write: the write holds the state
/// lock until its snapshot is durable or rolled back, and cancelling it there
/// would leave a staged device. The task owns everything it touches and ends
/// with the write, so it needs no other owner.
async fn outlive_caller<T: Send + 'static>(
    what: &str,
    write: impl Future<Output = T> + Send + 'static,
) -> Result<T, String> {
    tokio::spawn(write).await.map_err(|error| format!("{what} task failed to join: {error}"))
}

fn submit_mutation(
    persistence: &PersistenceCoordinator,
    state: &mut AuthState,
) -> Result<PersistenceWaiter, IdentityError> {
    debug_assert!(!state.closing);
    let snapshot = state.snapshot_after_mutation()?;
    Ok(persistence.submit(snapshot))
}

/// What enrolling a device under an invitation answers: the owner's result,
/// and the authorization the device's waiting link receives.
struct InvitedEnrollment {
    record: Result<DeviceRecord, IdentityError>,
    authorization: Result<AuthGrant, String>,
}

/// Enroll `device_public_key` under `invitation_id`: claim the invitation,
/// record the device, and hold the state lock until that snapshot is durable,
/// so no authorization reader observes a staged device. An uncommitted write
/// is rolled back. Both an owner's approval and a bound invitation's claim
/// enroll through here. Every argument is owned, so a caller can run it in a
/// task that outlives a link or admin client that drops mid-write.
async fn enroll_invited_device(
    mut state: OwnedMutexGuard<AuthState>,
    persistence: Arc<PersistenceCoordinator>,
    daemon_name: String,
    invitation_id: String,
    device_public_key: [u8; 32],
    device_name: String,
    now: u64,
) -> InvitedEnrollment {
    let Some(invitation) = state.invitations.get_mut(&invitation_id) else {
        let error = IdentityError::InvitationExpired(invitation_id);
        let authorization = Err(error.to_string());
        return InvitedEnrollment { record: Err(error), authorization };
    };
    let fingerprint = public_key_fingerprint(&device_public_key);
    let previous_claim = invitation.claimed_by.replace(fingerprint.clone());
    let previous_expiration = invitation.expires_at_unix;
    invitation.expires_at_unix =
        invitation.expires_at_unix.max(now.saturating_add(ENROLLMENT_RETRY_GRACE.as_secs()));
    let record = DeviceRecord {
        id: fingerprint.clone(),
        name: device_name,
        public_key: encode_key(&device_public_key),
        fingerprint,
        created_at_unix: now,
        last_seen_at_unix: now,
        revoked_at_unix: None,
    };
    let previous_device = state.devices.insert(record.id.clone(), record.clone());
    let generation = state.revocation_generation;
    let waiter = match submit_mutation(&persistence, &mut state) {
        Ok(waiter) => waiter,
        Err(error) => {
            rollback_approval(
                &mut state,
                &invitation_id,
                &record.id,
                previous_claim,
                previous_expiration,
                previous_device,
            );
            let authorization = Err(error.to_string());
            return InvitedEnrollment { record: Err(error), authorization };
        }
    };
    let grant = AuthGrant {
        device_id: record.id.clone(),
        daemon_name,
        revocation_generation: generation,
        authority: crate::crypto::ServiceAuthority::legacy_full(),
    };
    match waiter.wait_result().await {
        Ok(()) => {
            drop(state);
            InvitedEnrollment { record: Ok(record), authorization: Ok(grant) }
        }
        Err(PersistenceFailure::Committed(message)) => {
            drop(state);
            InvitedEnrollment {
                record: Err(IdentityError::Committed(message)),
                authorization: Ok(grant),
            }
        }
        Err(PersistenceFailure::Uncommitted(message)) => {
            rollback_approval(
                &mut state,
                &invitation_id,
                &record.id,
                previous_claim,
                previous_expiration,
                previous_device,
            );
            drop(state);
            InvitedEnrollment {
                record: Err(IdentityError::Persistence(message.clone())),
                authorization: Err(message),
            }
        }
    }
}

fn rollback_approval(
    state: &mut AuthState,
    invitation_id: &str,
    device_id: &str,
    previous_claim: Option<String>,
    previous_expiration: u64,
    previous_device: Option<DeviceRecord>,
) {
    let invitation = state
        .invitations
        .get_mut(invitation_id)
        .expect("approval keeps its invitation while persistence is pending");
    invitation.claimed_by = previous_claim;
    invitation.expires_at_unix = previous_expiration;
    if let Some(previous_device) = previous_device {
        state.devices.insert(device_id.to_owned(), previous_device);
    } else {
        state.devices.remove(device_id);
    }
}

#[async_trait]
impl ServerAuthenticator for AuthDatabase {
    async fn invitation_secret(&self, id: &str) -> Result<Option<[u8; 32]>, CryptoError> {
        let now = unix_time().map_err(|error| CryptoError::Unauthorized(error.to_string()))?;
        let (secret, persistence) = {
            let mut state = self.state.lock().await;
            let persistence = if state.prune_invitations(now) {
                state.ensure_open().map_err(|error| CryptoError::Link(error.to_string()))?;
                Some(
                    self.submit_mutation_locked(&mut state)
                        .map_err(|error| CryptoError::Link(error.to_string()))?,
                )
            } else {
                None
            };
            let secret = state
                .invitations
                .get(id)
                .filter(|invitation| invitation.expires_at_unix > now)
                .map(|invitation| invitation.secret);
            (secret, persistence)
        };
        if let Some(persistence) = persistence {
            persistence.wait().await.map_err(|error| CryptoError::Link(error.to_string()))?;
        }
        Ok(secret)
    }

    async fn authorize(&self, request: AuthRequest) -> Result<AuthGrant, String> {
        match request.mode {
            AuthKind::Enrolled => {
                let fingerprint = public_key_fingerprint(&request.device_public_key);
                let state = self.state.lock().await;
                let generation = state.revocation_generation;
                let device = state
                    .devices
                    .get(&fingerprint)
                    .ok_or_else(|| "device is not enrolled".to_string())?;
                if device.revoked_at_unix.is_some() {
                    return Err("device has been revoked".into());
                }
                if decode_key(&device.public_key).map_err(|error| error.to_string())?
                    != request.device_public_key
                {
                    return Err("device key does not match enrollment".into());
                }
                Ok(AuthGrant {
                    device_id: fingerprint,
                    daemon_name: self.daemon_name.clone(),
                    revocation_generation: generation,
                    authority: crate::crypto::ServiceAuthority::legacy_full(),
                })
            }
            // A trusted-network listener vouches for every peer that can reach it;
            // the grant still names the client's own key so connections stay
            // attributable and individually disconnectable. The `network:` prefix
            // keeps it apart from a policy-gated `carrier:` grant: the network's
            // membership, not `allow_carrier`, is what keeps it current.
            AuthKind::Carrier
                if matches!(&request.inbound, InboundAuthEvidence::TrustedNetwork(_)) =>
            {
                Ok(AuthGrant {
                    device_id: format!(
                        "{TRUSTED_NETWORK_DEVICE_PREFIX}{}",
                        public_key_fingerprint(&request.device_public_key)
                    ),
                    daemon_name: self.daemon_name.clone(),
                    revocation_generation: *self.revocation_tx.borrow(),
                    authority: crate::crypto::ServiceAuthority::legacy_full(),
                })
            }
            AuthKind::Carrier
                if self.allow_carrier
                    && matches!(
                        &request.inbound,
                        InboundAuthEvidence::Kernel(_) | InboundAuthEvidence::Ssh(_)
                    ) =>
            {
                Ok(AuthGrant {
                    device_id: format!(
                        "carrier:{}",
                        public_key_fingerprint(&request.device_public_key)
                    ),
                    daemon_name: self.daemon_name.clone(),
                    revocation_generation: *self.revocation_tx.borrow(),
                    authority: crate::crypto::ServiceAuthority::legacy_full().same_owner(),
                })
            }
            AuthKind::Carrier => Err("trusted carrier access is disabled or unavailable".into()),
            // A grant's session ignores the revocation generation (a grant is
            // not a device record), so it is pinned to 0: a revocation between
            // two lane handshakes never splits one connection's lanes.
            AuthKind::Grant => {
                let verifier = self
                    .grant_verifier
                    .get()
                    .ok_or_else(|| "carrier grants are not accepted by this daemon".to_string())?;
                let admission = match request.grant.as_ref() {
                    Some(token) => {
                        let admission = verifier.verify(crate::grant::GrantPresentation {
                            token: token.as_str(),
                            noise_key: &request.device_public_key,
                            link_group: crate::grant::link_group(
                                request.session,
                                request.generation,
                                request.connection_attempt,
                            ),
                        })?;
                        if !crate::grant::is_grant_device_id(&admission.device_id) {
                            return Err(
                                "carrier grant verifier answered a non-grant device id".into()
                            );
                        }
                        self.admitted_grants.remember(
                            request.device_public_key,
                            request.session,
                            admission.clone(),
                        );
                        admission
                    }
                    // A resume: only into a session this key already holds
                    // (the daemon refuses generation 1+ without one).
                    None if request.generation > 0 => self
                        .admitted_grants
                        .get(&request.device_public_key, request.session)
                        .ok_or_else(|| {
                            "no carrier grant admitted this key; ask for a grant".to_string()
                        })?,
                    None => return Err("a new carrier session needs a grant".into()),
                };
                Ok(AuthGrant {
                    device_id: admission.device_id,
                    daemon_name: self.daemon_name.clone(),
                    revocation_generation: 0,
                    authority: admission.authority,
                })
            }
            AuthKind::Invitation => {
                let invitation_id = request
                    .invitation_id
                    .clone()
                    .ok_or_else(|| "invitation id is missing".to_string())?;
                let now = unix_time().map_err(|error| error.to_string())?;
                let fingerprint = public_key_fingerprint(&request.device_public_key);
                let (decision_tx, decision_rx) = oneshot::channel();
                let pending_token = Arc::new(());
                {
                    let mut state = Arc::clone(&self.state).lock_owned().await;
                    state.ensure_open().map_err(|error| error.to_string())?;
                    let invitation = state
                        .invitations
                        .get(&invitation_id)
                        .ok_or_else(|| "invitation is unknown or expired".to_string())?;
                    if invitation.expires_at_unix <= now {
                        return Err("invitation is expired".into());
                    }
                    // A bound invitation admits its one key and no other: a
                    // stranger is refused before it can queue or claim anything.
                    let bound_device_name = match &invitation.bound_device {
                        Some(bound) if bound.public_key != request.device_public_key => {
                            return Err("invitation is bound to another device".into());
                        }
                        Some(bound) => Some(bound.name.clone()),
                        None => None,
                    };
                    if let Some(claimed_by) = &invitation.claimed_by {
                        if claimed_by != &fingerprint {
                            return Err("invitation was already claimed by another device".into());
                        }
                        let generation = state.revocation_generation;
                        let device = state.devices.get(&fingerprint).ok_or_else(|| {
                            "claimed invitation has no enrolled device".to_string()
                        })?;
                        if device.revoked_at_unix.is_some()
                            || decode_key(&device.public_key).map_err(|error| error.to_string())?
                                != request.device_public_key
                        {
                            return Err("device enrollment is no longer active".into());
                        }
                        return Ok(AuthGrant {
                            device_id: fingerprint,
                            daemon_name: self.daemon_name.clone(),
                            revocation_generation: generation,
                            authority: crate::crypto::ServiceAuthority::legacy_full(),
                        });
                    }
                    if let Some(owner_given_name) = bound_device_name {
                        // The owner approved this key when binding the
                        // invitation to it: enroll it now, as an approval
                        // would. Like an approval, the write runs in its own
                        // task, so a link that drops mid-write cannot strand
                        // a staged device.
                        let enrollment = enroll_invited_device(
                            state,
                            Arc::clone(&self.persistence),
                            self.daemon_name.clone(),
                            invitation_id,
                            request.device_public_key,
                            owner_given_name.unwrap_or(request.device_name),
                            now,
                        );
                        return outlive_caller("identity enrollment", enrollment)
                            .await
                            .and_then(|enrollment| enrollment.authorization);
                    }
                    if let Some(existing) = state.pending.get(&invitation_id) {
                        // Another device may never ride on, or displace, this request.
                        if existing.device_public_key != request.device_public_key {
                            return Err("invitation already has a pending enrollment".into());
                        }
                        // The same device presents the invitation again: its client gave up on
                        // the link that is waiting (a network change or a dropped link abandons
                        // the attempt, and the redial presents the invitation again), and that
                        // waiter's link is gone. This attempt takes over the request, so the
                        // person's approval reaches the link the device is on now.
                        if let Some(superseded) = state.pending.remove(&invitation_id) {
                            let _ = superseded.decision.send(Err(
                                "a newer connection from this device took over the enrollment request"
                                    .into(),
                            ));
                        }
                    }
                    state.pending.insert(
                        invitation_id.clone(),
                        PendingDecision {
                            request: PendingEnrollment {
                                invitation_id: invitation_id.clone(),
                                device_name: request.device_name,
                                device_fingerprint: fingerprint,
                                requested_at_unix: now,
                            },
                            device_public_key: request.device_public_key,
                            decision: decision_tx,
                            token: Arc::clone(&pending_token),
                        },
                    );
                }
                let mut cleanup =
                    PendingDecisionCleanup::new(&self.state, invitation_id.clone(), pending_token);
                self.pending_changed.notify_waiters();
                let result = match tokio::time::timeout(APPROVAL_TIMEOUT, decision_rx).await {
                    Ok(Ok(result)) => result,
                    Ok(Err(_)) => Err("enrollment approval channel closed".into()),
                    Err(_) => Err("enrollment approval timed out".into()),
                };
                cleanup.finish().await;
                result
            }
        }
    }
}

pub(super) struct AuthState {
    revision: u64,
    revocation_generation: u64,
    closing: bool,
    devices: HashMap<String, DeviceRecord>,
    pub(super) invitations: HashMap<String, InvitationRecord>,
    pending: HashMap<String, PendingDecision>,
    recorded_connection_attempts: HashMap<(String, ConnectionAttemptId), u64>,
    recorded_connection_attempt_order: VecDeque<(String, ConnectionAttemptId)>,
}

impl AuthState {
    fn from_persisted(persisted: PersistedState) -> Self {
        let now = unix_time().unwrap_or(0);
        Self {
            revision: persisted.revision,
            revocation_generation: persisted.revocation_generation,
            closing: false,
            devices: persisted
                .devices
                .into_iter()
                .map(|device| (device.id.clone(), device))
                .collect(),
            invitations: persisted
                .invitations
                .into_iter()
                .filter(|invitation| invitation.expires_at_unix > now)
                .filter_map(|invitation| {
                    // A binding that does not decode drops the invitation: it
                    // must never load as an unbound one.
                    let bound_device = match invitation.bound_device {
                        Some(public_key) => Some(BoundDevice {
                            public_key: decode_key(&public_key).ok()?,
                            name: invitation.bound_device_name,
                        }),
                        None => None,
                    };
                    Some((
                        invitation.id,
                        InvitationRecord {
                            secret: decode_key(&invitation.secret).ok()?,
                            expires_at_unix: invitation.expires_at_unix,
                            route_hints: invitation.route_hints,
                            claimed_by: invitation.claimed_by,
                            bound_device,
                        },
                    ))
                })
                .collect(),
            pending: HashMap::new(),
            recorded_connection_attempts: HashMap::new(),
            recorded_connection_attempt_order: VecDeque::new(),
        }
    }

    fn snapshot_after_mutation(&mut self) -> Result<PersistedState, IdentityError> {
        self.revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| IdentityError::Invalid("identity revision exhausted".into()))?;
        Ok(self.to_persisted())
    }

    fn ensure_open(&self) -> Result<(), IdentityError> {
        if self.closing {
            return Err(IdentityError::Persistence("authorization state is shutting down".into()));
        }
        Ok(())
    }

    fn to_persisted(&self) -> PersistedState {
        PersistedState {
            version: AUTH_STATE_VERSION,
            revision: self.revision,
            revocation_generation: self.revocation_generation,
            devices: self.devices.values().cloned().collect(),
            invitations: self
                .invitations
                .iter()
                .map(|(id, invitation)| PersistedInvitation {
                    id: id.clone(),
                    secret: encode_key(&invitation.secret),
                    expires_at_unix: invitation.expires_at_unix,
                    route_hints: invitation.route_hints.clone(),
                    claimed_by: invitation.claimed_by.clone(),
                    bound_device: invitation
                        .bound_device
                        .as_ref()
                        .map(|device| encode_key(&device.public_key)),
                    bound_device_name: invitation
                        .bound_device
                        .as_ref()
                        .and_then(|device| device.name.clone()),
                })
                .collect(),
        }
    }

    fn prune_invitations(&mut self, now: u64) -> bool {
        let previous = self.invitations.len();
        self.invitations.retain(|id, invitation| {
            invitation.expires_at_unix > now || self.pending.contains_key(id)
        });
        self.invitations.len() != previous
    }
}

pub(super) struct InvitationRecord {
    secret: [u8; 32],
    pub(super) expires_at_unix: u64,
    route_hints: Vec<String>,
    pub(super) claimed_by: Option<String>,
    /// Only this device may claim the invitation; it enrolls with no approval.
    pub(super) bound_device: Option<BoundDevice>,
}

struct PendingDecision {
    request: PendingEnrollment,
    device_public_key: [u8; 32],
    decision: oneshot::Sender<Result<AuthGrant, String>>,
    token: Arc<()>,
}

struct PendingDecisionCleanup {
    state: Weak<Mutex<AuthState>>,
    invitation_id: String,
    token: Arc<()>,
    armed: bool,
}

impl PendingDecisionCleanup {
    fn new(state: &Arc<Mutex<AuthState>>, invitation_id: String, token: Arc<()>) -> Self {
        Self { state: Arc::downgrade(state), invitation_id, token, armed: true }
    }

    async fn finish(&mut self) {
        if let Some(state) = self.state.upgrade() {
            let mut locked = state.lock().await;
            remove_pending_decision(&mut locked, &self.invitation_id, &self.token);
        }
        self.armed = false;
    }
}

impl Drop for PendingDecisionCleanup {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let Some(state) = self.state.upgrade() else {
            return;
        };
        if let Ok(mut locked) = state.try_lock() {
            remove_pending_decision(&mut locked, &self.invitation_id, &self.token);
            return;
        }
        let invitation_id = self.invitation_id.clone();
        let token = Arc::clone(&self.token);
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let mut locked = state.lock().await;
                remove_pending_decision(&mut locked, &invitation_id, &token);
            });
            return;
        }

        let synchronous_fallback = Arc::clone(&state);
        let fallback_invitation_id = invitation_id.clone();
        let fallback_token = Arc::clone(&token);
        if std::thread::Builder::new()
            .name("cmux-pending-enrollment-cleanup".into())
            .spawn(move || {
                let mut locked = state.blocking_lock();
                remove_pending_decision(&mut locked, &invitation_id, &token);
            })
            .is_err()
        {
            let mut locked = synchronous_fallback.blocking_lock();
            remove_pending_decision(&mut locked, &fallback_invitation_id, &fallback_token);
        }
    }
}

fn remove_pending_decision(state: &mut AuthState, invitation_id: &str, token: &Arc<()>) {
    if state.pending.get(invitation_id).is_some_and(|pending| Arc::ptr_eq(&pending.token, token)) {
        state.pending.remove(invitation_id);
    }
}
