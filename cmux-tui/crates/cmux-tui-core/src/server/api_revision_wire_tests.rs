//! API revisions on the raw protocol: an older client is served in its own
//! revision both ways, a native or newer client is untouched, an unknown
//! old revision is refused, and `identify` advertises the range.

use cmux_api_compat::{Change, Compat, MessageChange, Schema};

use super::super::*;
use super::NegotiatedRevision;

fn writer_with_outbound() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    (writer, outbound)
}

/// Revision 13 renames a request member, a result member and an event member.
fn history() -> &'static Compat {
    let rename = |message: &str, path: &str, to: &str| MessageChange {
        message: message.into(),
        change: Change::Rename { path: path.into(), to: to.into() },
    };
    let mut schema = Schema::new("cmux-mux", 12);
    schema.push(
        "test renames",
        vec![
            rename("request:rename-tab", "/title", "name"),
            rename("response:rename-tab", "/data/title", "name"),
            rename("event:tab-renamed", "/surface", "tab"),
        ],
    );
    Box::leak(Box::new(Compat::new(schema).unwrap()))
}

fn translating_writer(client_revision: u32) -> (MessageWriter, Arc<BoundedOutbound>) {
    let (mut writer, outbound) = writer_with_outbound();
    let negotiated = NegotiatedRevision::with_compat(history());
    negotiated.declare(client_revision).unwrap();
    writer.api_revision = Arc::new(negotiated);
    (writer, outbound)
}

fn pop(outbound: &BoundedOutbound) -> Value {
    serde_json::from_str(&outbound.try_pop().unwrap()).unwrap()
}

#[test]
fn api_revision_old_client_is_served_in_its_revision() {
    let (writer, outbound) = translating_writer(12);
    let line = r#"{"id":"r1","cmd":"rename-tab","tab":4,"title":"logs"}"#;
    let upgraded: Value = serde_json::from_str(&writer.api_revision.upgrade_request(line)).unwrap();
    assert_eq!(upgraded, json!({"id":"r1","cmd":"rename-tab","tab":4,"name":"logs"}));

    writer.send_control(&json!({"id":"r1","ok":true,"data":{"name":"logs"}})).unwrap();
    assert_eq!(pop(&outbound), json!({"id":"r1","ok":true,"data":{"title":"logs"}}));

    writer.send_control(&json!({"event":"tab-renamed","tab":4})).unwrap();
    assert_eq!(pop(&outbound), json!({"event":"tab-renamed","surface":4}));

    // A reply whose request was never seen is left alone.
    writer.send_control(&json!({"id":"r9","ok":true,"data":{"name":"x"}})).unwrap();
    assert_eq!(pop(&outbound), json!({"id":"r9","ok":true,"data":{"name":"x"}}));
}

#[test]
fn api_revision_native_and_newer_clients_are_untouched() {
    for revision in [13, 14] {
        let (writer, outbound) = translating_writer(revision);
        let line = r#"{"id":"r1","cmd":"rename-tab","title":"logs"}"#;
        assert!(matches!(writer.api_revision.upgrade_request(line), std::borrow::Cow::Borrowed(_)));
        writer.send_control(&json!({"event":"tab-renamed","tab":4})).unwrap();
        assert_eq!(pop(&outbound), json!({"event":"tab-renamed","tab":4}));
    }
}

#[test]
fn api_revision_older_than_the_base_is_refused() {
    let negotiated = NegotiatedRevision::with_compat(history());
    assert!(negotiated.declare(11).is_err());
}

#[test]
fn api_revision_identify_and_set_client_info() {
    let mux = Mux::new_for_test("api-revision-identify", crate::SurfaceOptions::default());
    let (writer, _outbound) = writer_with_outbound();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let run = |request: Value| {
        let command: Command = serde_json::from_value(request).unwrap();
        handle_command(&mux, client, command, &writer)
    };
    // Strict old SDKs read the default reply: the revision fields are opt-in.
    let plain = run(json!({"cmd":"identify"})).unwrap();
    assert!(plain.get("api_revision").is_none() && plain.get("install").is_none(), "{plain}");
    let identity = run(json!({"cmd":"identify","revisions":true})).unwrap();
    let (current, base) = super::identify_fields();
    assert_eq!(identity["api_revision"], current);
    assert_eq!(identity["min_api_revision"], base);
    assert!(run(json!({"cmd":"set-client-info","api_revision": base - 1})).is_err());
    assert!(run(json!({"cmd":"set-client-info","api_revision": current})).is_ok());
    mux.shutdown();
}

#[test]
fn api_revision_too_old_refusal_names_the_clients_update_command() {
    let mux = Mux::new_for_test("api-revision-refusal", crate::SurfaceOptions::default());
    let (writer, _outbound) = writer_with_outbound();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let run = |request: Value| {
        let command: Command = serde_json::from_value(request).unwrap();
        handle_command(&mux, client, command, &writer)
    };
    let (_, base) = super::identify_fields();
    let refuse = |install: Option<&str>| {
        let mut request =
            json!({"cmd":"set-client-info","api_revision": base - 1,"version":"0.13.4"});
        if let Some(install) = install {
            request["install"] = json!(install);
        }
        run(request).unwrap_err().to_string()
    };
    let npm = refuse(Some("npm"));
    assert!(npm.starts_with("this client (cmux 0.13.4) is too old"), "{npm}");
    assert!(npm.ends_with("run `npm install --global cmux@latest`"), "{npm}");
    assert!(refuse(Some("pypi")).ends_with("run `uv tool upgrade cmux`"));
    assert!(refuse(Some("app")).contains("Check for Updates"));
    let unknown = refuse(None);
    assert!(
        unknown.contains("npm install --global cmux@latest")
            && unknown.contains("uv tool upgrade cmux")
    );

    let identity = run(json!({"cmd":"identify","revisions":true})).unwrap();
    assert_eq!(identity["version"], crate::release::distribution_version());
    assert!(identity["install"].is_string());
    mux.shutdown();
}
