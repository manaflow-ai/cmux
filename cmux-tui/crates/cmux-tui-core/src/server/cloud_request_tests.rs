//! Message requests through the daemon (plans/cmux-next/home-messaging-invites/DESIGN.md
//! 2.3): `cloud-requests-list` reads the person's requests, and `cloud-conversation-op`
//! forwards `invite.accept_verified` and `request.dismiss`.

use std::time::{Duration, Instant};

use super::super::tests::captured_writer;
use super::super::*;
use crate::cloud_conversations::testing::FakeBackend;
use crate::cloud_conversations::{CloudConversations, ServiceOptions};

const CONV: &str = "conv_dm_0123456789ABCDEFGHJKMNPQRS";

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn cloud_mux() -> (Arc<Mux>, u64, Arc<FakeBackend>) {
    let mux = Mux::new_for_test("cloud-requests", crate::SurfaceOptions::default());
    let backend = Arc::new(FakeBackend::default());
    let options = ServiceOptions {
        linger: Duration::ZERO,
        backoff_min: Duration::from_millis(5),
        backoff_max: Duration::from_millis(20),
        poll: Duration::from_millis(5),
        max_concurrent_requests: 1,
        api_origins: vec!["https://api.cmux.test".into()],
        ..ServiceOptions::default()
    };
    assert!(
        mux.install_cloud_conversations(CloudConversations::with_options(backend.clone(), options))
    );
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, client, backend)
}

fn run(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, client, command, &writer())
}

fn reply(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
    let (writer, outbound) = captured_writer();
    let request: Request = serde_json::from_value(request).unwrap();
    assert!(handle_request(mux, client, request, &writer));
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(line) = outbound.try_pop() {
            return serde_json::from_str(&line).unwrap();
        }
        assert!(Instant::now() < deadline, "no reply");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn sign_in(mux: &Arc<Mux>, client: u64) {
    let set = run(
        mux,
        client,
        json!({"cmd":"cloud-session-set","api_base_url":"https://api.cmux.test",
               "access_token":"stack.jwt.token","expires_at":4_102_444_800_000_u64,
               "client_version":"0.70.0"}),
    )
    .unwrap();
    assert_eq!(set["state"], "active");
}

#[test]
fn requests_list_reads_home_requests_and_drops_rows_without_a_conversation_id() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    let good = json!({"conversation":CONV,"inviter":"Carol Jones","kind":"dm",
        "preview":"hi Dave","created_at":"2026-10-19T00:00:00.000Z",
        "expires_at":"2026-11-02T00:00:00.000Z","trusted":false});
    let bad = json!({"conversation":"addr_ABREQ2MXXDJ3CH86MMYYKA0FPC","inviter":"X","kind":"dm",
        "preview":"","created_at":"2026-10-19T00:00:00.000Z",
        "expires_at":"2026-11-02T00:00:00.000Z","trusted":false});
    backend.reply(
        "/v1/read",
        200,
        json!({"ok":true,"op":"home.requests.list","value":{"requests":[good, bad]},"revision":"0"}),
    );
    let listed = reply(&mux, client, json!({"id":1,"cmd":"cloud-requests-list"}));
    assert_eq!(listed["ok"], true, "{listed}");
    assert_eq!(listed["data"], json!({"requests":[good]}), "{listed}");
    assert_eq!(backend.posted()[0].url, "https://api.cmux.test/v1/read");
    assert_eq!(backend.posted()[0].body, json!({"op":"home.requests.list","params":{}}));

    // It takes no fields.
    let extra = run(&mux, client, json!({"cmd":"cloud-requests-list","user":"user_x"}));
    assert!(extra.is_err(), "an unknown field is refused");
}

#[test]
fn requests_list_needs_the_lease_and_a_trusted_local_connection() {
    let (mux, client, backend) = cloud_mux();
    let signed_out = reply(&mux, client, json!({"id":1,"cmd":"cloud-requests-list"}));
    assert_eq!(signed_out["error_code"], "cloud_signed_out", "{signed_out}");
    let remote = mux.control_clients.register(ClientTransport::WebSocket, writer());
    let error = run(&mux, remote, json!({"cmd":"cloud-requests-list"})).unwrap_err();
    assert!(error.to_string().contains("trusted local connection"), "{error}");
    assert!(backend.posted().is_empty());
}

#[test]
fn accept_verified_and_dismiss_are_forwarded_and_other_kinds_still_refused() {
    let (mux, client, backend) = cloud_mux();
    sign_in(&mux, client);
    for (key, op) in [
        ("a1", json!({"kind":"invite.accept_verified"})),
        ("d1", json!({"kind":"request.dismiss","block":true})),
    ] {
        backend.reply(
            "/v1/ops",
            200,
            json!({"ok":true,"op":op["kind"],"value":{},"revision":"1","transaction":"tx",
                   "idempotency_key":key,"replayed":false,"stream":format!("conv:{CONV}"),"sequence":1}),
        );
        let done = reply(
            &mux,
            client,
            json!({"id":2,"cmd":"cloud-conversation-op","conversation":CONV,"idempotency_key":key,"op":op}),
        );
        assert_eq!(done["ok"], true, "{op}: {done}");
    }
    let posted = backend.posted();
    assert_eq!(
        posted[0].body,
        json!({"op":"invite.accept_verified","params":{"conversation":CONV},"idempotency_key":"a1","origin":"cli"})
    );
    assert_eq!(
        posted[1].body,
        json!({"op":"request.dismiss","params":{"block":true,"conversation":CONV},"idempotency_key":"d1","origin":"cli"})
    );
    let unlisted = reply(
        &mux,
        client,
        json!({"id":3,"cmd":"cloud-conversation-op","conversation":CONV,"idempotency_key":"x",
               "op":{"kind":"invite.accept"}}),
    );
    assert_eq!(unlisted["reason"], "unsupported_op", "{unlisted}");
    assert_eq!(backend.posted().len(), 2, "an unlisted kind never reaches the cloud");
}
