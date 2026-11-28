//! The `inbox` ops against the Swift tests' cases (HomePinnedReorderTests, HomeChatCyclingTests,
//! HomeComposeAndTeamTests, HomeSidebarDragTests, RecoveredWorkspaceMarkerTests,
//! HomeChiefRosterTests, HomeGroupRolesTests), through `ops::call` as Swift calls them.

use cmux_home_rules::ops::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("inbox.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e}"))
}

fn person(id: &str, name: &str) -> Value {
    json!({ "id": id, "kind": "human", "displayName": name, "membership": "active" })
}

fn chief(id: &str, name: &str) -> Value {
    json!({ "id": id, "kind": "agent", "displayName": name, "agentClass": "chief", "membership": "active" })
}

fn row(id: &str, kind: &str, title: &str, ts: f64, participants: Vec<Value>) -> Value {
    json!({ "id": id, "kind": kind, "title": title, "timestamp": ts, "participants": participants })
}

/// HomeChiefRosterTests' fixture: four Chiefs and a DM with Ada.
fn roster_rows() -> Value {
    json!([
        row("conv_local", "chief", "Mux", 5.0, vec![person("me", "Me"), chief("agent_mux", "Mux")]),
        row(
            "conv_hosted",
            "chief",
            "Hosted",
            4.0,
            vec![person("me", "Me"), chief("chief_hosted", "Hosted")]
        ),
        row(
            "conv_placed",
            "chief",
            "Placed",
            3.0,
            vec![person("me", "Me"), chief("chief_placed", "Placed")]
        ),
        row(
            "conv_unii",
            "chief",
            "Unii",
            2.0,
            vec![person("me", "Me"), chief("agent_unii", "Unii")]
        ),
        row("conv_ada", "direct", "Ada", 1.0, vec![person("me", "Me"), person("ada", "Ada")]),
    ])
}

fn empty_pins() -> Value {
    json!({ "pinned": [], "unpinned": [] })
}

#[test]
fn pins_decode_without_positions_and_chiefs_pin_by_default() {
    let split = op("pins_split", json!({ "pins": empty_pins(), "rows": roster_rows() }));
    assert_eq!(split["pinned"], json!(["conv_local", "conv_hosted", "conv_placed", "conv_unii"]));
    assert_eq!(split["rest"], json!(["conv_ada"]));
}

#[test]
fn rest_is_newest_first_ties_by_id() {
    let rows = json!([
        row("b", "direct", "", 1.0, vec![]),
        row("a", "direct", "", 1.0, vec![]),
        row("c", "direct", "", 2.0, vec![]),
    ]);
    let split = op("pins_split", json!({ "pins": empty_pins(), "rows": rows }));
    assert_eq!(split["rest"], json!(["c", "a", "b"]));
}

#[test]
fn unpinning_a_chief_remembers_it_and_pinning_again_clears() {
    let chief_row = row("conv_local", "chief", "Mux", 5.0, vec![]);
    let pins =
        op("pins_set_pinned", json!({ "pins": empty_pins(), "row": chief_row, "on": false }));
    assert_eq!(pins["unpinned"], json!(["conv_local"]));
    assert_eq!(op("pins_is_pinned", json!({ "pins": pins, "row": chief_row })), json!(false));
    let pins = op("pins_set_pinned", json!({ "pins": pins, "row": chief_row, "on": true }));
    assert_eq!(pins["pinned"], json!(["conv_local"]));
    assert_eq!(pins["unpinned"], json!([]));
    // Pinning a pinned row changes nothing.
    let again = op("pins_set_pinned", json!({ "pins": pins, "row": chief_row, "on": true }));
    assert_eq!(again, pins);
}

