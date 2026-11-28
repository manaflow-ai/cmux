//! Who builds the `identify` reply (goals/dev-loop-ceiling.md, idea c).
//!
//! The reply's body lives in the cmux-tui binary crate
//! (`cmux-tui/src/bin/cmux-tui/identify.rs`), a leaf that nothing else depends
//! on: the binary installs it at start (`install_identify`), so an edit to the
//! daemon's identity reply recompiles that small crate and the link, not this
//! crate (~657k lines) and the cmux-tui library (~521k lines) after it.
//! A process whose entry point is not that binary (this crate's and cmux-tui's
//! tests, the Windows `cmux_tui.dll`, the hot-patch binary) compiles the same
//! file into this crate instead (`bundled-identify`), so there is one copy of
//! the reply and every build serves it.
//!
//! `parts` is what the reply reads from the daemon, named here so the leaf
//! reaches nothing private.

use std::sync::{Arc, OnceLock};

use serde_json::Value;

use crate::Mux;

/// The `identify` reply: `(mux, machine_metadata, revisions)`.
pub type IdentifyFn = fn(&Arc<Mux>, bool, bool) -> anyhow::Result<Value>;

static IDENTIFY: OnceLock<IdentifyFn> = OnceLock::new();

/// Records the process's `identify` reply. The first call wins.
pub fn install_identify(identify: IdentifyFn) {
    let _ = IDENTIFY.set(identify);
}

#[cfg(any(test, feature = "bundled-identify"))]
#[path = "../../../cmux-tui/src/bin/cmux-tui/identify.rs"]
mod bundled;

pub(super) fn identify(
    mux: &Arc<Mux>,
    machine_metadata: bool,
    revisions: bool,
) -> anyhow::Result<Value> {
    if let Some(identify) = IDENTIFY.get() {
        return identify(mux, machine_metadata, revisions);
    }
    #[cfg(any(test, feature = "bundled-identify"))]
    return bundled::identify(mux, machine_metadata, revisions);
    #[cfg(not(any(test, feature = "bundled-identify")))]
    anyhow::bail!(
        "this daemon has no identify reply: its entry point never called \
         cmux_tui_core::server::install_identify (cmux-tui/src/bin/cmux-tui.rs does)"
    )
}

/// What the `identify` reply reads from the daemon.
#[doc(hidden)]
pub mod parts {
    use std::sync::Arc;

    use serde_json::{Value, json};

    use crate::Mux;

    pub use crate::panic_free::JsonFields;
    pub use crate::release::{InstallChannel, distribution_version};
    pub use crate::server::PROTOCOL_VERSION;

    /// `(build_id, cli_path)`; both `None` when the entry point installed no build.
    pub fn build_fields() -> (Option<String>, Option<String>) {
        super::super::daemon_build::identify_build_fields()
    }

    pub fn build_commit() -> Option<&'static str> {
        super::super::daemon_build::stamped_build_commit()
    }

    pub fn build_time() -> Option<u64> {
        super::super::daemon_build::stamped_build_time()
    }

    pub fn ghostty_commit() -> Option<&'static str> {
        super::super::daemon_build::stamped_ghostty_commit()
    }

    pub fn capabilities(mux: &Mux) -> Vec<&'static str> {
        super::super::identify_capabilities(mux)
    }

    /// `(api_revision, min_api_revision)`.
    pub fn api_revisions() -> (u32, u32) {
        super::super::api_revision_wire::identify_fields()
    }

    /// `(api_version, min_api_version)`.
    pub fn api_versions() -> (Option<&'static str>, Option<&'static str>) {
        super::super::api_revision_wire::identify_versions()
    }

    pub fn machine_name() -> String {
        crate::machine_name::machine_name()
    }

    pub fn machine_platform() -> Value {
        crate::resource_api::machine_platform()
    }

    pub fn machine_capabilities() -> Value {
        crate::resource_api::machine_capabilities()
    }

    pub fn machine_id(mux: &Arc<Mux>) -> Value {
        json!(mux.machine_public_id)
    }

    pub fn session_resource_id(mux: &Arc<Mux>) -> Value {
        json!(mux.session_public_id)
    }

    pub fn screen_device_id(mux: &Arc<Mux>) -> Option<String> {
        mux.control_clients.remote_host.screen_device_id()
    }
}
