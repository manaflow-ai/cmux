//! Origin page default deny (plans/cmux-next/request-origin.md, "Page
//! access"): a page may not call a terminal input, screen or history read,
//! attach/detach, renderer or file system operation. The allow list is
//! empty: no shipped cmux-next page needs one of them.

use serde_json::{Value, json};

use crate::request_origin::params_sha256;
use crate::server::origin_gate::{
    set_peer_key_for_test, set_role_for_test, set_verified_app_for_test,
};
use crate::server::*;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("page-access-{label}"), crate::SurfaceOptions::default())
}

fn connect(mux: &Arc<Mux>) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Conn { client, writer, outbound, scheduler }
}

fn relay(mux: &Arc<Mux>, peer: &str) -> Conn {
    let conn = connect(mux);
    set_role_for_test(mux, conn.client, "page_relay");
    set_peer_key_for_test(mux, conn.client, peer);
    conn
}

fn send(mux: &Arc<Mux>, conn: &Conn, request: &Value) -> Value {
    assert!(handle_connection_message(
        mux,
        conn.client,
        &request.to_string(),
        &conn.writer,
        &conn.scheduler
    ));
    let message = conn.outbound.try_pop().expect("a synchronous reply");
    serde_json::from_str(&message).unwrap()
}

fn v2(operation: &str, params: Value, origin: Option<Value>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "r1",
        "operation": operation,
        "params": params,
    });
    if let Some(origin) = origin {
        request["origin"] = origin;
    }
    request
}

/// The refusal of a page: the catalog's `OriginForbiddenDetails`.
fn assert_page_refused(reply: &Value, operation: &str) {
    assert_eq!(reply["ok"], false, "{operation}: {reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{operation}: {reply}");
    assert_eq!(
        reply["error"]["details"],
        json!({"required": "agent", "derived": "page"}),
        "{operation}: {reply}"
    );
}

fn assert_not_forbidden(reply: &Value, operation: &str) {
    assert_ne!(reply["error"]["code"], "origin.forbidden", "{operation}: {reply}");
}

const INPUT: &[&str] = &[
    "terminal.input.write",
    "terminal.input.keys",
    "terminal.input.mouse",
    "terminal.input.focus",
    "pane.run",
    "workspace.run",
    "sidebar_view.input",
    "browser.input.text",
    "browser.input.key",
    "browser.input.mouse",
    "browser.input.wheel",
];

const SCREEN_READ: &[&str] = &[
    "terminal.screen.read",
    "terminal.history.read",
    "terminal.history.clear",
    "terminal.output_read",
    "terminal.state.read",
    "terminal.copy",
    "terminal.wait",
    "terminal.wait_exit",
    "terminal.process.get",
];

const ATTACH: &[&str] = &[
    "terminal.attach",
    "terminal.viewer.resize",
    "terminal.viewer.release",
    "terminal.viewport.scroll",
    "browser.attach",
    "browser.viewer.resize",
    "browser.viewer.release",
    "sidebar_view.attach",
    "client.detach",
];

const RENDERER: &[&str] = &["terminal.renderer_grant.create"];

const FILE_SYSTEM: &[&str] = &[
    "git.status",
    "git.diff",
    "git.files.search",
    "git.checkpoint.create",
    "git.checkpoint.diff",
    "git.checkpoint.get",
    "git.checkpoint.list",
    "git.checkpoint.pin",
    "git.checkpoint.unpin",
    "session.journal.hook.put",
];

/// Operations that spawn a terminal and refuse a page only when it picks
/// the working directory (`cwd`), as R5 does on legacy `new-screen`.
const SPAWN_WITH_CWD: &[&str] = &["pane.create", "pane.split", "tab.create_terminal"];

fn params() -> Value {
    json!({"machine": "current", "session": "current", "terminal": "t_x", "cwd": "/tmp"})
}

/// Every operation of `class` is refused on a page relay (no claim and
/// claim page), and on a local connection that narrows itself to page;
/// a plain local connection is not refused by origin.
fn assert_class_denied_to_pages(label: &str, class: &[&str]) {
    let mux = mux(label);
    let relay = relay(&mux, "token:10.1");
    let narrowed = connect(&mux);
    let plain = connect(&mux);
    for operation in class {
        assert_page_refused(&send(&mux, &relay, &v2(operation, params(), None)), operation);
        let page = Some(json!({"claim": "page"}));
        assert_page_refused(&send(&mux, &relay, &v2(operation, params(), page.clone())), operation);
        assert_page_refused(&send(&mux, &narrowed, &v2(operation, params(), page)), operation);
        // Empty params: the operation fails its validation, never runs.
        assert_not_forbidden(&send(&mux, &plain, &v2(operation, json!({}), None)), operation);
    }
}

#[test]
fn a_page_cannot_send_terminal_input() {
    assert_class_denied_to_pages("input", INPUT);
}

#[test]
fn a_page_cannot_read_a_screen_or_its_history() {
    assert_class_denied_to_pages("screen", SCREEN_READ);
}

#[test]
fn a_page_cannot_attach_or_detach() {
    assert_class_denied_to_pages("attach", ATTACH);
}

#[test]
fn a_page_cannot_get_a_renderer() {
    assert_class_denied_to_pages("renderer", RENDERER);
}

#[test]
fn a_page_cannot_reach_the_file_system() {
    assert_class_denied_to_pages("fs", FILE_SYSTEM);
}

#[test]
fn a_page_cannot_pick_the_cwd_of_a_new_terminal() {
    let mux = mux("spawn-cwd");
    let relay = relay(&mux, "token:10.1");
    let plain = connect(&mux);
    for operation in SPAWN_WITH_CWD {
        let with_cwd = json!({"machine": "current", "session": "current", "cwd": "/etc"});
        assert_page_refused(&send(&mux, &relay, &v2(operation, with_cwd.clone(), None)), operation);
        assert_not_forbidden(&send(&mux, &plain, &v2(operation, with_cwd, None)), operation);
        // Without cwd the class rule does not apply (the op is outside it).
        let without = json!({"machine": "current", "session": "current"});
        assert_not_forbidden(&send(&mux, &relay, &v2(operation, without.clone(), None)), operation);
        let null_cwd = json!({"machine": "current", "session": "current", "cwd": null});
        assert_not_forbidden(&send(&mux, &relay, &v2(operation, null_cwd, None)), operation);
    }
}

/// The result of a denied operation would reach page JS, so a native
/// confirmation (a confirmed-user claim on the relay) does not open it.
#[test]
fn a_confirmed_user_claim_on_a_page_relay_is_still_refused() {
    let mux = mux("confirmed");
    let app = connect(&mux);
    set_role_for_test(&mux, app.client, "main");
    set_peer_key_for_test(&mux, app.client, "token:10.1");
    set_verified_app_for_test(&mux, app.client, true);
    let relay = relay(&mux, "token:10.1");
    for operation in ["terminal.input.write", "terminal.screen.read", "terminal.attach", "git.diff"]
    {
        let issue = v2(
            "origin.confirmation.issue",
            json!({
                "machine": "current",
                "session": "current",
                "operation": operation,
                "params_sha256": params_sha256(&params()),
                "relay_connection_id": relay.client.to_string(),
            }),
            None,
        );
        let issued = send(&mux, &app, &issue);
        let token = issued["result"]["token"].as_str().expect("token").to_string();
        let claim = json!({"claim": "user", "confirmation": token});
        assert_page_refused(&send(&mux, &relay, &v2(operation, params(), Some(claim))), operation);
    }
}
