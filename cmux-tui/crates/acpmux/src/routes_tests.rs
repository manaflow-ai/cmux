use super::*;

#[test]
fn generic_route_creation_refuses_claude_tokens_but_existing_files_still_load() {
    let dir = tempfile::tempdir().unwrap();
    let error = file_from_json(&json!({
        "kind": "claude-token",
        "families": ["claude"],
        "secret": "keychain:fixture",
    }))
    .unwrap_err();
    assert!(error.to_string().contains("cmux cloud connect claude"));

    std::fs::write(
        dir.path().join("claude-token.toml"),
        "kind = \"claude-token\"\nfamilies = [\"claude\"]\nsecret = \"keychain:fixture\"\n",
    )
    .unwrap();
    let (routes, problems) = load(Some(dir.path()));
    assert!(problems.is_empty(), "{problems:?}");
    assert_eq!(routes.len(), 1);
    assert_eq!(routes[0].file.kind, RouteKind::ClaudeToken);
}

#[test]
fn failed_route_move_preserves_every_saved_binding() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("config");
    let home = root.path().join("state");
    let id = "work-key";
    let file = file_from_json(&json!({
        "kind": "direct-api-key", "families": ["claude"], "secret": "env:WORK_KEY",
    }))
    .unwrap();
    let route = add(Some(&dir), id, &file, false).unwrap();
    let before = update_bindings(&home, |b| {
        b.chats.insert("chat".into(), id.into());
        b.workspaces.insert("workspace".into(), id.into());
        b.families.insert("claude".into(), id.into());
        b.global = Some(id.into());
        b.connection_order = vec![id.into(), "other".into()];
    })
    .unwrap();

    // Make the rename fail after the route has been found and validated.
    let held = dir.join("held");
    assert!(
        remove_with(
            Some(&dir),
            &home,
            id,
            None,
            |route| {
                std::fs::rename(&route.path, &held).unwrap();
                Ok(())
            },
            |error| error,
        )
        .is_err()
    );
    std::fs::rename(held, route.path).unwrap();
    assert_eq!(bindings(&home), before);
    assert!(bindings_with_disconnects(&home).disconnected_credentials.is_empty());
}

