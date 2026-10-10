//! Test hooks for resource topology: reservation, patch failure and close interception points, and lifecycle probes.

use super::*;

impl Mux {
    #[cfg(test)]
    pub(crate) fn set_resource_terminal_reservation_hook_for_test(
        &self,
        hook: Option<TerminalReservationHook>,
    ) {
        *self.terminal_create_after_terminal_reservation.lock().unwrap() = hook;
    }

    #[cfg(test)]
    pub(crate) fn set_resource_patch_failure_for_test(&self, enabled: bool) {
        self.workspace_registry.lock().unwrap().set_resource_patch_failure(enabled).unwrap();
    }

    #[cfg(test)]
    pub(crate) fn set_resource_patch_failures_remaining_for_test(&self, failures: u64) {
        self.workspace_registry.lock().unwrap().set_resource_patch_failures_remaining(failures);
    }

    #[cfg(test)]
    pub(crate) fn resource_terminal_lifecycle_for_test(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<(String, Option<String>)>> {
        Ok(self.workspace_registry.lock().unwrap().terminal_record(terminal_id)?.map(|terminal| {
            (terminal_lifecycle_name(terminal.lifecycle).to_string(), terminal.incarnation)
        }))
    }
}
