//! The existing machine API projects only the verified local app's admitted
//! remote routes, and its publication expires with that exact connection.

use super::super::*;
use crate::{Actor, ResourceMachineRequest, ResourceSelectors};
use serde_json::{Value, json};

#[path = "machine_catalog_reader_tests.rs"]
mod reader_tests;

#[path = "machine_identity_reader_tests.rs"]
mod identity_reader_tests;

struct Publisher {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Publisher {
    fn new(mux: &Arc<Mux>, transport: ClientTransport, verified: bool) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(transport, writer.clone());
        origin_gate::set_role_for_test(mux, client, "main");
        origin_gate::set_peer_key_for_test(mux, client, "token:100.1");
        origin_gate::set_verified_app_for_test(mux, client, verified);
        Self {
            client,
            writer,
            outbound,
            scheduler: Arc::new(ConnectionSurfaceScheduler::new(
                mux.surface_operation_admission.clone(),
            )),
        }
    }

    fn send(&self, mux: &Arc<Mux>, sequence: u64, records: Value) -> Value {
        self.frame(
            mux,
            json!({"id":1,"cmd":"machine-catalog-publish",
            "expected_machine_id":mux.machine_public_id,"sequence":sequence,"machines":records}),
        )
    }

    fn frame(&self, mux: &Arc<Mux>, frame: Value) -> Value {
        self.line(mux, &frame.to_string())
    }

    fn line(&self, mux: &Arc<Mux>, line: &str) -> Value {
        assert!(handle_connection_message(mux, self.client, line, &self.writer, &self.scheduler));
        serde_json::from_str(&self.outbound.try_pop().expect("one synchronous publication reply"))
            .unwrap()
    }

    /// The reply to `line` and the JSON parses its way to the reply took.
    fn line_counted(&self, mux: &Arc<Mux>, line: &str) -> (Value, u64) {
        let stats = crate::diagnostics::IpcStats::default();
        let reply = {
            let _scope = crate::diagnostics::JsonParseScope::enter(
                &stats,
                crate::diagnostics::IpcTransport::Lines,
            );
            self.line(mux, line)
        };
        (reply, stats.snapshot().parses.lines.json_parses)
    }
}

fn mux() -> Arc<Mux> {
    Mux::new_for_test("catalog-owner", crate::SurfaceOptions::default())
}

fn remote() -> Value {
    let owner = Mux::new_for_test("remote-owner", crate::SurfaceOptions::default());
    json!({"id":owner.machine_public_id,"name":"build server","origin":"ssh","status":"running",
           "platform":{"os":"linux","arch":"aarch64"},"capabilities":["terminal","agent_session"]})
}

fn dispatch(
    mux: &Arc<Mux>,
    operation: ResourceOperation,
    machine: Option<&str>,
) -> Result<Value, ResourceError> {
    mux.resource_machine_service().dispatch(&ResourceMachineRequest {
        operation,
        selectors: ResourceSelectors { machine: machine.map(str::to_owned), ..Default::default() },
        fields: if matches!(
            operation,
            ResourceOperation::MachineList | ResourceOperation::MachineGet
        ) {
            serde_json::from_value(json!({"catalog":true})).unwrap()
        } else {
            Default::default()
        },
        idempotency_key: None,
        actor: Actor::local_user(),
    })
}

#[test]
fn cmux_next_machine_catalog_publishes_into_the_existing_machine_api() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    let remote = remote();
    let reply = publisher.send(&mux, 1, json!([remote]));
    assert_eq!(reply["ok"], true, "a verified publication must be admitted: {reply}");
    let listed = dispatch(&mux, ResourceOperation::MachineList, None).unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 2);
    assert_eq!(listed[0]["id"], json!(mux.machine_public_id));
    assert_eq!(listed[1]["id"], remote["id"]);
    assert_eq!(listed[1]["platform"], remote["platform"]);
    assert_eq!(listed[1]["capabilities"], remote["capabilities"]);
    assert_eq!(
        dispatch(&mux, ResourceOperation::MachineGet, remote["id"].as_str()).unwrap(),
        listed[1]
    );
    assert_eq!(dispatch(&mux, ResourceOperation::MachineGet, Some("current")).unwrap(), listed[0]);
}

