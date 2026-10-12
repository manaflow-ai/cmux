//! Open Chat of a chat whose folder is another workspace's agent-home folder
//! (cx-djoj7): the chat opens in a new workspace, which proposes the chat's
//! folder. The store answered with the new workspace's own agent-home
//! folder, so acpmux refused the adopt ("cwd .../agent-home/<new> does not
//! match the adopted session .../agent-home/<old>"). An agent-home folder a
//! caller names is now where the chat starts.

use serde_json::{Value, json};

use super::*;

/// One `cmux.protocol/2` request; returns the whole response.
fn v2(server: &HeadlessServer, operation: &str, params: Value) -> Value {
    let mut fields = json!({"machine": "current", "session": "current"});
    fields.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
    let request = json!({"protocol": "cmux.protocol/2", "type": "request",
                         "id": format!("agent-home-{operation}"), "operation": operation,
                         "params": fields});
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|_| panic!("{operation}: no JSON reply: {line}"))
}

/// The store's answer, wherever the reply carries it.
fn answer(reply: &Value) -> &Value {
    assert_eq!(reply["ok"], true, "{reply}");
    let result = &reply["result"];
    if result["value"].is_object() { &result["value"] } else { result }
}

#[test]
fn a_chat_in_another_workspaces_agent_home_starts_there() {
    let root = unique_temp_dir("agent-home-reopen");
    let home = root.join("home");
    let data = root.join("data");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&data).unwrap();
    #[cfg(target_os = "macos")]
    let base = home.join("Library/Application Support/cmux/agent-home");
    #[cfg(not(target_os = "macos"))]
    let base = data.join("cmux/agent-home");
    // The chat's folder: the agent-home folder of the workspace it started in.
    let old = base.join("75afca2a-0b1c-4d2e-8f30-1a2b3c4d5e6f");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join(".cmux-agent-home"), "").unwrap();
    let old = fs::canonicalize(&old).unwrap();

    let server = HeadlessServer::start_with_options(
        "agent-home-reopen",
        None,
        None,
        &[("HOME", home.to_str().unwrap()), ("XDG_DATA_HOME", data.to_str().unwrap())],
    );
    let created = json_socket_request(&server.socket, json!({"id": 1, "cmd": "new-workspace"}));
    assert!(created["surface"].is_u64(), "{created}");
    let listed = json_socket_request(&server.socket, json!({"id": 2, "cmd": "list-workspaces"}));
    let workspace = listed["workspaces"][0]["resource_id"]
        .as_str()
        .unwrap_or_else(|| panic!("no workspace: {listed}"))
        .to_owned();

    let reply = v2(
        &server,
        "workspace.agent_start.get",
        json!({"workspace": workspace, "cwd": old.to_str().unwrap()}),
    );
    let start = answer(&reply);
    assert_eq!(start["kind"], "agent_home", "{reply}");
    assert_eq!(start["cwd"], old.to_str().unwrap(), "{reply}");
    assert_eq!(start["agent_home"], old.to_str().unwrap(), "{reply}");
    assert!(start.get("skipped").is_none_or(Value::is_null), "{reply}");

    // The workspace's own agent-home folder is still skipped, so its chosen or tab folder wins.
    // The store names it (by the workspace's durable key) when asked with no folder.
    let reply = v2(&server, "workspace.agent_start.get", json!({"workspace": workspace}));
    let own = PathBuf::from(answer(&reply)["agent_home"].as_str().unwrap());
    fs::create_dir_all(&own).unwrap();
    let reply = v2(
        &server,
        "workspace.agent_start.get",
        json!({"workspace": workspace, "cwd": own.to_str().unwrap()}),
    );
    assert_eq!(answer(&reply)["skipped"]["reason"], "agent_home", "{reply}");

    // A folder inside an agent-home folder, or one with no safe id, is still no start folder.
    let inner = old.join("sub");
    fs::create_dir_all(&inner).unwrap();
    let reply = v2(
        &server,
        "workspace.agent_start.get",
        json!({"workspace": workspace, "cwd": inner.to_str().unwrap()}),
    );
    let start = answer(&reply);
    assert_eq!(start["skipped"]["reason"], "agent_home", "{reply}");
    assert_ne!(start["agent_home"], old.to_str().unwrap(), "{reply}");
}
