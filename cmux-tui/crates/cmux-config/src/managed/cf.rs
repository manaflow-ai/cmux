//! macOS managed preferences through CFPreferences (what MDM profiles feed;
//! cfprefsd merges the device and user channels). Only keys the published
//! schema lists are honored. Forced versus recommended comes from
//! `CFPreferencesAppValueIsForced` (Swift `CFManagedPreferenceReader`).

use std::path::PathBuf;

use core_foundation::base::{CFType, TCFType};
use core_foundation::propertylist::create_data;
use core_foundation::string::CFString;
use core_foundation_sys::preferences::{
    CFPreferencesAppSynchronize, CFPreferencesAppValueIsForced, CFPreferencesCopyAppValue,
};
use core_foundation_sys::propertylist::kCFPropertyListXMLFormat_v1_0;
use serde_json::Value;

use super::{
    DOMAIN, LEGACY_DOMAIN, LEGACY_KEYS, ManagedPreferences, ManagedReader, json_from_plist,
    published_keys,
};
use crate::schema::Schema;

#[derive(Debug, Clone)]
pub struct CfManagedReader {
    pub domain: String,
    pub keys: Vec<String>,
}

impl CfManagedReader {
    /// The `com.manaflow.cmux` domain with every published key.
    pub fn new(schema: &Schema) -> CfManagedReader {
        CfManagedReader { domain: DOMAIN.to_string(), keys: published_keys(schema) }
    }
}

impl ManagedReader for CfManagedReader {
    fn read(&self) -> ManagedPreferences {
        let mut result = ManagedPreferences::default();
        let app = CFString::new(&self.domain);
        // SAFETY: `app` is a valid CFString for the duration of the call.
        unsafe { CFPreferencesAppSynchronize(app.as_concrete_TypeRef()) };
        for key in &self.keys {
            let Some((value, forced)) = copy_value(key, &app) else { continue };
            if forced {
                result.forced.insert(key.clone(), value);
            } else {
                result.recommended.insert(key.clone(), value);
            }
        }
        let legacy = CFString::new(LEGACY_DOMAIN);
        // SAFETY: `legacy` is a valid CFString for the duration of the call.
        unsafe { CFPreferencesAppSynchronize(legacy.as_concrete_TypeRef()) };
        for key in LEGACY_KEYS {
            if result.forced.contains_key(key) {
                continue;
            }
            // The legacy domain is the app's own domain, so only forced values count.
            if let Some((value, true)) = copy_value(key, &legacy) {
                result.forced.insert(key.to_string(), value);
            }
        }
        result
    }

    /// Files whose changes mean a profile was installed or removed (wake-up
    /// hints only; macOS documents no notification for that).
    fn watch_paths(&self) -> Vec<PathBuf> {
        let root = PathBuf::from("/Library/Managed Preferences");
        let user = std::env::var("USER").unwrap_or_default();
        let mut paths = Vec::new();
        for domain in [self.domain.as_str(), LEGACY_DOMAIN] {
            let file = format!("{domain}.plist");
            paths.push(root.join(&file));
            if !user.is_empty() {
                paths.push(root.join(&user).join(&file));
            }
        }
        paths
    }
}

/// The value of `key` in `app` as JSON and whether it is forced.
fn copy_value(key: &str, app: &CFString) -> Option<(Value, bool)> {
    let cf_key = CFString::new(key);
    // SAFETY: both strings are valid; the result follows the create rule.
    let raw = unsafe {
        CFPreferencesCopyAppValue(cf_key.as_concrete_TypeRef(), app.as_concrete_TypeRef())
    };
    if raw.is_null() {
        return None;
    }
    // SAFETY: `raw` is a non-null owned CF object (create rule).
    let owned = unsafe { CFType::wrap_under_create_rule(raw) };
    let data = create_data(owned.as_CFTypeRef(), kCFPropertyListXMLFormat_v1_0).ok()?;
    let plist = plist::Value::from_reader_xml(data.bytes()).ok()?;
    let value = json_from_plist(&plist)?;
    // SAFETY: both strings are valid for the duration of the call.
    let forced = unsafe {
        CFPreferencesAppValueIsForced(cf_key.as_concrete_TypeRef(), app.as_concrete_TypeRef())
    } != 0;
    Some((value, forced))
}
