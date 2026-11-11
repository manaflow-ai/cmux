//! The `_acpmux/sessions` filters a capability serves, and the one check every request that
//! sends one goes through. An older acpmux ignores a param it does not know and answers the
//! whole list, never an error: a filter sent unchecked reads every peer's sessions (31 MB on a
//! Mac that mirrors ~10,000) and the caller takes them for the narrowed list. Here a filter is
//! sent only to an acpmux whose `initialize` lists its capability; to any other, the request
//! goes without it and [`GatedList::narrow`] applies it to the rows, so the answer is the same.
//! `agent_session_list_gate_tests.rs` refuses a gated field's name anywhere else in this crate.

use serde_json::{Value, json};
use std::time::Duration;

use super::{AcpmuxLink, LinkError};

/// `localOnly`, `excludeStatus` and `orderBy` (acpmux `capabilities.rs`).
pub(crate) const SESSION_LIST_FILTERS: &str = "session-list-filters-v1";
/// `pendingOnly` (acpmux `capabilities.rs`).
pub(crate) const SESSION_LIST_PENDING: &str = "session-list-pending-v1";

/// Each gated `_acpmux/sessions` field and the capability that serves it.
pub(crate) const GATED_FIELDS: &[(&str, &str)] = &[
    ("localOnly", SESSION_LIST_FILTERS),
    ("excludeStatus", SESSION_LIST_FILTERS),
    ("orderBy", SESSION_LIST_FILTERS),
    ("pendingOnly", SESSION_LIST_PENDING),
];

/// The filters a session list asks for; built only here, sent only through [`Self::gate`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct SessionListFilter {
    /// Only this machine's own sessions, never a peer's.
    pub(crate) local_only: bool,
    /// Only the sessions with a pending permission or question.
    pub(crate) pending_only: bool,
}

/// A session list's request as this acpmux serves it: the params to send, and the filters
/// it does not serve, which [`GatedList::narrow`] applies to the rows instead.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct GatedList {
    pub(crate) params: Value,
    unserved: SessionListFilter,
}

impl SessionListFilter {
    /// `params` with each of these filters `capabilities` serves; the rest are left for
    /// [`GatedList::narrow`].
    pub(crate) fn gate(self, mut params: Value, capabilities: &[String]) -> GatedList {
        let serves = |capability: &str| capabilities.iter().any(|c| c == capability);
        let mut unserved = Self::default();
        if self.local_only {
            if serves(SESSION_LIST_FILTERS) {
                set(&mut params, "localOnly");
            } else {
                unserved.local_only = true;
            }
        }
        if self.pending_only {
            if serves(SESSION_LIST_PENDING) {
                set(&mut params, "pendingOnly");
            } else {
                unserved.pending_only = true;
            }
        }
        GatedList { params, unserved }
    }
}

fn set(params: &mut Value, field: &str) {
    if !params.is_object() {
        *params = json!({});
    }
    if let Some(fields) = params.as_object_mut() {
        fields.insert(field.to_owned(), Value::Bool(true));
    }
}

impl GatedList {
    /// The acpmux serves every filter asked for: its answer is already narrowed.
    pub(crate) fn served(&self) -> bool {
        self.unserved == SessionListFilter::default()
    }

    /// `reply`'s rows kept to the filters the acpmux did not serve.
    pub(crate) fn narrow(&self, mut reply: Value) -> Value {
        let filter = self.unserved;
        if let Some(rows) = reply.get_mut("sessions").and_then(Value::as_array_mut) {
            rows.retain(|row| {
                (!filter.local_only || row.get("peer").is_none_or(Value::is_null))
                    && (!filter.pending_only
                        || row.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0)
            });
        }
        reply
    }
}

impl AcpmuxLink {
    /// The capability ids this acpmux serves (its `initialize` reply's
    /// `_meta.acpmux.capabilities`), asked once per link; `meta` goes in that request's
    /// `_meta` (a teammate's link names its author on every call). An acpmux that refuses or
    /// answers without the list serves none, so every gated filter is applied here instead.
    pub(crate) fn capabilities(&self, meta: Option<&Value>, timeout: Duration) -> &[String] {
        self.capabilities.get_or_init(|| {
            let mut hello = json!({"protocolVersion": 1,
                "clientInfo": {"name": "cmux-agent-session", "version": "1"}, "clientCapabilities": {}});
            if let (Some(meta), Some(fields)) = (meta, hello.as_object_mut()) {
                fields.insert("_meta".into(), meta.clone());
            }
            let reply: Result<Value, LinkError> = self.call("initialize", hello, timeout);
            reply
                .ok()
                .and_then(|reply| {
                    let ids = reply.pointer("/_meta/acpmux/capabilities")?.as_array()?;
                    Some(ids.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                })
                .unwrap_or_default()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn caps(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|id| (*id).to_owned()).collect()
    }

    #[test]
    fn a_served_filter_is_sent_and_an_unserved_one_applied_to_the_rows() {
        let local = SessionListFilter { local_only: true, ..SessionListFilter::default() };
        let served = local.gate(json!({}), &caps(&["acpmux-v1", SESSION_LIST_FILTERS]));
        assert!(served.served());
        assert_eq!(served.params, json!({"localOnly": true}));
        let old = local.gate(json!({"withTools": false}), &caps(&["acpmux-v1"]));
        assert!(!old.served());
        assert_eq!(old.params, json!({"withTools": false}), "no localOnly to an older acpmux");
        let rows = json!({"sessions": [{"sessionId": "own"}, {"sessionId": "far", "peer": "mac"},
                                       {"sessionId": "own2", "peer": null}]});
        assert_eq!(
            old.narrow(rows)["sessions"],
            json!([{"sessionId": "own"}, {"sessionId": "own2", "peer": null}])
        );
    }

    #[test]
    fn pending_only_needs_its_own_capability() {
        let pending = SessionListFilter { pending_only: true, ..SessionListFilter::default() };
        let old = pending.gate(json!({}), &caps(&[SESSION_LIST_FILTERS]));
        assert_eq!(old.params, json!({}));
        let rows = json!({"sessions": [{"sessionId": "a", "pendingPermissions": 1},
                                       {"sessionId": "b", "pendingPermissions": 0}]});
        assert_eq!(
            old.narrow(rows)["sessions"],
            json!([{"sessionId": "a", "pendingPermissions": 1}])
        );
        let served = pending.gate(json!({}), &caps(&[SESSION_LIST_PENDING]));
        assert_eq!(served.params, json!({"pendingOnly": true}));
    }

    /// The detector's field list is this table's.
    #[test]
    fn the_detector_knows_every_gated_field() {
        let mut table: Vec<&str> = GATED_FIELDS.iter().map(|(field, _)| *field).collect();
        let mut detector = super::super::list_gate_tests::GATED_FIELDS.to_vec();
        table.sort_unstable();
        detector.sort_unstable();
        assert_eq!(table, detector);
    }
}
