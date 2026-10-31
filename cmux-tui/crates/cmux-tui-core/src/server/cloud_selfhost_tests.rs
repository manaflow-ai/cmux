//! Wire tests for a self-hosted chat server over Tailscale
//! (plans/cmux-next/dm-group-chat-DESIGN.md sections 4.3 and 4.5): a lease
//! with `auth: "tailscale"` names a tailnet origin, holds no token, sends no
//! Authorization header, never asks for a Stack lease, and learns the
//! person's user id from `GET /v1/selfhost/info` (`cloud-selfhost-info`).

use std::time::{Duration, Instant};

use base64::Engine;

use super::super::origin_gate::{set_role_for_test, set_verified_app_for_test};
use super::super::tests::captured_writer;
use super::super::*;
use crate::cloud_conversations::testing::{FakeBackend, wait_until};
use crate::cloud_conversations::{CloudConversations, ServiceOptions};

const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";
const ORIGIN: &str = "http://mini.tail1234.ts.net:7320";
const USER: &str = "user_ts_abcdefghijklmnopqrst";

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn cloud_mux() -> (Arc<Mux>, u64, Arc<FakeBackend>) {
    let mux = Mux::new_for_test("cloud-selfhost", crate::SurfaceOptions::default());
    let backend = Arc::new(FakeBackend::default());
    let options = ServiceOptions {
        linger: Duration::ZERO,
        backoff_min: Duration::from_millis(5),
        backoff_max: Duration::from_millis(20),
        poll: Duration::from_millis(5),
        api_origins: vec![],
        ..ServiceOptions::default()
    };
    assert!(
        mux.install_cloud_conversations(CloudConversations::with_options(backend.clone(), options))
    );
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, client, backend)
}

/// The verified cmux app connection (`origin: "user"`, the person's lease).
fn app(mux: &Arc<Mux>, client: u64) {
    set_role_for_test(mux, client, "main");
    set_verified_app_for_test(mux, client, true);
}

/// Runs `request` through the full request path and returns the reply line,
/// which may arrive from another thread.
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

fn tailscale_lease(origin: &str) -> Value {
    json!({"id":1,"cmd":"cloud-session-set","api_base_url":origin,"auth":"tailscale"})
}

fn cloud_events(events: &crate::MuxEventReceiver) -> Vec<Value> {
    events
        .try_iter()
        .filter(|event| matches!(event, MuxEvent::CloudConversation(_)))
        .map(|event| subscribed_event_json(&event))
        .collect()
}

fn info_reply(backend: &FakeBackend) {
    backend.reply(
        "/v1/selfhost/info",
        200,
        json!({"kind":"selfhost","user_id":USER,"login":"ada@example.com",
               "display_name":"Ada","server_name":"mini"}),
    );
}

/// The app leases the self-hosted server and learns its user id.
fn selfhost_sign_in(mux: &Arc<Mux>, client: u64, backend: &FakeBackend) {
    app(mux, client);
    let set = reply(mux, client, tailscale_lease(ORIGIN));
    assert_eq!(set["ok"], true, "{set}");
    info_reply(backend);
    let info = reply(mux, client, json!({"id":2,"cmd":"cloud-selfhost-info"}));
    assert_eq!(info["ok"], true, "{info}");
}

