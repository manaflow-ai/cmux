//! Adopt reads a Claude Code profile's chats from Claude's store, whatever family the profile
//! declares (`claude-sr2`), and opens the session holding a chat only when its store is known
//! to be the asked one.

use super::super::Hub;
use super::{adopted_in, store_families};
use serde_json::json;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

fn home(name: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("acpmux-adopt-profile-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    home
}

/// `claude` and `claude-sr2` (a Claude Code profile of its own family) over one Claude store,
/// and a Codex profile.
fn config(home: &std::path::Path) -> crate::config::Config {
    serde_json::from_value(json!({
        "harnesses": {
            "claude": {"kind": "claude-stdio", "argv": ["claude"],
                       "env": {"CLAUDE_CONFIG_DIR": home}},
            "claude-sr2": {"kind": "claude-stdio", "argv": ["sr2", "claude2"],
                           "family": "claude-sr2", "env": {"CLAUDE_CONFIG_DIR": home}},
            "codex": {"argv": ["codex-acp"]},
        },
        "defaultHarness": "claude", "store": {"mode": "memory"}
    }))
    .unwrap()
}

fn hub(home: &std::path::Path) -> Arc<Hub> {
    let cfg = config(home);
    let store = crate::store::open(&cfg.store, home).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_harness_homes(crate::adopt::HarnessHomes {
        claude: home.to_owned(),
        codex: home.join("no-codex"),
    });
    hub
}

fn meta(id: &str, harness: &str, family: &str, native: &str) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": harness, "family": family, "cwd": "/", "status": "idle",
        "createdAt": 1, "updatedAt": 1, "agentSessionId": native
    }))
    .unwrap()
}

/// Red on the base: the folder-trust gate resolved an adopt that names no `cwd` with the
/// profile name as the family, and `claude-sr2` was "not supported".
#[tokio::test]
async fn the_trust_gate_finds_a_claude_sr2_chats_folder() {
    let home = home("trust");
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let chat = "0199a1b2-0000-7000-8000-00000000c1a0";
    let transcript = home.join(format!("projects/p/{chat}.jsonl"));
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    std::fs::write(&transcript, format!("{}\n", json!({"type": "user", "cwd": project}))).unwrap();
    let hub = hub(&home);
    for name in ["claude-sr2", "claude"] {
        let cwd = hub.adopted_cwd_for_trust(name, chat, false).await;
        assert_eq!(
            cwd.unwrap_or_else(|e| panic!("{name}: {}", e.message)),
            Some(project.to_string_lossy().into_owned()),
            "{name}"
        );
    }
    let _ = std::fs::remove_dir_all(home);
}

/// The session holding a chat is the one an adopt opens, on its own profile; one whose store
/// is another, or unknown (its profile gone from the config), never is.
#[test]
fn the_holding_session_is_matched_by_its_store() {
    let home = home("held");
    let hub = hub(&home);
    let stores = store_families(&hub.config.try_read().unwrap());
    assert_eq!(stores["claude-sr2"], "claude");
    let sessions = |metas: Vec<crate::store::SessionMeta>| -> HashMap<String, Arc<_>> {
        metas.into_iter().map(|m| (m.id.clone(), hub.make_session(m))).collect()
    };
    let id = |s: Option<Arc<crate::hub::Session>>| s.map(|s| s.id.clone());

    let held = sessions(vec![meta("sr2", "claude-sr2", "claude-sr2", "n1")]);
    assert_eq!(id(adopted_in(&held, &stores, "claude", "n1")), Some("sr2".into()));
    assert_eq!(id(adopted_in(&held, &stores, "codex", "n1")), None);
    assert_eq!(id(adopted_in(&held, &stores, "claude", "n2")), None);

    // A profile this config no longer has: its recorded family decides, and a family that
    // names no store matches nothing.
    let gone = sessions(vec![
        meta("old-sr", "claude-old", "claude-old", "n3"),
        meta("old-claude", "claude-gone", "claude", "n4"),
    ]);
    assert_eq!(id(adopted_in(&gone, &stores, "claude", "n3")), None);
    assert_eq!(id(adopted_in(&gone, &stores, "codex", "n3")), None);
    assert_eq!(id(adopted_in(&gone, &stores, "claude", "n4")), Some("old-claude".into()));
    assert_eq!(id(adopted_in(&gone, &stores, "codex", "n4")), None);
    let _ = std::fs::remove_dir_all(home);
}

/// Red on the base: the chat list's open plan offered only profiles of the `claude` family, so a
/// machine whose Claude Code runs on `claude-sr2` alone could not adopt from its store.
#[test]
fn the_open_plan_counts_a_claude_sr2_profile_as_a_claude_store() {
    let home = home("open");
    let mut cfg = config(&home);
    cfg.harnesses.remove("claude");
    let homes =
        crate::adopt::HarnessHomes { claude: home.join("default"), codex: home.join("codex") };
    let profiles = crate::chats::store_profiles(&cfg, &homes);
    let sr2 = profiles.iter().find(|p| p.name == "claude-sr2").expect("claude-sr2 adopts");
    assert_eq!(sr2.family, "claude");
    assert_eq!(sr2.claude.as_deref(), Some(home.as_path()));
    let _ = std::fs::remove_dir_all(home);
}
