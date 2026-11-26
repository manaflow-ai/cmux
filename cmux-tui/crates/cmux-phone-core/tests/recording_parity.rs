//! Parity with the Swift tests in Packages/macOS/CmuxNext/Tests/CmuxNextPhoneTests
//! (PhoneRecorderTests, PhoneFeedbackClipTests, PhoneServiceTests), and the
//! rules of CmuxNextPhoneAccess.CloudHostReplicaFollower, asked through the
//! JSON door the app uses.
use serde_json::{Value, json};

fn ask(request: Value) -> Value {
    let reply = cmux_phone_core::respond(request.to_string().as_bytes()).expect("request decodes");
    serde_json::from_slice(&reply).expect("reply is JSON")
}

fn fixture(name: &str) -> String {
    std::fs::read_to_string(format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR")))
        .unwrap()
}

const MS: i64 = 1_000_000;

fn device(id: &str, model: &str) -> Value {
    json!({"id": id, "name": "iPhone 18 Pro", "model": model, "os_version": "iOS 27.0",
           "state": {"kind": "ready"}})
}

fn caps(mode: &str) -> u64 {
    ask(json!({"op": "capabilities", "mode": mode}))["bits"].as_u64().unwrap()
}

#[test]
fn a_recording_keeps_video_log_timed_inputs_notes_and_poster() {
    let phone = device("sim:SIM-1", "iPhone 18 Pro");
    let plan = ask(json!({"op": "recorder_start", "id": "sim:SIM-1", "capabilities": caps("sim")}));
    assert_eq!(plan, json!({"video": "screen.mov", "log": "device-log.ndjson"}));
    let mut recorder = ask(json!({"op": "recorder_begin", "id": "rec-1", "device": phone,
        "started_at": "2027-01-15T08:00:00Z", "video": plan["video"], "log": plan["log"],
        "uptime_nanos": 0}))["recorder"]
        .clone();
    let mut note = |input: Value, on: &str, at: i64| {
        let reply = ask(json!({"op": "recorder_note", "recorder": recorder, "input": input,
            "device_id": on, "uptime_nanos": at}));
        recorder = reply["recorder"].clone();
        reply["noted"].as_bool().unwrap()
    };
    assert!(note(json!({"kind": "tap", "x": 100.0, "y": 200.0}), "sim:SIM-1", 1500 * MS));
    assert!(!note(json!({"kind": "tap", "x": 1.0, "y": 1.0}), "sim:OTHER", 1500 * MS));
    assert!(note(json!({"kind": "text", "text": "hi"}), "sim:SIM-1", 3750 * MS));

    let stopped = ask(json!({"op": "recorder_stop", "recorder": recorder,
        "notes": "Send button does nothing", "uptime_nanos": 4750 * MS}));
    assert_eq!(stopped["poster"], "poster.png");
    let done = &stopped["recording"];
    assert_eq!(done["duration"], 4.75);
    assert_eq!(done["events"][0]["at"], 1.5);
    assert_eq!(done["events"][1]["at"], 3.75);
    assert_eq!(done["events"][0]["kind"], "tap");
    assert_eq!(done["events"][1]["kind"], "text");
    assert_eq!(done["video"], "screen.mov");
    assert_eq!(done["log"], "device-log.ndjson");

    let files = ask(json!({"op": "recording_files", "recording": done, "poster": true}));
    assert_eq!(files["recording"]["poster"], "poster.png");
    assert_eq!(files["notes_md"], "Send button does nothing");
    let lines: Vec<&str> = files["events_jsonl"].as_str().unwrap().lines().collect();
    assert_eq!(
        lines,
        [
            r#"{"at":1.5,"kind":"tap","point":{"x":100.0,"y":200.0}}"#,
            r#"{"at":3.75,"detail":"hi","kind":"text"}"#
        ]
    );
    let manifest: Value = serde_json::from_str(files["manifest"].as_str().unwrap()).unwrap();
    assert_eq!(manifest["startedAt"], "2027-01-15T08:00:00Z");
    assert_eq!(manifest["device"]["osVersion"], "iOS 27.0");
    assert_eq!(manifest["device"]["state"], json!({"ready": {}}));
    let loaded = ask(json!({"op": "recording_read", "manifest": files["manifest"]}));
    assert_eq!(loaded["recording"], files["recording"]);
}

#[test]
fn a_manifest_written_by_swift_reads() {
    let manifest = r#"{
      "device" : {"id" : "sim:SIM-1", "model" : "iPhone 18 Pro", "name" : "iPhone 18 Pro",
                  "osVersion" : "iOS 27.0", "state" : {"unavailable" : {"reason" : "gone"}}},
      "duration" : 4.75, "events" : [{"at" : 1.5, "kind" : "open-url", "detail" : "myapp:\/\/cart"}],
      "id" : "rec-1", "notes" : "", "startedAt" : "2027-01-15T08:00:00Z", "video" : "screen.mov"
    }"#;
    let loaded = ask(json!({"op": "recording_read", "manifest": manifest}))["recording"].clone();
    assert_eq!(loaded["device"]["state"], json!({"kind": "unavailable", "reason": "gone"}));
    assert_eq!(loaded["events"][0]["detail"], "myapp://cart");
    assert_eq!(loaded["log"], Value::Null);
    let bad =
        ask(json!({"op": "recording_read", "manifest": manifest.replace("sim:SIM-1", "junk")}));
    assert_eq!(bad["error"], "unreadable");
}

