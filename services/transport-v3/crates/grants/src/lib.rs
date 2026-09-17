//! V3 permissions shared by native endpoints and servers. No ACL evaluator or network I/O.
//! Callers must check an admission before every protected operation and schedule its expiry.

use std::collections::{BTreeMap, BTreeSet};

use ed25519_dalek::{pkcs8::EncodePrivateKey, SigningKey, VerifyingKey};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
use libp2p_identity::PeerId;
use serde::{Deserialize, Serialize};
use thiserror::Error;

const ISSUER: &str = "cmux-transport-v3";
const TOKEN_TYPE: &str = "cmux-v3-grant+jwt";
const REVOCATION_TOKEN_TYPE: &str = "cmux-v3-revocation+jwt";
const MAX_TOKEN_BYTES: usize = 8192;

/// Expected scope supplied by the receiving service, with transport-authenticated peer IDs.
#[derive(Clone, Copy)]
pub struct Scope<'a> {
    pub team: &'a str,
    pub source: PeerId,
    pub destination: PeerId,
    pub action: &'a str,
}

/// Absence or zero is never interpreted as unlimited access.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "mode", rename_all = "snake_case", deny_unknown_fields)]
pub enum OfflineAccess {
    Bounded { seconds: u32 },
    UntilRevoked {},
}