#[test]
fn a_tailscale_lease_names_only_tailnet_origins() {
    for as_app in [false, true] {
        let (mux, client, _) = cloud_mux();
        if as_app {
            app(&mux, client);
        }
        for (origin, normalized) in [
            ("http://mini.tail1234.ts.net:7320", "http://mini.tail1234.ts.net:7320"),
            ("https://MINI.Tail1234.TS.NET", "https://mini.tail1234.ts.net"),
            ("http://100.101.102.103:7320", "http://100.101.102.103:7320"),
            ("http://100.64.0.1", "http://100.64.0.1"),
            ("http://100.127.255.254:7320", "http://100.127.255.254:7320"),
            ("http://[fd7a:115c:a1e0::1]:7320", "http://[fd7a:115c:a1e0::1]:7320"),
        ] {
            let set = reply(&mux, client, tailscale_lease(origin));
            assert_eq!(set["ok"], true, "{origin} (app {as_app}): {set}");
            assert_eq!(
                set["data"],
                json!({"state":"active","api_base_url":normalized,"auth":"tailscale"}),
                "{origin}"
            );
        }
        for origin in [
            "http://100.63.255.255:7320",
            "http://100.128.0.1:7320",
            "http://[fd7a:115c:a1e1::1]:7320",
            "http://example.com",
            "https://example.com",
            "http://evil.ts.net.example.com",
            "http://ts.net",
            "http://localhost:7320",
            "http://127.0.0.1:7320",
            "https://cloud-api.cmux.dev",
        ] {
            let set = reply(&mux, client, tailscale_lease(origin));
            assert_eq!(set["ok"], false, "{origin} (app {as_app}) must be refused: {set}");
            assert_eq!(set["reason"], "unknown_api_origin", "{origin}: {set}");
        }
        for bad in [
            json!({"id":1,"cmd":"cloud-session-set","api_base_url":"ftp://mini.tail1234.ts.net","auth":"tailscale"}),
            json!({"id":1,"cmd":"cloud-session-set","api_base_url":"http://mini.tail1234.ts.net/v1","auth":"tailscale"}),
            json!({"id":1,"cmd":"cloud-session-set","api_base_url":ORIGIN,"auth":"tailscale","access_token":"t"}),
            json!({"id":1,"cmd":"cloud-session-set","api_base_url":ORIGIN,"auth":"magic"}),
        ] {
            let set = reply(&mux, client, bad.clone());
            assert_eq!(set["ok"], false, "{bad} must be refused: {set}");
        }
    }
}

#[test]
fn a_bearer_lease_keeps_the_hosted_origin_rules() {
    let (mux, client, _) = cloud_mux();
    // Not the app: a tailnet origin is not a known cmux Cloud origin for a bearer.
    let set = reply(
        &mux,
        client,
        json!({"id":1,"cmd":"cloud-session-set","api_base_url":"https://mini.tail1234.ts.net",
               "access_token":"stack.jwt.token","expires_at":4_102_444_800_000_u64}),
    );
    assert_eq!(set["reason"], "unknown_api_origin", "{set}");
    // http to a non-loopback host stays refused for a bearer, even for the app.
    app(&mux, client);
    let set = reply(
        &mux,
        client,
        json!({"id":1,"cmd":"cloud-session-set","api_base_url":ORIGIN,
               "access_token":"stack.jwt.token","expires_at":4_102_444_800_000_u64}),
    );
    assert_eq!(set["ok"], false, "{set}");
    let set = reply(
        &mux,
        client,
        json!({"id":1,"cmd":"cloud-session-set","api_base_url":"https://cloud-api.cmux.dev",
               "access_token":"stack.jwt.token","expires_at":4_102_444_800_000_u64}),
    );
    assert_eq!(
        set["data"],
        json!({"state":"active","api_base_url":"https://cloud-api.cmux.dev","expires_at":4_102_444_800_000_u64}),
        "{set}"
    );
}