#[test]
fn one_recording_at_a_time() {
    let recorder = ask(json!({"op": "recorder_begin", "id": "r", "device": device("sim:S", "m"),
        "started_at": "t", "video": "screen.mov", "uptime_nanos": 0}))["recorder"]
        .clone();
    let again = ask(
        json!({"op": "recorder_start", "recorder": recorder, "id": "sim:S", "capabilities": 0}),
    );
    assert_eq!(again, json!({"error": "already_recording"}));
    let none = ask(json!({"op": "recorder_stop", "recorder": null, "uptime_nanos": 0}));
    assert_eq!(none, json!({"error": "not_recording"}));
}

#[test]
fn real_devices_record_mp4_without_a_log_stream() {
    let plan = ask(json!({"op": "recorder_start", "id": "dev:DEV-1", "capabilities": caps("dev")}));
    assert_eq!(plan, json!({"video": "screen.mp4", "log": null}));
    let android =
        ask(json!({"op": "capabilities", "mode": "avd", "android": true}))["bits"].clone();
    let plan = ask(json!({"op": "recorder_start", "id": "avd:Pixel", "capabilities": android}));
    assert_eq!(plan, json!({"video": "screen.mp4", "log": "device-log.ndjson"}));
}

#[test]
fn recording_ids_sort_by_time() {
    let reply = ask(json!({"op": "recording_id", "time": [2026, 10, 19, 17, 42, 3],
        "uuid": "1A2B3C4D-0000-0000-0000-000000000000"}));
    assert_eq!(reply["id"], "20261019-174203-1a2b");
}

fn event(input: Value) -> Value {
    ask(json!({"op": "recording_event", "at": 0.0, "input": input}))["event"].clone()
}

#[test]
fn clipboard_text_is_not_written_into_the_event_log() {
    assert_eq!(event(json!({"kind": "pasteboard"})), json!({"at": 0.0, "kind": "pasteboard"}));
}

#[test]
fn every_input_names_its_detail() {
    let detail = |input: Value| event(input)["detail"].clone();
    assert_eq!(detail(json!({"kind": "button", "button": "volumeUp"})), "volume-up");
    assert_eq!(detail(json!({"kind": "appearance", "dark": true})), "dark");
    assert_eq!(
        detail(json!({"kind": "location", "latitude": 37.0, "longitude": -122.25})),
        "37.0,-122.25"
    );
    assert_eq!(detail(json!({"kind": "install", "path": "/tmp/build/Shop.app/"})), "Shop.app");
    assert_eq!(detail(json!({"kind": "launch", "package": "com.shop"})), "com.shop");
    assert_eq!(detail(json!({"kind": "software_keyboard"})), Value::Null);
    let swipe = event(
        json!({"kind": "swipe", "from_x": 1.0, "from_y": 2.0, "to_x": 3.0, "to_y": 4.0, "seconds": 0.3}),
    );
    assert_eq!(swipe["point"], json!({"x": 1.0, "y": 2.0}));
    assert_eq!(swipe["to"], json!({"x": 3.0, "y": 4.0}));
    assert_eq!(swipe["kind"], "swipe");
}

