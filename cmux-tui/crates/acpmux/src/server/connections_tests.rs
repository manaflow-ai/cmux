use super::*;

fn conn(id: &str, kind: &'static str, signed_in: bool, default_for: &[&str]) -> Connection {
    Connection {
        id: id.into(),
        credential_instance: None,
        key_revision: None,
        kind,
        provider: "openai".into(),
        families: vec!["codex".into()],
        label: id.into(),
        email: None,
        plan: None,
        signed_in,
        sign_in_reason: None,
        enabled: true,
        default_for: default_for.iter().map(|f| (*f).to_owned()).collect(),
        serves_cloud: true,
        can_serve_cloud: true,
        can_check_access: kind == "api-key",
        can_replace_key: None,
        endpoint: None,
        expires_at: None,
        endpoint_credentials: None,
        cloud_families: None,
        launch_harness: None,
    }
}

fn ids(list: &[Connection]) -> Vec<&str> {
    list.iter().map(|c| c.id.as_str()).collect()
}

#[test]
fn the_default_order_is_picker_defaults_then_signed_in_accounts_then_keys() {
    let listed = vec![
        conn("codex-login", "codex-login", true, &[]),
        conn("openai-key", "api-key", true, &[]),
        conn("chatgpt", "chatgpt-plan", true, &[]),
        conn("work", "subscription", false, &[]),
        conn("codex-2", "subscription", true, &["codex"]),
        conn("claude-login", "claude-login", true, &["claude"]),
    ];
    assert_eq!(
        ids(&ordered(listed.clone(), &[])),
        ["codex-2", "claude-login", "codex-login", "chatgpt", "openai-key", "work"]
    );
    // The person's order first; ids that are gone are skipped; the rest keep the default.
    let explicit = vec!["openai-key".to_owned(), "gone".to_owned(), "work".to_owned()];
    assert_eq!(
        ids(&ordered(listed, &explicit)),
        ["openai-key", "work", "codex-2", "claude-login", "codex-login", "chatgpt"]
    );
}

struct Dirs {
    _root: tempfile::TempDir,
    routes: PathBuf,
    home: PathBuf,
}

fn dirs() -> Dirs {
    let root = tempfile::tempdir().unwrap();
    let (routes, home) = (root.path().join("routes"), root.path().join("home"));
    std::fs::create_dir_all(&routes).unwrap();
    Dirs { _root: root, routes, home }
}

fn state_ids(state: &Value) -> Vec<String> {
    state["connections"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn replacing_a_cloud_key_requires_consent_for_a_new_credential() {
    let first = dirs();
    let second = dirs();
    let sources = ProfileSources::none();
    let connection = |d: &Dirs, key: &str| {
        let (id, _) =
            add_key(Some(&d.routes), &d.home, "anthropic", key, None, &sources, Some(true))
                .unwrap();
        let (_, _, _, _, instance) =
            credential_plan(Some(&d.routes), &d.home, &id, &ProfileSources::none()).unwrap();
        (id, instance.unwrap())
    };
    let (id, original) = connection(&first, "keychain:first");
    let (other_id, other_instance) = connection(&second, "keychain:second");
    assert_eq!(id, other_id);
    assert_ne!(original, other_instance);

    let replacement = replace_key(
        Some(&first.routes),
        &first.home,
        &id,
        "anthropic",
        "keychain:rotated",
        &original,
        &sources,
    )
    .unwrap();
    let row = find(&replacement, &id);
    let replacement_instance = row["credential_instance"].as_str().unwrap();
    assert_ne!(replacement_instance, original);
    assert_eq!(row["serves_cloud"], false);
    assert_eq!(replacement["disconnected_credentials"][&id], json!([&original]));
    assert_eq!(
        credential_plan(Some(&first.routes), &first.home, &id, &sources).unwrap_err().data.unwrap()
            ["reason"],
        "connections.not_cloud"
    );

    routes::edit(Some(&first.routes), &id, |file| {
        file.cloud_enabled = Some(true);
        Ok(())
    })
    .unwrap();
    let (_, _, _, reference, instance) =
        credential_plan(Some(&first.routes), &first.home, &id, &ProfileSources::none()).unwrap();
    assert_eq!(reference.as_deref(), Some("keychain:rotated"));
    assert_eq!(instance.as_deref(), Some(replacement_instance));

    routes::remove(Some(&first.routes), &first.home, &id).unwrap();
    let (reused_id, new_instance) = connection(&first, "keychain:new");
    assert_eq!(reused_id, id);
    assert_ne!(new_instance, original);
    assert!(
        replace_key(
            Some(&first.routes),
            &first.home,
            &id,
            "anthropic",
            "keychain:stale",
            &original,
            &sources,
        )
        .is_err()
    );
    let (_, _, _, reference, instance) =
        credential_plan(Some(&first.routes), &first.home, &id, &ProfileSources::none()).unwrap();
    assert_eq!(reference.as_deref(), Some("keychain:new"));
    assert_eq!(instance.as_deref(), Some(new_instance.as_str()));
}

#[test]
fn legacy_anthropic_keys_without_an_explicit_provider_serve_cloud() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let path = d.routes.join("work.toml");
    std::fs::write(
        &path,
        r#"
# Existing route
kind = "direct-api-key"
families = ["claude"]
anthropic_base_url = "https://api.anthropic.com"
secret = "keychain:work"
"#,
    )
    .unwrap();
    // A directory where the lock file goes makes every route write fail.
    let lock = d.routes.join(".route-write.lock");
    std::fs::create_dir(&lock).unwrap();
    let row = connection_state(dir, &d.home, "work", &ProfileSources::none());
    assert_eq!(row["connection"]["serves_cloud"], true);
    assert!(credential_plan(dir, &d.home, "work", &ProfileSources::none()).unwrap().4.is_none());
    std::fs::remove_dir(&lock).unwrap();

    let (family, kind, var, secret, instance) =
        credential_plan(dir, &d.home, "work", &ProfileSources::none()).unwrap();
    assert_eq!(
        (family.as_str(), kind, var, secret.as_deref()),
        ("claude", "api-key", "ANTHROPIC_API_KEY", Some("keychain:work"))
    );
    assert!(instance.is_some());
    assert_eq!(routes::find(dir, "work").unwrap().file.credential_instance, instance);

    // Legacy readers can still decode the same TOML document, and its comments survived.
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(toml::from_str::<RouteFile>(&text).unwrap().credential_instance.is_none());
    assert!(text.contains("# Existing route"));
}

#[test]
fn existing_direct_keys_keep_cloud_with_implicit_or_slash_terminated_urls() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let sources = ProfileSources::none();
    for (provider, family, field, official, variable) in [
        (
            "anthropic",
            "claude",
            "anthropic_base_url",
            "https://api.anthropic.com/",
            "ANTHROPIC_API_KEY",
        ),
        ("openai", "codex", "openai_base_url", "https://api.openai.com/v1/", "OPENAI_API_KEY"),
    ] {
        for (suffix, url) in [
            ("implicit", None),
            ("official", Some(official)),
            ("custom", Some("https://models.example/v1")),
        ] {
            let id = format!("{provider}-{suffix}");
            let mut file = json!({
                "kind": "direct-api-key", "families": [family], "secret": "keychain:work",
            });
            if let Some(url) = url {
                file[field] = json!(url);
            }
            routes::add(dir, &id, &serde_json::from_value(file).unwrap(), false).unwrap();
            let listed = state(dir, &d.home, &sources);
            let cloud = suffix != "custom";
            assert_eq!(find(&listed, &id)["can_serve_cloud"], cloud, "{id}");
            assert_eq!(find(&listed, &id)["serves_cloud"], cloud, "{id}");
            let credential = credential_plan(dir, &d.home, &id, &sources);
            if cloud {
                let (served, _, key_env, _, _) = credential.unwrap();
                assert_eq!((served.as_str(), key_env), (family, variable));
            } else {
                assert_eq!(
                    credential.unwrap_err().data.unwrap()["reason"],
                    "connections.not_cloud"
                );
            }
        }
    }
}

