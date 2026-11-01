//! Capture startup authority before terminal exec; attach entries after the mux.
use std::path::Path;
use std::sync::Arc;

use cmux_tui_core::Mux;

pub(crate) struct DaemonEntryStartup {
    #[cfg(target_os = "linux")]
    root: Option<cmux_link::root_bootstrap::Daemon>,
}

impl DaemonEntryStartup {
    pub(crate) fn capture() -> Self {
        #[cfg(target_os = "linux")]
        let root = match cmux_link::root_bootstrap::Daemon::from_stdin() {
            Ok(bootstrap) => bootstrap,
            Err(error) => {
                eprintln!("cmux: root bootstrap unavailable: {error}");
                None
            }
        };
        Self {
            #[cfg(target_os = "linux")]
            root,
        }
    }

    pub(crate) fn start_entry(
        &mut self,
        enabled: bool,
        mux: &Arc<Mux>,
        session: &Path,
    ) -> anyhow::Result<Option<cmux_tui_core::server::RemoteEntryServer>> {
        #[cfg(target_os = "linux")]
        if super::native_supervision::attach_native_receiver(
            self.root.as_mut(),
            enabled,
            mux,
            session,
        )? {
            return Ok(None);
        }
        super::start_link_entry(enabled, mux, session)
    }
}
