//! The daemon's `identify` reply (the `identify` command and the native
//! owner's handshake). It lives in the cmux-tui binary crate, a leaf, so an edit
//! here rebuilds this small crate and the link, not cmux-tui-core and the
//! cmux-tui library (goals/dev-loop-ceiling.md); `src/bin/cmux-tui.rs` installs
//! it at start. cmux-tui-core compiles this same file for processes that do not
//! start there (`server/identify_reply.rs`, `bundled-identify`), so write every
//! path as `cmux_tui_core::...`.

use std::sync::Arc;

use cmux_tui_core::Mux;
use cmux_tui_core::server::identify_reply::parts::{self, JsonFields};
use serde_json::{Value, json};

pub(crate) fn identify(
    mux: &Arc<Mux>,
    machine_metadata: bool,
    revisions: bool,
) -> anyhow::Result<Value> {
    let (registry_id, generation) = mux.registry_identity();
    let (build_id, cli_path) = parts::build_fields();
    let mut identity = json!({
        "app": "cmux-tui",
        // The npm/PyPI release (the crate version in the app and local builds).
        "version": parts::distribution_version(),
        "build_commit": parts::build_commit(),
        "build_id": build_id,
        "cli_path": cli_path,
        "ghostty_commit": parts::ghostty_commit(),
        "protocol": parts::PROTOCOL_VERSION,
        "capabilities": parts::capabilities(mux),
        "session": mux.session,
        "pid": std::process::id(),
        "session_id": registry_id,
        "machine_name": parts::machine_name(),
        "registry_id": registry_id,
        "generation": generation,
        "workspace_revision": mux.with_state(|state| state.workspace_revision),
        "terminal_revision": mux.terminal_registry_revision()?,
        "daemon_handoff": 1,
        "lifecycle_ready": mux.server_lifecycle_ready(),
        "launch_snapshot_path": mux.launch_snapshot_path(),
    });
    // NEXT Cloud daemons are long-lived across app launches.  Include the
    // backend origin they were started with so a later client can detect a
    // staging/prod switch before it attaches to the old daemon.  Classic
    // daemons intentionally omit this field and keep their existing behavior.
    if revisions
        && std::env::var("CMUX_NEXT_CLOUD_RUNTIME").as_deref() == Ok("1")
        && let Some(backend) = std::env::var_os("CMUX_NEXT_CLOUD_BACKEND")
            .or_else(|| std::env::var_os("CMUX_NEXT_CLOUD_ENV"))
            .and_then(|value| value.into_string().ok())
            .filter(|value| !value.trim().is_empty())
    {
        identity.insert("cloud_backend", json!(backend));
    }
    // Opt-in like machine metadata: strict pre-revision SDKs decode the
    // default reply with deny_unknown_fields (machine_identity_reader_tests.rs).
    if revisions {
        let (current, base) = parts::api_revisions();
        let channel = parts::InstallChannel::current();
        identity.insert("api_revision", json!(current));
        identity.insert("min_api_revision", json!(base));
        let (version, oldest) = parts::api_versions();
        identity.insert("api_version", json!(version));
        identity.insert("min_api_version", json!(oldest));
        // cmux-tui-core's version: the workspace's, which this crate shares.
        identity.insert("crate_version", json!(env!("CARGO_PKG_VERSION")));
        // How this daemon was installed and how to update it, for a client's refusal text.
        identity.insert("install", json!(channel.as_str()));
        identity.insert("update_command", json!(channel.update_command()));
        // The source commit's time, so a client that updates this machine
        // never moves it back to an older build (`link machine update --if-older`).
        identity.insert("build_time", json!(parts::build_time()));
    }
    if machine_metadata {
        identity.insert("machine_id", parts::machine_id(mux));
        identity.insert("session_resource_id", parts::session_resource_id(mux));
        identity.insert("machine_platform", parts::machine_platform());
        // What kind of device this machine is and the SF Symbol that kind draws
        // (`cmux-device-kind`): the sidebar's machine header, hover card and remote headers
        // draw the symbol by this name.
        let device = cmux_device_kind::this_device().kind;
        identity.insert("machine_device", json!(device.as_str()));
        identity.insert("machine_symbol", json!(device.symbol()));
        identity.insert("machine_capabilities", parts::machine_capabilities());
        // The worker's independently generated screen UUID is intentionally
        // separate from the daemon machine ID. It is read only from the
        // authenticated local supervisor cache and omitted from legacy
        // identify replies.
        identity.insert("screen_device_id", json!(parts::screen_device_id(mux)));
    }
    Ok(identity)
}
