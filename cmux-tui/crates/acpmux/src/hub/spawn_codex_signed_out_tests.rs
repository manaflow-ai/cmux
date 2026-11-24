//! hq#21792 event 12: a Codex launch on a machine (a lane VM: no Cloud marker, no join) where
//! `codex login status` says Not logged in and nothing else gives it a way in is refused at spawn,
//! naming the host, the harness and the fix (`codex_signed_out.rs`). With a sign-in, a key or a
//! provider of its own, it starts as before.

use super::*;
use crate::store::{META_SCHEMA, SessionMeta};
use serde_json::json;
use std::os::unix::fs::PermissionsExt;

fn hub() -> Arc<Hub> {
    let config: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

#[tokio::test]
async fn a_codex_with_no_login_on_a_lane_vm_is_refused_with_the_host_and_fix() {
    let root =
        std::env::temp_dir().join(format!("acpmux-spawn-codex-signed-out-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    // No etc/cmux: not a Cloud image, as on a lane VM.
    std::fs::create_dir_all(&root).unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    // A `codex` that answers `login status` as the real one does when signed out.
    let codex = root.join("bin/codex");
    std::fs::create_dir_all(codex.parent().unwrap()).unwrap();
    std::fs::write(
        &codex,
        "#!/bin/sh\nif [ \"$1\" = login ]; then echo 'Not logged in' >&2; exit 1; fi\nexit 0\n",
    )
    .unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let hub = hub();
    hub.set_vm_marker_root(root.clone());
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": "spawn-codex-signed-out",
        "name": "spawn-codex-signed-out",
        "harness": "codex",
        "cwd": home,
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap();
    let profile = |extra: &[(&str, &str)]| -> HarnessProfile {
        // Empty values mask the test runner's own env (an empty value counts as unset).
        let mut env = std::collections::BTreeMap::from([
            ("HOME".to_owned(), home.to_string_lossy().into_owned()),
            ("CODEX_HOME".to_owned(), home.join(".codex").to_string_lossy().into_owned()),
            ("CODEX_API_KEY".to_owned(), String::new()),
            ("OPENAI_API_KEY".to_owned(), String::new()),
            ("OPENAI_BASE_URL".to_owned(), String::new()),
            ("CMUX_CODEX_AUTH".to_owned(), String::new()),
        ]);
        env.extend(extra.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())));
        serde_json::from_value(json!({
            "argv": [codex.to_string_lossy(), "app-server"],
            "family": "codex",
            "env": env,
        }))
        .unwrap()
    };
    let none = std::collections::BTreeMap::new();
    let host = crate::hand::pair::hostname();

    let err = hub.spawn_profile_for(&meta, &profile(&[]), &none).await.unwrap_err();
    let text = err.message.clone();
    assert!(text.contains(&host), "names the host: {text}");
    assert!(text.contains("`codex` harness"), "names the harness: {text}");
    assert!(text.contains("codex login"), "names the fix: {text}");
    assert!(text.contains("-m claude"), "names the other harness: {text}");

    // A key of its own: it starts.
    let keyed = profile(&[("CODEX_API_KEY", "sk-own")]);
    assert!(hub.spawn_profile_for(&meta, &keyed, &none).await.is_ok());

    // A provider of its own (a lane VM's subrouter), though `codex login status` says signed out.
    std::fs::write(home.join(".codex/config.toml"), "model_provider = \"subrouter\"\n").unwrap();
    assert!(hub.spawn_profile_for(&meta, &profile(&[]), &none).await.is_ok());
    std::fs::remove_file(home.join(".codex/config.toml")).unwrap();

    // Its own sign-in.
    std::fs::write(home.join(".codex/auth.json"), r#"{"tokens":{"access_token":"t"}}"#).unwrap();
    assert!(hub.spawn_profile_for(&meta, &profile(&[]), &none).await.is_ok());
    let _ = std::fs::remove_dir_all(&root);
}