#[test]
fn the_main_chief_leads_until_placed() {
    assert_eq!(
        op("pins_leading", json!({ "pins": empty_pins(), "main": "conv_unii" })),
        json!("conv_unii")
    );
    let placed = op(
        "pins_place",
        json!({ "pins": empty_pins(), "id": "conv_unii", "index": 2, "shown": ["conv_local", "conv_hosted", "conv_placed", "conv_unii"] }),
    );
    assert_eq!(placed["pinned"], json!(["conv_local", "conv_hosted", "conv_unii", "conv_placed"]));
    assert_eq!(op("pins_leading", json!({ "pins": placed, "main": "conv_unii" })), Value::Null);
    // A drop past the end clamps.
    let last = op(
        "pins_place",
        json!({ "pins": empty_pins(), "id": "a", "index": 99, "shown": ["b", "a"] }),
    );
    assert_eq!(last["pinned"], json!(["b", "a"]));
    let arranged = op(
        "pins_arrange",
        json!({ "pins": { "pinned": ["x", "y"], "unpinned": ["y"] }, "order": ["y"], "positions": [7] }),
    );
    assert_eq!(arranged, json!({ "pinned": ["y", "x"], "unpinned": [], "positions": { "y": 7 } }));
}

#[test]
fn sidebar_puts_the_main_chief_first_and_tags_rows() {
    let model = op(
        "sidebar",
        json!({
            "rows": roster_rows(),
            "order": { "kind": "pins", "pins": empty_pins() },
            "me": "me",
            "roster": { "main": "conv_placed", "places": { "conv_hosted": { "kind": "cloud" } } },
            "chiefTags": { "conv_hosted": "Cloud" },
            "chiefNames": { "conv_local": "  Mux Prime " },
        }),
    );
    let pinned: Vec<&str> =
        model["pinned"].as_array().unwrap().iter().map(|i| i["id"].as_str().unwrap()).collect();
    assert_eq!(pinned, ["conv_placed", "conv_local", "conv_hosted", "conv_unii"]);
    let placed = &model["pinned"][0];
    assert_eq!(placed["isMainChief"], json!(true));
    assert_eq!(placed["chief"], json!("chief_placed"));
    assert_eq!(placed["preview"], json!({ "kind": "chiefEmpty" }));
    assert_eq!(model["pinned"][1]["title"], json!("Mux Prime"));
    let hosted = &model["pinned"][2];
    assert_eq!(hosted["listBadge"], json!({ "kind": "tag", "text": "Cloud" }));
    assert_eq!(hosted["place"], json!({ "kind": "cloud" }));
    assert_eq!(
        hosted["accessibility"],
        json!([{ "kind": "title" }, { "kind": "badge" }, { "kind": "time" }])
    );
    assert_eq!(model["rows"][0]["id"], json!("conv_ada"));
    assert_eq!(model["rows"][0]["avatars"], json!([{ "initials": "A", "seed": "ada" }]));
}

fn team_contacts() -> Value {
    json!([
        { "id": "ada", "name": "Ada", "source": "team" },
        { "id": "bo", "name": "Bo", "source": "team" },
        { "id": "me", "name": "Me", "source": "team" },
    ])
}

#[test]
fn teammates_without_a_dm_are_listed() {
    let rows =
        json!([row("conv_bo", "direct", "Bo", 1.0, vec![person("me", "Me"), person("bo", "Bo")])]);
    let model = op(
        "sidebar",
        json!({ "rows": rows, "order": { "kind": "pins", "pins": empty_pins() }, "me": "me", "contacts": team_contacts() }),
    );
    assert_eq!(model["teammates"], json!([{ "id": "ada", "name": "Ada", "source": "team" }]));
    assert_eq!(model["people"], json!([]));
}

#[test]
fn a_search_finds_people_and_lists_no_teammates() {
    let model = op(
        "sidebar",
        json!({ "rows": [], "order": { "kind": "pins", "pins": empty_pins() }, "me": "me", "query": " ada ", "contacts": team_contacts() }),
    );
    assert_eq!(model["people"], json!([{ "id": "ada", "name": "Ada", "source": "team" }]));
    assert_eq!(model["teammates"], json!([]));
}

