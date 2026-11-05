//! The `cloud_*` tools (mcp/cloud_tools.rs): which app actions each runs, with which target and
//! arguments, and the take-over refusal.

use super::*;

fn answers(list: &[(&str, Result<Value, Value>)]) -> BTreeMap<String, Result<Value, Value>> {
    list.iter().map(|(action, answer)| ((*action).to_owned(), answer.clone())).collect()
}

fn exec(stdout: &str) -> Result<Value, Value> {
    Ok(json!({"exit_code": 0, "stdout": stdout, "stderr": ""}))
}

fn holder(holder: &str) -> Result<Value, Value> {
    Ok(json!({"machine": "vm-1", "holder": holder, "since_ms": 1_700_000_000_000_i64}))
}

/// The `action.run` params the app got, in order.
fn app_runs(server: &Server<Fake>) -> Vec<Value> {
    sent_of(server, "app")
        .into_iter()
        .filter(|sent| sent["method"] == "action.run")
        .map(|sent| sent["params"].clone())
        .collect()
}

fn serve(fake: Fake) -> Server<Fake> {
    Server::new(fake, None)
}

#[test]
fn the_cloud_tools_are_listed_with_short_descriptions() {
    let mut server = serve(Fake::default());
    let tools = server.list();
    for name in [
        "cloud_machines",
        "cloud_chat_start",
        "cloud_chat_send",
        "cloud_chat_status",
        "cloud_computer",
        "cloud_computer_control",
    ] {
        let tool =
            tools.iter().find(|tool| tool["name"] == name).unwrap_or_else(|| panic!("{name}"));
        assert!(tool["description"].as_str().unwrap().len() < 300, "{name}");
        assert_eq!(tool["inputSchema"]["additionalProperties"], false, "{name}");
    }
}

#[test]
fn cloud_machines_lists_the_apps_machines_and_this_chiefs_computer() {
    let fake = Fake {
        chief_computer: Some("vm-1".into()),
        action_answers: answers(&[(
            "cloud list-machines",
            Ok(json!({"loaded": true, "account": {"signed_in": true}, "machines": [
                {"machine_id": "vm-1", "target": "machine:vm-1", "title": "dev", "status": "running",
                 "workspaces": [{"id": "w"}]},
            ]})),
        )]),
        ..Fake::default()
    };
    let mut server = serve(fake);
    let listed = call(&mut server, "cloud_machines", json!({}));
    assert_eq!(listed["isError"], false, "{listed}");
    let content = &listed["structuredContent"];
    assert_eq!(content["computer"], "machine:vm-1");
    assert_eq!(content["signed_in"], true);
    assert_eq!(
        content["machines"],
        json!([{"machine_id": "vm-1", "target": "machine:vm-1", "title": "dev", "status": "running"}])
    );
    let run = &app_runs(&server)[0];
    assert_eq!(
        (run["action"].as_str(), run["cli"].as_bool()),
        (Some("cloud list-machines"), Some(true))
    );
    assert_eq!(run["origin"], "mcp");
}

#[test]
fn an_input_op_reads_the_lease_then_drives_cua_driver_on_the_chiefs_computer() {
    let fake = Fake {
        chief_computer: Some("vm-1".into()),
        action_answers: answers(&[
            ("cloud.computerControl", holder("chief")),
            ("cloud exec", exec("{\"ok\":true}")),
        ]),
        ..Fake::default()
    };
    let mut server = serve(fake);
    let clicked = call(&mut server, "cloud_computer", json!({"op": "click", "x": 10, "y": 20}));
    assert_eq!(clicked["isError"], false, "{clicked}");
    assert_eq!(clicked["structuredContent"]["machine"], "machine:vm-1");
    assert_eq!(clicked["structuredContent"]["result"], json!({"ok": true}));
    let runs = app_runs(&server);
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert_eq!(runs[0]["action"], "cloud.computerControl");
    assert!(runs[0].get("cli").is_none(), "the lease is run by its action id");
    assert_eq!(runs[0]["args"], json!({"machine": "vm-1", "action": "status"}));
    assert_eq!(runs[1]["action"], "cloud exec");
    assert_eq!(runs[1]["target"], "machine:vm-1");
    let script = runs[1]["args"]["command"].as_str().unwrap();
    assert!(script.contains(". /etc/cmux/desktop-env.sh"), "{script}");
    assert!(
        script.ends_with(
            "cua-driver call click '{\"button\":\"left\",\"scope\":\"desktop\",\"x\":10,\"y\":20}'"
        ),
        "{script}"
    );

    // Named keys and typed text are one quoted JSON word each.
    let mut server = serve(Fake {
        action_answers: answers(&[
            ("cloud.computerControl", holder("chief")),
            ("cloud exec", exec("")),
        ]),
        ..Fake::default()
    });
    let typed = call(
        &mut server,
        "cloud_computer",
        json!({"op": "type", "machine": "machine:vm-2", "text": "it's $HOME"}),
    );
    assert_eq!(typed["isError"], false, "{typed}");
    let keyed = call(
        &mut server,
        "cloud_computer",
        json!({"op": "key", "machine": "vm-2", "keys": "ctrl+L"}),
    );
    assert_eq!(keyed["isError"], false, "{keyed}");
    let execs = app_runs(&server)
        .into_iter()
        .filter(|run| run["action"] == "cloud exec")
        .collect::<Vec<_>>();
    assert_eq!(execs[0]["target"], "machine:vm-2");
    assert!(
        execs[0]["args"]["command"]
            .as_str()
            .unwrap()
            .ends_with("type_text '{\"scope\":\"desktop\",\"text\":\"it'\\''s $HOME\"}'"),
        "{}",
        execs[0]["args"]["command"]
    );
    assert!(
        execs[1]["args"]["command"]
            .as_str()
            .unwrap()
            .ends_with("hotkey '{\"keys\":[\"ctrl\",\"l\"],\"scope\":\"desktop\"}'"),
        "{}",
        execs[1]["args"]["command"]
    );
}

