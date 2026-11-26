//! Defaults that depend on the running build rather than the schema (Swift
//! `SettingsBuildDefaults`), as ops. They fill keys no layer sets, in the
//! effective root only: cmux-next.json is shared by NIGHTLY, cmux NEXT, RC and
//! stable, so a NIGHTLY default written there would become stable's value
//! too. The app keeps which build it is; which keys that fills, what its
//! children are told and what counts as customized are decided here.
//!
//! `values` is always an object of dotted keys to values.
//! - `build_defaults.channel` `{downloads_automatically?, dev_build?,
//!   installs_when_idle?}` answers `{values}`: the defaults of a build of that
//!   channel.
//! - `build_defaults.child_environment` `{values}` answers `{value?}`: the
//!   text of `CMUX_NEXT_SETTINGS_BUILD_DEFAULTS` for the build's Rust children
//!   (compact, sorted keys), absent when the build has none.
//! - `build_defaults.fill` `{root, values}` answers `{root}`: `root` with each
//!   build default whose key it leaves unset.
//! - `build_defaults.default_value` `{key, values?}` answers `{value?}`: the
//!   key's default in this build, its build default over the schema's.
//! - `build_defaults.is_unset_value` `{key, value, values?, set_below_file?}`
//!   answers `{unset}`: `value` is what the key has with no file value (this
//!   build's default, and no layer below the file sets it), so the file
//!   leaves the key out.
//! - `build_defaults.is_customized` `{key, stored?, file_root, values?,
//!   theme_file_sets?, set_below_file?}` answers `{customized}`: Settings
//!   offers Reset. `stored` is the file's value of the key (legacy names
//!   read), `theme_file_sets` says the active theme file sets the key and
//!   `set_below_file` that a layer below the file does.

use serde_json::{Map, Value, json};

use super::{OpError, string};
use crate::keypath::key_path;
use crate::render::compact;
use crate::schema::{Schema, replaced_value};
use crate::sidebar_look::GROUP_BACKGROUND;
use crate::value::value_at;

/// Automatic Updates (`UpdatesSettings.automaticPath`): Download
/// Automatically where the channel downloads by itself
/// (`UpdateTrack.downloadsAutomaticallyByDefault`), Install When Idle where
/// it installs when idle (`UpdateTrack.installsWhenIdleByDefault`).
pub const AUTOMATIC_UPDATES: &str = "updates.automatic";
/// `UpdatesAutomaticSetting.download`.
pub const DOWNLOAD: &str = "download";
/// `UpdatesAutomaticSetting.idle`.
pub const IDLE: &str = "idle";
/// iPhone pairing, on in a DEV build (`BuildStatePaths.isolatesSharedState`).
pub const ALLOW_IPHONE_CONNECTIONS: &str = "mobile.allowIPhoneConnections";

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "build_defaults.channel" => Ok(json!({ "values": channel(
            flag(request, "downloads_automatically"),
            flag(request, "dev_build"),
            flag(request, "installs_when_idle"),
        ) })),
        "build_defaults.child_environment" => values(request).map(|values| {
            child_environment(&values).map_or_else(|| json!({}), |value| json!({ "value": value }))
        }),
        "build_defaults.fill" => fill_op(request),
        "build_defaults.default_value" => default_value_op(request),
        "build_defaults.is_unset_value" => is_unset_value_op(request),
        "build_defaults.is_customized" => is_customized_op(request),
        _ => return None,
    })
}

/// The defaults of a build (Swift `SettingsBuildDefaults.channel`):
/// Automatic Updates is Install When Idle in cmux NEXT's NIGHTLY (Leo
/// 2026-11-22: "auto be de facto able to click the restart button"), else
/// Download Automatically where the channel downloads by itself (every
/// channel since Leo 2026-11-07, "Yeah, let's do that, man", which is also
/// the schema's default); iPhone pairing is on in a DEV build, whose own file
/// starts empty.
pub fn channel(
    downloads_automatically: bool,
    dev_build: bool,
    installs_when_idle: bool,
) -> Map<String, Value> {
    let mut values = Map::new();
    if installs_when_idle {
        values.insert(AUTOMATIC_UPDATES.to_owned(), Value::String(IDLE.to_owned()));
    } else if downloads_automatically {
        values.insert(AUTOMATIC_UPDATES.to_owned(), Value::String(DOWNLOAD.to_owned()));
    }
    if dev_build {
        values.insert(ALLOW_IPHONE_CONNECTIONS.to_owned(), Value::Bool(true));
    }
    values
}