#[test]
fn two_accounts_of_one_name_list_once() {
    let contacts = json!([
        { "id": "work", "name": "Austin Wang", "source": "team" },
        { "id": "personal", "name": "Austin Wang", "source": "team" },
        { "id": "ada", "name": "Ada", "source": "team" },
    ]);
    let dm = json!([row(
        "conv_w",
        "direct",
        "Austin",
        1.0,
        vec![person("me", "Me"), person("work", "Austin Wang")]
    )]);
    let with_dm = op(
        "sidebar",
        json!({ "rows": dm, "order": { "kind": "pins", "pins": empty_pins() }, "me": "me", "contacts": contacts }),
    );
    assert_eq!(with_dm["teammates"], json!([{ "id": "ada", "name": "Ada", "source": "team" }]));
    let no_dm = op(
        "sidebar",
        json!({ "rows": [], "order": { "kind": "pins", "pins": empty_pins() }, "me": "me", "contacts": contacts }),
    );
    let ids: Vec<&str> =
        no_dm["teammates"].as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["work", "ada"]);
    let search = op(
        "sidebar",
        json!({ "rows": dm, "order": { "kind": "pins", "pins": empty_pins() }, "me": "me", "query": "austin", "contacts": contacts }),
    );
    assert_eq!(
        search["people"],
        json!([{ "id": "personal", "name": "Austin Wang", "source": "team" }])
    );
}

#[test]
fn chat_cycling_wraps_and_numbers() {
    let order = json!(["a", "b", "c", "d", "e"]);
    let n = |current: Value, offset: i64, wrapping: bool| {
        op(
            "sidebar_neighbor",
            json!({ "order": order, "current": current, "offset": offset, "wrapping": wrapping }),
        )
    };
    assert_eq!(n(json!("e"), 1, true), json!("a"));
    assert_eq!(n(json!("a"), -1, true), json!("e"));
    assert_eq!(n(json!("e"), 1, false), Value::Null);
    assert_eq!(n(Value::Null, 1, false), json!("a"));
    assert_eq!(n(json!("zz"), 1, false), json!("a"));
    let num = |number: i64| op("sidebar_number", json!({ "order": order, "number": number }));
    assert_eq!(num(1), json!("a"));
    assert_eq!(num(9), json!("e"));
    assert_eq!(num(6), json!("e"));
    assert_eq!(num(0), json!("a"));
    assert_eq!(op("sidebar_number", json!({ "order": [], "number": 1 })), Value::Null);
    assert_eq!(op("sidebar_neighbor", json!({ "order": [], "offset": 1 })), Value::Null);
}

#[test]
fn unread_puts_the_main_chief_first_and_skips_muted() {
    let pinned = json!([
        { "id": "p1", "unread": 1 },
        { "id": "main", "unread": 2 },
        { "id": "p3", "unread": 3, "muted": true },
    ]);
    let rest = json!([{ "id": "r1" }, { "id": "r2", "unread": 1 }]);
    let unread = op(
        "sidebar_unread",
        json!({ "pinned": pinned, "rest": rest, "unreadMarks": ["r1"], "mainChief": "main" }),
    );
    assert_eq!(unread, json!(["main", "p1", "r1", "r2"]));
}

#[test]
fn sidebar_drag_and_clamp() {
    let drag = |proposed: f64, widest: f64| {
        op("width_drag", json!({ "proposed": proposed, "widest": widest }))
    };
    let (min, full) = (100.0, 188.0);
    let mid = (min + full) / 2.0;
    assert_eq!(drag(250.0, 700.0), json!(250.0));
    assert_eq!(drag(full - 1.0, 700.0), json!(full));
    assert_eq!(drag(mid, 700.0), json!(full));
    assert_eq!(drag(mid - 1.0, 700.0), json!(min));
    assert_eq!(drag(min / 2.0, 700.0), json!(min));
    assert_eq!(drag(min / 2.0 - 1.0, 700.0), json!(0.0));
    assert_eq!(drag(-40.0, 700.0), json!(0.0));
    assert_eq!(drag(900.0, 700.0), json!(700.0));
    assert_eq!(drag(160.0, 150.0), json!(min));
    assert_eq!(op("width_clamp", json!({ "width": 400.0, "window": 400.0 })), json!(min));
    assert_eq!(op("width_clamp", json!({ "width": 328.0, "window": 1200.0 })), json!(328.0));
    assert_eq!(op("width_column_minimum", json!({})), json!(381.0));
}