fn feedback_recording() -> Value {
    json!({"id": "rec-1", "started_at": "1970-01-01T00:00:00Z", "duration": 42.31,
        "device": {"id": "sim:SIM-1", "name": "Test Phone", "model": "iPhone 18 Pro",
                   "os_version": "iOS 27.0", "state": {"kind": "ready"}},
        "video": "screen.mov", "log": "device-log.ndjson", "poster": "poster.png",
        "notes": "Checkout spinner never stops.",
        "events": [event_at(1.5, json!({"kind": "tap", "x": 100.4, "y": 200.0})),
                   event_at(3.0, json!({"kind": "swipe", "from_x": 10.0, "from_y": 500.0,
                                        "to_x": 10.0, "to_y": 100.0, "seconds": 0.3})),
                   event_at(61.06, json!({"kind": "text", "text": "coupon"}))]})
}

fn event_at(at: f64, input: Value) -> Value {
    ask(json!({"op": "recording_event", "at": at, "input": input}))["event"].clone()
}

#[test]
fn the_summary_names_device_length_notes_steps_and_log_errors() {
    let log = [
        r#"Filtering the log data using """#,
        r#"{"messageType":"Default","eventMessage":"fine","processImagePath":"/usr/libexec/x"}"#,
        r#"{"messageType":"Error","eventMessage":"payment request timed out","processImagePath":"/Applications/Shop.app/Shop"}"#,
        r#"{"messageType":"Fault","eventMessage":"layout loop","processImagePath":"/System/UIKitCore"}"#,
    ]
    .join("\n");
    let clip = ask(json!({"op": "feedback_clip", "recording": feedback_recording(),
        "log_ndjson": log, "folder_url": "file:///tmp/rec-1"}));
    let text = clip["markdown"].as_str().unwrap();
    assert!(text.contains("Test Phone (iPhone 18 Pro, iOS 27.0) · 0:42.3 · 3 inputs, 1 taps"));
    assert!(text.contains("Checkout spinner never stops."));
    assert!(text.contains("- 0:01.5 tap (100, 200)"));
    assert!(text.contains("- 0:03.0 swipe (10, 500) → (10, 100)"));
    assert!(text.contains("- 1:01.1 text `coupon`"));
    assert!(text.contains("[error] Shop: payment request timed out"));
    assert!(text.contains("[fault] UIKitCore: layout loop"));
    assert!(!text.contains("fine"));
    assert_eq!(clip["attachments"], json!(["screen.mov", "poster.png"]));
    assert_eq!(
        text,
        "**Phone feedback**: Test Phone (iPhone 18 Pro, iOS 27.0) · 0:42.3 · 3 inputs, 1 taps\n\n\
         Checkout spinner never stops.\n\nSteps:\n- 0:01.5 tap (100, 200)\n\
         - 0:03.0 swipe (10, 500) → (10, 100)\n- 1:01.1 text `coupon`\n\nLog errors:\n```\n\
         [error] Shop: payment request timed out\n[fault] UIKitCore: layout loop\n```\n\n\
         Recording folder: [rec-1](file:///tmp/rec-1)"
    );
}

#[test]
fn the_summary_takes_localized_strings_and_caps_the_steps() {
    let mut recording = feedback_recording();
    let tap = event_at(1.0, json!({"kind": "tap", "x": 1.0, "y": 1.0}));
    recording["events"] = json!(vec![tap; 31]);
    recording["poster"] = Value::Null;
    recording["notes"] = json!("  \n");
    let clip = ask(json!({"op": "feedback_clip", "recording": recording, "folder_url": "f",
        "strings": {"title": "Retour", "inputs": "%2$lld appuis sur %1$lld", "steps": "Étapes :",
                    "log_errors": "x", "folder": "Dossier :"}}));
    let text = clip["markdown"].as_str().unwrap();
    assert!(text.starts_with(
        "**Retour**: Test Phone (iPhone 18 Pro, iOS 27.0) · 0:42.3 · 31 appuis sur 31\n\nÉtapes :\n"
    ));
    assert_eq!(text.matches("- 0:01.0 tap (1, 1)").count(), 30);
    assert!(text.ends_with("- …\n\nDossier : [rec-1](f)"));
    assert_eq!(clip["attachments"], json!(["screen.mov"]));
}

