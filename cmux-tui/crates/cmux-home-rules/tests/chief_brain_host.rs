//! `HomeBrainHost`, `ChiefHostStop`, `ChiefBrainKeeper` and `ChiefAcpmuxHeal` parity
//! (ChiefBrainWatchFilesHostTests, ChiefHostIdleHandoffTests, ChiefAppAcpmuxTests).

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("chief_brain.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

#[test]
fn the_bundled_chief_runs_in_stable_nightly_and_debug_only() {
    let allowed = |id: Value, debug: bool| {
        op("bundled_chief_allowed", json!({"bundleId": id, "isDebugBuild": debug}))["allowed"]
            .clone()
    };
    assert_eq!(allowed(json!("com.cmuxterm.app"), false), json!(true));
    assert_eq!(allowed(json!("com.cmuxterm.app.nightly"), false), json!(true));
    assert_eq!(allowed(json!("com.cmuxterm.app.debug.tag"), false), json!(true));
    assert_eq!(allowed(json!("com.cmuxterm.apps"), false), json!(false));
    assert_eq!(allowed(json!("com.example"), false), json!(false));
    assert_eq!(allowed(Value::Null, true), json!(true));
}

#[test]
fn the_kill_switch_stops_every_candidate() {
    let r = op(
        "host_resolve_plan",
        json!({"environment": {"CMUX_AGENTS_DISABLED": " 1 "}, "bundledBinDirectory": "/b", "bundledChiefAllowed": true}),
    );
    assert_eq!(r["disabled"], json!(true));
    assert_eq!(r["candidates"], json!([]));
    let r = op("agents_disabled", json!({"environment": {"ACPMUX_AGENT_LAUNCH": "DENY"}}));
    assert_eq!(r, json!({"disabled": true, "notice": "chiefAgentsDisabled"}));
    let r = op("agents_disabled", json!({}));
    assert_eq!(r, json!({"disabled": false, "notice": null}));
}

#[test]
fn the_override_comes_before_the_bundled_chief_and_own_acpmux_sets_its_home() {
    let r = op(
        "host_resolve_plan",
        json!({"environment": {"CMUX_NEXT_MUX_HOST": "/dev/host"}, "bundledBinDirectory": "/b/",
               "bundledChiefAllowed": true, "acpmuxHome": "/h/acpmux"}),
    );
    assert_eq!(r["candidates"], json!(["/dev/host", "/b/optchat-chief"]));
    assert_eq!(r["acpmuxSet"], json!({"ACPMUX_HOME": "/h/acpmux"}));
    assert_eq!(r["acpmuxRemove"], json!(["ACPMUX_SOCKET"]));
    let r = op("host_resolve_plan", json!({"usesAppAcpmux": true, "bundledBinDirectory": "/b"}));
    assert_eq!(r["candidates"], json!([]));
    assert_eq!(r["acpmuxSet"], json!({}));
}

#[test]
fn the_files_host_launches_the_chief_through_run() {
    let r = op(
        "host_arguments",
        json!({"executable": "/b/optchat-chief", "filesHostExecutable": "/f/cmux-files-host",
               "daemonSocket": "/s.sock", "muxHome": "/m"}),
    );
    assert_eq!(r["launchPath"], json!("/bin/sh"));
    let args: Vec<&str> =
        r["arguments"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    assert_eq!(args[2], "mux-host-launch");
    assert_eq!(&args[3..7], ["/f/cmux-files-host", "run", "--", "/b/optchat-chief"]);
    assert_eq!(&args[7..], ["host", "--daemon-socket", "/s.sock", "--mux-home", "/m"]);
    let r =
        op("host_arguments", json!({"executable": "/b/x", "daemonSocket": "/s", "muxHome": "/m"}));
    assert_eq!(r["arguments"][3], json!("/b/x"));
    assert_eq!(r["arguments"][4], json!("host"));
}

#[test]
fn the_host_environment_carries_paths_links_and_the_app() {
    let r = op(
        "host_environment",
        json!({"process": {"USER": "leo", "TMPDIR": "/t", "SECRET": "x", "CMUX_SPACE": "tag"},
               "home": "/Users/leo", "muxHome": "/m", "bundledBinDirectory": "/b",
               "userName": "Leo", "chiefTitle": "Chief", "appLinks": {"CMUX_APP_LINK": "1"},
               "acpmuxEnvironment": {"ACPMUX_HOME": "/a"}, "acpmuxExecutable": "/b/acpmux",
               "usesAppAcpmux": true, "buildSpaceKey": "CMUX_SPACE",
               "bundleId": "com.cmuxterm.app", "appVersion": "1.2"}),
    );
    let env = &r["environment"];
    assert_eq!(env["MUX_AGENT_TOKEN_FILE"], json!("/m/agent-token"));
    assert_eq!(env["MUX_HOST_LOG"], json!("/m/host.log"));
    assert_eq!(env["HOME"], json!("/Users/leo"));
    assert_eq!(env["MUX_USER_NAME"], json!("Leo"));
    assert_eq!(env["CMUX_APP_LINK"], json!("1"));
    assert_eq!(env["ACPMUX_HOME"], json!("/a"));
    assert_eq!(env["ACPMUX_BIN"], json!("/b/acpmux"));
    assert_eq!(env["OPTCHAT_ACPMUX_SUPERVISED"], json!("1"));
    assert_eq!(env["USER"], json!("leo"));
    assert_eq!(env["CMUX_SPACE"], json!("tag"));
    assert_eq!(env["SECRET"], Value::Null, "only the copied keys pass");
    assert_eq!(env["CMUX_CHIEF_APP_BUNDLE_ID"], json!("com.cmuxterm.app"));
    assert_eq!(env["CMUX_CHIEF_APP_VERSION"], json!("1.2"));
    assert!(env["PATH"].as_str().unwrap().starts_with("/b"));
}

#[test]
fn the_lock_names_the_host_pid() {
    let pid = |text: Value| op("lock_pid", json!({"text": text}))["pid"].clone();
    assert_eq!(pid(json!("4242\n1\nflock\n")), json!(4242));
    assert_eq!(pid(json!("\n 77 \n")), json!(77));
    assert_eq!(pid(json!("1\n")), Value::Null);
    assert_eq!(pid(json!("nope")), Value::Null);
    assert_eq!(pid(Value::Null), Value::Null);
}

#[test]
fn only_a_host_that_takes_the_handoff_is_asked() {
    let target = |running: Value, mark: Value| {
        op("handoff_target", json!({"runningPid": running, "mark": mark}))["pid"].clone()
    };
    assert_eq!(target(json!(4242), json!("4242\n")), json!(4242));
    assert_eq!(target(json!(4242), Value::Null), Value::Null, "an older host");
    assert_eq!(target(json!(4242), json!("4141\n")), Value::Null, "an earlier host's mark");
    assert_eq!(target(Value::Null, json!("4242\n")), Value::Null, "no running host");
}

#[test]
fn the_chief_host_and_the_files_launcher_are_told_apart() {
    let p =
        |path: Value, name: Value| op("host_process", json!({"path": path, "processName": name}));
    let r = p(json!("/A/Contents/Resources/bin/optchat-chief"), json!("optchat-chief"));
    assert_eq!(r, json!({"isChiefHost": true, "isFilesHostLauncher": false}));
    let r = p(
        json!("/A/cmux Files (dev).app/Contents/MacOS/cmux-files-host"),
        json!("cmux-files-host"),
    );
    assert_eq!(r, json!({"isChiefHost": false, "isFilesHostLauncher": true}));
    let r = p(Value::Null, json!("optchat-chief"));
    assert_eq!(r, json!({"isChiefHost": true, "isFilesHostLauncher": false}));
    let r = p(json!("/x/cmux-files-host"), Value::Null);
    assert_eq!(r["isFilesHostLauncher"], json!(false));
}

#[test]
fn the_app_acpmux_keeps_nothing_when_the_chief_runs_on_it() {
    assert_eq!(
        op("app_acpmux_end_keep", json!({"chiefUsesAppAcpmux": true}))["keep"],
        json!("nothing")
    );
    assert_eq!(
        op("app_acpmux_end_keep", json!({"chiefUsesAppAcpmux": false}))["keep"],
        json!("chief")
    );
}

fn start(state: &mut Value, event: Value) -> Vec<Value> {
    let r = op("host_start_step", json!({"state": state, "event": event}));
    *state = r["state"].clone();
    r["effects"].as_array().cloned().unwrap()
}

fn kinds(fx: &[Value]) -> Vec<String> {
    fx.iter().map(|e| e["kind"].as_str().unwrap().to_owned()).collect()
}

#[test]
fn an_own_acpmux_start_hands_off_a_stale_host_then_launches() {
    let mut s = json!({});
    assert_eq!(
        kinds(&start(&mut s, json!({"kind": "begin", "usesAppAcpmux": false, "hasAcpmux": true}))),
        ["adoptBuildHomes"]
    );
    assert_eq!(kinds(&start(&mut s, json!({"kind": "done"}))), ["leaveAppAcpmux"]);
    assert_eq!(kinds(&start(&mut s, json!({"kind": "moved", "ok": true}))), ["handOffIfStale"]);
    assert_eq!(kinds(&start(&mut s, json!({"kind": "handOff", "stale": true}))), ["stopHost"]);
    assert_eq!(
        start(&mut s, json!({"kind": "stopped", "pid": 9})),
        [json!({"kind": "waitForExit", "pid": 9, "seconds": 15})]
    );
    assert_eq!(kinds(&start(&mut s, json!({"kind": "done"}))), ["checkToken"]);
    assert_eq!(
        kinds(&start(&mut s, json!({"kind": "token", "hasToken": false}))),
        ["mintAndLaunch"]
    );
    let fx = start(&mut s, json!({"kind": "launched", "pid": 50}));
    assert_eq!(fx, [json!({"kind": "finish", "outcome": {"kind": "launched", "pid": 50}})]);
}

#[test]
fn a_token_reuses_the_host_the_lock_names() {
    let mut s = json!({});
    start(&mut s, json!({"kind": "begin", "usesAppAcpmux": false, "hasAcpmux": false}));
    start(&mut s, json!({"kind": "done"}));
    assert_eq!(kinds(&start(&mut s, json!({"kind": "moved", "ok": true}))), ["checkToken"]);
    assert_eq!(kinds(&start(&mut s, json!({"kind": "token", "hasToken": true}))), ["readLock"]);
    let fx = start(&mut s, json!({"kind": "lockRead", "pid": 77}));
    assert_eq!(
        fx,
        [json!({"kind": "finish", "outcome": {"kind": "reusedRunningHost", "pid": 77}})]
    );
}

#[test]
fn an_app_acpmux_start_moves_then_marks_the_launched_pid() {
    let mut s = json!({});
    start(&mut s, json!({"kind": "begin", "usesAppAcpmux": true, "hasAcpmux": true}));
    assert_eq!(kinds(&start(&mut s, json!({"kind": "done"}))), ["ensureAppAcpmux"]);
    assert_eq!(kinds(&start(&mut s, json!({"kind": "done"}))), ["runAppAcpmuxMove"]);
    assert_eq!(kinds(&start(&mut s, json!({"kind": "moved", "ok": true}))), ["checkToken"]);
    start(&mut s, json!({"kind": "token", "hasToken": false}));
    assert_eq!(
        start(&mut s, json!({"kind": "launched", "pid": 60})),
        [json!({"kind": "markPid", "pid": 60})]
    );
    let fx = start(&mut s, json!({"kind": "done"}));
    assert_eq!(fx, [json!({"kind": "finish", "outcome": {"kind": "launched", "pid": 60}})]);
}

#[test]
fn an_app_acpmux_launch_with_no_pid_marks_the_lock_pid_and_a_failed_move_reuses() {
    let mut s = json!({});
    start(&mut s, json!({"kind": "begin", "usesAppAcpmux": true, "hasAcpmux": true}));
    start(&mut s, json!({"kind": "done"}));
    start(&mut s, json!({"kind": "done"}));
    start(&mut s, json!({"kind": "moved", "ok": true}));
    start(&mut s, json!({"kind": "token", "hasToken": false}));
    assert_eq!(kinds(&start(&mut s, json!({"kind": "launched", "pid": null}))), ["readLock"]);
    assert_eq!(
        start(&mut s, json!({"kind": "lockRead", "pid": 61})),
        [json!({"kind": "markPid", "pid": 61})]
    );
    // A move that fails reuses whatever the lock names.
    let mut s = json!({});
    start(&mut s, json!({"kind": "begin", "usesAppAcpmux": true, "hasAcpmux": true}));
    start(&mut s, json!({"kind": "done"}));
    start(&mut s, json!({"kind": "done"}));
    assert_eq!(kinds(&start(&mut s, json!({"kind": "moved", "ok": false}))), ["readLock"]);
    let fx = start(&mut s, json!({"kind": "lockRead", "pid": null}));
    assert_eq!(
        fx,
        [json!({"kind": "finish", "outcome": {"kind": "reusedRunningHost", "pid": null}})]
    );
    // An event out of place changes nothing.
    assert!(start(&mut s, json!({"kind": "launched", "pid": 1})).is_empty());
}

fn keeper(name: &str, asked: bool, k: Value) -> Value {
    op(name, json!({"asked": asked, "keeper": k}))
}

#[test]
fn the_keeper_starts_watches_or_waits() {
    let r = keeper("keeper_ensure", false, json!({"canStart": false}));
    assert_eq!(r, json!({"answer": "no", "effects": []}));
    let r = keeper("keeper_ensure", false, json!({"canStart": true, "shutdownMarker": true}));
    assert_eq!(r["answer"], json!("no"), "a quit Chief stays off until asked");
    let r = keeper("keeper_ensure", true, json!({"canStart": true, "shutdownMarker": true}));
    assert_eq!(
        r,
        json!({"answer": "ifStarted", "effects": [{"kind": "removeShutdownMarker"}, {"kind": "start"}]})
    );
    let r = keeper(
        "keeper_ensure",
        false,
        json!({"canStart": true, "hasWatch": true, "watchWatching": true}),
    );
    assert_eq!(r, json!({"answer": "yes", "effects": []}));
    let r = keeper(
        "keeper_ensure",
        false,
        json!({"canStart": true, "hasWatch": true, "runningPid": 5}),
    );
    assert_eq!(r, json!({"answer": "yes", "effects": [{"kind": "watch", "pid": 5}]}));
    let r = keeper("keeper_ensure", false, json!({"canStart": true, "hasWatch": true}));
    assert_eq!(r["effects"], json!([{"kind": "dropWatch"}, {"kind": "start"}]));
    let r = keeper(
        "keeper_ensure",
        true,
        json!({"canStart": true, "hasWatch": true, "watchStopped": true}),
    );
    assert_eq!(r["answer"], json!("no"), "a stopped keeper never starts");
}

#[test]
fn a_chat_does_not_restart_a_host_the_watch_gave_up_on() {
    let r = keeper("keeper_ensure_for_chat", false, json!({"canStart": true, "hasWatch": true}));
    assert_eq!(r["answer"], json!("no"));
    let r = keeper("keeper_ensure_for_chat", false, json!({"starting": true}));
    assert_eq!(r["answer"], json!("yes"));
    let r = keeper("keeper_ensure_for_chat", false, json!({"canStart": true}));
    assert_eq!(r["answer"], json!("ifStarted"));
    assert_eq!(
        keeper("keeper_is_running", false, json!({"runningPid": 3}))["running"],
        json!(true)
    );
    assert_eq!(
        keeper("keeper_is_running", false, json!({"hasWatch": true}))["running"],
        json!(false)
    );
}

#[test]
fn only_a_person_asking_a_chat_with_the_chief_wakes_it() {
    let parts = json!([{"id": "agent_mux", "kind": "agent"}, {"id": "u1", "kind": "human"}, {"id": "a2", "kind": "agent"}]);
    let ask = |author: &str, p: Value| {
        op("keeper_ask", json!({"author": author, "participants": p, "keeper": {"canStart": true}}))
    };
    let r = ask("u1", parts.clone());
    assert_eq!(r["asks"], json!(true));
    assert_eq!(r["ensure"]["answer"], json!("ifStarted"));
    assert_eq!(ask("a2", parts.clone())["asks"], json!(false));
    assert_eq!(ask("agent_mux", parts)["asks"], json!(false));
    assert_eq!(ask("u1", json!([{"id": "u1", "kind": "human"}]))["asks"], json!(false));
    assert_eq!(ask("u1", Value::Null)["ensure"], Value::Null);
}

#[test]
fn a_start_that_lands_after_quit_terminates_its_host() {
    let after = |r: Value| op("keeper_after_start", r);
    assert_eq!(
        after(json!({"pid": 5, "hasWatch": true, "watchStopped": true, "pidIsHost": true})),
        json!({"kind": "terminate", "pid": 5})
    );
    assert_eq!(
        after(json!({"pid": 5, "hasWatch": true, "watchStopped": true})),
        json!({"kind": "nothing"})
    );
    assert_eq!(after(json!({"pid": 5, "hasWatch": true})), json!({"kind": "watch", "pid": 5}));
    assert_eq!(after(json!({"pid": null})), json!({"kind": "createWatch", "pid": null}));
}

/// Runs a heal like `ChiefAcpmuxHeal` and records its calls (the Swift test's `calls`).
fn heal_calls(action: &str, exited: bool, handed_off: bool) -> Vec<&'static str> {
    let mut calls = Vec::new();
    let plan = op("heal_plan", json!({"action": action}));
    for effect in plan["effects"].as_array().unwrap() {
        match effect["kind"].as_str().unwrap() {
            "stopHost" => calls.push("stop"),
            "ensureHost" => calls.push("ensure"),
            "finishAfterTurn" => {
                let mut phase = json!("waitingForExit");
                calls.push("exit");
                let mut event = json!({"kind": "hostExit", "exited": exited});
                loop {
                    let r = op("heal_finish_step", json!({"phase": phase, "event": event}));
                    phase = r["phase"].clone();
                    let mut next = None;
                    for e in r["effects"].as_array().unwrap() {
                        match e["kind"].as_str().unwrap() {
                            "handOff" => {
                                calls.push("handOff");
                                next = Some(json!({"kind": "handOff", "handedOff": handed_off}));
                            }
                            "stopHost" => {
                                calls.push("stop");
                                next = Some(json!({"kind": "done"}));
                            }
                            "ensureHost" => {
                                calls.push("ensure");
                                next = Some(json!({"kind": "done"}));
                            }
                            _ => {}
                        }
                    }
                    match next {
                        Some(e) => event = e,
                        None => break,
                    }
                }
                assert_eq!(phase, json!("done"));
            }
            other => panic!("{other}"),
        }
    }
    calls
}

#[test]
fn the_heal_waits_for_the_turn_then_hands_off() {
    assert_eq!(heal_calls("waitForHost", true, true), ["exit", "handOff", "stop", "ensure"]);
    assert_eq!(heal_calls("waitForHost", true, false), ["exit", "handOff", "ensure"]);
    assert_eq!(heal_calls("waitForHost", false, true), ["exit"]);
    assert_eq!(heal_calls("handOff", true, true), ["stop", "ensure"]);
    assert!(heal_calls("keep", true, true).is_empty());
    assert_eq!(op("heal_plan", json!({"action": "handOff"}))["healed"], json!(true));
    assert_eq!(op("heal_plan", json!({"action": "waitForHost"}))["healed"], json!(false));
}