#[test]
fn a_tailscale_lease_sends_no_authorization_and_never_asks_for_a_lease() {
    let (mux, client, backend) = cloud_mux();
    let events = mux.subscribe();
    app(&mux, client);
    assert_eq!(reply(&mux, client, tailscale_lease(ORIGIN))["ok"], true);
    backend.reply(
        "/v1/read",
        200,
        json!({"ok":true,"op":"inbox.list","value":{"entries":[],"seq":0},"revision":"1"}),
    );
    let listed = reply(&mux, client, json!({"id":3,"cmd":"cloud-inbox-list"}));
    assert_eq!(listed["ok"], true, "{listed}");
    // A 401 (a login the server does not admit) is refused, and asks for nothing.
    backend.reply("/v1/read", 401, json!({"error":{"code":"unauthenticated","message":"no"}}));
    let refused = reply(&mux, client, json!({"id":4,"cmd":"cloud-inbox-list"}));
    assert_eq!(refused["ok"], false, "{refused}");
    let posted = backend.posted();
    assert_eq!(posted.len(), 2);
    assert!(posted.iter().all(|post| post.url == format!("{ORIGIN}/v1/read")), "{posted:?}");
    assert!(posted.iter().all(|post| post.bearer.is_empty()), "no bearer: {posted:?}");

    // The inbox socket: no bearer, and a 401 on it retries without a lease request.
    backend.refuse(crate::cloud_conversations::ConnectError::Unauthenticated);
    let wire = backend.wire();
    wire.push_text(
        json!({"t":"welcome","principal":{"user":USER},"streams":["inbox"]}).to_string(),
    );
    assert_eq!(reply(&mux, client, json!({"id":5,"cmd":"cloud-inbox-subscribe"}))["ok"], true);
    wait_until("a second connect after the 401", || backend.connected().len() >= 2);
    let connected = backend.connected();
    assert_eq!(connected[0].url, "ws://mini.tail1234.ts.net:7320/v1/wire/user");
    assert!(connected.iter().all(|connect| connect.bearer.is_empty()), "{connected:?}");
    let status = reply(&mux, client, json!({"id":6,"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "active", "{status}");
    assert_eq!(status["data"]["auth"], "tailscale", "{status}");
    assert!(status["data"].get("expires_at").is_none(), "{status}");
    let seen = cloud_events(&events);
    assert!(
        !seen.iter().any(|event| event["event"] == "cloud-session-needed"),
        "a tailscale lease never asks for a Stack lease: {seen:#?}"
    );
}

#[test]
fn selfhost_info_names_the_person_and_tags_events_with_them() {
    let (mux, client, backend) = cloud_mux();
    app(&mux, client);
    assert_eq!(reply(&mux, client, tailscale_lease(ORIGIN))["ok"], true);
    info_reply(&backend);
    let info = reply(&mux, client, json!({"id":2,"cmd":"cloud-selfhost-info"}));
    assert_eq!(info["ok"], true, "{info}");
    assert_eq!(
        info["data"],
        json!({"kind":"selfhost","user_id":USER,"login":"ada@example.com",
               "display_name":"Ada","server_name":"mini"})
    );
    let got = backend.got();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].url, format!("{ORIGIN}/v1/selfhost/info"));
    assert!(got[0].bearer.is_empty());
    let status = reply(&mux, client, json!({"id":3,"cmd":"cloud-session-status"}));
    assert_eq!(
        status["data"],
        json!({"state":"active","api_base_url":ORIGIN,"auth":"tailscale","participant":USER}),
        "{status}"
    );

    // Owner events on the conversation socket carry the person's user id.
    let events = mux.subscribe();
    let wire = backend.wire();
    wire.push_text(
        json!({"t":"welcome","principal":{"user":USER},"streams":[format!("conv:{CONV}")]})
            .to_string(),
    );
    wire.push_text(
        json!({"t":"snapshot","stream":format!("conv:{CONV}"),"seq":2,"decided":[],
               "state":{"id":CONV,"title":"Launch","kind":"group","participants":[],"last_seq":0,"rev":2,
                        "created_at":"2026-10-03T00:00:00.000Z","updated_at":"2026-10-03T00:00:00.000Z",
                        "read_cursors":{}},
               "rows":{"table":"msg","rows":[]}})
        .to_string(),
    );
    let subscribed = reply(
        &mux,
        client,
        json!({"id":4,"cmd":"cloud-conversation-subscribe","conversation":CONV}),
    );
    assert_eq!(subscribed["ok"], true, "{subscribed}");
    let mut seen = Vec::new();
    wait_until("the resync event", || {
        seen.extend(cloud_events(&events));
        seen.iter().any(|event| event["event"] == "cloud-conversation-resynced")
    });
    let resynced =
        seen.iter().find(|event| event["event"] == "cloud-conversation-resynced").unwrap();
    assert_eq!(resynced["account"], USER, "{resynced}");
}

#[test]
fn selfhost_info_refuses_a_bearer_lease_and_a_server_that_is_not_one() {
    let (mux, client, backend) = cloud_mux();
    app(&mux, client);
    let set = reply(
        &mux,
        client,
        json!({"id":1,"cmd":"cloud-session-set","api_base_url":"https://cloud-api.cmux.dev",
               "access_token":"stack.jwt.token","expires_at":4_102_444_800_000_u64}),
    );
    assert_eq!(set["ok"], true, "{set}");
    let refused = reply(&mux, client, json!({"id":2,"cmd":"cloud-selfhost-info"}));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["reason"], "not_selfhost", "{refused}");
    assert!(backend.got().is_empty());

    assert_eq!(reply(&mux, client, tailscale_lease(ORIGIN))["ok"], true);
    backend.reply("/v1/selfhost/info", 200, json!({"kind":"hosted","user_id":USER}));
    let refused = reply(&mux, client, json!({"id":3,"cmd":"cloud-selfhost-info"}));
    assert_eq!(refused["ok"], false, "{refused}");
    backend.reply("/v1/selfhost/info", 200, json!({"kind":"selfhost","user_id":"admin"}));
    let refused = reply(&mux, client, json!({"id":4,"cmd":"cloud-selfhost-info"}));
    assert_eq!(refused["ok"], false, "{refused}");
    let status = reply(&mux, client, json!({"id":5,"cmd":"cloud-session-status"}));
    assert!(status["data"].get("participant").is_none(), "{status}");
}

