//! Scope risk classes (`cmux-app-host/schema/v2/scope-classes.json`): one
//! table for the validator, the supervisor's consent sheet and the store.

use regex::Regex;
use serde_json::Value;
use std::sync::OnceLock;

/// The scope class table, embedded so every consumer classifies identically.
pub const SCOPE_CLASSES: &str = include_str!("../../cmux-app-host/schema/v2/scope-classes.json");

/// How much review a scope needs before an app may hold it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScopeClass {
    /// Granted with the app; listed in Settings and revocable.
    Standard,
    /// Highlighted on the consent sheet; revocable.
    Sensitive,
    /// First-party apps, or Verified apps whose review covers the scope.
    Restricted,
    /// Never granted at install; any tier gets it only by an explicit user
    /// grant in the native confirmation sheet, with a warning.
    Elevated,
}

/// A scope's class and whether only an app server may hold it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScopeInfo {
    pub class: ScopeClass,
    pub server_only: bool,
}

fn rules() -> &'static Vec<(Regex, ScopeInfo)> {
    static RULES: OnceLock<Vec<(Regex, ScopeInfo)>> = OnceLock::new();
    RULES.get_or_init(|| {
        let table: Value = serde_json::from_str(SCOPE_CLASSES).expect("scope classes are JSON");
        table["rules"]
            .as_array()
            .expect("rules")
            .iter()
            .map(|r| {
                let class = match r["class"].as_str() {
                    Some("standard") => ScopeClass::Standard,
                    Some("sensitive") => ScopeClass::Sensitive,
                    Some("restricted") => ScopeClass::Restricted,
                    Some("elevated") => ScopeClass::Elevated,
                    other => panic!("unknown scope class {other:?}"),
                };
                let pattern =
                    Regex::new(r["pattern"].as_str().expect("pattern")).expect("rule compiles");
                (
                    pattern,
                    ScopeInfo { class, server_only: r["serverOnly"].as_bool().unwrap_or(false) },
                )
            })
            .collect()
    })
}

/// The class of `scope`, or `None` when no rule knows it.
pub fn scope_info(scope: &str) -> Option<ScopeInfo> {
    rules().iter().find(|(re, _)| re.is_match(scope)).map(|(_, info)| *info)
}
