use super::*;

fn topology() -> Value {
    json!({
        "registry_id": "registry-one",
        "generation": "generation-one",
        "workspace_revision": 11,
        "pane_revision": 12,
        "terminal_revision": 13,
        "workspaces": [
            {
                "resource_id": "ws_one",
                "key": "workspace-one",
                "screens": [{"panes": [
                    {"tabs": [
                        {"kind":"pty","terminal_resource_id":"term_one","tab_resource_id":"tab_terminal"},
                        {"kind":"browser","tab_resource_id":"tab_same_pane"}
                    ]},
                    {"tabs": [{"kind":"browser","tab_resource_id":"tab_other_pane"}]}
                ]}]
            },
            {
                "resource_id": "ws_two",
                "key": "workspace-two",
                "screens": [{"panes": [{"tabs": [
                    {"kind":"pty","terminal_resource_id":"term_two","tab_resource_id":"tab_terminal_two"},
                    {"kind":"browser","tab_resource_id":"tab_two"}
                ]}]}]
            }
        ]
    })
}

fn provider() -> Value {
    json!({
        "available": true,
        "provider_id": "provider-one",
        "endpoint": "ws://127.0.0.1:9222/devtools/browser/browser-one",
        "authentication": "none",
        "revision": 17,
        "targets": [
            {"tab_id":"tab_same_pane","target_id":"target-one"},
            {"tab_id":"tab_other_pane","target_id":"target-other"},
            {"tab_id":"tab_two","target_id":"target-two"}
        ]
    })
}

fn targets() -> BTreeMap<String, String> {
    [("tab_same_pane", "target-one"), ("tab_other_pane", "target-other"), ("tab_two", "target-two")]
        .into_iter()
        .map(|(tab, target)| (tab.to_string(), target.to_string()))
        .collect()
}

#[test]
fn caller_terminal_selects_same_pane_without_using_active_state() {
    let scope = ProviderScope { terminal: Some("term_one".into()), ..Default::default() };
    let selected = select_workspace_target(&topology(), &targets(), &scope).unwrap();
    assert_eq!(selected.tab_id, "tab_same_pane");
    assert_eq!(selected.selection, "terminal-workspace");
}

#[test]
fn trusted_terminal_is_not_constrained_by_a_session_name() {
    let scope = ProviderScope {
        terminal: Some("term_one".into()),
        session_hint: Some("unrelated-outer-session".into()),
        ..Default::default()
    };

    let selected = select_workspace_target(&topology(), &targets(), &scope).unwrap();

    assert_eq!(selected.tab_id, "tab_same_pane");
    assert_eq!(selected.selection, "terminal-workspace");
}

#[test]
fn workspace_and_exact_tab_scopes_are_deterministic() {
    let workspace = ProviderScope { workspace: Some("workspace-two".into()), ..Default::default() };
    assert_eq!(
        select_workspace_target(&topology(), &targets(), &workspace).unwrap().tab_id,
        "tab_two"
    );
    let exact = ProviderScope { exact_tab: Some("tab_other_pane".into()), ..Default::default() };
    assert_eq!(
        select_workspace_target(&topology(), &targets(), &exact).unwrap().target_id,
        "target-other"
    );
}

#[test]
fn mirrored_terminal_uses_the_callers_workspace_placement() {
    let mut topology = topology();
    topology["workspaces"][1]["screens"][0]["panes"][0]["tabs"][0]["terminal_resource_id"] =
        json!("term_one");
    let scope = ProviderScope {
        workspace: Some("workspace-one".into()),
        terminal: Some("term_one".into()),
        ..Default::default()
    };

    let selected = select_workspace_target(&topology, &targets(), &scope).unwrap();

    assert_eq!(selected.workspace_id, "ws_one");
    assert_eq!(selected.tab_id, "tab_same_pane");
    assert_eq!(selected.selection, "terminal-workspace");
}

