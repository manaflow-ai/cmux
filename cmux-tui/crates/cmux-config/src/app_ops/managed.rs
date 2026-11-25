//! The managed-preferences manifest and docs: Swift `ManagedPreferencesManifest`.
//!
//! - `managed.manifest` `{}` answers `{files: [{name, text}]}`: the five published
//!   files of docs/mdm (ProfileManifests plist, Jamf JSON, example mobileconfig,
//!   Intune plist and the markdown), byte for byte.

use serde_json::{Value, json};

use super::OpError;
use crate::managed::manifest;
use crate::schema::Schema;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, _request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "managed.manifest" => Ok(manifest_files()),
        _ => return None,
    })
}

fn manifest_files() -> Value {
    let files: Vec<Value> = manifest::files(Schema::embedded())
        .into_iter()
        .map(|(name, text)| json!({ "name": name, "text": text }))
        .collect();
    json!({ "files": files })
}
