//! Wire tests for `split-client-keys-v1` (plans/cmux-next/remote-state-ownership.md
//! S1): `split`, `new-pane` and `new-pane-right` take client-minted public ids
//! for the new pane (`pane_id`) and its tab (`tab_id`), so a frontend can show
//! the pane before the reply under the ids the daemon will use. The ids are
//! fixed when the creation is prepared, a retry of the same request returns
//! the first result, the same id with another request is refused
//! (`creation.conflict`), and an id
//! that already exists is refused. A retry with the same `terminal_id` and no
//! pane id also returns the first result instead of `terminal_id_exists`.

use super::*;

const CAPABILITY: &str = "split-client-keys-v1";

struct Frontend {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
}

impl Frontend {
    fn new() -> Self {
        let mux = Mux::new_for_test("split-client-keys", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound, control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        Self { mux, client, writer }
    }

    fn run(&self, request: Value) -> anyhow::Result<Value> {
        let command: Command = serde_json::from_value(request).unwrap();
        handle_command(&self.mux, self.client, command, &self.writer)
    }

    fn first_pane(&self) -> PaneId {
        let surface = self.mux.new_workspace(None, Some((80, 24))).unwrap().id;
        self.mux.with_state(|state| state.pane_of(surface)).unwrap()
    }

    fn pane_count(&self) -> usize {
        self.mux.with_state(|state| state.panes.len())
    }

    /// The public ids of the pane holding `surface` and of its tab.
    fn public_ids(&self, created: &Value) -> (String, String) {
        let surface = created["surface"].as_u64().expect("created surface");
        let pane = self
            .mux
            .with_state(|state| {
                state.pane_of(surface).map(|pane| state.panes[&pane].public_id.to_string())
            })
            .expect("surface is placed");
        let tab = self
            .mux
            .surface(surface)
            .and_then(|surface| {
                surface.resource_identity().map(|identity| identity.tab_id.to_string())
            })
            .expect("surface has a tab identity");
        (pane, tab)
    }
}

fn pane_id(n: u8) -> String {
    format!("pane_{:032x}", 0x5100_0000_0000_0000_0000_0000_0000_0000u128 + u128::from(n))
}

fn tab_id(n: u8) -> String {
    format!("tab_{:032x}", 0x5100_0000_0000_0000_0000_0000_0000_0000u128 + u128::from(n))
}

/// A UUIDv4 in lowercase hex (`terminal-placement-env-v1`).
fn terminal_id(n: u8) -> String {
    format!("51000000000040008000{n:012x}")
}

/// The resource error code of a refused request.
fn code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<ResourceError>().map(|error| error.code.clone())
}

#[test]
fn the_daemon_advertises_split_client_keys() {
    assert!(advertised_capabilities(false).contains(&CAPABILITY));
}

#[test]
fn a_split_uses_the_client_minted_pane_and_tab_ids() {
    let frontend = Frontend::new();
    let pane = frontend.first_pane();
    for (n, request) in [
        json!({"cmd": "split", "pane": pane, "dir": "right"}),
        json!({"cmd": "new-pane", "pane": pane}),
        json!({"cmd": "new-pane-right", "pane": pane, "width": 0.5}),
    ]
    .into_iter()
    .enumerate()
    {
        let n = n as u8;
        let mut request = request;
        request["pane_id"] = json!(pane_id(n));
        request["tab_id"] = json!(tab_id(n));
        request["terminal_id"] = json!(terminal_id(n));
        let created = frontend.run(request.clone()).unwrap();
        assert_eq!(frontend.public_ids(&created), (pane_id(n), tab_id(n)), "{request}");
    }
}

#[test]
fn a_retry_with_the_same_ids_returns_the_first_split() {
    let frontend = Frontend::new();
    let pane = frontend.first_pane();
    let request = json!({
        "cmd": "split", "pane": pane, "dir": "right",
        "pane_id": pane_id(1), "tab_id": tab_id(1), "terminal_id": terminal_id(1),
    });
    let first = frontend.run(request.clone()).unwrap();
    let panes = frontend.pane_count();
    let retry = frontend.run(request).unwrap();
    assert_eq!(retry["surface"], first["surface"]);
    assert_eq!(retry["replayed"], json!(true));
    assert_eq!(frontend.pane_count(), panes, "a retry creates nothing");
}

#[test]
fn the_same_pane_id_with_another_request_is_refused() {
    let frontend = Frontend::new();
    let pane = frontend.first_pane();
    frontend
        .run(json!({"cmd": "split", "pane": pane, "dir": "right", "pane_id": pane_id(2)}))
        .unwrap();
    let panes = frontend.pane_count();
    let error = frontend
        .run(json!({"cmd": "split", "pane": pane, "dir": "down", "pane_id": pane_id(2)}))
        .unwrap_err();
    assert_eq!(code(&error).as_deref(), Some("creation.conflict"), "{error:#}");
    assert_eq!(frontend.pane_count(), panes);
}

#[test]
fn a_pane_id_that_already_exists_is_refused() {
    let frontend = Frontend::new();
    let pane = frontend.first_pane();
    let existing = frontend.mux.with_state(|state| state.panes[&pane].public_id.to_string());
    let panes = frontend.pane_count();
    let error = frontend
        .run(json!({"cmd": "split", "pane": pane, "dir": "right", "pane_id": existing}))
        .unwrap_err();
    assert!(format!("{error:#}").contains("pane_id_exists"), "{error:#}");
    assert_eq!(frontend.pane_count(), panes);
}

#[test]
fn a_tab_id_that_already_exists_is_refused() {
    let frontend = Frontend::new();
    let pane = frontend.first_pane();
    let first = frontend
        .run(json!({"cmd": "split", "pane": pane, "dir": "right", "tab_id": tab_id(3)}))
        .unwrap();
    let (_, tab) = frontend.public_ids(&first);
    assert_eq!(tab, tab_id(3));
    let panes = frontend.pane_count();
    let error = frontend
        .run(json!({"cmd": "split", "pane": pane, "dir": "down", "tab_id": tab_id(3)}))
        .unwrap_err();
    assert!(format!("{error:#}").contains("tab_id_exists"), "{error:#}");
    assert_eq!(frontend.pane_count(), panes);
}

#[test]
fn a_terminal_id_retry_returns_the_first_split() {
    let frontend = Frontend::new();
    let pane = frontend.first_pane();
    let request =
        json!({"cmd": "split", "pane": pane, "dir": "right", "terminal_id": terminal_id(4)});
    let first = frontend.run(request.clone()).unwrap();
    let panes = frontend.pane_count();
    let retry = frontend.run(request).unwrap();
    assert_eq!(retry["surface"], first["surface"]);
    assert_eq!(retry["replayed"], json!(true));
    assert_eq!(frontend.pane_count(), panes);
}

#[test]
fn malformed_client_ids_are_refused_before_anything_is_created() {
    let frontend = Frontend::new();
    let pane = frontend.first_pane();
    let panes = frontend.pane_count();
    for (field, value) in
        [("pane_id", "pane_xyz"), ("tab_id", "pane_00000000000000000000000000000001")]
    {
        let error = frontend
            .run(json!({"cmd": "split", "pane": pane, "dir": "right", field: value}))
            .unwrap_err();
        assert!(format!("{error:#}").contains("bad request"), "{field}: {error:#}");
    }
    assert_eq!(frontend.pane_count(), panes);
}