#[test]
fn mirrored_terminal_without_a_workspace_scope_is_rejected() {
    let mut topology = topology();
    topology["workspaces"][1]["screens"][0]["panes"][0]["tabs"][0]["terminal_resource_id"] =
        json!("term_one");
    let scope = ProviderScope { terminal: Some("term_one".into()), ..Default::default() };

    let error = select_workspace_target(&topology, &targets(), &scope)
        .err()
        .expect("an unscoped mirrored terminal must be ambiguous");

    assert!(error.to_string().contains("multiple cmux placements"));
    assert!(error.to_string().contains("CMUX_TUI_BROWSER_TAB_ID"));
}

#[test]
fn stable_topology_and_provider_revisions_allow_target_resolution() {
    ensure_stable_resolution(&topology(), &provider(), &topology(), &provider()).unwrap();
    let scope = ProviderScope { terminal: Some("term_one".into()), ..Default::default() };

    let resolved = resolve_page_target_snapshot(&topology(), &provider(), &scope).unwrap();

    assert_eq!(resolved.tab_id, "tab_same_pane");
    assert_eq!(resolved.provider_revision, 17);
}

#[test]
fn changing_topology_or_provider_revision_retries_resolution() {
    let mut changed_topology = topology();
    changed_topology["pane_revision"] = json!(13);
    let error = ensure_stable_resolution(&topology(), &provider(), &changed_topology, &provider())
        .unwrap_err();
    assert!(error.to_string().contains("changed during target resolution"));

    let mut changed_provider = provider();
    changed_provider["revision"] = json!(18);
    let error = ensure_stable_resolution(&topology(), &provider(), &topology(), &changed_provider)
        .unwrap_err();
    assert!(error.to_string().contains("changed during target resolution"));
}

#[test]
fn direct_page_url_preserves_gateway_query_and_escapes_target() {
    assert_eq!(
        direct_page_url(
            "ws://127.0.0.1:9222/devtools/browser/browser-id?gateway=one",
            "target/with space"
        )
        .unwrap(),
        "ws://127.0.0.1:9222/devtools/page/target%2Fwith%20space?gateway=one"
    );
}

#[test]
fn control_response_limit_is_enforced_while_streaming() {
    let (reader, mut writer) = UnixStream::pair().unwrap();
    let writer = std::thread::spawn(move || writer.write_all(b"12345678\n").unwrap());
    let error =
        read_control_line(&mut BufReader::new(reader), Instant::now() + Duration::from_secs(1), 8)
            .unwrap_err();
    writer.join().unwrap();

    assert!(error.to_string().contains("response exceeds 16 MiB"));
}

// hq-f8: on macOS, setsockopt(SO_RCVTIMEO) fails with EINVAL once the peer has
// closed. A response the peer wrote just before it closed is still buffered and
// must be read, not lost to that error. The peer writes and closes before the read.
#[test]
fn buffered_response_is_read_after_the_peer_closed() {
    let (reader, mut writer) = UnixStream::pair().unwrap();
    writer.write_all(b"{\"id\":1}\n").unwrap();
    drop(writer);
    let line = read_control_line(
        &mut BufReader::new(reader),
        Instant::now() + Duration::from_secs(1),
        RESPONSE_LIMIT,
    )
    .unwrap();

    assert_eq!(line, b"{\"id\":1}\n");
}

#[test]
fn control_response_limit_is_enforced_after_the_peer_closed() {
    let (reader, mut writer) = UnixStream::pair().unwrap();
    writer.write_all(b"12345678\n").unwrap();
    drop(writer);
    let error =
        read_control_line(&mut BufReader::new(reader), Instant::now() + Duration::from_secs(1), 8)
            .unwrap_err();

    assert!(error.to_string().contains("response exceeds 16 MiB"), "{error:#}");
}

#[test]
fn manifest_does_not_touch_the_mux_socket() {
    let response = handle_plugin_request(json!({
        "protocol": PLUGIN_PROTOCOL,
        "type": "plugin.manifest",
        "capability": "plugin.manifest",
        "request": {}
    }))
    .unwrap();
    assert_eq!(response["success"], true);
    assert_eq!(response["manifest"]["name"], PLUGIN_NAME);
}
