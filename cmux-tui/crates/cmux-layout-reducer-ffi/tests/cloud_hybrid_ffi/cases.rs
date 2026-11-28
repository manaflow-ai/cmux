//! `cloud_hybrid_*` through the C ABI: the app sends the start's state, one event and its clock,
//! and runs the effects the answer lists (cmux-cloud-start-core `hybrid` holds the rules).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

fn step(state: &Value, event: Value, now: u64) -> Value {
    let (code, reply) =
        call(c"cloud_hybrid_step", &json!({"state": state, "event": event, "now": now}));
    assert_eq!(code, OK);
    reply
}

#[test]
fn a_pro_account_gets_it_and_another_plan_hears_why_not() {
    let pro = json!({"plan": "next_pro", "signedIn": true});
    assert_eq!(call(c"cloud_hybrid_enabled", &pro), (OK, json!({"enabled": true})));
    let plus = json!({"plan": "next_plus", "signedIn": true});
    assert_eq!(
        call(c"cloud_hybrid_enabled", &plus),
        (OK, json!({"enabled": false, "off": "plan"}))
    );
    let flagged = json!({"plan": "next_pro", "signedIn": true, "flag": false});
    assert_eq!(call(c"cloud_hybrid_enabled", &flagged).1["off"], "flag");
    assert_eq!(call(c"cloud_hybrid_enabled", &json!({"plan": "next_pro"})).1["off"], "no-cloud");
}

#[test]
fn the_apps_cloud_send_runs_its_first_turn_here_on_a_plain_folder() {
    let send = json!({
        "account": {"plan": "next_pro", "signedIn": true},
        "folder": true,
        "catalog": {"defaultHarness": "claude", "harnesses": {"claude": {}}},
    });
    assert_eq!(
        call(c"cloud_hybrid_gui_start", &send),
        (OK, json!({"here": true, "probe": "cloud hybrid gui start: here"}))
    );
    let mut repo = send.clone();
    repo["repository"] = json!(true);
    assert_eq!(
        call(c"cloud_hybrid_gui_start", &repo),
        (
            OK,
            json!({"here": false, "off": "repository",
                    "probe": "cloud hybrid gui start: off repository"})
        )
    );
    let mut bare = send.clone();
    bare["catalog"] = Value::Null;
    assert_eq!(call(c"cloud_hybrid_gui_start", &bare).1["off"], "no-local-harness");
    let mut killed = send;
    killed["killed"] = json!(true);
    assert_eq!(call(c"cloud_hybrid_gui_start", &killed).1["off"], "kill-switch");
}

#[test]
fn a_call_key_is_the_gateways_header_and_a_stable_hash() {
    let ask = json!({"chatId": "c", "turnId": "t", "callSeq": 0});
    let (code, reply) = call(c"cloud_hybrid_call_key", &ask);
    assert_eq!(code, OK);
    assert_eq!(reply["header"], "x-cmux-call-key");
    assert_eq!(reply["key"].as_str().map(str::len), Some(64));
    assert_eq!(call(c"cloud_hybrid_call_key", &ask).1, reply);
}

#[test]
fn a_start_answers_here_at_once_and_goes_on_on_its_machine() {
    let begun = step(&Value::Null, json!({"on": "begin"}), 0);
    assert_eq!(
        begun["effects"],
        json!([
            {"do": "startHere"},
            {"do": "createMachine"},
            {"do": "show", "cloud": "booting"}
        ])
    );
    let first = step(&begun["state"], json!({"on": "prompt", "id": "p1"}), 1);
    assert_eq!(first["effects"], json!([{"do": "deliver", "id": "p1", "to": "here"}]));
    let running = step(&first["state"], json!({"on": "turnStarted"}), 2);
    let ready = step(&running["state"], json!({"on": "machineReady"}), 4_000);
    assert_eq!(ready["state"]["cloud"], "ready");
    let moving = step(&ready["state"], json!({"on": "turnEnded"}), 5_000);
    assert_eq!(moving["effects"][1], json!({"do": "move"}));
    let held = step(&moving["state"], json!({"on": "prompt", "id": "p2"}), 5_100);
    assert_eq!(held["effects"], json!([{"do": "hold", "id": "p2"}]));
    let live = step(&held["state"], json!({"on": "moveCommitted"}), 5_600);
    assert_eq!(live["state"]["home"], "cloud");
    assert_eq!(
        live["effects"],
        json!([
            {"do": "log", "line": "hybrid start step: live 5600 ms"},
            {"do": "show", "cloud": "live"},
            {"do": "deliver", "id": "p2", "to": "cloud"}
        ])
    );
}

