//! The customize types: written from `cmux_customize::schema` at build time, so they name
//! every key this cmux has, and the TypeScript copy in the checkout is the same text.

use cmux_extension_sdk::customize::{self, keys};
use std::path::PathBuf;

#[test]
fn the_rust_tables_are_the_customize_schema() {
    let schema = cmux_customize::schema::Schema::current();
    assert_eq!(customize::SETTINGS.len(), schema.settings.len());
    assert_eq!(customize::SETTINGS_HASH, schema.settings_hash);
    for (table, setting) in customize::SETTINGS.iter().zip(&schema.settings) {
        assert_eq!(table.key, setting.key);
        assert_eq!(table.kind, setting.kind);
        assert_eq!(table.agent_settable, setting.agent_settable);
        let default = setting.default.as_ref().map(|value| value.to_string());
        assert_eq!(table.default, default.as_deref(), "{}", setting.key);
    }
    // A key is a constant: a misspelled one does not compile.
    assert_eq!(keys::APPEARANCE_THEME_FILE, "appearance.themeFile");
    assert!(customize::setting(keys::APPEARANCE_ACCENT).is_some_and(|s| s.theme_file));
    assert_eq!(customize::VIEW_SLOTS.len(), schema.views.len());
    assert_eq!(customize::EXTENSION_POINTS.len(), cmux_app_manifest::KNOWN_INTERFACES.len());
    assert_eq!(customize::THEME_TOKENS.len(), schema.theme.tokens.len());
    let section = customize::VIEW_SLOTS.iter().find(|s| s.interface == "cmux.section/1");
    assert_eq!(section.map(|s| s.places), Some(&["top", "middle", "bottom"][..]));
}

/// The staleness check: the TypeScript types in this checkout (gitignored; every build of
/// this crate writes them) are exactly what the schema writes now.
#[test]
fn the_typescript_types_in_the_checkout_are_current() {
    let schema = cmux_customize::schema::Schema::current();
    let expected = cmux_customize::schema::typescript(&schema);
    assert_eq!(customize::TYPESCRIPT, expected, "the build wrote other types than the schema");
    let file =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("typescript/src/generated/customize.ts");
    let on_disk = std::fs::read_to_string(&file).unwrap_or_default();
    assert!(
        on_disk == expected,
        "{} is stale or missing: build cmux-extension-sdk again (cargo build -p cmux-extension-sdk), \
         or write it with `cmux customize schema --typescript > {}`",
        file.display(),
        file.display()
    );
}
