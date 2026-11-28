//! Public Server dispatch, with a credential host and authoritative owner.
use cmux_cloud::{
    ControlPlane, Origin, RelayError, Request, Server, SessionStatus, WireCall, WireError,
    WireReply, WireResult,
};
use serde_json::{Value, json};
use std::collections::HashMap;

struct Host {
    backend: String,
    team: String,
    status: String,
    revision: u64,
    calls: Vec<WireCall>,
    answers: HashMap<String, WireResult>,
    lose: bool,
    refuse: bool,
    local_refusal: Option<&'static str>,
    corrupt: Option<(&'static str, Value)>,
}

impl Default for Host {
    fn default() -> Self {
        Self {
            backend: "https://cloud-api.cmux.dev".into(),
            team: "team_a".into(),
            status: "running".into(),
            revision: 7,
            calls: vec![],
            answers: HashMap::new(),
            lose: false,
            refuse: false,
            local_refusal: None,
            corrupt: None,
        }
    }
}

impl Host {
    fn record(&self, id: &str) -> Value {
        json!({"id":id,"team":self.team,"creator":"user_a","name":null,
            "size":{"cpu":null,"memory_mb":null,"disk_mb":null},"status":self.status,
            "image":{"id":"img","daemon_version":null},"host":null,"classic":false,
            "created_at":0,"last_active_at":null,"idle_policy":{"idle_seconds":0},
            "error":null,"revision":self.revision.to_string()})
    }
}

impl ControlPlane for Host {
    fn session(&mut self) -> Result<SessionStatus, RelayError> {
        Ok(SessionStatus {
            signed_in: true,
            backend: Some(self.backend.clone()),
            team: Some(self.team.clone()),
        })
    }

