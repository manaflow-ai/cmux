use super::derive_template_workspace_key;

/// The key the first derivation (#27895) gave: a restart of a claim cut short finds its
/// workspace by this key, so the derivation's output must stay byte for byte the same.
#[test]
fn the_template_workspace_key_is_the_same_uuidv8_as_the_first_derivation() {
    assert_eq!(
        derive_template_workspace_key("sess-0123", "6b0c1a52-7d3e-4f6a-9b1c-2d3e4f5a6b7c"),
        "c20bfc16-7d4f-8de7-a6a2-8ec42b62a821"
    );
}
