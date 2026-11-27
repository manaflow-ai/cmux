//! The menu bar menu and the profile menu: the cases the app's Swift tests checked against the
//! Swift specs (`MenuBarMenuSpecTests`), row for row, in English and in another language.

use cmux_action_catalog::ffi::call;
use cmux_action_catalog::status_menus::{
    CHAT_LIMIT, COMPUTER_USE_SESSION_LIMIT, MENU_BAR_ACTION_IDS, Strings, menu_bar_items,
    profile_menu,
};
use serde_json::{Value, json};

fn everything(_: &str) -> bool {
    true
}

fn items(state: Value) -> Vec<Value> {
    menu_bar_items(&state, &Strings::new(""), &everything)
}

/// The Swift test's short names: `-`, `info:text`, an action id, `setting:key:text`,
/// `header:title`, `chat:id`, `command:name("target")`, `id@session`, `computerUse:app`.
fn ids(items: &[Value]) -> Vec<String> {
    items
        .iter()
        .map(|row| {
            let (tag, body) = row.as_object().unwrap().iter().next().unwrap();
            let field = |key: &str| body[key].as_str().unwrap_or("").to_owned();
            match tag.as_str() {
                "separator" => "-".into(),
                "info" => format!("info:{}", field("text")),
                "action" => field("id"),
                "setting" => format!("setting:{}:{}", field("key"), field("text")),
                "header" => format!("header:{}", body.as_str().unwrap()),
                "chat" => format!("chat:{}", field("id")),
                "command" => format!("command:{}(\"{}\")", field("command"), field("target")),
                "sessionAction" => format!("{}@{}", field("id"), field("session")),
                "computerUse" => format!("computerUse:{}", field("app")),
                other => panic!("unknown row {other}"),
            }
        })
        .collect()
}

fn submenu(row: &Value) -> Vec<Value> {
    row["computerUse"]["items"].as_array().unwrap().clone()
}

#[test]
fn signed_out_order() {
    let ids = ids(&items(json!({})));
    assert_eq!(
        ids,
        [
            "palette.auth.signIn",
            "-",
            "showMainWindow",
            "newTab",
            "home.show",
            "home.messageChiefPet",
            "palette.quickAgentChat",
            "-",
            "sendFeedback",
            "help.documentation",
            "help.troubleshooting",
            "-",
            "help.discord",
            "help.followOnX",
            "help.github",
            "updates.whatsNew",
            "-",
            "about",
            "palette.checkForUpdates",
            "openSettings",
            "-",
            "help.revealLogs",
            "help.copyLogs",
            "-",
            "quit",
        ]
    );
    assert!(!ids.iter().any(|id| id.to_lowercase().contains("slack")));
}

#[test]
fn signed_in_shows_who_and_sign_out() {
    let items = items(
        json!({ "account": { "lines": ["Ada Lovelace", "ada@example.com"], "team": "Manaflow", "teamSymbol": "person.2" } }),
    );
    let ids = ids(&items);
    assert_eq!(ids[..4], ["info:Ada Lovelace", "info:ada@example.com", "openTeamPicker", "-"]);
    assert_eq!(items[0], json!({ "info": { "text": "Ada Lovelace", "avatar": true } }));
    assert_eq!(items[1], json!({ "info": { "text": "ada@example.com", "avatar": false } }));
    assert_eq!(
        items[2],
        json!({ "action": { "id": "openTeamPicker", "title": "Manaflow", "symbol": "person.2" } })
    );
    assert_eq!(ids[ids.len() - 2..], ["palette.auth.signOut", "quit"]);
    assert!(!ids.contains(&"palette.auth.signIn".to_owned()));
}

#[test]
fn agent_status() {
    let busy = items(json!({ "agentsWorking": 3, "agentsNeedingInput": 1 }));
    let ids = ids(&busy);
    let start = ids.iter().position(|id| id == "-").unwrap() + 1;
    assert_eq!(
        ids[start..start + 3],
        ["info:Agents working: 3", "agent.jumpToNextNeedingInput", "-"]
    );
    assert_eq!(
        busy[start + 1],
        json!({ "action": { "id": "agent.jumpToNextNeedingInput", "title": "Needs input: 1", "symbol": "exclamationmark.bubble" } })
    );
    assert_eq!(
        busy[start],
        json!({ "info": { "text": "Agents working: 3", "symbol": "circle.dotted", "avatar": false } })
    );
    let idle = menu_ids(json!({}));
    assert!(!idle.contains(&"agent.jumpToNextNeedingInput".to_owned()));
    assert!(!idle.iter().any(|id| id.starts_with("info:")));
}

