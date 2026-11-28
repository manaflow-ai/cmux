use super::*;

fn read(name: &str, root: Value) -> Value {
    call("custom.read", &json!({"name": name, "root": root})).unwrap().unwrap()
}

fn messages(answer: &Value) -> Vec<(String, String)> {
    answer["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| {
            (d["path"].as_str().unwrap().to_owned(), d["message"].as_str().unwrap().to_owned())
        })
        .collect()
}

#[test]
fn every_name_reads_an_empty_root_without_diagnostics() {
    for name in NAMES {
        if name == "reduced_backgrounds_notes" {
            continue;
        }
        let answer = read(name, json!({}));
        assert!(answer["diagnostics"].as_array().unwrap().is_empty(), "{name}: {answer}");
    }
}

#[test]
fn a_key_the_schema_lacks_is_one_diagnostic_not_a_crash() {
    let root = json!({});
    let read = Read::new(&root);
    assert!(read.row("no.such.row").is_none());
    assert!(read.choices_of("no.such.row").is_empty());
    let answer = read.finish();
    assert_eq!(
        messages(&answer),
        vec![("no.such.row".to_owned(), "the schema has no such row".to_owned())]
    );
}

#[test]
fn agent_mouse_messages() {
    let answer =
        read("agent_mouse", json!({"browser": {"agentMouse": {"motion": "x", "maxMoveMs": 5}}}));
    assert_eq!(
        messages(&answer),
        vec![
            (
                "browser.agentMouse.motion".to_owned(),
                "expected \"human\" or \"instant\"".to_owned()
            ),
            (
                "browser.agentMouse.maxMoveMs".to_owned(),
                "expected a number from 60 to 1000".to_owned()
            ),
        ]
    );
}

#[test]
fn closed_history_takes_whole_numbers_only() {
    let answer = read(
        "closed_history",
        json!({"history": {"closed": {"maxGroups": 1.5, "maxAgeDays": 30}}}),
    );
    assert_eq!(answer["values"]["maxAgeDays"], 30);
    assert_eq!(messages(&answer).len(), 1);
}

#[test]
fn legacy_values_read_without_diagnostics() {
    let quit = read("quit_behavior", json!({"app": {"quitBehavior": "end"}}));
    assert_eq!(quit["values"]["behavior"], "end-keep-layout");
    let smoothing = read("font_smoothing", json!({"appearance": {"fontSmoothing": "system"}}));
    assert_eq!(smoothing["values"]["mode"], "auto");
}

#[test]
fn home_server_forms() {
    let own =
        read("home_server", json!({"home": {"server": {"selfHosted": "http://a.b.ts.net:7320"}}}));
    assert_eq!(own["values"]["server"]["mode"], "selfHosted");
    let bad = read("home_server", json!({"home": {"server": 3}}));
    assert_eq!(bad["values"]["server"]["mode"], "hosted");
    assert_eq!(messages(&bad).len(), 1);
}

#[test]
fn interface_scale_clamps_and_says_so() {
    let answer = read("interface_scale", json!({"appearance": {"interfaceScale": 3}}));
    assert_eq!(answer["values"]["scale"], 1.25);
    assert_eq!(messages(&answer)[0].1, "expected a scale from 0.9 to 1.25; clamped");
}

#[test]
fn home_server_origins_are_normalised() {
    for (input, origin) in [
        ("http://mini.tail1234.ts.net:7320/", "http://mini.tail1234.ts.net:7320"),
        ("HTTPS://Mini.Tail1234.ts.net", "https://mini.tail1234.ts.net"),
        ("http://100.101.102.103:7320", "http://100.101.102.103:7320"),
    ] {
        let answer = read("home_server", json!({"home": {"server": {"selfHosted": input}}}));
        assert_eq!(answer["values"]["server"]["url"], origin, "{input}");
        assert!(messages(&answer).is_empty());
    }
    assert_eq!(
        read("home_server", json!({"home": {"server": "hosted"}}))["values"]["server"]["mode"],
        "hosted"
    );
}

