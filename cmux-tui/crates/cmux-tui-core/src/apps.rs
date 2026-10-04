//! App supervisor (`apps-v1`, plans/cmux-next/app-platform.md section 13).
//!
//! Owns, per machine: the install mirror (`apps.json` in the daemon state
//! dir, V9 fields) until `UserDO` installs sync down, grants and their tier
//! rules, the per-call scope check (`cmux-app-host/generated/scopes.json`),
//! per-app KV storage (SQLite), the `net.fetch` egress gate, gesture tokens,
//! and one sandboxed `cmux-app-host` process per running app. App calls run
//! through the daemon's own dispatcher. Clients only mirror installs and
//! scene streams; no engine, registry or grant logic lives in a client.
//!
//! Daemon commands (JSON lines like every v12 command; `server/apps.rs`):
//! `apps-list`, `apps-set`, `apps-mount`, `apps-unmount`, `apps-dispatch`,
//! `apps-run`, `apps-logs`; events `apps-changed`, `apps-host`,
//! `apps-scene`, `apps-mount-failed`, `apps-log`, `request-settled`.

// The app host is a Unix process with an OS sandbox; other platforms
// advertise no `apps-v1` and answer `apps-*` with `apps.unavailable`.
#[cfg(unix)]
mod actions;
#[cfg(unix)]
mod calls;
#[cfg(unix)]
mod catalog;
#[cfg(unix)]
mod egress;
#[cfg(unix)]
mod grants;
#[cfg(unix)]
mod host;
#[cfg(unix)]
mod hosts;
#[cfg(unix)]
mod mirror;
#[cfg(all(test, unix))]
mod mirror_tests;
#[cfg(unix)]
mod provider;
#[cfg(unix)]
mod routing;
#[cfg(unix)]
mod runs;
#[cfg(unix)]
mod servers;
#[cfg(unix)]
mod storage;
#[cfg(unix)]
mod supervisor;
#[cfg(all(test, unix))]
mod supervisor_tests;
#[cfg(unix)]
mod terminal_links;
#[cfg(unix)]
mod terminal_ops;
#[cfg(unix)]
mod timer;

use std::sync::{Arc, OnceLock};

#[cfg(unix)]
pub(crate) use mirror::{HiddenAccess, Origin, SetOp};
#[cfg(unix)]
pub(crate) use provider::{ProviderClaim, admit_origin};
#[cfg(unix)]
pub(crate) use runs::RunRequest;
#[cfg(unix)]
pub(crate) use supervisor::{ApiError, Supervisor};

/// The capability string; advertised only when the app host binary exists.
pub const CAPABILITY: &str = "apps-v1";

/// The supervisor of one daemon, created on the first `apps-*` command.
#[derive(Default)]
pub(crate) struct AppsSlot {
    #[cfg(unix)]
    supervisor: OnceLock<Arc<Supervisor>>,
    #[cfg(not(unix))]
    supervisor: OnceLock<Arc<()>>,
}

impl AppsSlot {
    #[cfg(unix)]
    pub(crate) fn get_or_init(&self, mux: &Arc<crate::Mux>) -> Arc<Supervisor> {
        self.supervisor
            .get_or_init(|| {
                let state_dir = mux.session_state_directory();
                let idle = std::env::var("CMUX_APPS_IDLE_STOP_SECONDS")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(60);
                Supervisor::new(
                    supervisor::Config {
                        sources: catalog::Sources::from_env(state_dir.as_deref()),
                        state_dir,
                        host_binary: host::resolve_binary(),
                        host_args: Vec::new(),
                        server_dir: host::resolve_server_dir(),
                        idle_stop: std::time::Duration::from_secs(idle),
                        provider_deadline: std::time::Duration::from_secs(30),
                        provider_user_deadline: std::time::Duration::from_secs(600),
                    },
                    Box::new(routing::MuxRouter::new(mux)),
                    Box::new(egress::HttpFetcher),
                )
            })
            .clone()
    }

    pub(crate) fn disconnect(&self, client: u64) {
        #[cfg(unix)]
        if let Some(supervisor) = self.supervisor.get() {
            supervisor.disconnect(client);
        }
        #[cfg(not(unix))]
        let _ = (client, &self.supervisor);
    }
}

/// The capability to advertise, if this build can run apps here.
pub(crate) fn advertised() -> Option<&'static str> {
    #[cfg(unix)]
    {
        host::resolve_binary().map(|_| CAPABILITY)
    }
    #[cfg(not(unix))]
    {
        None
    }
}