fn menu_ids(state: Value) -> Vec<String> {
    ids(&items(state))
}

#[test]
fn keeping_awake_leads_the_agents_section() {
    let all = items(
        json!({ "agentsWorking": 2, "keepingAwake": { "commands": 1, "setting": "sessions.keepAwake" } }),
    );
    let ids = ids(&all);
    let start = ids.iter().position(|id| id == "-").unwrap() + 1;
    assert_eq!(
        ids[start..start + 4],
        [
            "setting:sessions.keepAwake:Keeping Mac awake",
            "info:Commands running: 1",
            "info:Agents working: 2",
            "-"
        ]
    );
    assert_eq!(
        all[start],
        json!({ "setting": { "text": "Keeping Mac awake", "key": "sessions.keepAwake", "symbol": "cup.and.saucer" } })
    );
    let agents_only = menu_ids(
        json!({ "agentsWorking": 1, "keepingAwake": { "commands": 0, "setting": "sessions.keepAwake" } }),
    );
    assert!(agents_only.contains(&"setting:sessions.keepAwake:Keeping Mac awake".to_owned()));
    assert!(!agents_only.iter().any(|id| id.starts_with("info:Commands running")));
    let phone =
        menu_ids(json!({ "keepingAwake": { "commands": 0, "setting": "phone.keepAwake" } }));
    assert!(phone.contains(&"setting:phone.keepAwake:Keeping Mac awake".to_owned()));
    let manual = menu_ids(json!({ "keepingAwake": { "commands": 0 } }));
    assert!(manual.contains(&"info:Keeping Mac awake".to_owned()));
    let none = menu_ids(json!({ "agentsWorking": 1, "keepingAwake": null }));
    assert!(!none.iter().any(|id| id.starts_with("setting:")));
}

#[test]
fn update_ready_offers_restart() {
    let items = items(json!({ "updateReady": true }));
    let ids = ids(&items);
    assert!(!ids.contains(&"palette.checkForUpdates".to_owned()));
    let index = ids.iter().position(|id| id == "palette.applyUpdateIfAvailable").unwrap();
    assert_eq!(ids[index - 1], "about");
    assert_eq!(
        items[index],
        json!({ "action": { "id": "palette.applyUpdateIfAvailable", "title": "Restart to Update", "symbol": "arrow.down.circle.fill" } })
    );
}

#[test]
fn unbound_rows_and_empty_sections_are_left_out() {
    let bound = ["showMainWindow", "help.discord", "quit"];
    let rows = menu_bar_items(&json!({}), &Strings::new(""), &|id| bound.contains(&id));
    assert_eq!(ids(&rows), ["showMainWindow", "-", "help.discord", "-", "quit"]);
    // A setting row needs Settings… bound.
    let state = json!({ "keepingAwake": { "commands": 0, "setting": "sessions.keepAwake" } });
    let without = menu_bar_items(&state, &Strings::new(""), &|id| id == "quit");
    assert_eq!(ids(&without), ["quit"]);
}

fn chats(count: usize) -> Vec<Value> {
    (1..=count)
        .map(|n| json!({ "id": format!("c{n}"), "title": format!("Chat {n}"), "harness": "codex" }))
        .collect()
}

/// The app caps a list before it sends it (`MenuBarMenuState.Chats(_:limit:)`).
fn capped(list: Vec<Value>) -> Value {
    let more = list.len().saturating_sub(CHAT_LIMIT);
    json!({ "shown": list.into_iter().take(CHAT_LIMIT).collect::<Vec<_>>(), "more": more })
}

