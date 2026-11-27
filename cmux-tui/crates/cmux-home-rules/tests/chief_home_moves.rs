//! `chief_home` app acpmux move, app links, the home directory and the hosted Chief: the cases of the
//! Swift `ChiefAppAcpmuxTests`, `DevBuildProcessIsolationTests` and `HostedChiefMigrationTests`.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("chief_home.{name}"), &request)
        .unwrap_or_else(|err| panic!("chief_home.{name}: {err}"))
}

#[test]
fn the_host_restarts_onto_the_app_acpmux_once() {
    let base = json!({ "hostPID": 42, "markedPID": 42, "markedHome": "/app/acpmux", "appHome": "/app/acpmux" });
    assert_eq!(op("acpmux_plan", base.clone())["restartHost"], false);
    let mut replaced = base.clone();
    replaced["hostReplaced"] = json!(true);
    assert_eq!(op("acpmux_plan", replaced)["restartHost"], true);
    let mut other = base.clone();
    other["markedPID"] = json!(7);
    assert_eq!(op("acpmux_plan", other)["restartHost"], true);
    let mut moved = base;
    moved["markedHome"] = json!("/own/acpmux");
    assert_eq!(op("acpmux_plan", moved)["restartHost"], true);
    assert_eq!(op("acpmux_plan", json!({ "appHome": "/a" }))["restartHost"], false);
    assert_eq!(
        op("acpmux_plan", json!({ "appHome": "/a", "ownDaemonPresent": true }))["endOwnDaemon"],
        true
    );
    assert_eq!(
        op(
            "acpmux_plan",
            json!({ "appHome": "/a", "ownDaemonPresent": true, "namedChiefsRun": true })
        )["endOwnDaemon"],
        false
    );
}

#[test]
fn the_mark_reads_back_what_it_writes() {
    let text =
        op("acpmux_mark_text", json!({ "pid": 4242, "appHome": "/Users/me/.acpmux" }))["text"]
            .clone();
    assert_eq!(text, "4242\n/Users/me/.acpmux\n");
    assert_eq!(
        op("acpmux_read_mark", json!({ "text": text })),
        json!({ "pid": 4242, "home": "/Users/me/.acpmux" })
    );
    assert_eq!(
        op("acpmux_read_mark", json!({ "text": "\n12\n" })),
        json!({ "pid": 12, "home": null })
    );
    assert_eq!(op("acpmux_read_mark", json!({ "text": " 12\n/h" }))["pid"], Value::Null);
    assert_eq!(op("acpmux_mark_file", json!({ "root": "/r" }))["path"], "/r/state/host.acpmux");
    let on = |host: Value, marked: Value, home: &str| {
        op(
            "acpmux_on_app",
            json!({ "hostPID": host, "markedPID": marked, "markedHome": home, "ownHome": "/own" }),
        )["onAppAcpmux"]
            .clone()
    };
    assert_eq!(on(json!(5), json!(5), "/app"), true);
    assert_eq!(on(json!(5), json!(5), "/own"), false);
    assert_eq!(on(json!(5), json!(6), "/app"), false);
    assert_eq!(on(Value::Null, json!(5), "/app"), false);
    assert_eq!(op("acpmux_idle", json!({ "census": {"inTurn": 0} }))["idle"], true);
    assert_eq!(op("acpmux_idle", json!({ "census": {"inTurn": 1} }))["idle"], false);
    assert_eq!(
        op("acpmux_idle", json!({ "census": {"inTurn": 0, "chiefInTurn": true} }))["idle"],
        false
    );
    assert_eq!(op("acpmux_idle", json!({}))["idle"], false);
}

#[test]
fn app_links_live_in_the_home_state() {
    let links = op("app_links", json!({ "root": "/Users/me/.cmux/chief/default" }));
    assert_eq!(links["controlLink"], "/Users/me/.cmux/chief/default/state/app.sock");
    assert_eq!(links["daemonLink"], "/Users/me/.cmux/chief/default/state/app-daemon.sock");
    assert_eq!(links["hostEnvironment"]["CMUX_SOCKET_PATH"], links["controlLink"]);
    assert_eq!(links["hostEnvironment"]["CMUX_APP_DAEMON_SOCKET"], links["daemonLink"]);
    assert_eq!(
        op("app_temporary_link", json!({ "link": "/s/app.sock", "pid": 9 }))["path"],
        "/s/app.sock.9.tmp"
    );
}

#[test]
fn a_dev_build_admits_only_its_own_home() {
    let root = "/Users/me/.cmux/chief";
    let admits = |home: &str, dev: bool, other: &str| {
        op("directory_admits", json!({ "homeRoot": format!("{root}/{home}"), "devBuild": dev, "root": format!("{root}/{other}") }))["admits"].clone()
    };
    let dev = "com.cmuxterm.app.debug.my-tag";
    assert_eq!(admits(dev, true, dev), true);
    assert_eq!(admits(dev, true, "default"), false);
    assert_eq!(admits(dev, true, "com.cmuxterm.app.debug.other"), false);
    assert_eq!(admits("default", false, "default"), true);
    assert_eq!(admits("default", false, "com.cmuxterm.app.nightly.cmux-next"), true);
    assert_eq!(admits("default", false, dev), false);
    assert_eq!(admits("default", false, "com.cmuxterm.app.debug.my-tag.work"), false);
    assert_eq!(admits("default", false, "com.cmuxterm.app.staging.my-tag"), false);
}

