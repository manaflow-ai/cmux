//! Pairing requests: begin, respond, resolve via the resource API, cancel, authenticate, and list pending pairings.

use super::*;

impl Mux {
    pub fn begin_pairing(
        &self,
        peer: std::net::IpAddr,
    ) -> Result<(PairingChallenge, Receiver<PairingDecision>), PairingError> {
        let result = self.pairing.begin(peer)?;
        self.emit(MuxEvent::PairingRequested(result.0.clone()));
        Ok(result)
    }

    pub fn respond_pairing(&self, id: u64, approve: bool) -> bool {
        let responded = self.pairing.respond(id, approve);
        if responded {
            self.emit(MuxEvent::PairingResolved { request: id });
        }
        responded
    }

    pub(crate) fn resource_resolve_pairing_selected(
        &self,
        selectors: crate::ResourceSelectors,
        pairing_id: &PairingRequestPublicId,
        decision: &str,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = serde_json::json!({
            "operation":"pairing_request.resolve",
            "selectors":selectors,
            "pairing_request_id":pairing_id,
            "decision":decision,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) =
            registry.replay_resource_patch(mutation, "pairing_request.resolve", &fingerprint)?
        {
            return Ok(replay);
        }

        let approve = match decision {
            "accept" => true,
            "reject" => false,
            _ => {
                return Err(anyhow::Error::new(ResourceError::validation_invalid(
                    Some("decision"),
                    "pairing decision must be accept or reject",
                )));
            }
        };
        let payload =
            pairing_id.as_str().strip_prefix("pairing_").expect("typed pairing id prefix");
        let numeric = u128::from_str_radix(payload, 16)
            .ok()
            .and_then(|value| u64::try_from(value).ok())
            .ok_or_else(|| {
                anyhow::Error::new(ResourceError::not_found("pairing_request", pairing_id.as_str()))
            })?;

        let mut session_selectors = selectors;
        session_selectors.pairing_request = None;
        let mut state = self.state.lock().unwrap();
        let resolved = self
            .resolve_resource_path_in_state(
                &state,
                &registry,
                crate::ResourceTarget::Session,
                &session_selectors,
            )
            .map_err(anyhow::Error::new)?;
        let session_id =
            resolved.path.session.context("pairing route omitted its session identity")?;

        let commit = self
            .pairing
            .respond_after(numeric, approve, |challenge| {
                let status = if approve { "accepted" } else { "rejected" };
                let value = serde_json::json!({
                    "pairing_request":{
                        "id":pairing_id,
                        "session_id":session_id,
                        "peer":challenge.peer,
                        "code":challenge.code,
                        "expires_in_seconds":challenge.expires_in.to_string(),
                        "status":status,
                    },
                });
                let deltas = serde_json::json!([{
                    "kind":"delete",
                    "sequence":0,
                    "resource":"pairing_request",
                    "id":pairing_id,
                }]);
                registry.commit_resource_patch(
                    mutation,
                    "pairing_request.resolve",
                    &fingerprint,
                    None,
                    expected_revision,
                    &ResourcePatch { changes: Vec::new() },
                    &value,
                    &deltas,
                )
            })?
            .ok_or_else(|| {
                anyhow::Error::new(ResourceError::not_found("pairing_request", pairing_id.as_str()))
            })?;

        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
            self.emit(MuxEvent::PairingResolved { request: numeric });
        }
        Ok(commit)
    }

    pub fn cancel_pairing(&self, id: u64) {
        if self.pairing.cancel(id) {
            self.emit(MuxEvent::PairingResolved { request: id });
        }
    }

    pub fn authenticate_pairing_credential(&self, credential: &str) -> bool {
        self.pairing.authenticate(credential)
    }

    pub fn pending_pairings(&self) -> Vec<PairingChallenge> {
        self.pairing.pending()
    }
}
