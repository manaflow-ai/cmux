//! The model alias fold (`model_catalog.rs`): the table leo-workspace `tools/model_aliases.py`
//! agrees with, against the bundled catalog.

use super::*;

fn claude() -> crate::catalog::CatalogHarness {
    bundled_harness("claude").expect("the bundled catalog lists Claude Code")
}

fn codex() -> crate::catalog::CatalogHarness {
    bundled_harness("codex").expect("the bundled catalog lists Codex")
}

fn canon(entry: &crate::catalog::CatalogHarness, name: &str) -> String {
    canonical_model(entry, name).unwrap().model
}

#[test]
fn fold_drops_case_heads_and_separator_runs() {
    assert_eq!(fold("  Fable 5.2 "), "fable-5.2");
    assert_eq!(fold("claude/fable-5.2"), "fable-5.2");
    assert_eq!(fold("Anthropic/Claude_Opus__5.5"), "claude-opus-5.5");
    assert_eq!(fold("codex/gpt-6.2-sol"), "gpt-6.2-sol");
    assert_eq!(fold("-opus - 5 _5-"), "opus-5-5");
}

#[test]
fn keys_cover_dots_dashes_joined_digits_and_the_claude_prefix() {
    let k = keys("fable5.2");
    for want in ["fable5.2", "fable5-2", "fable-5-2", "fable-5.2"] {
        assert!(k.contains(&want.to_owned()), "{want} in {k:?}");
    }
    let k = keys("claude-fable-5.2");
    assert!(k.contains(&"fable-5-2".to_owned()), "{k:?}");
    assert!(keys("gpt-6-2-sol").contains(&"gpt-6.2-sol".to_owned()));
    assert!(keys("codex-6.2-sol").contains(&"gpt-6.2-sol".to_owned()));
}

/// The table every leo-workspace entry point and acpmux read the same way: the spellings the
/// 16 dead lanes and their siblings used reach the id Claude Code takes.
#[test]
fn every_spelling_of_a_claude_model_reaches_its_id() {
    let c = claude();
    for name in [
        "fable-5.2",
        "fable5.2",
        "fable-5-2",
        "claude-fable-5.2",
        "Fable 5.2",
        "claude/fable-5.2",
        "anthropic/claude-fable-5.2",
        "FABLE_5_2",
        "claude-fable-5-2",
    ] {
        assert_eq!(canon(&c, name), "claude-fable-5-2", "{name}");
    }
    for name in ["opus-5.5", "Opus 5.5", "opus5.5", "claude-opus-5.5", "opus-5-5"] {
        assert_eq!(canon(&c, name), "claude-opus-5-5", "{name}");
    }
    for name in ["sonnet-5.5", "Sonnet 5.5", "claude/sonnet-5.5"] {
        assert_eq!(canon(&c, name), "claude-sonnet-5-5", "{name}");
    }
    for name in ["haiku-5.5", "Haiku 5.5"] {
        assert_eq!(canon(&c, name), "claude-haiku-5-5", "{name}");
    }
    // Other releases the catalog lists keep their own ids: fable-5 is Fable 5, not 5.2.
    assert_eq!(canon(&c, "fable-5.1"), "claude-fable-5-1");
    assert_eq!(canon(&c, "fable5"), "claude-fable-5");
    assert_eq!(canon(&c, "opus 4.8"), "claude-opus-4-8");
}

#[test]
fn a_suffix_is_kept_and_a_listed_name_is_never_rewritten() {
    let c = claude();
    assert_eq!(canon(&c, "opus-5.5[1m]"), "claude-opus-5-5[1m]");
    assert_eq!(canon(&c, "fable-5.2 [1m]"), "claude-fable-5-2[1m]");
    // Aliases Claude Code takes itself, and full ids, pass as given.
    for name in ["opus", "fable", "sonnet[1m]", "claude-opus-5-5", "claude-fable-5-2[1m]"] {
        let got = canonical_model(&c, name).unwrap();
        assert_eq!(got.model, name);
        assert!(got.known && !got.changed(), "{name}");
    }
}

#[test]
fn an_unknown_name_passes_through_unchanged() {
    let c = claude();
    for name in ["default", "opusplan", "claude-opus-4-5-20251101", "gpt-6.1-sol", "my-proxy-model"]
    {
        let got = canonical_model(&c, name).unwrap();
        assert_eq!(got.model, name);
        assert!(!got.changed(), "{name}");
    }
}

