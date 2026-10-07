//! The RPC surface as a checked-in JSON document, embedded so
//! `acpmux daemon schema` always matches the running binary. A test fails
//! when a method constant is missing from it.

pub const SCHEMA: &str = include_str!("../docs/acpmux-schema.json");

#[cfg(test)]
mod tests {
    use super::SCHEMA;
    use crate::rpc::method;

    #[test]
    fn schema_lists_every_mux_method_and_notification() {
        let v: serde_json::Value = serde_json::from_str(SCHEMA).expect("schema is valid JSON");
        let methods = v["methods"].as_object().expect("methods");
        let notes = v["notifications"].as_object().expect("notifications");
        for m in [
            method::MUX_STATUS,
            method::MUX_SESSIONS,
            method::MUX_WEB_MODES,
            method::MUX_HARNESSES,
            method::MUX_RELOAD_CONFIG,
            method::MUX_DEFAULTS,
            method::MUX_ATTACH,
            method::MUX_DETACH,
            method::MUX_WATCH,
            method::MUX_RENAME,
            method::MUX_KILL,
            method::MUX_QUEUE_REMOVE,
            method::MUX_INFO,
            method::MUX_EVENTS,
            method::MUX_PERMISSION_RESPOND,
            method::MUX_PERMISSION_GROUPS,
            method::MUX_PERMISSION_GROUP_RESPOND,
            method::MUX_PERMISSION_CHAT_REVOKE,
            method::MUX_SET_POLICY,
            method::MUX_SET_RULES,
            method::MUX_TAG,
            method::MUX_WAIT,
            method::MUX_WARM,
            method::MUX_HISTORY,
            method::MUX_SCHEMA,
            method::MUX_EXPORT,
            method::MUX_IMPORT,
            method::MUX_SHUTDOWN,
            method::MUX_HANDOFF_PREPARE,
            method::MUX_HANDOFF_GET,
            method::MUX_HANDOFF_DRAFT,
            method::MUX_HANDOFF_START,
            method::MUX_HANDOFF_DISCARD,
            method::ACP_TRUST_GET,
            method::ACP_TRUST_SET,
            method::MUX_HARNESS_ENABLE,
            crate::catalog::RPC_GET,
            crate::catalog::RPC_REFRESH,
        ] {
            assert!(methods.contains_key(m), "schema is missing method {m}");
        }
        // Folder profiles in the harness list (BRING-YOUR-OWN-HARNESS H4).
        let harnesses = &methods[method::MUX_HARNESSES];
        assert!(harnesses["params"].get("cwd").is_some(), "{harnesses}");
        assert!(harnesses["result"].get("folderProfiles").is_some(), "{harnesses}");
        for n in [
            method::MUX_EVENT,
            method::MUX_SESSION_CHANGED,
            method::MUX_PERMISSION_PENDING,
            method::MUX_PROMPT_ACCEPTED,
            method::MUX_HARNESSES_CHANGED,
            crate::catalog::EVENT_CHANGED,
        ] {
            assert!(notes.contains_key(n), "schema is missing notification {n}");
        }
    }
}
