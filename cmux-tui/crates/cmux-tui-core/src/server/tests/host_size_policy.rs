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

/// Leo, 2026-11-15: "i dont see the point of a narrower-than-iphone
/// terminal". A Mac pane of 39x26 and a phone of 54 columns: the grid stays
/// as wide as the phone while it shows the terminal; the Mac pane clips.
#[test]
fn host_policy_fit_the_smallest_viewer_is_never_narrower_than_a_showing_phone() {
    let rig = rig("phone-floor");
    let mac = rig.mac((120, 40));
    let phone = rig.phone("p1", (54, 40));
    assert_eq!(rig.grid(), (54, 40));
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26), "columns keep the phone's width, rows fit the Mac pane");
    // Once the phone stops showing the terminal, the Mac pane sets it.
    rig.run(&phone, json!({"cmd":"release-surface-size","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (39, 26));
}

fn split_beside(rig: &Rig, actor: &crate::Actor) {
    let pane = rig.mux.with_state(|state| state.pane_of(rig.surface.id).unwrap());
    rig.mux.split_as(actor, pane, SplitDir::Right, None).unwrap();
}

fn agent() -> crate::Actor {
    crate::Actor::Terminal { id: "term_agent".into() }
}

#[test]
fn host_policy_an_agent_split_does_not_shrink_the_grid_until_the_person_uses_the_mac_pane() {
    let rig = rig("agent-split");
    let mac = rig.mac((120, 40));
    let phone = rig.phone("p1", (54, 40));
    assert_eq!(rig.grid(), (54, 40));
    // An agent splits the Mac pane; the app reports the pane's new size.
    split_beside(&rig, &agent());
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "the agent's split does not count");
    // The person types in the Mac pane: its own size counts again.
    rig.run(&mac, json!({"cmd":"note-size-activity","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (54, 26));
    rig.run(&phone, json!({"cmd":"release-surface-size","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (39, 26));
}

#[test]
fn host_policy_an_agent_split_counts_once_no_other_view_does() {
    let rig = rig("agent-split-alone");
    let mac = rig.mac((120, 40));
    let phone = rig.phone("p1", (54, 40));
    split_beside(&rig, &agent());
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40));
    // The phone leaves: the Mac pane is the only viewer and fits its pane.
    rig.run(&phone, json!({"cmd":"release-surface-size","surface":rig.surface.id})).unwrap();
    assert_eq!(rig.grid(), (39, 26));
    // A Mac alone is never held: a later agent split resizes it at once.
    split_beside(&rig, &agent());
    rig.claim(&mac, (30, 20));
    assert_eq!(rig.grid(), (30, 20));
}

#[test]
fn host_policy_a_person_split_shrinks_the_mac_pane_at_once() {
    let rig = rig("person-split");
    let mac = rig.mac((120, 40));
    let _phone = rig.phone("p1", (54, 40));
    split_beside(&rig, &crate::Actor::Frontend { install_id: "signed_app".into() });
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26));
}

/// A second column right of the rig's pane, made by the daemon (not an
/// agent): the panes of the two columns.
fn two_columns(rig: &Rig) -> (PaneId, PaneId) {
    two_columns_of(rig, &rig.surface)
}

/// As [`two_columns`], in the workspace of `surface`.
fn two_columns_of(rig: &Rig, surface: &crate::Surface) -> (PaneId, PaneId) {
    let first = rig.mux.with_state(|state| state.pane_of(surface.id).unwrap());
    let right = rig.mux.new_pane_right(first, 0.5, Some((38, 22))).unwrap();
    let right = rig.mux.with_state(|state| state.pane_of(right.id).unwrap());
    (first, right)
}

fn column_widths(rig: &Rig) -> Vec<f32> {
    rig.mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns.iter().map(|column| column.width).collect()
    })
}

/// `set-layout-sizes` of `actor`: the widths of the two columns as one
/// change.
fn batch(
    rig: &Rig,
    actor: &crate::Actor,
    columns: (PaneId, PaneId),
    widths: (f32, f32),
) -> Result<(), crate::mux::LayoutSizesError> {
    rig.mux.set_layout_sizes_in_transaction_checked_as(
        actor,
        &[
            crate::mux::LayoutSizeValue::PaneWidth { pane: columns.0, width: widths.0 },
            crate::mux::LayoutSizeValue::PaneWidth { pane: columns.1, width: widths.1 },
        ],
        7,
        1,
    )
}

/// The rig with two columns, this Mac's view and a phone that sets the grid.
fn two_column_rig(name: &str) -> (Rig, (PaneId, PaneId), View, View) {
    let rig = rig(name);
    let columns = two_columns(&rig);
    let mac = rig.mac((120, 40));
    let phone = rig.phone("p1", (54, 40));
    assert_eq!(rig.grid(), (54, 40), "the start: the phone sets the grid");
    (rig, columns, mac, phone)
}

/// An agent that narrows the Mac pane with one batch is an agent's layout
/// change as much as its split is: the phone's grid stays.
#[test]
fn host_policy_an_agent_batch_resize_does_not_shrink_the_grid() {
    let (rig, columns, mac, _phone) = two_column_rig("batch-agent");
    batch(&rig, &agent(), columns, (0.4, 0.6)).unwrap();
    assert_eq!(column_widths(&rig), vec![0.4, 0.6], "the batch did not set the widths");
    // The app reports the pane's new size.
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "the agent's batch does not count");
}

