//! An `agents.promptSuggestions` MDM or the team policy forces reaches the `__agent-host` that
//! runs a chat's translator (`SpawnSpec::prompt_suggestions_managed`): the host is its own process
//! and never sees the daemon's settings push, so a forced off still asked Claude Code for
//! suggestions, each one an extra model call (review of cmux#33097).

use super::*;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

fn claude_spec(dir: &Path, session: &str, managed: Option<bool>) -> SpawnSpec {
    let mut spec = spec(dir, session);
    spec.args = vec![FAKE_CLAUDE.into()];
    spec.env.push(("CLAUDE_CONFIG_DIR".into(), dir.join("claude").to_string_lossy().into_owned()));
    spec.translator = Some(agent_host::TranslatorSpec {
        acp_session_id: "acp-1".into(),
        mode: "default".into(),
        model: "haiku".into(),
        effort: "default".into(),
        fast: false,
        prompt_suggestions: true,
        recap: None,
        claude_session_id: None,
    });
    spec.prompt_suggestions_managed = managed;
    spec
}

/// The `initialize` control request the host's translator wrote to Claude Code's stdin (logged as
/// a `claude.stdin` tap).
async fn initialize_sent(dir: &Path, session: &str, managed: Option<bool>) -> Value {
    let record =
        link::spawn(&launcher(), &claude_spec(dir, session, managed)).await.expect("spawn");
    let lock = live_lock(dir, &record);
    let (owner, _) = connected(&record, 0).await;
    let mut logged = 0;
    request(&owner, 1, "initialize", json!({"protocolVersion": 1})).await;
    let seen = read_until(&owner, &mut logged, |e| {
        matches!(e, Entry::Tap { dir: TapDir::Out, msg }
            if msg["method"] == "claude.stdin" && msg["params"]["request"]["subtype"] == "initialize")
    })
    .await;
    let Some((_, Entry::Tap { msg, .. })) = seen.last() else { unreachable!() };
    let sent = msg["params"]["request"].clone();
    owner.terminate(Duration::from_millis(500)).await.unwrap();
    read_until(&owner, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    sent
}

#[tokio::test]
async fn a_host_started_after_a_forced_off_asks_claude_for_no_suggestions() {
    let dir = scratch("managed-suggestions");
    // Nothing forced and no settings file: suggestions are on, so the request asks for them.
    let unforced = initialize_sent(&dir, "s-unforced", None).await;
    assert_eq!(unforced["promptSuggestions"], true, "{unforced}");
    // A forced off beats the default: the host's own translator must not ask.
    let forced = initialize_sent(&dir, "s-forced-off", Some(false)).await;
    assert!(forced.get("promptSuggestions").is_none(), "{forced}");
    let _ = std::fs::remove_dir_all(&dir);
}