#[test]
fn recovered_terminals_need_a_first_workspace() {
    let home = json!({ "id": "w_home", "name": "Home", "kind": "home" });
    let need = |workspaces: Value| op("needs_first_workspace", json!({ "workspaces": workspaces }));
    assert_eq!(
        need(json!([home, { "id": "w1", "name": "Shell", "kind": "terminal", "recovered": true }])),
        json!(true)
    );
    assert_eq!(
        need(
            json!([home, { "id": "w1", "name": "Recovered terminals", "kind": "terminal", "recovered": false }])
        ),
        json!(false)
    );
    for name in ["Recovered terminals", "復元されたターミナル"] {
        assert_eq!(
            need(json!([home, { "id": "w1", "name": name, "kind": "terminal" }])),
            json!(true)
        );
    }
    assert_eq!(
        need(json!([
            home,
            { "id": "w1", "name": "Recovered terminals", "kind": "terminal" },
            { "id": "w2", "name": "Mine", "kind": "terminal" },
        ])),
        json!(false)
    );
    assert_eq!(
        op(
            "needs_first_workspace",
            json!({ "workspaces": [{ "id": "w2", "name": "Mine" }], "leftover": ["w2"] })
        ),
        json!(true)
    );
}

#[test]
fn group_roles_tag_all_but_members() {
    for (role, tag) in [
        ("owner", json!("owner")),
        ("admin", json!("admin")),
        ("read_only", json!("readOnly")),
        ("member", Value::Null),
    ] {
        let member = op(
            "group_member",
            json!({ "participant": { "id": "ada", "displayName": "Ada Lovelace", "role": role }, "me": "me" }),
        );
        assert_eq!(member.get("roleTag").cloned().unwrap_or(Value::Null), tag, "{role}");
        assert_eq!(member["initials"], json!("AL"));
    }
}

#[test]
fn sections_and_invites() {
    let invited = json!({ "id": "inv_1", "displayName": "", "membership": "invited", "invitedContact": "x@y.z" });
    let rows = json!([
        row("d1", "direct", "D", 1.0, vec![person("me", "Me"), invited.clone()]),
        row("c1", "chief", "C", 1.0, vec![]),
        { "id": "p1", "kind": "group", "isPinned": true },
        row("m1", "group", "G", 1.0, vec![]),
    ]);
    let lines = op("lines", json!({ "rows": rows }));
    assert_eq!(
        lines,
        json!([
            { "kind": "header", "section": "chiefs" }, { "kind": "row", "id": "c1" },
            { "kind": "header", "section": "pinned" }, { "kind": "row", "id": "p1" },
            { "kind": "header", "section": "messages" }, { "kind": "row", "id": "m1" },
            { "kind": "header", "section": "invited" }, { "kind": "row", "id": "d1" },
        ])
    );
    assert_eq!(
        op("pending_invites", json!({ "rows": rows })),
        json!([{ "conversation": "d1", "contact": "x@y.z" }])
    );
    // An internal id never names anyone.
    assert_eq!(
        op(
            "invite_waiting",
            json!({ "participants": [{ "id": "inv_1", "displayName": "inv_abc", "membership": "invited" }], "me": "me" })
        ),
        json!({ "kind": "invited" })
    );
    assert_eq!(
        op("invite_waiting", json!({ "participants": [invited], "me": "me" })),
        json!({ "kind": "waitingFor", "name": "x@y.z" })
    );
}