#[test]
fn order_set_refuses_an_unknown_id_and_stores_a_known_order() {
    let d = dirs();
    let (_, _) = add_key(
        Some(&d.routes),
        &d.home,
        "anthropic",
        "keychain:cmux-test-key",
        None,
        &ProfileSources::none(),
        None,
    )
    .unwrap();
    let error = set_order(Some(&d.routes), &d.home, &["nope".to_owned()], &ProfileSources::none())
        .unwrap_err();
    assert_eq!(error.data.as_ref().unwrap()["reason"], "connections.unknown_id");
    assert!(routes::bindings(&d.home).connection_order.is_empty(), "nothing stored");
    let twice = vec!["anthropic-key".to_owned(), "anthropic-key".to_owned()];
    assert!(set_order(Some(&d.routes), &d.home, &twice, &ProfileSources::none()).is_err());

    let state = set_order(
        Some(&d.routes),
        &d.home,
        &[
            "cursor-native-login".to_owned(),
            "anthropic-key".to_owned(),
            "grok-native-login".to_owned(),
            "gemini-login".to_owned(),
        ],
        &ProfileSources::none(),
    )
    .unwrap();
    assert_eq!(state["order_explicit"], true);
    assert_eq!(state_ids(&state)[0], "anthropic-key");
    assert_eq!(routes::bindings(&d.home).connection_order, ["anthropic-key"]);
    let text = std::fs::read_to_string(d.home.join("routes/bindings.json")).unwrap();
    assert!(text.contains("\"connection_order\""), "{text}");
    // Removing the route drops it from the order.
    routes::remove(Some(&d.routes), &d.home, "anthropic-key").unwrap();
    assert!(routes::bindings(&d.home).connection_order.is_empty());
}

#[test]
fn spread_defaults_off_and_is_stored() {
    let d = dirs();
    assert_eq!(state(Some(&d.routes), &d.home, &ProfileSources::none())["spread"], false);
    assert_eq!(
        set_spread(Some(&d.routes), &d.home, true, &ProfileSources::none()).unwrap()["spread"],
        true
    );
    assert_eq!(routes::bindings(&d.home).spread, Some(true));
}

#[test]
fn a_key_is_added_as_a_reference_and_listed_with_its_provider() {
    let d = dirs();
    let inline = add_key(
        Some(&d.routes),
        &d.home,
        "openrouter",
        "sk-or-v1-abc",
        None,
        &ProfileSources::none(),
        None,
    );
    assert_eq!(inline.unwrap_err().data.unwrap()["reason"], "route.secret_inline");
    assert!(
        add_key(
            Some(&d.routes),
            &d.home,
            "mistral",
            "keychain:x",
            None,
            &ProfileSources::none(),
            None,
        )
        .is_err()
    );
    let (id, state) = add_key(
        Some(&d.routes),
        &d.home,
        "openrouter",
        "keychain:cmux-or",
        Some("Mine"),
        &ProfileSources::none(),
        None,
    )
    .unwrap();
    assert_eq!(id, "openrouter-key");
    let key = state["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "openrouter-key")
        .cloned()
        .unwrap();
    assert_eq!(key["kind"], "api-key");
    assert_eq!(key["provider"], "openrouter");
    assert_eq!(key["families"], json!(["claude", "codex", "openrouter"]));
    assert_eq!(key["label"], "Mine");
    assert_eq!(key["signed_in"], true);
    assert_eq!(key["can_check_access"], true);
    assert_eq!(key["serves_cloud"], false);
    assert_eq!(key["can_serve_cloud"], false);
    let (second, _) = add_key(
        Some(&d.routes),
        &d.home,
        "openrouter",
        "keychain:cmux-or-2",
        None,
        &ProfileSources::none(),
        None,
    )
    .unwrap();
    assert_eq!(second, "openrouter-key-2");
    let route = routes::find(Some(&d.routes), "openrouter-key").unwrap();
    assert_eq!(route.file.secret.as_deref(), Some("keychain:cmux-or"));
    assert_eq!(route.file.provider.as_deref(), Some("openrouter"));
}

#[test]
fn access_check_will_only_send_saved_keys_to_their_configured_provider() {
    let d = dirs();
    let (id, _) = add_key(
        Some(&d.routes),
        &d.home,
        "google",
        "keychain:cmux-google",
        None,
        &ProfileSources::none(),
        None,
    )
    .unwrap();
    let mut file = routes::find(Some(&d.routes), &id).unwrap().file;
    let (base, kind) = standard_key_endpoint(&file).unwrap();
    assert_eq!(
        crate::byo_endpoint::models_url(kind, base),
        "https://generativelanguage.googleapis.com/v1beta/openai/models"
    );
    file.openai_base_url = Some("https://example.com/v1".into());
    assert!(standard_key_endpoint(&file).is_none());
    file.openai_base_url = None;
    assert!(standard_key_endpoint(&file).is_none());
}

fn secret_file(d: &Dirs, name: &str, value: &str) -> String {
    let path = d._root.path().join(name);
    std::fs::write(&path, format!("{value}\n")).unwrap();
    crate::router_socket::owner_only(&path);
    format!("file:{}", path.display())
}

fn find<'a>(state: &'a Value, id: &str) -> &'a Value {
    state["connections"].as_array().unwrap().iter().find(|c| c["id"] == id).unwrap()
}