#[test]
fn an_attachment_goes_up_and_comes_back_through_a_selfhosted_server() {
    let (mux, client, backend) = cloud_mux();
    selfhost_sign_in(&mux, client, &backend);
    let bytes: Vec<u8> = (0..5000u32).map(|n| (n % 251) as u8).collect();
    let hash = {
        use sha2::{Digest, Sha256};
        Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect::<String>()
    };
    let object = format!("/v1/home/attachments/{CONV}/{hash}");
    backend.reply(
        "/v1/home/attachments/intent",
        200,
        json!({"ok":true,"value":{"state":"upload","mode":"stream","method":"PUT","slot":"slot1",
               "upload_url":format!("{ORIGIN}/v1/home/attachments/upload/{CONV}/slot1.1.sig"),
               "headers":{"content-type":"application/octet-stream"}}}),
    );
    backend.reply(
        &format!("/v1/home/attachments/upload/{CONV}/slot1.1.sig"),
        200,
        json!({"ok":true,"value":{"state":"stored","attachment":{"hash":hash,
               "mime_type":"application/octet-stream","byte_count":bytes.len()}}}),
    );
    let begun = reply(
        &mux,
        client,
        json!({"id":10,"cmd":"cloud-attachment-upload","op":"begin","conversation":CONV,
               "sha256":hash,"byte_count":bytes.len(),"mime_type":"application/octet-stream",
               "name":"notes.bin"}),
    );
    assert_eq!(begun["ok"], true, "{begun}");
    let upload = begun["data"]["upload"].as_str().unwrap().to_owned();
    let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let chunk = reply(
        &mux,
        client,
        json!({"id":11,"cmd":"cloud-attachment-upload","op":"chunk","upload":upload,
               "piece":"original","offset":0,"data":data}),
    );
    assert_eq!(chunk["ok"], true, "{chunk}");
    let committed = reply(
        &mux,
        client,
        json!({"id":12,"cmd":"cloud-attachment-upload","op":"commit","upload":upload}),
    );
    assert_eq!(committed["ok"], true, "{committed}");
    assert_eq!(committed["data"]["stored"]["hash"], hash, "{committed}");
    let puts = backend.put_requests();
    assert_eq!(
        puts,
        vec![(format!("{ORIGIN}/v1/home/attachments/upload/{CONV}/slot1.1.sig"), 5000)]
    );

    backend.reply(
        "/v1/home/attachments/url",
        200,
        json!({"ok":true,"value":{"url":format!("{ORIGIN}{object}?s=sig"),"expires_at":4_102_444_800_000_u64}}),
    );
    backend.object(&object, "application/octet-stream", bytes.clone());
    let read = reply(
        &mux,
        client,
        json!({"id":13,"cmd":"cloud-attachment-read","conversation":CONV,"hash":hash,
               "offset":1000,"length":16}),
    );
    assert_eq!(read["ok"], true, "{read}");
    let got = base64::engine::general_purpose::STANDARD
        .decode(read["data"]["data"].as_str().unwrap())
        .unwrap();
    assert_eq!(got, bytes[1000..1016].to_vec());
    assert_eq!(read["data"]["byte_count"], 5000);
    assert!(backend.posted().iter().all(|post| post.bearer.is_empty()));
}
