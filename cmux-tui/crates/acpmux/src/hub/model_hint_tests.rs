use super::{hint_text, looks_like_claude_model_id};

#[test]
fn claude_model_shapes() {
    for id in [
        "claude-opus-5-5",
        "claude-sonnet-4-6",
        "claude-haiku-4-5-20251001",
        "claude-opus-4-7[1m]",
        "claude-3-5-sonnet-20241022",
        "opus",
        "sonnet[1m]",
        "haiku",
    ] {
        assert!(looks_like_claude_model_id(id), "{id}");
    }
    for name in ["claude-sr2", "claude-sr2-pipe", "claude", "claude-opus", "claude-work", "claude-"]
    {
        assert!(!looks_like_claude_model_id(name), "{name}");
    }
}

#[test]
fn harness_profile_gets_no_claude_model_suggestion() {
    let err = "unknown harness \"claude-sr2\"".to_owned();
    let out = hint_text(err, "claude-sr2", &[], Some("claude"));
    assert!(!out.contains("claude/claude-sr2"), "{out}");
    assert!(!out.contains("is a model id"), "{out}");
    assert!(out.contains("harness profile this host does not have"), "{out}");
    assert!(out.contains("-m claude/claude-opus-5-5 -e medium"), "{out}");
    assert!(!out.contains("fable"), "{out}");
}

#[test]
fn a_missing_harness_names_its_next_step() {
    let codex = hint_text("unknown harness \"codex\"".into(), "codex", &[], None);
    assert!(codex.contains("`cmux harness install codex`"), "{codex}");
    let gemini = hint_text("unknown harness \"gemini\"".into(), "gemini", &[], None);
    assert!(gemini.contains("`cmux harness add gemini --example gemini`"), "{gemini}");
    for agent in ["grok", "cursor", "antigravity"] {
        let out = hint_text(format!("unknown harness {agent:?}"), &format!("{agent}/x"), &[], None);
        assert!(out.contains(&format!("{agent:?} is not set up here")), "{out}");
        assert!(out.contains("`cmux harness add ID --registry`"), "{out}");
    }
    assert_eq!(hint_text("bad".into(), "a b", &[], None), "bad");
}

#[test]
fn real_model_id_still_suggests_claude_spelling() {
    assert!(looks_like_claude_model_id("claude-opus-5-5"));
    let hits = vec!["claude/claude-opus-5-5".to_owned()];
    let out = hint_text("unknown harness".into(), "claude-opus-5-5", &hits, Some("claude"));
    assert!(
        out.contains("\"claude-opus-5-5\" is a model id: write claude/claude-opus-5-5"),
        "{out}"
    );
}

#[test]
fn other_names_keep_the_bare_error() {
    assert_eq!(
        hint_text("unknown harness \"gpt\"".into(), "gpt", &[], None),
        "unknown harness \"gpt\""
    );
}
