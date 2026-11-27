use super::*;

fn conn(id: &str, kind: &'static str, signed_in: bool, default_for: &[&str]) -> Connection {
    Connection {
        id: id.into(),
        kind,
        provider: "openai".into(),
        families: vec!["codex".into()],
        label: id.into(),
        email: None,
        plan: None,
        signed_in,
        enabled: true,
        default_for: default_for.iter().map(|f| (*f).to_owned()).collect(),
        serves_cloud: true,
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
fn order_set_refuses_an_unknown_id_and_stores_a_known_order() {
    let d = dirs();
    let (_, _) =
        add_key(Some(&d.routes), &d.home, "anthropic", "keychain:cmux-test-key", None).unwrap();
    let error = set_order(Some(&d.routes), &d.home, &["nope".to_owned()]).unwrap_err();
    assert_eq!(error.data.as_ref().unwrap()["reason"], "connections.unknown_id");
    assert!(routes::bindings(&d.home).connection_order.is_empty(), "nothing stored");
    let twice = vec!["anthropic-key".to_owned(), "anthropic-key".to_owned()];
    assert!(set_order(Some(&d.routes), &d.home, &twice).is_err());

    let state = set_order(Some(&d.routes), &d.home, &["anthropic-key".to_owned()]).unwrap();
    assert_eq!(state["order_explicit"], true);
    assert_eq!(state_ids(&state)[0], "anthropic-key");
    let text = std::fs::read_to_string(d.home.join("routes/bindings.json")).unwrap();
    assert!(text.contains("\"connection_order\""), "{text}");
    // Removing the route drops it from the order.
    routes::remove(Some(&d.routes), &d.home, "anthropic-key").unwrap();
    assert!(routes::bindings(&d.home).connection_order.is_empty());
}

#[test]
fn spread_defaults_on_and_is_stored() {
    let d = dirs();
    assert_eq!(state(Some(&d.routes), &d.home)["spread"], true);
    assert_eq!(set_spread(Some(&d.routes), &d.home, false).unwrap()["spread"], false);
    assert_eq!(routes::bindings(&d.home).spread, Some(false));
}

#[test]
fn a_key_is_added_as_a_reference_and_listed_with_its_provider() {
    let d = dirs();
    let inline = add_key(Some(&d.routes), &d.home, "openrouter", "sk-or-v1-abc", None);
    assert_eq!(inline.unwrap_err().data.unwrap()["reason"], "route.secret_inline");
    assert!(add_key(Some(&d.routes), &d.home, "mistral", "keychain:x", None).is_err());
    let (id, state) =
        add_key(Some(&d.routes), &d.home, "openrouter", "keychain:cmux-or", Some("Mine")).unwrap();
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
    assert_eq!(key["families"], json!(["claude", "codex"]));
    assert_eq!(key["label"], "Mine");
    assert_eq!(key["signed_in"], true);
    assert_eq!(key["serves_cloud"], false, "Revision 2: only Anthropic and OpenAI keys");
    let (second, _) =
        add_key(Some(&d.routes), &d.home, "openrouter", "keychain:cmux-or-2", None).unwrap();
    assert_eq!(second, "openrouter-key-2");
    let route = routes::find(Some(&d.routes), "openrouter-key").unwrap();
    assert_eq!(route.file.secret.as_deref(), Some("keychain:cmux-or"));
    assert_eq!(route.file.provider.as_deref(), Some("openrouter"));
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
fn every_connection_kind_turns_off_and_a_disabled_one_gets_no_credential() {
    let d = dirs();
    let token = secret_file(&d, "t", "sk-ant-oat01-x");
    add_claude_token(Some(&d.routes), &d.home, &token, None).unwrap();
    let plan = RouteFile {
        name: Some("ChatGPT plan".into()),
        kind: RouteKind::ChatgptPlan,
        families: vec!["codex".into()],
        anthropic_base_url: None,
        openai_base_url: Some(chatgpt::CODEX_BACKEND.into()),
        auth: None,
        secret: None,
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
    for id in ["claude-token", "chatgpt", "claude-login"] {
        let answer = accounts::set_for_test(Some(&d.routes), &d.home, id, Some(false));
        assert_eq!(answer.unwrap()["enabled"], false, "{id}");
        let s = state(Some(&d.routes), &d.home);
        let c = find(&s, id);
        assert_eq!(c["enabled"], false, "{id}");
        assert_eq!(c["default_for"], json!([]), "{id} is nobody's default when off");
        assert_eq!(
            state_ids(&s).last().map(String::as_str),
            Some(id),
            "{id}: a turned-off connection sorts last"
        );
        if id != "claude-login" {
            let e = credential_plan(Some(&d.routes), &d.home, id).unwrap_err();
            assert_eq!(e.data.unwrap()["reason"], "connections.disabled", "{id}");
        }
        accounts::set_for_test(Some(&d.routes), &d.home, id, Some(true)).unwrap();
        assert_eq!(find(&state(Some(&d.routes), &d.home), id)["enabled"], true, "{id}");
    }
    assert!(routes::bindings(&d.home).disabled_connections.is_empty());
    // The switch of claude-login lives in the bindings, not a route file.
    assert!(routes::find(Some(&d.routes), "claude-login").is_err());
}

#[test]
fn which_connections_serve_cloud() {
    for (kind, provider, cloud) in [
        ("chatgpt-plan", "openai", true),
        ("claude-token", "anthropic", true),
        ("api-key", "anthropic", true),
        ("api-key", "openai", true),
        ("api-key", "openrouter", false),
        ("api-key", "google", false),
        ("api-key", "xai", false),
        ("codex-login", "openai", false),
        ("claude-login", "anthropic", false),
        ("subscription", "openai", false),
    ] {
        assert_eq!(serves_cloud(kind, provider), cloud, "{kind} {provider}");
    }
    let d = dirs();
    let s = state(Some(&d.routes), &d.home);
    assert_eq!(find(&s, "codex-login")["serves_cloud"], false);
    assert_eq!(find(&s, "claude-login")["serves_cloud"], false);
}

#[test]
fn a_claude_token_is_added_as_a_reference_and_delivered_as_the_oauth_token() {
    let d = dirs();
    let inline = add_claude_token(Some(&d.routes), &d.home, "sk-ant-oat01-abc", None);
    assert_eq!(inline.unwrap_err().data.unwrap()["reason"], "route.secret_inline");
    let reference = secret_file(&d, "claude-token", "sk-ant-oat01-secret");
    let (id, state) = add_claude_token(Some(&d.routes), &d.home, &reference, None).unwrap();
    assert_eq!(id, "claude-token");
    let c = find(&state, "claude-token");
    assert_eq!(c["kind"], "claude-token");
    assert_eq!(c["provider"], "anthropic");
    assert_eq!(c["families"], json!(["claude"]));
    assert_eq!(c["label"], "Claude Code token");
    assert_eq!(c["signed_in"], true);
    assert_eq!(c["serves_cloud"], true);
    let route = routes::find(Some(&d.routes), "claude-token").unwrap();
    assert_eq!(route.file.secret.as_deref(), Some(reference.as_str()), "only the reference");
    assert!(matches!(
        routes::env_for(&route, "claude", &d.home),
        Err(routes::RouteError::Unavailable(_))
    ));
    let (family, kind, var, secret) =
        credential_plan(Some(&d.routes), &d.home, "claude-token").unwrap();
    assert_eq!((family.as_str(), kind, var), ("claude", "claude-token", "CLAUDE_CODE_OAUTH_TOKEN"));
    assert_eq!(resolve("claude-token", &secret.unwrap()).unwrap(), "sk-ant-oat01-secret");
}

#[test]
fn a_claude_token_with_whitespace_inside_is_delivered_without_it() {
    let d = dirs();
    let reference = secret_file(&d, "claude-token", " sk-ant-oat01-ab\n  cd\t\u{a0}ef \r");
    add_claude_token(Some(&d.routes), &d.home, &reference, None).unwrap();
    let (_, kind, _, secret) = credential_plan(Some(&d.routes), &d.home, "claude-token").unwrap();
    let value = delivered(kind, resolve("claude-token", &secret.unwrap()).unwrap());
    assert_eq!(value, "sk-ant-oat01-abcdef");
    let env = json!({"env": {"CLAUDE_CODE_OAUTH_TOKEN": value}});
    assert!(crate::agent_credentials::AgentCredential::parse(&env).is_ok());
    assert_eq!(delivered("api-key", "a b".into()), "a b", "only a Claude token is reshaped");
}

#[test]
fn keys_are_delivered_in_their_providers_variable_and_logins_not_at_all() {
    let d = dirs();
    let anthropic = secret_file(&d, "a", "sk-ant-api-1");
    let openai = secret_file(&d, "o", "sk-proj-1");
    add_key(Some(&d.routes), &d.home, "anthropic", &anthropic, None).unwrap();
    add_key(Some(&d.routes), &d.home, "openai", &openai, None).unwrap();
    add_key(Some(&d.routes), &d.home, "openrouter", "keychain:cmux-or", None).unwrap();
    let (family, kind, var, _) =
        credential_plan(Some(&d.routes), &d.home, "anthropic-key").unwrap();
    assert_eq!((family.as_str(), kind, var), ("claude", "api-key", "ANTHROPIC_API_KEY"));
    let (family, _, var, secret) = credential_plan(Some(&d.routes), &d.home, "openai-key").unwrap();
    assert_eq!((family.as_str(), var), ("codex", "OPENAI_API_KEY"));
    assert_eq!(resolve("openai-key", &secret.unwrap()).unwrap(), "sk-proj-1");
    for id in ["openrouter-key", "codex-login", "claude-login"] {
        let e = credential_plan(Some(&d.routes), &d.home, id).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "connections.not_cloud", "{id}");
    }
    let e = credential_plan(Some(&d.routes), &d.home, "nope").unwrap_err();
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
        name: Some("ChatGPT plan".into()),
        kind: RouteKind::ChatgptPlan,
        families: vec!["codex".into()],
        anthropic_base_url: None,
        openai_base_url: Some(chatgpt::CODEX_BACKEND.into()),
        auth: None,
        secret: None,
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
    let list = list(Some(&d.routes), &d.home, &routes::bindings(&d.home));
    let plan = list.iter().find(|c| c.id == "chatgpt").unwrap();
    assert_eq!(plan.kind, "chatgpt-plan");
    assert!(plan.signed_in);
    assert_eq!(plan.email.as_deref(), Some("alex@example.com"));
    assert_eq!(plan.plan.as_deref(), Some("plus"));
    assert!(plan.serves_cloud);
    let (family, kind, var, secret) = credential_plan(Some(&d.routes), &d.home, "chatgpt").unwrap();
    assert_eq!(
        (family.as_str(), kind, var),
        ("codex", "chatgpt-plan", "CMUX_CHATGPT_ACCESS_TOKEN")
    );
    assert!(secret.is_none(), "the daemon's own token, not a reference");
    // A sign-in from the retired token-sharing client (`oaiapp_...`) reads signed out: its
    // token is refused by OpenAI, so the person signs in again (cmux#45774).
    let old = chatgpt::store::Record { client_id: "oaiapp_x".into(), ..record.clone() };
    chatgpt::store::write(&d.home, "chatgpt", &old).unwrap();
    let list = super::list(Some(&d.routes), &d.home, &routes::bindings(&d.home));
    assert!(!list.iter().find(|c| c.id == "chatgpt").unwrap().signed_in);
    // A local chat never spawns on it.
    let route = routes::find(Some(&d.routes), "chatgpt").unwrap();
    assert!(matches!(
        routes::env_for(&route, "codex", &d.home),
        Err(routes::RouteError::Unavailable(_))
    ));
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
    let list = list(Some(&d.routes), &d.home, &routes::bindings(&d.home));
    let plan = list.iter().find(|c| c.id == "chatgpt").unwrap();
    assert_eq!(plan.kind, "chatgpt-plan");
    assert!(plan.serves_cloud && plan.signed_in);
    assert_eq!(plan.email.as_deref(), Some("ci@example.com"));
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
    let (routes_dir, home) = (d.routes.clone(), d.home.clone());
    let begun = svc
        .begin(
            move |reference| {
                add_token_reference(Some(&routes_dir), &home, reference, Some("Work Claude"))
            },
            |_| {},
        )
        .await
        .unwrap();
    assert_eq!(begun.url.as_deref(), Some("https://claude.ai/oauth/authorize?abc"));
    let status = svc.wait(&begun.attempt, Duration::from_secs(10)).await.unwrap();
    assert_eq!(status, chatgpt::Status::Done("claude-token".into()));
    let reply = token_wait_reply(Some(&d.routes), &d.home, &status);
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
    let failed = token_wait_reply(None, &d.home, &chatgpt::Status::Failed("no_url".into()));
    assert_eq!(failed, json!({"status": "failed", "connection": null, "error": "no_url"}));
}
