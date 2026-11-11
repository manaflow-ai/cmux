//! A pooled Claude Code agent runs the model it was started on (its `--model`): Claude Code
//! never switches a new session's model (`profile_takes_model_at_spawn`). The key carries that
//! model, so a chat takes the agent only when it asks for the same one. Before, the key had no
//! model: a Cloud chat that asked for Haiku took the spare an earlier Sonnet chat left on the
//! VM, ran Sonnet, and its record said Haiku (Leo 2026-11-10, "Does it work across every
//! expected possible workspace?").

use super::*;

fn claude() -> HarnessProfile {
    serde_json::from_value(json!({"kind": "claude-stdio", "argv": ["claude"]})).expect("profile")
}

fn draft(profile: &HarnessProfile, model: Option<&str>) -> SessionMeta {
    super::super::resolve::draft_meta(super::super::resolve::Draft {
        id: String::new(),
        agent: "claude",
        profile,
        family: "claude",
        preset: None,
        model_request: model.map(str::to_owned),
        cwd: PathBuf::from("/a"),
        agent_session_id: None,
        policy: None,
        remote: false,
    })
}

fn key_for(profile: &HarnessProfile, model: Option<&str>) -> PoolKey {
    let (model, effort) = started_on(profile, &draft(profile, model));
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
        prompt_suggestions: None,
        model,
        effort,
    }
}

/// The model `spawn_pooled` puts on a pooled Claude Code's command line for `draft`.
fn command_line_model(profile: &HarnessProfile, draft: &SessionMeta) -> Option<String> {
    let model = current_model(draft).unwrap_or_else(|| "default".into());
    let plan = crate::claude_stdio::spawn_plan(
        profile,
        None,
        false,
        Some("fresh"),
        Some("default"),
        crate::claude_stdio::OWN_MODE,
        Some(&model),
    );
    let at = plan.args.iter().position(|a| a == "--model")?;
    plan.args.get(at + 1).cloned()
}

#[test]
fn the_keyed_model_is_the_model_the_pooled_agent_runs() {
    let p = claude();
    for (asked, runs) in [
        ("claude-haiku-5-5", "claude-haiku-5-5"),
        ("claude-sonnet-5-5", "claude-sonnet-5-5"),
        ("haiku-5-5", "claude-haiku-5-5"),
        ("opus", "opus"),
    ] {
        let d = draft(&p, Some(asked));
        let (model, _) = started_on(&p, &d);
        assert_eq!(model.as_deref(), Some(runs), "asked {asked}");
        assert_eq!(command_line_model(&p, &d), model, "asked {asked}");
    }
    // The harness's own default: no --model, no model in the key.
    for none in [None, Some("default"), Some("")] {
        let d = draft(&p, none);
        assert_eq!(started_on(&p, &d), (None, None), "{none:?}");
        assert_eq!(command_line_model(&p, &d), None, "{none:?}");
    }
    // A harness whose model is set after start or in its argv keys none.
    let acp: HarnessProfile =
        serde_json::from_value(json!({"kind": "acp", "argv": ["opencode", "acp"]})).unwrap();
    assert_eq!(started_on(&acp, &draft(&acp, Some("zai/glm-5.1"))), (None, None));
}

#[test]
fn a_chat_never_takes_an_agent_pooled_on_another_model() {
    let p = claude();
    let now = Duration::from_secs(1);
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    let sonnet = key_for(&p, Some("claude-sonnet-5-5"));
    let generation = pool.want(Role::Spare, sonnet.clone(), now).start.expect("a start");
    assert!(pool.complete(&sonnet, generation, "warm-sonnet", now).is_none());
    match pool.take(&key_for(&p, Some("claude-haiku-5-5"))) {
        Take::Ready(p) => panic!("a Haiku chat took {p}, an agent started on Sonnet"),
        Take::Warming(_) => panic!("a Haiku chat waited on an agent starting on Sonnet"),
        Take::Discard(_) | Take::Miss => {}
    }
    // Nor does a chat on the harness's default take a Sonnet agent, or the other way round.
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    let generation = pool.want(Role::Spare, sonnet.clone(), now).start.expect("a start");
    assert!(pool.complete(&sonnet, generation, "warm-sonnet", now).is_none());
    assert!(!matches!(pool.take(&key_for(&p, None)), Take::Ready(_)));
}

#[test]
fn a_chat_takes_an_agent_pooled_on_the_model_it_asks_for() {
    let p = claude();
    let now = Duration::from_secs(1);
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    let haiku = key_for(&p, Some("claude-haiku-5-5"));
    let generation = pool.want(Role::Spare, haiku.clone(), now).start.expect("a start");
    assert!(pool.complete(&haiku, generation, "warm-haiku", now).is_none());
    // `haiku-5-5` is the same model as Claude Code runs it.
    assert!(matches!(pool.take(&key_for(&p, Some("haiku-5-5"))), Take::Ready("warm-haiku")));
}
