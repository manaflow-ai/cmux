//! A pooled Claude Code agent took its model at spawn (`--model`), and a new chat on it never
//! sends `session/set_model`: an agent pooled on one model (the spare of the chat before) is never
//! served to a chat asking for another. Production 2026-11-10: `acp ensure -m
//! claude/claude-haiku-5-5` on a VM ran the Sonnet of the chat before it.

use super::*;

fn key(model: Option<&str>) -> PoolKey {
    PoolKey {
        origin: Origin::Local,
        cwd: PathBuf::from("/a"),
        harness: "claude".into(),
        preset: None,
        args: vec!["claude".into()],
        system_prompt_sha256: None,
        auth: String::new(),
        account: None,
        machine: None,
        prompt_suggestions: Some(false),
        model: model.map(str::to_owned),
    }
}

fn draft(model_request: Option<&str>) -> SessionMeta {
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s", "name": "s", "harness": "claude",
        "cwd": "/a", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    meta.model_request = model_request.map(str::to_owned);
    meta
}

#[test]
fn the_key_carries_the_model_the_agent_is_spawned_with() {
    assert_eq!(spawn_model(&draft(Some("claude-haiku-5-5"))).as_deref(), Some("claude-haiku-5-5"));
    assert_eq!(spawn_model(&draft(Some("default"))), None);
    assert_eq!(spawn_model(&draft(Some(""))), None);
    assert_eq!(spawn_model(&draft(None)), None);
}

#[test]
fn an_agent_pooled_on_another_model_is_discarded_not_served() {
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    let now = Duration::from_secs(1);
    let sonnet = key(Some("claude-sonnet-5-5"));
    let generation = pool.want(Role::Spare, sonnet.clone(), now).start.expect("a start");
    assert!(pool.complete(&sonnet, generation, "warm-sonnet", now).is_none());
    match pool.take(&key(Some("claude-haiku-5-5"))) {
        Take::Ready(p) => panic!("served {p}, pooled on Sonnet, to a chat that asked for Haiku"),
        Take::Discard(_) | Take::Miss => {}
        Take::Warming(_) => panic!("waited on an agent pooled on another model"),
    }
}

#[test]
fn an_agent_pooled_on_the_asked_model_is_served() {
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    let now = Duration::from_secs(1);
    let haiku = key(Some("claude-haiku-5-5"));
    let generation = pool.want(Role::Spare, haiku.clone(), now).start.expect("a start");
    assert!(pool.complete(&haiku, generation, "warm-haiku", now).is_none());
    assert!(matches!(pool.take(&haiku), Take::Ready("warm-haiku")));
}