/// The route finds `machine-catalog-publish` by the decoded `cmd`, never a
/// substring of the line: an escaped name publishes as its
/// plain spelling, and an accepted or a refused line takes two parses, the
/// head and the handler's one decode.
#[test]
fn cmux_next_machine_catalog_publish_is_routed_by_its_decoded_cmd_and_decoded_once() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    let publish = json!({"id":1,"cmd":"machine-catalog-publish",
        "expected_machine_id":mux.machine_public_id,"sequence":1,"machines":[remote()]})
    .to_string();
    let escaped = publish.replace("machine-catalog-publish", r"machine-catalog\u002dpublish");
    let (reply, parses) = publisher.line_counted(&mux, &escaped);
    assert_eq!(reply["ok"], true, "{escaped}: {reply}");
    assert_eq!(reply["id"], 1);
    assert_eq!(parses, 2, "the head and the route's decode");

    let stale = json!({"id":2,"cmd":"machine-catalog-publish",
        "expected_machine_id":mux.machine_public_id,"sequence":1,"machines":[]})
    .to_string();
    let (refused, parses) = publisher.line_counted(&mux, &stale);
    assert_eq!(refused["error_code"], "machine_catalog.stale", "{refused}");
    assert_eq!(refused["id"], 2, "a refusal takes its id from the same decode");
    assert_eq!(parses, 2);

    let anonymous = publisher.frame(
        &mux,
        json!({"cmd":"machine-catalog-publish","expected_machine_id":mux.machine_public_id,
            "sequence":2,"machines":[remote()]}),
    );
    assert_eq!(anonymous["ok"], true, "{anonymous}");
    assert!(anonymous.get("id").is_none(), "{anonymous}");
}

#[test]
fn cmux_next_machine_catalog_refuses_stale_replacements_and_local_impersonation() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    let record = remote();
    assert_eq!(publisher.send(&mux, 3, json!([record]))["ok"], true);
    let before = dispatch(&mux, ResourceOperation::MachineList, None).unwrap();
    assert_eq!(publisher.send(&mux, 2, json!([]))["error_code"], "machine_catalog.stale");
    assert_eq!(publisher.send(&mux, 3, json!([]))["error_code"], "machine_catalog.stale");
    assert_eq!(publisher.send(&mux, 3, json!([record]))["ok"], true, "exact replay is harmless");
    let mut impostor = record.clone();
    impostor["id"] = json!(mux.machine_public_id);
    assert_eq!(
        publisher.send(&mux, 4, json!([impostor]))["error_code"],
        "machine_catalog.bad_request"
    );
    assert_eq!(
        publisher.send(&mux, 4, json!([record, record]))["error_code"],
        "machine_catalog.bad_request"
    );
    assert_eq!(dispatch(&mux, ResourceOperation::MachineList, None).unwrap(), before);
    assert_eq!(publisher.send(&mux, 4, json!([]))["ok"], true);
    assert_eq!(
        dispatch(&mux, ResourceOperation::MachineList, None).unwrap().as_array().unwrap().len(),
        1
    );
}

/// The owner fence is typed like spec/sdk-schema.json says: a required
/// string. A missing, null or non-string owner is refused before the
/// publication is read, and nothing is published.
#[test]
fn cmux_next_machine_catalog_owner_fence_must_be_a_string() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    let before = dispatch(&mux, ResourceOperation::MachineList, None).unwrap();
    for owner in [None, Some(Value::Null), Some(json!(7)), Some(json!([mux.machine_public_id]))] {
        let mut frame =
            json!({"id":1,"cmd":"machine-catalog-publish","sequence":1,"machines":[remote()]});
        if let Some(owner) = owner {
            frame["expected_machine_id"] = owner;
        }
        assert_eq!(
            publisher.frame(&mux, frame.clone())["error_code"],
            "machine_catalog.bad_request",
            "{frame}"
        );
    }
    assert_eq!(dispatch(&mux, ResourceOperation::MachineList, None).unwrap(), before);
    assert_eq!(publisher.send(&mux, 1, json!([remote()]))["ok"], true);
}

