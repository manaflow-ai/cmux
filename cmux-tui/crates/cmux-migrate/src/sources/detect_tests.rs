use super::setup_for;

#[test]
fn one_js_manager_and_pins_first() {
    assert_eq!(
        setup_for(&["package-lock.json", "pnpm-lock.yaml", ".tool-versions", "Cargo.lock"]),
        ["mise install", "pnpm install --frozen-lockfile", "cargo fetch"]
    );
    assert!(setup_for(&["README.md"]).is_empty());
}