/// The same change as two single commands of the agent: the grid stays.
#[test]
fn host_policy_an_agent_width_command_does_not_shrink_the_grid() {
    let (rig, columns, mac, _phone) = two_column_rig("batch-singles");
    rig.mux.set_viewport_pane_width_checked_as(&agent(), columns.0, 0.4).unwrap();
    rig.mux.set_viewport_pane_width_checked_as(&agent(), columns.1, 0.6).unwrap();
    let widths = column_widths(&rig);
    assert!(
        (widths[0] - 0.4).abs() < 1e-6 && (widths[1] - 0.6).abs() < 1e-6,
        "the commands did not set the widths: {widths:?}"
    );
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "the agent's width commands do not count");
}

#[test]
fn host_policy_a_person_batch_resize_shrinks_the_mac_pane_at_once() {
    let (rig, columns, mac, _phone) = two_column_rig("batch-person");
    let person = crate::Actor::Frontend { install_id: "signed_app".into() };
    batch(&rig, &person, columns, (0.4, 0.6)).unwrap();
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26));
}

/// A batch that the daemon refuses changed no pane: a smaller report after
/// it is the person's own and counts at once.
#[test]
fn host_policy_an_agent_batch_that_is_refused_holds_nothing() {
    let (rig, columns, mac, _phone) = two_column_rig("batch-refused");
    let before = column_widths(&rig);
    let error = batch(&rig, &agent(), columns, (0.4, 1.5)).unwrap_err();
    assert_eq!(error.index(), Some(1), "{error}");
    assert_eq!(column_widths(&rig), before, "a refused batch changed a width");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26), "a refused batch held the Mac view's report");
}

/// A batch of the widths the columns have changes nothing and holds nothing.
#[test]
fn host_policy_an_agent_batch_that_changes_nothing_holds_nothing() {
    let (rig, columns, mac, _phone) = two_column_rig("batch-same");
    let now = column_widths(&rig);
    batch(&rig, &agent(), columns, (now[0], now[1])).unwrap();
    assert_eq!(column_widths(&rig), now, "a batch of the same widths changed a width");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26), "a batch that changed nothing held the Mac view's report");
}

/// An agent changes the layout, then sends a batch that is refused, before
/// the app's report of the first change arrives: that report is still the
/// agent's and does not count.
#[test]
fn host_policy_an_agent_refused_batch_keeps_the_hold_of_its_earlier_change() {
    let (rig, columns, mac, _phone) = two_column_rig("batch-later-no");
    rig.mux.set_viewport_pane_width_checked_as(&agent(), columns.0, 0.4).unwrap();
    assert!(batch(&rig, &agent(), columns, (0.3, 1.5)).is_err(), "a width of 1.5 was taken");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "a refused batch ended the hold of the earlier change");
}

/// As above, with a later batch that changes nothing.
#[test]
fn host_policy_an_agent_unchanged_batch_keeps_the_hold_of_its_earlier_change() {
    let (rig, columns, mac, _phone) = two_column_rig("batch-later-same");
    rig.mux.set_viewport_pane_width_checked_as(&agent(), columns.0, 0.4).unwrap();
    let now = column_widths(&rig);
    batch(&rig, &agent(), columns, (now[0], now[1])).unwrap();
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "an unchanged batch ended the hold of the earlier change");
}

