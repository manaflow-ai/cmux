//! The sub-session settings (`agents.subsessions.*`): their keys, the catalog rows that give
//! their defaults and ranges, and whether sub-session tools are on. The sub-sessions themselves
//! are in `hub/subsessions.rs`.

use serde_json::Value;

/// The settings keys (schemas/settings/source/subsessions.json).
pub const SETTING_ENABLED: &str = "agents.subsessions.enabled";
pub const SETTING_MAX_CHILDREN: &str = "agents.subsessions.maxChildren";
pub const SETTING_MAX_DEPTH: &str = "agents.subsessions.maxDepth";
pub const SETTING_MAX_RUNNING: &str = "agents.subsessions.maxRunning";
/// `maxRunning`'s default and ceiling until the catalog has its row.
const MAX_RUNNING_FALLBACK: NumberSetting = NumberSetting { default: 1000, max: 1000 };
pub const SETTING_ANSWER_QUESTIONS: &str = "agents.subsessions.answerQuestions";
/// The settings catalog source of those keys: their defaults and ranges have
/// one definition, shared with the app's Settings.
const CATALOG_SOURCE: &str = include_str!("../../../../schemas/settings/source/subsessions.json");

/// One number setting of the catalog: its default and the largest value.
#[derive(Clone, Copy)]
pub struct NumberSetting {
    pub default: u32,
    pub max: u32,
}

/// The catalog rows the daemon reads.
pub struct Catalog {
    pub enabled: bool,
    pub answer_questions: bool,
    pub max_children: NumberSetting,
    pub max_depth: NumberSetting,
    pub max_running: NumberSetting,
}

/// The catalog, parsed once from the embedded source.
pub fn catalog() -> &'static Catalog {
    static CATALOG: std::sync::OnceLock<Catalog> = std::sync::OnceLock::new();
    CATALOG.get_or_init(|| {
        // crash-allow: the source is a checked-in file embedded with include_str!, so a bad row fails every daemon start in tests/subsessions.rs before it can ship
        parse_catalog(CATALOG_SOURCE).expect("subsessions.json rows")
    })
}

/// The agents.subsessions rows of a settings source file, or None when one is missing.
fn parse_catalog(source: &str) -> Option<Catalog> {
    let doc: Value = serde_json::from_str(source).ok()?;
    let row = |key: &str| -> Option<Value> {
        doc["lists"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|l| l["rows"].as_array().into_iter().flatten())
            .find(|r| r["key"] == key)
            .cloned()
    };
    let get = |v: &Value| v.as_u64().and_then(|n| u32::try_from(n).ok());
    let number = |key: &str| -> Option<NumberSetting> {
        let r = row(key)?;
        Some(NumberSetting { default: get(&r["default"])?, max: get(&r["range"]["max"])? })
    };
    Some(Catalog {
        enabled: row(SETTING_ENABLED)?["default"].as_bool()?,
        answer_questions: row(SETTING_ANSWER_QUESTIONS)?["default"].as_bool()?,
        max_children: number(SETTING_MAX_CHILDREN)?,
        max_depth: number(SETTING_MAX_DEPTH)?,
        max_running: number(SETTING_MAX_RUNNING).unwrap_or(MAX_RUNNING_FALLBACK),
    })
}

/// Whether sub-session tools are on (settings `agents.subsessions.enabled`,
/// else the catalog default).
pub fn enabled() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, SETTING_ENABLED)
                .and_then(|v| v.as_bool())
                .unwrap_or(catalog().enabled)
        }
        _ => catalog().enabled,
    }
}