#[test]
fn keychain_other_build_shows_a_signed_out_settings_row() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let file = routes::file_from_json(&json!({
        "kind": "chatgpt-plan", "provider": "openai", "families": ["codex"],
    }))
    .unwrap();
    let id = "chatgpt";
    routes::add(dir, id, &file, false).unwrap();
    let store = crate::subscription_store::Store::new(&d.home, "chatgpt");
    let record = chatgpt::store::Record {
        client_id: chatgpt::CODEX_CLIENT_ID.into(),
        sub: "fixture-user".into(),
        refresh_token: "fixture-refresh".into(),
        ..Default::default()
    };
    store.write(id, &record).unwrap();
    store.refuse_test_item(id, crate::subscription_store::Error::KeychainOtherBuild);

    let settings = state(dir, &d.home, &ProfileSources::none());
    assert_eq!(find(&settings, id)["signed_in"], false);
    assert_eq!(find(&settings, id)["sign_in_reason"], "keychain_other_build");
    assert!(settings.get("disconnected_credentials").is_none());
    assert!(store.metadata(id).is_some_and(|record| record["signed_in"] == true));

    let instance = find(&settings, id)["credential_instance"].as_str().unwrap();
    routes::remove(dir, &d.home, id).unwrap();
    let disconnected = state(dir, &d.home, &ProfileSources::none());
    assert_eq!(disconnected["disconnected_credentials"][id], json!([instance]));
}

#[test]
fn restored_chatgpt_index_for_another_workspace_requires_sign_in_in_settings() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let file = routes::file_from_json(&json!({
        "kind": "chatgpt-plan", "provider": "openai", "families": ["codex"],
    }))
    .unwrap();
    let id = "chatgpt";
    routes::add(dir, id, &file, false).unwrap();
    let record = chatgpt::store::Record {
        client_id: chatgpt::CODEX_CLIENT_ID.into(),
        sub: "fixture-user".into(),
        workspace: Some("active-workspace".into()),
        refresh_token: "fixture-refresh".into(),
        ..Default::default()
    };
    chatgpt::store::write(&d.home, id, &record).unwrap();
    let path = chatgpt::store::dir(&d.home).join("chatgpt.json");
    let mut index: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    index["workspace"] = json!("restored-workspace");
    chatgpt::store::write_atomic(&path, &serde_json::to_vec(&index).unwrap()).unwrap();

    let settings = state(dir, &d.home, &ProfileSources::none());
    assert_eq!(find(&settings, id)["signed_in"], false);
    assert_eq!(find(&settings, id)["sign_in_reason"], "reauth_required");
    assert!(settings.get("disconnected_credentials").is_none());
}

#[test]
fn saved_claude_token_route_can_serve_cloud_and_can_be_removed() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let id = "claude-token";
    let path = d.routes.join("claude-token.toml");
    std::fs::write(
        &path,
        concat!(
            "kind = \"claude-token\"\n",
            "families = [\"claude\"]\n",
            "provider = \"anthropic\"\n",
            "secret = \"keychain:cmux-model-key/claude-token-1234abcd\"\n",
            "notes = \"claude setup-token: served to Cloud machines' Claude agents\"\n",
        ),
    )
    .unwrap();

    let settings = state(dir, &d.home, &ProfileSources::none());
    assert_eq!(find(&settings, id)["can_serve_cloud"], true);
    let route = routes::find(dir, id).unwrap();
    assert!(matches!(
        routes::env_for(&route, "claude", &d.home),
        Err(routes::RouteError::Unavailable(_))
    ));
    let (family, kind, var, reference, _) =
        credential_plan(dir, &d.home, id, &ProfileSources::none()).unwrap();
    assert_eq!((family.as_str(), kind, var), ("claude", "claude-token", "ANTHROPIC_AUTH_TOKEN"));
    assert_eq!(reference.as_deref(), route.file.secret.as_deref());
    accounts::set_for_test(dir, &d.home, id, Some(false)).unwrap();
    assert!(routes::find(dir, id).unwrap().file.disabled);
    let error = credential_plan(dir, &d.home, id, &ProfileSources::none()).unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "connections.disabled");
    routes::remove(dir, &d.home, id).unwrap();
    assert!(!path.exists());
}

#[test]
fn chatgpt_and_claude_login_turn_off_and_a_disabled_plan_gets_no_credential() {
    let d = dirs();
    let plan = RouteFile {
        credential_instance: None,
        name: Some("ChatGPT plan".into()),
        kind: RouteKind::ChatgptPlan,
        families: vec!["codex".into()],
        anthropic_base_url: None,
        openai_base_url: Some(chatgpt::CODEX_BACKEND.into()),
        auth: None,
        secret: None,
        claude_token_expires_at: None,
        cloud_enabled: None,
        headers: Default::default(),
        health_url: None,
        fallback: vec![],
        auto_fallback: false,
        notes: None,
        account_home: None,
        shadow_of: None,
        disabled: false,
        provider: Some("openai".into()),
    };
    routes::add(Some(&d.routes), "chatgpt", &plan, false).unwrap();
    for id in ["chatgpt", "claude-login"] {
        let answer = accounts::set_for_test(Some(&d.routes), &d.home, id, Some(false));
        assert_eq!(answer.unwrap()["enabled"], false, "{id}");
        let s = state(Some(&d.routes), &d.home, &ProfileSources::none());
        let c = find(&s, id);
        assert_eq!(c["enabled"], false, "{id}");
        assert_eq!(c["default_for"], json!([]), "{id} is nobody's default when off");
        assert_eq!(
            state_ids(&s).last().map(String::as_str),
            Some(id),
            "{id}: a turned-off connection sorts last"
        );
        if id == "chatgpt" {
            let e =
                credential_plan(Some(&d.routes), &d.home, id, &ProfileSources::none()).unwrap_err();
            assert_eq!(e.data.unwrap()["reason"], "connections.disabled", "{id}");
        }
        accounts::set_for_test(Some(&d.routes), &d.home, id, Some(true)).unwrap();
        assert_eq!(
            find(&state(Some(&d.routes), &d.home, &ProfileSources::none()), id)["enabled"],
            true,
            "{id}"
        );
    }
    assert!(routes::bindings(&d.home).disabled_connections.is_empty());
    // The switch of claude-login lives in the bindings, not a route file.
    assert!(routes::find(Some(&d.routes), "claude-login").is_err());
}