#[test]
fn home_server_refusals_keep_hosted_and_say_why() {
    for bad in [
        json!(1),
        json!("selfHosted"),
        json!(true),
        json!({"selfHosted": "ftp://mini.tail1234.ts.net"}),
        json!({"selfHosted": "http://mini.tail1234.ts.net/path"}),
        json!({"selfHosted": "http://mini.tail1234.ts.net?x=1"}),
        json!({"selfHosted": "http://user@mini.tail1234.ts.net"}),
        json!({"selfHosted": "not a url"}),
        json!({"selfHosted": 7320}),
        json!({"other": "http://mini.tail1234.ts.net"}),
        json!({"selfHosted": "http://mini.tail1234.ts.net", "extra": "x"}),
    ] {
        let answer = read("home_server", json!({"home": {"server": bad.clone()}}));
        assert_eq!(answer["values"]["server"]["mode"], "hosted", "{bad}");
        assert_eq!(messages(&answer)[0].0, "home.server", "{bad}");
    }
}

#[test]
fn agent_mouse_defaults_and_choices() {
    let absent = read("agent_mouse", json!({}));
    assert_eq!(absent["values"]["motion"], "human");
    assert_eq!(absent["values"]["maxMoveMs"].as_f64(), Some(350.0));
    let chosen = read(
        "agent_mouse",
        json!({"browser": {"agentMouse": {"motion": "instant", "maxMoveMs": 200}}}),
    );
    assert_eq!(chosen["values"]["motion"], "instant");
    assert_eq!(chosen["values"]["maxMoveMs"], 200.0);
}

#[test]
fn verification_autofill_accounts_are_trimmed_lowercased_and_deduped() {
    let root = json!({"browser": {"verificationAutofill": {"accounts": [" Lawrence@cmux.com ", "lawrence@cmux.com", "not an address"]}}});
    assert_eq!(
        read("verification_autofill", root)["values"]["accounts"],
        json!(["lawrence@cmux.com"])
    );
    let bad = read(
        "verification_autofill",
        json!({"browser": {"verificationAutofill": {"enabled": "yes"}}}),
    );
    assert_eq!(bad["values"]["enabled"], false);
    assert_eq!(messages(&bad).len(), 1);
    assert_eq!(messages(&bad)[0].0, "browser.verificationAutofill.enabled");
}

#[test]
fn font_smoothing_choices_and_refusals() {
    for mode in ["auto", "antialiased", "subpixel"] {
        let answer = read("font_smoothing", json!({"appearance": {"fontSmoothing": mode}}));
        assert_eq!(answer["values"]["mode"], mode);
        assert!(messages(&answer).is_empty());
    }
    for bad in [json!("subpixel-antialiased-ish"), json!(true), json!(0)] {
        let answer = read("font_smoothing", json!({"appearance": {"fontSmoothing": bad}}));
        assert_eq!(answer["values"]["mode"], "auto");
        assert_eq!(messages(&answer)[0].0, "appearance.fontSmoothing");
    }
}

#[test]
fn device_hub_reads_the_url() {
    let answer = read("device_hub", json!({"deviceHub": {"url": "http://mini.tail.ts.net:8787"}}));
    assert_eq!(answer["values"]["url"], "http://mini.tail.ts.net:8787");
    assert_eq!(read("device_hub", json!({}))["values"]["url"], "");
    let bad = read("device_hub", json!({"deviceHub": {"url": 3}}));
    assert_eq!(messages(&bad), vec![("deviceHub.url".to_owned(), "expected a string".to_owned())]);
}

#[test]
fn menu_look_reads_and_reports() {
    let good = read(
        "menu_look",
        json!({"appearance": {"menu": {"cornerRadius": 12, "fill": "#2b2b2b", "rowHeight": 30, "shortcuts": "muted", "submenu": "flush"},
                               "popover": {"padding": 12, "header": "strong", "progressHeight": 6}}}),
    );
    assert!(messages(&good).is_empty(), "{good}");
    assert_eq!(good["values"]["cornerRadius"], 12.0);
    assert_eq!(good["values"]["fill"], "#2b2b2b");
    assert_eq!(good["values"]["submenu"], "flush");
    assert_eq!(good["values"]["popoverHeader"], "strong");
    let bad = read(
        "menu_look",
        json!({"appearance": {"menu": {"shadow": "huge", "fill": "red", "rowHeight": 99}}}),
    );
    assert_eq!(bad["values"]["rowHeight"], 40.0);
    assert!(
        messages(&bad)
            .iter()
            .any(|m| m.0 == "appearance.menu.shadow" && m.1.starts_with("expected one of"))
    );
    let paths: Vec<_> = messages(&bad).into_iter().map(|m| m.0).collect();
    for path in ["appearance.menu.shadow", "appearance.menu.fill", "appearance.menu.rowHeight"] {
        assert!(paths.iter().any(|p| p == path), "{path}: {paths:?}");
    }
}

