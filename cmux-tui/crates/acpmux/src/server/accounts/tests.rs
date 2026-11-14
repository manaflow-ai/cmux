use super::*;
use crate::routes::RouteFile;
use std::collections::BTreeMap;

#[test]
fn the_default_is_the_family_binding_then_the_global_one_then_the_cli_login() {
    let mut b = routes::Bindings::default();
    assert!(is_default(&b, "claude", "claude-login", true));
    assert!(!is_default(&b, "claude", "claude-2", false));
    b.global = Some("claude-2".into());
    assert!(is_default(&b, "claude", "claude-2", false));
    assert!(!is_default(&b, "claude", "claude-login", true));
    b.families.insert("claude".into(), "claude-3".into());
    assert!(is_default(&b, "claude", "claude-3", false));
    assert!(!is_default(&b, "claude", "claude-2", false));
}

#[test]
fn turning_off_the_default_account_clears_its_defaults_but_not_a_chats_binding() {
    let root = std::env::temp_dir().join(format!("acpmux-accounts-off-{}", std::process::id()));
    let (dir, state) = (root.join("routes"), root.join("state"));
    std::fs::create_dir_all(&dir).unwrap();
    let file = RouteFile {
        name: Some("Work key".into()),
        kind: RouteKind::DirectApiKey,
        families: vec!["claude".into()],
        anthropic_base_url: None,
        openai_base_url: None,
        auth: None,
        secret: Some("env:ANTHROPIC_WORK_KEY".into()),
        headers: BTreeMap::new(),
        health_url: None,
        fallback: vec![],
        auto_fallback: false,
        notes: None,
        account_home: None,
        shadow_of: None,
        disabled: false,
    };
    routes::add(Some(&dir), "claude-key", &file, false).unwrap();
    routes::update_bindings(&state, |b| {
        b.families.insert("claude".into(), "claude-key".into());
        b.families.insert("codex".into(), "codex-2".into());
        b.global = Some("claude-key".into());
        b.workspaces.insert("ws-1".into(), "claude-key".into());
        b.chats.insert("chat-1".into(), "claude-key".into());
    })
    .unwrap();
    set(Some(&dir), &state, "claude-key", Some(true), None).unwrap();
    assert_eq!(
        routes::bindings(&state).families.get("claude").map(String::as_str),
        Some("claude-key")
    );
    set(Some(&dir), &state, "claude-key", Some(false), None).unwrap();
    let b = routes::bindings(&state);
    assert_eq!(b.families.get("claude"), None, "a turned-off account still picks new chats");
    assert_eq!(b.global, None);
    assert_eq!(b.workspaces.get("ws-1"), None, "a workspace default moves new chats onto it too");
    assert_eq!(
        b.chats.get("chat-1").map(String::as_str),
        Some("claude-key"),
        "a bound chat keeps it"
    );
    assert_eq!(
        b.families.get("codex").map(String::as_str),
        Some("codex-2"),
        "another family's default stays"
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_codex_login_names_its_plan_and_email_from_the_id_token() {
    let dir = std::env::temp_dir().join(format!("acpmux-accounts-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let claims = json!({"email": "alex@example.com",
                            "https://api.openai.com/auth": {"chatgpt_plan_type": "pro"}});
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims.to_string());
    let auth = json!({"tokens": {"id_token": format!("h.{payload}.s"), "refresh_token": "x"}});
    std::fs::write(dir.join("auth.json"), auth.to_string()).unwrap();
    let login = codex_login(&dir);
    assert!(login.signed_in);
    assert_eq!(login.plan.as_deref(), Some("pro"));
    assert_eq!(login.email.as_deref(), Some("alex@example.com"));
    std::fs::write(dir.join("auth.json"), "{}").unwrap();
    assert!(!codex_login(&dir).signed_in, "an empty login file is not a login");
    std::fs::remove_file(dir.join("auth.json")).unwrap();
    assert!(!codex_login(&dir).signed_in);
    let _ = std::fs::remove_dir_all(&dir);
}