#[test]
fn replacing_a_key_keeps_the_connection_and_its_route_settings() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let sources = ProfileSources::none();
    let old = "keychain:cmux-model-key/openai-previous";
    let new = "keychain:cmux-model-key/openai-replacement";
    let (id, _) = add_key(dir, &d.home, "openai", old, Some("Research"), &sources, None).unwrap();
    let mut expected = routes::find(dir, &id).unwrap().file;
    expected.disabled = true;
    routes::add(dir, &id, &expected, true).unwrap();
    set_order(dir, &d.home, std::slice::from_ref(&id), &sources).unwrap();
    let instance = expected.credential_instance.as_deref().unwrap().to_owned();

    assert!(replace_key(dir, &d.home, &id, "anthropic", new, &instance, &sources).is_err());
    assert_eq!(routes::find(dir, &id).unwrap().file.secret.as_deref(), Some(old));

    let state = replace_key(dir, &d.home, &id, "openai", new, &instance, &sources).unwrap();
    assert_eq!(state_ids(&state)[0], id);
    assert_eq!(state["replaced_secret"], old);
    expected.secret = Some(new.to_owned());
    let saved = routes::find(dir, &id).unwrap().file;
    assert_ne!(saved.credential_instance, expected.credential_instance);
    expected.credential_instance = saved.credential_instance.clone();
    assert_eq!(saved, expected);
    assert_eq!(routes::load(dir).0.len(), 1);
    routes::remove(dir, &d.home, &id).unwrap();
    assert!(replace_key(dir, &d.home, &id, "openai", old, &instance, &sources).is_err());
    assert!(routes::find(dir, &id).is_err());
}

#[tokio::test]
async fn replacing_a_gemini_key_requires_existing_local_chats_to_pick_it_again() {
    let d = dirs();
    let mut config: config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    config.path = Some(d.home.join("config.json"));
    config.profile_sources = ProfileSources::none();
    config.profile_sources.cmux_json = Some(d.routes.with_file_name("cmux.json"));
    let profile: HarnessProfile =
        serde_json::from_value(json!({"argv": ["gemini"], "family": "gemini"})).unwrap();
    let store = crate::store::open(&config.store, &d.home).unwrap();
    let hub = Hub::new(config, store);
    let dir = Some(d.routes.as_path());
    let old = "env:FIXTURE_OLD_GEMINI_KEY";
    let new = "env:FIXTURE_NEW_GEMINI_KEY";
    let (id, state) =
        add_key(dir, &d.home, "google", old, None, &ProfileSources::none(), None).unwrap();
    let instance = find(&state, &id)["credential_instance"].as_str().unwrap();
    routes::set_binding(&d.home, "chat:existing", Some(&id)).unwrap();
    routes::set_binding(&d.home, "family:gemini", Some(&id)).unwrap();

    let launch = async |chat: &str| {
        let mut env = Default::default();
        hub.apply_route_for("gemini", Some(chat), None, false, &profile, &mut env).await?;
        Ok::<_, RpcError>(env)
    };
    assert_eq!(launch("existing").await.unwrap()["GEMINI_API_KEY"], format!("${{{old}}}"));
    handle(
        &hub,
        Origin::Local,
        method::MUX_CONNECTIONS_KEY_ADD,
        &json!({"provider": "google", "secret": new, "replace": id, "replaceInstance": instance}),
    )
    .await
    .unwrap();

    let error = launch("existing").await.unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "route.not_found");
    // An older daemon can still read and save the same chat binding, but its
    // route lookup cannot resolve it to the new key.
    let bindings = routes::set_binding(&d.home, "chat:other", Some(&id)).unwrap();
    assert!(routes::find(dir, &bindings.chats["existing"]).is_err());
    assert!(routes::find_chat_route(dir, &d.home, "existing", &id).is_err());
    assert_eq!(launch("new").await.unwrap()["GEMINI_API_KEY"], format!("${{{new}}}"));
    routes::set_binding(&d.home, "chat:existing", Some(&id)).unwrap();
    assert_eq!(launch("existing").await.unwrap()["GEMINI_API_KEY"], format!("${{{new}}}"));
}

#[test]
fn existing_google_and_xai_keys_need_explicit_cloud_consent() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let sources = ProfileSources::none();
    for (provider, family, url) in [
        ("google", "gemini", "https://generativelanguage.googleapis.com/v1beta/openai"),
        ("xai", "grok", "https://api.x.ai/v1"),
    ] {
        let id = format!("{provider}-key");
        let legacy = routes::file_from_json(&json!({
            "kind": "direct-api-key", "provider": provider, "families": [family],
            "openaiBaseUrl": url, "secret": "keychain:work",
        }))
        .unwrap();
        std::fs::write(
            d.routes.join(format!("{id}.toml")),
            toml::to_string_pretty(&legacy).unwrap(),
        )
        .unwrap();
        let listed = state(dir, &d.home, &sources);
        assert_eq!(find(&listed, &id)["can_serve_cloud"], true);
        assert_eq!(find(&listed, &id)["serves_cloud"], false);
        assert_eq!(
            credential_plan(dir, &d.home, &id, &sources).unwrap_err().data.unwrap()["reason"],
            "connections.not_cloud"
        );
        routes::edit(dir, &id, |file| {
            file.cloud_enabled = Some(true);
            Ok(())
        })
        .unwrap();
        assert_eq!(find(&state(dir, &d.home, &sources), &id)["serves_cloud"], true);
        assert_eq!(credential_plan(dir, &d.home, &id, &sources).unwrap().0, family);
    }
}

#[test]
fn failed_disconnect_keeps_the_key_and_retry_publishes_its_withdrawal() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let sources = ProfileSources::none();
    let (id, listed) =
        add_key(dir, &d.home, "anthropic", "keychain:work", None, &sources, Some(true)).unwrap();
    let instance = find(&listed, &id)["credential_instance"].as_str().unwrap();
    let bindings = routes::update_bindings(&d.home, |b| {
        b.chats.insert("chat".into(), id.clone());
        b.workspaces.insert("workspace".into(), id.clone());
        b.families.insert("claude".into(), id.clone());
        b.global = Some(id.clone());
        b.connection_order = vec![id.clone(), "other".into()];
    })
    .unwrap();
    let write = d.home.join("routes/bindings.json.tmp");
    std::fs::create_dir_all(&write).unwrap();

    assert!(routes::remove(dir, &d.home, &id).is_err());
    assert_eq!(routes::bindings(&d.home), bindings);
    let listed = state(dir, &d.home, &sources);
    assert_eq!(find(&listed, &id)["credential_instance"], instance);
    assert!(listed.get("disconnected_credentials").is_none());

    std::fs::remove_dir(&write).unwrap();
    // A crash after the marker write but before the route move also leaves a retryable row.
    routes::update_bindings(&d.home, |b| {
        b.disconnected_credentials.entry(id.clone()).or_default().insert(instance.to_owned());
    })
    .unwrap();
    assert!(state(dir, &d.home, &sources).get("disconnected_credentials").is_none());

    routes::remove(dir, &d.home, &id).unwrap();
    let listed = state(dir, &d.home, &sources);
    assert!(!state_ids(&listed).contains(&id));
    assert_eq!(listed["disconnected_credentials"][&id], json!([instance]));
    let bindings = routes::bindings(&d.home);
    assert!(bindings.chats.is_empty());
    assert!(bindings.workspaces.is_empty());
    assert!(bindings.families.is_empty());
    assert!(bindings.global.is_none());
    assert_eq!(bindings.connection_order, ["other"]);
    assert!(credential_plan(dir, &d.home, &id, &sources).is_err());
}