#[test]
fn computer_use_then_unread_then_running_on_top() {
    let state = json!({
        "computerUse": { "sessions": [
            { "id": "s1", "agent": "Claude Code", "appName": "Calculator", "bundleID": "com.apple.calculator", "acting": true, "stopped": false },
            { "id": "s2", "agent": "Codex", "acting": false, "stopped": false },
        ] },
        "unread": capped(chats(2)),
        "running": capped(chats(10)),
    });
    let menu = items(state);
    let ids = ids(&menu);
    assert_eq!(
        ids[..16],
        [
            "computerUse:Calculator",
            "-",
            "header:Unread",
            "chat:c1",
            "chat:c2",
            "-",
            "header:Running",
            "chat:c1",
            "chat:c2",
            "chat:c3",
            "chat:c4",
            "chat:c5",
            "chat:c6",
            "chat:c7",
            "chat:c8",
            "search.chats",
        ]
    );
    assert_eq!((ids[16].as_str(), ids[17].as_str()), ("-", "palette.auth.signIn"));
    assert_eq!(
        menu[15],
        json!({ "action": { "id": "search.chats", "title": "More…", "symbol": "ellipsis" } })
    );
    assert_eq!(menu[3], json!({ "chat": { "id": "c1", "title": "Chat 1", "harness": "codex" } }));
    assert_eq!(menu[0]["computerUse"]["bundleID"], "com.apple.calculator");
    let sub = submenu(&menu[0]);
    assert_eq!(
        self::ids(&sub),
        [
            "info:Claude Code in Calculator",
            "computerUseStop@s1",
            "command:computerUseShowCursor(\"s1\")",
            "computerUseFocus@s1",
            "-",
            "info:Codex",
            "computerUseStop@s2",
            "command:computerUseShowCursor(\"s2\")",
            "computerUseFocus@s2",
            "-",
            "computerUseFocusCallingTerminal",
            "computerUseStop",
            "-",
            "agentActivity.open",
        ]
    );
    assert_eq!(
        sub[0],
        json!({ "info": { "text": "Claude Code in Calculator", "symbol": "cursorarrow.motionlines", "avatar": false } })
    );
    assert_eq!(
        sub[1],
        json!({ "sessionAction": { "id": "computerUseStop", "session": "s1", "title": "Stop", "symbol": "stop.circle" } })
    );
    assert_eq!(
        sub[2],
        json!({ "command": { "command": "computerUseShowCursor", "target": "s1", "title": "Show Cursor", "symbol": "scope" } })
    );
    assert_eq!(
        sub[3],
        json!({ "sessionAction": { "id": "computerUseFocus", "session": "s1", "title": "Show Window", "symbol": "macwindow" } })
    );
    assert_eq!(
        sub[5],
        json!({ "info": { "text": "Codex", "symbol": "cursorarrow", "avatar": false } })
    );
    assert_eq!(
        sub[11],
        json!({ "action": { "id": "computerUseStop", "title": "Stop All Agents", "symbol": "stop.circle" } })
    );

    let many: Vec<Value> =
        (1..=8).map(|n| json!({ "id": format!("s{n}"), "appName": format!("App {n}") })).collect();
    let rows = items(json!({ "computerUse": { "sessions": many } }));
    assert_eq!(rows[0]["computerUse"]["app"], "App 1");
    let infos = submenu(&rows[0]).iter().filter(|row| row.get("info").is_some()).count();
    assert_eq!(infos, COMPUTER_USE_SESSION_LIMIT);
    let anonymous = items(json!({ "computerUse": { "sessions": [{ "id": "x" }] } }));
    assert_eq!(submenu(&anonymous[0])[0]["info"]["text"], "An agent");
}

#[test]
fn new_sections_hide_when_empty() {
    let ids = menu_ids(json!({}));
    assert!(!ids.iter().any(|id| id.starts_with("header:")
        || id.starts_with("chat:")
        || id.starts_with("computerUse:")));
    let idle = items(json!({ "computerUse": { "sessions": [] } }));
    assert_eq!(
        idle[0],
        json!({ "computerUse": { "items": [
        { "action": { "id": "agentActivity.open", "symbol": "cursorarrow.click.2" } },
        { "action": { "id": "palette.computerUse.setup", "symbol": "gear" } },
    ] } })
    );
    let bound = ["computerUseStop", "quit"];
    let some = menu_bar_items(
        &json!({ "computerUse": { "sessions": [{ "id": "s" }] } }),
        &Strings::new(""),
        &|id| bound.contains(&id),
    );
    assert_eq!(
        self::ids(&submenu(&some[0])),
        [
            "info:An agent",
            "computerUseStop@s",
            "command:computerUseShowCursor(\"s\")",
            "-",
            "computerUseStop"
        ]
    );
}

