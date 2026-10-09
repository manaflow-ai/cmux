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

pub(crate) fn parse_rules(raw: &str) -> Result<Vec<(Regex, ScopeInfo)>, String> {
    let table: Value =
        serde_json::from_str(raw).map_err(|e| format!("scope classes are not JSON: {e}"))?;
    table["rules"]
        .as_array()
        .ok_or("scope classes have no rules")?
        .iter()
        .map(|r| {
            let class = match r["class"].as_str() {
                Some("standard") => ScopeClass::Standard,
                Some("sensitive") => ScopeClass::Sensitive,
                Some("restricted") => ScopeClass::Restricted,
                Some("elevated") => ScopeClass::Elevated,
                other => return Err(format!("unknown scope class {other:?}")),
            };
            let pattern = r["pattern"].as_str().ok_or("a scope rule has no pattern")?;
            let pattern =
                Regex::new(pattern).map_err(|e| format!("scope rule {pattern:?}: {e}"))?;
            Ok((
                pattern,
                ScopeInfo { class, server_only: r["serverOnly"].as_bool().unwrap_or(false) },
            ))
        })
        .collect()
}

/// The embedded rules, or `Err` when they do not load (a unit test loads them).
pub(crate) fn rules() -> Result<&'static [(Regex, ScopeInfo)], &'static str> {
    static RULES: OnceLock<Result<Vec<(Regex, ScopeInfo)>, String>> = OnceLock::new();
    RULES
        .get_or_init(|| parse_rules(SCOPE_CLASSES))
        .as_ref()
        .map(Vec::as_slice)
        .map_err(String::as_str)
}

/// The class of `scope`, or `None` when no rule knows it (also when the
/// embedded rules do not load: an unknown scope is refused, fail closed).
pub fn scope_info(scope: &str) -> Option<ScopeInfo> {
    rules().ok()?.iter().find(|(re, _)| re.is_match(scope)).map(|(_, info)| *info)
}