#[test]
fn an_unknown_op_or_event_is_invalid() {
    assert_eq!(call(c"cloud_hybrid_nothing", &json!({})).0, ERR_INVALID);
    let bad = json!({"event": {"on": "nothing"}, "now": 0});
    assert_eq!(call(c"cloud_hybrid_step", &bad).0, ERR_INVALID);
}

/// A sessions folder of its own under the temp folder, made empty.
fn sessions(name: &str) -> std::path::PathBuf {
    let root =
        std::env::temp_dir().join(format!("cloud-hybrid-start-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let sessions = root.join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    sessions
}

#[test]
fn a_session_with_no_hybrid_start_shows_none() {
    let sessions = sessions("none");
    let ask = json!({"stateDir": sessions, "session": "s-none"});
    assert_eq!(call(c"cloud_hybrid_start", &ask), (OK, json!({})));
    let _ = std::fs::remove_dir_all(sessions.parent().unwrap());
}

#[test]
fn the_newest_show_of_the_driver_log_is_the_start() {
    let sessions = sessions("log");
    let folder = sessions.parent().unwrap().join("hybrid-start");
    std::fs::create_dir_all(&folder).unwrap();
    let log = [
        "hybrid start step: gate 4 ms",
        r#"{"show":{"cloud":"booting","session":"s/1","at":10}}"#,
        r#"{"show":{"cloud":"failed","session":"s/1","reason":"quota","machine":"vm-1","at":20}}"#,
        r#"{"show":{"cloud":"mov"#,
    ]
    .join("\n");
    std::fs::write(folder.join("s-1.log"), log).unwrap();
    let ask = json!({"stateDir": sessions, "session": "s/1"});
    assert_eq!(
        call(c"cloud_hybrid_start", &ask),
        (OK, json!({"start": {"cloud": "failed", "reason": "quota", "sinceMs": 20}}))
    );
    assert_eq!(call(c"cloud_hybrid_start", &json!({"session": "s/1"})).0, ERR_INVALID);
    let _ = std::fs::remove_dir_all(sessions.parent().unwrap());
}

#[test]
fn a_session_reads_its_one_computer_status() {
    let facts = json!({
        "session_id": "s1",
        "home": "cloud",
        "machine": {"shape": {"vcpu": 2.0, "memory_gib": 4.0}, "paused_by": "spend_cap", "paused_since_ms": 9}
    });
    let (code, status) = call(c"cloud_computer_status", &facts);
    assert_eq!(code, OK);
    assert_eq!(status["phase"], "paused_spend_cap");
    assert_eq!(status["home"], "cloud");
    assert_eq!(status["shape"], json!({"vcpu": 2.0, "memory_gib": 4.0}));
    assert_eq!(status["why"], json!({"at_ms": 9, "reason": "spend_cap"}));
    assert_eq!(call(c"cloud_computer_status", &json!("nope")).0, ERR_INVALID);
}

#[test]
fn the_keep_count_says_how_many_and_what_another_does() {
    let plus = json!({"plan": "next_plus", "kept": 2, "on": false, "hoursUsed": 41.5});
    let (code, reply) = call(c"cloud_hybrid_keep_count", &plus);
    assert_eq!(code, OK);
    assert_eq!((reply["kept"].clone(), reply["slots"].clone()), (json!(2), json!(3)));
    assert_eq!(reply["hoursUsed"], 41);
    assert_eq!(reply["next"], json!({"do": "keeps", "after": 3}));
    let none = call(c"cloud_hybrid_keep_count", &json!({})).1;
    assert_eq!(none["next"], json!({"do": "startsTrial", "slots": 1, "hours": 10}));
    assert_eq!(call(c"cloud_hybrid_keep_count", &json!({"kept": "two"})).0, ERR_INVALID);
}

#[test]
fn a_computer_status_needs_its_session_and_reads_a_live_hybrid_show() {
    assert_eq!(call(c"cloud_computer_status", &json!({"home": "cloud"})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_computer_status", &json!({"session_id": ""})).0, ERR_INVALID);
    // The Show as `cloud_hybrid_start` answers it, `sinceMs` and all, paused at the spend cap.
    let facts = json!({
        "session_id": "s1",
        "hybrid": {"cloud": "live", "sinceMs": 4},
        "machine": {"paused_by": "spend_cap", "paused_since_ms": 9}
    });
    let (code, status) = call(c"cloud_computer_status", &facts);
    assert_eq!(code, OK);
    assert_eq!((&status["phase"], &status["home"]), (&json!("paused_spend_cap"), &json!("cloud")));
    // An unknown pause word is paused, not sleeping; a failed move keeps the chat here.
    let unknown = json!({"session_id": "s1", "home": "cloud", "machine": {"paused_by": "later"}});
    assert_eq!(call(c"cloud_computer_status", &unknown).1["phase"], "paused");
    let failed = json!({
        "session_id": "s1",
        "hybrid": {"cloud": "live"},
        "move": {"direction": "to_cloud", "failure": "network_dropped"}
    });
    let (_, status) = call(c"cloud_computer_status", &failed);
    assert_eq!((&status["phase"], &status["home"]), (&json!("move_failed"), &json!("this_mac")));
}

#[test]
fn the_live_status_reads_the_headers_facts_and_the_drivers_show() {
    let moving = json!({
        "session": "s1",
        "at": "local",
        "move": {"direction": "toCloud", "trigger": "person", "state": "moving", "startedMs": 8,
                 "canCancel": true}
    });
    let (code, status) = call(c"cloud_computer_status_live", &moving);
    assert_eq!(code, OK);
    assert_eq!((&status["phase"], &status["home"]), (&json!("moving"), &json!("this_mac")));
    assert_eq!(status["why"], json!({"at_ms": 8, "reason": "person_moved"}));
    // No `start` sent and a sessions folder with no driver log: no hybrid start, running.
    let dir = std::env::temp_dir().join(format!("cmux-status-live-{}", std::process::id()));
    let ask = json!({"session": "s1", "stateDir": dir});
    assert_eq!(call(c"cloud_computer_status_live", &ask).1["phase"], "running");
    assert_eq!(call(c"cloud_computer_status_live", &json!({"at": "cloud"})).0, ERR_INVALID);
}

#[test]
fn the_balance_simulates_each_place_and_picks_one() {
    let kept = json!({"folderBytes": 500_000_000u64, "headBytes": 5_000_000u64,
                      "uploadBytesPerSec": 5_000_000u64, "wakeMs": 8_000, "keepRunning": true});
    let (code, reply) = call(c"cloud_hybrid_balance", &kept);
    assert_eq!(code, OK);
    assert_eq!(
        (reply["best"].clone(), reply["why"].clone()),
        (json!("hybrid"), json!("answerHereWhileItWakes"))
    );
    assert_eq!(reply["places"].as_array().map(Vec::len), Some(4));
    assert_eq!(reply["headFirstSavesMs"], 92_000);
    assert_eq!(call(c"cloud_hybrid_balance", &json!({})).1["best"], "local");
    assert_eq!(call(c"cloud_hybrid_balance", &json!({"folderBytes": "big"})).0, ERR_INVALID);
}

#[test]
fn an_autosize_notice_becomes_a_chat_row_and_a_repeated_hold_folds() {
    let hold = |at: u64| {
        json!({
            "v": 1, "machine": "vm_a", "record": "rec_1", "team": "t1", "creator": "u1",
            "kind": "hold", "hold": "at_plan_limit", "reason": "memory",
            "reason_text": "it ran out of memory",
            "from": {"vcpu": 2, "mem_gib": 4, "disk_gib": 20, "hourly_usd": 0.148},
            "hourly_usd": 0.148,
            "upgrade": {"plan": "next_pro", "label": "Pro", "maxVcpu": 8, "maxMemGiB": 32, "maxDiskGiB": 128},
            "line": "This machine needs more than your plan allows", "at": at
        })
    };
    let (code, first) = call(c"cloud_autosize_rows", &json!({"event": hold(1)}));
    assert_eq!(code, OK);
    assert_eq!(first["added"], true);
    assert_eq!(
        first["rows"][0]["offer"],
        json!({"do": "upgrade", "plan": "next_pro", "label": "Pro", "vcpu": 8.0, "mem_gib": 32.0})
    );
    let (_, again) = call(
        c"cloud_autosize_rows",
        &json!({"rows": first["rows"], "event": hold(2), "viewer": "u2"}),
    );
    assert_eq!(again["rows"].as_array().unwrap().len(), 1);
    assert_eq!(again["rows"][0]["count"], 2);
    assert_eq!(
        again["rows"][0]["offer"],
        Value::Null,
        "a viewer who is not the creator is offered nothing"
    );
    let mut newer = hold(3);
    newer["v"] = json!(2);
    let (_, skipped) =
        call(c"cloud_autosize_rows", &json!({"rows": again["rows"], "event": newer}));
    assert_eq!(
        (skipped["added"].clone(), skipped["rows"].as_array().unwrap().len()),
        (json!(false), 1)
    );
    assert_eq!(call(c"cloud_autosize_rows", &json!({"rows": []})).0, ERR_INVALID);
}

#[test]
fn a_cloud_wire_autosize_frame_feeds_its_chats_rows() {
    let frame = |machine: &str, at: u64| {
        json!({
            "t": "ephemeral", "stream": "cloud:t_feed", "event": "cloud.machine.autosize",
            "data": {
                "v": 1, "machine": machine, "record": "rec_feed", "team": "t_feed", "creator": "u1",
                "kind": "grow", "reason": "memory", "reason_text": "it ran out of memory",
                "from": {"vcpu": 2, "mem_gib": 4, "disk_gib": 20, "hourly_usd": 0.148},
                "to": {"vcpu": 4, "mem_gib": 8, "disk_gib": 20, "hourly_usd": 0.296},
                "hourly_usd": 0.296, "line": "Machine grew to 4 vCPU / 8 GiB", "at": at
            }
        })
    };
    let ask = json!({"frame": frame("vm_feed_a", 1), "team": "t_feed"});
    let (code, fed) = call(c"cloud_autosize_frame", &ask);
    assert_eq!((code, fed), (OK, json!({"added": true, "machine": "vm_feed_a"})));
    assert_eq!(call(c"cloud_autosize_frame", &ask).1, json!({"added": false}), "a resend");
    let other_team = json!({"frame": frame("vm_feed_a", 2), "team": "t_other"});
    assert_eq!(call(c"cloud_autosize_frame", &other_team).1["added"], false);
    let not_autosize = json!({"frame": {"t": "ephemeral", "event": "cloud.machine.pausing"}});
    assert_eq!(call(c"cloud_autosize_frame", &not_autosize).1["added"], false);

    let (code, chat) = call(c"cloud_autosize_chat", &json!({"machine": "vm_feed_a"}));
    assert_eq!(code, OK);
    assert_eq!(chat["rows"].as_array().unwrap().len(), 1);
    assert_eq!(chat["rows"][0]["key"], "rec_feed:grow:1");
    let none = call(c"cloud_autosize_chat", &json!({"machine": "vm_feed_none"})).1;
    assert_eq!(none, json!({"rows": []}));
    assert_eq!(call(c"cloud_autosize_chat", &json!({})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_autosize_frame", &json!({})).0, ERR_INVALID);
}