#[test]
fn a_stopped_session_offers_resume() {
    let rows = items(json!({ "computerUse": { "sessions": [
        { "id": "s1", "agent": "Claude Code", "appName": "Notes", "acting": false, "stopped": true },
    ] } }));
    let sub = submenu(&rows[0]);
    assert_eq!(
        ids(&sub[..4]),
        [
            "info:Claude Code in Notes (Stopped)",
            "command:computerUseResume(\"s1\")",
            "command:computerUseShowCursor(\"s1\")",
            "computerUseFocus@s1",
        ]
    );
    assert_eq!(
        sub[0],
        json!({ "info": { "text": "Claude Code in Notes (Stopped)", "symbol": "stop.circle", "avatar": false } })
    );
    assert_eq!(
        sub[1],
        json!({ "command": { "command": "computerUseResume", "target": "s1", "title": "Resume", "symbol": "play.circle" } })
    );
}

/// The translated titles are the string catalog's, with the arguments where the language puts them.
#[test]
fn titles_are_translated() {
    let state = json!({
        "agentsWorking": 3,
        "computerUse": { "sessions": [{ "id": "s1", "agent": "Claude Code", "appName": "Notes", "stopped": true }] },
    });
    let ja = menu_bar_items(&state, &Strings::new("ja"), &everything);
    assert_eq!(submenu(&ja[0])[0]["info"]["text"], "Notes の Claude Code（停止中）");
    assert!(ids(&ja).contains(&"info:作業中のエージェント: 3".to_owned()));
    assert!(ids(&ja).contains(&"palette.auth.signIn".to_owned()));
    let sign_in = ja.iter().find(|row| row["action"]["id"] == "palette.auth.signIn").unwrap();
    assert_eq!(sign_in["action"]["title"], "cmux にサインイン…");
    assert_eq!(profile_menu(&Strings::new("ja-JP"))["submenus"][0]["title"], "ブックマーク");
}

/// Every action a row can run is in the list the app asks its registry about.
#[test]
fn every_row_action_is_listed() {
    let state = json!({
        "account": { "lines": ["A"], "team": "T", "teamSymbol": "person.2" },
        "agentsNeedingInput": 1,
        "updateReady": true,
        "unread": { "shown": chats(1), "more": 3 },
        "computerUse": { "sessions": [{ "id": "s" }] },
    });
    let mut rows = items(state);
    rows.extend(items(json!({ "computerUse": { "sessions": [] } })));
    rows.extend(items(json!({})));
    let mut seen = Vec::new();
    fn walk(rows: &[Value], seen: &mut Vec<String>) {
        for row in rows {
            for tag in ["action", "sessionAction"] {
                if let Some(id) = row[tag]["id"].as_str() {
                    seen.push(id.to_owned());
                }
            }
            if let Some(items) = row["computerUse"]["items"].as_array() {
                walk(items, seen);
            }
        }
    }
    walk(&rows, &mut seen);
    for id in seen {
        assert!(MENU_BAR_ACTION_IDS.contains(&id.as_str()), "{id}");
    }
}

