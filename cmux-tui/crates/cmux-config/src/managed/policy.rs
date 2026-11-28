//! Managed policy keys that are not cmux.json settings (Swift
//! `ManagedPreferences.policyKeys`, docs/mdm/managed-preferences.md), typed
//! for the enterprise lane.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use crate::diagnostics::{Diagnostic, DiagnosticKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyType {
    String,
    Boolean,
    Choice(&'static [&'static str]),
    StringArray(&'static [&'static str]),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PolicyKey {
    pub name: &'static str,
    pub ty: PolicyType,
    pub help: &'static str,
}

/// Every policy key, in documentation order.
pub const POLICY_KEYS: [PolicyKey; 8] = [
    PolicyKey {
        name: "EnrollmentToken",
        ty: PolicyType::String,
        help: "Team enrollment token from the cmux dashboard. Signed-in users in a verified domain of the team join it; the token alone never grants membership.",
    },
    PolicyKey {
        name: "ManagedTeam",
        ty: PolicyType::String,
        help: "Team id (team_...) that manages this device.",
    },
    PolicyKey {
        name: "RestrictToManagedTeam",
        ty: PolicyType::Boolean,
        help: "Refuse sign-in to any team other than ManagedTeam on this device.",
    },
    PolicyKey {
        name: "DisabledFeatures",
        ty: PolicyType::StringArray(&[
            "computerUse",
            "browserAutomation",
            "mcp",
            "cloud",
            "apps",
            "remoteHosts",
        ]),
        help: "Features to turn off: their UI, actions and host operations are removed.",
    },
    PolicyKey {
        name: "UpdateChannel",
        ty: PolicyType::Choice(&["stable", "nightly"]),
        help: "Update channel this device follows.",
    },
    PolicyKey {
        name: "MinimumVersion",
        ty: PolicyType::String,
        help: "Oldest cmux version allowed to sign in, for example 1.2.0.",
    },
    PolicyKey {
        name: "AllowedSignInMethods",
        ty: PolicyType::StringArray(&["sso", "password", "oauth"]),
        help: "Sign-in methods the app offers.",
    },
    PolicyKey {
        name: "DisableAutoUpdate",
        ty: PolicyType::Boolean,
        help: "Turn off automatic updates (also honored in the legacy com.cmuxterm.app domain).",
    },
];

/// Keys whose values never leave the owner except through `policy` reads
/// (the cold-start cache and status output show them as present only).
pub const SECRET_POLICY_KEYS: [&str; 1] = ["EnrollmentToken"];

/// Forced policy values, typed. A value of the wrong type is `None` here
/// (with a diagnostic); `raw` keeps every forced policy key as written.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Policy {
    pub enrollment_token: Option<String>,
    pub managed_team: Option<String>,
    pub restrict_to_managed_team: Option<bool>,
    pub disabled_features: Option<Vec<String>>,
    pub update_channel: Option<String>,
    pub minimum_version: Option<String>,
    pub allowed_sign_in_methods: Option<Vec<String>>,
    pub disable_auto_update: Option<bool>,
    pub raw: BTreeMap<String, Value>,
}

impl Policy {
    /// Types `raw` (forced, non-setting keys) and reports wrong types.
    pub fn from_raw(raw: BTreeMap<String, Value>, diagnostics: &mut Vec<Diagnostic>) -> Policy {
        let mut check = |name: &str| -> Option<Value> {
            let value = raw.get(name)?;
            let key = POLICY_KEYS.iter().find(|key| key.name == name)?;
            if type_ok(key.ty, value) {
                return Some(value.clone());
            }
            diagnostics.push(Diagnostic::new(
                DiagnosticKind::InvalidValue,
                name,
                "wrong type for this policy key",
            ));
            None
        };
        let string = |value: Option<Value>| -> Option<String> {
            value.and_then(|v| v.as_str().map(str::to_string))
        };
        let boolean = |value: Option<Value>| -> Option<bool> { value.and_then(|v| v.as_bool()) };
        let strings = |value: Option<Value>| -> Option<Vec<String>> {
            value.and_then(|v| {
                v.as_array().map(|items| {
                    items.iter().filter_map(|i| i.as_str().map(str::to_string)).collect()
                })
            })
        };
        Policy {
            enrollment_token: string(check("EnrollmentToken"))
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty()),
            managed_team: string(check("ManagedTeam")),
            restrict_to_managed_team: boolean(check("RestrictToManagedTeam")),
            disabled_features: strings(check("DisabledFeatures")),
            update_channel: string(check("UpdateChannel")),
            minimum_version: string(check("MinimumVersion")),
            allowed_sign_in_methods: strings(check("AllowedSignInMethods")),
            disable_auto_update: boolean(check("DisableAutoUpdate")),
            raw,
        }
    }

    /// Whether the policy turns `feature` off.
    pub fn disables(&self, feature: &str) -> bool {
        self.disabled_features
            .as_ref()
            .is_some_and(|features| features.iter().any(|f| f == feature))
    }

    /// Every forced policy key with its value. `redact_secrets` shows secret
    /// values as `"<set>"` (files on disk).
    pub fn to_json(&self, redact_secrets: bool) -> Value {
        let mut members = Map::new();
        for (key, value) in &self.raw {
            let shown = if redact_secrets && SECRET_POLICY_KEYS.contains(&key.as_str()) {
                json!("<set>")
            } else {
                value.clone()
            };
            members.insert(key.clone(), shown);
        }
        Value::Object(members)
    }
}

/// Unknown entries in a string array are kept (a newer feature name an
/// older build does not know), so only the shapes are checked.
fn type_ok(ty: PolicyType, value: &Value) -> bool {
    match ty {
        PolicyType::String => value.is_string(),
        PolicyType::Boolean => value.is_boolean(),
        PolicyType::Choice(choices) => value.as_str().is_some_and(|text| choices.contains(&text)),
        PolicyType::StringArray(_) => {
            value.as_array().is_some_and(|items| items.iter().all(Value::is_string))
        }
    }
}