#[test]
fn legacy_bindings_rewrite_keeps_disconnect_for_an_offline_guest() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let sources = ProfileSources::none();
    let (id, listed) =
        add_key(dir, &d.home, "anthropic", "keychain:work", None, &sources, Some(true)).unwrap();
    let instance = find(&listed, &id)["credential_instance"].as_str().unwrap();
    let backup = routes::remove(dir, &d.home, &id).unwrap();

    // The older Bindings struct only writes the fields it knows.
    let bindings = d.home.join("routes/bindings.json");
    let mut older: Value = serde_json::from_slice(&std::fs::read(&bindings).unwrap()).unwrap();
    older.as_object_mut().unwrap().remove("disconnected_credentials");
    older["spread"] = json!(false);
    std::fs::write(bindings, serde_json::to_vec(&older).unwrap()).unwrap();

    let replacement = routes::restore(dir, &d.home, &backup).unwrap();
    assert_ne!(replacement.file.credential_instance.as_deref(), Some(instance));
    let listed = state(dir, &d.home, &sources);
    assert_eq!(listed["spread"], false);
    assert_eq!(listed["disconnected_credentials"][&id], json!([instance]));
}

#[test]
fn new_keys_without_cloud_consent_stay_local_after_replacement() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let sources = ProfileSources::none();
    for provider in ["anthropic", "openai", "google", "vertex-express", "xai"] {
        let (id, listed) =
            add_key(dir, &d.home, provider, "keychain:fixture", None, &sources, None).unwrap();
        let key = find(&listed, &id);
        assert_eq!(key["can_serve_cloud"], true);
        assert_eq!(key["serves_cloud"], false);
        assert_eq!(key["enabled"], true);
        assert_eq!(key["signed_in"], true);
        let route = routes::find(dir, &id).unwrap();
        let instance = route.file.credential_instance.as_deref().unwrap();
        replace_key(dir, &d.home, &id, provider, "keychain:replacement", instance, &sources)
            .unwrap();
        assert_eq!(find(&state(dir, &d.home, &sources), &id)["serves_cloud"], false);
        assert_eq!(
            credential_plan(dir, &d.home, &id, &sources).unwrap_err().data.unwrap()["reason"],
            "connections.not_cloud"
        );
    }
}

#[test]
fn older_build_can_add_a_second_key_without_resolving_the_local_only_key() {
    let sources = ProfileSources::none();
    for provider in ["anthropic", "openai"] {
        for initially_enabled in [false, true] {
            let d = dirs();
            let dir = Some(d.routes.as_path());
            let reference = "keychain:fixture";
            let (id, _) = add_key(
                dir,
                &d.home,
                provider,
                reference,
                None,
                &sources,
                initially_enabled.then_some(true),
            )
            .unwrap();
            let route = routes::find(dir, &id).unwrap();
            let older_file = || {
                toml::from_str::<RouteFile>(&std::fs::read_to_string(&route.path).unwrap()).unwrap()
            };
            if initially_enabled {
                routes::validate(&older_file()).unwrap();
                routes::edit(dir, &id, |file| {
                    file.cloud_enabled = Some(false);
                    Ok(())
                })
                .unwrap();
            }
            // The older allocator skips files it can load without decoding notes.
            let older_loads = |id: &str| {
                std::fs::read_to_string(d.routes.join(format!("{id}.toml")))
                    .ok()
                    .and_then(|text| toml::from_str::<RouteFile>(&text).ok())
                    .is_some_and(|file| routes::validate(&file).is_ok())
            };
            let next = std::iter::once(format!("{provider}-key"))
                .chain((2..1000).map(|n| format!("{provider}-key-{n}")))
                .find(|candidate| !older_loads(candidate))
                .unwrap();
            let raw = older_file();
            let mut second = raw.clone();
            second.secret = Some("keychain:second-key".into());
            second.notes = None;
            routes::add(dir, &next, &second, false).unwrap();
            assert_eq!(next, format!("{provider}-key-2"));
            assert!(resolve(&id, raw.secret.as_deref().unwrap()).is_err());

            let saved = routes::find(dir, &id).unwrap();
            assert!(!saved.file.disabled);
            assert_eq!(saved.file.secret.as_deref(), Some(reference));
            assert_eq!(
                credential_plan(dir, &d.home, &id, &sources).unwrap_err().data.unwrap()["reason"],
                "connections.not_cloud"
            );
        }
    }
}

#[test]
fn saved_endpoint_profiles_are_editable_and_local_only() {
    let d = dirs();
    let folder = d.home.join("harnesses");
    std::fs::create_dir_all(&folder).unwrap();
    let sources = ProfileSources { user_dir: Some(folder.clone()), ..Default::default() };
    for (id, base_url) in
        [("hosted", "https://models.example/v1"), ("local", "http://127.0.0.1:11434/v1")]
    {
        let account = format!("cmux-harness/{id}/CMUX_BYO_API_KEY");
        let profile = byo_endpoint::profile_text(&byo_endpoint::Endpoint {
            cloud_enabled: Some(true),
            preset: None,
            id,
            name: id,
            kind: Kind::OpenAi,
            base_url,
            models: &["some-model".into()],
            keychain_item: Some(&account),
        });
        std::fs::write(folder.join(format!("{id}.toml")), profile).unwrap();
        let row = list(Some(&d.routes), &d.home, &Bindings::default(), &sources)
            .into_iter()
            .find(|connection| connection.id == id)
            .unwrap();
        assert!(!row.can_serve_cloud && !row.serves_cloud && row.signed_in);
        let fields = row.endpoint.unwrap();
        assert_eq!(fields.base_url, base_url);
        assert_eq!(fields.models, ["some-model"]);
        assert_eq!(fields.kind, "openai-endpoint");
        assert_eq!(
            credential_plan(Some(&d.routes), &d.home, id, &sources).unwrap_err().data.unwrap()["reason"],
            "connections.not_cloud"
        );
    }
}