#[test]
fn contacts_merge_team_by_name_then_connections_then_agents() {
    let rows = roster_rows();
    let connections = op("contacts_connections", json!({ "rows": rows, "me": "me" }));
    assert_eq!(connections, json!([{ "id": "ada", "name": "Ada", "source": "connection" }]));
    let agents = op("contacts_agents", json!({ "rows": rows, "me": "me" }));
    assert_eq!(agents.as_array().unwrap().len(), 4);
    let merged = op(
        "contacts_merged",
        json!({
            "team": [{ "id": "z", "name": "zed 10", "source": "team" }, { "id": "y", "name": "Zed 9", "source": "team" }],
            "connections": [{ "id": "z", "name": "dup", "source": "connection" }, { "id": "ada", "name": "Ada", "source": "connection" }],
            "agents": agents,
        }),
    );
    let ids: Vec<&str> =
        merged.as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["y", "z", "ada", "agent_mux", "chief_hosted", "chief_placed", "agent_unii"]);
    let members = op(
        "roster_group_members",
        json!({ "contacts": merged, "rows": rows, "main": "conv_unii", "me": "me" }),
    );
    let ids: Vec<&str> =
        members.as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["agent_unii", "agent_mux", "chief_hosted", "chief_placed", "y", "z", "ada"]);
    assert_eq!(op("contacts_without_dm", json!({ "contacts": merged, "rows": rows })), json!(6));
}

#[test]
fn row_text_kinds() {
    let day = 86_400.0;
    let now = 100.0 * day + 3600.0;
    let t = |time: f64| op("list_time", json!({ "time": time, "now": now }));
    assert_eq!(t(now - 60.0), json!("time"));
    assert_eq!(t(now - day), json!("yesterday"));
    assert_eq!(t(now - 3.0 * day), json!("weekday"));
    assert_eq!(t(now - 7.0 * day), json!("date"));
    assert_eq!(t(-62_135_769_600.0), json!("none"));
    let preview = op("row_preview", json!({ "preview": "a\nb" }));
    assert_eq!(preview, json!({ "kind": "text", "text": "a b", "isReply": false }));
    let reaction = op(
        "row_preview",
        json!({
            "preview": "x",
            "last": { "strippedPreview": "x", "strippedPlainText": "hi\nthere", "reaction": { "author": "ada", "kind": "👍" } },
            "participants": [person("ada", "Ada")],
            "me": "me",
        }),
    );
    assert_eq!(
        reaction,
        json!({ "kind": "reaction", "byMe": false, "name": "Ada", "reaction": "👍", "quoted": "hi there" })
    );
    let reply = op(
        "row_preview",
        json!({ "preview": "**x**", "last": { "strippedPreview": "x", "isReply": true } }),
    );
    assert_eq!(reply, json!({ "kind": "text", "text": "x", "isReply": true }));
}

#[test]
fn chief_default_place_and_glance() {
    let d = |setting: Value, running: bool| {
        op("chief_default", json!({ "setting": setting, "localRunning": running }))
    };
    assert_eq!(d(json!("bogus"), true), json!({ "default": "auto", "prefersLocal": true }));
    assert_eq!(d(Value::Null, false)["prefersLocal"], json!(false));
    assert_eq!(d(json!("local"), false)["prefersLocal"], json!(true));
    assert_eq!(d(json!("hosted"), true)["prefersLocal"], json!(false));
    assert_eq!(
        op("chief_place", json!({ "place": { "kind": "server", "name": "" } })),
        json!({ "kind": "unnamedServer" })
    );
    assert_eq!(
        op("chief_place", json!({ "place": { "kind": "server", "name": "box" } })),
        json!({ "kind": "server", "name": "box" })
    );
    let shortlist = op(
        "agent_shortlist",
        json!({ "statuses": ["working", "done", "needsYou", "failed", "idle", "needsYou", "working"] }),
    );
    assert_eq!(shortlist, json!([2, 5, 3, 1, 4]));
    assert_eq!(op("agent_indicator", json!({ "status": "needsYou" })), json!("waiting"));
}

