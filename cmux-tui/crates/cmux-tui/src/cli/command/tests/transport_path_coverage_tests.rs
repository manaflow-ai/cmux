use super::*;

#[test]
fn every_safe_transport_operation_has_a_noun_first_path() {
    const SESSION: &str = "session_00000000000000000000000000000002";
    const WORKSPACE: &str = "ws_00000000000000000000000000000004";
    const PANE: &str = "pane_00000000000000000000000000000006";
    const TERMINAL: &str = "term_00000000000000000000000000000008";
    // The case list is shared with `cmux mcp`'s parity test (command/cases.rs).
    let cases = cases::safe_operation_cases();

    assert_eq!(cases.len(), 181);
    let catalog = operation_catalog();
    assert_eq!(catalog["operations"].as_object().unwrap().len(), 193);
    let mut seen = std::collections::BTreeSet::new();
    let mut covered_fields = BTreeMap::<&str, std::collections::BTreeSet<String>>::new();
    for (args, expected) in &cases {
        let plan = protocol(args);
        assert_eq!(operation(&plan), *expected, "{args:?}");
        assert_plan_matches_catalog(&plan, expected, &catalog);
        assert!(seen.insert(*expected), "duplicate operation case {expected}");
        record_covered_fields(&plan, expected, &catalog, &mut covered_fields);

        if catalog["operations"][expected]["params"]["fields"]["expected_revision"].is_object() {
            let mut with_revision = args.clone();
            let insert_at = with_revision
                .iter()
                .position(|value| *value == "--")
                .unwrap_or(with_revision.len());
            with_revision.splice(insert_at..insert_at, ["--expected-revision", "7"]);
            let revised = protocol(&with_revision);
            assert_eq!(
                revised.params["expected_revision"], "7",
                "{expected} did not expose optimistic concurrency"
            );
            assert_plan_matches_catalog(&revised, expected, &catalog);
            record_covered_fields(&revised, expected, &catalog, &mut covered_fields);
        }
    }
    for (args, expected) in [
        (vec!["workspace", WORKSPACE, "run", "shell", "printf ok"], "workspace.run"),
        (vec!["workspace", "group", "g", "update", "--clear-top-index"], "workspace_group.update"),
        (vec!["pane", PANE, "run", "shell", "printf ok"], "pane.run"),
        (
            vec![
                "session",
                SESSION,
                "journal",
                "subscribe",
                "--cursor-session",
                SESSION,
                "--sequence",
                "42",
            ],
            "session.journal.subscribe",
        ),
        (vec!["terminal", TERMINAL, "write", "--bytes-base64", "AA=="], "terminal.input.write"),
        (vec!["git", "checkpoint", "get", "--path", "/repo", "--key", "k1"], "git.checkpoint.get"),
        (
            vec![
                "terminal",
                TERMINAL,
                "mouse",
                "wheel",
                "--row",
                "4",
                "--column",
                "7",
                "--delta-rows",
                "-2",
            ],
            "terminal.input.mouse",
        ),
    ] {
        let plan = protocol(&args);
        record_covered_fields(&plan, expected, &catalog, &mut covered_fields);
    }
    let expected = catalog["operations"]
        .as_object()
        .unwrap()
        .keys()
        .filter(|name| {
            !matches!(
                name.as_str(),
                "browser.viewer.release"
                        | "browser.viewer.resize"
                        | "request.cancel"
                        | "stream.cancel"
                        | "terminal.renderer_grant.create"
                        | "terminal.viewer.release"
                        | "terminal.viewer.resize"
                        // Window records have one writer, the app that hosts
                        // the window (OWNERSHIP-PRINCIPLES); the CLI reads app
                        // windows through `cmux window list`.
                        | "window_record.list"
                        | "window_record.put"
                        | "window_record.delete"
                        // The hosting app creates its home workspace; the
                        // CLI never offers it (workspace-kind-v1).
                        | "workspace.ensure_home"
                        // The verified app mints confirmations for its own
                        // page relay; the CLI is never that app.
                        | "origin.confirmation.issue"
            )
        })
        .map(String::as_str)
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(seen, expected, "safe CLI operation coverage drifted from the catalog");
    // Fields only the app that hosts a browser page writes (its record's
    // owner and history list), and a connection's own capability set; the
    // CLI never sets them.
    let app_owned = [
        ("tab.update", "owner"),
        ("tab.update", "back"),
        ("tab.update", "forward"),
        ("client.metadata.update", "capabilities"),
    ];
    for operation in &expected {
        let catalog_fields = catalog["operations"][operation]["params"]["fields"]
            .as_object()
            .unwrap()
            .keys()
            .filter(|field| !app_owned.contains(&(*operation, field.as_str())))
            .cloned()
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            covered_fields.get(operation).cloned().unwrap_or_default(),
            catalog_fields,
            "{operation} has catalog fields with no exercised CLI representation"
        );
    }
}