#[test]
fn cmux_next_machine_catalog_is_exclusive_and_expires_on_disconnect() {
    let mux = mux();
    let first = Publisher::new(&mux, ClientTransport::Unix, true);
    let second = Publisher::new(&mux, ClientTransport::Unix, true);
    assert_eq!(first.send(&mux, 1, json!([remote()]))["ok"], true);
    assert_eq!(second.send(&mux, 1, json!([]))["error_code"], "machine_catalog.taken");
    assert!(mux.control_clients.remove(first.client).is_some());
    assert_eq!(
        dispatch(&mux, ResourceOperation::MachineList, None).unwrap().as_array().unwrap().len(),
        1
    );
    assert_eq!(second.send(&mux, 1, json!([remote()]))["ok"], true);
    // A removed client is classified as remote by the outer dispatcher;
    // its default-deny gate rejects before the publication handler.
    assert_eq!(first.send(&mux, 9, json!([remote()]))["error_code"], "remote_denied");
    assert_eq!(
        dispatch(&mux, ResourceOperation::MachineList, None).unwrap().as_array().unwrap().len(),
        2
    );
}

#[test]
fn cmux_next_machine_catalog_untrusted_and_nonlocal_carriers_cannot_publish() {
    let mux = mux();
    for (transport, verified) in [
        (ClientTransport::Unix, false),
        (ClientTransport::WebSocket, true),
        (ClientTransport::Remote, true),
    ] {
        let client = Publisher::new(&mux, transport, verified);
        assert_eq!(client.send(&mux, 1, json!([remote()]))["ok"], false);
    }
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    let response = publisher.frame(
        &mux,
        json!({"id":1,"cmd":"machine-catalog-publish",
        "expected_machine_id":remote()["id"],"sequence":1,"machines":[]}),
    );
    assert_eq!(response["error_code"], "machine_catalog.owner_mismatch");
    assert_eq!(
        dispatch(&mux, ResourceOperation::MachineList, None).unwrap().as_array().unwrap().len(),
        1
    );
}

#[test]
fn cmux_next_machine_catalog_rejects_sensitive_or_unbounded_metadata_atomically() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    let record = remote();
    assert_eq!(publisher.send(&mux, 1, json!([record]))["ok"], true);
    let before = dispatch(&mux, ResourceOperation::MachineList, None).unwrap();
    for (key, value) in [
        ("path", json!("/private/data")),
        ("command", json!("echo bad")),
        ("name", json!("line\nfeed")),
        ("capabilities", json!(["bad/name"])),
        ("id", json!("local")),
        ("platform", json!({"os":"../../bad"})),
    ] {
        let mut invalid = record.clone();
        invalid[key] = value;
        assert_eq!(
            publisher.send(&mux, 2, json!([invalid]))["error_code"],
            "machine_catalog.bad_request",
            "field {key}"
        );
        assert_eq!(dispatch(&mux, ResourceOperation::MachineList, None).unwrap(), before);
    }
    assert_eq!(
        publisher.send(&mux, 2, json!(vec![record; 257]))["error_code"],
        "machine_catalog.bad_request"
    );
}

#[test]
fn cmux_next_machine_catalog_default_owner_stays_local_without_a_publisher() {
    let mux = mux();
    let listed = dispatch(&mux, ResourceOperation::MachineList, None).unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["id"], json!(mux.machine_public_id));
    assert!(dispatch(&mux, ResourceOperation::MachineGet, remote()["id"].as_str()).is_err());
}

#[test]
fn cmux_next_machine_catalog_never_confers_session_or_agent_execution_authority() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    let record = remote();
    assert_eq!(publisher.send(&mux, 1, json!([record]))["ok"], true);
    assert!(dispatch(&mux, ResourceOperation::SessionList, record["id"].as_str()).is_err());
    assert_eq!(
        dispatch(&mux, ResourceOperation::SessionList, Some("current"))
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
    mux.bind_conversation_principal(publisher.client, "agent:catalog-test".to_owned()).unwrap();
    assert_eq!(publisher.send(&mux, 2, json!([]))["error_code"], "machine_catalog.not_trusted");
    assert_eq!(
        dispatch(&mux, ResourceOperation::MachineList, None).unwrap().as_array().unwrap().len(),
        1
    );
}

#[test]
fn cmux_next_machine_catalog_owner_metadata_withdraws_with_verified_app_authority() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    assert_eq!(publisher.send(&mux, 1, json!([remote()]))["ok"], true);
    origin_gate::set_verified_app_for_test(&mux, publisher.client, false);
    assert_eq!(
        dispatch(&mux, ResourceOperation::MachineList, None).unwrap().as_array().unwrap().len(),
        1
    );
    assert_eq!(publisher.send(&mux, 2, json!([]))["error_code"], "machine_catalog.not_trusted");
}
