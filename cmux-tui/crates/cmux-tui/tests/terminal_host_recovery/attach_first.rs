//! Session restore puts the visible terminals first, as Chrome loads the
//! shown tab of a restored window before its background tabs. A restarted
//! owner adopts its surviving hosts a few at a time (`ADOPTION_REPLAYS`), in
//! record order. An attach to a terminal that still adopts (the app attaches
//! the terminals it shows) moves that terminal's adoption ahead of the queued
//! ones and waits for it, instead of failing with "unknown surface" and
//! retrying until the queue reaches it (600 hosts: the shown terminals came
//! live 5 to 9 s after the app started, cp/restore-investigate bench).

use super::*;

/// The tabs of `tree` (`list-workspaces`), each as JSON.
fn tabs(tree: &serde_json::Value) -> Vec<serde_json::Value> {
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .cloned()
        .collect()
}

fn adopting_count(socket: &Path) -> usize {
    request(socket, serde_json::json!({"cmd": "list-terminals"}))["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|terminal| terminal["lifecycle"] == "adopting")
        .count()
}

#[test]
fn an_attach_to_an_adopting_terminal_adopts_it_first_and_waits_for_it() {
    // Each adoption try holds its permit this long (a slow handshake and
    // replay), so the queue of COUNT hosts takes COUNT / 8 such rounds.
    const TRY_HOLD_MS: u64 = 500;
    const COUNT: usize = 48;
    let mut harness = RecoveryHarness::start("attach-first");
    for index in 0..COUNT {
        request(
            &harness.socket,
            serde_json::json!({
                "id": 100 + index,
                "cmd": "run",
                "argv": ["/bin/cat"],
                "new_workspace": index % 4 == 0,
                "name": format!("restored-{index}"),
            }),
        );
    }
    let records = wait_for_host_records(&harness.host_root(), COUNT);
    // Records adopt in path order: the last one is the last in the queue.
    let last = records.iter().map(|(_, record)| record.terminal_id.clone()).max().unwrap();
    let before = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let content = tabs(&before)
        .into_iter()
        .find(|tab| tab["terminal_id"] == last.as_str())
        .and_then(|tab| tab["content_resource_id"].as_str().map(str::to_string))
        .unwrap_or_else(|| panic!("no tab shows terminal {last}: {before}"));
    harness.sigkill();

    harness
        .extra_env
        .push(("CMUX_TUI_TEST_ADOPTION_TRY_HOLD_MS".to_string(), TRY_HOLD_MS.to_string()));
    harness.restart();
    let restarted = Instant::now();
    let tree = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let tab = tabs(&tree)
        .into_iter()
        .find(|tab| tab["content_resource_id"] == content.as_str())
        .unwrap_or_else(|| panic!("the restored tree lost the tab of {last}: {tree}"));
    assert_eq!(
        tab["terminal_state"], "adopting",
        "the last-queued terminal is not adopting: {tab}"
    );
    let surface = tab["surface"].as_u64().unwrap();

    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({"id": 7, "cmd": "attach-surface", "surface": surface})
    )
    .unwrap();
    let response = loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("the attach connection closed before its answer");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if value["id"] == 7 {
            break value;
        }
    };
    let attached = restarted.elapsed();
    let still_adopting = adopting_count(&harness.socket);
    assert_eq!(
        response["ok"], true,
        "an attach to the adopting terminal failed instead of waiting for it: {response}"
    );
    // The queue reaches the last host after COUNT / 8 rounds of TRY_HOLD_MS
    // (3 s); taken first, it is live after about one. At least one more round
    // is still queued when it answers, whatever the host's load.
    assert!(
        still_adopting >= 8,
        "the attach answered after {attached:?}, when only {still_adopting} terminals were \
         still adopting: it waited for the queue instead of going first"
    );
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd": "resolve-terminal", "terminal_id": last}),
    );
    assert_eq!(resolved["lifecycle"], "running", "{resolved}");
    assert_eq!(resolved["surface"].as_u64(), Some(surface), "{resolved}");
}

/// A detach of the attaching client's own view of a surface, sent after its
/// attach while that attach still waits for the adoption, wins: the attach
/// is cancelled, and no view or size lease of it stays behind. Before, the
/// detach answered at once (there was no view yet), and the attach attached
/// after it.
#[test]
fn a_detach_sent_while_the_attach_waits_cancels_that_attach() {
    const TRY_HOLD_MS: u64 = 500;
    const COUNT: usize = 24;
    let mut harness = RecoveryHarness::start("attach-first-detach");
    for index in 0..COUNT {
        request(
            &harness.socket,
            serde_json::json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
                               "name": format!("detach-{index}")}),
        );
    }
    let records = wait_for_host_records(&harness.host_root(), COUNT);
    let last = records.iter().map(|(_, record)| record.terminal_id.clone()).max().unwrap();
    let before = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let content = tabs(&before)
        .into_iter()
        .find(|tab| tab["terminal_id"] == last.as_str())
        .and_then(|tab| tab["content_resource_id"].as_str().map(str::to_string))
        .unwrap_or_else(|| panic!("no tab shows terminal {last}: {before}"));
    harness.sigkill();
    harness
        .extra_env
        .push(("CMUX_TUI_TEST_ADOPTION_TRY_HOLD_MS".to_string(), TRY_HOLD_MS.to_string()));
    harness.restart();
    let tree = request(&harness.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let surface = tabs(&tree)
        .into_iter()
        .find(|tab| tab["content_resource_id"] == content.as_str())
        .and_then(|tab| tab["surface"].as_u64())
        .unwrap_or_else(|| panic!("the restored tree lost the tab of {last}: {tree}"));

    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let clients = stream_request(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 1, "cmd": "list-clients"}),
    );
    let listed = clients.get("clients").unwrap_or(&clients).clone();
    let me = listed
        .as_array()
        .into_iter()
        .flatten()
        .find(|client| client["self"] == true)
        .and_then(|client| client["client"].as_u64())
        .unwrap_or_else(|| panic!("list-clients names no caller: {clients}"));
    for line in [
        serde_json::json!({"id": 7, "cmd": "attach-surface", "surface": surface,
                           "cols": 80, "rows": 24}),
        serde_json::json!({"id": 8, "cmd": "detach-client", "client": me, "surface": surface}),
    ] {
        writeln!(writer, "{line}").unwrap();
    }
    let mut answers = std::collections::HashMap::new();
    while answers.len() < 2 {
        let mut line = String::new();
        reader.read_line(&mut line).expect("the connection closed before both answers");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if value["id"] == 7 || value["id"] == 8 {
            answers.insert(value["id"].as_u64().unwrap(), value);
        }
    }
    assert_eq!(answers[&8]["ok"], true, "the detach failed: {}", answers[&8]);
    assert_eq!(
        answers[&7]["ok"], false,
        "the attach attached after the detach that came after it: {}",
        answers[&7]
    );
    let after = stream_request(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 9, "cmd": "list-clients"}),
    );
    let listed = after.get("clients").unwrap_or(&after).clone();
    let attached = listed
        .as_array()
        .into_iter()
        .flatten()
        .find(|client| client["self"] == true)
        .map(|client| client["attached"].clone())
        .unwrap_or_default();
    assert_eq!(attached, serde_json::json!([]), "a cancelled attach left a view: {after}");
}
