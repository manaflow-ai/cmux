//! `energy.set` and `energy.status` on the wire: a round
//! trip through the connection's frame path, the override over the daemon's
//! own reading, one watcher call per edge and none for a repeat, who may
//! send which line, and the override's end with the connection that set it.

use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::server::energy_rule::{PowerFacts, SaverSetting};
use crate::server::{
    BoundedOutbound, ClientTransport, ConnectionSurfaceScheduler, QueuedSink, disconnect_client,
    handle_connection_message,
};

/// The control client id the unit tests set overrides as.
const APP: u64 = 7;

/// Turns the daemon's own reading on or off: `onBattery`, with the Mac on
/// battery or plugged in. Returns whether the mode changed.
fn set_reading(energy: &DaemonEnergy, saver: bool) -> bool {
    let setting_changed = energy.set_setting(SaverSetting::OnBattery);
    let facts = PowerFacts { on_battery: saver, ..PowerFacts::default() };
    energy.set_facts(facts) || setting_changed
}

struct Caller {
    id: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Caller {
    fn new(mux: &Arc<Mux>, transport: ClientTransport, app: bool) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let id = mux.control_clients.register(transport, writer.clone());
        if app {
            origin_gate::set_role_for_test(mux, id, "main");
            origin_gate::set_verified_app_for_test(mux, id, true);
        }
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { id, writer, outbound, scheduler }
    }

    /// The reply to `request`, sent through the whole frame path (route
    /// lookup included). The route answers on this thread.
    fn call(&self, mux: &Arc<Mux>, request: Value) -> Value {
        assert!(handle_connection_message(
            mux,
            self.id,
            &request.to_string(),
            &self.writer,
            &self.scheduler,
        ));
        let line = self.outbound.try_pop().expect("the route answers before it returns");
        serde_json::from_str(&line).unwrap()
    }
}

fn code(reply: &Value) -> &str {
    assert_eq!(reply["ok"], false, "{reply}");
    reply["error_code"].as_str().unwrap_or_default()
}

#[test]
fn energy_set_round_trip_flips_the_mode_and_status_reads_it() {
    let mux = Mux::new_for_test("energy-round-trip", SurfaceOptions::default());
    let app = Caller::new(&mux, ClientTransport::Unix, true);
    let edges = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&edges);
    let _watch = mux.energy.mode().watch(move || {
        counted.fetch_add(1, Ordering::SeqCst);
    });

    let status = app.call(&mux, json!({"id": 1, "cmd": STATUS}));
    assert_eq!(
        status["data"],
        json!({
            "saver": false, "source": "daemon", "reason": null, "override": null, "reading": false,
            "setting": null, "offForNow": false,
        }),
        "{status}"
    );

    let set = app.call(&mux, json!({"id": 2, "cmd": SET, "saver": true, "reason": "battery"}));
    assert_eq!(
        (set["id"].clone(), set["data"].clone()),
        (json!(2), json!({"changed": true, "saver": true}))
    );
    assert!(mux.energy.mode().is_saver());
    assert_eq!(edges.load(Ordering::SeqCst), 1);

    // The same value again is no edge: nobody is told.
    let again = app.call(&mux, json!({"id": 3, "cmd": SET, "saver": true, "reason": "battery"}));
    assert_eq!(again["data"]["changed"], false, "{again}");
    assert_eq!(edges.load(Ordering::SeqCst), 1);

    let status = app.call(&mux, json!({"id": 4, "cmd": STATUS}));
    assert_eq!(
        status["data"],
        json!({
            "saver": true, "source": "app", "reason": "battery", "override": true, "reading": false,
            "setting": null, "offForNow": false,
        }),
        "{status}"
    );

    let off = app.call(&mux, json!({"id": 5, "cmd": SET, "saver": false}));
    assert_eq!(off["data"], json!({"changed": true, "saver": false}), "{off}");
    assert!(!mux.energy.mode().is_saver());
    assert_eq!(edges.load(Ordering::SeqCst), 2);
}