/// The rig with a second workspace, this Mac's view of the first one and a
/// phone that sets the grid.
fn two_workspace_rig(name: &str) -> (Rig, Arc<crate::Surface>, View, View) {
    let rig = rig(name);
    let other = rig.mux.new_workspace(None, Some((100, 30))).unwrap();
    let mac = rig.mac((120, 40));
    let phone = rig.phone("p1", (54, 40));
    assert_eq!(rig.grid(), (54, 40), "the start: the phone sets the grid");
    (rig, other, mac, phone)
}

/// An agent changes this workspace's layout, then another workspace's,
/// before the app's report of the first change arrives: that report is still
/// the agent's and does not count.
#[test]
fn host_policy_an_agent_change_in_another_workspace_keeps_the_hold_of_this_one() {
    let (rig, other, mac, _phone) = two_workspace_rig("agent-elsewhere");
    split_beside(&rig, &agent());
    let pane = rig.mux.with_state(|state| state.pane_of(other.id).unwrap());
    rig.mux.split_as(&agent(), pane, SplitDir::Right, None).unwrap();
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "a change in another workspace ended this one's hold");
}

/// As above, with a batch in the other workspace as the later change.
#[test]
fn host_policy_an_agent_batch_in_another_workspace_keeps_the_hold_of_this_one() {
    let (rig, other, mac, _phone) = two_workspace_rig("batch-elsewhere");
    let columns = two_columns_of(&rig, &other);
    split_beside(&rig, &agent());
    batch(&rig, &agent(), columns, (0.4, 0.6)).unwrap();
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "a batch in another workspace ended this one's hold");
}

/// An agent's change in another workspace alone holds nothing here: a
/// smaller report of this workspace's view is the person's own.
#[test]
fn host_policy_an_agent_change_in_another_workspace_holds_nothing_here() {
    let (rig, other, mac, _phone) = two_workspace_rig("agent-elsewhere-only");
    let pane = rig.mux.with_state(|state| state.pane_of(other.id).unwrap());
    rig.mux.split_as(&agent(), pane, SplitDir::Right, None).unwrap();
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26), "a change in another workspace held this one's view");
}

fn person() -> crate::Actor {
    crate::Actor::Frontend { install_id: "signed_app".into() }
}

/// A person's batch makes the first column (this Mac's pane) wider: the
/// widths before it, which an undo puts back.
fn widened_by_a_person(rig: &Rig, columns: (PaneId, PaneId)) -> Vec<f32> {
    let before = column_widths(rig);
    batch(rig, &person(), columns, (0.62, 0.38)).unwrap();
    assert_eq!(column_widths(rig), vec![0.62, 0.38], "the batch did not set the widths");
    assert_ne!(before, vec![0.62, 0.38], "the batch changed nothing");
    before
}

fn undo(rig: &Rig, actor: &crate::Actor, pane: PaneId) {
    let undone = rig.mux.undo_layout_as(actor, pane, None, false).unwrap();
    assert!(matches!(undone, crate::LayoutUndoResult::Undone { .. }), "{undone:?}");
}

/// An agent that undoes a resize makes this Mac's pane narrower as its own
/// resize does: the phone's grid stays.
#[test]
fn host_policy_an_agent_undo_of_a_resize_does_not_shrink_the_grid() {
    let (rig, columns, mac, _phone) = two_column_rig("undo-agent");
    let before = widened_by_a_person(&rig, columns);
    undo(&rig, &agent(), columns.0);
    assert_eq!(column_widths(&rig), before, "the undo did not put the widths back");
    // The app reports the pane's new size.
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "the agent's undo does not count");
}

#[test]
fn host_policy_a_person_undo_of_a_resize_shrinks_the_mac_pane_at_once() {
    let (rig, columns, mac, _phone) = two_column_rig("undo-person");
    let before = widened_by_a_person(&rig, columns);
    undo(&rig, &person(), columns.0);
    assert_eq!(column_widths(&rig), before, "the undo did not put the widths back");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26));
}

