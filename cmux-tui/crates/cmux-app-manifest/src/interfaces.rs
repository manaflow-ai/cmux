//! Interfaces this cmux version knows, with the options schema each one
//! accepts (`cmux-app-host/interfaces/<name>/<major>.json`).

use serde_json::Value;
use std::sync::OnceLock;

macro_rules! interfaces {
    ($($name:literal => $dir:literal),* $(,)?) => {
        /// Interface names this cmux version knows.
        pub const KNOWN_INTERFACES: &[&str] = &[$($name),*];
        const FILES: &[(&str, &str)] = &[
            $(($name, include_str!(concat!("../../cmux-app-host/interfaces/", $dir, "/1.json")))),*
        ];
    };
}

interfaces! {
    "cmux.contact.provider/1" => "cmux.contact.provider",
    "cmux.credential.provider/1" => "cmux.credential.provider",
    "cmux.diff.renderer/1" => "cmux.diff.renderer",
    "cmux.diff.source/1" => "cmux.diff.source",
    "cmux.editor/1" => "cmux.editor",
    "cmux.feed.source/1" => "cmux.feed.source",
    "cmux.fs.provider/1" => "cmux.fs.provider",
    "cmux.opener/1" => "cmux.opener",
    "cmux.palette.scope/1" => "cmux.palette.scope",
    "cmux.pane/1" => "cmux.pane",
    "cmux.search.provider/1" => "cmux.search.provider",
    "cmux.section/1" => "cmux.section",
    "cmux.status/1" => "cmux.status",
    "cmux.viewer/1" => "cmux.viewer",
}

/// Host capabilities this cmux version provides (`requires.hostCapabilities`;
/// plans/cmux-next/app-platform.md 14.4).
pub const KNOWN_HOST_CAPABILITIES: &[&str] = &["power.assertion/1"];

/// The compiled options schema of each known interface; `None` when the
/// interface takes no options.
fn option_validators() -> &'static Vec<(&'static str, Option<jsonschema::Validator>)> {
    static V: OnceLock<Vec<(&'static str, Option<jsonschema::Validator>)>> = OnceLock::new();
    V.get_or_init(|| {
        FILES
            .iter()
            .map(|(name, raw)| {
                let file: Value = serde_json::from_str(raw).expect("interface file is JSON");
                let validator = file.get("options").map(|schema| {
                    jsonschema::draft202012::new(schema).expect("interface options schema compiles")
                });
                (*name, validator)
            })
            .collect()
    })
}

/// Problems with `options` for `interface`, as (pointer under options, message).
/// An interface without an options schema accepts no options.
pub(crate) fn option_errors(interface: &str, options: &Value) -> Vec<(String, String)> {
    let Some((_, validator)) = option_validators().iter().find(|(n, _)| *n == interface) else {
        return Vec::new();
    };
    match validator {
        Some(v) => {
            v.iter_errors(options).map(|e| (e.instance_path.to_string(), e.to_string())).collect()
        }
        None => vec![(String::new(), format!("{interface} takes no options"))],
    }
}
