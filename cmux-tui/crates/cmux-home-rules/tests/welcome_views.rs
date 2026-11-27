//! Parity with `ChiefViewsPageTests`: lanes to rows, the Fleet and Landing feeds, and the URL checks.

use cmux_home_rules::call;
use cmux_home_rules::welcome::views::{
    LOCAL_MACHINE, Lane, Workspace, agent_rows, fleet_data_url, fleet_reply, landing_prs,
    landing_search_urls, lane_row, search_day, valid_fleet_url, valid_pull_request_url,
};
use serde_json::{Value, json};

#[test]
fn lanes_map_to_the_four_states_and_keep_their_summary_fields() {
    let lane: Lane = serde_json::from_value(json!({
        "id": "s1", "name": "huge-blue/chiefviews", "peer": "huge-blue", "cwd": "/w/chiefviews/cmux",
        "updatedAt": 1_792_535_000.0, "createdAt": 1_792_500_000.0, "harness": "claude",
        "state": "lost", "since": 1_792_534_000.0, "step": "Writing the Fleet view",
    }))
    .unwrap();
    let row = lane_row(&lane);
    assert_eq!(row.state, "failed");
    assert_eq!(row.machine, "huge-blue");
    assert_eq!(row.task.as_deref(), Some("Writing the Fleet view"));
    assert_eq!(row.folder.as_deref(), Some("/w/chiefviews/cmux"));
    assert_eq!(row.last_output_at, Some(1_792_535_000.0));
    let states: Vec<&str> = ["working", "input", "idle", "failed"]
        .iter()
        .map(|s| lane_row(&Lane { state: (*s).into(), ..Lane::default() }).state)
        .collect();
    assert_eq!(states, ["working", "waiting", "idle", "failed"]);
    let bare = lane_row(&Lane { id: "y".into(), state: "idle".into(), ..Lane::default() });
    assert_eq!(bare.machine, LOCAL_MACHINE);
    assert!(bare.folder.is_none() && bare.last_output_at.is_none() && bare.created_at.is_none());
}

#[test]
fn agents_reply_carries_every_field_the_page_reads() {
    let lane = Lane {
        id: "s".into(),
        name: "n".into(),
        title: "T".into(),
        parent: Some("chief".into()),
        state: "input".into(),
        since: Some(2.0),
        ..Lane::default()
    };
    let rows = agent_rows(&[lane], &[]);
    let agent = serde_json::to_value(&rows[0]).unwrap();
    assert_eq!(agent["state"], "waiting");
    assert_eq!(agent["kind"], "chat");
    assert_eq!(agent["machine"], "local");
    assert_eq!(agent["since"], 2.0);
    assert_eq!(agent["parent"], "chief");
    assert_eq!(agent["folder"], Value::Null);
}

#[test]
fn live_agent_terminals_follow_the_chats() {
    let ws: Workspace = serde_json::from_value(json!({
        "isLocal": false, "machineName": "mini", "machineID": "m1",
        "tabs": [
            {"id": "t1", "title": "claude", "agent": {"state": "blocked", "updatedAtMs": 5000}},
            {"id": "t2", "title": "chat", "hasAgentSession": true, "agent": {"state": "working", "updatedAtMs": 1}},
            {"id": "t3", "title": "shell"},
        ],
    }))
    .unwrap();
    let out = call(
        "welcome.agentRows",
        &json!({"lanes": [{"id": "b", "state": "idle"}, {"id": "a", "state": "working"}], "workspaces": [ws_json()]}),
    )
    .unwrap();
    let ids: Vec<&str> =
        out["agents"].as_array().unwrap().iter().map(|a| a["id"].as_str().unwrap()).collect();
    assert_eq!(&ids[..2], ["a", "b"], "chats sorted by id first");
    let rows = agent_rows(&[], &[ws]);
    assert_eq!(rows.len(), 1, "only a live agent terminal without a chat session");
    assert_eq!(rows[0].state, "waiting");
    assert_eq!(rows[0].machine, "mini");
}

fn ws_json() -> Value {
    json!({"isLocal": true, "machineId": "local", "tabs": [{"id": "t9", "title": "codex", "agent": {"state": "working", "updatedAtMs": 1}}]})
}

