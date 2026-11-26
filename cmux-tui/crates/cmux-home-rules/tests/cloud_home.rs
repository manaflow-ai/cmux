//! Parity tests for Home's cloud rules, part 2 (`ServerReachPlan.swift`,
//! `HomeCloudChiefs+Tab.swift`, `HomeCloudChiefs+Placement.swift`,
//! `HomeChiefArchive.swift`, `HomeMessageRequests.swift`,
//! `CloudHomeSource+Subscriptions.swift`, `CloudHomeSource+EditEcho.swift`;
//! cases from `ServerReachReconciliationTests`, `HomeDirectoryChiefArchiveTests`,
//! `HomeMessageRequestsTests` and `HomeChiefRosterTests`).

use cmux_home_rules::ops::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("cloud.{name}"), &request).expect(name)
}

const HOST: &str = "host_aaaaaaaa";
const INST: &str = "inst_bbbbbbbb";

fn reach(host: &str, install: &str, route: Value) -> Value {
    json!({ "hostID": host, "installID": install, "name": "mini", "route": route })
}

fn chief(id: &str, main: Option<&str>, place: Option<(&str, &str)>, default: bool) -> Value {
    let mut c = json!({ "id": id, "displayName": id, "isDefault": default, "rev": 3 });
    if let Some(main) = main {
        c["mainConversation"] = json!(main);
    }
    if let Some((host, install)) = place {
        c["brainPlace"] = json!({ "host": host, "install": install });
    }
    c
}

// ServerReach and ServerReachPlan.

#[test]
fn diff_reuses_only_same_install_and_route() {
    for route in [
        json!({ "kind": "unix", "socket": "/tmp/brain.sock" }),
        json!({ "kind": "overlay", "linkSocket": "/tmp/link.sock" }),
        json!({ "kind": "ssh", "destination": "mini" }),
    ] {
        let shown = reach(HOST, INST, route.clone());
        let same = op("reach_diff", json!({ "shown": [shown], "desired": [shown] }));
        assert_eq!(same, json!({ "add": [], "remove": [], "reroute": [] }));
        let reinstalled = reach(HOST, "inst_cccccccc", route);
        let moved = op("reach_diff", json!({ "shown": [shown], "desired": [reinstalled] }));
        assert_eq!(moved["reroute"], json!([reinstalled]));
        assert_eq!(moved["add"], json!([]));
    }
    let gone = op(
        "reach_diff",
        json!({ "shown": [reach(HOST, INST, json!({ "kind": "ssh", "destination": "mini" }))], "desired": [] }),
    );
    assert_eq!(gone["remove"], json!([format!("server-{HOST}")]));
}

#[test]
fn route_prefers_this_mac_then_overlay_then_ssh() {
    let host = json!({ "host": HOST, "name": "Leo's Mini" });
    let local = json!({ "hostNames": ["leos-mini"], "brainSocket": "/tmp/brain.sock" });
    let here = op("reach_route", json!({ "host": host, "install": INST, "local": local }));
    assert_eq!(here["route"], json!({ "kind": "unix", "socket": "/tmp/brain.sock" }));
    let link =
        json!({ "socket": "/tmp/link.sock", "installs": [INST], "install": "inst_mine0000" });
    let overlay =
        op("reach_route", json!({ "host": host, "install": INST, "local": local, "link": link }));
    assert_eq!(overlay["route"], json!({ "kind": "overlay", "linkSocket": "/tmp/link.sock" }));
    let ssh = op("reach_route", json!({ "host": host, "install": INST }));
    assert_eq!(ssh["route"], json!({ "kind": "ssh", "destination": "leos-mini" }));
    let label = op("reach_dns_label", json!({ "name": " --My_Mac Studio!.. " }));
    assert_eq!(label["label"], json!("my-mac-studio"));
    assert_eq!(op("reach_dns_label", json!({ "name": "!!" }))["route"], Value::Null);
}