#[test]
fn energy_override_wins_over_the_reading_until_cleared() {
    let energy = DaemonEnergy::default();
    assert!(set_reading(&energy, true));
    assert_eq!(energy.status().source, EnergySource::Daemon);
    assert!(energy.mode().is_saver());

    assert!(energy.set_override(APP, Some(false), None));
    assert!(!energy.status().saver);
    assert_eq!(energy.status().source, EnergySource::App);
    // The reading moves under the override without moving the mode.
    assert!(!set_reading(&energy, false));
    assert!(!set_reading(&energy, true));
    assert!(!energy.mode().is_saver());

    assert!(energy.set_override(APP, None, None));
    assert_eq!(
        energy.status(),
        EnergyStatus {
            saver: true,
            source: EnergySource::Daemon,
            reason: Some(SaverReason::Setting),
            app_override: None,
            reading: true,
            setting: Some(SaverSetting::OnBattery),
            off_for_now: false,
        }
    );
    assert!(energy.mode().is_saver());
}

#[test]
fn energy_reason_is_kept_only_while_the_override_holds_the_saver_on() {
    let energy = DaemonEnergy::default();
    for reason in SaverReason::ALL {
        energy.set_override(APP, Some(true), Some(reason));
        assert_eq!(energy.status().reason, Some(reason));
    }
    energy.set_override(APP, Some(false), None);
    assert_eq!(energy.status().reason, None);
}

#[test]
fn energy_racing_writers_leave_the_mode_on_the_last_inputs() {
    let energy = Arc::new(DaemonEnergy::default());
    let writers: Vec<_> = (0..8)
        .map(|index| {
            let energy = Arc::clone(&energy);
            std::thread::spawn(move || {
                for round in 0..2_000 {
                    if index % 2 == 0 {
                        energy.set_override(APP, Some(round % 2 == 0), Some(SaverReason::Setting));
                    } else {
                        set_reading(&energy, round % 3 == 0);
                    }
                }
            })
        })
        .collect();
    for writer in writers {
        writer.join().unwrap();
    }
    assert_eq!(energy.mode().is_saver(), energy.status().saver);
}

#[test]
fn energy_override_ends_with_the_client_that_set_it() {
    let energy = DaemonEnergy::default();
    assert!(set_reading(&energy, true));
    assert!(energy.set_override(APP, Some(false), None));
    // Another client leaving takes nothing.
    assert!(!energy.client_left(APP + 1));
    assert_eq!(energy.status().source, EnergySource::App);
    // The setter leaving hands the mode back to the reading.
    assert!(energy.client_left(APP));
    assert_eq!(energy.status().source, EnergySource::Daemon);
    assert!(energy.mode().is_saver());
    assert!(!energy.client_left(APP), "nothing left to clear");

    // A newer client's override survives an older client leaving.
    energy.set_override(APP, Some(true), Some(SaverReason::Battery));
    energy.set_override(APP + 1, Some(false), None);
    assert!(!energy.client_left(APP));
    assert_eq!(energy.status().app_override, Some(false));
    // An id wider than the setter bits is matched by its low 48 bits.
    let far = APP | (1 << 60);
    energy.set_override(far, Some(false), None);
    assert!(!energy.client_left(far + 1));
    assert_eq!(energy.status().source, EnergySource::App);
    assert!(energy.client_left(far), "the reading (on) takes over from the override (off)");
    assert_eq!(energy.status().source, EnergySource::Daemon);
}

#[test]
fn energy_app_override_is_gone_when_its_connection_closes() {
    let mux = Mux::new_for_test("energy-app-quit", SurfaceOptions::default());
    set_reading(&mux.energy, true);
    let app = Caller::new(&mux, ClientTransport::Unix, true);
    let cli = Caller::new(&mux, ClientTransport::Unix, false);
    let set = app.call(&mux, json!({"id": 1, "cmd": SET, "saver": false}));
    assert_eq!(set["data"], json!({"changed": true, "saver": false}), "{set}");
    // The app quits (or crashes, or its link drops): its connection ends.
    assert!(disconnect_client(&mux, app.id, false));
    let status = cli.call(&mux, json!({"id": 2, "cmd": STATUS}));
    assert_eq!(
        status["data"],
        json!({
            "saver": true, "source": "daemon", "reason": "setting", "override": null,
            "reading": true, "setting": "onBattery", "offForNow": false,
        }),
        "{status}"
    );
    assert!(mux.energy.mode().is_saver());
}

