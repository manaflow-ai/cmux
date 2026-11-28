//! A start placed on or forwarded to this machine keeps the name it was given
//! (`NewRequest::suffix_taken_name`): a taken one gets the first free `-N` suffix, never the
//! agent's name (`codex`). Leo: "acpmux placed the session on [a lane machine], under the name
//! "codex" instead of the one I gave it".

use super::*;
use serde_json::json;

fn test_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn named(name: &str, suffix_taken_name: bool) -> NewRequest {
    NewRequest {
        harness: Some("fake".into()),
        name: Some(name.into()),
        suffix_taken_name,
        cwd: Some(std::env::temp_dir()),
        ..NewRequest::default()
    }
}

#[tokio::test]
async fn a_placed_start_keeps_its_name_and_a_taken_one_is_suffixed_never_the_agents() {
    let hub = test_hub();
    let first = hub.new_session(named("slam-09", true)).await.unwrap();
    assert_eq!(first.meta().name, "slam-09");
    assert!(first.meta().name_given);
    let second = hub.new_session(named("slam-09", true)).await.unwrap();
    assert_eq!(second.meta().name, "slam-09-2");
    assert!(second.meta().name_given);
    let third = hub.new_session(named("slam-09", true)).await.unwrap();
    assert_eq!(third.meta().name, "slam-09-3");
    for s in [&first, &second, &third] {
        assert_ne!(s.meta().name, "fake", "never the agent's name");
    }
}

#[tokio::test]
async fn any_other_start_with_a_taken_name_is_still_refused() {
    // `new --reuse` finds the running session by this refusal (`find_or_create`).
    let hub = test_hub();
    hub.new_session(named("lane-a", false)).await.unwrap();
    let Err(e) = hub.new_session(named("lane-a", false)).await else {
        panic!("a taken name was not refused")
    };
    assert!(e.message.contains("is taken"), "{}", e.message);
}

#[test]
fn the_suffix_is_the_first_free_one_from_two() {
    let taken = |names: &[&str]| names.iter().map(|n| n.to_string()).collect::<Vec<_>>();
    assert_eq!(suffixed_name(&taken(&[]), "x"), "x");
    assert_eq!(suffixed_name(&taken(&["codex"]), "x"), "x");
    assert_eq!(suffixed_name(&taken(&["x"]), "x"), "x-2");
    assert_eq!(suffixed_name(&taken(&["x", "x-2", "x-4"]), "x"), "x-3");
}
