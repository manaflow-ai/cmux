//! Wire tests for `pane-browser-kind-v1`: raw `split` and `new-pane-right`
//! create a browser pane when the caller asks for
//! `kind: "browser"` with a `url`. Before this capability the daemon dropped
//! both fields and spawned a terminal, so a frontend's web split became a
//! terminal pane.

use super::*;

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    /// One workspace with one terminal pane; returns that pane.
    fn lone() -> (Self, PaneId) {
        let mux = Mux::new_for_test("split-kind", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        (Self { mux, outbound, writer, next_id: 1 }, pane)
    }

    fn send(&mut self, mut request: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        handle_message(&self.mux, 7, &request.to_string(), &self.writer);
        let response: Value = serde_json::from_str(&self.outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], id, "response must answer the request: {response}");
        response
    }

    fn ok(&mut self, request: Value) -> Value {
        let response = self.send(request.clone());
        assert_eq!(response["ok"], true, "{request} failed: {response}");
        response["data"].clone()
    }

    fn pane_count(&self) -> usize {
        self.mux.with_state(|state| state.panes.len())
    }

    /// The created surface must be a browser showing `url`, alone in a new
    /// pane that is not `old_pane`.
    fn assert_browser_pane(&self, created: &Value, old_pane: PaneId, url: &str) {
        let surface: SurfaceId = serde_json::from_value(created["surface"].clone()).unwrap();
        let (kind, shown, pane, tabs) = self.mux.with_state(|state| {
            let surface = state.surfaces[&surface].clone();
            let pane = state.pane_of(surface.id).unwrap();
            (surface.kind(), surface.browser_url(), pane, state.panes[&pane].tabs.clone())
        });
        assert_eq!(kind, crate::surface::SurfaceKind::Browser, "{created}");
        assert_eq!(shown.as_deref(), Some(url));
        assert_ne!(pane, old_pane, "the browser must be in a new pane");
        assert_eq!(tabs, vec![surface], "the new pane holds only the browser");
    }
}

#[test]
fn pane_browser_kind_capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&"pane-browser-kind-v1"));
}

#[test]
fn split_with_browser_kind_creates_a_browser_pane_with_the_url() {
    for dir in ["right", "down"] {
        let (mut wire, pane) = Wire::lone();
        let url = format!("https://example.com/{dir}");
        let created = wire.ok(json!({
            "cmd": "split", "pane": pane, "dir": dir, "kind": "browser", "url": url,
        }));
        wire.assert_browser_pane(&created, pane, &url);
        assert_eq!(wire.pane_count(), 2);
    }
}

#[test]
fn new_pane_right_with_browser_kind_creates_a_browser_column() {
    let (mut wire, pane) = Wire::lone();
    let created = wire.ok(json!({
        "cmd": "new-pane-right", "pane": pane, "width": 0.5,
        "kind": "browser", "url": "https://example.com/column",
    }));
    wire.assert_browser_pane(&created, pane, "https://example.com/column");
    let columns =
        handle_command(&wire.mux, 0, Command::ListWorkspaces, &wire.writer).unwrap()["workspaces"]
            [0]["screens"][0]["columns"]
            .as_array()
            .map_or(0, Vec::len);
    assert_eq!(columns, 2, "new-pane-right still makes a viewport column");
}

#[test]
fn pty_kind_and_no_kind_still_create_a_terminal() {
    for kind in [Some("pty"), None] {
        let (mut wire, pane) = Wire::lone();
        let mut request = json!({"cmd": "split", "pane": pane, "dir": "right"});
        if let Some(kind) = kind {
            request["kind"] = json!(kind);
        }
        let created = wire.ok(request);
        let surface: SurfaceId = serde_json::from_value(created["surface"].clone()).unwrap();
        let kind = wire.mux.with_state(|state| state.surfaces[&surface].kind());
        assert_eq!(kind, crate::surface::SurfaceKind::Pty);
    }
}

/// A kind the daemon does not know, a browser without a URL, a URL on a
/// terminal, and terminal-only fields on a browser are refused, and nothing
/// is created. Before `pane-browser-kind-v1` each of these made a terminal.
#[test]
fn malformed_kind_requests_are_refused_and_create_nothing() {
    let refused = [
        json!({"cmd": "split", "dir": "right", "kind": "spreadsheet", "url": "https://a.test"}),
        json!({"cmd": "split", "dir": "right", "kind": "browser"}),
        json!({"cmd": "split", "dir": "right", "kind": "browser", "url": ""}),
        json!({"cmd": "split", "dir": "right", "url": "https://a.test"}),
        json!({"cmd": "split", "dir": "right", "kind": "pty", "url": "https://a.test"}),
        json!({"cmd": "split", "dir": "right", "kind": "browser", "url": "https://a.test",
               "cwd": "/tmp"}),
        json!({"cmd": "split", "dir": "right", "kind": "browser", "url": "https://a.test",
               "keep": true}),
        json!({"cmd": "new-pane-right", "kind": "browser"}),
        json!({"cmd": "new-pane-right", "kind": "browser", "url": "https://a.test",
               "shell_args": ["-l"]}),
    ];
    for mut request in refused {
        let (mut wire, pane) = Wire::lone();
        request["pane"] = json!(pane);
        let response = wire.send(request.clone());
        assert_eq!(response["ok"], false, "{request} must be refused: {response}");
        assert_eq!(wire.pane_count(), 1, "{request} must create nothing");
    }
}

/// The browser kind is a raw-protocol field. Public v2 `pane.split` keeps
/// its terminal-only contract (its result type is `CreatedTerminalPath`), so
/// `kind` and `url` there, and the daemon-internal browser field, are refused
/// and create nothing.
#[test]
fn public_pane_split_refuses_browser_fields() {
    for (index, extra) in [
        json!({"kind": "browser", "url": "https://a.test"}),
        json!({"url": "https://a.test"}),
        json!({"pane_browser_url": "https://a.test"}),
    ]
    .into_iter()
    .enumerate()
    {
        let (wire, pane) = Wire::lone();
        let pane_public = wire.mux.with_state(|state| state.panes[&pane].public_id.to_string());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = wire.mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(wire.mux.surface_operation_admission.clone()));
        let mut params = json!({
            "machine": "current", "session": "current", "pane": pane_public, "direction": "left",
        });
        params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        let request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": format!("split-{index}"),
            "operation": "pane.split",
            "idempotency_key": format!("split-browser-{index}"),
            "params": params,
        });
        assert!(handle_connection_message(
            &wire.mux,
            client,
            &request.to_string(),
            &writer,
            &scheduler
        ));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let response: Value = loop {
            if let Some(text) = outbound.try_pop() {
                break serde_json::from_str(&text).unwrap();
            }
            assert!(std::time::Instant::now() < deadline, "no pane.split response");
            std::thread::sleep(std::time::Duration::from_millis(2));
        };
        assert_eq!(response["ok"], false, "{extra} must be refused: {response}");
        assert_eq!(wire.pane_count(), 1, "{extra} must create nothing");
        disconnect_client(&wire.mux, client, false);
    }
}
