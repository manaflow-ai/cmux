//! One explicitly pinned authority owns pause, priority, spacing and retry occupancy for
//! every enrolled daemon. An unreachable authority is a refusal, never a local fallback.
use super::resume_admission::{Binding, Permit};
use super::*;

impl Hub {
    pub(crate) async fn bind_fleet(&self, peer: &str) -> Result<Value, RpcError> {
        let binding = if peer == "local" {
            match self.resume_admission.binding() {
                Some(binding @ Binding::Authority { .. }) => binding,
                _ => Binding::Authority { id: uuid::Uuid::now_v7().to_string() },
            }
        } else {
            let remote = self.peer_by_name(peer).ok_or_else(|| {
                RpcError::invalid_params("fleet authority peer is not configured")
            })?;
            let status =
                remote.request(super::finished::METHOD, json!({"op": "fleet_status"})).await?;
            let id = status["authorityId"].as_str().ok_or_else(|| {
                RpcError::invalid_params("peer did not identify a fleet authority")
            })?;
            Binding::Member { peer: peer.into(), id: id.into() }
        };
        self.resume_admission.bind(binding.clone())?;
        Ok(json!({"binding": binding, "next": "verify every intended member before fleet-resume"}))
    }

    pub(crate) async fn fleet_call(&self, op: &str, mut params: Value) -> Result<Value, RpcError> {
        let binding = self.resume_admission.binding().ok_or_else(|| {
            RpcError::invalid_params("no shared fleet authority: run fleet-bind local on one authority, then fleet-bind PEER on every member")
        })?;
        params["op"] = json!(op);
        match binding {
            Binding::Authority { id } => {
                params["authorityId"] = json!(id);
                self.fleet_authority(&params).await
            }
            Binding::Member { peer, id } => {
                params["authorityId"] = json!(id);
                self.peer_by_name(&peer)
                    .ok_or_else(|| {
                        RpcError::invalid_params("pinned fleet authority peer is missing")
                    })?
                    .request(super::finished::METHOD, params)
                    .await
            }
        }
    }

    pub(crate) async fn fleet_authority(&self, params: &Value) -> Result<Value, RpcError> {
        let op = params["op"].as_str().unwrap_or("");
        let expected = params["authorityId"].as_str();
        if op != "fleet_status" && expected.is_none() {
            return Err(RpcError::invalid_params("pinned fleet authorityId is required"));
        }
        let status = self.resume_admission.authority_status(expected)?;
        match op {
            "fleet_status" => Ok(status),
            "fleet_pause" | "fleet_resume" => {
                let reason = params["reason"]
                    .as_str()
                    .filter(|r| !r.trim().is_empty())
                    .ok_or_else(|| RpcError::invalid_params("a reason is required"))?;
                self.resume_admission.pause((op == "fleet_pause").then_some(reason))?;
                self.resume_admission.authority_status(expected)
            }
            "fleet_acquire" => {
                let ticket = params["ticket"].as_str().unwrap_or("");
                let priority = params["priority"].as_u64().unwrap_or(2).min(255) as u8;
                self.resume_admission.reserve(ticket, priority).await?;
                Ok(json!({"ticket": ticket, "authorityId": expected}))
            }
            "fleet_release" => {
                let ticket = params["ticket"]
                    .as_str()
                    .ok_or_else(|| RpcError::invalid_params("ticket is required"))?;
                self.resume_admission.release(ticket)?;
                Ok(json!({"released": ticket, "authorityId": expected}))
            }
            _ => Err(RpcError::invalid_params("unknown fleet admission operation")),
        }
    }

    pub(super) fn check_background_session(&self, session: &Session) -> Result<(), RpcError> {
        self.check_finished(session)?;
        if session
            .meta
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .goal
            .as_ref()
            .is_some_and(|goal| goal.lifecycle() == "paused")
        {
            return Err(RpcError::invalid_params(
                "session goal is paused; background work cannot resume it",
            )
            .with_data(json!({"reason": "session.paused"})));
        }
        Ok(())
    }

    pub(super) async fn admit_background<'a>(
        &'a self,
        session: &Session,
        opts: &PromptOptions,
    ) -> Result<Option<ResumePermit<'a>>, RpcError> {
        self.check_finished(session)?;
        let retry = super::resume_admission::automatic(opts);
        let background =
            !super::resume_admission::person(opts.agent.as_deref(), opts.provenance.as_ref());
        if !retry && !background {
            return Ok(None);
        }
        self.check_background_session(session)?;
        if !retry
            && self.resume_admission.binding().is_none()
            && !self.resume_admission.recovering()
        {
            return Ok(None);
        }
        let permit = self.admit_resume(super::resume_admission::priority(opts, session)).await?;
        if let Err(error) = self.check_background_session(session) {
            permit.complete().await;
            return Err(error);
        }
        if retry {
            Ok(Some(permit))
        } else {
            // Messages can await reciprocal replies, so their grant staggers entry but
            // does not retain retry occupancy while they wait for another session.
            permit.complete().await;
            Ok(None)
        }
    }

    pub(super) async fn admit_resume<'a>(
        &'a self,
        priority: u8,
    ) -> Result<ResumePermit<'a>, RpcError> {
        if self.resume_admission.binding().is_none() {
            return Ok(ResumePermit::Local(self.resume_admission.enter(priority).await?));
        }
        let ticket = uuid::Uuid::now_v7().to_string();
        self.fleet_call("fleet_acquire", json!({"ticket": ticket, "priority": priority})).await?;
        Ok(ResumePermit::Shared { hub: self, ticket })
    }
}

pub(super) enum ResumePermit<'a> {
    Local(Permit<'a>),
    Shared { hub: &'a Hub, ticket: String },
}

impl ResumePermit<'_> {
    /// Explicit completion only: dropping a cancelled prompt must not free a remote slot
    /// while its hosted harness may still be running. An uncertain release retains occupancy.
    pub(super) async fn complete(self) {
        match self {
            Self::Local(permit) => drop(permit),
            Self::Shared { hub, ticket } => {
                if let Err(error) = hub.fleet_call("fleet_release", json!({"ticket": ticket})).await
                {
                    tracing::warn!(%ticket, %error, "fleet reservation retained after uncertain release");
                }
            }
        }
    }
}