#[test]
fn a_saved_endpoint_stays_editable_when_a_route_has_the_same_id() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let empty = ProfileSources::none();
    let id = "openai-key";
    let folder = d.home.join("harnesses");
    std::fs::create_dir_all(&folder).unwrap();
    let sources = ProfileSources { user_dir: Some(folder.clone()), ..Default::default() };
    let account = format!("cmux-harness/{id}/CMUX_BYO_API_KEY");
    std::fs::write(
        folder.join(format!("{id}.toml")),
        byo_endpoint::profile_text(&byo_endpoint::Endpoint {
            cloud_enabled: None,
            preset: None,
            id,
            name: "Custom OpenAI Key",
            kind: Kind::OpenAi,
            base_url: "https://models.example/v1",
            models: &["some-model".into()],
            keychain_item: Some(&account),
        }),
    )
    .unwrap();
    let (key, settings) =
        add_key(dir, &d.home, "openai", "keychain:fixture", None, &sources, None).unwrap();
    assert_eq!(key, "openai-key-2");
    assert_eq!(find(&settings, id)["kind"], "endpoint");

    // A CLI route or pre-existing configuration can still use the profile's ID.
    add_key(dir, &d.home, "openai", "keychain:legacy", None, &empty, None).unwrap();
    let settings = state(dir, &d.home, &sources);
    assert_eq!(find(&settings, id)["kind"], "api-key");
    let endpoint = find(&settings, "endpoint:openai-key");
    assert_eq!(endpoint["provider"], id);
    assert_eq!(endpoint["label"], "Custom OpenAI Key");
    assert_eq!(endpoint["can_serve_cloud"], false);
    assert!(endpoint["endpoint"]["revision"].is_string());
}

#[test]
fn native_key_routes_set_the_variable_the_harness_uses() {
    let d = dirs();
    for (provider, family, variable) in [
        ("google", "gemini", "GEMINI_API_KEY"),
        ("vertex-express", "gemini", "GOOGLE_API_KEY"),
        ("xai", "grok", "XAI_API_KEY"),
    ] {
        let (id, _) = add_key(
            Some(&d.routes),
            &d.home,
            provider,
            "keychain:fixture",
            None,
            &ProfileSources::none(),
            Some(true),
        )
        .unwrap();
        let route = routes::find(Some(&d.routes), &id).unwrap();
        let env = routes::env_for(&route, family, &d.home).unwrap();
        assert_eq!(env.set[variable], "${keychain:fixture}");
        assert!(!env.set.contains_key("OPENAI_API_KEY"));
        let (launch_family, _, launch_variable, _, _) =
            credential_plan(Some(&d.routes), &d.home, &id, &ProfileSources::none()).unwrap();
        assert_eq!((launch_family.as_str(), launch_variable), (family, variable));
    }
}

#[test]
fn which_connections_serve_cloud() {
    for (kind, provider, cloud) in [
        ("chatgpt-plan", "openai", true),
        ("claude-token", "anthropic", true),
        ("api-key", "anthropic", true),
        ("api-key", "openai", true),
        ("api-key", "openrouter", false),
        ("api-key", "google", true),
        ("api-key", "xai", true),
        ("codex-login", "openai", false),
        ("claude-login", "anthropic", false),
        ("subscription", "openai", false),
    ] {
        assert_eq!(serves_cloud(kind, provider), cloud, "{kind} {provider}");
    }
    let d = dirs();
    let s = state(Some(&d.routes), &d.home, &ProfileSources::none());
    assert_eq!(find(&s, "codex-login")["serves_cloud"], false);
    assert_eq!(find(&s, "claude-login")["serves_cloud"], false);
}

#[test]
fn saved_local_plans_never_offer_a_cloud_credential() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    for (kind, family) in
        [("grok-plan", "grok"), ("copilot-plan", "github-copilot"), ("kimi-plan", "opencode")]
    {
        let file = serde_json::from_value(json!({
            "kind": kind, "families": [family], "cloud_enabled": true,
        }))
        .unwrap();
        routes::add(dir, kind, &file, false).unwrap();
        let settings = state(dir, &d.home, &ProfileSources::none());
        let row = find(&settings, kind);
        assert_eq!(row["kind"], kind);
        assert_eq!(row["serves_cloud"], false);
        assert_eq!(row["can_serve_cloud"], false);
        let error = credential_plan(dir, &d.home, kind, &ProfileSources::none()).unwrap_err();
        assert_eq!(error.data.unwrap()["reason"], "connections.not_cloud");
    }
}

#[test]
fn a_claude_token_is_added_as_a_reference_and_delivered_as_anthropic_auth() {
    let d = dirs();
    let dir = Some(d.routes.as_path());
    let token = "sk-ant-oat01-fixture";
    let inline = routes::add_claude_token(dir, token, None).unwrap_err();
    assert_eq!(route_error(&inline).data.unwrap()["reason"], "route.secret_inline");
    let reference = secret_file(&d, "claude-token", token);
    let route = routes::add_claude_token(dir, &reference, None).unwrap();
    assert_eq!(route.id, "claude-token");
    let saved = std::fs::read_to_string(&route.path).unwrap();
    assert!(saved.contains(&reference));
    assert!(!saved.contains(token));
    let settings = state(dir, &d.home, &ProfileSources::none());
    let connection = find(&settings, &route.id);
    assert_eq!(connection["kind"], "claude-token");
    assert_eq!(connection["provider"], "anthropic");
    assert_eq!(connection["families"], json!(["claude"]));
    assert_eq!(connection["label"], "Claude Code token");
    assert_eq!(connection["signed_in"], true);
    assert_eq!(connection["serves_cloud"], true);
    assert!(!settings.to_string().contains(token));

    let (family, kind, var, secret, _) =
        credential_plan(dir, &d.home, &route.id, &ProfileSources::none()).unwrap();
    assert_eq!((family.as_str(), kind, var), ("claude", "claude-token", "ANTHROPIC_AUTH_TOKEN"));
    assert_eq!(secret.as_deref(), Some(reference.as_str()));
    assert_eq!(resolve(&route.id, &secret.unwrap()).unwrap(), token);

    let second =
        routes::add_claude_token(dir, "env:CMUX_TEST_CLAUDE_TOKEN", Some(" Work ")).unwrap();
    assert_eq!(second.id, "claude-token-2");
    let settings = state(dir, &d.home, &ProfileSources::none());
    assert_eq!(find(&settings, &second.id)["label"], "Work");
}

