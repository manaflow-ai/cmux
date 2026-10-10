//! The session host's side of launch credentials (plans/cmux-next/identity.md
//! sections 2 and 3): it mints one per terminal child and per ACP session,
//! and turns a presented credential into the request's actor.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::*;
use crate::launch_credential::{Claims, VerifyError, valid_subject};

/// What a presented credential means.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CredentialCheck {
    /// It verified and names a live subject of this session.
    Verified(Actor),
    /// Its key was dropped by rotation: the request counts as if it carried
    /// no credential.
    UnknownKey,
    /// Tampered, malformed, for another session or for a closed terminal.
    /// The reason is a stable wire word.
    Refused(&'static str),
}

impl Mux {
    /// The credential a new terminal's child receives; None when minting
    /// fails (the child then has none and its calls are the user's).
    pub(crate) fn mint_terminal_credential(&self, terminal: &TerminalPublicId) -> Option<String> {
        self.launch_identity.mint(&self.claims(Some(terminal.as_str()), None, None))
    }

    /// `credential.mint {acp_session, agent?}`: a credential for one acpmux
    /// ACP session. acpmux owns that session's lifetime: the daemon cannot
    /// see it, so such a credential stays valid until two rotations drop
    /// its key (slice 4 adds acpmux-side revocation).
    pub(crate) fn mint_acp_session_credential(
        &self,
        acp_session: &str,
        agent: Option<&str>,
    ) -> Result<Value, ResourceError> {
        if !valid_subject(acp_session) {
            return Err(ResourceError::validation_invalid(Some("acp_session"), "invalid_subject"));
        }
        if agent.is_some_and(|agent| !valid_subject(agent)) {
            return Err(ResourceError::validation_invalid(Some("agent"), "invalid_subject"));
        }
        let claims = self.claims(None, Some(acp_session), agent);
        let actor =
            Actor::AcpSession { id: acp_session.to_string(), agent: agent.map(str::to_string) };
        match self.launch_identity.mint(&claims) {
            Some(credential) => Ok(json!({"credential": credential, "actor": actor.wire()})),
            None => Err(ResourceError::operation_failed(
                "credential.mint",
                "no launch key is available",
                json!({"reason": "no_launch_key"}),
            )),
        }
    }

    fn claims(
        &self,
        terminal: Option<&str>,
        acp_session: Option<&str>,
        agent: Option<&str>,
    ) -> Claims {
        Claims {
            v: 1,
            host: self.session_public_id.as_str().to_string(),
            terminal: terminal.map(str::to_string),
            acp_session: acp_session.map(str::to_string),
            agent: agent.map(str::to_string),
            iat: SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs()),
        }
    }

    /// Check a credential. Liveness reads mux state only, never the
    /// registry, so callers run it before `commit_state` takes its locks.
    pub(crate) fn check_launch_credential(&self, credential: &str) -> CredentialCheck {
        let claims = match self.launch_identity.verify(credential) {
            Ok(claims) => claims,
            Err(VerifyError::UnknownKey) => return CredentialCheck::UnknownKey,
            Err(VerifyError::Malformed) => return CredentialCheck::Refused("credential_malformed"),
            Err(VerifyError::BadMac) => return CredentialCheck::Refused("credential_invalid"),
        };
        if claims.host != self.session_public_id.as_str() {
            return CredentialCheck::Refused("credential_foreign_host");
        }
        match (claims.terminal, claims.acp_session) {
            (Some(terminal), None) => {
                let live = TerminalPublicId::parse(terminal.clone())
                    .is_ok_and(|terminal| self.terminal_resource_surface(&terminal).is_some());
                if live {
                    CredentialCheck::Verified(Actor::Terminal { id: terminal })
                } else {
                    CredentialCheck::Refused("credential_closed")
                }
            }
            (None, Some(id)) => {
                CredentialCheck::Verified(Actor::AcpSession { id, agent: claims.agent })
            }
            _ => CredentialCheck::Refused("credential_malformed"),
        }
    }

    /// `credential.verify`: never an error for a bad credential, an answer.
    pub(crate) fn verify_launch_credential(&self, credential: &str) -> Value {
        match self.check_launch_credential(credential) {
            CredentialCheck::Verified(actor) => json!({"valid": true, "actor": actor.wire()}),
            CredentialCheck::UnknownKey => json!({"valid": false, "reason": "unknown_key"}),
            CredentialCheck::Refused(reason) => json!({"valid": false, "reason": reason}),
        }
    }

    /// The actor of one request: `connection` is what the connection proves,
    /// `credential` what the request presents. A verified credential wins
    /// over the connection's own identity; a dropped key counts as absent; a
    /// refused credential refuses the request (`validation.invalid` on field
    /// `credential`). Only a local connection may present one.
    pub(crate) fn request_actor(
        &self,
        connection: Actor,
        credential: Option<&str>,
    ) -> Result<Actor, ResourceError> {
        let Some(credential) = credential else { return Ok(connection) };
        let refuse =
            |reason: &'static str| ResourceError::validation_invalid(Some("credential"), reason);
        if !matches!(connection, Actor::User { .. } | Actor::Frontend { .. }) {
            return Err(refuse("credential_not_local"));
        }
        match self.check_launch_credential(credential) {
            CredentialCheck::Verified(actor) => Ok(actor),
            CredentialCheck::UnknownKey => Ok(connection),
            CredentialCheck::Refused(reason) => Err(refuse(reason)),
        }
    }

    /// `credential.rotate`; the connection gate already checked the owner.
    pub(crate) fn rotate_launch_keys(&self, idempotency_key: &str) -> Result<Value, ResourceError> {
        let (kid, replayed) = self.launch_identity.rotate(idempotency_key).map_err(|error| {
            ResourceError::operation_failed(
                "credential.rotate",
                "the launch keys could not be rotated",
                json!({"reason": "rotate_failed", "error": error.to_string()}),
            )
        })?;
        let (_, generation) = self.registry_identity();
        // The keys are the session host's, not the registry's: revision 0.
        Ok(
            json!({"value": {"kid": kid}, "generation": generation, "revision": "0", "replayed": replayed}),
        )
    }
}