#[test]
fn motion_categories_list_the_switched_off() {
    let answer = read(
        "motion_categories",
        json!({"ui": {"animations": {"enabled": false, "tabs": false, "web": "no"}}}),
    );
    assert_eq!(answer["values"]["enabled"], false);
    assert_eq!(answer["values"]["disabled"], json!(["tabs"]));
    assert_eq!(messages(&answer)[0].0, "ui.animations.web");
}

#[test]
fn retired_new_tab_templates_read_as_minimal() {
    for retired in RETIRED_TEMPLATES {
        let answer = read("new_tab_template", json!({"tabs": {"newTabTemplate": retired}}));
        assert_eq!(answer["values"]["template"], "minimal");
        assert!(messages(&answer).is_empty());
    }
    let bad = read("new_tab_template", json!({"tabs": {"newTabTemplate": "nope"}}));
    assert_eq!(messages(&bad)[0].1, "expected one of \"minimal\", \"classic\", \"terminal\"");
}

#[test]
fn now_playing_reads_each_path() {
    let answer = read(
        "now_playing",
        json!({"sidebar": {"nowPlaying": {"enabled": false, "otherApps": 1}}, "tabs": {"newTabNowPlaying": false}}),
    );
    assert_eq!(answer["values"]["enabled"], false);
    assert_eq!(answer["values"]["newTab"], false);
    assert_eq!(messages(&answer)[0].0, "sidebar.nowPlaying.otherApps");
}

#[test]
fn palette_ranking_sorts_aliases_and_dedupes_pins() {
    let answer = read(
        "palette_ranking",
        json!({"palette": {"aliases": {"zz": "a", "bb": "a", " ": "a", "cc": ""}, "pins": ["x", "y", "x", ""]}}),
    );
    assert_eq!(answer["values"]["aliases"], json!({"a": ["bb", "zz"]}));
    assert_eq!(answer["values"]["pins"], json!(["x", "y"]));
}

#[test]
fn reduced_backgrounds_notes_only_while_on() {
    let on = call(
        "custom.read",
        &json!({"name": "reduced_backgrounds_notes", "root": {}, "reduced": true}),
    )
    .unwrap()
    .unwrap();
    assert_eq!(on["diagnostics"][0]["kind"], "plainBackgrounds");
    let off = call("custom.read", &json!({"name": "reduced_backgrounds_notes", "root": {}}))
        .unwrap()
        .unwrap();
    assert!(messages(&off).is_empty());
}

#[test]
fn remote_localhost_overrides() {
    let answer = read(
        "remote_localhost",
        json!({"browser": {"remoteLocalhost": false, "remoteLocalhostWorkspaces": {"a": true, "b": "x"}}}),
    );
    assert_eq!(answer["values"]["enabled"], false);
    assert_eq!(answer["values"]["workspaceOverrides"], json!({"a": true}));
    assert_eq!(messages(&answer)[0].0, "browser.remoteLocalhostWorkspaces.b");
}

#[test]
fn screenshots_expand_home_and_trust_keeps_it() {
    let root = json!({"screenshots": {"folders": ["~/Shots", "/tmp/x", "rel"]}});
    let answer =
        call("custom.read", &json!({"name": "screenshots", "root": root, "home": "/Users/me"}))
            .unwrap()
            .unwrap();
    assert_eq!(answer["values"]["folders"], json!(["/Users/me/Shots", "/tmp/x"]));
    assert_eq!(messages(&answer)[0].1, "expected an absolute or ~/ path");
    let trust = read(
        "trust",
        json!({"agents": {"trust": {"projectRoots": ["~/code", "no"], "ownOrgs": ["acme", ""]}}}),
    );
    assert_eq!(trust["values"]["projectRoots"], json!(["~/code"]));
    assert_eq!(trust["values"]["ownOrgs"], json!(["acme"]));
    assert_eq!(messages(&trust).len(), 2);
}