/// A width for the column of `pane` on the resource route
/// (`pane.viewport_width.set`), which reads its value after the views are
/// marked.
fn route_width(rig: &Rig, actor: &crate::Actor, pane: PaneId, width: f64) -> anyhow::Result<()> {
    let selectors = rig.mux.ordinary_pane_selectors(pane).unwrap();
    let fields = serde_json::Map::from_iter([("width".to_string(), json!(width))]);
    rig.mux
        .resource_topology_operation(
            ResourceOperation::PaneViewportWidthSet,
            selectors,
            fields,
            None,
            &WorkspaceMutation::local("host-size-policy-test", actor.clone()),
        )
        .map(|_| ())
}

/// A width that the resource route refuses changed no pane: a smaller report
/// after it is the person's own and counts at once.
#[test]
fn host_policy_an_agent_width_that_the_resource_route_refuses_holds_nothing() {
    let (rig, columns, mac, _phone) = two_column_rig("route-refused");
    let before = column_widths(&rig);
    assert!(route_width(&rig, &agent(), columns.0, 1.5).is_err(), "a width of 1.5 was taken");
    assert_eq!(column_widths(&rig), before, "a refused width changed a width");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26), "a refused width held the Mac view's report");
}

/// An agent sets a width on the resource route, then sends one that is
/// refused, before the app's report of the first change arrives: that report
/// is still the agent's and does not count.
#[test]
fn host_policy_an_agent_refused_width_keeps_the_hold_of_its_earlier_change() {
    let (rig, columns, mac, _phone) = two_column_rig("route-later-no");
    route_width(&rig, &agent(), columns.0, 0.4).unwrap();
    let widths = column_widths(&rig);
    assert!((widths[0] - 0.4).abs() < 1e-6, "the route did not set the width: {widths:?}");
    assert!(route_width(&rig, &agent(), columns.0, 1.5).is_err(), "a width of 1.5 was taken");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "a refused width ended the hold of the earlier change");
}

/// A batch whose value is a split ratio (the divider between the two columns)
/// is the agent's change as a batch of widths is.
#[test]
fn host_policy_an_agent_batch_of_a_split_ratio_does_not_shrink_the_grid() {
    let (rig, _columns, mac, _phone) = two_column_rig("batch-ratio");
    let before = column_widths(&rig);
    let split = rig.mux.with_state(|state| state.workspaces[0].screens[0].layout_columns[1].id);
    rig.mux
        .set_layout_sizes_in_transaction_checked_as(
            &agent(),
            &[crate::mux::LayoutSizeValue::SplitRatio { split, ratio: 0.6 }],
            7,
            1,
        )
        .unwrap();
    assert_ne!(column_widths(&rig), before, "the batch did not move the divider");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "the agent's batch of a ratio does not count");
}

/// A local connection that the daemon types as a process in a cmux terminal
/// (an agent), as accept does from the peer's process.
fn agent_connection(rig: &Rig) -> View {
    let view = rig.connection(Via::Local);
    origin_gate::set_local_peer_for_test(
        &rig.mux,
        view.client,
        crate::request_origin::LocalPeer::Terminal("term_agent".into()),
    );
    let actor = origin_gate::connection_actor(&rig.mux, view.client);
    assert!(matches!(actor, crate::Actor::Terminal { .. }), "the connection's actor is {actor:?}");
    view
}

/// The wire command `set-layout-sizes` of `view`'s connection: the widths of
/// the two columns as one change.
fn wire_batch(rig: &Rig, view: &View, columns: (PaneId, PaneId), widths: (f32, f32)) {
    rig.run(
        view,
        json!({"cmd":"set-layout-sizes","transaction":1,"values":[
            {"pane":columns.0,"width":widths.0},{"pane":columns.1,"width":widths.1}]}),
    )
    .unwrap();
    assert_eq!(column_widths(rig), vec![widths.0, widths.1], "the command did not set the widths");
}

/// The command itself, from a connection that the daemon types as an agent:
/// the actor the handler reads is the one that marks the views.
#[test]
fn host_policy_an_agent_connection_batch_does_not_shrink_the_grid() {
    let (rig, columns, mac, _phone) = two_column_rig("wire-agent");
    wire_batch(&rig, &agent_connection(&rig), columns, (0.4, 0.6));
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "the agent's batch does not count");
}

/// The same command from the local user's own connection is a person's.
#[test]
fn host_policy_a_local_connection_batch_shrinks_the_mac_pane_at_once() {
    let (rig, columns, mac, _phone) = two_column_rig("wire-person");
    wire_batch(&rig, &rig.connection(Via::Local), columns, (0.4, 0.6));
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26));
}

