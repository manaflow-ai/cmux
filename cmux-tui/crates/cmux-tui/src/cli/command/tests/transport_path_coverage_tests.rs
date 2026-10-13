use super::*;

#[test]
fn every_safe_transport_operation_has_a_noun_first_path() {
    const SESSION: &str = "session_00000000000000000000000000000002";
    const WORKSPACE: &str = "ws_00000000000000000000000000000004";
    const PANE: &str = "pane_00000000000000000000000000000006";
    const TERMINAL: &str = "term_00000000000000000000000000000008";
    const TAB: &str = "tab_00000000000000000000000000000007";
    // The case list is shared with `cmux mcp`'s parity test (command/cases.rs).
    let cases = cases::safe_operation_cases();

    let catalog = operation_catalog();
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
        (vec!["notify", "--workspace", "current", "--desktop", "false"], "notification.create"),
        (vec!["notify", "--workspace", "current", "--reply"], "notification.create"),
        (vec!["workspace", "create", "--cwd", "/tmp", "--", "make", "watch"], "workspace.create"),
        (vec!["workspace", "create", "--shell", "make watch"], "workspace.create"),
        (vec!["workspace", "group", "g", "update", "--clear-top-index"], "workspace_group.update"),
        // closed.delete takes either a group (with members) or all, and all
        // takes retention bounds.
        (vec!["closed", "c1", "delete", "--members", "1"], "closed.delete"),
        (vec!["closed", "clear", "--before-ms", "5", "--keep-newest", "3"], "closed.delete"),
        (vec!["pane", PANE, "run", "shell", "printf ok"], "pane.run"),
        (vec!["tab", TAB, "update", "--icon", "star.fill"], "tab.update"),
        // layout.bulk: one case in cases.rs; the other levels and --end-terminals.
        (vec!["workspace", WORKSPACE, "close", "--others", "--end-terminals"], "layout.bulk"),
        (vec!["screen", "current", "close", "--to-right"], "layout.bulk"),
        (vec!["pane", PANE, "close", "--all"], "layout.bulk"),
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
                "conversation",
                "conv_01J00000000000000000000000",
                "send",
                "--parts-json",
                r#"[{"type":"text","text":"hi"}]"#,
            ],
            "conversation.send",
        ),
        (
            vec![
                "git",
                "commit",
                "--path",
                "/repo",
                "--message",
                "m",
                "--all",
                "--include-untracked",
            ],
            "git.commit",
        ),
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
        .filter(|name| !cases::MULTI_REQUEST_OPERATIONS.contains(&name.as_str()))
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
                        // The Mac app edits the sidebar layout through its
                        // own sidebar actions and intent log.
                        | "sidebar_layout.get"
                        // The Mac app's palette is the one client of the
                        // user's palette usage history.
                        | "palette_usage.get"
                        | "palette_usage.record"
                        | "palette_usage.import"
                        | "palette_usage.hide"
                        | "palette_usage.forget"
                        | "sidebar_layout.update"
                        // The project list is the app's and its importers'
                        // (plans/cmux-next/projects.md); no CLI verb yet.
                        | "project.list"
                        | "project.observe"
                        | "project.add"
                        | "project.update"
                        | "project.remove"
                        | "project.sync"
                        // The hosting app creates its home workspace; the
                        // CLI never offers it (workspace-kind-v1).
                        | "workspace.ensure_home"
                        // The hosting app opens an app's workspace from its
                        // sidebar item (app-screens-v1); no CLI verb yet.
                        | "workspace.ensure_app"
                        // The verified app mints confirmations for its own
                        // page relay; the CLI is never that app.
                        | "origin.confirmation.issue"
                        // Only the user sets where a workspace's agents run,
                        // through the verified app (gate A2).
                        | "workspace.agent_folder.set"
                        // The app's agent pane asks where a new chat starts;
                        // an agent already runs in its folder (cx-9aps).
                        | "workspace.agent_start.get"
                        // Typing and live reply drafts are published by the
                        // participant's own client (the Chief's brain); the
                        // CLI's `cmux chief` only reads them.
                        | "conversation.typing"
                        | "conversation.draft"
                        // `cmux chief engine|stop` and the chat's /model,
                        // /effort and Ctrl+C send these (cli/chief), outside
                        // the noun grammar.
                        | "chief.engine.get"
                        | "chief.engine.set"
                        | "chief.stop"
                        // Launch credentials: acpmux and owners call these
                        // on the socket; an agent never mints or rotates.
                        | "credential.verify"
                        | "credential.mint"
                        | "credential.rotate"
                        // The daemon's settings ops (cx-9ce.10) have no
                        // noun-first CLI verb yet, as they have no MCP tool
                        // (83285ad2b3bf; cx-9ce.12, cx-ncc.32).
                        | "settings.get"
                        | "settings.list"
                        | "settings.reset"
                        | "settings.reset_all"
                        | "settings.schema"
                        | "settings.set"
                        | "settings.snapshot"
                        // The daemon's keybindings ops (cx-9ce.17) are the
                        // Keyboard Shortcuts page's, with no CLI verb or MCP
                        // tool yet, like the settings ops.
                        | "keybindings.get"
                        | "keybindings.remove"
                        | "keybindings.reset"
                        | "keybindings.set"
                        // History ops are reached through `cmux history`
                        // (cx-gzh.15), not the noun grammar; the page and
                        // omnibox ops are the browser host's and the app's.
                        | "history.entries.list"
                        | "history.entries.remove"
                        | "history.site.remove"
                        | "history.clear"
                        | "history.restore"
                        | "history.backups.purge"
                        | "history.visit.record"
                        | "history.visit.title"
                        | "history.visit.import"
                        | "history.visit.remove"
                        | "history.visit.summaries"
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
        // layout.bulk: the CLI names the anchor by its selector and has no
        // selection; apps and MCP send anchor and ids.
        ("layout.bulk", "anchor"),
        ("layout.bulk", "ids"),
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