#[test]
fn plan_skips_devices_and_names_unroutable() {
    let chiefs = json!([
        chief("a", Some("c1"), Some((HOST, INST)), true),
        chief("b", Some("c2"), Some((HOST, INST)), false),
        chief("c", None, Some(("host_dddddddd", INST)), false),
        chief("d", None, Some(("host_eeeeeeee", INST)), false),
        chief("e", Some("c3"), None, false),
    ]);
    let hosts = json!([
        { "host": HOST, "name": "mini" },
        { "host": "host_dddddddd", "name": "phone", "kind": "device" },
        { "host": "host_eeeeeeee", "name": "!!!" },
    ]);
    let plan = op("reach_plan", json!({ "chiefs": chiefs, "hosts": hosts }));
    assert_eq!(
        plan["desired"],
        json!([reach(HOST, INST, json!({ "kind": "ssh", "destination": "mini" }))])
    );
    assert_eq!(plan["unroutable"], json!(["!!!"]));
}

#[test]
fn reach_validates_ids_and_sockets() {
    let ok = op(
        "reach_new",
        json!({ "hostID": HOST, "installID": INST, "name": " mini ", "route": { "kind": "unix", "socket": "/tmp/a.sock" } }),
    );
    assert_eq!(ok["machineID"], json!(format!("server-{HOST}")));
    assert_eq!(ok["reach"]["name"], json!("mini"));
    for (host, install, name, socket, field) in [
        ("host_x", INST, "mini", "/tmp/a", "host"),
        (HOST, "inst_", "mini", "/tmp/a", "install"),
        (HOST, INST, "  ", "/tmp/a", "name"),
        (HOST, INST, "mini", "/tmp/../a", "socket"),
    ] {
        let bad = op(
            "reach_new",
            json!({ "hostID": host, "installID": install, "name": name, "route": { "kind": "unix", "socket": socket } }),
        );
        assert_eq!(bad["invalid"], json!(field));
    }
}

#[test]
fn link_peers_and_files() {
    let show = json!({ "running": true, "socket": "/s/link.sock", "install": "inst_mine0000", "peers_file": "/state/link/peers.json" });
    let peers = json!({ "peers": [{ "install": INST }, { "name": "no install" }] });
    let out = op("reach_link_peers", json!({ "show": show, "peers": peers }));
    assert_eq!(out["link"]["socket"], json!("/s/link.sock"));
    assert_eq!(out["link"]["installs"], json!([INST]));
    assert_eq!(out["registrationFile"], json!("/state/link.json"));
    assert_eq!(out["watchedFiles"], json!(["/state/link/peers.json", "/state/link.json"]));
    let stopped = op("reach_link_peers", json!({ "show": { "running": false, "socket": "/s" } }));
    assert_eq!(stopped["link"]["socket"], Value::Null);
    let file = op("reach_default_link_setup_file", json!({ "home": "/Users/me" }));
    assert_eq!(
        file["file"],
        json!("/Users/me/Library/Application Support/cmux-tui/sessions/link/config.json")
    );
    let env = op(
        "reach_default_link_setup_file",
        json!({ "home": "/Users/me", "environment": { "CMUX_TUI_STATE_DIR": "/st/" } }),
    );
    assert_eq!(env["file"], json!("/st/link/config.json"));
}

#[test]
fn parse_chiefs_and_hosts_refuse_a_wrong_reply() {
    let chiefs = op(
        "reach_parse_chiefs",
        json!({ "value": { "chiefs": [
            { "id": "a", "rev": 2, "display_name": "Chief", "is_default": true, "main_conversation": "c1",
              "brain_place": { "host": HOST, "install": INST } },
            { "id": "no-rev" },
        ] } }),
    );
    assert_eq!(chiefs["chiefs"].as_array().map(Vec::len), Some(1));
    assert_eq!(chiefs["chiefs"][0]["brainPlace"]["host"], json!(HOST));
    assert!(call("cloud.reach_parse_chiefs", &json!({ "value": {} })).is_err());
    let hosts = op(
        "reach_parse_hosts",
        json!({ "value": { "hosts": [{ "id": HOST, "name": "mini", "kind": "server" }], "next_cursor": "p2" } }),
    );
    assert_eq!(hosts["hosts"][0]["host"], json!(HOST));
    assert_eq!(hosts["next"], json!("p2"));
    assert!(call("cloud.reach_parse_hosts", &json!({ "value": { "rows": [] } })).is_err());
}

// HomeCloudChiefs.

fn both() -> Value {
    json!({
        "hosted": chief("h", Some("hosted-c"), None, true),
        "placed": chief("p", Some("placed-c"), Some((HOST, INST)), false),
    })
}