#[test]
fn energy_set_needs_the_verified_app_and_well_formed_fields() {
    let mux = Mux::new_for_test("energy-refusals", SurfaceOptions::default());
    let app = Caller::new(&mux, ClientTransport::Unix, true);
    let cli = Caller::new(&mux, ClientTransport::Unix, false);
    let web = Caller::new(&mux, ClientTransport::WebSocket, true);

    assert_eq!(
        code(&cli.call(&mux, json!({"id": 1, "cmd": SET, "saver": true}))),
        "energy.not_trusted"
    );
    assert_eq!(
        code(&web.call(&mux, json!({"id": 2, "cmd": SET, "saver": true}))),
        "energy.not_trusted"
    );
    assert_eq!(code(&web.call(&mux, json!({"id": 3, "cmd": STATUS}))), "energy.not_trusted");
    // A local CLI reads the status (`cmux energy status`).
    assert_eq!(cli.call(&mux, json!({"id": 4, "cmd": STATUS}))["ok"], true);

    for bad in [
        json!({"id": 5, "cmd": SET}),
        json!({"id": 6, "cmd": SET, "saver": "yes"}),
        json!({"id": 7, "cmd": SET, "saver": false, "reason": "battery"}),
        json!({"id": 8, "cmd": SET, "saver": true, "reason": "sunny"}),
        json!({"id": 9, "cmd": SET, "saver": true, "extra": 1}),
        json!({"id": 12, "cmd": SET, "saver": false, "offForNow": "yes"}),
        json!({"id": 10, "cmd": STATUS, "saver": true}),
    ] {
        assert_eq!(code(&app.call(&mux, bad.clone())), "energy.bad_request", "{bad}");
    }
    assert!(!mux.energy.mode().is_saver(), "no refused line flips the mode");

    let cleared = app.call(&mux, json!({"id": 11, "cmd": SET, "saver": null}));
    assert_eq!(cleared["data"], json!({"changed": false, "saver": false}), "{cleared}");
}

#[test]
fn energy_lines_are_routed_and_the_capability_is_advertised() {
    for cmd in COMMANDS {
        let route = crate::server::routes::find(cmd).expect("routed");
        assert_eq!(route.stage, crate::server::FrameStage::Route);
    }
    assert!(crate::server::routes::find("energy.").is_none());
    let mux = Mux::new_for_test("energy-capability", SurfaceOptions::default());
    let capabilities = crate::server::identify_capabilities(&mux);
    assert!(capabilities.contains(&CAPABILITY));
    assert!(capabilities.contains(&RULE_CAPABILITY));
}

