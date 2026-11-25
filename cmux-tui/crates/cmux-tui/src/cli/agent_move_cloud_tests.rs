use super::*;

const LOCAL_CHAT: &str = "sess-local-0001";
const CLOUD_CHAT: &str = "sess-cloud-0002";

fn machine(id: &str, title: &str) -> CloudMachine {
    CloudMachine { id: id.into(), title: title.into() }
}

/// The app shows `LOCAL_CHAT` in a tab of this Mac and `CLOUD_CHAT` on Cloud machine vm-1, and the
/// account lists `machines`.
fn facts(machines: &[CloudMachine]) -> Facts {
    let mut chats = HashMap::new();
    chats.insert(LOCAL_CHAT.into(), ChatTab { tab: "tab-l".into(), cloud_machine: None });
    chats.insert(
        CLOUD_CHAT.into(),
        ChatTab { tab: "tab-c".into(), cloud_machine: Some("vm-1".into()) },
    );
    Facts {
        chats: Some(chats),
        signed_in: Some(true),
        loaded: true,
        machines: Some(machines.to_vec()),
    }
}

fn code(result: Result<Route, Refusal>) -> &'static str {
    result.expect_err("a refusal").code
}

#[test]
fn cloud_with_one_machine_takes_it() {
    let one = [machine("vm-1", "brave-otter")];
    assert_eq!(
        route("cloud", None, LOCAL_CHAT, &facts(&one)),
        Ok(Route::Cloud {
            session: LOCAL_CHAT.into(),
            tab: "tab-l".into(),
            machine: one[0].clone()
        })
    );
    // A unique id prefix names the chat too.
    assert!(matches!(route("cloud", None, "sess-local", &facts(&one)), Ok(Route::Cloud { .. })));
}

#[test]
fn cloud_with_several_machines_lists_them_and_asks_for_a_name() {
    let two = [machine("vm-1", "brave-otter"), machine("vm-2", "calm-heron")];
    let refusal = route("cloud", None, LOCAL_CHAT, &facts(&two)).unwrap_err();
    assert_eq!(refusal.code, "cloud.machine_ambiguous");
    for word in ["brave-otter (vm-1)", "calm-heron (vm-2)", "--to NAME"] {
        assert!(refusal.message.contains(word), "{}", refusal.message);
    }
    // Then the name, the id or `vm:ID` picks one.
    for target in ["calm-heron", "vm-2", "vm:vm-2", "machine:vm-2", "CALM-HERON"] {
        assert_eq!(
            route(target, None, LOCAL_CHAT, &facts(&two)),
            Ok(Route::Cloud {
                session: LOCAL_CHAT.into(),
                tab: "tab-l".into(),
                machine: two[1].clone()
            }),
            "{target}"
        );
    }
}

#[test]
fn cloud_with_no_machine_names_the_command_that_makes_one() {
    let refusal = route("cloud", None, LOCAL_CHAT, &facts(&[])).unwrap_err();
    assert_eq!(refusal.code, "cloud.no_machine");
    assert!(refusal.message.contains("cmux setup cloud-machine"), "{}", refusal.message);
    // Never "none" on a list the app has not loaded.
    let mut unread = facts(&[]);
    unread.loaded = false;
    assert_eq!(code(route("cloud", None, LOCAL_CHAT, &unread)), "cloud.list_unread");
    // A `vm:` target the account lacks says what it has.
    let one = [machine("vm-1", "brave-otter")];
    let refusal = route("vm:vm-9", None, LOCAL_CHAT, &facts(&one)).unwrap_err();
    assert_eq!(refusal.code, "cloud.machine_unknown");
    assert!(refusal.message.contains("brave-otter (vm-1)"), "{}", refusal.message);
}

#[test]
fn cloud_refusals_name_a_next_step() {
    let one = [machine("vm-1", "brave-otter")];
    let mut out = facts(&one);
    out.signed_in = Some(false);
    let refusal = route("cloud", None, LOCAL_CHAT, &out).unwrap_err();
    assert_eq!(refusal.code, "cloud.signed_out");
    assert!(refusal.message.contains("cmux login"), "{}", refusal.message);
    let refusal = route("cloud", None, LOCAL_CHAT, &Facts::default()).unwrap_err();
    assert_eq!(refusal.code, "app.unreachable");
    assert!(refusal.message.contains("open cmux"), "{}", refusal.message);
    assert_eq!(code(route("cloud", None, "nobody", &facts(&one))), "move.chat_not_shown");
    let refusal = route("cloud", None, CLOUD_CHAT, &facts(&one)).unwrap_err();
    assert_eq!(refusal.code, "move.already_cloud");
    assert!(refusal.message.contains("--to here"), "{}", refusal.message);
    assert_eq!(code(route("cloud", Some("mini"), LOCAL_CHAT, &facts(&one))), "move.cloud_from");
}

#[test]
fn here_brings_a_cloud_chat_back_and_leaves_the_rest_to_acpmux() {
    let one = [machine("vm-1", "brave-otter")];
    assert_eq!(
        route("local", None, CLOUD_CHAT, &facts(&one)),
        Ok(Route::BringBack {
            session: CLOUD_CHAT.into(),
            tab: "tab-c".into(),
            machine: one[0].clone()
        })
    );
    // A chat of this Mac, one the app does not show, or a move `--from` a peer: acpmux.
    assert_eq!(route("local", None, LOCAL_CHAT, &facts(&one)), Ok(Route::Acpmux));
    assert_eq!(route("local", None, "peer-chat", &facts(&one)), Ok(Route::Acpmux));
    assert_eq!(route("local", Some("mini"), CLOUD_CHAT, &facts(&one)), Ok(Route::Acpmux));
    assert_eq!(route("local", None, CLOUD_CHAT, &Facts::default()), Ok(Route::Acpmux));
}

