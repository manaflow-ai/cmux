//! `appearance-v1` command handlers (cmux-next-ios/PROTOCOL.md "Appearance"):
//! `get-appearance` and the cmux app's `set-appearance-background`. Each
//! function is one `Command` arm of `handle_command_with_cancellation`.

use super::AppearanceBackgroundRequest;
use super::origin_gate;
use crate::Mux;
use crate::mux::appearance::AppearanceBackground;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

impl Mux {
    /// Whether `client` may read the background file's path: the verified
    /// cmux app, or this build's cmux-mobile-host on a local connection
    /// (which strips `include_path` from every phone request and serves the
    /// file itself, `appearance-asset`).
    pub(crate) fn may_read_appearance_path(&self, client: u64) -> bool {
        origin_gate::is_user(self, client)
            || (self.control_clients.is_unix(client)
                && !self.is_remote_client(client)
                && origin_gate::is_mobile_host_lane(self, client))
    }
}

/// `get-appearance {include_path?}` → `{appearance}`.
pub(super) fn get_appearance(
    mux: &Arc<Mux>,
    client: u64,
    include_path: bool,
) -> anyhow::Result<Value> {
    anyhow::ensure!(
        !include_path || mux.may_read_appearance_path(client),
        "forbidden: only the cmux app or cmux-mobile-host may read the background file path"
    );
    Ok(json!({"appearance": mux.appearance_snapshot(include_path)}))
}

/// `set-appearance-background {background}` → `{revision}`. The verified
/// cmux app only: a phone's lane, an agent or a script gets `forbidden`.
pub(super) fn set_appearance_background(
    mux: &Arc<Mux>,
    client: u64,
    background: Option<AppearanceBackgroundRequest>,
) -> anyhow::Result<Value> {
    anyhow::ensure!(
        origin_gate::is_user(mux, client),
        "forbidden: only the cmux app may set this Mac's background"
    );
    let background = background
        .map(|request| {
            AppearanceBackground::validated(
                request.path,
                request.sha256,
                request.width,
                request.height,
                request.luminance,
            )
        })
        .transpose()?;
    Ok(json!({"revision": mux.set_appearance_background(background)}))
}