impl Default for OfflineAccess {
    fn default() -> Self {
        Self::Bounded { seconds: 300 }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LeasePolicy {
    pub offline: OfflineAccess,
    pub renew_every_seconds: u32,
}

impl Default for LeasePolicy {
    fn default() -> Self {
        Self {
            offline: OfflineAccess::Bounded { seconds: 300 },
            renew_every_seconds: 30,
        }
    }
}

impl LeasePolicy {
    pub fn validate(self) -> Result<Self, Error> {
        if self.renew_every_seconds == 0
            || matches!(self.offline, OfflineAccess::Bounded { seconds }
                if seconds == 0 || self.renew_every_seconds >= seconds)
        {
            return Err(Error::InvalidPolicy);
        }
        Ok(self)
    }

    /// The offline budget starts at the authority's last verified state, not at cache access.
    pub fn deadline(self, verified_at: u64, now: u64) -> Result<Option<u64>, Error> {
        self.validate()?;
        if verified_at > now {
            return Err(Error::InvalidPolicy);
        }
        match self.offline {
            OfflineAccess::UntilRevoked {} => Ok(None),
            OfflineAccess::Bounded { seconds } => {
                let deadline = verified_at
                    .checked_add(u64::from(seconds))
                    .ok_or(Error::InvalidPolicy)?;
                if now >= deadline {
                    return Err(Error::Expired);
                }
                Ok(Some(deadline))
            }
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Grant {
    pub iss: String,
    /// Destination libp2p identity, also the JWT audience.
    pub aud: String,
    /// Initiating libp2p identity, authenticated by the transport, never the request body.
    pub sub: String,
    pub team_id: String,
    pub action: String,
    pub policy_revision: u64,
    pub lease: LeasePolicy,
    pub iat: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exp: Option<u64>,
}

/// Monotonic authorization state delivered to endpoints and relays. This is a
/// signed snapshot delta, not a client assertion. Missing updates are detected
/// by the sequence and policy revision and must be fetched before admission.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RevocationUpdate {
    pub key_id: String,
    pub team_id: String,
    pub sequence: u64,
    pub policy_revision: u64,
    pub revoked_peers: Vec<String>,
    pub issued_at: u64,
}
impl RevocationUpdate {
    fn validate(&self, now: u64) -> Result<(), Error> {
        if self.key_id.is_empty()
            || self.key_id.len() > 128
            || self.team_id.is_empty()
            || self.team_id.len() > 256
            || self.sequence == 0
            || self.policy_revision == 0
            || self.issued_at > now
            || now - self.issued_at > 300
            || self.revoked_peers.len() > 10000
            || self
                .revoked_peers
                .iter()
                .any(|peer| peer.parse::<PeerId>().is_err())
        {
            return Err(Error::InvalidGrant);
        }
        Ok(())
    }
}

impl Grant {
    pub fn new(
        scope: Scope<'_>,
        policy_revision: u64,
        lease: LeasePolicy,
        verified_at: u64,
        now: u64,
    ) -> Result<Self, Error> {
        let grant = Self {
            iss: ISSUER.into(),
            aud: scope.destination.to_string(),
            sub: scope.source.to_string(),
            team_id: scope.team.into(),
            action: scope.action.into(),
            policy_revision,
            lease,
            iat: now,
            exp: lease.deadline(verified_at, now)?,
        };
        grant.validate(now)?;
        Ok(grant)
    }

    fn validate(&self, now: u64) -> Result<(), Error> {
        self.lease.validate()?;
        if self.iss != ISSUER
            || self.team_id.is_empty()
            || self.team_id.len() > 256
            || self.action.is_empty()
            || self.action.len() > 128
            || self.iat > now
            || self.sub.parse::<PeerId>().is_err()
            || self.aud.parse::<PeerId>().is_err()
        {
            return Err(Error::InvalidGrant);
        }
        match (self.lease.offline, self.exp) {
            (OfflineAccess::UntilRevoked {}, None) => Ok(()),
            (OfflineAccess::Bounded { seconds }, Some(exp))
                if exp > self.iat && exp - self.iat <= u64::from(seconds) =>
            {
                if now >= exp {
                    Err(Error::Expired)
                } else {
                    Ok(())
                }
            }
            _ => Err(Error::InvalidGrant),
        }
    }
}

/// Server-only ownership: clients receive public keys, never this signer.
pub struct GrantSigner {
    key_id: String,
    key: EncodingKey,
}

impl GrantSigner {
    pub fn new(key_id: String, key: &SigningKey) -> Result<Self, Error> {
        if key_id.is_empty() || key_id.len() > 128 {
            return Err(Error::InvalidGrant);
        }
        let der = key.to_pkcs8_der().map_err(|_| Error::InvalidGrant)?;
        Ok(Self {
            key_id,
            key: EncodingKey::from_ed_der(der.as_bytes()),
        })
    }

    pub fn sign(&self, grant: &Grant, now: u64) -> Result<String, Error> {
        grant.validate(now)?;
        let mut header = Header::new(Algorithm::EdDSA);
        header.typ = Some(TOKEN_TYPE.into());
        header.kid = Some(self.key_id.clone());
        jsonwebtoken::encode(&header, grant, &self.key).map_err(|_| Error::InvalidGrant)
    }

    pub fn sign_revocation(&self, mut update: RevocationUpdate, now: u64) -> Result<String, Error> {
        update.key_id = self.key_id.clone();
        update.validate(now)?;
        let mut header = Header::new(Algorithm::EdDSA);
        header.typ = Some(REVOCATION_TOKEN_TYPE.into());
        header.kid = Some(self.key_id.clone());
        jsonwebtoken::encode(&header, &update, &self.key).map_err(|_| Error::InvalidGrant)
    }
}

/// Supplied by trusted server configuration, not populated from token headers.
#[derive(Default)]
pub struct AuthorityKeys(BTreeMap<String, DecodingKey>);

impl AuthorityKeys {
    pub fn insert(&mut self, key_id: String, public_key: VerifyingKey) {
        self.0
            .insert(key_id, DecodingKey::from_ed_der(public_key.as_bytes()));
    }

    pub fn admit(
        &self,
        token: &str,
        scope: Scope<'_>,
        now: u64,
        revocations: &Revocations,
    ) -> Result<Admission, Error> {
        if token.len() > MAX_TOKEN_BYTES {
            return Err(Error::InvalidGrant);
        }
        let header = jsonwebtoken::decode_header(token).map_err(|_| Error::InvalidGrant)?;
        if header.alg != Algorithm::EdDSA || header.typ.as_deref() != Some(TOKEN_TYPE) {
            return Err(Error::InvalidGrant);
        }
        let key = header
            .kid
            .as_ref()
            .and_then(|id| self.0.get(id))
            .ok_or(Error::UnknownSigner)?;
        let mut validation = Validation::new(Algorithm::EdDSA);
        validation.set_required_spec_claims(&["iss", "aud", "sub", "iat"]);
        validation.set_issuer(&[ISSUER]);
        validation.set_audience(&[scope.destination.to_string()]);
        // Expiration is checked below against an injected clock, including explicit unlimited mode.
        validation.validate_exp = false;
        validation.leeway = 0;
        let grant = jsonwebtoken::decode::<Grant>(token, key, &validation)
            .map_err(|_| Error::InvalidGrant)?
            .claims;
        if grant.team_id != scope.team
            || grant.sub != scope.source.to_string()
            || grant.aud != scope.destination.to_string()
            || grant.action != scope.action
        {
            return Err(Error::WrongScope);
        }
        let admission = Admission(grant);
        admission.check(now, revocations)?;
        Ok(admission)
    }

    pub fn admit_revocation(
        &self,
        token: &str,
        team: &str,
        now: u64,
    ) -> Result<RevocationUpdate, Error> {
        if token.len() > MAX_TOKEN_BYTES || team.len() > 256 {
            return Err(Error::InvalidGrant);
        }
        let header = jsonwebtoken::decode_header(token).map_err(|_| Error::InvalidGrant)?;
        if header.alg != Algorithm::EdDSA || header.typ.as_deref() != Some(REVOCATION_TOKEN_TYPE) {
            return Err(Error::InvalidGrant);
        }
        let key = header
            .kid
            .as_ref()
            .and_then(|id| self.0.get(id))
            .ok_or(Error::UnknownSigner)?;
        let mut validation = Validation::new(Algorithm::EdDSA);
        validation.validate_exp = false;
        validation.leeway = 0;
        validation.required_spec_claims.clear();
        let update = jsonwebtoken::decode::<RevocationUpdate>(token, key, &validation)
            .map_err(|_| Error::InvalidGrant)?
            .claims;
        if !team.is_empty() && update.team_id != team {
            return Err(Error::WrongScope);
        }
        update.validate(now)?;
        Ok(update)
    }
}

/// Authenticated updates only. Revisions invalidate older grants, including unlimited ones.
#[derive(Default, Clone)]
pub struct Revocations {
    revisions: BTreeMap<String, u64>,
    devices: BTreeSet<(String, PeerId)>,
    sequences: BTreeMap<String, u64>,
}

impl Revocations {
    pub fn advance_policy(&mut self, team: String, revision: u64) {
        let current = self.revisions.entry(team).or_default();
        *current = (*current).max(revision);
    }
    pub fn revoke_device(&mut self, team: String, peer: PeerId) {
        self.devices.insert((team, peer));
    }
    pub fn apply_update(&mut self, update: &RevocationUpdate) -> Result<(), Error> {
        if let Some(previous) = self.sequences.get(&update.team_id) {
            if update.sequence != previous.saturating_add(1) {
                return Err(Error::InvalidGrant);
            }
        } else if update.sequence != 1 {
            return Err(Error::InvalidGrant);
        }
        self.sequences
            .insert(update.team_id.clone(), update.sequence);
        self.advance_policy(update.team_id.clone(), update.policy_revision);
        for peer in &update.revoked_peers {
            self.revoke_device(
                update.team_id.clone(),
                peer.parse().map_err(|_| Error::InvalidGrant)?,
            );
        }
        Ok(())
    }
}

pub struct Admission(Grant);

impl Admission {
    pub fn version(&self) -> (u64, u64) {
        (self.0.policy_revision, self.0.iat)
    }
    pub fn expires_at(&self) -> Option<u64> {
        self.0.exp
    }
    pub fn check(&self, now: u64, revocations: &Revocations) -> Result<(), Error> {
        self.0.validate(now)?;
        if revocations
            .revisions
            .get(&self.0.team_id)
            .is_some_and(|r| *r > self.0.policy_revision)
            || [self.0.sub.as_str(), self.0.aud.as_str()]
                .iter()
                .any(|peer| {
                    peer.parse().is_ok_and(|peer| {
                        revocations
                            .devices
                            .contains(&(self.0.team_id.clone(), peer))
                    })
                })
        {
            return Err(Error::Revoked);
        }
        Ok(())
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum Error {
    #[error("invalid lease policy")]
    InvalidPolicy,
    #[error("invalid signed grant")]
    InvalidGrant,
    #[error("unknown authority signing key")]
    UnknownSigner,
    #[error("grant does not authorize this device pair, team, or operation")]
    WrongScope,
    #[error("authorization expired")]
    Expired,
    #[error("authorization revoked")]
    Revoked,
}