#[test]
fn while_the_person_has_control_input_is_refused_and_screenshots_still_work() {
    let fake = Fake {
        chief_computer: Some("vm-1".into()),
        action_answers: answers(&[
            ("cloud.computerControl", holder("human")),
            ("cloud exec", exec("")),
            ("cloud file-read", Ok(json!({"data_base64": "iVBORw0K"}))),
        ]),
        ..Fake::default()
    };
    let mut server = serve(fake);
    for arguments in [
        json!({"op": "click", "x": 1, "y": 1}),
        json!({"op": "type", "text": "x"}),
        json!({"op": "open_url", "url": "https://example.com"}),
    ] {
        let refused = call(&mut server, "cloud_computer", arguments.clone());
        assert_eq!(refused["isError"], true, "{arguments}");
        let error = &refused["structuredContent"]["error"];
        assert_eq!(error["code"], "computer.human_has_control", "{arguments}");
        assert_eq!(error["details"]["control"]["holder"], "human");
        assert_eq!(refused["structuredContent"]["state"], "not_run");
    }
    assert!(
        app_runs(&server).iter().all(|run| run["action"] != "cloud exec"),
        "no input reached the machine"
    );

    let shot = call(&mut server, "cloud_computer", json!({"op": "screenshot"}));
    assert_eq!(shot["isError"], false, "{shot}");
    assert_eq!(
        shot["content"][1],
        json!({"type": "image", "data": "iVBORw0K", "mimeType": "image/png"})
    );
    let runs = app_runs(&server);
    let tail = &runs[runs.len() - 2..];
    assert_eq!(tail[0]["action"], "cloud exec", "a screenshot reads no lease");
    assert!(tail[0]["args"]["command"].as_str().unwrap().contains("get_desktop_state"));
    assert_eq!(tail[1]["action"], "cloud file-read");
    assert_eq!(tail[1]["target"], "machine:vm-1");
}

#[test]
fn an_app_without_the_lease_runs_input_and_another_failure_refuses_it() {
    let missing = json!({"code": "action.not_found", "message": "unknown action"});
    let mut server = serve(Fake {
        action_answers: answers(&[
            ("cloud.computerControl", Err(missing)),
            ("cloud exec", exec("")),
        ]),
        ..Fake::default()
    });
    let moved = call(
        &mut server,
        "cloud_computer",
        json!({"op": "move", "machine": "vm-1", "x": 5, "y": 6}),
    );
    assert_eq!(moved["isError"], false, "{moved}");

    let down = json!({"code": "cloud.unavailable", "message": "the app is restarting"});
    let mut server = serve(Fake {
        action_answers: answers(&[("cloud.computerControl", Err(down)), ("cloud exec", exec(""))]),
        ..Fake::default()
    });
    let refused = call(
        &mut server,
        "cloud_computer",
        json!({"op": "move", "machine": "vm-1", "x": 5, "y": 6}),
    );
    assert_eq!(refused["isError"], true);
    assert!(app_runs(&server).iter().all(|run| run["action"] != "cloud exec"));

    // No machine named and none attached: nothing runs.
    let mut server = serve(Fake::default());
    let unnamed = call(&mut server, "cloud_computer", json!({"op": "screenshot"}));
    assert_eq!(unnamed["structuredContent"]["error"]["code"], "validation.invalid");
    assert!(app_runs(&server).is_empty());
}

