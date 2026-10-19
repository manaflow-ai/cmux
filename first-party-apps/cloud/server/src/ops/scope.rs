//! One parent scope owns every cached result, carrier and transfer of this server.
use super::Server;
use crate::api::{CloudError, ControlPlane, Ctx, Request};

pub(super) fn changed() -> CloudError {
    CloudError {
        retryable: true,
        ..CloudError::new("credential.session_changed", "the Cloud session changed")
    }
}

impl<C: ControlPlane> Server<C> {
    /// The host owns this channel. A notice only removes authority; the next op still asks its owner.
    pub(crate) fn parent_scope_changed(&mut self) {
        self.forget_scope();
    }
    pub(super) fn check_scope(&mut self, request: &Request) -> Result<(), CloudError> {
        let current = match self.control_plane.request_scope(request.expected_scope.is_some()) {
            Ok(scope) => scope,
            Err(error) => {
                self.forget_scope();
                return Err(Ctx::new(&mut self.control_plane, &mut self.projection, None)
                    .relay_error(error));
            }
        };
        if current != self.session_scope {
            self.forget_scope();
            self.session_scope = current.clone();
        }
        if request.expected_scope.as_ref().is_some_and(|s| Some(s) != current.as_ref()) {
            return Err(changed());
        }
        Ok(())
    }

    pub(crate) fn remember_pending_scope(&mut self, id: &serde_json::Value) {
        if let Some(scope) = &self.session_scope {
            self.pending_scopes.insert(id.to_string(), scope.clone());
        }
    }

    pub(crate) fn finish_pending_scope(
        &mut self,
        id: &serde_json::Value,
        outcome: Result<serde_json::Value, CloudError>,
    ) -> (Option<String>, Result<serde_json::Value, CloudError>) {
        let scope = self.pending_scopes.remove(&id.to_string());
        if outcome.is_ok() && scope.is_some() {
            let mut request = Request::new("", serde_json::Value::Null);
            request.expected_scope = scope.clone();
            if let Err(error) = self.check_scope(&request) {
                return (scope, Err(error));
            }
        }
        (scope, outcome)
    }

    pub(crate) fn take_scope_answers(
        &mut self,
    ) -> Vec<(serde_json::Value, Result<serde_json::Value, CloudError>)> {
        std::mem::take(&mut self.scope_answers)
    }

    pub(super) fn forget_scope(&mut self) {
        self.session_scope = None;
        self.ledger.clear();
        self.projection.clear();
        self.attach.infos.clear();
        self.attach.hosts.clear();
        self.attach.paused_restarts.clear();
        let parked = self.take_scope_waiters();
        let files = self.edge.file_jobs.forget_scope();
        self.scope_answers.extend(parked.into_iter().chain(files).map(|id| (id, Err(changed()))));
        self.attach.supervisor.forget_scope("the Cloud session changed");
        self.attach.drain_link_events();
        self.attach
            .frames
            .close_all(&cmux_terminal_iface::Lost::new("the Cloud session changed", false));
        for terminal in self.attach.rescue_terminals.values_mut() {
            let _ = terminal.close(cmux_terminal_iface::Close::Now);
        }
        self.attach.rescue_terminals.clear();
        self.edge.forget_scope();
    }
}