#[test]
fn profile_menu_rows() {
    let menu = profile_menu(&Strings::new(""));
    assert_eq!(
        menu["profileActions"],
        json!([
            "browserProfile.rename",
            "browserProfile.setColor",
            "browserProfile.setIcon",
            "browserProfile.manageExtensions"
        ])
    );
    let keys: Vec<&str> =
        menu["submenus"].as_array().unwrap().iter().map(|s| s["key"].as_str().unwrap()).collect();
    assert_eq!(keys, ["bookmarks", "downloads", "extensions", "history", "developers"]);
    assert_eq!(
        menu["submenus"][3],
        json!({ "key": "history", "title": "History", "symbol": "clock.arrow.circlepath",
                "actions": ["history.show", "recentlyClosed", "history.reopen", "history.clear"] })
    );
    assert_eq!(
        menu["chief"],
        json!({ "action": "home.openChief", "title": "Show Chief", "symbol": "sparkles" })
    );
    assert_eq!(menu["settings"], json!({ "action": "openSettings", "symbol": "gear" }));
    assert_eq!(
        menu["updates"],
        json!({ "action": "palette.checkForUpdates", "symbol": "arrow.down.circle" })
    );
    assert_eq!(
        menu["account"],
        json!([{ "action": "accounts.show", "symbol": "person.crop.circle" },
               { "action": "palette.openCloudPane", "title": "Cloud", "symbol": "cloud" }])
    );
    assert_eq!(
        menu["creation"],
        json!([{ "action": "newTab.default", "symbol": "plus" },
               { "action": "newIncognitoWindow", "title": "Incognito Window", "symbol": "eyeglasses" }])
    );
    assert_eq!(menu["chiefPetSetting"], "home.chiefPetEnabled");
}

/// The C ABI's one JSON call answers each op.
#[test]
fn call_answers_each_op() {
    let reply = |request: Value| -> Value {
        serde_json::from_str(&call(request.to_string().as_bytes())).unwrap()
    };
    let menu =
        reply(json!({ "op": "menu_bar_items", "state": {}, "bound": ["quit"], "locale": "" }));
    assert_eq!(menu, json!({ "items": [{ "action": { "id": "quit", "symbol": "power" } }] }));
    assert_eq!(
        reply(json!({ "op": "menu_bar_action_ids" }))["ids"].as_array().unwrap().len(),
        MENU_BAR_ACTION_IDS.len()
    );
    assert_eq!(
        reply(json!({ "op": "profile_menu", "locale": "de" }))["submenus"][0]["title"],
        "Lesezeichen"
    );
    assert_eq!(
        reply(json!({ "op": "when_parse", "text": "!a" })),
        json!({ "clause": { "not": { "has": "a" } } })
    );
    assert_eq!(
        reply(json!({ "op": "when_parse", "text": "(a" })),
        json!({ "error": { "message": "expected )", "offset": 2 } })
    );
    assert_eq!(
        reply(json!({ "op": "when_text", "clause": { "in": ["k", "l"] } })),
        json!({ "text": "k in l" })
    );
    assert!(reply(json!({ "op": "nope" }))["error"].is_string());
    assert!(serde_json::from_str::<Value>(&call(b"not json")).unwrap()["error"].is_string());
}

#[test]
fn c_abi_round_trip() {
    use cmux_action_catalog::ffi::{OK, cmux_action_catalog_call, cmux_action_catalog_reply_free};
    let request = br#"{"op":"when_text","clause":{"has":"a"}}"#;
    let mut reply = std::ptr::null_mut();
    let mut len = 0usize;
    // SAFETY: `request` is a live slice and both out pointers are locals.
    let status =
        unsafe { cmux_action_catalog_call(request.as_ptr(), request.len(), &mut reply, &mut len) };
    assert_eq!(status, OK);
    // SAFETY: on OK the reply is `len` bytes the caller owns until it frees them.
    let text =
        String::from_utf8(unsafe { std::slice::from_raw_parts(reply, len) }.to_vec()).unwrap();
    assert_eq!(text, r#"{"text":"a"}"#);
    // SAFETY: exactly what the call wrote, freed once.
    unsafe { cmux_action_catalog_reply_free(reply, len) };
}

/// Signed out on a dev build: the line under Sign In names the backend it signs in to (cmux#46930;
/// Leo: "why is the stuff so weird to log in to dev builds?"); signed in, no such line. The Swift
/// `MenuBarMenuSpecTests.signInNamesItsBackend` case, row for row.
#[test]
fn sign_in_names_its_backend() {
    let line = "Signs in to Development backend · dev-abc.cmux.dev";
    let signed_out = ids(&items(json!({ "signInBackend": line })));
    assert_eq!(
        signed_out[..3],
        ["palette.auth.signIn".to_owned(), format!("info:{line}"), "-".to_owned()]
    );
    let signed_in = ids(&items(json!({ "account": { "lines": ["Ada"] }, "signInBackend": line })));
    assert!(!signed_in.contains(&format!("info:{line}")));
}
