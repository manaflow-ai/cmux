//! The `chief_settings` area: the Chief's settings snapshot the Mac card, and any other platform's,
//! renders. Each op is a stateless rule the Swift app used to hold:
//!
//! - [`names`]: the names a person reads for harness and model ids (`ChiefNames.swift`) and the official
//!   engines (`ChiefBackend.swift`, `HomeChiefSettingsView.harnessItems`).
//! - [`model_menu`]: the Model popup (`HomeChiefModelMenu.swift`).
//! - [`engine`]: the pickers' Default titles (`HomeChiefEngineTitles.swift`), the engine errors
//!   (`HomeChiefEngineError.swift`), the hosted brain's route (`HomeChiefHostedEngine.swift`), each Chief's
//!   harness (`HomeChiefHarnesses.swift`), recent picks (`HomeChiefModelRecents.swift`) and the snapshot's
//!   files (`HomeChiefFiles.swift`: engine.json, the offered report, the CodeRouter route).
//! - [`chief_names`]: renames being saved (`HomeChiefNames.swift`), rename failures
//!   (`HomeChiefRenameFailure.swift`) and the chief conversation's name (`HomeChiefName.swift`).
//! - [`picture`]: the picture crop (`HomeChiefPictureCrop.swift`), the registry's media types
//!   (`HomeChiefAvatars.swift`, `ChiefAvatarPicture.swift`) and the picture file rules (`HomeChiefFiles.swift`).
//! - [`computer`]: the computer section's and control bar's decisions (`HomeChiefComputerSection.swift`,
//!   `HomeChiefComputerControlBar.swift`).
//!
//! Every text a person reads comes from the request's optional `strings` ([`Strings`]): the app passes
//! its localized words, and a request without them reads in English.

pub mod chief_names;
pub mod computer;
pub mod engine;
pub mod model_menu;
pub mod names;
pub mod picture;

use crate::ops::OpError;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// This area's op names (without the `chief_settings.` prefix).
pub const OPS: &[&str] = &[
    // names
    "harnessName",
    "modelName",
    "backends",
    "backendTitle",
    "backendBadge",
    "harnessItems",
    // model menu
    "modelMenu",
    "modelRelease",
    "modelDisplayName",
    // engine
    "engineTitles",
    "defaultTitled",
    "engineError",
    "hostedOffer",
    "hostedPatch",
    "hostedConfig",
    "hostedSnapshot",
    "harnesses",
    "recentsRemember",
    "engineChoice",
    "snapshotOffering",
    "routeConfigured",
    // chief names
    "namesStep",
    "namesOf",
    "namesAll",
    "localRecords",
    "localRename",
    "renameFailure",
    "conversationRenameFailure",
    "nextName",
    "titleMigration",
    "selectChief",
    // picture
    "cropStep",
    "cropRender",
    "registryMediaType",
    "pictureExtension",
    "pictureFileName",
    "namesPicture",
    "pathKey",
    "squareCrop",
    "squaredCacheName",
    // computer
    "controlLine",
    "computerSection",
    "computerNote",
    "computerPoll",
];

/// Runs `chief_settings.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "harnessName" | "modelName" | "backends" | "backendTitle" | "backendBadge"
        | "harnessItems" => names::call(name, request),
        "modelMenu" | "modelRelease" | "modelDisplayName" => model_menu::call(name, request),
        "engineTitles" | "defaultTitled" | "engineError" | "hostedOffer" | "hostedPatch"
        | "hostedConfig" | "hostedSnapshot" | "harnesses" | "recentsRemember" | "engineChoice"
        | "snapshotOffering" | "routeConfigured" => engine::call(name, request),
        "namesStep"
        | "namesOf"
        | "namesAll"
        | "localRecords"
        | "localRename"
        | "renameFailure"
        | "conversationRenameFailure"
        | "nextName"
        | "titleMigration"
        | "selectChief" => chief_names::call(name, request),
        "cropStep" | "cropRender" | "registryMediaType" | "pictureExtension"
        | "pictureFileName" | "namesPicture" | "pathKey" | "squareCrop" | "squaredCacheName" => {
            picture::call(name, request)
        }
        "controlLine" | "computerSection" | "computerNote" | "computerPoll" => {
            computer::call(name, request)
        }
        _ => Err(OpError::Unknown),
    }
}