/// The daemon relays its mode to acpmux: the app's
/// `energy.set` reaches a fake acpmux as `_acpmux/energy` on the agent chat
/// watch's connection, after the mode the watch sent as it connected.
#[cfg(unix)]
#[test]
fn energy_set_reaches_acpmux_on_the_chat_watch_connection() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;

    let dir = std::env::temp_dir().join(format!("cmx-energy-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("acpmux.sock");
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let mux = Mux::new_for_test("energy-acpmux-relay", SurfaceOptions::default());
    mux.watch_agent_chats(Some(socket));

    let (stream, _) = listener.accept().unwrap();
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
    let mut writer = stream.try_clone().unwrap();
    let mut reader = BufReader::new(stream);
    let mut next = || {
        let mut line = String::new();
        reader.read_line(&mut line).expect("a request from the daemon");
        let request: Value = serde_json::from_str(&line).unwrap();
        // acpmux answers each request; the watch reads past the energy replies.
        let result = match request["method"].as_str() {
            Some("_acpmux/watch") => json!({"sessions": []}),
            _ => json!({}),
        };
        let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
        writer.write_all(format!("{reply}\n").as_bytes()).unwrap();
        request
    };
    let opened: Vec<Value> = (0..3).map(|_| next()).collect();
    assert_eq!(opened[0]["method"], "initialize");
    assert_eq!(opened[1]["method"], "_acpmux/watch");
    assert_eq!(opened[2]["method"], "_acpmux/energy");
    assert_eq!(opened[2]["params"], json!({"saver": false}), "the mode as the watch connects");

    let app = Caller::new(&mux, ClientTransport::Unix, true);
    let set = app.call(&mux, json!({"id": 1, "cmd": SET, "saver": true, "reason": "battery"}));
    assert_eq!(set["data"], json!({"changed": true, "saver": true}), "{set}");
    let edge = next();
    assert_eq!(edge["method"], "_acpmux/energy");
    assert_eq!(edge["params"], json!({"saver": true}), "an edge");

    // The override ends with the app's connection: acpmux hears that edge too.
    assert!(disconnect_client(&mux, app.id, false));
    assert_eq!(next()["params"], json!({"saver": false}));
    let _ = std::fs::remove_dir_all(&dir);
}

/// `offForNow` (energy-v2) rides `energy.set`, outlives the app's
/// connection and holds the daemon's own reading off.
#[test]
fn energy_set_carries_turn_off_for_now_past_the_apps_connection() {
    let mux = Mux::new_for_test("energy-off-for-now", SurfaceOptions::default());
    set_reading(&mux.energy, true);
    let app = Caller::new(&mux, ClientTransport::Unix, true);
    let set = app.call(&mux, json!({"id": 1, "cmd": SET, "saver": false, "offForNow": true}));
    assert_eq!(set["data"], json!({"changed": true, "saver": false}), "{set}");
    assert!(disconnect_client(&mux, app.id, false));
    let status = mux.energy.status();
    assert!(status.off_for_now && !status.saver && !status.reading, "{status:?}");
    assert_eq!(status.source, EnergySource::Daemon);
    // A v1 line (no offForNow) leaves the hold as it is.
    let again = Caller::new(&mux, ClientTransport::Unix, true);
    again.call(&mux, json!({"id": 2, "cmd": SET, "saver": null}));
    assert!(mux.energy.status().off_for_now);
    let ended = again.call(&mux, json!({"id": 3, "cmd": SET, "saver": null, "offForNow": false}));
    assert_eq!(ended["data"], json!({"changed": true, "saver": true}), "{ended}");
}

#[test]
fn energy_inputs_survive_a_pack_round_trip() {
    let facts = [
        None,
        Some(PowerFacts::default()),
        Some(PowerFacts { on_battery: true, low_battery: true, low_power_mode: true, hot: true }),
        Some(PowerFacts { on_battery: true, hot: true, ..PowerFacts::default() }),
    ];
    let overrides = [
        (None, None),
        (Some(false), None),
        (Some(true), None),
        (Some(true), Some(SaverReason::Thermal)),
    ];
    let settings = [None, Some(SaverSetting::Auto), Some(SaverSetting::Off)];
    for facts in facts {
        for (app_override, reason) in overrides {
            for setting in settings {
                for off_for_now in [false, true] {
                    let inputs = Inputs { app_override, reason, setting, off_for_now, facts };
                    let packed = inputs.pack();
                    assert_eq!(packed & !INPUTS, 0, "{inputs:?} spills into the setter bits");
                    assert_eq!(Inputs::unpack(packed | setter(APP)), inputs);
                }
            }
        }
    }
}

/// The daemon reads `energy.saver` from its settings owner at the first read
/// and on each later change, as the app does.
#[test]
fn energy_setting_follows_the_settings_file() {
    let dir = cmux_unix_socket::short_test_dir("energy-setting");
    let config = dir.path().join("cmux-next.json");
    std::fs::write(&config, r#"{"energy": {"saver": "off"}}"#).unwrap();
    let mux = Mux::new_for_test("energy-setting", SurfaceOptions::default());
    assert!(mux.start_settings_owner(crate::mux::settings::SettingsPaths {
        config,
        seed: None,
        state_dir: Some(dir.path().to_path_buf()),
        reader: Box::new(cmux_config::managed::FixedManagedReader::default()),
        watch: false,
    }));
    assert_eq!(mux.energy.status().setting, Some(SaverSetting::Off));
    mux.energy.set_facts(PowerFacts {
        on_battery: true,
        low_battery: true,
        ..PowerFacts::default()
    });
    assert!(!mux.energy.mode().is_saver(), "off never turns on, even on a low battery");

    let meta = || cmux_config::WriteMeta {
        origin: cmux_config::Origin::App,
        idempotency_key: None,
        if_revision: None,
    };
    let target = || cmux_config::Target::Key(energy_rule::SETTING_KEY.into());
    let set = cmux_config::Op::Set { target: target(), value: json!("always"), meta: meta() };
    mux.settings_apply(set).unwrap();
    assert_eq!(mux.energy.status().setting, Some(SaverSetting::Always));
    assert!(mux.energy.mode().is_saver());
    mux.settings_apply(cmux_config::Op::Reset { target: target(), meta: meta() }).unwrap();
    assert_eq!(mux.energy.status().setting, Some(SaverSetting::Auto), "missing is auto");
    assert_eq!(mux.energy.status().reason, Some(SaverReason::Battery));
}
