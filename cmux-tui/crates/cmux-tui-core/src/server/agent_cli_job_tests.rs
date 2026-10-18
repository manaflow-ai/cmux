//! Native admission and durable creation receipts. These use the core's
//! test surface runtime; actual updater execution/exit needs a native journey.

use super::*;

const COMMAND: &str = "agent-cli-update-job";

struct Caller {
    id: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Caller {
    fn new(mux: &Arc<Mux>, verified: bool) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let id = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        super::super::origin_gate::set_role_for_test(mux, id, "main");
        super::super::origin_gate::set_verified_app_for_test(mux, id, verified);
        Self {
            id,
            writer,
            outbound,
            scheduler: Arc::new(ConnectionSurfaceScheduler::new(
                mux.surface_operation_admission.clone(),
            )),
        }
    }

    fn call(&self, mux: &Arc<Mux>, request: Value) -> Value {
        assert!(handle_connection_message(
            mux,
            self.id,
            &request.to_string(),
            &self.writer,
            &self.scheduler,
        ));
        let until = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(line) = self.outbound.try_pop() {
                let value: Value = serde_json::from_str(&line).unwrap();
                if value.get("event").is_none() {
                    return value;
                }
            }
            assert!(std::time::Instant::now() < until, "job did not answer");
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

fn prepared() -> Value {
    // The test surface runtime records the launch, without executing this.
    json!({"cli":"claude","argv":["/private/owner/claude","update"]})
}

fn request(mux: &Mux, cli: &str, key: &str) -> Value {
    json!({"id":1,"cmd":COMMAND,"expected_machine_id":mux.machine_public_id,
        "cli":cli,"idempotency_key":key})
}

#[test]
fn cmux_next_agent_cli_job_requires_a_verified_user_connection_before_params() {
    let owner = Owner::new(json!(["harnessUpdatePrepare"]), prepared());
    let mux = owner.mux("job-unverified");
    let caller = Caller::new(&mux, false);
    assert_code(&caller.call(&mux, json!({"id":1,"cmd":COMMAND})), "agent_cli_job.not_trusted");
    assert!(owner.connections.recv_timeout(Duration::from_millis(100)).is_err());
}

#[test]
fn cmux_next_agent_cli_job_rejects_owner_selectors_commands_and_actor_claims() {
    let owner = Owner::new(json!(["harnessUpdatePrepare"]), prepared());
    let mux = owner.mux("job-controls");
    let caller = Caller::new(&mux, true);
    for field in ["argv", "shell", "socket", "session", "actor"] {
        let mut value = request(&mux, "claude", "bad-controls");
        value[field] = json!("private");
        assert_code(&caller.call(&mux, value), "agent_cli_job.bad_request");
    }
    let mut foreign = request(&mux, "claude", "foreign");
    foreign["expected_machine_id"] = json!("machine_11111111111111111111111111111111");
    assert_code(&caller.call(&mux, foreign), "agent_cli_job.owner_mismatch");
    assert!(owner.connections.recv_timeout(Duration::from_millis(100)).is_err());
}

#[test]
fn cmux_next_agent_cli_job_creates_one_visible_terminal_and_replays_without_an_owner() {
    let owner = Owner::new(json!(["harnessUpdatePrepare"]), prepared());
    let mux = owner.mux("job-replay");
    let caller = Caller::new(&mux, true);
    let before = mux.with_state(|state| state.workspaces.len());
    let intent = request(&mux, "claude", "original-intent");
    let first = caller.call(&mux, intent.clone());
    assert_eq!(first["ok"], true, "{first}");
    assert_eq!(first["data"]["machine"], json!(mux.machine_public_id));
    assert_eq!(first["data"]["cli"], "claude");
    assert_eq!(first["data"]["replayed"], false);
    assert!(first["data"]["path"]["terminal_id"].as_str().is_some());
    assert_eq!(mux.with_state(|state| state.workspaces.len()), before + 1);
    mux.set_acpmux_socket(None);
    let again = caller.call(&mux, intent);
    assert_eq!(again["ok"], true, "{again}");
    assert_eq!(again["data"]["path"], first["data"]["path"]);
    assert_eq!(again["data"]["replayed"], true);
    assert_eq!(mux.with_state(|state| state.workspaces.len()), before + 1);
    assert_eq!(owner.methods(), ["initialize", "_acpmux/harness/update/prepare"]);
}

#[test]
fn cmux_next_agent_cli_job_changed_intent_conflicts_before_requiring_a_plan() {
    let owner = Owner::new(json!(["harnessUpdatePrepare"]), prepared());
    let mux = owner.mux("job-conflict");
    let caller = Caller::new(&mux, true);
    assert_eq!(caller.call(&mux, request(&mux, "claude", "shared-key"))["ok"], true);
    mux.set_acpmux_socket(None);
    assert_code(&caller.call(&mux, request(&mux, "codex", "shared-key")), "idempotency.conflict");
    assert_eq!(owner.methods(), ["initialize", "_acpmux/harness/update/prepare"]);
}

#[test]
fn cmux_next_agent_cli_job_old_owners_are_not_given_a_legacy_fallback() {
    let owner = Owner::new(json!(["harnessUpdatePlan"]), prepared());
    let mux = owner.mux("job-old-owner");
    let caller = Caller::new(&mux, true);
    assert_code(&caller.call(&mux, request(&mux, "claude", "legacy")), "agent_cli_job.unsupported");
    assert_eq!(owner.methods(), ["initialize"]);
}

#[test]
fn cmux_next_agent_cli_job_requires_the_selected_session_before_preparing() {
    let owner = Owner::new(json!(["harnessUpdatePrepare"]), prepared());
    let mux = owner.mux("job-session");
    let caller = Caller::new(&mux, true);
    let mut missing = request(&mux, "claude", "missing-session");
    missing.as_object_mut().unwrap().remove("expected_session_id");
    assert_code(&caller.call(&mux, missing), "agent_cli_job.bad_request");
    let mut bound = request(&mux, "claude", "bound-session");
    bound["expected_session_id"] = json!(mux.session_public_id);
    let mut foreign = bound.clone();
    foreign["expected_session_id"] = json!("session_11111111111111111111111111111111");
    assert_code(&caller.call(&mux, foreign), "agent_cli_job.session_mismatch");
    assert!(owner.connections.recv_timeout(Duration::from_millis(100)).is_err());
    let reply = caller.call(&mux, bound);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["session"], json!(mux.session_public_id));
}