/// A ratio for the divider between the two columns on the resource route
/// (`pane.split_ratio.set`), which reads its value after the views are
/// marked.
fn route_ratio(rig: &Rig, actor: &crate::Actor, pane: PaneId, ratio: f64) -> anyhow::Result<()> {
    let split = rig
        .mux
        .with_state(|state| {
            let split = state.workspaces[0].screens[0].layout_columns[1].id;
            state.resource_indexes.split_ids.get(&split).map(ToString::to_string)
        })
        .unwrap();
    let selectors = rig.mux.ordinary_pane_selectors(pane).unwrap();
    let fields = serde_json::Map::from_iter([
        ("split_id".to_string(), json!(split)),
        ("ratio".to_string(), json!(ratio)),
    ]);
    rig.mux
        .resource_topology_operation(
            ResourceOperation::PaneSplitRatioSet,
            selectors,
            fields,
            None,
            &WorkspaceMutation::local("host-size-policy-test", actor.clone()),
        )
        .map(|_| ())
}

/// The control of the row below: the same call with a ratio that is taken is
/// the agent's change.
#[test]
fn host_policy_an_agent_split_ratio_on_the_resource_route_does_not_shrink_the_grid() {
    let (rig, columns, mac, _phone) = two_column_rig("route-ratio");
    let before = column_widths(&rig);
    route_ratio(&rig, &agent(), columns.0, 0.6).unwrap();
    assert_ne!(column_widths(&rig), before, "the route did not move the divider");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "the agent's ratio does not count");
}

/// A split ratio that the resource route refuses changed no pane, as a
/// refused width: a smaller report after it counts at once.
#[test]
fn host_policy_an_agent_split_ratio_that_the_resource_route_refuses_holds_nothing() {
    let (rig, columns, mac, _phone) = two_column_rig("route-ratio-refused");
    let before = column_widths(&rig);
    let refused = route_ratio(&rig, &agent(), columns.0, 1.5).unwrap_err();
    assert!(format!("{refused:#}").contains("invalid split ratio"), "{refused:#}");
    assert_eq!(column_widths(&rig), before, "a refused ratio changed a width");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26), "a refused ratio held the Mac view's report");
}

/// The creation command with a receipt (`create-surface-with-receipt`) of
/// `view`'s connection: a pane right of the rig's pane. The app's own
/// creations use this command; any connection that lists the capability can.
fn wire_receipted_split(rig: &Rig, view: &View) {
    rig.run(view, json!({"cmd":"set-client-info","capabilities":[CREATION_RECEIPTS_CAPABILITY]}))
        .unwrap();
    let pane = rig.mux.with_state(|state| state.pane_of(rig.surface.id).unwrap());
    let panes =
        || rig.mux.with_state(|state| state.workspaces[0].screens[0].root.pane_ids_vec().len());
    let before = panes();
    let reply = rig
        .run(
            view,
            json!({"cmd":"create-surface-with-receipt","operation":"split-right",
                "origin":"host-size-policy-test","receipt":"host-size-policy-split-0001",
                "pane":pane}),
        )
        .unwrap();
    assert_eq!(reply["replayed"], false, "{reply}");
    assert_eq!(panes(), before + 1, "the command made no pane");
}

/// A split through the creation command with a receipt, from a connection
/// that the daemon types as an agent, is the agent's layout change.
#[test]
fn host_policy_an_agent_connection_receipted_split_does_not_shrink_the_grid() {
    let rig = rig("receipt-agent");
    let mac = rig.mac((120, 40));
    let _phone = rig.phone("p1", (54, 40));
    let agent = agent_connection(&rig);
    wire_receipted_split(&rig, &agent);
    // The client info did not change who the connection is.
    let actor = origin_gate::connection_actor(&rig.mux, agent.client);
    assert!(matches!(actor, crate::Actor::Terminal { .. }), "the connection's actor is {actor:?}");
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 40), "the agent's split does not count");
}

/// The same command from the local user's own connection is a person's.
#[test]
fn host_policy_a_local_connection_receipted_split_shrinks_the_mac_pane_at_once() {
    let rig = rig("receipt-person");
    let mac = rig.mac((120, 40));
    let _phone = rig.phone("p1", (54, 40));
    wire_receipted_split(&rig, &rig.connection(Via::Local));
    rig.claim(&mac, (39, 26));
    assert_eq!(rig.grid(), (54, 26));
}
