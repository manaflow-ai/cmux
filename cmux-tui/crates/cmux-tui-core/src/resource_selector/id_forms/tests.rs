//! The id-prefix match of the one resolver (W5-P). Public ids are random,
//! so a shared 4-digit prefix is made here from fixed ids, not from a mux.

use super::*;

/// A tab id: `tab_8a3f`, then `tail` padded with zeros to 32 hex digits.
fn tab(tail: &str) -> String {
    format!("tab_8a3f{tail:0<28}")
}

#[test]
fn w5p_a_shared_prefix_is_ambiguous_with_every_candidate_and_never_a_guess() {
    let (one, two) = (tab("1"), tab("2"));
    let other = format!("tab_9{}", "0".repeat(31));
    let ids = vec![two.clone(), other.clone(), one.clone()];

    let error = match_prefix("tab", "tab_8a3f", ids.clone()).unwrap_err();
    assert_eq!(error.code, "selector.ambiguous", "{error:?}");
    assert_eq!(error.details["candidates"], serde_json::json!([one, two]));
    assert_eq!(error.details["scope"], "tab");
    assert!(error.message.contains("2 tabs have ids that start with tab_8a3f"), "{error:?}");

    // One more digit, or another prefix, names one tab.
    assert_eq!(match_prefix("tab", "tab_8a3f1", ids.clone()).unwrap(), Some(one));
    assert_eq!(match_prefix("tab", "tab_9000", ids.clone()).unwrap(), Some(other));

    // A prefix of no id is not found, with the id-shape hint.
    let error = match_prefix("tab", "tab_7777", ids).unwrap_err();
    assert_eq!(error.code, "selector.not_found", "{error:?}");
    assert!(error.message.contains("32 hex digits, and this one has 4"), "{error:?}");
    assert!(error.message.contains("cmux tab list"), "{error:?}");
}

#[test]
fn w5p_every_kind_the_resolver_expands_takes_a_four_digit_prefix() {
    for kind in [
        ResourceTarget::Workspace,
        ResourceTarget::Screen,
        ResourceTarget::Pane,
        ResourceTarget::Tab,
        ResourceTarget::Terminal,
        ResourceTarget::Browser,
    ] {
        let prefix = id_prefix(kind).unwrap();
        let four = format!("{prefix}_0123");
        assert_eq!(id_prefix_parts(&four), Some((prefix, "0123")), "{four}");
        let three = format!("{prefix}_012");
        assert_eq!(id_prefix_parts(&three), None, "{three}");
    }
    for kind in [ResourceTarget::Machine, ResourceTarget::Session] {
        assert_eq!(id_prefix(kind), None);
    }
}