#[test]
fn list_picks_default_hosted_and_placed() {
    let chiefs = json!([
        chief("h1", Some("c1"), None, false),
        chief("h2", Some("c2"), None, true),
        chief("nomain", None, None, true),
        chief("p1", Some("c3"), Some((HOST, INST)), false),
    ]);
    let list = op("chiefs_list", json!({ "chiefs": chiefs }));
    assert_eq!(list["hosted"]["id"], json!("h2"));
    assert_eq!(list["placed"]["id"], json!("p1"));
    let placed_only = op("chiefs_placed_only", json!({ "chiefs": chiefs }));
    assert_eq!(
        placed_only,
        json!({ "placed": chief("p1", Some("c3"), Some((HOST, INST)), false) })
    );
}

#[test]
fn other_host_offers_the_other_chief() {
    let other = |c: &str| {
        op("chiefs_other_host", json!({ "chiefs": both(), "conversation": c }))["other"].clone()
    };
    assert_eq!(other("hosted-c"), json!("placed"));
    assert_eq!(other("placed-c"), json!("hosted"));
    assert_eq!(other("elsewhere"), Value::Null);
    let lone = op(
        "chiefs_other_host",
        json!({ "chiefs": { "hosted": chief("h", Some("hosted-c"), None, true) }, "conversation": "hosted-c" }),
    );
    assert_eq!(lone["other"], Value::Null);
}

#[test]
fn shown_and_tab() {
    let shown = op("chiefs_shown", json!({ "chiefs": both(), "choice": "placed" }));
    assert_eq!(shown["chief"]["id"], json!("p"));
    assert_eq!(shown["canSwitch"], json!(true));
    let tab = |chiefs: Value, local: Value, history: bool, prefers: bool| {
        op(
            "chiefs_tab",
            json!({ "chiefs": chiefs, "local": local, "localHasHistory": history, "choice": "hosted", "prefersLocal": prefers }),
        )["conversation"]
            .clone()
    };
    assert_eq!(tab(both(), json!("local-c"), true, false), json!("hosted-c"));
    assert_eq!(tab(both(), json!("local-c"), false, true), json!("local-c"));
    let no_hosted = json!({ "placed": chief("p", Some("placed-c"), Some((HOST, INST)), false) });
    assert_eq!(tab(no_hosted.clone(), json!("local-c"), true, false), json!("local-c"));
    assert_eq!(tab(no_hosted, json!("local-c"), false, false), json!("placed-c"));
    assert_eq!(tab(json!({}), Value::Null, false, false), Value::Null);
}

#[test]
fn placement_from_chiefs_then_records() {
    let placement = |c: &str| {
        op(
            "chiefs_placement",
            json!({ "chiefs": both(), "conversation": c,
                    "records": [{ "id": "r", "mainConversation": "rec-c", "placed": true }] }),
        )["placement"]
            .clone()
    };
    assert_eq!(placement("placed-c"), json!({ "id": "p", "placed": true }));
    assert_eq!(placement("hosted-c"), json!({ "id": "h", "placed": false }));
    assert_eq!(placement("rec-c"), json!({ "id": "r", "placed": true }));
    assert_eq!(placement("none"), Value::Null);
}

#[test]
fn tabs_move_and_stale_close() {
    let panes = json!([
        { "pane": "p1", "tabs": [{ "surface": "s1", "conversation": "old" }, { "surface": "s2" }] },
        { "pane": "p2", "tabs": [{ "surface": "s3", "conversation": "old" }, { "surface": "s4", "conversation": "new" }] },
    ]);
    let moved = op("chiefs_move", json!({ "from": ["old"], "chief": "newer", "panes": panes }));
    assert_eq!(moved["close"], json!(["s1", "s3"]));
    assert_eq!(moved["pane"], json!("p1"));
    let already = op("chiefs_move", json!({ "from": ["old"], "chief": "new", "panes": panes }));
    assert_eq!(already, json!({ "close": [], "pane": null }), "the Chief already has its tab");
    let stale =
        op("chiefs_stale_tabs", json!({ "stale": ["old", "new"], "chief": "new", "panes": panes }));
    assert_eq!(stale["close"], json!(["s1", "s3"]));
    assert_eq!(
        op("chiefs_is_open", json!({ "chief": "new", "panes": panes }))["open"],
        json!(true)
    );
    assert_eq!(
        op("chiefs_is_open", json!({ "chief": "zzz", "panes": panes }))["open"],
        json!(false)
    );
}

