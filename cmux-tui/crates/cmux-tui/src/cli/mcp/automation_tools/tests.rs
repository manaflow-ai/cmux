use super::*;

fn w(name: &str, args: Value) -> Result<(Vec<String>, Option<String>), String> {
    let tool = TOOLS.iter().find(|t| t.name == name).unwrap();
    words(tool, args.as_object().unwrap())
}

#[test]
fn teleport_mcp_tool_arguments_become_the_cli_words() {
    let (create, key) = w(
        "automation_create",
        json!({"name": "Brief", "target": "cloud", "prompt": "--sum up", "weekdays": "09:00",
                   "private": true, "editors": ["user_a", "user_b"], "catch_up": "none",
                   "idempotency_key": "k-1"}),
    )
    .unwrap();
    assert_eq!(
        create,
        [
            "create",
            "--target",
            "cloud",
            "Brief",
            "--prompt=--sum up",
            "--weekdays=09:00",
            "--catch-up=none",
            "--private",
            "--editor=user_a",
            "--editor=user_b"
        ]
    );
    assert_eq!(key.as_deref(), Some("k-1"));
    let (run, key) = w("automation_run", json!({"automation": "Brief"})).unwrap();
    let key = key.unwrap();
    assert!(key.starts_with("mcp-automation-run-"));
    assert_eq!(run, ["run".to_string(), "Brief".into(), format!("--key={key}")]);
    assert_eq!(
        w("automation_teleport", json!({"automation": "Brief", "to": "ssh:mini"})).unwrap().0,
        ["teleport", "Brief", "--to=ssh:mini"]
    );
    assert_eq!(w("automation_audit", json!({})).unwrap().0, ["audit", "--target", "cloud"]);
    assert_eq!(
        w("automation_test", json!({"automation": "Crash", "event": "FATAL x"})).unwrap(),
        (vec!["test".to_string(), "Crash".into(), "--event=FATAL x".into()], None)
    );
    assert_eq!(
        w(
            "automation_create",
            json!({"name": "Crash", "command": "true", "watch": "tail -F a.log",
                       "debounce": "2s", "if": "grep -q FATAL", "cooldown": "1h", "max_runs": 3,
                       "idempotency_key": "k-2"}),
        )
        .unwrap()
        .0,
        [
            "create",
            "Crash",
            "--command=true",
            "--watch=tail -F a.log",
            "--debounce=2s",
            "--if=grep -q FATAL",
            "--cooldown=1h",
            "--max-runs=3"
        ]
    );
    // 0 turns the default watch cap off, as on the CLI.
    assert_eq!(
        w(
            "automation_create",
            json!({"name": "C", "command": "true", "watch": "w", "max_runs": 0})
        )
        .unwrap()
        .0
        .last()
        .map(String::as_str),
        Some("--max-runs=0")
    );
    assert_eq!(w("automation_list", json!({})).unwrap(), (vec!["list".to_string()], None));
    assert_eq!(w("automation_events", json!({})).unwrap(), (vec!["events".to_string()], None));
    assert!(w("automation_events", json!({"automation": "x"})).is_err(), "it only lists");
    assert_eq!(
        w(
            "automation_create",
            json!({"name": "Review", "prompt": "Review it", "when": "pr-opened",
                       "idempotency_key": "k-3"})
        )
        .unwrap()
        .0,
        ["create", "Review", "--prompt=Review it", "--when=pr-opened"]
    );
    assert_eq!(
        w(
            "automation_edit",
            json!({"automation": "Review", "when": "agent-idle", "idempotency_key": "k-4"})
        )
        .unwrap()
        .0,
        ["edit", "Review", "--when=agent-idle"]
    );
    assert_eq!(
        w("automation_runs", json!({"automation": "Brief", "limit": 5})).unwrap().0,
        ["history", "Brief", "--limit=5"]
    );
    for bad in [
        json!({"automation": "--all"}),
        json!({"automation": "x", "target": "mars"}),
        json!({"automation": "x", "extra": 1}),
    ] {
        assert!(w("automation_pause", bad.clone()).is_err(), "{bad}");
    }
    assert!(w("automation_get", json!({})).is_err(), "automation is required");
    let names: Vec<_> =
        descriptors().iter().map(|d| d["name"].as_str().unwrap().to_string()).collect();
    assert_eq!(names.len(), 13);
    let create = descriptors().into_iter().find(|d| d["name"] == "automation_create").unwrap();
    assert_eq!(
        create["inputSchema"]["properties"]["when"]["enum"],
        json!(["agent-idle", "agent-needs-input", "pr-opened"])
    );
    assert!(create["description"].as_str().unwrap().contains("pr-opened"));
    assert!(names.iter().all(|n| n.starts_with("automation_")));
}
