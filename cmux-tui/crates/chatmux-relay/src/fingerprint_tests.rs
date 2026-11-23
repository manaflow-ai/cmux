use super::*;

/// Vectors produced by the JS implementation
/// (`packages/relay/bin/fingerprint.mjs` `deriveCuteCode`).
#[test]
fn matches_the_js_implementation_on_pinned_vectors() {
    assert_eq!(derive_cute_code("test-key"), "gecko-oriole-35");
    assert_eq!(
        derive_cute_code("MCowBQYDK2VuAyEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
        "salmon-radish-40"
    );
    assert_eq!(derive_cute_code("abc"), "pebble-island-22");
}