fn sheet_step(sheet: &mut Value, event: Value) -> Value {
    let out = op("group_sheet_step", json!({ "sheet": sheet, "event": event }));
    *sheet = out["sheet"].clone();
    out["effects"].clone()
}

fn router_step(state: &mut Value, event: Value) -> Value {
    let out = op("router_step", json!({ "state": state, "event": event }));
    *state = out["state"].clone();
    out["effects"].clone()
}

#[test]
fn group_sheet_runs_one_action_and_clears_on_add() {
    let addable = json!([{ "id": "ada", "name": "Ada", "source": "team" }, { "id": "bo", "name": "Bo", "source": "team" }]);
    let mut sheet = op("group_sheet_new", json!({ "title": "Crew", "addable": addable }));
    assert_eq!(sheet_step(&mut sheet, json!({ "kind": "rename" })), json!([]));
    sheet_step(&mut sheet, json!({ "kind": "toggle", "id": "bo" }));
    sheet_step(&mut sheet, json!({ "kind": "toggle", "id": "ada" }));
    sheet_step(&mut sheet, json!({ "kind": "setAdding", "on": true }));
    assert_eq!(
        sheet_step(&mut sheet, json!({ "kind": "addChosen" })),
        json!([{ "kind": "add", "people": ["bo", "ada"], "names": "Ada, Bo" }])
    );
    sheet_step(&mut sheet, json!({ "kind": "setDraft", "text": "Crew 2" }));
    assert_eq!(
        sheet_step(&mut sheet, json!({ "kind": "rename" })),
        json!([]),
        "one action at a time"
    );
    sheet_step(
        &mut sheet,
        json!({ "kind": "finished", "outcome": { "succeeded": true, "message": "Added" } }),
    );
    assert_eq!(sheet["chosen"], json!([]));
    assert_eq!(sheet["isAdding"], json!(false));
    assert_eq!(sheet["status"], json!("Added"));
    assert_eq!(
        sheet_step(&mut sheet, json!({ "kind": "rename" })),
        json!([{ "kind": "rename", "name": "Crew 2" }])
    );
    sheet_step(
        &mut sheet,
        json!({ "kind": "finished", "outcome": { "message": "No", "notReachable": true } }),
    );
    assert_eq!(sheet["offersInvite"], json!(true));
    // An update moves an unedited draft along and prunes the chosen.
    sheet_step(&mut sheet, json!({ "kind": "setDraft", "text": "Crew" }));
    sheet_step(&mut sheet, json!({ "kind": "toggle", "id": "bo" }));
    sheet_step(
        &mut sheet,
        json!({ "kind": "update", "title": "Team", "addable": [{ "id": "ada", "name": "Ada", "source": "team" }] }),
    );
    assert_eq!(sheet["nameDraft"], json!("Team"));
    assert_eq!(sheet["chosen"], json!([]));
    sheet_step(&mut sheet, json!({ "kind": "setSearch", "text": " ad " }));
    let view = op("group_sheet_view", json!({ "sheet": sheet }));
    assert_eq!(view["shownAddable"].as_array().unwrap().len(), 1);
    assert_eq!(view["canRename"], json!(false));
}