#[test]
fn surface_backgrounds_report_each_mistake() {
    let answer = read(
        "surface_backgrounds",
        json!({"appearance": {"surfaces": {"sidebar": {"color": "#112233", "opacity": 0.5, "x": 1}, "nope": {}, "tabBar": {"opacity": 2}}}}),
    );
    assert_eq!(
        answer["values"]["overrides"],
        json!({"sidebar": {"color": "#112233", "opacity": 0.5}})
    );
    assert_eq!(messages(&answer).len(), 3);
}

#[test]
fn updates_automatic_reads_its_old_toggles_while_unset() {
    let automatic = |updates: Value| {
        read("updates", json!({ "updates": updates }))["values"]["automatic"].clone()
    };
    assert_eq!(automatic(json!({"installWhenIdle": true})), json!("idle"));
    assert_eq!(automatic(json!({"checkAutomatically": false})), json!("off"));
    assert_eq!(
        automatic(json!({"automatic": "notify", "checkAutomatically": false})),
        json!("notify")
    );
    let bad =
        read("updates", json!({"updates": {"automatic": "sometimes", "installWhenIdle": true}}));
    assert_eq!(messages(&bad)[0].0, "updates.automatic");
}

#[test]
fn updates_notify_alias_and_clamps() {
    let answer = read("updates", json!({"updates": {"checkIntervalSeconds": 1}}));
    assert_eq!(messages(&answer)[0].0, "updates.checkIntervalSeconds");
    assert!(messages(&answer)[0].1.starts_with("clamped to "));
}

#[test]
fn appearance_tuning_wording() {
    let answer = read("appearance_tuning", json!({"appearance": {"hue": 9}}));
    assert!(messages(&answer)[0].1.ends_with("such as 0.5"), "{answer}");
}

#[test]
fn recent_fonts_and_tips() {
    let answer = call("recent_fonts.recorded", &json!({"family": "A", "list": ["B", "A", "C"]}))
        .unwrap()
        .unwrap();
    assert_eq!(answer["list"], json!(["A", "B", "C"]));
    let trimmed =
        call("recent_fonts.recorded", &json!({"family": "  A ", "list": ["B"]})).unwrap().unwrap();
    assert_eq!(trimmed["list"], json!(["A", "B"]));
    let blank =
        call("recent_fonts.recorded", &json!({"family": "  ", "list": ["B"]})).unwrap().unwrap();
    assert_eq!(blank["list"], json!(["B"]));
    let tip = call("feature_tips.is_open", &json!({"lastShownAt": 0, "at": 100})).unwrap().unwrap();
    assert_eq!(tip["open"], false);
}

// Ports of SessionKeepAwakeSettingTests, PhoneAccessSettingTests (parse cases),
// BrowserToolbarPositionSettingTests and TabBarBottomTitlebarSettingTests.
#[test]
fn sessions_keep_awake_while_plugged_in_unless_set() {
    let unset = read("sessions", json!({}));
    assert_eq!(unset["values"]["keepAwake"], "pluggedIn");
    assert!(messages(&unset).is_empty());
    for raw in ["off", "pluggedIn", "always"] {
        let loaded = read("sessions", json!({"sessions": {"keepAwake": raw}}));
        assert_eq!(loaded["values"]["keepAwake"], raw);
    }
    let bad = read("sessions", json!({"sessions": {"keepAwake": "forever"}}));
    assert_eq!(bad["values"]["keepAwake"], "pluggedIn");
    let found = messages(&bad);
    assert!(found.iter().any(|m| m.0 == "sessions.keepAwake"), "{found:?}");
    assert_eq!(found[0].1, "expected one of \"off\", \"pluggedIn\", \"always\"");
}

#[test]
fn phone_access_defaults_loads_and_ignores_retired_keys() {
    assert_eq!(read("sessions", json!({}))["values"]["phoneKeepAwake"], "pluggedIn");
    let loaded = read("sessions", json!({"phone": {"keepAwake": "always"}}));
    assert_eq!(loaded["values"]["phoneKeepAwake"], "always");
    let retired =
        read("sessions", json!({"phone": {"allowConnections": true, "startSessions": false}}));
    assert!(!messages(&retired).iter().any(|m| m.0.starts_with("phone.")));
}