#[test]
fn fleet_trims_the_dashboard() {
    let data = json!({"updated":"2026-10-20T22:40:42Z","history":[1,2,3],
     "minis":[{"host":"cmux7s-mac-mini","error":null,"load":[12.5,11,15],"ncpu":14,"cpu_pct":37,"mem_free_pct":72},
              {"host":"aws-m4pro-9","error":"console locked","load":null,"ncpu":14}],
     "runners":[{"host":"cmux7s-mac-mini","status":"online","busy":true},{"host":"cmux7s-mac-mini","status":"online","busy":false},
                {"host":"cmux7s-mac-mini","status":"offline","busy":true}],
     "queued":[{"job":"a"},{"job":"b"}],
     "recent_prs":[{"pr":22640,"title":"cmux-next · b844","branch":"fix/x","status":"running"},{"pr":null}]});
    let reply = fleet_reply(&data).unwrap();
    assert_eq!(reply["updated"], "2026-10-20T22:40:42Z");
    assert_eq!(reply["queued"], 2);
    let machines = reply["machines"].as_array().unwrap();
    assert_eq!(machines.len(), 2);
    assert_eq!(machines[0]["load"], 12.5);
    assert_eq!(machines[0]["runnersBusy"], 1);
    assert_eq!(machines[0]["runnersOnline"], 2);
    assert_eq!(machines[1]["error"], "console locked");
    assert_eq!(machines[1]["load"], Value::Null);
    assert_eq!(reply["prs"].as_array().unwrap().len(), 1);
    let mut keys: Vec<&String> = reply.as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(keys, ["machines", "prs", "queued", "updated"]);
    assert!(fleet_reply(&json!({"other": 1})).is_none());
    let op = call("welcome.fleetReply", &json!({"body": "{\"other\":1}"})).unwrap();
    assert_eq!(op["reply"], Value::Null);
}

#[test]
fn dashboard_addresses_are_https_or_private_http() {
    assert!(valid_fleet_url(" https://ci.example.test:8444/ ").is_some());
    assert!(valid_fleet_url("http://ci.example.test/").is_none());
    assert!(valid_fleet_url("http://localhost:8444/").is_some());
    assert!(valid_fleet_url("http://mini.tail0.ts.net:8444/").is_some());
    assert!(valid_fleet_url("file:///etc/passwd").is_none());
    assert!(valid_fleet_url("https://user:pw@ci.example.test/").is_none());
    assert!(valid_fleet_url("not a url").is_none());
    assert_eq!(
        fleet_data_url("https://ci.example.test:8444/"),
        "https://ci.example.test:8444/data.json"
    );
    assert_eq!(
        fleet_data_url("https://ci.example.test/data.json"),
        "https://ci.example.test/data.json"
    );
}

#[test]
fn landing_reads_github_search() {
    let data = json!({"items":[{"number":22618,"title":"New Tab: dots","html_url":"https://github.com/manaflow-ai/cmux/pull/22618",
               "user":{"login":"teamleaderleo"},"labels":[{"name":"ready-to-land"}],"draft":false,
               "created_at":"2026-10-20T10:00:00Z","pull_request":{"merged_at":null}},
              {"number":1,"title":"elsewhere","html_url":"https://evil.example/pull/1"}]});
    let prs = landing_prs(&data).unwrap();
    assert_eq!(prs.len(), 1);
    assert_eq!(prs[0]["labels"], json!(["ready-to-land"]));
    assert_eq!(prs[0]["author"], "teamleaderleo");
    assert_eq!(prs[0]["mergedAt"], Value::Null);
    assert!(landing_prs(&json!({"message": "rate limited"})).is_none());
    let (open, merged) = landing_search_urls("2026-10-19");
    assert!(open.contains("is:open") || open.contains("is%3Aopen"));
    assert!(merged.contains("2026-10-19"));
    assert_eq!(search_day(1_792_535_000.0), "2026-10-19");
    assert!(valid_pull_request_url("https://github.com/manaflow-ai/cmux/pull/1").is_some());
    assert!(valid_pull_request_url("https://github.com/other/repo/pull/1").is_none());
    assert!(valid_pull_request_url("http://github.com/manaflow-ai/cmux/pull/1").is_none());
    assert!(
        valid_pull_request_url("https://github.com/manaflow-ai/cmux/../../other/repo").is_none()
    );
}
