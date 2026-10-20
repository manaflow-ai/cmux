//! Read-only remote catalog projection. The local snapshot and all session
//! effects stay with the native owner; a published record is never a dial.

use super::{LocalResourceMachineService, ResourceError, ResourceSelectors, Selector};
use serde_json::Value;

impl LocalResourceMachineService {
    pub(super) fn remote_machine_snapshots(&self) -> Vec<Value> {
        #[cfg(unix)]
        if let Some(mux) = self.mux.upgrade()
            && let Some((publisher, records)) = mux.control_clients.remote_machine_catalog()
            && mux.conversation_principal(publisher) == crate::conversation_store::LOCAL_USER
        {
            return records;
        }
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
        let matches: Vec<_> = self
            .remote_machine_snapshots()
            .into_iter()
            .filter(|record| match &selector {
                Selector::Id(id) => record["id"].as_str() == Some(id.as_str()),
                Selector::Name(name) => record["name"].as_str() == Some(name.as_str()),
                Selector::Current => false,
            })
            .collect();
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
