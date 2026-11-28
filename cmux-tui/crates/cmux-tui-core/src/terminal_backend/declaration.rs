//! What an app's manifest declares for a terminal interface.

use serde_json::Value;

use super::{BackendError, LocalId, check_kinds};

/// One `implements` entry of a terminal interface, run by the app's server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Declaration {
    /// `options.kinds`: the kinds this app serves; any other is denied.
    pub kinds: Vec<LocalId>,
    /// `options.openOps`: the app's catalog ops whose user runs may open a
    /// link or terminal; a token minted for any other op is denied.
    pub open_ops: Vec<String>,
}

impl Declaration {
    /// The declaration of `interface` in `manifest`. `denied` when the app
    /// does not implement it with its server, `invalid` when the options are
    /// malformed (the manifest validator refuses those at install already).
    pub(crate) fn from_manifest(manifest: &Value, interface: &str) -> Result<Self, BackendError> {
        let entry = manifest
            .get("implements")
            .and_then(|implements| implements.get(interface))
            .filter(|entry| entry.get("server") == Some(&Value::Bool(true)))
            .ok_or_else(|| {
                BackendError::denied(format!(
                    "the app does not implement {interface} with its server"
                ))
            })?;
        let strings = |key: &str| -> Vec<&str> {
            entry
                .pointer(&format!("/options/{key}"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect()
        };
        let kinds =
            strings("kinds").into_iter().map(LocalId::new).collect::<Result<Vec<_>, _>>()?;
        check_kinds(&kinds)?;
        let open_ops: Vec<String> = strings("openOps").into_iter().map(str::to_owned).collect();
        if open_ops.is_empty() {
            return Err(BackendError::invalid(format!("{interface} declares no options.openOps")));
        }
        Ok(Self { kinds, open_ops })
    }
}
