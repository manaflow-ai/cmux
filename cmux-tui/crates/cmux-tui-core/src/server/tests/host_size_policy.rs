//! The per-Mac host sizing policy (`host-size-policy-v1`,
//! cmux-next-ios/PROTOCOL.md "Terminal sizing policy"): this Mac's views,
//! phones on spliced lanes (`remote:true`), and the mode and order stored in
//! the settings file, over the wire commands.

use super::*;
use crate::mux::settings::SettingsPaths;

struct Rig {
    mux: Arc<Mux>,
    surface: Arc<crate::Surface>,
    config: std::path::PathBuf,
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

impl Rig {
    fn run(&self, view: &View, request: Value) -> anyhow::Result<Value> {
        handle_command(&self.mux, view.client, json_command(request), &view.writer)
    }

    /// A connection with this identity, attached to the terminal and
    /// claiming `size`.
    fn view(&self, info: Value, size: (u16, u16)) -> View {
        let writer = test_writer();
        let client = self.mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let view = View { client, writer };
        let mut info = info;
        info["cmd"] = json!("set-client-info");
        info["capabilities"] = json!([SHARED_SIZING_CAPABILITY]);
        self.run(&view, info).unwrap();
        attach_test_view(&self.mux, client, self.surface.id, &view.writer);
        self.claim(&view, size);
        view
    }

    fn mac(&self, size: (u16, u16)) -> View {
        self.view(json!({"kind":"frontend","device_kind":"mac","device_name":"Studio"}), size)
    }

    /// A phone as cmux-mobile-host forwards it: `remote` and the link's id.
    fn phone(&self, id: &str, size: (u16, u16)) -> View {
        self.view(
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

    fn set_policy(&self, view: &View, policy: Value) -> Value {
        self.run(view, json!({"cmd":"set-host-size-policy","policy":policy})).unwrap()
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
    rig.run(
        &mac,
        json!({"cmd":"set-size-counts","surface":rig.surface.id,"counts":false}),
    )
    .unwrap();
    assert_ne!(rig.grid(), (120, 40));
    rig.run(&mac, json!({"cmd":"set-size-counts","surface":rig.surface.id,"counts":null}))
        .unwrap();
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
    assert_eq!(read["policy"]["order"], json!(["device:p2","mac","device:p1"]));
    assert!(
        rig.run(&mac, json!({"cmd":"set-host-size-policy","policy":{"mode":"priority","order":["nope"]}}))
            .is_err()
    );
    assert!(rig.run(&mac, json!({"cmd":"set-host-size-policy","policy":{"mode":"tallest"}})).is_err());
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
    let file: Value =
        serde_json::from_str(&std::fs::read_to_string(&rig.config).unwrap()).unwrap();
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
    rig.run(&mac, json!({"cmd":"set-size-policy","surface":rig.surface.id,"policy":null}))
        .unwrap();
    assert_eq!(rig.grid(), (120, 40));
}

#[test]
fn host_policy_capability_is_identified() {
    assert!(advertised_capabilities(false).contains(&"host-size-policy-v1"));
}