#[test]
fn auto_and_peers_stay_with_acpmux() {
    let one = [machine("vm-1", "brave-otter")];
    for target in ["auto", "build-box", "gcp-3"] {
        assert_eq!(route(target, None, LOCAL_CHAT, &facts(&one)), Ok(Route::Acpmux), "{target}");
        assert_eq!(route(target, None, LOCAL_CHAT, &Facts::default()), Ok(Route::Acpmux));
    }
    assert!(!needs_facts("auto", None));
    assert!(!needs_facts("local", Some("mini")));
    assert!(needs_facts("cloud", None));
    assert!(needs_facts("build-box", None));
}

#[test]
fn the_topology_says_which_tab_shows_a_chat_and_on_which_cloud_machine() {
    let topology = json!({
        "workspaces": [
            {"id": "ws-mac", "machine": "local",
             "tabs": [{"id": "tab-l", "kind": "conversation", "agent_session": LOCAL_CHAT}]},
            {"id": "ws-vm", "machine": "vm-1",
             "panes": [{"tabs": [{"id": "tab-c", "kind": "conversation", "agent_session": CLOUD_CHAT}]}]},
            {"id": "ws-ssh", "machine": "mini",
             "tabs": [{"id": "tab-s", "kind": "conversation", "agent_session": "sess-ssh"},
                      {"id": "tab-t", "kind": "terminal"}]}
        ],
        "sessions": [
            {"id": "s1", "machine": "vm-1", "transport": "cloud"},
            {"id": "s2", "machine": "mini", "transport": "ssh"}
        ]
    });
    let chats = chats_of(&topology);
    assert_eq!(chats.len(), 3, "{chats:?}");
    assert_eq!(chats[LOCAL_CHAT], ChatTab { tab: "tab-l".into(), cloud_machine: None });
    assert_eq!(
        chats[CLOUD_CHAT],
        ChatTab { tab: "tab-c".into(), cloud_machine: Some("vm-1".into()) }
    );
    assert_eq!(chats["sess-ssh"].cloud_machine, None);
}

#[test]
fn the_machine_list_reads_sign_in_and_machines() {
    let mut facts = Facts::default();
    read_list(
        &json!({"account": {"signed_in": true}, "loaded": true,
                "machines": [{"machine_id": "vm-1", "title": "brave-otter"}, {"machine_id": "vm-2"}]}),
        &mut facts,
    );
    assert_eq!(facts.signed_in, Some(true));
    assert!(facts.loaded);
    assert_eq!(facts.machines, Some(vec![machine("vm-1", "brave-otter"), machine("vm-2", "vm-2")]));
    let mut out = Facts::default();
    read_list(&json!({"account": {"signed_in": false}, "loaded": false, "machines": []}), &mut out);
    assert_eq!(out.signed_in, Some(false));
    assert!(!out.loaded);
}

#[test]
fn each_route_runs_the_apps_own_action() {
    let one = machine("vm-1", "brave-otter");
    let cloud =
        Route::Cloud { session: LOCAL_CHAT.into(), tab: "tab-l".into(), machine: one.clone() };
    assert_eq!(
        action_words(&cloud),
        ["cloud", "move", "--target", "tab:tab-l", "--machine", "machine:vm-1"]
    );
    let back = Route::BringBack { session: CLOUD_CHAT.into(), tab: "tab-c".into(), machine: one };
    assert_eq!(action_words(&back), ["cloud", "bring-back", "--target", "tab:tab-c"]);
}

#[test]
fn dry_run_says_the_path_and_the_machine() {
    let one = machine("vm-1", "brave-otter");
    let cloud =
        Route::Cloud { session: LOCAL_CHAT.into(), tab: "tab-l".into(), machine: one.clone() };
    let described = describe(&cloud);
    assert_eq!(described["path"], "cloud_move");
    assert_eq!(described["machine_id"], "vm-1");
    assert_eq!(described["command"], "cmux cloud move --target tab:tab-l --machine machine:vm-1");
    assert_eq!(
        human_line(&described, true),
        "sess-local-0001: would move to Cloud machine brave-otter (vm-1): the app's Move to Cloud \
         (`cmux cloud move --target tab:tab-l --machine machine:vm-1`)"
    );
    let back = Route::BringBack { session: CLOUD_CHAT.into(), tab: "tab-c".into(), machine: one };
    assert_eq!(
        human_line(&describe(&back), true),
        "sess-cloud-0002: would come back here from Cloud machine brave-otter (vm-1): the app's \
         Bring Back Local (`cmux cloud bring-back --target tab:tab-c`)"
    );
    assert_eq!(
        human_line(&describe(&back), false),
        "sess-cloud-0002: came back here from Cloud machine brave-otter (vm-1)"
    );
}

#[test]
fn the_apps_move_refuses_acpmux_only_options_with_why() {
    for option in ["--after-turn", "--leave-dirty", "--cwd"] {
        let why = app_refuses_option(option).expect(option);
        assert!(why.contains(&format!("drop {option}")), "{why}");
    }
    for option in ["--interrupt", "--carry-changes", "--dry-run", "--timings"] {
        assert_eq!(app_refuses_option(option), None, "{option}");
    }
}

#[test]
fn a_run_past_the_apps_wait_is_still_a_move_not_a_refusal() {
    assert!(still_running(&json!({"code": "mutation.outcome_unknown"})));
    assert!(still_running(&json!({"code": "action.timeout"})));
    assert!(!still_running(&json!({"code": "cloud.signed_out"})));
}