    fn call(&mut self, call: &WireCall) -> Result<WireReply, RelayError> {
        self.calls.push(call.clone());
        assert_eq!(call.expected_backend.as_deref(), Some(self.backend.as_str()));
        assert_eq!(call.expected_team.as_deref(), Some(self.team.as_str()));
        let id = call.params["machine"].as_str().unwrap();
        if call.op == "cloud.machine.get" {
            assert!(call.idempotency_key.is_none());
            assert!(call.expected_revision.is_none());
            return Ok(WireReply::Result(WireResult {
                value: self.record(id),
                revision: Some(self.revision.to_string()),
                replayed: false,
            }));
        }
        let key = call.idempotency_key.as_ref().unwrap();
        if let Some(code) = self.local_refusal {
            return Ok(WireReply::Error(WireError {
                code: code.into(),
                message: "host refused before POST".into(),
                details: None,
                retryable: false,
            }));
        }
        if let Some(answer) = self.answers.get(key) {
            return Ok(WireReply::Result(WireResult { replayed: true, ..answer.clone() }));
        }
        assert_eq!(call.expected_revision.as_deref(), Some(self.revision.to_string().as_str()));
        assert_eq!(call.origin, Some("user"));
        if self.refuse {
            return Err(RelayError::Unavailable("unknown outcome".into()));
        }
        self.status = match call.op.as_str() {
            "cloud.machine.pause" => "pausing",
            "cloud.machine.start" => "starting",
            "cloud.machine.delete" => "deleting",
            _ => panic!("unexpected mutation"),
        }
        .into();
        self.revision += 1;
        let value = if call.op == "cloud.machine.delete" {
            json!({"deleted":true})
        } else {
            json!({"machine":self.record(id)})
        };
        let answer =
            WireResult { value, revision: Some(self.revision.to_string()), replayed: false };
        self.answers.insert(key.clone(), answer.clone());
        if std::mem::take(&mut self.lose) {
            return Err(RelayError::Unavailable("answer lost after commit".into()));
        }
        let mut answer = answer;
        if let Some((field, value)) = self.corrupt.take() {
            answer.value["machine"][field] = value;
        }
        Ok(WireReply::Result(answer))
    }
}

fn request(op: &str, key: &str) -> Request {
    Request::new(op, json!({"machine":"vm_test"})).key(key).origin(Origin::User)
}

#[test]
fn production_alias_consumes_running_and_replays_unknown_without_a_second_read() {
    let mut server = Server::new(Host { lose: true, ..Host::default() });
    let request = request("vm.pause", "pause-1");
    assert!(server.handle(&request).is_err());
    let result = server.handle(&request).unwrap();
    assert_eq!(result["machine"]["status"], "pausing", "accepted is not completed");
    let calls = &server.control_plane().calls;
    assert_eq!(calls.len(), 3, "one get plus the mutation and exact replay");
    assert_eq!(calls[1], calls[2]);
    assert_eq!(calls[2].expected_revision.as_deref(), Some("7"));
    assert_eq!(server.handle(&request).unwrap(), result);
    assert_eq!(server.control_plane().calls.len(), 3, "completed replay is local");
}

#[test]
fn all_three_production_mutation_sites_use_the_typed_path() {
    for (op, initial, accepted) in [
        ("cloud.machine.pause", "running", "pausing"),
        ("vm.resume", "paused", "starting"),
        ("vm.delete", "failed", ""),
    ] {
        let mut server = Server::new(Host { status: initial.into(), ..Host::default() });
        let result = server.handle(&request(op, "key")).unwrap();
        if accepted.is_empty() {
            assert_eq!(result, json!({"deleted":true}));
        } else {
            assert_eq!(result["machine"]["status"], accepted);
        }
        assert_eq!(server.control_plane().calls.len(), 2);
    }
}

#[test]
fn invalid_power_states_and_extra_cloud_statuses_never_dispatch_a_mutation() {
    for state in [
        "paused", "pausing", "starting", "deleting", "failed", "ready", "stopped", "deleted",
        "unknown",
    ] {
        let mut server = Server::new(Host { status: state.into(), ..Host::default() });
        assert!(server.handle(&request("vm.pause", "key")).is_err(), "{state}");
        assert_eq!(server.control_plane().calls.len(), 1);
    }
}

#[test]
fn wrong_response_subject_team_and_revision_preserve_the_original_intent() {
    for (field, value) in
        [("id", json!("vm_other")), ("team", json!("team_b")), ("revision", json!("6"))]
    {
        let mut server = Server::new(Host { corrupt: Some((field, value)), ..Host::default() });
        let request = request("cloud.machine.pause", "key");
        assert!(server.handle(&request).is_err());
        assert!(server.handle(&request).is_ok());
        let calls = &server.control_plane().calls;
        assert_eq!(calls.len(), 3);
        assert_eq!(calls[1], calls[2]);
    }
}

#[test]
fn a_pending_key_cannot_cross_backend_team_target_or_operation() {
    for field in ["backend", "team", "machine", "op"] {
        let mut server = Server::new(Host { lose: true, ..Host::default() });
        assert!(server.handle(&request("vm.pause", "key")).is_err());
        let mut retry = request("vm.pause", "key");
        match field {
            "backend" => server.control_plane_mut().backend = "https://other.example".into(),
            "team" => server.control_plane_mut().team = "team_b".into(),
            "machine" => {
                retry = Request::new("vm.pause", json!({"machine":"vm_other"}))
                    .key("key")
                    .origin(Origin::User)
            }
            "op" => retry = request("vm.delete", "key"),
            _ => unreachable!(),
        }
        assert!(server.handle(&retry).is_err());
        assert_eq!(server.control_plane().calls.len(), 2, "scope refusal is local");
    }
}

#[test]
fn unresolved_ledger_entries_are_never_evicted_to_admit_a_new_intent() {
    let mut server = Server::new(Host { refuse: true, ..Host::default() });
    for index in 0..512 {
        assert!(server.handle(&request("vm.pause", &format!("key-{index}"))).is_err());
    }
    let before = server.control_plane().calls.len();
    let error = server.handle(&request("vm.pause", "overflow")).unwrap_err();
    assert_eq!(error.code, "cmux.cloud.relay_busy");
    assert_eq!(server.control_plane().calls.len(), before, "backpressure before network I/O");
    assert!(server.handle(&request("vm.pause", "key-0")).is_err());
    assert_eq!(
        server.control_plane().calls.len(),
        before + 1,
        "oldest key still retries without reading"
    );
}

#[test]
fn completed_replay_survives_capacity_pressure_without_reobserving_or_rebinding() {
    for (op, initial) in [("vm.pause", "running"), ("vm.resume", "paused"), ("vm.delete", "failed")]
    {
        let mut server = Server::new(Host { status: initial.into(), ..Host::default() });
        let original = request(op, "key-0");
        let result = server.handle(&original).unwrap();
        for index in 1..512 {
            server.control_plane_mut().status = initial.into();
            server.handle(&request(op, &format!("key-{index}"))).unwrap();
        }
        // A new key must not discard a completed response and later reinterpret
        // that key against a different power state, revision or credential scope.
        server.control_plane_mut().status = initial.into();
        let before = server.control_plane().calls.len();
        let error = server.handle(&request(op, "overflow")).unwrap_err();
        assert_eq!(error.code, "cmux.cloud.relay_busy", "{op}");
        server.control_plane_mut().status = "deleting".into();
        assert_eq!(server.handle(&original).unwrap(), result, "{op}");
        assert_eq!(server.control_plane().calls.len(), before, "no fresh read or mutation");
        server.control_plane_mut().team = "team_b".into();
        let error = server.handle(&original).unwrap_err();
        assert_eq!(error.code, "cmux.cloud.idempotency_conflict", "{op}");
        assert_eq!(server.control_plane().calls.len(), before);
    }
}

#[test]
fn restart_with_an_inflight_provider_state_refuses_a_new_live_capability() {
    // After a restart the ephemeral intent is gone. Reconciliation is
    // required; Pausing cannot be rebound into a fresh Running capability.
    let mut server = Server::new(Host { status: "pausing".into(), revision: 8, ..Host::default() });
    let error = server.handle(&request("vm.pause", "original-key")).unwrap_err();
    assert_eq!(error.code, "cmux.cloud.not_running");
    assert_eq!(server.control_plane().calls.len(), 1);
}

#[test]
fn invalid_arguments_leave_the_callers_key_available_for_correction() {
    let mut server = Server::new(Host::default());
    let invalid = Request::new("vm.pause", json!({"machine":"vm_test", "surprise":true}))
        .key("key")
        .origin(Origin::User);
    assert!(server.handle(&invalid).is_err());
    assert!(server.control_plane().calls.is_empty());
    assert!(server.handle(&request("vm.pause", "key")).is_ok());
}

#[test]
fn first_attempt_host_refusals_do_not_exhaust_unresolved_capacity() {
    for code in ["credential.scope_refused", "credential.fence_invalid"] {
        let mut server = Server::new(Host { local_refusal: Some(code), ..Host::default() });
        for index in 0..513 {
            let error = server.handle(&request("vm.pause", &format!("key-{index}"))).unwrap_err();
            assert_ne!(error.code, "cmux.cloud.relay_busy", "{code} at {index}");
        }
        assert_eq!(server.control_plane().calls.len(), 1026);
        assert!(server.control_plane().answers.is_empty());
        server.control_plane_mut().local_refusal = None;
        assert!(server.handle(&request("vm.pause", "repaired")).is_ok());
    }
}

#[test]
fn local_refusal_after_an_uncertain_attempt_preserves_the_original_intent() {
    for code in ["credential.scope_refused", "credential.fence_invalid"] {
        let mut server = Server::new(Host { lose: true, ..Host::default() });
        let request = request("vm.pause", "key");
        assert!(server.handle(&request).is_err());
        server.control_plane_mut().local_refusal = Some(code);
        assert!(server.handle(&request).is_err());
        server.control_plane_mut().local_refusal = None;
        assert!(server.handle(&request).is_ok());
        let calls = &server.control_plane().calls;
        assert_eq!(calls.len(), 4, "one get and three identical mutation attempts");
        assert_eq!(calls[1], calls[2]);
        assert_eq!(calls[1], calls[3]);
    }
}
