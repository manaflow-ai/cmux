//! App ids (`tabs.newTabApp`, validation `domain:app_id`): exactly the ids an
//! app manifest may have. The rule is the manifest schema's own
//! `properties.id.pattern`, read from the schema the manifest validator
//! (cmux-app-manifest) embeds, never restated. Swift
//! (`SettingsSchema.appIDPattern`, generated) and the web page read the same
//! pattern.

use std::sync::OnceLock;

use serde_json::Value;

const MANIFEST_SCHEMA: &str = include_str!("../../../cmux-app-host/schema/v2/cmux-app.schema.json");

fn app_id_regex() -> Option<&'static regex::Regex> {
    static REGEX: OnceLock<Option<regex::Regex>> = OnceLock::new();
    REGEX
        .get_or_init(|| {
            let schema: Value = serde_json::from_str(MANIFEST_SCHEMA).ok()?;
            regex::Regex::new(schema.pointer("/properties/id/pattern")?.as_str()?).ok()
        })
        .as_ref()
}

/// The manifest's app id pattern; `None` only in a broken build.
pub fn app_id_pattern() -> Option<&'static str> {
    app_id_regex().map(regex::Regex::as_str)
}

/// Whether `id` is an id an app manifest may have. False when the pattern
/// could not be read (fail closed).
pub fn is_valid_app_id(id: &str) -> bool {
    app_id_regex().is_some_and(|regex| regex.is_match(id))
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_manifest_schema_has_an_app_id_pattern() {
        assert!(super::app_id_pattern().is_some());
        assert!(super::is_valid_app_id("local/web-pane"));
        assert!(!super::is_valid_app_id("Foo/Bar"));
    }
}
