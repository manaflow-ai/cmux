//! `settings.*` over the control socket (`settings-v1`,
//! plans/cmux-next/settings-react.md section 3): every op, the refusal
//! codes, the app-only check, and `settings-changed`.

use super::*;
use crate::mux::settings::{SETTINGS_HOST_CAPABILITY, SettingsPaths};

struct Fixture {
    mux: Arc<Mux>,
    directory: tempfile::TempDir,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Fixture {
    fn new(file: &str, forced: &[(&str, Value)]) -> Fixture {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("cmux.json");
        std::fs::write(&config, file).unwrap();
        let managed = cmux_config::ManagedPreferences {
            forced: forced.iter().map(|(k, v)| ((*k).to_owned(), v.clone())).collect(),
            ..Default::default()
        };
        let mux = Mux::new_for_test("settings", crate::SurfaceOptions::default());
        assert!(mux.start_settings_owner(SettingsPaths {
            config,
            state_dir: Some(directory.path().join("state")),
            reader: Box::new(cmux_config::managed::FixedManagedReader(managed)),
            watch: false,
        }));
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Fixture { mux, directory, scheduler }
    }

    fn client(&self, transport: ClientTransport) -> (u64, MessageWriter, Arc<BoundedOutbound>) {
        let (writer, outbound) = tests::captured_writer();
        let client = self.mux.control_clients.register(transport, writer.clone());
        (client, writer, outbound)
    }

    fn send(&self, client: &(u64, MessageWriter, Arc<BoundedOutbound>), line: &str) -> Value {
        assert!(handle_connection_message(&self.mux, client.0, line, &client.1, &self.scheduler));
        let message = client.2.try_pop().expect("a response");
        serde_json::from_str(&message).unwrap()
    }

    fn call(&self, operation: &str, fields: Value, key: Option<&str>) -> Value {
        let client = self.client(ClientTransport::Unix);
        self.send(&client, &request(operation, fields, key))
    }

    fn file(&self) -> Value {
        let text = std::fs::read_to_string(self.directory.path().join("cmux.json")).unwrap();
        cmux_config::jsonc::parse(&text).unwrap()
    }
}

fn request(operation: &str, fields: Value, key: Option<&str>) -> String {
    let mut params = json!({"machine": "current", "session": "current"});
    for (name, value) in fields.as_object().unwrap() {
        params[name] = value.clone();
    }
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "settings-1",
        "operation": operation, "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    request.to_string()
}

fn settings_events(events: &crate::event_bus::MuxEventReceiver) -> Vec<Value> {
    std::iter::from_fn(|| events.try_recv().ok())
        .map(|event| subscribed_event_json(&event))
        .filter(|event| event["event"] == "settings-changed")
        .collect()
}

/// What the hosting app sends on connect (`settings-host-v1`).
fn declare_host(fixture: &Fixture, client: &(u64, MessageWriter, Arc<BoundedOutbound>)) {
    let request: Request = serde_json::from_value(json!({
        "id": 2, "cmd": "set-client-info", "kind": "frontend",
        "capabilities": [SETTINGS_HOST_CAPABILITY],
    }))
    .unwrap();
    handle_command(&fixture.mux, client.0, request.cmd, &client.1).unwrap();
}

fn error_code(response: &Value) -> &str {
    assert_eq!(response["ok"], false, "{response}");
    response["error"]["code"].as_str().unwrap()
}

#[test]
fn identify_advertises_settings_and_the_schema_hash() {
    let fixture = Fixture::new("{}", &[]);
    let identity =
        handle_command(&fixture.mux, 0, Command::Identify, &tests::captured_writer().0).unwrap();
    assert!(identity["capabilities"].as_array().unwrap().iter().any(|c| c == "settings-v1"));
    assert_eq!(identity["settings_schema_hash"], cmux_config::Schema::embedded().schema_hash);
}

#[test]
fn every_read_answers_from_the_owner() {
    let fixture = Fixture::new(r#"{"ui": {"animationSpeed": "off"}}"#, &[]);
    let schema = fixture.call("settings.schema", json!({}), None);
    assert_eq!(schema["ok"], true, "{schema}");
    let rows = schema["result"]["rows"].as_array().unwrap();
    assert_eq!(rows.len(), cmux_config::Schema::embedded().rows.len());
    assert!(rows.iter().all(|row| row.get("accepts").is_none()));
    let list = fixture.call("settings.list", json!({"section": "general"}), None);
    assert!(list["result"].as_array().unwrap().iter().all(|row| row["section"] == "general"));
    let get = fixture.call("settings.get", json!({"key": "ui.animationSpeed"}), None);
    assert_eq!(get["result"]["value"], "off");
    assert_eq!(get["result"]["row"]["customized"], true);
    let by_path = fixture.call("settings.get", json!({"path": ["ui", "animationSpeed"]}), None);
    assert_eq!(by_path["result"]["key"], "ui.animationSpeed");
    let snapshot = fixture.call("settings.snapshot", json!({}), None);
    assert_eq!(snapshot["result"]["revision"], 0);
    assert_eq!(snapshot["result"]["effective"]["ui"]["animationSpeed"], "off");
    let both = fixture.call("settings.get", json!({"key": "a", "path": ["a"]}), None);
    assert_eq!(error_code(&both), "validation.invalid");
}

#[test]
fn writes_return_a_mutation_result_and_emit_settings_changed() {
    let fixture = Fixture::new("{\n  // mine\n}\n", &[]);
    let events = fixture.mux.subscribe();
    let set = fixture.call(
        "settings.set",
        json!({"key": "ui.animationSpeed", "value": "off"}),
        Some("k1"),
    );
    assert_eq!(set["ok"], true, "{set}");
    assert_eq!(set["result"]["value"], json!({"keys": ["ui.animationSpeed"]}));
    assert_eq!(set["result"]["revision"], "1");
    assert_eq!(set["result"]["replayed"], false);
    assert_eq!(fixture.file()["ui"]["animationSpeed"], "off");
    let replay = fixture.call(
        "settings.set",
        json!({"key": "ui.animationSpeed", "value": "off"}),
        Some("k1"),
    );
    assert_eq!(replay["result"]["replayed"], true);
    let reset = fixture.call("settings.reset", json!({"key": "ui.animationSpeed"}), Some("k2"));
    assert_eq!(reset["result"]["revision"], "2");
    assert!(fixture.file().get("ui").is_none());
    let all = fixture.call("settings.reset_all", json!({}), Some("k3"));
    assert_eq!(all["result"]["value"]["keys"], json!([]));
    assert_eq!(
        settings_events(&events),
        vec![
            json!({"event":"settings-changed","revision":1,"keys":["ui.animationSpeed"],"origin":"cli"}),
            json!({"event":"settings-changed","revision":2,"keys":["ui.animationSpeed"],"origin":"cli"}),
        ]
    );
    let text = std::fs::read_to_string(fixture.directory.path().join("cmux.json")).unwrap();
    assert!(text.contains("// mine"));
    assert!(fixture.directory.path().join("state/settings/effective.json").exists());
}

#[test]
fn refusals_carry_the_catalog_codes_and_the_owner_data() {
    let fixture = Fixture::new("{}", &[("appearance.density", json!("compact"))]);
    let invalid = fixture.call(
        "settings.set",
        json!({"key": "ui.animationSpeed", "value": "warp"}),
        Some("a"),
    );
    assert_eq!(error_code(&invalid), "settings.invalid");
    assert_eq!(invalid["error"]["details"]["kind"], "choice");
    assert_eq!(
        invalid["error"]["details"]["accepted"]["choices"],
        json!(["fast", "normal", "off"])
    );
    let managed = fixture.call(
        "settings.set",
        json!({"key": "appearance.density", "value": "comfortable"}),
        Some("b"),
    );
    assert_eq!(error_code(&managed), "settings.managed");
    assert_eq!(managed["error"]["details"]["source"], "mdm");
    let reset_managed =
        fixture.call("settings.reset", json!({"key": "appearance.density"}), Some("c"));
    assert_eq!(error_code(&reset_managed), "settings.managed");
    let agent = fixture.call(
        "settings.set",
        json!({"key": "feed.mirrorNotifications.terminal", "value": true, "origin": "mcp"}),
        Some("d"),
    );
    assert_eq!(error_code(&agent), "settings.agent_refused");
    assert_eq!(agent["error"]["details"]["reason"], "privacy");
    let removed = fixture.call(
        "settings.set",
        json!({"key": "appearance.tabBarBackground", "value": "darker"}),
        Some("e"),
    );
    assert_eq!(error_code(&removed), "settings.removed");
    let stale = fixture.call(
        "settings.set",
        json!({"key": "ui.animationSpeed", "value": "off", "if_revision": "9"}),
        Some("f"),
    );
    assert_eq!(error_code(&stale), "revision.conflict");
    assert_eq!(stale["error"]["details"], json!({"expected": "9", "actual": "0"}));
    fixture.call("settings.set", json!({"key": "ui.animationSpeed", "value": "off"}), Some("g"));
    let reused = fixture.call(
        "settings.set",
        json!({"key": "ui.animationSpeed", "value": "fast"}),
        Some("g"),
    );
    assert_eq!(error_code(&reused), "idempotency.conflict");
    assert_eq!(reused["error"]["details"]["committed_operation"], "settings.set");
}

#[test]
fn only_the_hosting_app_publishes_domains_and_the_team_policy() {
    let fixture = Fixture::new("{}", &[]);
    let publish = request(
        "settings.domains.publish",
        json!({"themes": ["Nord"], "font_families": [], "sounds": []}),
        Some("p1"),
    );
    let team = request(
        "settings.team_policy.set",
        json!({"layer": {"team_id": "team_1", "team_name": "Acme", "version": 1,
                         "enforced": {"ui.animationSpeed": "off"}}}),
        Some("t1"),
    );
    let cli = fixture.client(ClientTransport::Unix);
    for line in [&publish, &team] {
        let refused = fixture.send(&cli, line);
        assert_eq!(error_code(&refused), "operation.failed");
        assert_eq!(refused["error"]["details"]["extra"]["required_authority"], "hosting_app");
    }
    let remote = fixture.client(ClientTransport::WebSocket);
    declare_host(&fixture, &remote);
    assert_eq!(error_code(&fixture.send(&remote, &publish)), "operation.failed");

    let app = fixture.client(ClientTransport::Unix);
    declare_host(&fixture, &app);
    let published = fixture.send(&app, &publish);
    assert_eq!(published["ok"], true, "{published}");
    let theme = fixture.call(
        "settings.set",
        json!({"key": "appearance.theme", "value": "Dracula"}),
        Some("x"),
    );
    assert_eq!(error_code(&theme), "settings.invalid");
    let enforced = fixture.send(&app, &team);
    assert_eq!(enforced["ok"], true, "{enforced}");
    assert_eq!(enforced["result"]["value"]["keys"], json!(["ui.animationSpeed"]));
    let managed = fixture.call(
        "settings.set",
        json!({"key": "ui.animationSpeed", "value": "fast"}),
        Some("y"),
    );
    assert_eq!(managed["error"]["details"]["team"], "Acme");
}

#[test]
fn a_hand_edit_produces_one_settings_changed_event() {
    let fixture = Fixture::new("{}", &[]);
    let events = fixture.mux.subscribe();
    let config = fixture.directory.path().join("cmux.json");
    let temporary = fixture.directory.path().join(".cmux.json.tmp");
    std::fs::write(&temporary, r#"{"ui": {"animationSpeed": "normal"}}"#).unwrap();
    std::fs::rename(&temporary, &config).unwrap();
    // The watcher's hint runs exactly this reload.
    let change = fixture.mux.reload_settings().expect("a change");
    assert_eq!(change.keys, vec!["ui.animationSpeed".to_string()]);
    assert!(fixture.mux.reload_settings().is_none(), "a second hint changes nothing");
    assert_eq!(
        settings_events(&events),
        vec![
            json!({"event":"settings-changed","revision":1,"keys":["ui.animationSpeed"],"origin":"file"})
        ]
    );
    // A comment-only edit publishes nothing.
    std::fs::write(&temporary, "// note\n{\"ui\": {\"animationSpeed\": \"normal\"}}").unwrap();
    std::fs::rename(&temporary, &config).unwrap();
    assert!(fixture.mux.reload_settings().is_none());
    assert!(settings_events(&events).is_empty());
}