#[test]
fn computer_control_asks_the_person_and_hands_back_through_the_apps_lease() {
    let mut server = serve(Fake {
        chief_computer: Some("vm-1".into()),
        action_answers: answers(&[("cloud.computerControl", holder("human"))]),
        ..Fake::default()
    });
    let asked = call(
        &mut server,
        "cloud_computer_control",
        json!({"action": "request_human", "reason": "Sign in to Gmail"}),
    );
    assert_eq!(asked["isError"], false, "{asked}");
    assert_eq!(asked["structuredContent"]["holder"], "human");
    let back = call(
        &mut server,
        "cloud_computer_control",
        json!({"action": "hand_back", "machine": "machine:vm-3"}),
    );
    assert_eq!(back["isError"], false, "{back}");
    let runs = app_runs(&server);
    assert_eq!(
        runs[0]["args"],
        json!({"machine": "vm-1", "action": "request_human", "reason": "Sign in to Gmail"})
    );
    assert_eq!(runs[1]["args"], json!({"machine": "vm-3", "action": "hand_back"}));
    for arguments in [json!({"action": "take_over"}), json!({"action": "status", "reason": "x"})] {
        let refused = call(&mut server, "cloud_computer_control", arguments.clone());
        assert_eq!(
            refused["structuredContent"]["error"]["code"], "validation.invalid",
            "{arguments}"
        );
    }
}

#[test]
fn chat_send_and_status_run_acp_on_the_machine() {
    let mut server = serve(Fake {
        action_answers: answers(&[(
            "cloud exec",
            exec(
                "@@history\n{\"turns\":[{\"seq\":4,\"status\":\"completed\",\"endedAt\":9}]}\n\
                 @@send\nqueued\n@@exit 0\n",
            ),
        )]),
        ..Fake::default()
    });
    let sent = call(
        &mut server,
        "cloud_chat_send",
        json!({"machine": "machine:vm-1", "session": "sess-1", "prompt": "next"}),
    );
    assert_eq!(sent["isError"], false, "{sent}");
    assert_eq!(sent["structuredContent"]["after"], 4);
    assert_eq!(sent["structuredContent"]["sent"], true);
    let run = &app_runs(&server)[0];
    assert_eq!(
        (run["action"].as_str(), run["target"].as_str()),
        (Some("cloud exec"), Some("machine:vm-1"))
    );
    assert!(run["args"]["command"].as_str().unwrap().contains("acp send --no-wait sess-1 -"));

    let mut server = serve(Fake {
        action_answers: answers(&[(
            "cloud exec",
            exec(
                "@@wait 0\n@@history\n{\"turns\":[{\"seq\":5,\"status\":\"completed\",\"endedAt\":9}]}\n\
                 @@last\n{\"replies\":[\"done\"]}\n@@lastexit 0\n",
            ),
        )]),
        ..Fake::default()
    });
    let status = call(
        &mut server,
        "cloud_chat_status",
        json!({"machine": "vm-1", "session": "sess-1", "after": 4, "wait_s": 20}),
    );
    assert_eq!(status["isError"], false, "{status}");
    assert_eq!(status["structuredContent"]["state"], "ended");
    assert_eq!(status["structuredContent"]["reply"], "done");
    assert!(
        app_runs(&server)[0]["args"]["command"]
            .as_str()
            .unwrap()
            .contains("acp wait sess-1 --timeout 20")
    );
    // The turn before `after` is not this prompt's.
    let older = call(
        &mut server,
        "cloud_chat_status",
        json!({"machine": "vm-1", "session": "sess-1", "after": 5}),
    );
    assert_eq!(older["structuredContent"]["state"], "starting");
}

#[test]
fn chat_start_runs_the_start_chat_chain_through_the_apps_actions() {
    let mut server = serve(Fake {
        action_answers: answers(&[
            ("cloud list-machines", Ok(json!({"account": {"signed_in": true}, "machines": []}))),
            (
                "cloud start-session",
                Ok(json!({"machine_id": "vm-1", "session_id": "sess-1", "workspace_id": "ws_1",
                          "tab_id": "tab-1"})),
            ),
            ("cloud exec", exec("@@history\n{\"turns\":[]}\n@@send\nqueued\n@@exit 0\n")),
        ]),
        ..Fake::default()
    });
    let started = call(
        &mut server,
        "cloud_chat_start",
        json!({"prompt": "Run the tests", "machine": "machine:vm-1", "agent": "codex"}),
    );
    assert_eq!(started["isError"], false, "{started}");
    let content = &started["structuredContent"];
    assert_eq!(
        (content["machine_id"].as_str(), content["session_id"].as_str()),
        (Some("vm-1"), Some("sess-1"))
    );
    assert_eq!(
        content["follow_up"]["status"],
        "cmux cloud chat status --target machine:vm-1 --session sess-1 --wait 20"
    );
    let runs = app_runs(&server);
    assert_eq!(
        runs.iter().map(|run| run["action"].as_str().unwrap()).collect::<Vec<_>>(),
        ["cloud list-machines", "cloud start-session", "cloud exec"]
    );
    assert_eq!(runs[1]["target"], "machine:vm-1");
    assert_eq!(runs[1]["args"], json!({"agent": "codex"}));
    assert!(runs[2]["args"]["command"].as_str().unwrap().contains("'Run the tests'"));

    let refused = call(&mut server, "cloud_chat_start", json!({"prompt": "x", "cwd": "relative"}));
    assert_eq!(refused["structuredContent"]["error"]["code"], "validation.invalid");
}