#[test]
fn ok_value_and_ensure() {
    let refused =
        op("chiefs_ok_value", json!({ "reply": { "_tag": "Err", "code": "policy.denied" } }));
    assert_eq!(
        refused,
        json!({ "refused": { "code": "policy.denied", "message": "policy.denied" } })
    );
    let value = op("chiefs_ok_value", json!({ "reply": { "value": { "a": 1 } } }));
    assert_eq!(value, json!({ "value": { "a": 1 } }));

    let chiefs = json!([
        chief("h", Some("c1"), None, false),
        { "id": "p", "displayName": "Chief", "rev": 7, "brainPlace": { "host": HOST, "install": INST } },
    ]);
    let ensure = op(
        "chiefs_ensure",
        json!({ "chiefs": chiefs, "chiefName": "Chief", "placedName": "Chief on mini" }),
    );
    assert_eq!(ensure["needsHosted"], json!(false));
    assert_eq!(ensure["rename"]["idempotencyKey"], json!("chief-placed-rename-p-7"));
    assert_eq!(ensure["rename"]["params"]["display_name"], json!("Chief on mini"));
    assert_eq!(ensure["makeDefault"]["idempotencyKey"], json!("chief-hosted-default-h-3"));
    let empty =
        op("chiefs_ensure", json!({ "chiefs": [], "chiefName": "Chief", "placedName": "x" }));
    assert_eq!(empty["needsHosted"], json!(true));
    let created = |replayed: bool, before: bool| {
        op("chiefs_created_here", json!({ "replayed": replayed, "sentBefore": before }))["createdHere"].clone()
    };
    assert_eq!(created(false, false), json!(true));
    assert_eq!(created(true, false), json!(false));
    assert_eq!(created(true, true), json!(true));
}

// HomeChiefArchive.

fn record(id: &str, default: bool) -> Value {
    json!({ "id": id, "name": id, "isDefault": default, "rev": 1 })
}

#[test]
fn archive_default_and_offline_wait() {
    let account = json!({ "chiefs": [record("d", true), record("x", false)], "listed": true });
    assert_eq!(
        op("archive_plan", json!({ "id": "d", "account": account })),
        json!({ "kind": "waits" })
    );
    let call_x = op("archive_plan", json!({ "id": "x", "account": account }));
    assert_eq!(call_x["kind"], json!("call"));
    assert_eq!(call_x["record"]["id"], json!("x"));
    let offline = op("archive_plan", json!({ "id": "x", "account": { "listed": false } }));
    assert_eq!(offline, json!({ "kind": "waits" }));
    let unknown = op("archive_plan", json!({ "id": "zz", "account": account }));
    assert_eq!(unknown, json!({ "kind": "refused", "reason": null }));
    let gone =
        op("archive_plan", json!({ "id": "g", "account": { "gone": ["g"], "listed": true } }));
    assert_eq!(gone, json!({ "kind": "done", "dropped": false }));
}

#[test]
fn archive_replies() {
    let after = |reply: Value, attempt: u32| {
        op("archive_after", json!({ "reply": reply, "attempt": attempt }))
    };
    assert_eq!(after(json!({ "kind": "archived" }), 0), json!({ "kind": "done", "dropped": true }));
    assert_eq!(after(json!({ "kind": "notFound" }), 0), json!({ "kind": "done", "dropped": true }));
    assert_eq!(after(json!({ "kind": "conflict" }), 0), json!({ "kind": "reread" }));
    assert_eq!(after(json!({ "kind": "conflict" }), 1), json!({ "kind": "waits" }));
    assert_eq!(after(json!({ "kind": "unreachable" }), 0), json!({ "kind": "waits" }));
    let refused = after(json!({ "kind": "refused", "message": "refused: policy.denied" }), 0);
    assert_eq!(refused, json!({ "kind": "refused", "reason": "refused: policy.denied" }));
    let outcome = op("archive_outcome", json!({ "step": refused }));
    assert_eq!(
        outcome["outcome"],
        json!({ "kind": "refused", "reason": "refused: policy.denied" })
    );
    assert_eq!(
        op("archive_outcome", json!({ "step": { "kind": "waits" } }))["outcome"],
        json!({ "kind": "hiddenHere" })
    );
    assert_eq!(
        op("archive_outcome", json!({ "step": { "kind": "reread" } }))["outcome"],
        Value::Null
    );
}