#[test]
fn codex_ids_keep_their_dots() {
    let x = codex();
    for name in [
        "gpt-6.2-sol",
        "gpt-6-2-sol",
        "GPT 6.2 Sol",
        "gpt6.2-sol",
        "codex/gpt-6.2-sol",
        "codex-6.2-sol",
    ] {
        assert_eq!(canon(&x, name), "gpt-6.2-sol", "{name}");
    }
    assert_eq!(canon(&x, "gpt-6-astra"), "gpt-6-astra");
    assert_eq!(canon(&x, "gpt-6.1-sol"), "gpt-6.1-sol");
    assert_eq!(canon(&x, "gpt-5-6"), "gpt-5.6");
}

#[test]
fn a_rewrite_says_so_in_one_line() {
    let got = canonical_model(&claude(), "fable-5.2").unwrap();
    assert!(got.changed());
    assert_eq!(got.line(), "model fable-5.2 -> claude-fable-5-2");
}

#[test]
fn a_name_two_ids_share_is_ambiguous_and_names_both() {
    let aliases = ["sol".to_owned()];
    let models: Vec<(&str, &[String])> =
        vec![("gpt-6.1-sol", &aliases[..]), ("gpt-6.2-sol", &aliases[..])];
    let err = canonical_among(models, "Sol").unwrap_err();
    assert_eq!(err.choices, ["gpt-6.1-sol", "gpt-6.2-sol"]);
    assert_eq!(err.to_string(), "model Sol is ambiguous: one of gpt-6.1-sol, gpt-6.2-sol");
}

#[test]
fn a_family_word_goes_to_its_newest_model() {
    let x = codex();
    for name in ["astra", "Astra", "Astra 6.2", "astra-6.2", "astra6.2", "codex/astra"] {
        assert_eq!(canon(&x, name), "gpt-6.2-astra", "{name}");
    }
    for name in ["sol", "Sol 6.2", "sol-6.2"] {
        assert_eq!(canon(&x, name), "gpt-6.2-sol", "{name}");
    }
    assert_eq!(canon(&x, "luna"), "gpt-6.1-luna");
    assert_eq!(canon(&x, "Sol 6.1"), "gpt-6.1-sol");
    assert_eq!(canon(&x, "astra-6"), "gpt-6-astra");
    let c = claude();
    assert_eq!(canon(&c, "Fable"), "claude-fable-5-2");
    assert_eq!(canon(&c, "opus"), "opus", "a listed alias stays as the harness takes it");
}

#[test]
fn only_two_real_models_competing_is_ambiguous() {
    let x = codex();
    for name in ["gpt-6.2", "GPT 6.2", "codex-6.2"] {
        let err = canonical_model(&x, name).unwrap_err();
        assert_eq!(err.choices, ["gpt-6.2-astra", "gpt-6.2-sol"], "{name}");
    }
    assert_eq!(canon(&x, "gpt 5.6"), "gpt-5.6", "an id itself beats the ids it heads");
    let err = canonical_model(&claude(), "claude").unwrap_err();
    assert!(err.choices.contains(&"claude-fable-5-2".to_owned()), "{err}");
    assert!(err.choices.len() > 2, "{err}");
}

#[test]
fn only_claude_and_codex_names_fold() {
    let mut gateway = claude();
    gateway.id = "vercel-ai-gateway".into();
    gateway.families = vec!["vercel-ai-gateway".into()];
    let got = canonical_model(&gateway, "fable-5.2").unwrap();
    assert_eq!(got.model, "fable-5.2");
    assert!(!got.changed());
}

#[test]
fn model_errors_are_told_from_capacity_and_others() {
    for e in [
        r#"[claude-code:unrecognized_model] {"model":"fable-5.2"} There's an issue with the selected model (fable-5.2). It may not exist or you may not have access to it."#,
        "There's an issue with the selected model (opus-5-5).",
        r#"404 {"type":"error","error":{"type":"not_found_error","message":"model: fable-5.2"}}"#,
        "The model `gpt-6-2-sol` does not exist or you do not have access to it.",
        r#"{"error":{"code":"model_not_found"}}"#,
        "invalid model: fable-5.2",
    ] {
        assert!(is_model_error(e), "{e}");
    }
    for e in [
        "Selected model is at capacity. Please try a different model.",
        "stream disconnected before completion",
        "529 overloaded_error",
        "Not logged in",
    ] {
        assert!(!is_model_error(e), "{e}");
    }
}

#[test]
fn a_model_error_names_its_model() {
    assert_eq!(
        model_named_in("There's an issue with the selected model (fable-5.2). It may not exist")
            .as_deref(),
        Some("fable-5.2")
    );
    assert_eq!(
        model_named_in(r#"[claude-code:unrecognized_model] {"model":"fable-5.2","x":1}"#)
            .as_deref(),
        Some("fable-5.2")
    );
    assert_eq!(
        model_named_in("The model `gpt-6-2-sol` does not exist").as_deref(),
        Some("gpt-6-2-sol")
    );
    assert_eq!(model_named_in("stream disconnected"), None);
}
