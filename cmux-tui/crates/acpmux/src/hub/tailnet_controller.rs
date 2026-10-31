//! The embedded tailnet controller, made on first use. Part of `Hub`; see `hub/mod.rs`.

use super::*;

impl Hub {
    #[cfg(all(unix, feature = "tailnet"))]
    pub(crate) fn tailnet_controller(&self) -> Arc<crate::tailnet::embedded::Controller> {
        self.tailnet_controller
            .get_or_init(|| {
                crate::tailnet::embedded::Controller::new(
                    crate::tailnet::embedded::state_dir(&crate::config::home()),
                    crate::hand::pair::hostname(),
                )
            })
            .clone()
    }
}