#[test]
fn archive_sync_after_listing() {
    let account =
        json!({ "chiefs": [record("d", true), record("x", false)], "gone": ["g"], "listed": true });
    let sync =
        op("archive_sync", json!({ "hidden": ["d", "x", "g", "unknown"], "account": account }));
    assert_eq!(
        sync["sync"],
        json!({ "d": "keep", "x": "archive", "g": "unhide", "unknown": "unhide" })
    );
    let unlisted = op("archive_sync", json!({ "hidden": ["x"], "account": { "listed": false } }));
    assert_eq!(unlisted["sync"], json!({ "x": "skip" }));
}

// HomeMessageRequests.

fn request(id: &str) -> Value {
    json!({ "conversation": id, "inviter": "u", "isGroup": false, "title": null, "preview": "hi", "createdAt": null, "trusted": false })
}

#[test]
fn requests_answer_and_refusal_restore() {
    let taken = op(
        "requests_take",
        json!({ "items": [request("a"), request("b"), request("c")], "conversation": "b" }),
    );
    assert_eq!(taken["items"], json!([request("a"), request("c")]));
    assert_eq!(taken["index"], json!(1));
    let restored = op(
        "requests_restore",
        json!({ "items": taken["items"], "index": taken["index"], "request": taken["request"] }),
    );
    assert_eq!(restored["items"], json!([request("a"), request("b"), request("c")]));
    let listed = op(
        "requests_listed",
        json!({ "listed": [request("a"), request("b")], "answering": ["b"] }),
    );
    assert_eq!(listed["items"], json!([request("a")]));
}

#[test]
fn requests_reads_coalesce() {
    let step = |state: Value, event: &str| {
        op("requests_read_step", json!({ "state": state, "event": event }))
    };
    let first = step(json!({}), "refresh");
    assert_eq!(first["read"], json!(true));
    let again = step(first["state"].clone(), "refresh");
    assert_eq!(again, json!({ "state": { "reading": true, "again": true }, "read": false }));
    let more = step(again["state"].clone(), "readEnded");
    assert_eq!(more["read"], json!(true));
    let idle = step(more["state"].clone(), "readEnded");
    assert_eq!(idle, json!({ "state": { "reading": false, "again": false }, "read": false }));
}

// HomeCloudServer.

#[test]
fn server_rules() {
    let hosted = op("server_rules", json!({ "server": { "kind": "hosted" } }));
    assert_eq!(hosted, json!({ "sendsToken": true, "url": null }));
    let own = op(
        "server_rules",
        json!({ "server": { "kind": "selfHosted", "url": "http://mini:7320" } }),
    );
    assert_eq!(own, json!({ "sendsToken": false, "url": "http://mini:7320" }));
}

// CloudHomeSource+Subscriptions.

#[test]
fn subscriptions_evict_least_recent() {
    let sub = |state: Value, c: &str| {
        op(
            "subs_subscribe",
            json!({ "state": state, "conversation": c, "generation": 1, "max": 2 }),
        )
    };
    let a = sub(json!({ "generation": 1 }), "a");
    assert_eq!(a["subscribe"], json!(true));
    let b = sub(a["state"].clone(), "b");
    let again = sub(b["state"].clone(), "a");
    assert_eq!(again["subscribe"], json!(false));
    assert_eq!(again["state"]["recent"], json!(["b", "a"]));
    let c = sub(again["state"].clone(), "c");
    assert_eq!(c["unsubscribe"], json!(["b"]));
    assert_eq!(c["state"]["recent"], json!(["a", "c"]));
    let stale =
        op("subs_subscribe", json!({ "state": c["state"], "conversation": "d", "generation": 0 }));
    assert_eq!(stale["subscribe"], json!(false));
}

#[test]
fn subscriptions_reply_and_failure() {
    let state =
        json!({ "generation": 1, "targets": { "a": { "state": "connecting" } }, "recent": ["a"] });
    let live = op(
        "subs_replied",
        json!({ "state": state, "conversation": "a", "generation": 1, "replyState": "live", "account": "abc", "identityCloudId": "user_abc" }),
    );
    assert_eq!(live["live"], json!(true));
    assert_eq!(live["state"]["targets"]["a"]["state"], json!("live"));
    let other = op(
        "subs_replied",
        json!({ "state": state, "conversation": "a", "generation": 1, "replyState": "live", "account": "zzz", "identityCloudId": "user_abc" }),
    );
    assert_eq!(other["live"], json!(false));
    let evented =
        json!({ "generation": 1, "targets": { "a": { "state": "closed", "fromEvent": true } } });
    let late = op(
        "subs_replied",
        json!({ "state": evented, "conversation": "a", "generation": 1, "replyState": "live" }),
    );
    assert_eq!(late["state"]["targets"]["a"]["state"], json!("closed"));
    let failed = op("subs_failed", json!({ "state": state, "conversation": "a", "generation": 1 }));
    assert_eq!(failed, json!({ "generation": 1, "targets": {}, "recent": [] }));
}