#[test]
fn the_log_tail_keeps_only_the_newest_errors() {
    let lines: Vec<String> = (1..=20)
        .map(|n| {
            format!(r#"{{"messageType":"Error","eventMessage":"e{n}","processImagePath":"/p"}}"#)
        })
        .collect();
    let clip = ask(json!({"op": "feedback_clip", "recording": feedback_recording(),
        "log_ndjson": lines.join("\n"), "log_limit": 3, "folder_url": "f"}));
    let text = clip["markdown"].as_str().unwrap();
    assert!(text.contains("[error] p: e18\n[error] p: e19\n[error] p: e20\n```"));
    assert!(!text.contains("e17"));
}

fn simulators() -> Value {
    ask(json!({"op": "simctl_devices", "output": fixture("simctl-list.json")}))["devices"].clone()
}

#[test]
fn the_default_phone_is_the_ready_simulator() {
    let reply = ask(json!({"op": "default_device", "devices": simulators()}));
    assert_eq!(reply["device"]["name"], "iPhone 18 Pro");
    let recorded = device("dev:X", "iPhone 16 Pro");
    let reply =
        ask(json!({"op": "default_device", "devices": simulators(), "recording": recorded}));
    assert_eq!(reply["device"]["id"], "dev:X");
    let booting = json!([{"id": "adb:1", "name": "a", "model": "a", "os_version": "", "state": {"kind": "shutdown"}},
                         {"id": "sim:2", "name": "b", "model": "b", "os_version": "", "state": {"kind": "booting"}}]);
    assert_eq!(ask(json!({"op": "default_device", "devices": booting}))["device"]["id"], "sim:2");
    assert_eq!(
        ask(json!({"op": "default_device", "devices": []})),
        json!({"error": "unknown_device", "id": "(none)"})
    );
}

#[test]
fn input_the_device_cannot_take_fails_before_any_command_runs() {
    let reply = ask(json!({"op": "input_check", "id": "dev:00008140-0000000000000001",
        "capabilities": caps("dev"), "input": {"kind": "open_url", "url": "https://cmux.com"}}));
    assert_eq!(reply["allowed"], false);
    assert_eq!(reply["error"], "unsupported");
    assert_eq!(reply["mode"], "dev");
    assert_eq!(reply["what"], "open-url");
    let ok = ask(json!({"op": "input_check", "id": "sim:S", "capabilities": caps("sim"),
        "input": {"kind": "open_url", "url": "myapp://cart"}}));
    assert_eq!(ok, json!({"kind": "open-url", "needs": 16, "allowed": true}));
    // Touches need SimulatorKit's HID.
    let touch = json!({"kind": "tap", "x": 1.0, "y": 1.0});
    assert_eq!(
        ask(
            json!({"op": "input_check", "id": "sim:S", "capabilities": caps("sim"), "input": touch})
        )["allowed"],
        false
    );
    let live =
        ask(json!({"op": "capabilities", "mode": "sim", "live_input": true}))["bits"].clone();
    assert_eq!(
        ask(json!({"op": "input_check", "id": "sim:S", "capabilities": live, "input": touch}))["allowed"],
        true
    );
}

#[test]
fn capabilities_follow_the_backend_tables() {
    let names = |request: Value| ask(request)["names"].clone();
    assert_eq!(
        names(json!({"op": "capabilities", "mode": "sim"})),
        json!([
            "boot",
            "screenshot",
            "record",
            "log",
            "open-url",
            "pasteboard",
            "appearance",
            "location",
            "locale",
            "apps"
        ])
    );
    assert_eq!(
        names(json!({"op": "capabilities", "mode": "dev"})),
        json!(["screenshot", "record"])
    );
    assert_eq!(names(json!({"op": "capabilities", "mode": "vm"})), json!([]));
    assert_eq!(names(json!({"op": "capabilities", "mode": "adb"})), json!([]));
    assert_eq!(
        names(json!({"op": "capabilities", "mode": "adb", "android": true})),
        json!([
            "screenshot",
            "record",
            "log",
            "open-url",
            "touch",
            "keyboard",
            "live",
            "buttons",
            "appearance",
            "apps",
            "ui"
        ])
    );
    assert_eq!(
        names(json!({"op": "capabilities", "mode": "avd", "android": true})),
        json!([
            "boot",
            "screenshot",
            "record",
            "log",
            "open-url",
            "touch",
            "keyboard",
            "live",
            "buttons",
            "appearance",
            "location",
            "locale",
            "apps",
            "rotate",
            "ui"
        ])
    );
}

#[test]
fn small_moves_on_the_still_frame_are_taps() {
    let input = |from: [f64; 2], to: [f64; 2], seconds: f64| {
        ask(json!({"op": "touch_input", "screen": [400.0, 800.0], "from": from, "to": to,
            "seconds": seconds}))["input"]
            .clone()
    };
    assert_eq!(
        input([0.5, 0.5], [0.51, 0.51], 0.0),
        json!({"kind": "tap", "x": 200.0, "y": 400.0})
    );
    assert_eq!(
        input([0.5, 0.5], [0.5, 0.1], 0.02),
        json!({"kind": "swipe", "from_x": 200.0, "from_y": 400.0, "to_x": 200.0, "to_y": 80.0, "seconds": 0.1})
    );
}

#[test]
fn frames_are_one_file_per_device_and_log_lines_are_quoted() {
    let reply = ask(json!({"op": "frame_file", "id": "sim:6A05764C-FFD1-4B40-AA2E-AD27ADAC7A56"}));
    assert_eq!(reply["file"], "frame-sim-6A05764C-FFD1-4B40-AA2E-AD27ADAC7A56.png");
    let reply = ask(json!({"op": "shell_line", "argv": ["xcrun", "simctl", "spawn", "it's"]}));
    assert_eq!(reply["line"], r"'xcrun' 'simctl' 'spawn' 'it'\''s'");
}

// CloudHostReplicaFollower (no Swift tests; its doc comments are the spec).

fn apply(
    connected: bool,
    user: Option<&str>,
    on: bool,
    renew: bool,
    published: Option<&str>,
) -> Value {
    ask(json!({"op": "replica_apply", "want": {"connected": connected, "user_id": user, "on": on},
        "renew": renew, "published_user": published}))
}

#[test]
fn the_follower_leases_while_on_and_clears_when_signed_out() {
    assert_eq!(apply(false, Some("u"), true, false, None), json!({"action": "none"}));
    assert_eq!(apply(true, None, true, false, Some("u")), json!({"action": "clear"}));
    assert_eq!(
        apply(true, Some("u"), true, false, None),
        json!({"action": "lease", "invalidate": false})
    );
    assert_eq!(
        apply(true, Some("u"), true, true, None),
        json!({"action": "lease", "invalidate": true})
    );
    // Off: purge only this account's copy.
    assert_eq!(apply(true, Some("u"), false, false, Some("u")), json!({"action": "status"}));
    assert_eq!(apply(true, Some("u"), false, false, Some("v")), json!({"action": "clear"}));
    assert_eq!(apply(true, Some("u"), false, false, None), json!({"action": "clear"}));
}

fn purge(
    renew: bool,
    daemon: Option<i64>,
    asked: Option<i64>,
    state: &str,
    pending: Option<bool>,
) -> Value {
    ask(json!({"op": "replica_purge", "renew": renew, "daemon": daemon, "purge_asked": asked,
        "status": {"state": state, "purge_pending": pending}}))
}

#[test]
fn the_follower_forgets_once_the_asked_daemon_purged() {
    assert_eq!(purge(false, Some(42), Some(42), "off", None), json!({"action": "forget"}));
    assert_eq!(purge(false, Some(42), Some(42), "off", Some(false)), json!({"action": "forget"}));
    let again = |invalidate: bool| json!({"action": "lease_then_purge", "invalidate": invalidate, "mark_purge_asked": 42});
    assert_eq!(purge(false, Some(42), Some(42), "off", Some(true)), again(false));
    assert_eq!(purge(false, Some(42), Some(41), "off", None), again(false));
    assert_eq!(purge(false, Some(42), Some(42), "leased", None), again(false));
    assert_eq!(purge(true, Some(42), Some(42), "off", None), again(true));
    assert_eq!(
        purge(false, None, None, "off", None),
        json!({"action": "lease_then_purge", "invalidate": false, "mark_purge_asked": null})
    );
}

#[test]
fn the_lease_names_this_mac_in_at_most_64_scalars() {
    let lease = |origin: Value, name: &str| {
        ask(json!({"op": "replica_lease", "origin": origin, "token": "t", "expires_at": 9,
            "client_version": "1.2", "computer_name": name}))["lease"]
            .clone()
    };
    assert_eq!(lease(Value::Null, "Studio Mac"), Value::Null);
    assert_eq!(
        lease(json!("https://cmux.com"), " \n Studio Mac\n"),
        json!({"api_base_url": "https://cmux.com", "install_token": "t", "expires_at": 9,
               "client_version": "1.2", "host_name": "Studio Mac"})
    );
    assert_eq!(lease(json!("https://cmux.com"), "  ")["host_name"], "Mac");
    let long = "é".repeat(70);
    assert_eq!(
        lease(json!("https://cmux.com"), &long)["host_name"].as_str().unwrap().chars().count(),
        64
    );
    let keys = ask(json!({"op": "replica_keys"}));
    assert_eq!(keys["published_key"], "cmux.cloudReplica.publishedUser.v1");
    assert_eq!(keys["purge_asked_key"], "cmux.cloudReplica.purgeAskedDaemon.v1");
}
