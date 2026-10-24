//! The per-Mac host sizing policy (`host-size-policy-v1`,
//! cmux-next-ios/PROTOCOL.md "Terminal sizing policy"): this Mac's views,
//! phones on spliced lanes (`remote:true`), and the mode and order stored in
//! the settings file, over the wire commands.

use super::*;
use crate::mux::settings::SettingsPaths;

struct Rig {
    mux: Arc<Mux>,
    surface: Arc<crate::Surface>,
    config: PathBuf,
    _dir: cmux_unix_socket::TestDir,
}

/// A mux whose settings owner reads and writes its own file.
fn rig(name: &str) -> Rig {
    let dir = cmux_unix_socket::short_test_dir(&format!("hsp-{name}"));
    let config = dir.path().join("cmux-next.json");
    let mux = test_mux();
    assert!(mux.start_settings_owner(SettingsPaths {
        config: config.clone(),
        seed: None,
        state_dir: Some(dir.path().to_path_buf()),
        reader: Box::new(cmux_config::managed::FixedManagedReader::default()),
        watch: false,
    }));
    let surface = mux.new_workspace(None, Some((100, 30))).unwrap();
    Rig { mux, surface, config, _dir: dir }
}

struct View {
    client: u64,
    writer: MessageWriter,
}

/// How a test connection reaches the daemon.
#[derive(Clone, Copy)]
enum Via {
    /// A local Unix connection of this Mac.
    Local,
    /// A local Unix connection whose peer is this build's bundled
    /// cmux-mobile-host (a phone's spliced lane).
    MobileHost,
    /// A WebSocket connection (another machine).
    WebSocket,
}

impl Rig {
    fn run(&self, view: &View, request: Value) -> anyhow::Result<Value> {
        handle_command(&self.mux, view.client, json_command(request), &view.writer)
    }

    /// A connection with this identity, attached to the terminal and
    /// claiming `size`.
    fn view(&self, info: Value, size: (u16, u16)) -> View {
        self.view_via(Via::Local, info, size)
    }

    fn connection(&self, via: Via) -> View {
        let writer = test_writer();
        let transport = match via {
            Via::WebSocket => ClientTransport::WebSocket,
            Via::Local | Via::MobileHost => ClientTransport::Unix,
        };
        let client = self.mux.control_clients.register(transport, writer.clone());
        if matches!(via, Via::MobileHost) {
            origin_gate::set_mobile_host_peer_for_test(&self.mux, client);
        }
        View { client, writer }
    }

    /// The verified cmux app's own connection (origin `user`).
    fn app(&self) -> View {
        let app = self.connection(Via::Local);
        origin_gate::set_role_for_test(&self.mux, app.client, "main");
        origin_gate::set_verified_app_for_test(&self.mux, app.client, true);
        app
    }

    fn view_via(&self, via: Via, info: Value, size: (u16, u16)) -> View {
        let view = self.connection(via);
        let mut info = info;
        info["cmd"] = json!("set-client-info");
        // As the real phone and Mac do: a phone that renders a larger host
        // grid lists `host-grid-view-v1`, so the daemon's handheld ceiling
        // (PR #24638) does not cap the PTY at it.
        info["capabilities"] = json!([SHARED_SIZING_CAPABILITY, HOST_GRID_VIEW_CAPABILITY]);
        self.run(&view, info).unwrap();
        attach_test_view(&self.mux, view.client, self.surface.id, &view.writer);
        self.claim(&view, size);
        view
    }

    fn mac(&self, size: (u16, u16)) -> View {
        self.view(json!({"kind":"frontend","device_kind":"mac","device_name":"Studio"}), size)
    }

    /// A phone as cmux-mobile-host forwards it: `remote` and the link's id.
    fn phone(&self, id: &str, size: (u16, u16)) -> View {
        self.view_via(
            Via::MobileHost,
            json!({"kind":"ios","device_kind":"iphone","device_id":id,"remote":true}),
            size,
        )
    }

    fn claim(&self, view: &View, size: (u16, u16)) {
        self.run(
            view,
            json!({"cmd":"resize-surface","surface":self.surface.id,"cols":size.0,"rows":size.1}),
        )
        .unwrap();
    }

    /// Sets the host policy from the cmux app (the views themselves are
    /// plain local connections, which may not write it).
    fn set_policy(&self, _view: &View, policy: Value) -> Value {
        let app = self.app();
        self.run(&app, json!({"cmd":"set-host-size-policy","policy":policy})).unwrap()
    }

    fn grid(&self) -> (u16, u16) {
        self.surface.size()
    }
}