#[test]
fn legacy_opt_out_is_migrated_to_an_unresolvable_reference() {
    let instance = uuid::Uuid::new_v4().to_string();
    let legacy_notes = crate::agent_credentials::with_stored_instance(
        "# cmux-cloud-enabled: false anthropic\nWork connection",
        &instance,
    );
    for (fields, prior_instance) in [
        (
            "secret = \"env:WORK_KEY\"\nnotes = \"Work connection\"\ncloud_enabled = false\n"
                .to_owned(),
            None,
        ),
        (
            format!("secret = \"local-only:env:WORK_KEY\"\nnotes = '''{legacy_notes}'''\n"),
            Some(instance.as_str()),
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("work-key.toml");
        let route_dir = Some(dir.path());
        std::fs::write(
            &path,
            format!("kind = \"direct-api-key\"\nfamilies = [\"claude\"]\n{fields}"),
        )
        .unwrap();
        assert_eq!(find(route_dir, "work-key").unwrap().file.cloud_enabled, Some(false));
        let saved = for_credential(route_dir, "work-key").unwrap();
        let saved_instance = saved.file.credential_instance.as_deref().unwrap();
        if let Some(prior_instance) = prior_instance {
            assert_eq!(saved_instance, prior_instance);
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let mut older: RouteFile = toml::from_str(&text).unwrap();
        validate(&older).unwrap();
        assert!(resolve_reference(older.secret.as_deref().unwrap()).is_err());
        assert_eq!(saved.file.notes.as_deref(), Some("Work connection"));
        assert_eq!(saved.file.secret.as_deref(), Some("env:WORK_KEY"));
        assert_eq!(saved.file.cloud_enabled, Some(false));

        older.name = Some("Renamed in the older build".into());
        std::fs::write(&path, toml::to_string_pretty(&older).unwrap()).unwrap();
        let renamed = find(route_dir, "work-key").unwrap();
        assert_eq!(renamed.file.name, older.name);
        assert_eq!(renamed.file.secret, saved.file.secret);
        assert_eq!(renamed.file.notes, saved.file.notes);
        assert_eq!(renamed.file.cloud_enabled, Some(false));
        assert_eq!(renamed.file.credential_instance, saved.file.credential_instance);

        let backup = remove(route_dir, dir.path(), "work-key").unwrap();
        let restored = restore(route_dir, dir.path(), &backup).unwrap();
        assert_eq!(restored.file.secret, saved.file.secret);
        assert_eq!(restored.file.cloud_enabled, Some(false));
        assert_ne!(restored.file.credential_instance, saved.file.credential_instance);
        let older: RouteFile =
            toml::from_str(&std::fs::read_to_string(restored.path).unwrap()).unwrap();
        validate(&older).unwrap();
        assert!(resolve_reference(older.secret.as_deref().unwrap()).is_err());
    }
}

#[test]
fn older_rename_preserves_a_claude_tokens_disconnect_identity() {
    for legacy in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let routes = Some(dir.path());
        let added = add_claude_token(routes, "keychain:fixture", None).unwrap();
        let instance = added.file.credential_instance.as_deref().unwrap();
        if legacy {
            // The previous writer stored the instance only in the TOML comment.
            let legacy_text = toml::to_string_pretty(&added.file).unwrap();
            std::fs::write(
                &added.path,
                crate::agent_credentials::with_stored_instance(&legacy_text, instance),
            )
            .unwrap();
        }
        let delivered = for_credential(routes, &added.id).unwrap();
        assert_eq!(delivered.file.credential_instance.as_deref(), Some(instance));

        let text = std::fs::read_to_string(&added.path).unwrap();
        // The older account writer retains notes and drops all TOML comments.
        let mut older: RouteFile = toml::from_str(&text).unwrap();
        older.name = Some("Renamed in the older build".into());
        std::fs::write(&added.path, toml::to_string_pretty(&older).unwrap()).unwrap();
        let renamed = find(routes, &added.id).unwrap();
        assert_eq!(renamed.file.name, older.name);
        assert_eq!(renamed.file.notes.as_deref(), Some(CLAUDE_TOKEN_NOTES));
        assert_eq!(renamed.file.credential_instance.as_deref(), Some(instance));

        remove_with(routes, dir.path(), &added.id, Some(instance), |_| Ok(()), |e| e).unwrap();
        assert!(
            bindings_with_disconnects(dir.path()).disconnected_credentials[&added.id]
                .contains(instance)
        );
    }
}

#[test]
fn older_rename_preserves_the_instance_delivered_by_an_implicit_cloud_key() {
    for (family, provider) in [("claude", "anthropic"), ("codex", "openai")] {
        for comment_only in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let route_dir = Some(dir.path());
            let id = "work-key";
            let path = dir.path().join(format!("{id}.toml"));
            let text = format!(
                "# Comment on this key\nkind = \"direct-api-key\"\nprovider = \"{provider}\"\nfamilies = [\"{family}\"]\nsecret = \"env:WORK_KEY\"\nnotes = \"Work connection\"\n"
            );
            let prior = comment_only.then(|| uuid::Uuid::new_v4().to_string());
            let text = match &prior {
                Some(instance) => crate::agent_credentials::with_stored_instance(&text, instance),
                None => text,
            };
            std::fs::write(&path, text).unwrap();

            let delivered = for_credential(route_dir, id).unwrap().file;
            let instance = delivered.credential_instance.unwrap();
            assert_eq!(delivered.cloud_enabled, None);
            if let Some(prior) = prior {
                assert_eq!(instance, prior);
            }

            // The base account writer retains known fields, including notes, and drops comments.
            let text = std::fs::read_to_string(&path).unwrap();
            assert!(text.contains("# Comment on this key"));
            let mut older: RouteFile = toml::from_str(&text).unwrap();
            older.name = Some("Renamed in the older build".into());
            std::fs::write(&path, toml::to_string_pretty(&older).unwrap()).unwrap();
            let renamed = for_credential(route_dir, id).unwrap().file;
            assert_eq!(renamed.name, older.name);
            assert_eq!(renamed.notes.as_deref(), Some("Work connection"));
            assert_eq!(renamed.cloud_enabled, None);
            assert_eq!(renamed.credential_instance.as_deref(), Some(instance.as_str()));

            remove_with(route_dir, dir.path(), id, Some(&instance), |_| Ok(()), |e| e).unwrap();
            assert!(bindings(dir.path()).disconnected_credentials[id].contains(&instance));
        }
    }
}

#[test]
fn replacing_direct_api_key_preserves_cloud_opt_out() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path();
    let mut file = file_from_json(&json!({
        "kind": "direct-api-key",
        "families": ["claude"],
        "secret": "env:ROUTES_TEST_KEY",
    }))
    .unwrap();
    file.cloud_enabled = Some(false);
    add(Some(path), "work-key", &file, false).unwrap();

    let replacement = file_from_json(&json!({
        "kind": "direct-api-key",
        "families": ["claude"],
        "secret": "env:WORK_REPLACEMENT_KEY",
        "replace": true,
    }))
    .unwrap();
    add(Some(path), "work-key", &replacement, true).unwrap();
    let saved = find(Some(path), "work-key").unwrap().file;
    assert_eq!(saved.cloud_enabled, Some(false));
    assert_eq!(saved.secret.as_deref(), Some("env:WORK_REPLACEMENT_KEY"));

    for cloud_enabled in [None, Some(true)] {
        file.cloud_enabled = cloud_enabled;
        let route = add(Some(path), "default-key", &file, true).unwrap();
        let text = std::fs::read_to_string(route.path).unwrap();
        assert!(!text.contains("cloud_enabled"));
        assert_eq!(file_from_toml(&text).unwrap().cloud_enabled, cloud_enabled);
    }
}