/// The value of `CMUX_NEXT_SETTINGS_BUILD_DEFAULTS` for `values`: a compact
/// object with sorted keys, which `schema::build_defaults_from` reads back.
/// `None` when the build has no defaults.
pub fn child_environment(values: &Map<String, Value>) -> Option<String> {
    (!values.is_empty()).then(|| compact(&Value::Object(values.clone())))
}

/// `root` with every build default whose key it leaves unset. A key an old
/// key it replaced still answers for is not unset: the person's old pick
/// wins (`updates.downloadAutomatically: false` reads as Notify Only; Swift
/// `SettingsBuildDefaults.filling`).
pub fn fill(root: &Value, values: &Map<String, Value>) -> Value {
    values.iter().fold(root.clone(), |root, (key, value)| {
        let path = key_path(key);
        if value_at(&root, &path).is_some() || replaced_value(&path, &root).is_some() {
            root
        } else {
            super::controller::replacing(&path, Some(value.clone()), &root)
        }
    })
}

/// `key`'s default in this build: its build default, else the schema's.
pub fn default_value(key: &str, values: &Map<String, Value>) -> Option<Value> {
    values
        .get(key)
        .cloned()
        .or_else(|| Schema::embedded().row(key).and_then(|row| row.default.clone()))
}

/// Swift `JSONValue ==`: numbers compare as doubles, keys unordered.
fn same(a: Option<&Value>, b: Option<&Value>) -> bool {
    a.map(compact) == b.map(compact)
}

/// Whether the person's file sets `key` to something other than this build's
/// default (an explicit off in NIGHTLY, whose default is on, counts). A value
/// kept over the active theme file is the person's even at the default:
/// Reset returns to the file's value (#44894). An explicit sidebar group
/// style over one a layer below sets returns ownership to the sidebar look.
pub fn is_customized(
    key: &str,
    stored: Option<&Value>,
    file_root: &Value,
    values: &Map<String, Value>,
    theme_file_sets: bool,
    set_below_file: bool,
) -> bool {
    let Some(stored) = stored else { return false };
    if theme_file_sets && super::theme::exception_keys(file_root).contains(key) {
        return true;
    }
    if key == GROUP_BACKGROUND && set_below_file {
        return true;
    }
    !same(Some(stored), default_value(key, values).as_ref())
}

fn flag(request: &Value, key: &str) -> bool {
    request.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// The object `values` of `request`; absent is none.
fn values(request: &Value) -> Result<Map<String, Value>, OpError> {
    match request.get("values") {
        None | Some(Value::Null) => Ok(Map::new()),
        Some(Value::Object(values)) => Ok(values.clone()),
        Some(_) => Err(OpError::Invalid("expected an object `values`".to_owned())),
    }
}

fn fill_op(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").unwrap_or(&Value::Null);
    Ok(json!({ "root": fill(root, &values(request)?) }))
}

fn default_value_op(request: &Value) -> Result<Value, OpError> {
    Ok(match default_value(string(request, "key")?, &values(request)?) {
        Some(value) => json!({ "value": value }),
        None => json!({}),
    })
}

fn is_unset_value_op(request: &Value) -> Result<Value, OpError> {
    let default = default_value(string(request, "key")?, &values(request)?);
    let unset = same(request.get("value"), default.as_ref()) && !flag(request, "set_below_file");
    Ok(json!({ "unset": unset }))
}

fn is_customized_op(request: &Value) -> Result<Value, OpError> {
    let customized = is_customized(
        string(request, "key")?,
        request.get("stored").filter(|stored| !stored.is_null()),
        request.get("file_root").unwrap_or(&Value::Null),
        &values(request)?,
        flag(request, "theme_file_sets"),
        flag(request, "set_below_file"),
    );
    Ok(json!({ "customized": customized }))
}

#[cfg(test)]
mod tests;
