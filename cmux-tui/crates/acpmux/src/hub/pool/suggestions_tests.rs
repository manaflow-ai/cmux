//! A pooled Claude or Codex agent read `agents.promptSuggestions` once as its host started: a
//! change since (the settings file, or what MDM or the team policy forces) leaves its key
//! unmatched, so a new chat never takes an agent under the old switch (review F2 of cmux#33097).

use super::*;

fn profile(kind: &str, argv: &[&str]) -> HarnessProfile {
    serde_json::from_value(json!({"kind": kind, "argv": argv})).expect("profile")
}

fn key(prompt_suggestions: Option<bool>) -> PoolKey {
    PoolKey {
        origin: Origin::Local,
        cwd: PathBuf::from("/a"),
        harness: "claude".into(),
        preset: None,
        args: Vec::new(),
        system_prompt_sha256: None,
        auth: String::new(),
        account: None,
        machine: None,
        prompt_suggestions,
        model: None,
        effort: None,
    }
}

#[test]
fn only_harnesses_that_read_the_switch_carry_it_in_their_key() {
    let claude = profile("claude-stdio", &["claude"]);
    let codex = profile("acp", &["codex", "app-server"]);
    let opencode = profile("acp", &["opencode", "acp"]);
    assert_eq!(suggestions_at_start(&claude, || false), Some(false));
    assert_eq!(suggestions_at_start(&codex, || true), Some(true));
    assert_eq!(suggestions_at_start(&opencode, || panic!("opencode reads no switch")), None);
}

#[test]
fn an_agent_pooled_under_the_old_switch_is_discarded_not_served() {
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    let now = Duration::from_secs(1);
    let on = key(Some(true));
    let generation = pool.want(Role::Spare, on.clone(), now).start.expect("a start");
    assert!(pool.complete(&on, generation, "warm-on", now).is_none());
    match pool.take(&key(Some(false))) {
        Take::Discard(Some("warm-on")) => {}
        Take::Ready(p) => panic!("served {p} under the old switch"),
        _ => panic!("the warm agent was neither served nor discarded"),
    }
}