#[test]
fn router_merges_connections_and_routes_owners() {
    let mut state = json!({});
    assert_eq!(
        router_step(&mut state, json!({ "kind": "cloudConnection", "connection": "online" })),
        json!([{ "kind": "connection", "connection": "online" }])
    );
    // Cloud keeps the merged link online: the daemon coming back is a recovery.
    assert_eq!(
        router_step(&mut state, json!({ "kind": "localConnection", "connection": "online" })),
        json!([{ "kind": "ownerRecovered" }])
    );
    assert_eq!(
        router_step(
            &mut state,
            json!({ "kind": "localInbox", "conversations": [{ "id": "l1", "participants": ["ada"] }], "me": "me", "cloud": ["c1"] })
        ),
        json!([{ "kind": "inbox", "rev": 1 }])
    );
    assert_eq!(
        router_step(&mut state, json!({ "kind": "cloudInbox", "ids": ["c2"], "account": "acct" })),
        json!([{ "kind": "removed", "id": "c1", "rev": 2 }, { "kind": "changed", "id": "c2", "rev": 3 }])
    );
    let route = |state: &Value, intent: Value| {
        op("router_route", json!({ "state": state, "intent": intent, "chief": "agent_mux" }))
    };
    assert_eq!(
        route(&state, json!({ "kind": "createGroup", "ids": ["ada", "agent_mux"] })),
        json!({ "kind": "local" })
    );
    assert_eq!(
        route(&state, json!({ "kind": "createGroup", "ids": ["bo"] })),
        json!({ "kind": "cloud" })
    );
    assert_eq!(
        route(&state, json!({ "kind": "createGroup", "ids": ["ada"], "invites": ["x@y.z"] })),
        json!({ "kind": "cloud" })
    );
    assert_eq!(route(&state, json!({ "kind": "openDirect" })), json!({ "kind": "cloud" }));
    assert_eq!(route(&state, json!({ "kind": "createChief" })), json!({ "kind": "local" }));
    assert_eq!(
        route(&state, json!({ "kind": "other", "conversation": "c2" })),
        json!({ "kind": "cloud" })
    );
    assert_eq!(
        route(&state, json!({ "kind": "other", "conversation": "l1" })),
        json!({ "kind": "local" })
    );
    assert_eq!(route(&state, json!({ "kind": "other" })), json!({ "kind": "local" }));
    assert_eq!(
        route(&state, json!({ "kind": "other", "conversation": "new" })),
        json!({ "kind": "byOwner", "conversation": "new" })
    );
    assert_eq!(
        router_step(&mut state, json!({ "kind": "lookup", "id": "new", "listed": ["new"] })),
        json!([{ "kind": "owner", "owner": "cloud" }])
    );
    assert_eq!(
        router_step(&mut state, json!({ "kind": "lookup", "id": "gone", "listed": [] })),
        json!([{ "kind": "owner", "owner": "local" }])
    );
    // Another account drops the previous one's cloud owners it no longer lists.
    router_step(&mut state, json!({ "kind": "cloudInbox", "ids": [], "account": "other" }));
    assert_eq!(state["owners"], json!({ "l1": "local" }));
    assert_eq!(
        op(
            "router_upload_rejection",
            json!({ "owner": "cloud", "reason": "attachments unsupported" })
        ),
        json!("cloud_attachments_unsupported")
    );
    assert_eq!(op("router_merged_connection", json!({ "local": "offline" })), json!("offline"));
}

#[test]
fn search_folds_case_accents_and_width() {
    let r = json!({ "id": "x", "title": "Café Ｒｅｓｕｍé", "participants": [person("me", "Zoë"), person("p", "Ñandu")] });
    let m = |needle: &str| op("row_matches", json!({ "row": r, "needle": needle, "me": "me" }));
    assert_eq!(m("cafe"), json!(true));
    assert_eq!(m("resume"), json!(true));
    assert_eq!(m("nandu"), json!(true));
    assert_eq!(m("zoe"), json!(false), "my own name is not a match");
    assert_eq!(op("name_key", json!({ "name": "  Ádá " })), json!("ada"));
    let names = op(
        "participant_names",
        json!({ "participants": [{ "id": "a", "displayName": "user_abc123", "invitedContact": "jo-ann smith" }] }),
    );
    assert_eq!(names[0]["visibleName"], json!("jo-ann smith"));
    assert_eq!(names[0]["initials"], json!("JA"));
}