#[test]
fn browser_toolbar_position_is_top_unless_bottom() {
    let unset = read("chrome_placement", json!({"browser": {}}));
    assert_eq!(unset["values"]["browserToolbarPosition"], "top");
    assert!(messages(&unset).is_empty());
    let bottom = read("chrome_placement", json!({"browser": {"toolbarPosition": "bottom"}}));
    assert_eq!(bottom["values"]["browserToolbarPosition"], "bottom");
    for bad in [json!("left"), json!(1)] {
        let answer = read("chrome_placement", json!({"browser": {"toolbarPosition": bad}}));
        assert_eq!(answer["values"]["browserToolbarPosition"], "top");
        assert!(messages(&answer).iter().any(|m| m.0 == "browser.toolbarPosition"));
    }
}

#[test]
fn bottom_tab_bar_and_window_titlebar_are_independent() {
    let bottom = read("chrome_placement", json!({"tabs": {"barPosition": "bottom"}}));
    assert_eq!(bottom["values"]["tabBarPosition"], "bottom");
    assert!(messages(&bottom).is_empty());
    let titlebar = read("window_titlebar", json!({}));
    assert_eq!(titlebar["values"]["style"], "minimal");
    let bad = read("window_titlebar", json!({"window": {"titlebar": "unknown"}}));
    assert_eq!(bad["values"]["style"], "minimal");
    assert!(messages(&bad).iter().any(|m| m.0 == "window.titlebar"));
    let standard = read(
        "window_titlebar",
        json!({"tabs": {"barPosition": "bottom"}, "window": {"titlebar": "standard"}}),
    );
    assert_eq!(standard["values"]["style"], "standard");
}

#[test]
fn chrome_placement_choices_say_the_swift_order() {
    let bad = read(
        "chrome_placement",
        json!({"tabs": {"barOrder": 1}, "sidebar": {"spacesPosition": "x"}}),
    );
    let found = messages(&bad);
    assert!(found.iter().any(|m| m.0 == "tabs.barOrder" && m.1.starts_with("expected one of \"")));
    assert!(found.iter().any(|m| m.0 == "sidebar.spacesPosition"));
}

#[test]
fn quit_behavior_legacy_values_and_message() {
    assert_eq!(read("quit_behavior", json!({}))["values"]["behavior"], "keep");
    let end = read("quit_behavior", json!({"app": {"quitBehavior": "end"}}));
    assert_eq!(end["values"]["behavior"], "end-keep-layout");
    assert!(messages(&end).is_empty());
    let ask = read("quit_behavior", json!({"app": {"quitBehavior": "ask"}}));
    assert_eq!(ask["values"]["behavior"], "keep");
    assert!(messages(&ask).is_empty());
    let bad = read("quit_behavior", json!({"app": {"quitBehavior": "nope"}}));
    assert_eq!(
        messages(&bad)[0],
        (
            "app.quitBehavior".to_owned(),
            "expected one of \"keep\", \"end-keep-layout\", \"end-everything\"".to_owned()
        )
    );
}

#[test]
fn workspace_hibernation_and_list_read_their_keys() {
    let unset = read("workspace_hibernation", json!({}));
    assert_eq!(unset["values"]["freeingRunningCommands"], "never");
    assert!(messages(&unset).is_empty());
    let bad = read(
        "workspace_hibernation",
        json!({"workspaces": {"hibernation": {"enabled": "x"}, "freeing": {"runningCommands": "bad", "agents": 1}}}),
    );
    let paths: Vec<_> = messages(&bad).into_iter().map(|m| m.0).collect();
    for path in [
        "workspaces.hibernation.enabled",
        "workspaces.freeing.runningCommands",
        "workspaces.freeing.agents",
    ] {
        assert!(paths.iter().any(|p| p == path), "{path}: {paths:?}");
    }
    let list = read(
        "workspace_list",
        json!({"workspaces": {"newPlacement": "bottom", "autoName": false}, "sidebar": {"groupByComputer": "x"}}),
    );
    assert_eq!(list["values"]["newWorkspacePlacement"], "bottom");
    assert!(
        messages(&list)
            .iter()
            .any(|m| m.0 == "sidebar.groupByComputer" && m.1 == "expected true or false")
    );
}