/// The words the rules put in titles, as the app localizes them (`HomeEngineStrings`, `HomeStrings`,
/// `ChiefBackend.title`). Every field defaults to the English the Swift strings default to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Strings {
    /// `home.engine.models.recent`.
    pub recent_section: String,
    /// `home.engine.models.planAndExecute`.
    pub plan_and_execute_section: String,
    /// `home.engine.models.other`.
    pub other_models_section: String,
    /// `home.engine.models.older`.
    pub older_models_section: String,
    /// `home.engine.models.opusPlan`.
    pub opus_plan_title: String,
    /// `home.engine.models.contextVariant` (`%1$@ · %2$@ context`: the model, the window).
    pub context_variant_format: String,
    /// `home.engine.default`.
    pub default_value: String,
    /// `home.engine.defaultNamed` (`Default (%@)`).
    pub default_named_format: String,
    /// Effort titles by effort id (`home.engine.effort.*`), over the English ones.
    pub efforts: BTreeMap<String, String>,
    /// Official engine titles by harness id (`home.chief.backend.*`), over the English ones.
    pub backends: BTreeMap<String, String>,
    /// Official engine hints by harness id (`home.chief.backend.*Hint`), over the English ones.
    pub hints: BTreeMap<String, String>,
    /// `HomeStrings.chiefName` (the chief conversation's name, N1).
    pub chief_name: String,
    /// `HomeStrings.title` (Home's localized title, an old default chief title).
    pub home_title: String,
}

impl Default for Strings {
    fn default() -> Self {
        Strings {
            recent_section: "Recent".into(),
            plan_and_execute_section: "Plan and Execute".into(),
            other_models_section: "Other Models".into(),
            older_models_section: "Older Models".into(),
            opus_plan_title: "Opus Plans, Sonnet Executes".into(),
            context_variant_format: "%1$@ · %2$@ context".into(),
            default_value: "Default".into(),
            default_named_format: "Default (%@)".into(),
            efforts: BTreeMap::new(),
            backends: BTreeMap::new(),
            hints: BTreeMap::new(),
            chief_name: "Chief".into(),
            home_title: "Home".into(),
        }
    }
}

impl Strings {
    /// An effort level's name; one the app does not know shows as the brain names it.
    pub fn effort_title(&self, id: &str) -> String {
        if let Some(title) = self.efforts.get(id) {
            return title.clone();
        }
        match id {
            "off" => "Off",
            "minimal" => "Minimal",
            "low" => "Low",
            "medium" => "Medium",
            "high" => "High",
            "xhigh" => "Extra High",
            "max" => "Max",
            other => other,
        }
        .to_owned()
    }
}

/// The request's `strings` (English when absent or not an object of strings).
pub(crate) fn strings(request: &Value) -> Strings {
    request.get("strings").and_then(|value| Strings::deserialize(value).ok()).unwrap_or_default()
}

/// Foundation's `String(format:)` for `%@` arguments: `%@` takes the next argument, `%N$@` the Nth,
/// `%%` is a percent sign.
pub fn format(template: &str, args: &[&str]) -> String {
    let mut out = String::new();
    let mut next = 0;
    let chars: Vec<char> = template.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] != '%' {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        if chars.get(i + 1) == Some(&'%') {
            out.push('%');
            i += 2;
            continue;
        }
        if chars.get(i + 1) == Some(&'@') {
            out.push_str(args.get(next).copied().unwrap_or(""));
            next += 1;
            i += 2;
            continue;
        }
        // %N$@
        let mut j = i + 1;
        while j < chars.len() && chars[j].is_ascii_digit() {
            j += 1;
        }
        if j > i + 1 && chars.get(j) == Some(&'$') && chars.get(j + 1) == Some(&'@') {
            let digits: String = chars[i + 1..j].iter().collect();
            let index = digits.parse::<usize>().unwrap_or(0);
            out.push_str(index.checked_sub(1).and_then(|n| args.get(n)).copied().unwrap_or(""));
            i = j + 2;
            continue;
        }
        out.push('%');
        i += 1;
    }
    out
}

/// Swift's `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub(crate) fn trim(text: &str) -> &str {
    text.trim()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_fills_positional_and_sequential_arguments() {
        assert_eq!(format("%1$@ · %2$@ context", &["Opus 5.5", "1M"]), "Opus 5.5 · 1M context");
        assert_eq!(format("%2$@ / %1$@", &["a", "b"]), "b / a");
        assert_eq!(format("Default (%@)", &["Claude"]), "Default (Claude)");
        assert_eq!(format("100%% %@", &["x"]), "100% x");
    }

    #[test]
    fn every_op_routes() {
        for op in OPS {
            assert_ne!(call(op, &Value::Null), Err(OpError::Unknown), "{op}");
        }
    }
}