#[test]
fn subscriptions_edit_gate() {
    let gate = |target: Value, closed: bool| {
        op("subs_editable", json!({ "target": target, "closed": closed }))
    };
    assert_eq!(
        gate(json!("live"), false),
        json!({ "degraded": false, "subscribe": false, "error": null })
    );
    assert_eq!(gate(json!("live"), true)["error"], json!("notAuthorized"));
    assert_eq!(
        gate(Value::Null, false),
        json!({ "degraded": true, "subscribe": true, "error": "ownerUnreachable" })
    );
    assert_eq!(gate(json!("connecting"), false)["subscribe"], json!(false));
}

// CloudHomeSource+EditEcho.

fn echo(state: Value, event: Value) -> (Value, Value) {
    let out = op("echo_step", json!({ "state": state, "event": event }));
    (out["state"].clone(), out["effects"].clone())
}

#[test]
fn edit_echo_holds_until_echo() {
    let (s, fx) = echo(
        json!({ "generation": 1 }),
        json!({ "kind": "begin", "conversation": "a", "generation": 1 }),
    );
    assert_eq!(fx, json!([{ "kind": "cancelDeadline", "conversation": "a" }]));
    let (s, fx) = echo(
        s,
        json!({ "kind": "finish", "conversation": "a", "generation": 1, "committedAt": 5 }),
    );
    assert_eq!(fx, json!([{ "kind": "scheduleDeadline", "conversation": "a", "afterMs": 30000 }]));
    let (s, fx) = echo(s, json!({ "kind": "echoed", "conversation": "a", "rev": 4 }));
    assert_eq!(fx, json!([]));
    let (s, fx) = echo(s, json!({ "kind": "echoed", "conversation": "a", "rev": 5 }));
    assert_eq!(fx, json!([{ "kind": "endSubscription", "conversation": "a" }]));
    assert_eq!(s["holds"], json!({}));
}

#[test]
fn edit_echo_refusal_viewed_and_deadline() {
    let begun = json!({ "generation": 1, "holds": { "a": { "inFlight": 1 } } });
    let (_, fx) = echo(
        begun.clone(),
        json!({ "kind": "finish", "conversation": "a", "generation": 1, "final": true }),
    );
    assert_eq!(fx, json!([{ "kind": "endSubscription", "conversation": "a" }]));
    let viewed = json!({ "generation": 1, "holds": { "a": { "inFlight": 1 } }, "viewed": ["a"] });
    let (s, fx) = echo(
        viewed,
        json!({ "kind": "finish", "conversation": "a", "generation": 1, "committedAt": 2 }),
    );
    assert_eq!(fx, json!([]));
    assert_eq!(s["holds"], json!({}));
    let two = json!({ "generation": 1, "holds": { "a": { "inFlight": 2 } } });
    let (s, fx) = echo(
        two,
        json!({ "kind": "finish", "conversation": "a", "generation": 1, "committedAt": 2 }),
    );
    assert_eq!(fx, json!([]));
    let (_, fx) = echo(s, json!({ "kind": "deadline", "conversation": "a", "generation": 1 }));
    assert_eq!(fx, json!([]), "an edit still in flight keeps the hold");
    let idle = json!({ "generation": 1, "holds": { "a": { "awaited": 9 } } });
    let (_, fx) =
        echo(idle.clone(), json!({ "kind": "deadline", "conversation": "a", "generation": 1 }));
    assert_eq!(fx, json!([{ "kind": "endSubscription", "conversation": "a" }]));
    let (_, fx) = echo(idle, json!({ "kind": "deadline", "conversation": "a", "generation": 2 }));
    assert_eq!(fx, json!([]));
    let (_, fx) = echo(begun, json!({ "kind": "finish", "conversation": "a", "generation": 2 }));
    assert_eq!(fx, json!([]));
}
