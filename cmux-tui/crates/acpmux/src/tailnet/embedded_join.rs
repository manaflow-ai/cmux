//! Join the embedded node to the person's own tailnet (a Tailscale auth key, or a Headscale key
//! and its server), with a device name and ACL tags. Off until asked: `_acpmux/tailnet/join`.
//!
//! The key is used once, to sign in: it lives in memory from the request to the node's start and
//! is never written to disk, a log, argv or settings. The node's state folder keeps its identity,
//! so a restart needs no key. What is kept is [`JoinProfile`] (`join.json`, no secret): the
//! server, name and tags the node restarts with. Nothing here touches the machine's own
//! Tailscale, its routes, an exit node or `accept-routes`: the embedded node is the app's own
//! userspace device.

use std::path::Path;

use cmux_tailnet_join::{Credential, JoinRequest, Secret};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The version of [`JoinParams`] and [`JoinProfile`] this build speaks. A newer peer's extra
/// fields are ignored; an older one's missing fields take their defaults.
pub const JOIN_VERSION: u32 = 1;

/// The file in the state folder that records the join (no secret).
pub(crate) const PROFILE_FILE: &str = "join.json";

/// `_acpmux/tailnet/join`'s params.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct JoinParams {
    pub v: u32,
    /// A Tailscale auth key (`tskey-auth-...`) or a Headscale pre-auth key. Serialized as
    /// `<redacted>`, shown as `Secret(<redacted>)`.
    pub key: Option<Secret>,
    /// A Headscale (or other) coordination server; none is Tailscale's.
    pub control_url: Option<String>,
    /// The device name; none keeps this machine's name.
    pub hostname: Option<String>,
    /// ACL tags the key's owner may use (`tag:name` or `name`).
    pub tags: Vec<String>,
    /// The node leaves the tailnet when it goes offline.
    pub ephemeral: bool,
    /// Join even though the node is signed in to a tailnet now (it signs out of that one first).
    pub switch: bool,
    /// The person allowed a plain `http://` login server for this join (the key crosses the
    /// network unencrypted). Never inferred from the address.
    pub allow_http: bool,
}

/// What a join keeps on disk, beside the node's own state: the server, name and tags the node
/// restarts with. Never a key.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct JoinProfile {
    pub v: u32,
    pub control_url: Option<String>,
    pub hostname: Option<String>,
    pub tags: Vec<String>,
    pub ephemeral: bool,
}

impl JoinProfile {
    pub fn to_json(&self) -> Value {
        json!({
            "v": JOIN_VERSION,
            "controlUrl": self.control_url,
            "hostname": self.hostname,
            "tags": self.tags,
            "ephemeral": self.ephemeral,
        })
    }
}

/// A checked join: the profile to keep and the one-time key.
#[derive(Debug)]
pub struct JoinPlan {
    pub profile: JoinProfile,
    pub key: Secret,
    pub switch: bool,
}

impl JoinParams {
    pub fn from_value(params: &Value) -> Result<Self, String> {
        // Never echo the params: they carry the key.
        serde_json::from_value(params.clone())
            .map_err(|_| "tailnet join: the params are not a join request".to_owned())
    }

    /// Checks the request with `cmux-tailnet-join`'s rules (key shape, https server, name, tags).
    pub fn plan(self) -> Result<JoinPlan, String> {
        let key = self.key.ok_or_else(|| "tailnet join: a key is required".to_owned())?;
        let checked = JoinRequest {
            credential: Credential::AuthKey { key },
            control_url: self.control_url,
            hostname: self.hostname,
            tags: self.tags,
            ssh: false,
            ephemeral: self.ephemeral,
            serve: Vec::new(),
            switch_from_other_tailnet: self.switch,
            allow_http: self.allow_http,
        }
        .check()
        .map_err(|invalid| invalid.0)?;
        let options = cmux_tailnet_join::embedded_options(&checked);
        let request = checked.request();
        Ok(JoinPlan {
            profile: JoinProfile {
                v: JOIN_VERSION,
                control_url: options.control_url,
                hostname: options.hostname,
                tags: request.tags.clone(),
                ephemeral: options.ephemeral,
            },
            key: options.auth_key,
            switch: self.switch,
        })
    }
}

/// The saved profile, if a join made one. A file that does not parse is no profile.
pub(crate) fn read_profile(state_dir: &Path) -> Option<JoinProfile> {
    let path = state_dir.join(PROFILE_FILE);
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > 64 * 1024 {
        return None;
    }
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

pub(crate) fn write_profile(state_dir: &Path, profile: &JoinProfile) -> Result<(), String> {
    crate::config::private_state_dir(state_dir).map_err(|e| e.to_string())?;
    let mut saved = profile.clone();
    saved.v = JOIN_VERSION;
    let bytes = serde_json::to_vec_pretty(&saved).map_err(|e| e.to_string())?;
    crate::config::write_atomic(&state_dir.join(PROFILE_FILE), &bytes).map_err(|e| e.to_string())
}

/// Whether the state folder holds a signed-in identity: tsnet's FileStore (`tailscaled.state`)
/// names a current login profile. Only key names are read; nothing from it is logged.
pub(crate) fn has_saved_login(state_dir: &Path) -> bool {
    let path = state_dir.join("tailscaled.state");
    let Ok(meta) = std::fs::symlink_metadata(&path) else { return false };
    if !meta.is_file() || meta.len() > 16 * 1024 * 1024 {
        return false;
    }
    let Ok(bytes) = std::fs::read(&path) else { return false };
    let Ok(Value::Object(store)) = serde_json::from_slice::<Value>(&bytes) else { return false };
    store.get("_current-profile").and_then(Value::as_str).is_some_and(|v| !v.is_empty())
}

/// The refusal for a node that is signed in to a tailnet and a join without `switch`.
pub(crate) fn other_tailnet_refusal(current: Option<&JoinProfile>) -> String {
    let server =
        current.and_then(|p| p.control_url.clone()).unwrap_or_else(|| "Tailscale".to_owned());
    format!(
        "this Mac's cmux node is already signed in to a tailnet on {server}: leave it first, or join with switch (--switch) to sign out of it and join the new one"
    )
}

#[cfg(test)]
#[path = "embedded_join_tests.rs"]
mod tests;
