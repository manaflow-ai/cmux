//! The customize templates (`skills/cmux-customization/templates/*/main.js`) run in the
//! native host's QuickJS VM as a person's `~/.config/cmux/customize` app does. The bun
//! kit tests run them in another engine, which accepts code QuickJS refuses.

mod common;

use cmux_app_host::Limits;
use common::Harness;
use serde_json::{Value, json};
use std::path::Path;

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects it.
mod apps {
    use super::*;

    fn templates() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../skills/cmux-customization/templates")
    }

    fn harness(name: &str) -> Harness {
        let main = std::fs::read_to_string(templates().join(name).join("main.js"))
            .unwrap_or_else(|e| panic!("{name}/main.js: {e}"));
        let init = json!({ "app": { "id": "local/customize", "version": "1.0.0" } });
        let mut h = Harness::with(&main, init, Limits::default());
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_millis() as u64;
        let chats = json!({ "chats": [
            { "id": "s1", "title": "Approve the migration", "state": "input", "unread": false, "harness": "claude",
              "project": "api", "cwd": "/src/api", "workspace": "ws_1", "machine": null, "step": "Asking to run it",
              "error": null, "since_ms": now - 120_000, "updated_ms": now - 120_000, "created_ms": now - 600_000,
              "pull_requests": [] },
            { "id": "s2", "title": "Run the suite", "state": "working", "unread": false, "harness": "codex",
              "project": "desktop", "cwd": null, "workspace": null, "machine": null, "step": null, "error": null,
              "since_ms": now - 240_000, "updated_ms": now - 240_000, "created_ms": now - 900_000,
              "pull_requests": [] }
        ]});
        h.handle("agent_chat.list", move |_, _| (true, json!({ "value": chats.clone() })));
        h.handle("workspace.list", |_, _| {
            (true, json!({ "value": [{ "id": "ws_1", "name": "api", "focused": true }] }))
        });
        h.handle("tab.list", |_, _| (true, json!({ "value": [] })));
        h.handle("app.storage.get", |_, _| (true, json!({ "value": null })));
        h
    }

    fn exports(name: &str) -> Vec<String> {
        let manifest: Value = serde_json::from_str(
            &std::fs::read_to_string(templates().join(name).join("cmux-app.json"))
                .expect("manifest"),
        )
        .expect("manifest json");
        manifest["implements"]
            .as_object()
            .expect("implements")
            .values()
            .filter_map(|entry| entry["export"].as_str().map(str::to_string))
            .collect()
    }

    #[test]
    fn every_customize_template_mounts_in_the_native_vm() {
        let mut names: Vec<String> = std::fs::read_dir(templates())
            .expect("templates")
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert!(names.contains(&"threads".to_string()), "{names:?}");
        for name in names {
            for export in exports(&name) {
                let mut h = harness(&name);
                assert_eq!(
                    h.mount("m", &export, json!({})),
                    None,
                    "{name}: {export} failed to mount"
                );
            }
        }
    }

    #[test]
    fn the_threads_template_draws_cards_in_the_native_vm() {
        let mut h = harness("threads");
        assert_eq!(h.mount("m", "renderThreads", json!({})), None);
        let texts = h.texts("m");
        for expected in ["Approve the migration", "Input", "Working"] {
            assert!(texts.iter().any(|t| t == expected), "{expected} missing from {texts:?}");
        }
    }
}
