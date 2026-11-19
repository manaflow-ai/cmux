//! Read-only remote catalog projection. The local snapshot and all session
//! effects stay with the native owner; a published record is never a dial.

use super::{LocalResourceMachineService, ResourceError, ResourceSelectors, Selector};
use serde_json::Value;

impl LocalResourceMachineService {
    pub(super) fn remote_machine_snapshots(&self) -> Vec<Value> {
        self.remote_machine_records(|_, _| true)
    }

    fn remote_machine_records(&self, keep: impl Fn(&str, &str) -> bool) -> Vec<Value> {
        #[cfg(unix)]
        if let Some(mux) = self.mux.upgrade()
            && let Some((publisher, records)) = mux.control_clients.remote_machine_catalog(keep)
            && mux.conversation_principal(publisher) == crate::conversation_store::LOCAL_USER
        {
            return records;
        }
        #[cfg(not(unix))]
        let _ = keep;
        Vec::new()
    }

    pub(super) fn remote_machine_snapshot(
        &self,
        selectors: &ResourceSelectors,
    ) -> Result<Value, ResourceError> {
        let raw = selectors.machine.as_deref().ok_or_else(|| {
            ResourceError::selector_invalid(
                "machine",
                "<missing>",
                "missing required machine selector",
            )
        })?;
        let selector = Selector::parse(raw)?;
        let matches = self.remote_machine_records(|id, name| match &selector {
            Selector::Id(wanted) => id == wanted,
            Selector::Name(wanted) => name == wanted,
            Selector::Current => false,
        });
        match matches.as_slice() {
            [] => Err(ResourceError::not_found("machine", raw)),
            [record] => Ok(record.clone()),
            _ => Err(ResourceError::ambiguous(
                "machine",
                raw,
                matches
                    .iter()
                    .filter_map(|record| record["id"].as_str().map(str::to_owned))
                    .collect(),
            )),
        }
    }
}