#[test]
fn host_policy_fit_the_smallest_viewer_is_the_default() {
    let rig = rig("smallest");
    let mac = rig.mac((120, 40));
    let phone = rig.phone("p1", (60, 30));
    assert_eq!(rig.grid(), (60, 30));
    let second = rig.phone("p2", (50, 35));
    assert_eq!(rig.grid(), (50, 30));
    let read = rig.run(&mac, json!({"cmd":"get-host-size-policy"})).unwrap();
    assert_eq!(read["policy"], json!({"mode":"smallest","order":[]}));
    // A phone that stops showing the terminal no longer counts.
    rig.run(&second, json!({"cmd":"release-surface-size","surface":rig.surface.id})).unwrap();
    rig.run(&phone, json!({"cmd":"release-surface-size","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (120, 40));
}

#[test]
fn host_policy_prefer_this_mac_keeps_the_mac_grid_while_phones_claim() {
    let rig = rig("mac");
    let mac = rig.mac((120, 40));
    let answer = rig.set_policy(&mac, json!({"mode":"mac"}));
    assert_eq!(answer["policy"]["mode"], "mac");
    let phone = rig.phone("p1", (60, 30));
    let _second = rig.phone("p2", (50, 35));
    assert_eq!(rig.grid(), (120, 40));
    // The phone typing does not take it either.
    rig.run(&phone, json!({"cmd":"note-size-activity","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (120, 40));
    let read =
        rig.run(&phone, json!({"cmd":"get-host-size-policy","surface":rig.surface.id})).unwrap();
    let mac_id = rig.mux.terminal_view_participant_id(rig.surface.id, mac.client).unwrap();
    assert_eq!(read["mac_participants"], json!([mac_id]));
    // The Mac pane hidden: its view stops counting and a phone sets the grid.
    rig.run(&mac, json!({"cmd":"set-size-counts","surface":rig.surface.id,"counts":false}))
        .unwrap();
    assert_ne!(rig.grid(), (120, 40));
    rig.run(&mac, json!({"cmd":"set-size-counts","surface":rig.surface.id,"counts":null})).unwrap();
    assert_eq!(rig.grid(), (120, 40));
}

#[test]
fn host_policy_a_phone_lane_is_never_this_mac() {
    let rig = rig("remote");
    let mac = rig.mac((120, 40));
    rig.set_policy(&mac, json!({"mode":"mac"}));
    // Another Mac reaching this one over a phone lane, posing as a Mac.
    let other = rig.view(
        json!({"kind":"frontend","device_kind":"mac","device_id":"m2","remote":true}),
        (80, 24),
    );
    // A later `remote:false` cannot undo the mark.
    rig.run(&other, json!({"cmd":"set-client-info","remote":false})).unwrap();
    let read =
        rig.run(&mac, json!({"cmd":"get-host-size-policy","surface":rig.surface.id})).unwrap();
    let mac_id = rig.mux.terminal_view_participant_id(rig.surface.id, mac.client).unwrap();
    assert_eq!(read["mac_participants"], json!([mac_id]));
    rig.run(&other, json!({"cmd":"note-size-activity","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (120, 40));
}

#[test]
fn host_policy_priority_order_ranks_devices_and_falls_through() {
    let rig = rig("priority");
    let mac = rig.mac((120, 40));
    let first = rig.phone("p1", (60, 30));
    let second = rig.phone("p2", (50, 35));
    rig.set_policy(&mac, json!({"mode":"priority","order":["device:p2","mac","device:p1"]}));
    assert_eq!(rig.grid(), (50, 35));
    rig.run(&second, json!({"cmd":"release-surface-size","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (120, 40));
    rig.run(&mac, json!({"cmd":"set-size-counts","surface":rig.surface.id,"counts":false}))
        .unwrap();
    assert_eq!(rig.grid(), (60, 30));
    // The order survives a mode change that omits it.
    rig.set_policy(&mac, json!({"mode":"smallest"}));
    let read = rig.run(&first, json!({"cmd":"get-host-size-policy"})).unwrap();
    assert_eq!(read["policy"]["order"], json!(["device:p2", "mac", "device:p1"]));
    let app = rig.app();
    assert!(
        rig.run(
            &app,
            json!({"cmd":"set-host-size-policy","policy":{"mode":"priority","order":["nope"]}})
        )
        .is_err()
    );
    assert!(
        rig.run(&app, json!({"cmd":"set-host-size-policy","policy":{"mode":"tallest"}})).is_err()
    );
}

#[test]
fn host_policy_prefer_the_active_device_follows_input() {
    let rig = rig("latest");
    let mac = rig.mac((120, 40));
    rig.set_policy(&mac, json!({"mode":"latest"}));
    let phone = rig.phone("p1", (60, 30));
    // A phone that only attached does not take the grid.
    assert_eq!(rig.grid(), (120, 40));
    rig.run(&phone, json!({"cmd":"note-size-activity","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (60, 30));
    rig.run(&mac, json!({"cmd":"note-size-activity","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (120, 40));
}

#[test]
fn host_policy_is_stored_in_the_settings_file_and_followed_live() {
    let rig = rig("stored");
    let mac = rig.mac((120, 40));
    let _phone = rig.phone("p1", (60, 30));
    assert_eq!(rig.grid(), (60, 30));
    rig.set_policy(&mac, json!({"mode":"mac"}));
    assert_eq!(rig.grid(), (120, 40));
    let file: Value = serde_json::from_str(&std::fs::read_to_string(&rig.config).unwrap()).unwrap();
    assert_eq!(file["mobile"]["terminalSizing"], "mac");
    // An edit through the settings owner (the Mac's Settings page) applies too.
    rig.mux
        .settings_apply(cmux_config::Op::Set {
            target: cmux_config::Target::Key("mobile.terminalSizing".into()),
            value: json!("smallest"),
            meta: cmux_config::WriteMeta {
                origin: cmux_config::Origin::App,
                idempotency_key: None,
                if_revision: None,
            },
        })
        .unwrap();
    assert_eq!(rig.grid(), (60, 30));
    // A terminal override still wins over the host policy.
    rig.run(
        &mac,
        json!({"cmd":"set-size-policy","surface":rig.surface.id,"policy":{"mode":"fixed","fixed":{"cols":90,"rows":20}}}),
    )
    .unwrap();
    rig.set_policy(&mac, json!({"mode":"mac"}));
    assert_eq!(rig.grid(), (90, 20));
    rig.run(&mac, json!({"cmd":"set-size-policy","surface":rig.surface.id,"policy":null})).unwrap();
    assert_eq!(rig.grid(), (120, 40));
}

#[test]
fn host_policy_capability_is_identified() {
    assert!(advertised_capabilities(false).contains(&"host-size-policy-v1"));
}

/// Review finding 1: "this Mac" is decided by the daemon from what it can
/// check about the connection, never by a missing opt-in flag.
#[test]
fn host_policy_only_local_connections_are_this_mac() {
    let rig = rig("local-only");
    let mac = rig.mac((120, 40));
    rig.set_policy(&mac, json!({"mode":"mac"}));
    // Another machine's Mac over a WebSocket, with no `remote` mark.
    let websocket = rig.view_via(
        Via::WebSocket,
        json!({"kind":"frontend","device_kind":"mac","device_id":"m2"}),
        (80, 24),
    );
    // A phone lane whose set-client-info hostd did not mark (an older hostd).
    let lane = rig.view_via(
        Via::MobileHost,
        json!({"kind":"frontend","device_kind":"mac","device_id":"m3"}),
        (70, 20),
    );
    let read =
        rig.run(&mac, json!({"cmd":"get-host-size-policy","surface":rig.surface.id})).unwrap();
    let mac_id = rig.mux.terminal_view_participant_id(rig.surface.id, mac.client).unwrap();
    assert_eq!(read["mac_participants"], json!([mac_id]));
    rig.run(&websocket, json!({"cmd":"note-size-activity","surface":rig.surface.id})).unwrap();
    rig.run(&lane, json!({"cmd":"note-size-activity","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (120, 40));
}

/// Review finding 2: only the cmux app and a phone's lane write the Mac's
/// policy; an agent's or a script's local connection, or another machine,
/// is refused.
#[test]
fn host_policy_writes_come_from_the_app_or_a_phone_only() {
    let rig = rig("writers");
    let local = rig.connection(Via::Local);
    let refused = rig.run(&local, json!({"cmd":"set-host-size-policy","policy":{"mode":"mac"}}));
    assert!(refused.unwrap_err().to_string().contains("forbidden"));
    let websocket = rig.connection(Via::WebSocket);
    assert!(
        rig.run(&websocket, json!({"cmd":"set-host-size-policy","policy":{"mode":"mac"}})).is_err()
    );
    assert_eq!(rig.mux.host_size_policy().mode, crate::mux::host_policy::HostSizeMode::Smallest);
    let phone = rig.phone("p1", (60, 30));
    let answer =
        rig.run(&phone, json!({"cmd":"set-host-size-policy","policy":{"mode":"latest"}})).unwrap();
    assert_eq!(answer["policy"]["mode"], "latest");
    let app = rig.app();
    rig.run(&app, json!({"cmd":"set-host-size-policy","policy":{"mode":"mac"}})).unwrap();
    assert_eq!(rig.mux.host_size_policy().mode, crate::mux::host_policy::HostSizeMode::Mac);
    // Reading stays open to every connection.
    rig.run(&local, json!({"cmd":"get-host-size-policy"})).unwrap();
}

/// Review finding 3: a policy read from an older settings revision never
/// replaces one from a newer revision, whatever order they are adopted in.
#[test]
fn host_policy_adopts_settings_revisions_in_order() {
    use crate::mux::host_policy::{HostSizeMode, HostSizePolicy};
    let rig = rig("revisions");
    let newer = HostSizePolicy { mode: HostSizeMode::Latest, order: Vec::new() };
    let older = HostSizePolicy { mode: HostSizeMode::Mac, order: Vec::new() };
    rig.mux.adopt_host_size_policy(newer.clone(), 1_000_002);
    rig.mux.adopt_host_size_policy(older, 1_000_001);
    assert_eq!(rig.mux.host_size_policy(), newer);
}

/// Review finding 9: a terminal shown in two workspaces keeps a workspace
/// default of either; the host policy never overwrites it.
#[test]
fn host_policy_never_overrides_a_workspace_default_of_any_placement() {
    let rig = rig("placements");
    let mac = rig.mac((120, 40));
    let other = rig.mux.new_workspace(None, Some((100, 30))).unwrap();
    let pane = rig.mux.with_state(|state| state.pane_of(other.id).unwrap());
    let terminal = rig.surface.terminal_public_id().cloned().unwrap();
    rig.mux
        .resource_project_terminal_selected(
            crate::ResourceSelectors {
                terminal: Some(terminal.to_string()),
                ..Mux::ordinary_resource_selectors()
            },
            rig.mux.ordinary_pane_selectors(pane).unwrap(),
            usize::MAX,
            None,
            None,
            &WorkspaceMutation::daemon_local("test-terminal-projection"),
        )
        .unwrap();
    let workspace = rig.mux.surface_workspace(other.id).unwrap();
    rig.mux
        .set_workspace_size_policy(
            workspace,
            Some(TerminalSizingPolicy::new(
                crate::sizing_policy::TerminalSizingMode::Fixed,
                Vec::new(),
                Some(crate::sizing_policy::TerminalGridSize::new(90, 20)),
            )),
        )
        .unwrap();
    assert_eq!(rig.grid(), (90, 20));
    // A new viewer (a re-expansion of the host policy) keeps it.
    let _phone = rig.phone("p1", (60, 30));
    assert_eq!(rig.grid(), (90, 20));
    let _ = mac;
}

/// Review 2 finding 1: a phone's lane relays no other device, so a sub-view
/// (`resize-attached-view`) it opens may not take a device's place in the
/// priority order by copying that device's user and device id.
#[test]
fn host_policy_a_phone_lanes_sub_view_cannot_take_a_devices_place() {
    let rig = rig("subview");
    let mac = rig.mac((120, 40));
    let ipad = rig.view_via(
        Via::MobileHost,
        json!({"kind":"ios","device_kind":"ipad","device_id":"ipad-1","user_id":"u1","remote":true}),
        (90, 30),
    );
    rig.set_policy(&mac, json!({"mode":"priority","order":["device:ipad-1","mac"]}));
    assert_eq!(rig.grid(), (90, 30));
    rig.run(&ipad, json!({"cmd":"release-surface-size","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (120, 40));
    // Another phone's lane opens a sub-view with the iPad's whole identity.
    let phone = rig.connection(Via::MobileHost);
    rig.run(
        &phone,
        json!({"cmd":"set-client-info","kind":"ios","device_kind":"iphone","device_id":"p2","remote":true,
               "capabilities":[SHARED_SIZING_CAPABILITY, HOST_GRID_VIEW_CAPABILITY]}),
    )
    .unwrap();
    attach_test_view(&rig.mux, phone.client, rig.surface.id, &phone.writer);
    rig.run(
        &phone,
        json!({"cmd":"resize-attached-view","surface":rig.surface.id,"view":"spoof",
               "identity":{"user_id":"u1","device_kind":"ipad","device_id":"ipad-1"},"cols":40,"rows":20}),
    )
    .unwrap();
    assert_eq!(rig.grid(), (120, 40), "the sub-view never ranks as the iPad");
}