#[test]
fn an_openrouter_key_is_local_even_with_cloud_enabled() {
    let d = dirs();
    let key = secret_file(&d, "openrouter", "fixture-openrouter-key");
    let (id, _) = add_key(
        Some(&d.routes),
        &d.home,
        "openrouter",
        &key,
        None,
        &ProfileSources::none(),
        Some(true),
    )
    .unwrap();
    let route = routes::find(Some(&d.routes), &id).unwrap();
    let local = routes::env_for(&route, "openrouter", &d.home).unwrap();
    assert!(local.set["OPENROUTER_API_KEY"].contains(&key));
    assert_eq!(local.set[crate::agent_credentials::LOCAL_REDACTION], "OPENROUTER_API_KEY");
    assert_eq!(
        credential_plan(Some(&d.routes), &d.home, &id, &ProfileSources::none())
            .unwrap_err()
            .data
            .unwrap()["reason"],
        "connections.not_cloud"
    );
}

#[test]
fn a_claude_token_with_whitespace_inside_is_delivered_without_it() {
    let d = dirs();
    let reference = secret_file(&d, "claude-token", " sk-ant-oat01-ab  cd\t\u{a0}ef \r");
    let route = routes::add_claude_token(Some(&d.routes), &reference, None).unwrap();
    let (_, kind, _, secret, _) =
        credential_plan(Some(&d.routes), &d.home, &route.id, &ProfileSources::none()).unwrap();
    let value = delivered(kind, resolve(&route.id, &secret.unwrap()).unwrap());
    assert_eq!(value, "sk-ant-oat01-abcdef");
    assert_eq!(delivered(kind, " sk-ant-oat01-ab\n  cd\t\u{a0}ef \r".into()), value);
    let env = json!({"env": {"CLAUDE_CODE_OAUTH_TOKEN": value}});
    assert!(crate::agent_credentials::AgentCredential::parse(&env).is_ok());
    assert_eq!(delivered("api-key", "a b".into()), "a b", "only a Claude token is reshaped");
}

#[test]
fn keys_are_delivered_in_their_providers_variable_and_logins_not_at_all() {
    let d = dirs();
    let anthropic = secret_file(&d, "a", "sk-ant-api-1");
    let openai = secret_file(&d, "o", "sk-proj-1");
    add_key(
        Some(&d.routes),
        &d.home,
        "anthropic",
        &anthropic,
        None,
        &ProfileSources::none(),
        Some(true),
    )
    .unwrap();
    add_key(Some(&d.routes), &d.home, "openai", &openai, None, &ProfileSources::none(), Some(true))
        .unwrap();
    let (family, kind, var, _, _) =
        credential_plan(Some(&d.routes), &d.home, "anthropic-key", &ProfileSources::none())
            .unwrap();
    assert_eq!((family.as_str(), kind, var), ("claude", "api-key", "ANTHROPIC_API_KEY"));
    let (family, _, var, secret, _) =
        credential_plan(Some(&d.routes), &d.home, "openai-key", &ProfileSources::none()).unwrap();
    assert_eq!((family.as_str(), var), ("codex", "OPENAI_API_KEY"));
    assert_eq!(resolve("openai-key", &secret.unwrap()).unwrap(), "sk-proj-1");
    for id in ["codex-login", "claude-login"] {
        let e = credential_plan(Some(&d.routes), &d.home, id, &ProfileSources::none()).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "connections.not_cloud", "{id}");
    }
    let e = credential_plan(Some(&d.routes), &d.home, "nope", &ProfileSources::none()).unwrap_err();
    assert_eq!(e.code, RpcError::not_found("").code);
}

#[test]
fn a_chatgpt_plan_route_is_listed_from_its_record() {
    let d = dirs();
    let record = chatgpt::store::Record {
        client_id: chatgpt::CODEX_CLIENT_ID.into(),
        sub: "user-1".into(),
        email: Some("alex@example.com".into()),
        plan: Some("plus".into()),
        refresh_token: "r".into(),
        ..Default::default()
    };
    chatgpt::store::write(&d.home, "chatgpt", &record).unwrap();
    let file = RouteFile {
        credential_instance: None,
        name: Some("ChatGPT plan".into()),
        kind: RouteKind::ChatgptPlan,
        families: vec!["codex".into()],
        anthropic_base_url: None,
        openai_base_url: Some(chatgpt::CODEX_BACKEND.into()),
        auth: None,
        secret: None,
        claude_token_expires_at: None,
        cloud_enabled: None,
        headers: Default::default(),
        health_url: None,
        fallback: vec![],
        auto_fallback: false,
        notes: None,
        account_home: None,
        shadow_of: None,
        disabled: false,
        provider: Some("openai".into()),
    };
    routes::add(Some(&d.routes), "chatgpt", &file, false).unwrap();
    let list = list(Some(&d.routes), &d.home, &routes::bindings(&d.home), &ProfileSources::none());
    let plan = list.iter().find(|c| c.id == "chatgpt").unwrap();
    assert_eq!(plan.kind, "chatgpt-plan");
    assert!(plan.signed_in);
    assert_eq!(plan.email.as_deref(), Some("alex@example.com"));
    assert_eq!(plan.plan.as_deref(), Some("plus"));
    assert!(plan.serves_cloud);
    let (family, kind, var, secret, _) =
        credential_plan(Some(&d.routes), &d.home, "chatgpt", &ProfileSources::none()).unwrap();
    assert_eq!(
        (family.as_str(), kind, var),
        ("codex", "chatgpt-plan", "CMUX_CHATGPT_ACCESS_TOKEN")
    );
    assert!(secret.is_none(), "the daemon's own token, not a reference");
    // A sign-in from the retired token-sharing client (`oaiapp_...`) reads signed out: its
    // token is refused by OpenAI, so the person signs in again (cmux#45774).
    let old = chatgpt::store::Record { client_id: "oaiapp_x".into(), ..record.clone() };
    chatgpt::store::write(&d.home, "chatgpt", &old).unwrap();
    let list =
        super::list(Some(&d.routes), &d.home, &routes::bindings(&d.home), &ProfileSources::none());
    assert!(!list.iter().find(|c| c.id == "chatgpt").unwrap().signed_in);
    let route = routes::find(Some(&d.routes), "chatgpt").unwrap();
    assert!(route.serves("codex"));
    assert!(!route.serves("opencode"));
    let launch = routes::env_for(&route, "codex", &d.home).unwrap();
    assert!(launch.set.is_empty(), "the hub resolves a fresh ChatGPT token at launch");
    assert!(launch.unset.iter().any(|key| key == "OPENAI_API_KEY"));
}

fn auth_file(d: &Dirs, text: &str) -> PathBuf {
    std::fs::create_dir_all(&d.home).unwrap();
    let path = d.home.join("auth.json");
    std::fs::write(&path, text).unwrap();
    path
}

fn import(d: &Dirs, origin: Origin, enabled: bool, text: &str) -> Result<String, RpcError> {
    let path = auth_file(d, text);
    import_chatgpt(origin, enabled, Some(d.routes.clone()), d.home.clone(), path.to_str().unwrap())
}