#[test]
fn the_directory_finds_homes_and_named_brains() {
    let parents = op(
        "directory_home_parents",
        json!({ "homeRoot": "/c/default", "chiefRoot": "/c" }),
    )["parents"]
        .clone();
    assert_eq!(parents, json!(["/c", "/c/isolated"]));
    let homes = op(
        "directory_homes",
        json!({ "listings": [
            {"parent": "/c", "directories": ["default", ".backups"], "brains": {"default": ["agent_two", ".tmp"]}},
            {"parent": "/c/isolated", "directories": ["x"]}
        ] }),
    )["homes"].clone();
    let homes = homes.as_object().unwrap();
    assert_eq!(homes.len(), 3);
    let roots: Vec<(&str, &str)> = homes
        .values()
        .map(|found| (found["root"].as_str().unwrap(), found["acpmuxOwner"].as_str().unwrap()))
        .collect();
    assert!(roots.contains(&("/c/default", "/c/default")));
    assert!(roots.contains(&("/c/default/c/agent_two", "/c/default")));
    assert!(roots.contains(&("/c/isolated/x", "/c/isolated/x")));
    assert!(homes.keys().all(|key| key.starts_with("chief:")));
    let owned = |v: Value| op("directory_owned", v)["owned"].clone();
    assert_eq!(owned(json!({ "homeRoot": "/h", "ownerRoot": "/h", "homeHostRuns": true })), true);
    assert_eq!(owned(json!({ "homeRoot": "/h", "ownerRoot": "/h", "ownerHostRuns": true })), false);
    assert_eq!(owned(json!({ "homeRoot": "/h/c/a", "ownerRoot": "/h" })), false);
}

#[test]
fn the_hosted_ledger_and_run() {
    let keys = op("ledger_keys", json!({ "session": "s", "chief": "agent" }));
    assert_eq!(keys["account"], "home.chief.hostedAccount.s");
    assert_eq!(keys["memoryStarted"], "home.chief.hosted.s.agent.memoryStarted");
    let refusal =
        |code: Value| op("ledger_is_refusal", json!({ "ownerCode": code }))["refusal"].clone();
    assert_eq!(refusal(json!("import_out_of_order")), true);
    for transient in [
        "rate_limited",
        "unavailable",
        "http_502",
        "internal",
        "auth_expired",
        "brain_busy",
        "http_401",
        "http_403",
    ] {
        assert_eq!(refusal(json!(transient)), false, "{transient}");
    }
    assert_eq!(refusal(Value::Null), false);
    assert_eq!(
        op("ledger_host", json!({ "session": "cmux chief\u{e9}" }))["host"],
        "mac-cmuxchief"
    );
    let long = "x".repeat(200);
    assert_eq!(op("ledger_host", json!({ "session": long }))["host"].as_str().unwrap().len(), 128);
    assert_eq!(op("hosted_wiring_copies", json!({ "debugBuild": true }))["copies"], false);
    assert_eq!(
        op(
            "hosted_wiring_copies",
            json!({ "debugBuild": true, "environment": {"CMUX_NEXT_HOSTED_CHIEF_COPY": "1"} })
        )["copies"],
        true
    );
    assert_eq!(op("hosted_wiring_copies", json!({}))["copies"], true);

    let start = json!({ "user": "u1", "mainConversation": "c", "hasHosted": true, "wiringCopies": true, "toolBundled": true, "memoryExists": true });
    assert_eq!(
        op("hosted_start", start.clone()),
        json!({ "runs": true, "copies": true, "memoryDue": true, "pending": true })
    );
    let mut other_account = start;
    other_account["ledgerAccount"] = json!("u2");
    assert_eq!(op("hosted_start", other_account)["copies"], false);
    assert_eq!(op("hosted_start", json!({ "user": "u1" }))["runs"], false);
    for (done, exists, tool, step) in [
        (true, true, true, "done"),
        (false, false, true, "skip"),
        (false, true, true, "export"),
        (false, true, false, "wait"),
    ] {
        assert_eq!(
            op(
                "hosted_memory_step",
                json!({ "memoryDone": done, "memoryExists": exists, "toolBundled": tool })
            )["step"],
            step
        );
    }
    assert_eq!(op("hosted_brain", json!({ "copied": true }))["turnOn"], true);
    assert_eq!(op("hosted_brain", json!({}))["notice"], "brainOff");
    assert_eq!(
        op("hosted_brain", json!({ "enabled": true })),
        json!({ "turnOn": false, "enabled": true, "markBrain": true, "notice": null })
    );
    assert_eq!(op("hosted_failure", json!({ "ownerCode": "brain_busy" }))["action"], "busy");
    assert_eq!(op("hosted_failure", json!({ "cancelled": true }))["action"], "cancelled");
    assert_eq!(op("hosted_failure", json!({ "current": false }))["action"], "stale");
    assert_eq!(op("hosted_failure", json!({ "brainRead": true }))["brainOff"], true);
    let give_up =
        op("hosted_failure", json!({ "ownerCode": "bad", "copies": true, "failures": 3 }));
    assert_eq!(give_up["action"], "giveUp");
    assert_eq!(give_up["markSteps"], true);
    assert_eq!(
        op("hosted_failure", json!({ "ownerCode": "bad", "copies": true, "failures": 0 }))["notice"],
        "copyFailed"
    );
}