fn codex_auth(refresh: Option<&str>) -> String {
    chatgpt::import_test_auth(chatgpt::CODEX_CLIENT_ID, refresh, true)
}

fn reason(e: &RpcError) -> String {
    e.data.as_ref().and_then(|d| d["reason"].as_str()).unwrap_or_default().to_owned()
}

#[test]
fn chatgpt_import_is_refused_unless_the_switch_is_set() {
    let d = dirs();
    let error = import(&d, Origin::Local, false, &codex_auth(Some("rt"))).unwrap_err();
    assert_eq!(reason(&error), "chatgpt.import_disabled");
    assert!(chatgpt::store::all(&d.home).is_empty(), "nothing stored");
    assert!(routes::find(Some(&d.routes), "chatgpt").is_err(), "no route written");
}

#[test]
fn chatgpt_import_is_refused_off_the_local_socket_even_with_the_switch() {
    let d = dirs();
    for origin in [Origin::Web, Origin::Peer, Origin::LocalApp] {
        let error = import(&d, origin, true, &codex_auth(Some("rt"))).unwrap_err();
        assert_eq!(reason(&error), "chatgpt.import_local_only", "{origin:?}");
    }
    assert!(chatgpt::store::all(&d.home).is_empty(), "nothing stored");
}

#[test]
fn chatgpt_import_refuses_another_client_and_a_missing_refresh_token() {
    let d = dirs();
    let other = chatgpt::import_test_auth("app_someone_else", Some("rt"), true);
    let error = import(&d, Origin::Local, true, &other).unwrap_err();
    assert_eq!(reason(&error), "chatgpt.wrong_client");
    let error = import(&d, Origin::Local, true, &codex_auth(None)).unwrap_err();
    assert_eq!(reason(&error), "chatgpt.no_refresh_token");
    let no_account = chatgpt::import_test_auth(chatgpt::CODEX_CLIENT_ID, Some("rt"), false);
    let error = import(&d, Origin::Local, true, &no_account).unwrap_err();
    assert_eq!(reason(&error), "chatgpt.no_chatgpt_account");
    let error = import(&d, Origin::Local, true, "not json").unwrap_err();
    assert_eq!(reason(&error), "chatgpt.import_invalid");
    assert!(chatgpt::store::all(&d.home).is_empty(), "nothing stored");
}

#[test]
fn an_imported_codex_login_lists_as_a_cloud_serving_chatgpt_plan() {
    let d = dirs();
    let id = import(&d, Origin::Local, true, &codex_auth(Some("rt-1"))).unwrap();
    assert_eq!(id, "chatgpt");
    let record = chatgpt::store::read(&d.home, &id).unwrap().unwrap();
    assert!(record.signed_in());
    assert_eq!(record.client_id, chatgpt::CODEX_CLIENT_ID);
    assert_eq!(record.refresh_token, "rt-1");
    assert_eq!(record.sub, "user-1");
    assert_eq!(record.plan.as_deref(), Some("plus"));
    let route = routes::find(Some(&d.routes), &id).unwrap();
    assert_eq!(route.file.kind, RouteKind::ChatgptPlan);
    assert_eq!(route.file.families, vec!["codex".to_owned()]);
    let response = connection_state(Some(&d.routes), &d.home, &id, &ProfileSources::default());
    let plan = &response["connection"];
    assert_eq!(plan["id"], "chatgpt");
    assert_eq!(plan["kind"], "chatgpt-plan");
    assert_eq!(plan["serves_cloud"], true);
    assert_eq!(plan["signed_in"], true);
    assert_eq!(plan["email"], "ci@example.com");
    // Importing the same account again replaces its record: no second connection.
    let again = import(&d, Origin::Local, true, &codex_auth(Some("rt-2"))).unwrap();
    assert_eq!(again, "chatgpt");
    assert_eq!(chatgpt::store::read(&d.home, "chatgpt").unwrap().unwrap().refresh_token, "rt-2");
}

/// One-click Claude token end to end at the service: the fake `claude setup-token` prints a
/// link and a token; the connection holds the stored item's reference, and neither `begin`'s
/// nor `wait`'s answer nor the route file carries the token.
#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn claude_token_begin_and_wait_add_a_connection_by_reference_only() {
    use crate::claude_token::{self, store};
    const TOKEN: &str = "sk-ant-oat01-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AbCdEfGhIjKlMnOp";
    let d = dirs();
    let fake = d._root.path().join("claude");
    std::fs::write(
        &fake,
        format!(
            "#!/bin/sh\nprintf 'https://claude.ai/oauth/authorize?abc\\n'\nsleep 0.2\nprintf '{TOKEN}\\n'\nsleep 30\n"
        ),
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let secrets = d._root.path().join("secrets");
    std::fs::create_dir_all(&secrets).unwrap();
    let svc = Arc::new(claude_token::Service::new(
        Arc::new(store::Files(secrets.clone())),
        Some(fake),
        Duration::from_secs(10),
    ));
    let routes_dir = d.routes.clone();
    let begun = svc
        .begin(
            move |reference| add_token_reference(Some(&routes_dir), reference, Some("Work Claude")),
            |_| {},
        )
        .await
        .unwrap();
    assert_eq!(begun.url.as_deref(), Some("https://claude.ai/oauth/authorize?abc"));
    let status = svc.wait(&begun.attempt, Duration::from_secs(10)).await.unwrap();
    assert_eq!(status, chatgpt::Status::Done("claude-token".into()));
    let sources = ProfileSources::none();
    let reply = token_wait_reply(Some(&d.routes), &d.home, &status, &sources);
    assert_eq!(reply["status"], "done");
    assert_eq!(reply["connection"]["kind"], "claude-token");
    assert_eq!(reply["connection"]["label"], "Work Claude");
    let route = routes::find(Some(&d.routes), "claude-token").unwrap();
    let secret = route.file.secret.unwrap();
    assert!(secret.starts_with(&format!("file:{}", secrets.display())), "{secret}");
    assert_eq!(routes::resolve_reference(&secret).unwrap(), TOKEN);
    let route_text = std::fs::read_to_string(
        std::fs::read_dir(&d.routes)
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| p.to_string_lossy().contains("claude-token"))
            .unwrap(),
    )
    .unwrap_or_default();
    for text in [reply.to_string(), format!("{begun:?}"), route_text] {
        assert!(!text.contains(TOKEN), "{text}");
    }
    let failed =
        token_wait_reply(None, &d.home, &chatgpt::Status::Failed("no_url".into()), &sources);
    assert_eq!(failed, json!({"status": "failed", "connection": null, "error": "no_url"}));
}
